#!/bin/bash
# Checks for every hook and the runner, including the bypasses and races the hooks
# are hardened against. Each run uses its own temp folder for data and config.
# Run from the project folder: bash tests/run_tests.sh
cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"
H="$ROOT/hooks"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
export HOOKS_DATA_DIR="$T/data"
export HOOKS_CONFIG_DIR="$T/config"
cp -R "$ROOT/config" "$HOOKS_CONFIG_DIR"
FAILED=0

check() {  # check <description> <command...>
    local name="$1"; shift
    if "$@" >/dev/null 2>&1; then echo "  ok    $name"; else echo "  FAIL  $name"; FAILED=$((FAILED + 1)); fi
}

bash_json() {  # bash_json <command> [session]: a PreToolUse payload for the Bash tool
    jq -cn --arg c "$1" --arg s "${2:-test}" '{tool_name: "Bash", tool_input: {command: $c}, session_id: $s, cwd: env.PWD}'
}
edit_json() {  # edit_json <file> [session]
    jq -cn --arg f "$1" --arg s "${2:-test}" '{tool_name: "Edit", tool_input: {file_path: $f}, session_id: $s}'
}
run_hook() {  # run_hook <hook> <payload>: exit status of the hook
    printf '%s' "$2" | bash "$H/$1" >/dev/null 2>&1
}
exits() {  # exits <code> <hook> <payload>
    run_hook "$2" "$3"
    [ "$?" -eq "$1" ]
}
says() {  # says <text> <hook> <payload>: stdout or stderr contains the text
    local out
    out="$(printf '%s' "$3" | bash "$H/$2" 2>&1)"
    [[ "$out" == *"$1"* ]]
}
blocked_by() {  # blocked_by <hook> <payload>: exit 2 and a BLOCKED reason (a bash syntax error also exits 2)
    local out
    out="$(printf '%s' "$2" | bash "$H/$1" 2>&1 >/dev/null)"
    [ "$?" -eq 2 ] && [[ "$out" == *"BLOCKED: "* ]]
}
blocks() { blocked_by firewall.sh "$(bash_json "$1")"; }
allows() { exits 0 firewall.sh "$(bash_json "$1")"; }
set_conf() {  # set_conf <content of hooks.conf>
    printf '%s\n' "$1" >"$HOOKS_CONFIG_DIR/hooks.conf"
}

echo "Firewall: blocked"
for cmd in 'rm -rf /tmp/x' 'rm -fr /tmp/x' 'rm -r -f /tmp/x' 'rm -R build' 'rm --recursive build' \
    '/bin/rm -rf /tmp/x' 'sudo rm -rf /' 'rm  -rf   /tmp/x' 'echo "hi" && rm -rf /tmp/x' \
    'ls; rm -rf ~' 'git reset --hard HEAD~3' 'git push --force' 'git push origin main -f' 'git push -uf origin main' \
    'git -C repo push --force-with-lease' 'mkfs.ext4 /dev/sdb1' 'dd if=/dev/zero of=/dev/sda' 'echo x > /dev/sda' \
    ':(){ :|:& };:' 'chmod -R 777 .' 'chmod 777 secrets.txt'; do
    check "$cmd"   blocks "$cmd"
done
check "a second line of the command"          blocks "$(printf 'echo start\nrm -rf /tmp/x')"
check "JSON with spaces after the colons"     blocked_by firewall.sh '{"tool_name": "Bash", "tool_input": {"command": "rm -rf /tmp/x"}}'

echo "Firewall: allowed"
for cmd in 'ls -la' 'rm notes.txt' 'rm -f build.log' 'npm run format -- -r' 'grep -rf patterns.txt src' \
    'git push origin main' 'git push origin feature-fix' 'git push --follow-tags' 'git reset --soft HEAD~1' \
    'dd if=disk.img of=copy.img' 'chmod 755 run.sh' 'cat /dev/null'; do
    check "$cmd"   allows "$cmd"
