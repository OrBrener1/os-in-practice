/*
 * channels.c: the same stream of records sent through four inter-process channels.
 *
 * A producer (a forked child) generates N numeric records and a consumer (the
 * parent) computes their count, sum, min and max. Only the channel between them
 * changes:
 *
 *   pipe       anonymous pipe, one write() per batch of records
 *   fifo       named pipe in a private temp directory
 *   shm-slot   System V shared memory, a one-record mailbox (ping-pong)
 *   shm        System V shared memory, a ring buffer of 4096 records
 *
 * Every run is checked against aggregates computed directly from the generator,
 * so a lost, duplicated or reordered record shows up as an error.
 *
 * Usage: channels <pipe|fifo|shm-slot|shm> <N> <seed> [--batch K]
 *        channels compare <N> <seed>
 */
#define _POSIX_C_SOURCE 200809L
#ifdef __APPLE__
#define _DARWIN_C_SOURCE /* macOS hides mkdtemp when only POSIX is requested */
#endif
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <sched.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ipc.h>
#include <sys/shm.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define RING_SLOTS 4096 /* a power of two, so an index wraps with a mask */
#define MAX_BATCH (1 << 20)
#define SPINS_PER_CHECK 4096

typedef enum { CH_PIPE, CH_FIFO, CH_SLOT, CH_RING } Channel;
static const char *const channel_label[] = {"PIPE", "FIFO", "SHM-SLOT", "SHM"};

typedef struct {
    unsigned long count, sum;
    long min, max;
} Stats;

typedef struct {
    pid_t pid;
    int reaped, status;
} Child;

static int in_child; /* a forked child must leave with _exit(), not exit() */
static char fifo_dir[64], fifo_path[96];

/* ---------- errors and cleanup ---------- */

static void die(const char *what) {
    perror(what);
    if (in_child)
        _exit(1);
    exit(1);
}

static void fail(const char *message) {
    fprintf(stderr, "%s\n", message);
    if (in_child)
        _exit(1);
    exit(1);
}

/* Registered with atexit(), so every error path in the parent removes the FIFO. */
static void remove_fifo(void) {
    if (fifo_path[0]) {
        unlink(fifo_path);
        fifo_path[0] = '\0';
    }
    if (fifo_dir[0]) {
        rmdir(fifo_dir);
        fifo_dir[0] = '\0';
    }
}

/* Ctrl-C or SIGTERM in the parent: remove the FIFO, then die of the same signal. */
static void on_signal(int sig) {
    remove_fifo();
    signal(sig, SIG_DFL);
    raise(sig);
}

/* ---------- the data ---------- */

static long value_at(long i, long seed) {
    return (long)(((unsigned long)i * 1103515245UL + (unsigned long)seed) % 100000UL);
}

static void stats_add(Stats *s, long v) {
    if (s->count == 0 || v < s->min)
        s->min = v;
    if (s->count == 0 || v > s->max)
        s->max = v;
    s->count++;
    s->sum += (unsigned long)v;
}

static Stats expected_stats(long n, long seed) {
    Stats s = {0, 0, 0, 0};
    for (long i = 0; i < n; i++)
        stats_add(&s, value_at(i, seed));
    return s;
}

/* ---------- reading, writing, waiting ---------- */

static void write_all(int fd, const void *buf, size_t n) {
    const char *p = buf;
    while (n > 0) {
        ssize_t w = write(fd, p, n);
        if (w == -1) {
            if (errno == EINTR)
                continue;
            die("write");
        }
        p += w;
        n -= (size_t)w;
    }
}

/* Reads until n bytes arrived or the writer closed its end. Returns the bytes read. */
static size_t read_upto(int fd, void *buf, size_t n) {
    char *p = buf;
    size_t got = 0;
    while (got < n) {
        ssize_t r = read(fd, p + got, n - got);
        if (r == -1) {
            if (errno == EINTR)
                continue;
            die("read");
        }
        if (r == 0)
            break;
        got += (size_t)r;
    }
    return got;
}

static double now_ms(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) == -1)
        die("clock_gettime");
    return ts.tv_sec * 1000.0 + ts.tv_nsec / 1e6;
}

static pid_t spawn(void) {
    pid_t pid = fork();
    if (pid == -1)
        die("fork");
    if (pid == 0) {
        in_child = 1;
        signal(SIGINT, SIG_DFL); /* the parent's cleanup handler is not for the child */
        signal(SIGTERM, SIG_DFL);
    }
    return pid;
}

