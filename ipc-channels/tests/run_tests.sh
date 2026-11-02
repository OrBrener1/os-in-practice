#!/bin/bash
# Checks beyond the demo: sizes around the buffer limits, bad arguments, and cleanup
# after normal runs, Ctrl-C and kill -9. Run from the project folder: bash tests/run_tests.sh
cd "$(dirname "$0")/.." || exit 1
BIN=./channels
FAILED=0

check() {  # check <description> <command...>
    local name="$1"; shift
    if "$@" >/dev/null 2>&1; then echo "  ok    $name"; else echo "  FAIL  $name"; FAILED=$((FAILED + 1)); fi
}

fails_with() {  # fails_with <message part> <command...>: exits non-zero and prints the message
    local msg="$1" err code
    shift
    err="$("$@" 2>&1 >/dev/null)"
    code=$?
    [ "$code" -ne 0 ] && [[ "$err" == *"$msg"* ]]
}

oracle() {  # oracle <N> <seed>: the aggregates, computed in Python
    python3 -c "
n, seed = $1, $2
v = [(i * 1103515245 + seed) % 100000 for i in range(n)]
print(f'count={len(v)} sum={sum(v)} min={min(v)} max={max(v)}')"
}

matches_oracle() {  # matches_oracle <label> <N> <seed> <command...>
    local label="$1" n="$2" seed="$3"
    shift 3
    [ "$("$@" 2>/dev/null)" = "[Channel: $label] $(oracle "$n" "$seed")" ]
}

segments() { ipcs -m 2>/dev/null | grep -cE '^(0x|m )'; }
leftover_fifos() { ls -d /tmp/ipc-channels-* 2>/dev/null | wc -l | tr -d ' '; }

echo "Results against an independent calculation (Python)"
for n in 1 2 4095 4096 4097 50000; do
    check "pipe     N=$n"         matches_oracle PIPE     "$n" 5 $BIN pipe "$n" 5
    check "fifo     N=$n"         matches_oracle FIFO     "$n" 5 $BIN fifo "$n" 5
    check "shm-slot N=$n"         matches_oracle SHM-SLOT "$n" 5 $BIN shm-slot "$n" 5
    check "shm      N=$n"         matches_oracle SHM      "$n" 5 $BIN shm "$n" 5
done
check "pipe batch larger than N"   matches_oracle PIPE "100" 0 $BIN pipe 100 0 --batch 512
check "pipe N one past the batch"  matches_oracle PIPE "513" 0 $BIN pipe 513 0 --batch 512
check "fifo N not a multiple of the batch" matches_oracle FIFO "1000" 3 $BIN fifo 1000 3 --batch 64

echo "Arguments"
check "N 0 is rejected"            fails_with "N must"       $BIN pipe 0 1
check "negative seed is rejected"  fails_with "seed must"    $BIN pipe 10 -1
check "unknown channel prints usage" fails_with "Usage"      $BIN tube 10 1
check "no arguments prints usage"  fails_with "Usage"        $BIN
check "--batch 0 is rejected"      fails_with "--batch must" $BIN pipe 10 1 --batch 0
check "--batch with shm is rejected" fails_with "pipe and fifo only" $BIN shm 10 1 --batch 8
check "compare runs all six"       test "$($BIN compare 20000 1 2>&1 | grep -c ' [0-9.]* *[0-9.]*$')" -ge 6

echo "Cleanup"
BEFORE=$(segments)
for ch in shm-slot shm; do $BIN $ch 20000 1 >/dev/null 2>&1; done
$BIN fifo 20000 1 >/dev/null 2>&1
check "no segment left after normal runs"  test "$(segments)" -eq "$BEFORE"
check "no FIFO directory left after a run" test "$(leftover_fifos)" -eq 0

$BIN shm 2000000000 1 >/dev/null 2>&1 &
PID=$!
sleep 1
CHILD=$(pgrep -P "$PID" | head -1)
kill -9 "$PID" 2>/dev/null
wait "$PID" 2>/dev/null
sleep 1
check "the producer was running"           test -n "$CHILD"
check "no segment left after kill -9"      test "$(segments)" -eq "$BEFORE"
check "the producer exits when its parent is gone" bash -c "! kill -0 $CHILD 2>/dev/null"

$BIN fifo 2000000000 1 >/dev/null 2>&1 &
PID=$!
sleep 1
kill -INT "$PID" 2>/dev/null
wait "$PID" 2>/dev/null
STATUS=$?
sleep 0.5
check "Ctrl-C on a FIFO run ends with status 130" test "$STATUS" -eq 130
check "no FIFO directory left after Ctrl-C"       test "$(leftover_fifos)" -eq 0

echo
if [ "$FAILED" -eq 0 ]; then echo "All checks passed."; else echo "$FAILED check(s) failed."; exit 1; fi
