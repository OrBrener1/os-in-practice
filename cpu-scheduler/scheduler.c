/*
 * scheduler.c: a CPU scheduling simulator built on real processes and signals.
 *
 * Reads a process list from a CSV file and runs four algorithms on it, one
 * after the other: FCFS, SJF, Priority (all non-preemptive) and Round Robin.
 *
 * Design:
 *   - The parent is the scheduler and the only process that prints.
 *   - Every simulated process is a real child created with fork(). A child does
 *     nothing: it stops itself with SIGSTOP and waits.
 *   - The scheduler gives a process the CPU with SIGCONT, takes it away with
 *     SIGSTOP (Round Robin) and ends it with SIGTERM.
 *   - Simulated time passes in the parent: it arms a timer and sleeps in
 *     sigsuspend() until SIGALRM arrives. By default one time unit is one real
 *     second (alarm); --unit-ms N makes it N milliseconds (setitimer).
 *
 * Usage: scheduler <processes.csv> <time-quantum> [--unit-ms N] [--compare]
 * CSV line: name,description,arrival,burst,priority (blank lines and # comments are skipped)
 */
#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <limits.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#define MAX_PROCESSES 1000
#define MAX_LINE 256
#define NAME_LEN 51
#define DESC_LEN 101

typedef struct {
    char name[NAME_LEN];
    char description[DESC_LEN];
    int arrival;
    int burst;
    int priority; /* lower number runs first */
    int remaining;
    pid_t pid;
} Process;

typedef enum { POLICY_FCFS, POLICY_SJF, POLICY_PRIORITY } Policy;

static Process base[MAX_PROCESSES]; /* as read from the file, sorted by arrival */
static Process work[MAX_PROCESSES]; /* the copy each algorithm runs on */
static int nproc;
static int quantum;
static long unit_ms = 1000;
static int compare_mode;
static volatile sig_atomic_t timer_fired;

/* One row of the --compare table per algorithm. */
static struct {
    const char *name;
    double avg_wait;
    double avg_turnaround;
} results[4];
static int nresults;

static void record_result(const char *name, long long total_wait, long long total_turnaround) {
    results[nresults].name = name;
    results[nresults].avg_wait = (double)total_wait / nproc;
    results[nresults].avg_turnaround = (double)total_turnaround / nproc;
    nresults++;
}

/* ---------- signals and simulated time ---------- */

static void on_alarm(int sig) {
    (void)sig;
    timer_fired = 1;
}

/* Ctrl-C or SIGTERM: kill every child still alive so none is left stopped. */
static void on_interrupt(int sig) {
    for (int i = 0; i < nproc; i++)
        if (work[i].pid > 0)
            kill(work[i].pid, SIGKILL);
    _exit(128 + sig);
}

static void install_handlers(void) {
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sigemptyset(&sa.sa_mask);

    sa.sa_handler = on_alarm;
    if (sigaction(SIGALRM, &sa, NULL) == -1) { perror("sigaction"); exit(1); }

    sa.sa_handler = on_interrupt;
    if (sigaction(SIGINT, &sa, NULL) == -1 || sigaction(SIGTERM, &sa, NULL) == -1) {
        perror("sigaction");
        exit(1);
    }
}

/*
 * Let `units` time units pass. SIGALRM is blocked while the timer is armed and
 * released atomically inside sigsuspend(), so the signal cannot slip in between
 * the check of timer_fired and the wait (the race a plain pause() loop has).
 */
static void simulate(int units) {
    sigset_t block, previous;
    long long total_ms = (long long)units * unit_ms;

    if (units <= 0)
        return;

    sigemptyset(&block);
    sigaddset(&block, SIGALRM);
    sigprocmask(SIG_BLOCK, &block, &previous);
    timer_fired = 0;

    if (unit_ms == 1000) {
        alarm((unsigned int)units);
    } else {
        struct itimerval timer;
        memset(&timer, 0, sizeof timer);
        timer.it_value.tv_sec = (time_t)(total_ms / 1000);
        timer.it_value.tv_usec = (suseconds_t)((total_ms % 1000) * 1000);
        if (setitimer(ITIMER_REAL, &timer, NULL) == -1) { perror("setitimer"); exit(1); }
    }

    while (!timer_fired)
        sigsuspend(&previous);
    sigprocmask(SIG_SETMASK, &previous, NULL);
}

/* ---------- child processes ---------- */

static void wait_until_stopped(pid_t pid) {
    int status;
    pid_t r;
    do {
        r = waitpid(pid, &status, WUNTRACED);
    } while (r == -1 && errno == EINTR);
    if (r == -1) { perror("waitpid"); exit(1); }
    if (!WIFSTOPPED(status)) {
        fprintf(stderr, "child %d ended before it was scheduled\n", (int)pid);
        exit(1);
    }
}

static void terminate(Process *p) {
    if (p->pid <= 0)
        return;
    kill(p->pid, SIGCONT); /* a stopped process only handles SIGTERM once continued */
    kill(p->pid, SIGTERM);
    while (waitpid(p->pid, NULL, 0) == -1 && errno == EINTR)
        ;
    p->pid = -1;
}

