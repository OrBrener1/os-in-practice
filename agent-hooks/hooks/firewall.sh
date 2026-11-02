#!/bin/bash
# Blocks Bash commands that match a pattern in config/dangerous_patterns.txt.
# Exit 0 lets the command run, exit 2 blocks it and the reason goes to stderr.

source "$(dirname "$0")/lib.sh"
read_input
require_json_or_block

[ "$(json_get .tool_name)" = "Bash" ] || exit 0
COMMAND="$(json_get .tool_input.command)"
PATTERNS="$CONFIG_DIR/dangerous_patterns.txt"

if [ ! -f "$PATTERNS" ]; then
    printf 'firewall: %s not found, nothing is checked\n' "$PATTERNS" >&2
    exit 0
fi

# The comment right above a pattern is used as the reason when it matches.
REASON=""
while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
        '#'*) REASON="$(printf '%s' "${line#\#}" | sed 's/^[[:space:]]*//')"; continue ;;
        '') REASON=""; continue ;;
    esac
    printf '%s\n' "$COMMAND" | grep -qE -- "$line" 2>/dev/null
    case $? in
        0)
            printf "BLOCKED: %s (pattern '%s'). Use a safer alternative.\n" "${REASON:-dangerous command}" "$line" >&2
            exit 2
            ;;
        2)
            printf "firewall: skipping invalid pattern '%s'\n" "$line" >&2
            ;;
    esac
done <"$PATTERNS"

exit 0
