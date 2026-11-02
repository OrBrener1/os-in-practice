"""Sends 100000 records (seed 7) through each channel and compares the summary
lines with examples/demo_output.txt. The timing line goes to stderr and is not
compared, because it changes from run to run."""
import difflib
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
BINARY = HERE.parent / "channels"
SOURCE = HERE.parent / "channels.c"

if not BINARY.exists() or BINARY.stat().st_mtime < SOURCE.stat().st_mtime:
    subprocess.run(["gcc", "-Wall", "-Wextra", "-O2", "-o", str(BINARY), str(SOURCE)], check=True)

lines = []
for channel in ["pipe", "fifo", "shm-slot", "shm"]:
    result = subprocess.run([str(BINARY), channel, "100000", "7"], capture_output=True, text=True, timeout=60)
    if result.returncode != 0:
        print(f"{channel} failed:\n{result.stderr}")
        sys.exit(1)
    lines.append(result.stdout)
actual = "".join(lines)
expected = (HERE / "demo_output.txt").read_text()

if actual == expected:
    print("Output matches examples/demo_output.txt")
    sys.exit(0)
print("Output differs from examples/demo_output.txt")
sys.stdout.writelines(difflib.unified_diff(expected.splitlines(True), actual.splitlines(True), "expected", "actual"))
sys.exit(1)