static void terminate_all(Process procs[], int count) {
    for (int i = 0; i < count; i++)
        terminate(&procs[i]);
}

/* One child per simulated process. Each one stops itself and waits to be resumed. */
static void create_children(Process procs[], int count) {
    for (int i = 0; i < count; i++) {
        pid_t pid = fork();
        if (pid < 0) {
            perror("fork");
            terminate_all(procs, count);
            exit(1);
        }
        if (pid == 0) {
            signal(SIGINT, SIG_DFL);  /* the scheduler's handlers are not for the child */
            signal(SIGTERM, SIG_DFL);
            raise(SIGSTOP);
            for (;;)
                pause();
        }
        procs[i].pid = pid;
        wait_until_stopped(pid); /* do not schedule a child that is not parked yet */
    }
}

static void give_cpu(Process *p) { kill(p->pid, SIGCONT); }

static void take_cpu(Process *p) {
    kill(p->pid, SIGSTOP);
    wait_until_stopped(p->pid);
}

/* ---------- output ---------- */

static void print_header(const char *mode) {
    printf("══════════════════════════════════════════════\n");
    printf(">> Scheduler Mode : %s\n", mode);
    printf(">> Engine Status  : Initialized\n");
    printf("──────────────────────────────────────────────\n\n");
}

static void print_footer_average(double average) {
    printf("\n──────────────────────────────────────────────\n");
    printf(">> Engine Status  : Completed\n");
    printf(">> Summary        :\n");
    printf("   └─ Average Waiting Time : %.2f time units\n", average);
    printf(">> End of Report\n");
    printf("══════════════════════════════════════════════\n");
}

static void print_footer_turnaround(int total) {
    printf("\n──────────────────────────────────────────────\n");
    printf(">> Engine Status  : Completed\n");
    printf(">> Summary        :\n");
    printf("   └─ Total Turnaround Time : %d time units\n\n", total);
    printf(">> End of Report\n");
    printf("══════════════════════════════════════════════\n");
}

static void print_run(int start, int end, const Process *p) {
    printf("%d → %d: %s Running %s.\n", start, end, p->name, p->description);
    fflush(stdout);
}

static void print_idle(int start, int end) {
    if (end > start) {
        printf("%d → %d: Idle.\n", start, end);
        fflush(stdout);
    }
}

/* ---------- input ---------- */

static void fail_line(const char *path, int line_no, const char *why) {
    fprintf(stderr, "%s:%d: %s\n", path, line_no, why);
    exit(1);
}

static void read_processes(const char *path) {
    FILE *f = fopen(path, "r");
    char line[MAX_LINE + 2];
    int line_no = 0;

    if (!f) { perror(path); exit(1); }
    while (fgets(line, sizeof line, f)) {
        Process *p = &base[nproc];
        char extra;
        line_no++;
        line[strcspn(line, "\r\n")] = '\0';
        if (line[0] == '\0' || line[0] == '#') /* blank lines and # comments */
            continue;
        if (nproc == MAX_PROCESSES)
            fail_line(path, line_no, "more than 1000 processes");
        if (sscanf(line, "%50[^,],%100[^,],%d,%d,%d%c", p->name, p->description,
                   &p->arrival, &p->burst, &p->priority, &extra) != 5)
            fail_line(path, line_no, "expected: name,description,arrival,burst,priority");
        if (p->arrival < 0)
            fail_line(path, line_no, "arrival time must not be negative");
        if (p->burst <= 0)
            fail_line(path, line_no, "burst time must be positive");
        if (p->priority <= 0)
            fail_line(path, line_no, "priority must be positive");
        p->remaining = p->burst;
        p->pid = -1;
        nproc++;
    }
    fclose(f);
    if (nproc == 0) {
        fprintf(stderr, "%s: no processes\n", path);
        exit(1);
    }
}

/* Insertion sort is stable, so equal arrival times keep their file order. */
static void sort_by_arrival(void) {
    for (int i = 1; i < nproc; i++) {
        Process key = base[i];
        int j = i - 1;
        while (j >= 0 && base[j].arrival > key.arrival) {
            base[j + 1] = base[j];
            j--;
        }
        base[j + 1] = key;
    }
}

static void reset_work(void) {
    for (int i = 0; i < nproc; i++) {
        work[i] = base[i];
        work[i].remaining = base[i].burst;
        work[i].pid = -1;
    }
}

/* ---------- the algorithms ---------- */

/* Among the arrived, unfinished processes, the best one by policy; -1 if none.
 * The array is in arrival order and only a strictly better process replaces the
 * current pick, so ties go to the one that came first. */
static int pick_next(const int done[], int now, Policy policy) {
    int best = -1;
    for (int i = 0; i < nproc; i++) {
        if (done[i] || work[i].arrival > now)
            continue;
        if (best == -1 || (policy == POLICY_SJF && work[i].burst < work[best].burst) ||
            (policy == POLICY_PRIORITY && work[i].priority < work[best].priority))
            best = i;
        if (policy == POLICY_FCFS)
            return i;
    }
    return best;
}

