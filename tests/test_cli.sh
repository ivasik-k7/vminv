#!/usr/bin/env bash
# Validates CLI plumbing offline: uploader dispatch, profile write/resolve,
# schedule cron-line generation, upgrade repo handling. No network, no vCenter.
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "${HERE}/.." && pwd)"
source "${HERE}/lib.sh"
source "${ROOT}/lib/common.sh"
source "${ROOT}/lib/upload.sh"
source "${ROOT}/lib/profile.sh"

export XDG_CONFIG_HOME="$(mktemp -d)"
TMP="$(mktemp -d)"
trap 'rm -rf "$XDG_CONFIG_HOME" "$TMP"' EXIT

echo "== uploader: local destination =="
mkdir -p "${TMP}/run"; echo hi >"${TMP}/run/a.txt"; echo '{}' >"${TMP}/run/inventory.json"
upload_run "${TMP}/run" "${TMP}/dest" >/dev/null 2>&1
assert_ok "tarball landed in local dest" bash -c "ls ${TMP}/dest/run.tar.gz"

echo "== uploader: unknown scheme rejected =="
assert_fail "rejects bogus scheme" upload_file "${TMP}/run/a.txt" "wat://nope"
assert_fail "empty dest rejected"  upload_file "${TMP}/run/a.txt" ""

echo "== profiles: write & resolve (no secrets) =="
PROFILE_VALUES=( [VCENTER_HOST]="vc.example" [VCENTER_USER]="svc@vsphere.local"
                 [TARGET_PROVIDER]="azure" [UPLOAD_DEST]="s3://bucket/x" [PASSWORD_SOURCE]="prompt" )
write_profile demo >/dev/null 2>&1
pf="$(vminv_profile_file demo)"
assert_ok "profile file created" bash -c "test -f '$pf'"
assert_fail "no password key written to profile" grep -q VCENTER_PASSWORD "$pf"
# load it back and confirm values
( set -a; source "$pf"; set +a; [ "$VCENTER_HOST" = "vc.example" ] && [ "$TARGET_PROVIDER" = "azure" ] ) \
  && _pass "profile values round-trip" || _fail "profile values round-trip"
assert_eq "600" "$(stat -c '%a' "$pf" 2>/dev/null || stat -f '%Lp' "$pf")" "profile is mode 600"

echo "== schedule: cron line generation (captured, not installed) =="
source "${ROOT}/lib/schedule.sh"
# stub crontab so nothing touches the real one
crontab() { if [ "${1:-}" = "-l" ]; then return 0; else cat >"${TMP}/cronout"; fi; }
SELF_DIR="$ROOT"; VMINV_ENTRY="${ROOT}/vminv"
schedule_add prod "0 2 * * *" >/dev/null 2>&1
line="$(cat "${TMP}/cronout" 2>/dev/null)"
assert_contains "$line" "0 2 * * *" "cron expression present"
assert_contains "$line" "schedule run --profile prod" "invokes schedule run for profile"
assert_contains "$line" "# vminv-schedule:prod" "tagged for safe list/remove"
assert_fail "rejects malformed cron (3 fields)" schedule_add prod "0 2 *"

echo "== presets: five of them =="
assert_eq "5" "${#CRON_PRESETS[@]}" "five cron presets provided"

echo "== upgrade: requires a repo =="
source "${ROOT}/lib/upgrade.sh"
VMINV_REPO=""; VMINV_VERSION="0.0.0"
assert_fail "upgrade without repo fails clearly" cmd_upgrade

finish