/* True while the producer may still be running. Checks only every few thousand spins. */
static int still_producing(Child *c, unsigned long *spins) {
    pid_t r;
    if ((++*spins % SPINS_PER_CHECK) != 0 || c->reaped)
        return !c->reaped;
    r = waitpid(c->pid, &c->status, WNOHANG);
    if (r == c->pid)
        c->reaped = 1;
    else if (r == -1 && errno != EINTR)
        die("waitpid");
    return !c->reaped;
}

static void finish_child(Child *c) {
    if (!c->reaped) {
        pid_t r;
        do {
            r = waitpid(c->pid, &c->status, 0);
        } while (r == -1 && errno == EINTR);
        if (r == -1)
            die("waitpid");
        c->reaped = 1;
    }
    if (!WIFEXITED(c->status) || WEXITSTATUS(c->status) != 0)
        fail("the producer failed");
}

/* A producer that waits for room gives up if the consumer is gone. */
static void producer_wait(pid_t parent, unsigned long *spins) {
    if ((++*spins % SPINS_PER_CHECK) == 0 && getppid() != parent)
        _exit(1);
    sched_yield();
}

/* ---------- pipe and FIFO ---------- */

static void produce_stream(int fd, long n, long seed, int batch) {
    long *buf = malloc((size_t)batch * sizeof *buf);
    if (!buf)
        die("malloc");
    for (long i = 0; i < n;) {
        long chunk = n - i < batch ? n - i : batch;
        for (long k = 0; k < chunk; k++)
            buf[k] = value_at(i + k, seed);
        write_all(fd, buf, (size_t)chunk * sizeof *buf);
        i += chunk;
    }
    free(buf);
}

static Stats consume_stream(int fd, long n, int batch) {
    Stats s = {0, 0, 0, 0};
    long *buf = malloc((size_t)batch * sizeof *buf);
    if (!buf)
        die("malloc");
    for (long got = 0; got < n;) {
        long chunk = n - got < batch ? n - got : batch;
        size_t bytes = read_upto(fd, buf, (size_t)chunk * sizeof *buf);
        if (bytes % sizeof *buf != 0)
            fail("the stream ended in the middle of a record");
        for (size_t k = 0; k < bytes / sizeof *buf; k++)
            stats_add(&s, buf[k]);
        got += (long)(bytes / sizeof *buf);
        if (bytes < (size_t)chunk * sizeof *buf)
            fail("the stream ended before all records arrived");
    }
    free(buf);
    return s;
}

static Stats run_pipe(long n, long seed, int batch) {
    int fd[2];
    Stats s;
    Child c = {0, 0, 0};

    if (pipe(fd) == -1)
        die("pipe");
    c.pid = spawn();
    if (c.pid == 0) {
        if (close(fd[0]) == -1)
            die("close");
        produce_stream(fd[1], n, seed, batch);
        if (close(fd[1]) == -1)
            die("close");
        _exit(0);
    }
    /* The unused write end must be closed here, or the reader never sees EOF. */
    if (close(fd[1]) == -1)
        die("close");
    s = consume_stream(fd[0], n, batch);
    if (close(fd[0]) == -1)
        die("close");
    finish_child(&c);
    return s;
}

static Stats run_fifo(long n, long seed, int batch) {
    char dir[] = "/tmp/ipc-channels-XXXXXX";
    Stats s;
    Child c = {0, 0, 0};
    int fd;

    if (!mkdtemp(dir))
        die("mkdtemp");
    snprintf(fifo_dir, sizeof fifo_dir, "%s", dir);
    snprintf(fifo_path, sizeof fifo_path, "%s/fifo", dir);
    if (mkfifo(fifo_path, 0600) == -1)
        die("mkfifo");

    c.pid = spawn();
    if (c.pid == 0) {
        fd = open(fifo_path, O_WRONLY);
        if (fd == -1)
            die("open");
        produce_stream(fd, n, seed, batch);
        if (close(fd) == -1)
            die("close");
        _exit(0);
    }
    fd = open(fifo_path, O_RDONLY);
    if (fd == -1)
        die("open");
    s = consume_stream(fd, n, batch);
    if (close(fd) == -1)
        die("close");
    finish_child(&c);
    remove_fifo();
    return s;
}

/* ---------- shared memory ---------- */

/*
 * Creates an anonymous segment, attaches it and marks it for removal at once.
 * A segment marked for removal lives until the last process detaches, so even a
 * kill -9 of the parent cannot leave one behind. The child inherits the mapping
 * through fork().
 */
