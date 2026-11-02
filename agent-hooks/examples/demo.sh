#!/bin/bash
# Sends four Bash commands through the runner, the way Claude Code would before running
# them, and compares the output with examples/demo_output.txt. Data goes to a temp folder.
# Run from the project folder: bash examples/demo.sh
cd "$(dirname "$0")/.." || exit 1
export HOOKS_DATA_DIR="$(mktemp -d)"
trap 'rm -rf "$HOOKS_DATA_DIR"' EXIT

send() {
    printf '$ %s\n' "$1"
    jq -cn --arg c "$1" '{tool_name: "Bash", tool_input: {command: $c}, session_id: "demo", cwd: env.HOOKS_DATA_DIR}' |
        ./hook_runner.sh PreToolUse Bash 2>&1 | grep -vE '^(Matched|Passed|Blocked|Warnings):|^--- |^$'
    printf 'exit %d\n\n' "${PIPESTATUS[1]}"
}

{
    send 'ls -la'
    send 'echo "cleaning up" && rm -fr build'
    send 'git commit -m "add the session summary"'
    send 'git commit -m "feat: add the session summary"'
} >"$HOOKS_DATA_DIR/out.txt"

cat "$HOOKS_DATA_DIR/out.txt"
if diff -q "$HOOKS_DATA_DIR/out.txt" examples/demo_output.txt >/dev/null; then
    echo "Output matches examples/demo_output.txt"
else
    echo "Output differs from examples/demo_output.txt"
    diff examples/demo_output.txt "$HOOKS_DATA_DIR/out.txt"
    exit 1
fi
