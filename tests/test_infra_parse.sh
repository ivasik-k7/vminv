#!/usr/bin/env bash
# Validates infrastructure normalization (clusters/hosts/datastores/networks/pools)
# against fixtures, with no live vCenter.
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "${HERE}/.." && pwd)"
source "${HERE}/lib.sh"
source "${ROOT}/lib/common.sh"
source "${ROOT}/lib/collect_infra.sh"

export VMINV_FIXTURES="${HERE}/fixtures"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

# Run the full infra collection against fixtures, then assert on the outputs.
collect_infra "$OUT" >/dev/null 2>&1
J() { "$JQ_BIN" "$@"; }

echo "== clusters =="
assert_eq "2" "$(J 'length' "${OUT}/clusters.json")" "2 clusters"
assert_eq "true" "$(J -r '.[]|select(.name=="Prod-Cluster-01")|.drs_enabled' "${OUT}/clusters.json")" "DRS enabled parsed"
assert_eq "intel-skylake" "$(J -r '.[]|select(.name=="Prod-Cluster-01")|.evc_mode' "${OUT}/clusters.json")" "EVC mode parsed"
assert_eq "disabled" "$(J -r '.[]|select(.name=="Dev-Cluster-02")|.evc_mode' "${OUT}/clusters.json")" "EVC absent -> disabled"
assert_eq "1024" "$(J -r '.[]|select(.name=="Prod-Cluster-01")|.total_memory_gib' "${OUT}/clusters.json")" "1TiB -> 1024 GiB"

echo "== hosts =="
assert_eq "2" "$(J 'length' "${OUT}/hosts.json")" "2 hosts"
assert_eq "256" "$(J -r '.[0].memory_gib' "${OUT}/hosts.json")" "host RAM GiB"
assert_eq "40" "$(J -r '.[0].cores' "${OUT}/hosts.json")" "host cores"
assert_eq "7.0.3" "$(J -r '.[]|select(.name=="esx-02.corp.example.com")|.esxi_version' "${OUT}/hosts.json")" "mixed ESXi versions"

echo "== datastores =="
assert_eq "vsan" "$(J -r '.[]|select(.name=="vsanDatastore")|.type' "${OUT}/datastores.json")" "vSAN type"
assert_eq "3" "$(J -r '.[]|select(.name=="vsanDatastore")|.vm_count' "${OUT}/datastores.json")" "datastore VM count"
assert_eq "50" "$(J -r '.[]|select(.name=="vsanDatastore")|.pct_used' "${OUT}/datastores.json")" "pct used computed"
assert_eq "10240" "$(J -r '.[]|select(.name=="vsanDatastore")|.used_gib' "${OUT}/datastores.json")" "used GiB computed"

echo "== networks =="
assert_eq "3" "$(J 'length' "${OUT}/networks.json")" "2 dvpg + 1 standard"
assert_eq "100" "$(J -r '.[]|select(.name=="PG-Web-VLAN100")|.vlan_id' "${OUT}/networks.json")" "VLAN id parsed"
assert_eq "vDS-Prod" "$(J -r '.[]|select(.name=="PG-Web-VLAN100")|.switch' "${OUT}/networks.json")" "dvs moref resolved to name"
assert_eq "standard" "$(J -r '.[]|select(.name=="VM Network")|.kind' "${OUT}/networks.json")" "standard network kind"

echo "== resource pools / vApps =="
assert_eq "2" "$(J 'length' "${OUT}/resourcepools.json")" "1 pool + 1 vApp"
assert_eq "vApp" "$(J -r '.[]|select(.name=="App-Tier-vApp")|.kind' "${OUT}/resourcepools.json")" "vApp kind labeled"

echo "== licenses & host attribution =="
assert_eq "2" "$(J 'length' "${OUT}/licenses.json")" "2 licenses"
assert_eq "esx.enterprisePlus.cpuPackage" "$(J -r '.[]|select(.name=="esx-01.corp.example.com")|.license_edition' "${OUT}/hosts.json")" "host license edition attributed"
assert_eq "...EFGHK" "$(J -r '.[]|select(.edition=="esx.enterprisePlus.cpuPackage")|.license_key_tail' "${OUT}/licenses.json")" "license key tail only (no full key leaked)"

echo "== standard networking =="
assert_eq "1" "$(J 'length' "${OUT}/standard_switches.json")" "1 standard vSwitch"
assert_eq "50" "$(J -r '.[]|select(.name=="Legacy-VLAN50")|.vlan_id' "${OUT}/standard_portgroups.json")" "standard portgroup VLAN id"

echo "== CSV boolean-false regression =="
# json_to_csv must render boolean false as "false", not an empty cell.
assert_contains "$(grep Dev-Cluster-02 "${OUT}/clusters.csv")" "false" "boolean false rendered in CSV (not blank)"

finish
