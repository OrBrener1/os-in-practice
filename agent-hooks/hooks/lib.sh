# Shared helpers for the hooks. Sourced by every hook, never run on its own.
# Needs bash 3.2 or newer (the version macOS ships) and jq.

HOOKS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_DIR="${HOOKS_CONFIG_DIR:-$HOOKS_ROOT/config}"
DATA_DIR="${HOOKS_DATA_DIR:-$HOOKS_ROOT/data}"
INPUT=""

if ! command -v jq >/dev/null 2>&1; then
    printf 'agent-hooks: jq is required but was not found\n' >&2
    exit 1
fi

# Reads the hook's JSON payload from stdin.
read_input() {
    INPUT="$(cat)"
}

input_is_json() {
    printf '%s' "$INPUT" | jq -e 'type == "object"' >/dev/null 2>&1
}

# A guard that cannot read its input must not let the action through.
require_json_or_block() {
    if ! input_is_json; then
        printf 'BLOCKED: hook input is not a JSON object\n' >&2
        exit 2
    fi
}

# json_get <jq path>: the value as text, or nothing when it is missing or null.
# jq decodes escapes, so a command with \" or \n inside is read whole.
json_get() {
    printf '%s' "$INPUT" | jq -r "($1) // empty | if type == \"string\" then . else tojson end" 2>/dev/null
}

# Session ids end up in file names and in a |-separated state file, so only a
# safe set of characters is kept.
session_id() {
    local raw
    raw="$(json_get .session_id)"
    raw="$(printf '%s' "$raw" | tr -c 'A-Za-z0-9._-' '_')"
    case "$raw" in
        '' | . | ..) raw="default" ;;
    esac
    printf '%s' "$raw"
}

# conf_int <KEY> <default> <minimum>: an integer from hooks.conf, or the default
# when the key is missing or the value is not a whole number at or above the minimum.
conf_int() {
    local key="$1" value="$2" min="$3" line
    if [ -f "$CONFIG_DIR/hooks.conf" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            case "$line" in
                "$key="*) value="${line#"$key="}" ;;
            esac
        done <"$CONFIG_DIR/hooks.conf"
    fi
    case "$value" in
        '' | *[!0-9]*) value="$2" ;;
    esac
    [ "$value" -ge "$min" ] 2>/dev/null || value="$2"
    printf '%s' "$value"
}

# Non-comment, non-empty lines of a config file.
config_lines() {
    [ -f "$1" ] || return 0
    grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$1" || true
}

# A lock made with mkdir, which is atomic on every POSIX system (flock is not on
# macOS). A lock older than about five seconds of waiting is treated as left behind
# by a killed hook and taken over.
lock_acquire() {
    local tries=0
    until mkdir "$1" 2>/dev/null; do
        tries=$((tries + 1))
        if [ "$tries" -ge 500 ]; then
            rmdir "$1" 2>/dev/null
            tries=0
        fi
        sleep 0.01
    done
}

lock_release() {
    rmdir "$1" 2>/dev/null
}

timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}
