#!/bin/bash
# After an edit, checks the file's syntax by its extension: .sh and .bash with
# bash -n, .py by parsing it with Python's ast module, .c and .h with the C
# compiler's -fsyntax-only. Other files are skipped.
# Exit 0 when the syntax is fine or there is no checker, exit 1 on a syntax error.

source "$(dirname "$0")/lib.sh"
read_input
input_is_json || exit 0

FILE_PATH="$(json_get .tool_input.file_path)"
SESSION_ID="$(session_id)"
[ -n "$FILE_PATH" ] && [ -f "$FILE_PATH" ] || exit 0

BASENAME="$(basename "$FILE_PATH")"
case "$BASENAME" in
    *.*) EXTENSION="$(printf '%s' "${BASENAME##*.}" | tr '[:upper:]' '[:lower:]')" ;;
    *) EXTENSION="" ;;
esac

have() { command -v "$1" >/dev/null 2>&1; }

case "$EXTENSION" in
    sh | bash)
        CHECKER="bash"
        ;;
    py)
        CHECKER="python3"
        ;;
    c | h)
        CHECKER="${CC:-cc}"
        ;;
    *)
        printf 'No syntax checker for .%s\n' "$EXTENSION" >&2
        exit 0
        ;;
esac

if ! have "$CHECKER"; then
    printf 'No %s found to check %s\n' "$CHECKER" "$FILE_PATH" >&2
    exit 0
fi

case "$EXTENSION" in
    sh | bash) OUTPUT="$(bash -n "$FILE_PATH" 2>&1)" ;;
    # py_compile would write a __pycache__ folder into the user's project; parsing does not.
    py) OUTPUT="$(python3 -c 'import ast, sys; ast.parse(open(sys.argv[1], "rb").read(), sys.argv[1])' "$FILE_PATH" 2>&1)" ;;
    c | h) OUTPUT="$("$CHECKER" -fsyntax-only -x c "$FILE_PATH" 2>&1)" ;;
esac
STATUS=$?

LOG_FILE="$DATA_DIR/session_$SESSION_ID.log"
mkdir -p "$DATA_DIR"

if [ "$STATUS" -ne 0 ]; then
    printf 'SYNTAX ERROR in %s: %s\n' "$FILE_PATH" "$OUTPUT" >&2
    printf '[%s] SYNTAX_ERROR %s (%s)\n' "$(timestamp)" "$FILE_PATH" "$EXTENSION" >>"$LOG_FILE"
    exit 1
fi

printf 'Syntax OK: %s\n' "$FILE_PATH"
printf '[%s] SYNTAX_OK %s (%s)\n' "$(timestamp)" "$FILE_PATH" "$EXTENSION" >>"$LOG_FILE"
exit 0