done
check "a tool other than Bash passes"         exits 0 firewall.sh "$(edit_json main.c)"
check "input that is not JSON is blocked"     blocked_by firewall.sh 'not json'
printf '(unclosed\nrm -rf\n' >"$T/bad_patterns.txt"
cp "$HOOKS_CONFIG_DIR/dangerous_patterns.txt" "$T/patterns.bak"
cp "$T/bad_patterns.txt" "$HOOKS_CONFIG_DIR/dangerous_patterns.txt"
check "an invalid pattern is reported"        says "skipping invalid pattern" firewall.sh "$(bash_json 'ls')"
check "patterns after an invalid one still work"  blocks 'rm -rf /tmp/x'
cp "$T/patterns.bak" "$HOOKS_CONFIG_DIR/dangerous_patterns.txt"

echo "Rate limiter"
state_line() { grep "^$1|" "$HOOKS_DATA_DIR/.command_count"; }
set_conf $'MAX_COMMANDS=3\nWARNING_THRESHOLD=2'
check "first command passes"                  exits 0 rate_limiter.sh "$(bash_json 'git status' rl)"
check "warning at the threshold"              says "approaching the command limit (2/3)" rate_limiter.sh "$(bash_json 'ls' rl)"
check "still allowed at the limit"            exits 0 rate_limiter.sh "$(bash_json 'git log' rl)"
check "blocked past the limit"                blocked_by rate_limiter.sh "$(bash_json 'git diff' rl)"
check "state line has total and breakdown"    test "$(state_line rl)" = "rl|4|git:3,ls:1"
check "another session has its own count"     exits 0 rate_limiter.sh "$(bash_json 'ls' other)"
touch "$HOOKS_DATA_DIR/.reset_commands"
check "the reset file starts the count again" exits 0 rate_limiter.sh "$(bash_json 'make' rl)"
check "after the reset the total is 1"        test "$(state_line rl)" = "rl|1|make:1"
check "the reset file is removed"             test ! -e "$HOOKS_DATA_DIR/.reset_commands"
run_hook rate_limiter.sh "$(bash_json 'ls' 'a|b')"
check "a | in the session id is replaced"     test "$(state_line 'a_b')" = "a_b|1|ls:1"
run_hook rate_limiter.sh "$(bash_json 'x:y,z|w arg' sep)"
check "separators in the command type are replaced"  test "$(state_line sep)" = "sep|1|x_y_z_w:1"
set_conf $'MAX_COMMANDS=lots\nWARNING_THRESHOLD=-1'
check "bad numbers in hooks.conf fall back to defaults"  exits 0 rate_limiter.sh "$(bash_json 'ls' defaults)"
parallel_count() {
    local i
    set_conf $'MAX_COMMANDS=1000\nWARNING_THRESHOLD=1000'
    for i in $(seq 1 40); do run_hook rate_limiter.sh "$(bash_json 'ls' par)" & done
    wait
    test "$(state_line par)" = "par|40|ls:40"
}
check "40 hooks at once count to exactly 40"  parallel_count
check "no lock or temp file left behind"      test "$(ls -A "$HOOKS_DATA_DIR" | grep -v -e '^\.command_count$' | grep -c -v '^session_')" = 0

