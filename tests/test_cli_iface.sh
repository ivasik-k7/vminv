#!/usr/bin/env bash
# Validates the CLI interface contract end-to-end by invoking the real `vminv`
# entrypoint: exit codes, per-command help, output modes, quiet/stream
# discipline, suggestions, and completion. Offline (fixtures).
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "${HERE}/.." && pwd)"
source "${HERE}/lib.sh"
VM="${ROOT}/vminv"
FIX="${HERE}/fixtures"
JQ="${ROOT}/bin/jq"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# run command, capture exit code only
rc() { "$@" >/dev/null 2>&1; echo $?; }

echo "== version / help =="
assert_eq "vminv $(grep -m1 '^VMINV_VERSION=' "$VM" | sed 's/.*"\(.*\)"/\1/')" "$("$VM" version)" "version prints vminv <semver>"
assert_eq "0" "$(rc "$VM" version)" "version exits 0"
assert_contains "$("$VM" scan --help)" "USAGE: vminv [scan]" "scan --help has usage"
assert_contains "$("$VM" schedule --help)" "add|list|remove|run" "schedule --help describes subcommands"
assert_contains "$("$VM" help upload)" "DEST schemes" "help <cmd> works"

echo "== exit codes =="
assert_eq "2" "$(rc "$VM" frobnicate)"                 "unknown command -> EX_USAGE(2)"
assert_eq "2" "$(rc "$VM" --format yaml --fixtures "$FIX")" "bad --format -> EX_USAGE(2)"
assert_eq "2" "$(rc "$VM" upload)"                     "upload with no dir -> EX_USAGE(2)"
assert_eq "2" "$(rc "$VM" --target nope --fixtures "$FIX" --output "$TMP/a")" "bad --target -> EX_USAGE(2)"
assert_eq "0" "$(rc "$VM" --fixtures "$FIX" --output "$TMP/b" --no-perf)" "clean fixture scan -> 0"

echo "== typo suggestion =="
assert_contains "$("$VM" sca 2>&1)" "Did you mean" "near-miss suggests a command"

echo "== output discipline (json mode: stdout is ONLY data) =="
"$VM" --fixtures "$FIX" --output "$TMP/c" --no-perf --format json --quiet >"$TMP/out.json" 2>"$TMP/err.txt"
assert_ok "stdout in json mode is valid JSON" "$JQ" -e . "$TMP/out.json"
assert_eq "/" "$("$JQ" -r '.run_dir|.[0:1]' "$TMP/out.json")" "json result carries run_dir"
assert_eq "false" "$("$JQ" -r '.partial' "$TMP/out.json")" "json result carries partial flag"
assert_eq "0" "$(wc -l <"$TMP/err.txt" | tr -d ' ')" "quiet mode -> no stderr on success"

echo "== color discipline =="
out="$("$VM" --fixtures "$FIX" --output "$TMP/d" --no-perf 2>&1)"
case "$out" in *$'\033'*) _fail "no ANSI escapes when stderr is not a TTY";; *) _pass "no ANSI escapes off-TTY";; esac

echo "== completion =="
assert_ok "bash completion is valid bash" bash -c "'$VM' completion bash | bash -n"
assert_eq "2" "$(rc "$VM" completion powershell)" "unsupported completion shell -> 2"

finish
