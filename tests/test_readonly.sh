#!/usr/bin/env bash
# Verifies the read-only safety guarantee at two levels:
#   1. Runtime: the govc wrapper refuses non-allowlisted verbs.
#   2. Static : no mutating govc verb appears anywhere in the code, and the
#               govc binary is only ever invoked from the single wrapper.
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "${HERE}/.." && pwd)"
source "${HERE}/lib.sh"
source "${ROOT}/lib/common.sh"

echo "== read-only guard (runtime) =="
assert_ok   "allows read verb: about"          _govc_verb_allowed about
assert_ok   "allows read verb: object.collect" _govc_verb_allowed object.collect
assert_ok   "allows read verb: vm.info"        _govc_verb_allowed vm.info
assert_ok   "allows read verb: metric.sample"  _govc_verb_allowed metric.sample
assert_fail "refuses vm.destroy"               _govc_verb_allowed vm.destroy
assert_fail "refuses vm.power"                  _govc_verb_allowed vm.power
assert_fail "refuses snapshot.create"          _govc_verb_allowed snapshot.create
assert_fail "refuses vm.create"                _govc_verb_allowed vm.create
assert_fail "refuses import.ova"               _govc_verb_allowed import.ova

# govc_ro must reject a mutating verb before any execution.
assert_fail "govc_ro refuses vm.destroy" govc_ro vm.destroy x

echo "== read-only guard (static analysis of code) =="
CODE_FILES=$(find "${ROOT}/lib" -name '*.sh'; echo "${ROOT}/vminv")

# (a) The govc binary must be invoked ONLY inside the wrapper (common.sh).
# The binary is always referenced as "$GOVC_BIN", so that signature is the
# authoritative check (display strings mentioning "govc" are not invocations).
offenders=""
for f in $CODE_FILES; do
  case "$f" in */common.sh) continue ;; esac
  if grep -nE '"\$GOVC_BIN"' "$f" 2>/dev/null | grep -vE '^\s*[0-9]+:\s*#' >/dev/null; then
    offenders="${offenders} $(basename "$f")"
  fi
done
assert_eq "" "$offenders" "govc binary (\$GOVC_BIN) referenced only in common.sh"

# (b) No mutating govc verb token anywhere in non-comment code lines.
MUTATING='vm\.create|vm\.destroy|vm\.power|vm\.clone|vm\.migrate|vm\.markas|vm\.register|vm\.unregister|vm\.disk\.create|snapshot\.(create|remove|revert)|host\.(maintenance|disconnect|reconnect)|datastore\.(rm|mkdir|upload|mv|cp)|object\.(destroy|rename|mv)|import\.(ova|ovf|vmdk)|\.power(\.|[[:space:]])|guest\.(rm|mkdir|upload|run|start)'
hits=""
for f in $CODE_FILES; do
  # strip comment-only lines, then search
  if grep -vE '^\s*#' "$f" | grep -nE "$MUTATING" >/dev/null 2>&1; then
    hits="${hits} $(basename "$f")"
  fi
done
assert_eq "" "$hits" "no mutating govc verbs in code"

finish