echo "Commit validator"
c_ok() { exits 0 commit_validator.sh "$(bash_json "$1")"; }
c_blocks() { blocked_by commit_validator.sh "$(bash_json "$1")"; }
check "valid message"                         c_ok 'git commit -m "feat: add the session summary"'
check "single quotes"                         c_ok "git commit -m 'fix: handle an empty payload'"
check "-am"                                   c_ok 'git commit -am "docs: explain the runner"'
check "--message="                            c_ok 'git commit --message="test: cover the reset file"'
check "scope and !"                           c_ok 'git commit -m "feat(runner)!: change the exit codes"'
check "escaped quotes inside the message"     c_ok 'git commit -m "fix: quote \"$FILE\" in backups"'
check "after cd ... &&"                       c_ok 'cd repo && git commit -m "chore: bump the version"'
check "not a commit: echo"                    c_ok 'echo git commit -m bad'
check "no -m opens the editor, allowed"       c_ok 'git commit'
check "missing prefix"                        c_blocks 'git commit -m "add the session summary"'
check "unknown prefix"                        c_blocks 'git commit -m "feature: add the session summary"'
check "too short"                             c_blocks 'git commit -m "fix: a"'
check "too long"                              c_blocks "git commit -m \"feat: $(printf 'x%.0s' $(seq 1 70))\""
check "full stop at the end"                  c_blocks 'git commit -m "fix: handle an empty payload."'
check "message built with \$(cat <<EOF)"       says "command substitution" commit_validator.sh \
    "$(bash_json "$(printf 'git commit -m "$(cat <<EOF\nfeat: add x\nEOF\n)"')")"
printf 'feat\nfix\nperf\n' >"$HOOKS_CONFIG_DIR/commit_prefixes.txt"
check "prefixes come from the config"         c_ok 'git commit -m "perf: cache the patterns"'
check "the block lists the configured prefixes"  says "Valid prefixes: feat, fix, perf" commit_validator.sh "$(bash_json 'git commit -m "x y z w v u"')"
cp "$ROOT/config/commit_prefixes.txt" "$HOOKS_CONFIG_DIR/commit_prefixes.txt"
suggestion_in_repo() {  # the suggestion reads the staged changes of the repo in "cwd"
    local repo="$T/repo" payload
    mkdir -p "$repo" && git -C "$repo" init -q && printf 'x\n' >"$repo/test_parser.py" && git -C "$repo" add test_parser.py
    payload="$(jq -cn --arg d "$repo" '{tool_name: "Bash", tool_input: {command: "git commit -m \"cover the parser\""}, cwd: $d}')"
    says "try: 'test: cover the parser'" commit_validator.sh "$payload"
}
check "suggests test: for staged test files"  suggestion_in_repo

echo "Auto backup"
P="$T/project"
mkdir -p "$P/src" "$P/tests"
printf 'int main(void) { return 0; }\n' >"$P/src/main.c"
printf 'void t(void) {}\n' >"$P/tests/main.c"
B="$HOOKS_DATA_DIR/.backups"
backups_of() { ls -1 "$B" 2>/dev/null | grep -cF "$(printf '%s' "$1" | sed 's#/#%#g')."; }
set_conf 'MAX_BACKUPS=3'
check "a backup is made"                      exits 0 auto_backup.sh "$(edit_json "$P/src/main.c" bk)"
check "the backup has the file's content"     cmp -s "$P/src/main.c" "$B/$(ls -1 "$B" | head -1)"
check "the log has a BACKUP line"             grep -q "\] BACKUP $P/src/main.c -> .backups/" "$HOOKS_DATA_DIR/session_bk.log"
run_hook auto_backup.sh "$(edit_json "$P/src/main.c" bk)"
check "two backups in the same second are both kept"  test "$(backups_of "$P/src/main.c")" = 2
run_hook auto_backup.sh "$(edit_json "$P/tests/main.c" bk)"
check "same file name in another folder is separate"  test "$(backups_of "$P/tests/main.c")" = 1
printf 'orig\n' >"$P/src/main.c.orig"
run_hook auto_backup.sh "$(edit_json "$P/src/main.c.orig" bk)"
for _ in 1 2 3 4; do run_hook auto_backup.sh "$(edit_json "$P/src/main.c" bk)"; done
check "rotation keeps MAX_BACKUPS copies"     test "$(ls -1 "$B" | grep -c "src%main\.c\.[0-9]")" = 3
check "rotation leaves main.c.orig alone"     test "$(ls -1 "$B" | grep -c "src%main\.c\.orig\.")" = 1
check "a missing file is skipped"             exits 0 auto_backup.sh "$(edit_json "$P/nope.c" bk)"
check "input that is not JSON is skipped"     exits 0 auto_backup.sh 'not json'

