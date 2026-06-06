#!/usr/bin/env bash
# Validates the utilization pass: stats (avg/peak/p95), unit conversions,
# and the insufficient-data flag, against fixtures.
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "${HERE}/.." && pwd)"
source "${HERE}/lib.sh"
source "${ROOT}/lib/common.sh"
source "${ROOT}/lib/collect_infra.sh"
source "${ROOT}/lib/collect_vms.sh"
source "${ROOT}/lib/collect_perf.sh"

export VMINV_FIXTURES="${HERE}/fixtures"
OUT="$(mktemp -d)"; trap 'rm -rf "$OUT"' EXIT
PERF_WINDOW_DAYS=30; PERF_INTERVAL=daily

collect_infra "$OUT" >/dev/null 2>&1
collect_vms   "$OUT" >/dev/null 2>&1
collect_perf  "$OUT" >/dev/null 2>&1
u() { "$JQ_BIN" -r --arg n "$1" --arg f "$2" '.[]|select(.vm==$n)|.[$f]' "${OUT}/utilization.json"; }

echo "== stat helper =="
assert_eq '{"avg":40,"peak":100,"p95":100,"n":5}' "$(echo null | "$JQ_BIN" -c "$JQ_PERF_HELPERS"'stat([40,10,30,20,100])')" "avg/peak/p95 over 5 samples"
assert_eq '{"avg":null,"peak":null,"p95":null,"n":0}' "$(echo null | "$JQ_BIN" -c "$JQ_PERF_HELPERS"'stat([-1,-1])')" "all-negative -> no data"

echo "== coverage =="
assert_eq "4" "$("$JQ_BIN" 'length' "${OUT}/utilization.json")" "one util row per VM (incl. no-data VMs)"
assert_eq "false" "$(u web-01 insufficient_data)" "web-01 has history"
assert_eq "true"  "$(u legacy-app insufficient_data)" "legacy-app flagged insufficient"
assert_eq "true"  "$(u gpu-render-01 insufficient_data)" "gpu flagged insufficient"

echo "== values & unit conversion =="
assert_eq "30"   "$(u web-01 cpu_pct_p95)"  "cpu hundredths-% -> 30%"
assert_eq "2100" "$(u web-01 cpu_mhz_p95)"  "cpu MHz p95"
assert_eq "6144" "$(u web-01 mem_mb_p95)"   "mem consumed KB -> 6144 MB"
assert_eq "90"   "$(u db-prod-01 cpu_pct_p95)" "db cpu p95 90%"
assert_eq "33000" "$(u db-prod-01 cpu_mhz_p95)" "db cpu MHz p95"
assert_eq "112"  "$(u web-01 disk_iops_avg)" "iops avg = read.avg + write.avg"
assert_eq "null" "$(u legacy-app disk_iops_avg)" "no-data IOPS -> null (not 0)"

finish
