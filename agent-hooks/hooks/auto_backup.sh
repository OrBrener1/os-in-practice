#!/bin/bash
# Saves a timestamped copy of a file and keeps the newest MAX_BACKUPS copies per file.
# Registered before Edit and Write, so the copy holds the content from before the
# change. Run after the edit, it would only save what the agent just wrote.
# Backups: data/.backups/<path with / as %>.<timestamp>. Log: data/session_<id>.log
# Exit 0 always: a backup problem is reported, but never stops the edit.

source "$(dirname "$0")/lib.sh"
read_input
input_is_json || exit 0

FILE_PATH="$(json_get .tool_input.file_path)"
SESSION_ID="$(session_id)"
[ -n "$FILE_PATH" ] && [ -f "$FILE_PATH" ] || exit 0

MAX_BACKUPS="$(conf_int MAX_BACKUPS 5 1)"
BACKUP_DIR="$DATA_DIR/.backups"
mkdir -p "$BACKUP_DIR"

# The whole path is part of the name, so src/main.c and tests/main.c keep separate
# backups and separate rotation.
KEY="$(printf '%s' "$FILE_PATH" | sed 's#^\./##; s#/#%#g')"
STAMP="$(date +%Y-%m-%d_%H%M%S)"
NAME="$KEY.$STAMP"
N=1
while [ -e "$BACKUP_DIR/$NAME" ]; do # two edits in the same second
    NAME="$KEY.$STAMP-$N"
    N=$((N + 1))
done

if ! cp -p "$FILE_PATH" "$BACKUP_DIR/$NAME"; then
    printf 'auto_backup: could not copy %s\n' "$FILE_PATH" >&2
    exit 0
fi

SIZE="$(wc -c <"$FILE_PATH" | tr -d ' ')"
printf '[%s] BACKUP %s -> .backups/%s (%s bytes)\n' "$(timestamp)" "$FILE_PATH" "$NAME" "$SIZE" \
    >>"$DATA_DIR/session_$SESSION_ID.log"

# Rotation. The names sort by time, and the pattern requires the timestamp right
# after the key, so backups of main.c.orig are not taken for backups of main.c.
ls -1 "$BACKUP_DIR" | grep -F -- "$KEY." | LC_ALL=C sort |
    awk -v key="$KEY." 'index($0, key) == 1 && substr($0, length(key) + 1) ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]_[0-9][0-9][0-9][0-9][0-9][0-9](-[0-9]+)?$/' |
    awk -v keep="$MAX_BACKUPS" '{ names[NR] = $0 } END { for (i = 1; i <= NR - keep; i++) print names[i] }' |
    while IFS= read -r old; do
        rm -f "$BACKUP_DIR/$old"
    done

exit 0