echo "Syntax checker"
printf 'echo ok\n' >"$P/good.sh";            printf 'if then fi\n' >"$P/bad.sh"
printf 'print("ok")\n' >"$P/good.py";        printf 'def f(:\n' >"$P/bad.py"
printf 'int f(void) { return 1; }\n' >"$P/good.c"; printf 'int f(void) { return 1 }\n' >"$P/bad.c"
printf 'hello\n' >"$P/notes.txt"
for f in good.sh good.py good.c; do check "$f is OK"   exits 0 syntax_checker.sh "$(edit_json "$P/$f" sx)"; done
for f in bad.sh bad.py bad.c; do check "$f is an error (exit 1)"   exits 1 syntax_checker.sh "$(edit_json "$P/$f" sx)"; done
check "no __pycache__ written into the project"  test ! -e "$P/__pycache__"
check "other extensions are skipped"          exits 0 syntax_checker.sh "$(edit_json "$P/notes.txt" sx)"
check "the log has 3 OK and 3 errors"         test "$(grep -c SYNTAX_OK "$HOOKS_DATA_DIR/session_sx.log")$(grep -c SYNTAX_ERROR "$HOOKS_DATA_DIR/session_sx.log")" = 33

echo "Session summary"
cat >"$HOOKS_DATA_DIR/session_sum.log" <<'EOF'
[2026-05-01 10:00:00] BACKUP app/server.py -> .backups/app%server.py.2026-05-01_100000 (900 bytes)
[2026-05-01 10:00:01] SYNTAX_OK app/server.py (py)
[2026-05-01 10:02:00] BACKUP app/server.py -> .backups/app%server.py.2026-05-01_100200 (950 bytes)
[2026-05-01 10:03:00] BACKUP lib/v1.2/util.h -> .backups/lib%v1.2%util.h.2026-05-01_100300 (80 bytes)
[2026-05-01 10:03:01] SYNTAX_ERROR lib/v1.2/util.h (h)
EOF
summary() { printf '{"session_id":"%s","stop_hook_active":%s}' "$1" "${2:-false}" | bash "$H/session_summary.sh"; }
report() { summary sum | jq -r .systemMessage; }
check "output is JSON with a systemMessage"   bash -c "$(declare -f summary); H='$H'; summary sum | jq -e '.systemMessage | type == \"string\"'"
check "counts"                                bash -c "$(declare -f summary report); H='$H'; report | grep -q 'Total actions: 5' && report | grep -q 'Backups made: 3' && report | grep -q 'Syntax checks: 2' && report | grep -q 'Syntax errors: 1'"
check "period"                                bash -c "$(declare -f summary report); H='$H'; report | grep -q 'Period:  2026-05-01 10:00:00 -> 2026-05-01 10:03:01'"
check "most edited first"                     bash -c "$(declare -f summary report); H='$H'; report | grep -q '1. app/server.py (2 edits)' && report | grep -q '2. lib/v1.2/util.h (1 edit)'"
check "file types from the name, not the folder"  bash -c "$(declare -f summary report); H='$H'; report | grep -q '.py files: 3' && report | grep -q '.h files: 2'"
printf '[2026-05-01 10:00:00] BACKUP say "hi"\there.c -> .backups/x (1 bytes)\n' >"$HOOKS_DATA_DIR/session_odd.log"
check "quotes and tabs in names stay valid JSON"  bash -c "$(declare -f summary); H='$H'; summary odd | jq -e .systemMessage"
check "no log: says so"                       bash -c "$(declare -f summary); H='$H'; [ \"\$(summary none)\" = 'No session activity recorded.' ]"
check "stop_hook_active: no output at all"    bash -c "$(declare -f summary); H='$H'; [ -z \"\$(summary sum true)\" ]"

