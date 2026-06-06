#!/usr/bin/env bash
# Validates the FULL per-VM collection (vms + disks + nics + snapshots),
# placement cross-referencing, tags and folder paths, against fixtures.
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "${HERE}/.." && pwd)"
source "${HERE}/lib.sh"
source "${ROOT}/lib/common.sh"
source "${ROOT}/lib/collect_infra.sh"
source "${ROOT}/lib/collect_vms.sh"

export VMINV_FIXTURES="${HERE}/fixtures"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

collect_infra "$OUT" >/dev/null 2>&1   # VM placement needs infra maps
collect_vms   "$OUT" >/dev/null 2>&1
J() { "$JQ_BIN" "$@"; }
# field of the VM named $1
vm() { "$JQ_BIN" -r --arg n "$1" --arg f "$2" '.[]|select(.name==$n)|.[$f]' "${OUT}/vms.json"; }
# field $4 of the first row in file $1 where row[$2]==$3
sel() { "$JQ_BIN" -r --arg k "$2" --arg v "$3" --arg f "$4" '.[]|select(.[$k]==$v)|.[$f]' "$1"; }

echo "== vms table =="
assert_eq "4" "$(J 'length' "${OUT}/vms.json")" "4 VMs collected (none dropped by empty-stream)"
assert_eq "600" "$(vm db-prod-01 provisioned_gib)" "db provisioned = 100 + 500 RDM"
assert_eq "90"  "$(vm db-prod-01 used_gib)"        "db used from summary.storage.committed"
assert_eq "x86_64" "$(vm web-01 guest_arch)"       "guest arch derived from guestId"
assert_eq "2"   "$(vm web-01 cores_per_socket)"    "cores per socket"
assert_eq "7"   "$(vm legacy-app hw_version)"      "old hw version stripped of vmx-"
assert_eq "true"  "$(vm db-prod-01 secure_boot)"   "secure boot true"
assert_eq "efi"   "$(vm db-prod-01 firmware)"      "firmware efi"
assert_eq "true"  "$(vm gpu-render-01 encrypted)"  "encrypted VM detected (keyId present)"
assert_eq "false" "$(vm web-01 encrypted)"         "non-encrypted VM (keyId ABSENT -> false, not dropped)"
assert_eq "false" "$(vm legacy-app vmware_tools_installed)" "tools not installed flagged"

echo "== placement cross-reference =="
assert_eq "esx-01.corp.example.com" "$(vm web-01 host)" "host name resolved from moref"
assert_eq "Prod-Cluster-01" "$(vm web-01 cluster)" "cluster resolved via host parent"
assert_eq "null" "$(vm legacy-app cluster)" "host with no parent cluster -> null (no crash)"
assert_eq "Production-Pool" "$(vm web-01 resource_pool)" "resource pool resolved"
assert_eq "App-Tier-vApp" "$(vm gpu-render-01 vapp)" "vApp resolved"
assert_eq "/vm/Databases" "$(vm db-prod-01 folder_path)" "folder path resolved via parent chain"

echo "== tags =="
assert_eq "Environment/Production" "$("$JQ_BIN" -r '.[]|select(.name=="web-01")|.tags[0]' "${OUT}/vms.json")" "tags attached to VM"
assert_eq "0" "$("$JQ_BIN" '[.[]|select(.name=="legacy-app")|.tags[]]|length' "${OUT}/vms.json")" "untagged VM -> empty tags"

echo "== disks =="
assert_eq "5" "$(J 'length' "${OUT}/disks.json")" "5 disks total (none dropped by missing layoutEx)"
assert_eq "true"  "$(J -r '.[]|select(.is_rdm)|.is_rdm' "${OUT}/disks.json")" "RDM detected"
assert_eq "rdm"   "$(J -r '.[]|select(.is_rdm)|.provisioning' "${OUT}/disks.json")" "RDM provisioning label"
assert_eq "true"  "$(sel "${OUT}/disks.json" vm legacy-app independent)" "independent disk mode flagged"
assert_eq "sharingMultiWriter" "$(sel "${OUT}/disks.json" vm legacy-app sharing)" "multi-writer sharing captured"
assert_eq "thin" "$(sel "${OUT}/disks.json" vm web-01 provisioning)" "thin provisioning"
assert_eq "pvscsi" "$(sel "${OUT}/disks.json" vm web-01 controller_type)" "controller type resolved (from_entries fix)"
assert_eq "vsanDatastore" "$(sel "${OUT}/disks.json" vm web-01 datastore)" "datastore moref resolved to name"
assert_eq "thick-lazy" "$("$JQ_BIN" -r '.[]|select(.vm=="db-prod-01" and .label=="Hard disk 1")|.provisioning' "${OUT}/disks.json")" "thick-lazy provisioning"

echo "== nics =="
assert_eq "4" "$(J 'length' "${OUT}/nics.json")" "4 NICs total"
assert_eq "vmxnet3" "$(sel "${OUT}/nics.json" vm web-01 adapter_type)" "adapter type mapped"
assert_eq "100" "$(sel "${OUT}/nics.json" vm web-01 vlan_id)" "dvportgroup VLAN resolved"
assert_eq "PG-Web-VLAN100" "$(sel "${OUT}/nics.json" vm web-01 portgroup)" "dvportgroup name resolved"
assert_eq "VM Network" "$(sel "${OUT}/nics.json" vm db-prod-01 portgroup)" "standard network name (null portgroupKey, no crash)"
assert_eq "10.0.100.11;fe80::250:56ff:feaa:bb01" "$(sel "${OUT}/nics.json" vm web-01 ip_addresses)" "per-NIC IPs from guest.net by MAC"

echo "== snapshots =="
assert_eq "2" "$(J 'length' "${OUT}/snapshots.json")" "2 snapshots flattened from tree"
assert_eq "2" "$(vm db-prod-01 snapshot_count)" "snapshot_count on VM"
assert_eq "true" "$(sel "${OUT}/snapshots.json" name 'After patch' quiesced)" "quiesced flag"
assert_eq "14" "$(vm db-prod-01 snapshot_size_gib)" "snapshot size ~ vmsn(4) + delta(10) GiB"

finish
