#!/usr/bin/env bash
# Guards the single-sourced schema: the bash *_CSV_KEYS must match
# share/schema.json exactly. The PowerShell module reads the same file, so this
# is what keeps the two implementations' output schemas from drifting.
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "${HERE}/.." && pwd)"
source "${HERE}/lib.sh"
source "${ROOT}/lib/common.sh"
source "${ROOT}/lib/collect_infra.sh"
source "${ROOT}/lib/collect_vms.sh"
source "${ROOT}/lib/collect_perf.sh"
source "${ROOT}/lib/rightsize.sh"

SCHEMA="${ROOT}/share/schema.json"
sj() { "$JQ_BIN" -r --arg t "$1" '.tables[$t] | join(",")' "$SCHEMA"; }

echo "== bash *_CSV_KEYS == share/schema.json =="
assert_eq "$(sj datacenters)"        "$DC_CSV_KEYS"        "datacenters"
assert_eq "$(sj clusters)"           "$CLUSTER_CSV_KEYS"   "clusters"
assert_eq "$(sj licenses)"           "$LICENSE_CSV_KEYS"   "licenses"
assert_eq "$(sj hosts)"              "$HOST_CSV_KEYS"      "hosts"
assert_eq "$(sj standard_switches)"  "$STDSW_CSV_KEYS"     "standard_switches"
assert_eq "$(sj standard_portgroups)" "$STDPG_CSV_KEYS"    "standard_portgroups"
assert_eq "$(sj datastores)"         "$DS_CSV_KEYS"        "datastores"
assert_eq "$(sj dvswitches)"         "$DVS_CSV_KEYS"       "dvswitches"
assert_eq "$(sj networks)"           "$NET_CSV_KEYS"       "networks"
assert_eq "$(sj resourcepools)"      "$RP_CSV_KEYS"        "resourcepools"
assert_eq "$(sj vms)"                "$VMS_CSV_KEYS"       "vms"
assert_eq "$(sj disks)"              "$DISKS_CSV_KEYS"     "disks"
assert_eq "$(sj nics)"               "$NICS_CSV_KEYS"      "nics"
assert_eq "$(sj snapshots)"          "$SNAPS_CSV_KEYS"     "snapshots"
assert_eq "$(sj utilization)"        "$UTIL_CSV_KEYS"      "utilization"
assert_eq "$(sj rightsizing)"        "$RIGHTSIZE_CSV_KEYS" "rightsizing"
assert_eq "$(sj licensing)"          "$LICENSING_CSV_KEYS" "licensing"
# blockers CSV header is a literal in analyze_blockers.sh:
assert_eq "$(sj blockers)" "vm,severity,blocker,detail,cluster,vm_moref" "blockers"

finish
