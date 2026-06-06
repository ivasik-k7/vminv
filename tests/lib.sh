#!/usr/bin/env bash
# Tiny assertion helpers for the vminv test suite. Sourced by test_*.sh.

TESTS_RUN=0
TESTS_FAIL=0

_pass() { TESTS_RUN=$((TESTS_RUN+1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
_fail() { TESTS_RUN=$((TESTS_RUN+1)); TESTS_FAIL=$((TESTS_FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }

assert_eq() { # assert_eq <expected> <actual> <desc>
  if [ "$1" = "$2" ]; then _pass "$3"; else _fail "$3 (expected '$1', got '$2')"; fi
}
assert_contains() { # assert_contains <haystack> <needle> <desc>
  case "$1" in *"$2"*) _pass "$3" ;; *) _fail "$3 (missing '$2')" ;; esac
}
assert_ok() { # assert_ok <desc> <cmd...>  (run in subshell; a callee `exit` won't kill the suite)
  local d="$1"; shift
  if ( "$@" ) >/dev/null 2>&1; then _pass "$d"; else _fail "$d (command failed: $*)"; fi
}
assert_fail() { # assert_fail <desc> <cmd...>  (expects NON-zero exit)
  local d="$1"; shift
  if ( "$@" ) >/dev/null 2>&1; then _fail "$d (expected failure, but succeeded)"; else _pass "$d"; fi
}

finish() {
  echo
  if [ "$TESTS_FAIL" -eq 0 ]; then
    printf '\033[32m%d passed, 0 failed\033[0m\n' "$TESTS_RUN"; exit 0
  else
    printf '\033[31m%d passed, %d FAILED\033[0m\n' "$((TESTS_RUN-TESTS_FAIL))" "$TESTS_FAIL"; exit 1
  fi
}
