#!/bin/bash
# When the session stops, turns data/session_<id>.log into a short report and
# prints it as {"systemMessage": "..."} for Claude Code to show.
# Exit 0 always.

source "$(dirname "$0")/lib.sh"
read_input
input_is_json || exit 0

# Claude Code sets stop_hook_active when it is already continuing because of a Stop
# hook. Doing anything then could start a loop.
[ "$(json_get .stop_hook_active)" = "true" ] && exit 0

SESSION_ID="$(session_id)"
LOG_FILE="$DATA_DIR/session_$SESSION_ID.log"

if [ ! -s "$LOG_FILE" ]; then
    printf 'No session activity recorded.\n'
    exit 0
fi

count() { grep -c -- "$1" "$LOG_FILE" || true; }

TOTAL="$(wc -l <"$LOG_FILE" | tr -d ' ')"
BACKUPS="$(count '] BACKUP ')"
SYNTAX_OK="$(count '] SYNTAX_OK ')"
SYNTAX_ERRORS="$(count '] SYNTAX_ERROR ')"
FIRST="$(sed -n '1s/^\[\([^]]*\)\].*/\1/p' "$LOG_FILE")"
LAST="$(sed -n '$s/^\[\([^]]*\)\].*/\1/p' "$LOG_FILE")"

# The file named on each line: before " -> " for backups, before " (" for checks.
files() {
    sed -n -e 's/^\[[^]]*\] BACKUP \(.*\) -> .*/\1/p' \
        -e 's/^\[[^]]*\] SYNTAX_[A-Z]* \(.*\) ([^)]*)$/\1/p' "$LOG_FILE"
}

REPORT="╔══════════════════════════════════════╗
║        SESSION SUMMARY REPORT        ║
╚══════════════════════════════════════╝

Session: $SESSION_ID
Period:  $FIRST -> $LAST

── Activity ─────────────────────────
  Total actions: $TOTAL
  Backups made: $BACKUPS
  Syntax checks: $((SYNTAX_OK + SYNTAX_ERRORS))
  Syntax errors: $SYNTAX_ERRORS"

MOST_EDITED="$(sed -n 's/^\[[^]]*\] BACKUP \(.*\) -> .*/\1/p' "$LOG_FILE" | sort | uniq -c | sort -k1,1nr -k2 | head -3)"
if [ -n "$MOST_EDITED" ]; then
    REPORT="$REPORT

── Most Edited Files ────────────────"
    INDEX=1
    while IFS= read -r line; do
        N="$(printf '%s' "$line" | awk '{print $1}')"
        FILE="$(printf '%s' "$line" | sed 's/^[[:space:]]*[0-9]*[[:space:]]//')"
        [ "$N" -eq 1 ] && WORD="edit" || WORD="edits"
        REPORT="$REPORT
  $INDEX. $FILE ($N $WORD)"
        INDEX=$((INDEX + 1))
    done <<EOF
$MOST_EDITED
EOF
fi

FILE_TYPES="$(files | awk -F/ '{print $NF}' | awk -F. 'NF > 1 {print $NF}' | sort | uniq -c)"
if [ -n "$FILE_TYPES" ]; then
    REPORT="$REPORT

── File Types ───────────────────────"
    while IFS= read -r line; do
        N="$(printf '%s' "$line" | awk '{print $1}')"
        EXT="$(printf '%s' "$line" | awk '{print $2}')"
        REPORT="$REPORT
  .$EXT files: $N"
    done <<EOF
$FILE_TYPES
EOF
fi

# jq does the JSON escaping, so quotes, backslashes and tabs in file names are safe.
jq -cn --arg message "$REPORT" '{systemMessage: $message}'
exit 0