static void *shm_create(size_t size) {
    void *p;
    int id = shmget(IPC_PRIVATE, size, IPC_CREAT | 0600);
    if (id == -1)
        die("shmget");
    p = shmat(id, NULL, 0);
    if (p == (void *)-1) {
        shmctl(id, IPC_RMID, NULL);
        die("shmat");
    }
    if (shmctl(id, IPC_RMID, NULL) == -1)
        die("shmctl");
    return p;
}

enum { SLOT_EMPTY, SLOT_FULL };

typedef struct {
    _Atomic int status;
    long value;
} Slot;

static Stats run_slot(long n, long seed) {
    Slot *slot = shm_create(sizeof *slot);
    Stats s = {0, 0, 0, 0};
    Child c = {0, 0, 0};
    unsigned long spins = 0;
    pid_t parent = getpid();

    atomic_init(&slot->status, SLOT_EMPTY);
    c.pid = spawn();
    if (c.pid == 0) {
        for (long i = 0; i < n; i++) {
            while (atomic_load_explicit(&slot->status, memory_order_acquire) != SLOT_EMPTY)
                producer_wait(parent, &spins);
            slot->value = value_at(i, seed);
            atomic_store_explicit(&slot->status, SLOT_FULL, memory_order_release);
        }
        if (shmdt(slot) == -1)
            die("shmdt");
        _exit(0);
    }
    for (long got = 0; got < n; got++) {
        while (atomic_load_explicit(&slot->status, memory_order_acquire) != SLOT_FULL) {
            if (!still_producing(&c, &spins)) {
                if (atomic_load_explicit(&slot->status, memory_order_acquire) == SLOT_FULL)
                    break;
                fail("the producer ended before all records arrived");
            }
            sched_yield();
        }
        stats_add(&s, slot->value);
        atomic_store_explicit(&slot->status, SLOT_EMPTY, memory_order_release);
    }
    finish_child(&c);
    if (shmdt(slot) == -1)
        die("shmdt");
    return s;
}

typedef struct {
    _Alignas(64) _Atomic unsigned long head; /* next slot the consumer reads */
    _Alignas(64) _Atomic unsigned long tail; /* next slot the producer writes */
    _Alignas(64) long slots[RING_SLOTS];
} Ring;

static Stats run_ring(long n, long seed) {
    Ring *ring = shm_create(sizeof *ring);
    Stats s = {0, 0, 0, 0};
    Child c = {0, 0, 0};
    unsigned long spins = 0;
    pid_t parent = getpid();

    atomic_init(&ring->head, 0);
    atomic_init(&ring->tail, 0);
    c.pid = spawn();
    if (c.pid == 0) {
        unsigned long tail = 0;
        for (long i = 0; i < n;) {
            unsigned long head = atomic_load_explicit(&ring->head, memory_order_acquire);
            unsigned long space = RING_SLOTS - (tail - head);
            unsigned long chunk;
            if (space == 0) {
                producer_wait(parent, &spins);
                continue;
            }
            chunk = (unsigned long)(n - i) < space ? (unsigned long)(n - i) : space;
            for (unsigned long k = 0; k < chunk; k++)
                ring->slots[(tail + k) & (RING_SLOTS - 1)] = value_at(i + (long)k, seed);
            tail += chunk;
            i += (long)chunk;
            atomic_store_explicit(&ring->tail, tail, memory_order_release);
        }
        if (shmdt(ring) == -1)
            die("shmdt");
        _exit(0);
    }
    {
        unsigned long head = 0;
        for (long got = 0; got < n;) {
            unsigned long tail = atomic_load_explicit(&ring->tail, memory_order_acquire);
            unsigned long avail = tail - head;
            if (avail == 0) {
                if (!still_producing(&c, &spins)) {
                    tail = atomic_load_explicit(&ring->tail, memory_order_acquire);
                    if (tail == head)
                        fail("the producer ended before all records arrived");
                    continue;
                }
                sched_yield();
                continue;
            }
            for (unsigned long k = 0; k < avail; k++)
                stats_add(&s, ring->slots[(head + k) & (RING_SLOTS - 1)]);
            head += avail;
            got += (long)avail;
            atomic_store_explicit(&ring->head, head, memory_order_release);
        }
    }
    finish_child(&c);
    if (shmdt(ring) == -1)
        die("shmdt");
    return s;
}

