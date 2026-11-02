#!/bin/bash
# Runs the hooks registered in hooks.txt for one event and one tool, the way
# Claude Code would, so the hooks can be tried without it.
#
#   echo '<json>' | ./hook_runner.sh <event> <tool>
#   echo '{"tool_name":"Bash","tool_input":{"command":"ls"},"session_id":"s1"}' | ./hook_runner.sh PreToolUse Bash
#
# hooks.txt lines are event:matcher:script. The matcher is a tool name, several
# names joined by | (Edit|Write), or * for any tool. Scripts starting with ./ are
# relative to this folder. Hooks run in file order. For PreToolUse the first hook
# that exits with 2 blocks the action and stops the chain.
# Exit status: 2 when a PreToolUse hook blocked, 0 otherwise.

RUNNER_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="${HOOK_RUNNER_CONFIG:-$RUNNER_DIR/hooks.txt}"

if [ -t 1 ]; then
    RED=$'\033[0;31m' GREEN=$'\033[0;32m' YELLOW=$'\033[1;33m' CYAN=$'\033[0;36m' BOLD=$'\033[1m' RESET=$'\033[0m'
else
    RED='' GREEN='' YELLOW='' CYAN='' BOLD='' RESET=''
fi

if [ $# -ne 2 ] || [ -z "$1" ] || [ -z "$2" ]; then
    printf "Usage: echo '<json>' | %s <event> <tool>\n" "$0" >&2
    printf 'event: PreToolUse, PostToolUse or Stop. tool: Bash, Edit, Write, ...\n' >&2
    exit 1
fi
EVENT="$1"
TOOL="$2"

if [ ! -f "$CONFIG_FILE" ]; then
    printf 'hook_runner: config file not found: %s\n' "$CONFIG_FILE" >&2
    exit 1
fi

# Every hook reads the same payload, so stdin is saved once.
PAYLOAD="$(mktemp)"
ERRORS="$(mktemp)"
trap 'rm -f "$PAYLOAD" "$ERRORS"' EXIT
cat >"$PAYLOAD"

matches() { # matches <matcher>: does the tool match?
    [ "$1" = "*" ] && return 0
    case "|$1|" in
        *"|$TOOL|"*) return 0 ;;
    esac
    return 1
}

printf '%s--- Hook Runner (%s / %s) ---%s\n\n' "$BOLD" "$EVENT" "$TOOL" "$RESET"

MATCHED=0 PASSED=0 BLOCKED=0 WARNINGS=0 FINAL_EXIT=0

# The config is read into a list first, so the hooks' stdin is the payload and
# not the rest of the config file.
SCRIPTS=()
while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
        '#'* | '') continue ;;
    esac
    CONF_EVENT="${line%%:*}"
    rest="${line#*:}"
    CONF_MATCHER="${rest%%:*}"
    CONF_SCRIPT="${rest#*:}"
    [ "$CONF_EVENT" = "$EVENT" ] || continue
    matches "$CONF_MATCHER" || continue
    SCRIPTS+=("$CONF_SCRIPT")
done <"$CONFIG_FILE"

for script in ${SCRIPTS[@]+"${SCRIPTS[@]}"}; do
    MATCHED=$((MATCHED + 1))
    path="$script"
    case "$path" in
        ./*) path="$RUNNER_DIR/${path#./}" ;;
    esac
    printf '%s> Running:%s %s\n' "$CYAN" "$RESET" "$script"

    if [ ! -f "$path" ]; then
        printf '  %s! Not found%s\n\n' "$YELLOW" "$RESET"
        WARNINGS=$((WARNINGS + 1))
        continue
    fi

    bash "$path" <"$PAYLOAD" 2>"$ERRORS"
    code=$?
    message="$(cat "$ERRORS")"

    case "$code" in
        0)
            printf '  %sPassed%s\n' "$GREEN" "$RESET"
            [ -n "$message" ] && printf '  %s\n' "$message"
            PASSED=$((PASSED + 1))
            ;;
        2)
            printf '  %sBLOCKED%s\n' "$RED" "$RESET"
            [ -n "$message" ] && printf '  %s\n' "$message"
            BLOCKED=$((BLOCKED + 1))
            if [ "$EVENT" = "PreToolUse" ]; then
                FINAL_EXIT=2
                printf '  [chain stopped, the hook exited with 2]\n\n'
                break
            fi
            ;;
        *)
            printf '  %sWarning (exit %d)%s\n' "$YELLOW" "$code" "$RESET"
            [ -n "$message" ] && printf '  %s\n' "$message"
            WARNINGS=$((WARNINGS + 1))
            ;;
    esac
    printf '\n'
done

printf '%s--- Summary ---%s\n' "$BOLD" "$RESET"
printf 'Matched:  %d\n' "$MATCHED"
printf 'Passed:   %d\n' "$PASSED"
printf 'Blocked:  %d\n' "$BLOCKED"
printf 'Warnings: %d\n' "$WARNINGS"
exit "$FINAL_EXIT"