echo "Runner"
mkdir -p "$T/fake"
printf 'exit 0\n' >"$T/fake/pass.sh"
printf 'echo careful >&2; exit 1\n' >"$T/fake/warn.sh"
printf 'echo no >&2; exit 2\n' >"$T/fake/block.sh"
printf 'touch "%s/after"\n' "$T" >"$T/fake/after.sh"
printf 'cat > "%s/seen"\n' "$T" >"$T/fake/stdin.sh"
cat >"$T/hooks.txt" <<EOF
# comment
PreToolUse:Bash:$T/fake/pass.sh
PreToolUse:Bash:$T/fake/warn.sh
PreToolUse:Bash:$T/fake/block.sh
PreToolUse:Bash:$T/fake/after.sh
PostToolUse:Edit|Write:$T/fake/block.sh
PostToolUse:Edit|Write:$T/fake/after.sh
Stop:*:$T/fake/stdin.sh
PreToolUse:Read:$T/fake/missing.sh
EOF
runner() { printf '%s' "${3:-{\}}" | HOOK_RUNNER_CONFIG="$T/hooks.txt" "$ROOT/hook_runner.sh" "$1" "$2"; }
runner PreToolUse Bash >"$T/out.txt" 2>&1; code=$?
check "a PreToolUse block exits 2"            test "$code" = 2
check "the chain stops at the block"          test ! -e "$T/after"
check "the warning and its message are shown" grep -q "careful" "$T/out.txt"
check "the summary counts 3 matched"          grep -q "Matched:  3" "$T/out.txt"
runner PostToolUse Write >"$T/out.txt" 2>&1; code=$?
check "a PostToolUse exit 2 does not block"   test "$code" = 0
check "and does not stop the chain"           test -e "$T/after"
check "| in the matcher"                      grep -q "Matched:  2" "$T/out.txt"
runner Stop Anything '{"session_id":"s"}' >/dev/null 2>&1
check "* matches any tool, hooks get the payload"  test "$(cat "$T/seen")" = '{"session_id":"s"}'
check "a missing script is a warning"         bash -c "$(declare -f runner); T='$T'; ROOT='$ROOT'; runner PreToolUse Read | grep -q 'Not found'"
check "no hook for the tool: exit 0"          bash -c "$(declare -f runner); T='$T'; ROOT='$ROOT'; runner PreToolUse Glob >/dev/null"
check "wrong arguments print usage"           bash -c "'$ROOT/hook_runner.sh' PreToolUse 2>&1 </dev/null | grep -q Usage"
check "no colour codes when not a terminal"   bash -c "! grep -q \$'\\033' '$T/out.txt'"

echo "The real hooks through the runner"
printf 'old\n' >"$P/edit_me.py"
edit_json "$P/edit_me.py" e2e | HOOK_RUNNER_CONFIG="$ROOT/hooks.txt" "$ROOT/hook_runner.sh" PreToolUse Edit >/dev/null 2>&1
printf 'new = (\n' >"$P/edit_me.py"
edit_json "$P/edit_me.py" e2e | HOOK_RUNNER_CONFIG="$ROOT/hooks.txt" "$ROOT/hook_runner.sh" PostToolUse Edit >"$T/out.txt" 2>&1
check "the backup holds the content from before the edit"  grep -qx old "$B/$(ls -1 "$B" | grep 'edit_me\.py\.' | head -1)"
check "the syntax error after the edit is reported"  grep -q "SYNTAX ERROR" "$T/out.txt"
check "a dangerous command is blocked end to end" bash -c "jq -cn '{tool_name:\"Bash\",tool_input:{command:\"rm -rf /\"}}' | HOOK_RUNNER_CONFIG='$ROOT/hooks.txt' '$ROOT/hook_runner.sh' PreToolUse Bash >/dev/null; [ \$? = 2 ]"

echo
if [ "$FAILED" -eq 0 ]; then echo "All checks passed."; else echo "$FAILED check(s) failed."; exit 1; fi
