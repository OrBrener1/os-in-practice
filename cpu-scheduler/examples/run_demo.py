"""Runs the scheduler on examples/processes.csv with a time quantum of 2 and
compares the output with examples/demo_output.txt.

One time unit is shortened to 20 ms so the demo takes about a second instead of
a minute. The order of events is the same as with real seconds."""
import difflib
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCHEDULER = HERE.parent / "scheduler"
SOURCE = HERE.parent / "scheduler.c"

if not SCHEDULER.exists() or SCHEDULER.stat().st_mtime < SOURCE.stat().st_mtime:
    subprocess.run(["gcc", "-Wall", "-Wextra", "-o", str(SCHEDULER), str(SOURCE)], check=True)

result = subprocess.run(
    [str(SCHEDULER), str(HERE / "processes.csv"), "2", "--unit-ms", "20"],
    capture_output=True, text=True, timeout=60)
expected = (HERE / "demo_output.txt").read_text()

if result.returncode == 0 and result.stdout == expected:
    print("Output matches examples/demo_output.txt")
    sys.exit(0)

print("Output differs from examples/demo_output.txt")
sys.stdout.writelines(difflib.unified_diff(
    expected.splitlines(True), result.stdout.splitlines(True), "expected", "actual"))
sys.stdout.write(result.stderr)
sys.exit(1)
