#!/bin/bash
# Counts commands per session and blocks once a session passes MAX_COMMANDS.
# State: data/.command_count, one line per session: session_id|total|type:N,type:N,...
# Exit 0 allows (with a warning past WARNING_THRESHOLD), exit 2 blocks.

source "$(dirname "$0")/lib.sh"
read_input
require_json_or_block

SESSION_ID="$(session_id)"
COMMAND="$(json_get .tool_input.command)"
MAX_COMMANDS="$(conf_int MAX_COMMANDS 50 1)"
WARNING_THRESHOLD="$(conf_int WARNING_THRESHOLD 40 0)"

STATE_FILE="$DATA_DIR/.command_count"
RESET_FILE="$DATA_DIR/.reset_commands"
LOCK="$DATA_DIR/.command_count.lock"

# The first word is the command type. ':', ',' and '|' would break the state format.
CMD_TYPE="$(printf '%s\n' "$COMMAND" | awk 'NR == 1 {print $1}' | tr ':,|' '___')"
[ -n "$CMD_TYPE" ] || CMD_TYPE="unknown"

mkdir -p "$DATA_DIR"

# Two hook processes can run at once (two sessions in one project, for example),
# and this is a read-modify-write of one file, so the whole update holds a lock.
lock_acquire "$LOCK"
trap 'lock_release "$LOCK"' EXIT
touch "$STATE_FILE"

if [ -f "$RESET_FILE" ]; then
    rm -f "$RESET_FILE"
    RESET=1
else
    RESET=0
fi

SESSION_LINE=""
[ "$RESET" -eq 1 ] || SESSION_LINE="$(awk -F'|' -v sid="$SESSION_ID" '$1 == sid {print; exit}' "$STATE_FILE")"

TOTAL_COUNT=0
BREAKDOWN=""
if [ -n "$SESSION_LINE" ]; then
    TOTAL_COUNT="$(printf '%s' "$SESSION_LINE" | cut -d'|' -f2)"
    BREAKDOWN="$(printf '%s' "$SESSION_LINE" | cut -d'|' -f3)"
    case "$TOTAL_COUNT" in '' | *[!0-9]*) TOTAL_COUNT=0 ;; esac
fi
TOTAL_COUNT=$((TOTAL_COUNT + 1))

NEW_BREAKDOWN=""
FOUND_TYPE=0
OLD_IFS="$IFS"
IFS=','
for pair in $BREAKDOWN; do
    TYPE="${pair%%:*}"
    COUNT="${pair#*:}"
    case "$COUNT" in '' | *[!0-9]*) COUNT=0 ;; esac
    if [ "$TYPE" = "$CMD_TYPE" ]; then
        COUNT=$((COUNT + 1))
        FOUND_TYPE=1
    fi
    NEW_BREAKDOWN="${NEW_BREAKDOWN:+$NEW_BREAKDOWN,}$TYPE:$COUNT"
done
IFS="$OLD_IFS"
[ "$FOUND_TYPE" -eq 1 ] || NEW_BREAKDOWN="${NEW_BREAKDOWN:+$NEW_BREAKDOWN,}$CMD_TYPE:1"

# Write a new file next to the old one and rename it over, so a reader never
# sees a half-written state file.
TMP_FILE="$(mktemp "$DATA_DIR/.command_count.XXXXXX")"
awk -F'|' -v sid="$SESSION_ID" '$1 != sid' "$STATE_FILE" >"$TMP_FILE"
printf '%s|%s|%s\n' "$SESSION_ID" "$TOTAL_COUNT" "$NEW_BREAKDOWN" >>"$TMP_FILE"
mv "$TMP_FILE" "$STATE_FILE"

lock_release "$LOCK"
trap - EXIT

if [ "$TOTAL_COUNT" -gt "$MAX_COMMANDS" ]; then
    printf "BLOCKED: session '%s' exceeded the command limit (%s > %s). Breakdown: %s\n" \
        "$SESSION_ID" "$TOTAL_COUNT" "$MAX_COMMANDS" "$NEW_BREAKDOWN" >&2
    exit 2
fi

if [ "$TOTAL_COUNT" -ge "$WARNING_THRESHOLD" ]; then
    printf "WARNING: session '%s' is approaching the command limit (%s/%s). Breakdown: %s\n" \
        "$SESSION_ID" "$TOTAL_COUNT" "$MAX_COMMANDS" "$NEW_BREAKDOWN" >&2
fi

exit 0