/* ---------- running and reporting ---------- */

/* Runs one channel, checks the result against the generator, returns the time in ms. */
static double run_channel(Channel ch, long n, long seed, int batch, int quiet) {
    double start = now_ms(), elapsed;
    Stats s, want;

    switch (ch) {
    case CH_PIPE: s = run_pipe(n, seed, batch); break;
    case CH_FIFO: s = run_fifo(n, seed, batch); break;
    case CH_SLOT: s = run_slot(n, seed); break;
    default: s = run_ring(n, seed); break;
    }
    elapsed = now_ms() - start;

    want = expected_stats(n, seed);
    if (s.count != want.count || s.sum != want.sum || s.min != want.min || s.max != want.max) {
        fprintf(stderr, "%s: the result differs from the generator: got count=%lu sum=%lu min=%ld max=%ld,"
                        " expected count=%lu sum=%lu min=%ld max=%ld\n",
                channel_label[ch], s.count, s.sum, s.min, s.max, want.count, want.sum, want.min, want.max);
        exit(1);
    }
    if (!quiet) {
        printf("[Channel: %s] count=%lu sum=%lu min=%ld max=%ld\n", channel_label[ch], s.count, s.sum,
               s.min, s.max);
        fflush(stdout);
        fprintf(stderr, "elapsed_ms=%.3f\n", elapsed);
    }
    return elapsed;
}

static void compare(long n, long seed) {
    static const struct {
        const char *name;
        Channel ch;
        int batch;
    } plan[] = {
        {"pipe, 1 record per write", CH_PIPE, 1},   {"pipe, 512 records per write", CH_PIPE, 512},
        {"fifo, 1 record per write", CH_FIFO, 1},   {"fifo, 512 records per write", CH_FIFO, 512},
        {"shm, one-slot mailbox", CH_SLOT, 1},      {"shm, ring buffer", CH_RING, 1},
    };
    printf("Sending %ld records over each channel (checked against the generator)\n\n", n);
    printf("%-30s %12s %16s\n", "Channel", "Time (ms)", "Million rec/s");
    for (size_t i = 0; i < sizeof plan / sizeof plan[0]; i++) {
        double ms = run_channel(plan[i].ch, n, seed, plan[i].batch, 1);
        printf("%-30s %12.1f %16.2f\n", plan[i].name, ms, (double)n / ms / 1000.0);
        fflush(stdout);
    }
}

/* ---------- command line ---------- */

static long parse_long(const char *text, const char *what, long min, long max) {
    char *end;
    long v;
    errno = 0;
    v = strtol(text, &end, 10);
    if (errno || *end != '\0' || v < min || v > max) {
        fprintf(stderr, "%s must be an integer from %ld to %ld\n", what, min, max);
        exit(1);
    }
    return v;
}

static void usage(const char *prog) {
    fprintf(stderr, "Usage: %s <pipe|fifo|shm-slot|shm> <N> <seed> [--batch K]\n       %s compare <N> <seed>\n",
            prog, prog);
    exit(1);
}

int main(int argc, char *argv[]) {
    static const char *const cli_name[] = {"pipe", "fifo", "shm-slot", "shm"};
    Channel ch = CH_PIPE;
    int batch = 1, batch_given = 0, is_compare, found = 0, i;
    long n, seed;

    if (argc < 4)
        usage(argv[0]);
    is_compare = strcmp(argv[1], "compare") == 0;
    if (!is_compare) {
        for (i = 0; i < 4; i++) {
            if (strcmp(argv[1], cli_name[i]) == 0) {
                ch = (Channel)i;
                found = 1;
            }
        }
        if (!found)
            usage(argv[0]);
    }
    n = parse_long(argv[2], "N", 1, LONG_MAX);
    seed = parse_long(argv[3], "seed", 0, LONG_MAX);
    if (argc == 6 && !is_compare && strcmp(argv[4], "--batch") == 0) {
        batch = (int)parse_long(argv[5], "--batch", 1, MAX_BATCH);
        batch_given = 1;
    } else if (argc != 4) {
        usage(argv[0]);
    }
    if (batch_given && ch != CH_PIPE && ch != CH_FIFO) {
        fprintf(stderr, "--batch applies to pipe and fifo only\n");
        return 1;
    }

    atexit(remove_fifo);
    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);
    if (is_compare)
        compare(n, seed);
    else
        run_channel(ch, n, seed, batch, 0);
    return 0;
}
