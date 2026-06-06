#!/usr/bin/env bash
# Runs the whole vminv test suite (offline, fixture-based — no live vCenter).
#
#   ./tests/run_tests.sh
#
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

fail=0
for t in "${HERE}"/test_*.sh; do
  echo
  printf '\033[1m### %s\033[0m\n' "$(basename "$t")"
  bash "$t" || fail=1
done

echo
if [ "$fail" -eq 0 ]; then
  printf '\033[1;32mALL TEST FILES PASSED\033[0m\n'
else
  printf '\033[1;31mSOME TESTS FAILED\033[0m\n'
fi
exit "$fail"