static int earliest_arrival(const int done[]) {
    int earliest = INT_MAX;
    for (int i = 0; i < nproc; i++)
        if (!done[i] && work[i].arrival < earliest)
            earliest = work[i].arrival;
    return earliest;
}

static void run_non_preemptive(const char *mode, Policy policy) {
    int done[MAX_PROCESSES] = {0};
    int finished = 0, now = 0;
    long long total_wait = 0, total_turnaround = 0;

    reset_work();
    print_header(mode);
    create_children(work, nproc);

    while (finished < nproc) {
        int i = pick_next(done, now, policy);
        if (i == -1) {
            int next = earliest_arrival(done);
            print_idle(now, next);
            simulate(next - now);
            now = next;
            continue;
        }
        total_wait += now - work[i].arrival;
        print_run(now, now + work[i].burst, &work[i]);
        give_cpu(&work[i]);
        simulate(work[i].burst);
        terminate(&work[i]);
        now += work[i].burst;
        total_turnaround += now - work[i].arrival;
        done[i] = 1;
        finished++;
    }
    print_footer_average((double)total_wait / nproc);
    record_result(mode, total_wait, total_turnaround);
}

typedef struct {
    int items[MAX_PROCESSES];
    int head, size;
} Queue;

static void push(Queue *q, int v) { q->items[(q->head + q->size++) % MAX_PROCESSES] = v; }

static int pop(Queue *q) {
    int v = q->items[q->head];
    q->head = (q->head + 1) % MAX_PROCESSES;
    q->size--;
    return v;
}

static void admit_arrivals(Queue *q, int now, int *next_arrival) {
    while (*next_arrival < nproc && work[*next_arrival].arrival <= now)
        push(q, (*next_arrival)++);
}

static void run_round_robin(void) {
    Queue q = {{0}, 0, 0};
    int finished = 0, now = 0, next_arrival = 0;
    long long total_wait = 0, total_turnaround = 0;

    reset_work();
    print_header("Round Robin");
    create_children(work, nproc);

    while (finished < nproc) {
        int i, slice;
        admit_arrivals(&q, now, &next_arrival);
        if (q.size == 0) {
            int next = work[next_arrival].arrival;
            print_idle(now, next);
            simulate(next - now);
            now = next;
            continue;
        }
        i = pop(&q);
        slice = work[i].remaining < quantum ? work[i].remaining : quantum;
        print_run(now, now + slice, &work[i]);
        give_cpu(&work[i]);
        simulate(slice);
        now += slice;
        work[i].remaining -= slice;
        /* Processes that arrived during the slice queue up before the preempted one. */
        admit_arrivals(&q, now, &next_arrival);
        if (work[i].remaining > 0) {
            take_cpu(&work[i]);
            push(&q, i);
        } else {
            terminate(&work[i]);
            finished++;
            /* waiting = time in the ready queue = turnaround minus the time it ran */
            total_turnaround += now - work[i].arrival;
            total_wait += now - work[i].arrival - work[i].burst;
        }
    }
    print_footer_turnaround(now);
    record_result("Round Robin", total_wait, total_turnaround);
}

static void print_comparison(void) {
    printf("══════════════════════════════════════════════\n");
    printf(">> Comparison\n");
    printf("──────────────────────────────────────────────\n");
    printf("   %-14s %12s %16s\n", "Algorithm", "Avg waiting", "Avg turnaround");
    for (int i = 0; i < nresults; i++)
        printf("   %-14s %12.2f %16.2f\n", results[i].name, results[i].avg_wait,
               results[i].avg_turnaround);
    printf("══════════════════════════════════════════════\n\n");
}

/* ---------- main ---------- */

static long parse_positive(const char *text, const char *what, long max) {
    char *end;
    long v;
    errno = 0;
    v = strtol(text, &end, 10);
    if (errno || *end != '\0' || v < 1 || v > max) {
        fprintf(stderr, "%s must be an integer from 1 to %ld\n", what, max);
        exit(1);
    }
    return v;
}

int main(int argc, char *argv[]) {
    if (argc < 3) {
        fprintf(stderr, "Usage: %s <processes.csv> <time-quantum> [--unit-ms N] [--compare]\n", argv[0]);
        return 1;
    }
    quantum = (int)parse_positive(argv[2], "time quantum", INT_MAX);
    for (int i = 3; i < argc; i++) {
        if (strcmp(argv[i], "--compare") == 0) {
            compare_mode = 1;
        } else if (strcmp(argv[i], "--unit-ms") == 0 && i + 1 < argc) {
            unit_ms = parse_positive(argv[++i], "--unit-ms", 1000);
        } else {
            fprintf(stderr, "Usage: %s <processes.csv> <time-quantum> [--unit-ms N] [--compare]\n", argv[0]);
            return 1;
        }
    }

    install_handlers();
    read_processes(argv[1]);
    sort_by_arrival();

    run_non_preemptive("FCFS", POLICY_FCFS);
    printf("\n");
    run_non_preemptive("SJF", POLICY_SJF);
    printf("\n");
    run_non_preemptive("Priority", POLICY_PRIORITY);
    printf("\n");
    run_round_robin();
    printf("\n");
    if (compare_mode)
        print_comparison();
    return 0;
}
