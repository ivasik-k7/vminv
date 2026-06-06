#!/usr/bin/env bash
# Validates right-sizing (p95 vs configured), licensing flags, and the
# summary.md/html report, against fixtures.
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "${HERE}/.." && pwd)"
source "${HERE}/lib.sh"
source "${ROOT}/lib/common.sh"
source "${ROOT}/lib/collect_infra.sh"
source "${ROOT}/lib/collect_vms.sh"
source "${ROOT}/lib/collect_perf.sh"
source "${ROOT}/lib/analyze_blockers.sh"
source "${ROOT}/lib/rightsize.sh"
source "${ROOT}/lib/report.sh"

export VMINV_FIXTURES="${HERE}/fixtures"
OUT="$(mktemp -d)"; trap 'rm -rf "$OUT"' EXIT
PERF_WINDOW_DAYS=30; PERF_INTERVAL=daily
THRESHOLD_LARGE_DISK_GB=2048; THRESHOLD_LARGE_VM_GB=8192
THRESHOLD_OLD_HW_VERSION=9; THRESHOLD_SNAPSHOT_AGE_DAYS=7

collect_infra "$OUT" >/dev/null 2>&1
collect_vms   "$OUT" >/dev/null 2>&1
collect_perf  "$OUT" >/dev/null 2>&1
analyze_blockers "$OUT" aws >/dev/null 2>&1
compute_rightsizing "$OUT" aws >/dev/null 2>&1
compute_licensing   "$OUT" >/dev/null 2>&1
generate_report     "$OUT" aws >/dev/null 2>&1

rs() { "$JQ_BIN" -r --arg n "$1" --arg f "$2" '.[]|select(.vm==$n)|.[$f]' "${OUT}/rightsizing.json"; }
lic() { "$JQ_BIN" -r --arg n "$1" --arg f "$2" '.[]|select(.vm==$n)|.[$f]' "${OUT}/licensing.json"; }

echo "== matrix loader =="
assert_eq "22" "$(_load_instance_matrix aws | "$JQ_BIN" 'length')" "AWS matrix parses"
assert_eq "true" "$(_load_instance_matrix aws | "$JQ_BIN" -c '[ . as $a | range(1;length) | $a[.-1].vcpu <= $a[.].vcpu ] | all')" "matrix sorted ascending by vcpu"
assert_eq "number" "$(_load_instance_matrix gcp | "$JQ_BIN" -r '.[0].vcpu|type')" "vcpu coerced to number"

echo "== right-sizing basis =="
assert_eq "p95"        "$(rs web-01 basis)"       "web-01 sized on p95 (has history)"
assert_eq "configured" "$(rs legacy-app basis)"   "legacy-app sized on configured (no history)"

echo "== right-sizing recommendations =="
assert_eq "2"  "$(rs web-01 req_vcpu)"            "web req vcpu = ceil(4*0.30/0.7)=2"
assert_eq "9"  "$(rs web-01 req_mem_gib)"         "web req mem = ceil(6/0.7)=9"
assert_eq "r5.large" "$(rs web-01 candidate_instance)" "web -> r5.large (mem-driven)"
assert_eq "21" "$(rs db-prod-01 req_vcpu)"        "db req vcpu = ceil(16*0.90/0.7)=21"
assert_eq "m5.8xlarge" "$(rs db-prod-01 candidate_instance)" "db -> m5.8xlarge (32 vCPU)"
assert_eq "t3.medium"  "$(rs legacy-app candidate_instance)" "legacy (configured 2/4) -> t3.medium"
assert_eq "true" "$(rs db-prod-01 fits)"          "candidate fits within matrix"

echo "== licensing flags =="
assert_eq "true"  "$(lic db-prod-01 windows_server)" "Windows Server detected"
assert_eq "2"     "$("$JQ_BIN" 'length' "${OUT}/licensing.json")" "2 VMs with licensing considerations"
assert_eq ""      "$("$JQ_BIN" -r '.[]|select(.vm=="web-01")' "${OUT}/licensing.json")" "Ubuntu VM not flagged"

echo "== report rendering =="
assert_ok "summary.md exists" bash -c "test -s '${OUT}/summary.md'"
assert_ok "summary.html exists" bash -c "test -s '${OUT}/summary.html'"
assert_contains "$(cat "${OUT}/summary.md")" "Migration readiness" "md has readiness section"
assert_contains "$(cat "${OUT}/summary.md")" "Right-sizing rollup" "md has right-sizing section"
assert_contains "$(cat "${OUT}/summary.md")" "Top blockers" "md has blockers section"
assert_contains "$(cat "${OUT}/summary.html")" "<table>" "html has tables"
# readiness totals in the report: 1 ready, 3 blocked (from blocker analysis)
assert_contains "$(cat "${OUT}/summary.md")" "| ✅ Ready | 1 |" "report counts ready=1"
assert_contains "$(cat "${OUT}/summary.md")" "| ⛔ Blocked | 3 |" "report counts blocked=3"

finish
