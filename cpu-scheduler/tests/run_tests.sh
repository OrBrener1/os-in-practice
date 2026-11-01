#!/bin/bash
# Checks the cases the demo does not cover: bad input, the --compare numbers and
# cleanup on Ctrl-C. Run from the project folder: bash tests/run_tests.sh
cd "$(dirname "$0")/.." || exit 1
BIN=./scheduler
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAILED=0

check() {  # check <description> <command...>: passes when the command succeeds
    local name="$1"; shift
    if "$@" >/dev/null 2>&1; then
        echo "  ok    $name"
    else
        echo "  FAIL  $name"
        FAILED=$((FAILED + 1))
    fi
}

fails_with() {  # fails_with <message part> <command...>: exits non-zero and prints the message on stderr
    local msg="$1" err code
    shift
    err="$("$@" 2>&1 >/dev/null)"
    code=$?
    [ "$code" -ne 0 ] && [[ "$err" == *"$msg"* ]]
}

echo "Input checks"
printf 'a,b,0,3\n' > "$TMP/short.csv"
printf 'a,b,0,0,1\n' > "$TMP/zero_burst.csv"
printf 'a,b,-1,2,1\n' > "$TMP/negative.csv"
printf '' > "$TMP/empty.csv"
python3 -c "
for i in range(1001): print(f'p{i},d,{i},1,1')" > "$TMP/big.csv"
printf 'a,b,0,3,1\r\nc,d,0,2,1\r\n' > "$TMP/crlf.csv"

check "quantum 0 is rejected"        fails_with "time quantum"        $BIN examples/processes.csv 0
check "quantum 'x' is rejected"      fails_with "time quantum"        $BIN examples/processes.csv x
check "--unit-ms 0 is rejected"      fails_with "--unit-ms"           $BIN examples/processes.csv 2 --unit-ms 0
check "unknown option is rejected"   fails_with "Usage"               $BIN examples/processes.csv 2 --fast
check "no arguments prints usage"    fails_with "Usage"               $BIN
check "missing file is reported"     fails_with "No such file"        $BIN "$TMP/none.csv" 2
check "short line names the line"    fails_with "short.csv:1"         $BIN "$TMP/short.csv" 2
check "zero burst is rejected"       fails_with "burst time"          $BIN "$TMP/zero_burst.csv" 2
check "negative arrival is rejected" fails_with "arrival time"        $BIN "$TMP/negative.csv" 2
check "empty file is rejected"       fails_with "no processes"        $BIN "$TMP/empty.csv" 2
check "1001 processes is rejected"   fails_with "more than 1000"      $BIN "$TMP/big.csv" 2
check "CRLF line endings are read"   $BIN "$TMP/crlf.csv" 1 --unit-ms 5

echo "Numbers (two jobs, both arrive at 0: A needs 4, B needs 2, quantum 2)"
printf 'A,a,0,4,1\nB,b,0,2,2\n' > "$TMP/two.csv"
OUT="$($BIN "$TMP/two.csv" 2 --unit-ms 5 --compare)"
# worked out by hand: FCFS waits 0 and 4, SJF runs B first, Round Robin ends both at 4 and 6
check "FCFS   2.00 / 5.00"        grep -Eq "^   FCFS +2\.00 +5\.00$"        <<< "$OUT"
check "SJF    1.00 / 4.00"        grep -Eq "^   SJF +1\.00 +4\.00$"         <<< "$OUT"
check "Priority 2.00 / 5.00"      grep -Eq "^   Priority +2\.00 +5\.00$"    <<< "$OUT"
check "Round Robin 2.00 / 5.00"   grep -Eq "^   Round Robin +2\.00 +5\.00$"  <<< "$OUT"
check "turnaround total is 6"     grep -q "Total Turnaround Time : 6 time units" <<< "$OUT"

echo "Ctrl-C"
$BIN examples/processes.csv 2 > /dev/null 2>&1 &
PID=$!
sleep 2
CHILDREN="$(pgrep -P "$PID")"
kill -INT "$PID"
wait "$PID" 2>/dev/null
STATUS=$?
sleep 0.2
check "exit status is 130"        test "$STATUS" -eq 130
check "had children before"       test -n "$CHILDREN"
LEFT=0
for c in $CHILDREN; do kill -0 "$c" 2>/dev/null && LEFT=$((LEFT + 1)); done
check "no child left alive"       test "$LEFT" -eq 0

echo
if [ "$FAILED" -eq 0 ]; then echo "All checks passed."; else echo "$FAILED check(s) failed."; exit 1; fi
