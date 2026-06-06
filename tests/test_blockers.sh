#!/usr/bin/env bash
# Validates migration blocker detection, severity, OS-matrix matching,
# and per-VM readiness status, against fixtures.
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "${HERE}/.." && pwd)"
source "${HERE}/lib.sh"
source "${ROOT}/lib/common.sh"
source "${ROOT}/lib/collect_infra.sh"
source "${ROOT}/lib/collect_vms.sh"
source "${ROOT}/lib/analyze_blockers.sh"

export VMINV_FIXTURES="${HERE}/fixtures"
OUT="$(mktemp -d)"; trap 'rm -rf "$OUT"' EXIT
THRESHOLD_LARGE_DISK_GB=2048; THRESHOLD_LARGE_VM_GB=8192
THRESHOLD_OLD_HW_VERSION=9; THRESHOLD_SNAPSHOT_AGE_DAYS=7

collect_infra "$OUT" >/dev/null 2>&1
collect_vms   "$OUT" >/dev/null 2>&1
analyze_blockers "$OUT" aws >/dev/null 2>&1

# does VM $1 have a blocker of code $2?
has() { "$JQ_BIN" -e --arg v "$1" --arg b "$2" 'any(.[]; .vm==$v and .blocker==$b)' "${OUT}/blockers.json" >/dev/null 2>&1 && echo yes || echo no; }
sev() { "$JQ_BIN" -r --arg b "$1" '.[]|select(.blocker==$b)|.severity' "${OUT}/blockers.json" | head -1; }
status() { "$JQ_BIN" -r --arg v "$1" '.[]|select(.name==$v)|.migration_status' "${OUT}/vms.json"; }

echo "== csv_to_json (matrix loader) =="
assert_eq "11" "$(csv_to_json <"${ROOT}/matrices/os_support.csv" | "$JQ_BIN" 'length')" "OS matrix parses to 11 rows"

echo "== high-severity blockers =="
assert_eq "yes" "$(has db-prod-01 rdm)"            "RDM flagged"
assert_eq "yes" "$(has db-prod-01 vtpm)"           "vTPM flagged"
assert_eq "yes" "$(has gpu-render-01 pci-passthrough)" "PCI passthrough flagged"
assert_eq "yes" "$(has gpu-render-01 vgpu)"        "vGPU flagged"
assert_eq "yes" "$(has gpu-render-01 vm-encryption)" "VM encryption flagged"
assert_eq "yes" "$(has legacy-app shared-multiwriter-disk)" "multi-writer disk flagged"
assert_eq "yes" "$(has legacy-app unsupported-os)" "unsupported OS (CentOS 6) flagged via matrix"
assert_eq "high" "$(sev rdm)" "RDM is high severity"

echo "== medium-severity blockers =="
assert_eq "yes" "$(has db-prod-01 stale-snapshot)" "stale snapshot (17d > 7d) flagged"
assert_eq "yes" "$(has legacy-app connected-iso)"  "connected ISO flagged"
assert_eq "yes" "$(has legacy-app old-hw-version)" "old hw version (vmx-7) flagged"
assert_eq "yes" "$(has legacy-app independent-disk)" "independent disk flagged"

echo "== no false positives on the clean VM =="
assert_eq "no" "$(has web-01 rdm)"        "web-01 has no RDM"
assert_eq "no" "$(has web-01 unsupported-os)" "Ubuntu is supported (no blocker)"

echo "== per-VM readiness =="
assert_eq "ready"   "$(status web-01)"        "clean VM -> ready"
assert_eq "blocked" "$(status db-prod-01)"    "RDM/vTPM VM -> blocked"
assert_eq "blocked" "$(status legacy-app)"    "multi-blocker VM -> blocked"
assert_eq "blocked" "$(status gpu-render-01)" "GPU/encrypted VM -> blocked"

echo "== summary counts =="
assert_eq "7" "$("$JQ_BIN" '.by_severity.high' "${OUT}/blockers_summary.json")" "7 high-severity findings"
assert_eq "5" "$("$JQ_BIN" '.by_severity.medium' "${OUT}/blockers_summary.json")" "5 medium-severity findings"

finish
