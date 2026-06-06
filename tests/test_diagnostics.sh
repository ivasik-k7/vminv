#!/usr/bin/env bash
# Validates the visibility commands: config, doctor, demo, and non-interactive
# configure --set. Offline; uses a throwaway XDG config home.
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "${HERE}/.." && pwd)"
source "${HERE}/lib.sh"
VM="${ROOT}/vminv"
export XDG_CONFIG_HOME="$(mktemp -d)"
TMP="$(mktemp -d)"
trap 'rm -rf "$XDG_CONFIG_HOME" "$TMP"' EXIT
rc() { "$@" >/dev/null 2>&1; echo $?; }

echo "== configure --set (non-interactive) writes a profile =="
"$VM" configure lab --set VCENTER_HOST=vc.lab.local --set VCENTER_USER=svc-ro@vsphere.local --set TARGET_PROVIDER=azure >/dev/null 2>&1
assert_ok "profile file created" bash -c "test -f '${XDG_CONFIG_HOME}/vminv/profiles/lab.env'"
assert_fail "no password key in profile" grep -q VCENTER_PASSWORD "${XDG_CONFIG_HOME}/vminv/profiles/lab.env"

echo "== config shows resolved values (flag before subcommand) =="
out="$("$VM" --profile lab config 2>&1)"
assert_contains "$out" "vc.lab.local" "config shows host"
assert_contains "$out" "azure" "config shows target"
assert_contains "$out" "Password is never displayed" "config notes secret policy"
assert_eq "0" "$(rc "$VM" --profile lab config)" "config exits 0"

echo "== config never prints a password =="
"$VM" configure sec --set VCENTER_HOST=vc.sec >/dev/null 2>&1
VCENTER_PASSWORD='SUPERSECRET123' "$VM" --profile sec config > "$TMP/c.txt" 2>&1
assert_fail "password absent from config output" grep -q 'SUPERSECRET123' "$TMP/c.txt"

echo "== doctor =="
out="$("$VM" doctor 2>&1)"
assert_contains "$out" "vminv doctor" "doctor header"
assert_contains "$out" "Readiness" "doctor readiness section"
assert_eq "0" "$(rc "$VM" doctor)" "doctor exits 0"
# fully configured (host+user+password) -> ready verdict
assert_contains "$(VCENTER_PASSWORD=x "$VM" --profile lab doctor 2>&1)" "Ready." "configured lab + password -> Ready verdict"
# missing password -> doctor flags it as not ready
assert_contains "$("$VM" --profile lab doctor 2>&1)" "Not ready" "lab without password -> not ready"

echo "== demo runs a full scan with no credentials =="
assert_eq "0" "$(rc "$VM" demo --output "$TMP/demo")"  "demo exits 0"
run="$(ls -d "$TMP"/demo/*/ 2>/dev/null | head -1)"
assert_ok "demo produced vms.csv" bash -c "test -s '${run}vms.csv'"
assert_ok "demo produced summary.md" bash -c "test -s '${run}summary.md'"
assert_ok "demo produced blockers.csv" bash -c "test -s '${run}blockers.csv'"

echo "== unconfigured scan gives actionable guidance (not a cryptic error) =="
out="$(printf '' | "$VM" --config /nonexistent.env 2>&1)"
assert_contains "$out" "not configured" "scan without config explains it's unconfigured"
assert_contains "$out" "vminv demo" "guidance points to demo"

finish
