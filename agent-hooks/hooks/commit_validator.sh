#!/bin/bash
# Checks git commit messages before the commit runs: a prefix from
# config/commit_prefixes.txt (conventional commits, scope and ! allowed), a length
# of 10 to 72 characters, and no full stop at the end. A missing prefix gets a
# suggestion based on the staged changes.
# Exit 0 allows, exit 2 blocks.

source "$(dirname "$0")/lib.sh"
read_input
require_json_or_block

COMMAND="$(json_get .tool_input.command)"
CWD="$(json_get .cwd)"
[ -n "$CWD" ] && [ -d "$CWD" ] || CWD="."

# Only a git commit at the start of a command or after ; && || | counts, so
# "echo git commit -m x" is not treated as a commit.
COMMIT_RE='(^|[;&|][[:space:]]*)git([[:space:]]+-C[[:space:]]+[^[:space:]]+)?[[:space:]]+commit([[:space:]]|$)'
printf '%s\n' "$COMMAND" | grep -qE "$COMMIT_RE" || exit 0

# No -m or --message means git opens an editor, and there is nothing to check here.
if ! printf '%s\n' "$COMMAND" | grep -qE '([[:space:]]-[[:alpha:]]*m([[:space:]]|$|["'"'"'])|[[:space:]]--message([[:space:]]|=))'; then
    exit 0
fi

# The message (the last one when -m is given more than once). Double quotes may
# hold escaped quotes: "feat: say \"hi\"".
FLAG='[[:space:]](-[[:alpha:]]*m[[:space:]]*|--message[[:space:]]*=?[[:space:]]*)'
COMMIT_MSG="$(printf '%s\n' "$COMMAND" | sed -nE "s/.*${FLAG}'([^']*)'.*/\\2/p" | head -1)"
if [ -z "$COMMIT_MSG" ]; then
    COMMIT_MSG="$(printf '%s\n' "$COMMAND" | sed -nE "s/.*${FLAG}\"(([^\"\\\\]|\\\\.)*)\".*/\\2/p" | head -1 |
        sed -e 's/\\"/"/g' -e 's/\\\\/\\/g')"
fi

case "$COMMIT_MSG" in
    *'$('* | *'`'*)
        printf 'BLOCKED: the commit message is built by a command substitution and cannot be checked. Pass it directly with -m.\n' >&2
        exit 2
        ;;
    '')
        # For example -m "$(cat <<'EOF' ... EOF)", spread over several lines.
        case "$COMMAND" in
            *'$('* | *'`'*)
                printf 'BLOCKED: the commit message is built by a command substitution and cannot be checked. Pass it directly with -m.\n' >&2
                ;;
            *)
                printf 'BLOCKED: could not read the commit message from the git commit command.\n' >&2
                ;;
        esac
        exit 2
        ;;
esac

PREFIXES="$(config_lines "$CONFIG_DIR/commit_prefixes.txt" | sed 's/[[:space:]]//g' | grep -v '^$' || true)"
[ -n "$PREFIXES" ] || PREFIXES="$(printf '%s\n' feat fix docs refactor test chore)"
VALID_LIST="$(printf '%s\n' "$PREFIXES" | paste -sd ',' - | sed 's/,/, /g')"

is_prefix() {
    printf '%s\n' "$PREFIXES" | grep -qxF -- "$1"
}

# "type: ", "type(scope): " or "type!: ", compared as plain text, not as a regex.
HEAD="${COMMIT_MSG%%: *}"
TYPE="${HEAD%%(*}"
TYPE="${TYPE%!}"
if [ "$HEAD" = "$COMMIT_MSG" ] || ! is_prefix "$TYPE" ||
    ! printf '%s\n' "${HEAD#"$TYPE"}" | grep -qE '^(\([^()[:space:]]+\))?!?$'; then
    STAT="$(git -C "$CWD" diff --cached --stat 2>/dev/null)"
    NAMES="$(git -C "$CWD" diff --cached --name-status 2>/dev/null)"
    SUGGESTED="feat"
    if printf '%s\n' "$NAMES" | grep -qiE 'test|spec'; then
        SUGGESTED="test"
    elif printf '%s\n' "$NAMES" | grep -qiE 'readme|\.md$'; then
        SUGGESTED="docs"
    elif ! printf '%s\n' "$NAMES" | grep -q '^A'; then
        INSERTIONS="$(printf '%s\n' "$STAT" | grep -oE '[0-9]+ insertion' | grep -oE '[0-9]+' || true)"
        DELETIONS="$(printf '%s\n' "$STAT" | grep -oE '[0-9]+ deletion' | grep -oE '[0-9]+' || true)"
        [ "${DELETIONS:-0}" -gt "${INSERTIONS:-0}" ] && SUGGESTED="refactor"
    fi
    is_prefix "$SUGGESTED" || SUGGESTED="$(printf '%s\n' "$PREFIXES" | head -1)"
    printf "BLOCKED: missing or unknown commit prefix. Based on the staged changes, try: '%s: %s'. Valid prefixes: %s\n" \
        "$SUGGESTED" "$COMMIT_MSG" "$VALID_LIST" >&2
    exit 2
fi

LENGTH=${#COMMIT_MSG}
if [ "$LENGTH" -lt 10 ] || [ "$LENGTH" -gt 72 ]; then
    printf 'BLOCKED: the commit message has %d characters, it must have 10 to 72.\n' "$LENGTH" >&2
    exit 2
fi

case "$COMMIT_MSG" in
    *.)
        printf 'BLOCKED: the commit message must not end with a full stop.\n' >&2
        exit 2
        ;;
esac

exit 0
