#!/usr/bin/env bash
#
# lib/collect_vms.sh — full per-VM inventory collection.
#
# ONE bulk property-collector query pulls every needed property for every VM
# (including the config.hardware.device array, snapshot tree and layoutEx), then
# several jq passes derive:
#     vms.json/csv        one row per VM (identity, compute, memory, guest OS,
#                         power, tools, firmware, hw version, placement, rollups)
#     disks.json/csv      one row per virtual disk
#     nics.json/csv       one row per virtual NIC
#     snapshots.json/csv  one row per snapshot (flattened tree)
#
# Cross-references (host->cluster, datastore, network/VLAN, resource pool, vApp,
# folder path, tags) are resolved from the infra JSON written earlier in the run.
#
# Polymorphic vSphere objects are discriminated by the govc/govmomi JSON
# "_typeName" field (modern vim25/json encoding). All such assumptions live in
# the jq below so a live-format variance is a localized fix.
#
# Sourced by vminv; requires lib/common.sh and a prior collect_infra run.

# Properties fetched per VM in the single bulk query.
VM_PROPS=(
  name config.instanceUuid config.uuid config.guestId config.guestFullName
  config.annotation config.version config.firmware config.bootOptions.efiSecureBootEnabled
  config.template config.keyId
  config.hardware.numCPU config.hardware.numCoresPerSocket config.hardware.memoryMB
  config.cpuAllocation.reservation config.cpuAllocation.limit config.cpuAllocation.shares.shares
  config.memoryAllocation.reservation config.memoryAllocation.limit config.memoryAllocation.shares.shares
  config.hardware.device config.tools.toolsVersion
  guest.hostName guest.guestFamily guest.guestFullName guest.ipAddress guest.net
  guest.toolsStatus guest.toolsRunningStatus guest.toolsVersionStatus2
  runtime.powerState runtime.bootTime runtime.host runtime.faultToleranceState runtime.connectionState
  summary.quickStats.uptimeSeconds summary.quickStats.balloonedMemory summary.quickStats.swappedMemory
  summary.storage.committed summary.storage.uncommitted summary.storage.unshared
  resourcePool parentVApp layoutEx snapshot parent
)

VMS_CSV_KEYS="name,power_state,migration_status,blocker_count,guest_os,guest_family,guest_arch,vcpu,cores_per_socket,memory_mb,cpu_reservation_mhz,cpu_limit_mhz,mem_reservation_mib,mem_limit_mib,ballooned_mib,swapped_mib,provisioned_gib,used_gib,disk_count,nic_count,snapshot_count,oldest_snapshot_age_days,snapshot_size_gib,firmware,secure_boot,hw_version,tools_status,tools_version,vmware_tools_installed,encrypted,fault_tolerance,template,primary_ip,guest_hostname,uptime_days,boot_time,host,cluster,resource_pool,vapp,folder_path,instance_uuid,moref"
DISKS_CSV_KEYS="vm,label,provisioned_gib,used_gib,provisioning,disk_mode,independent,sharing,is_rdm,controller_type,datastore,vmdk_path,vm_moref"
NICS_CSV_KEYS="vm,label,adapter_type,mac_address,portgroup,vlan_id,connected,ip_addresses,vm_moref"
SNAPS_CSV_KEYS="vm,name,description,created,age_days,quiesced,state,id,vm_moref"

# jq helpers specific to VM device/parsing, appended to JQ_OC_HELPERS.
JQ_VM_HELPERS='
  def strip_virtual: (. // "") | ltrimstr("Virtual");
  def nic_type:
    { "VirtualVmxnet3":"vmxnet3","VirtualVmxnet2":"vmxnet2","VirtualVmxnet":"vmxnet",
      "VirtualE1000e":"e1000e","VirtualE1000":"e1000","VirtualPCNet32":"pcnet32",
      "VirtualSriovEthernetCard":"sriov" }[.] // (. | strip_virtual);
  def ctrl_type:
    { "ParaVirtualSCSIController":"pvscsi","VirtualLsiLogicController":"lsilogic",
      "VirtualLsiLogicSASController":"lsilogic-sas","VirtualBusLogicController":"buslogic",
      "VirtualAHCIController":"sata","VirtualSATAController":"sata","VirtualIDEController":"ide",
      "VirtualNVMEController":"nvme" }[.] // (. | strip_virtual);
  def is_disk:   (._typeName == "VirtualDisk");
  def is_nic:    (.macAddress != null);
  def is_ctrl:   ((._typeName // "") | test("Controller$"));
  def disk_cap_bytes: (.capacityInBytes // ((.capacityInKB // 0) * 1024));
  def is_rdm: (((.backing._typeName) // "") | test("RawDiskMapping"));
  def disk_provisioning:
    if is_rdm then "rdm"
    elif (.backing.thinProvisioned == true) then "thin"
    elif (.backing.eagerlyScrub == true) then "thick-eager"
    else "thick-lazy" end;
  # recursive snapshot-tree flatten
  def flatten_snaps($vm; $vmo; $now):
    ( .[]? |
      ( { vm:$vm, vm_moref:$vmo, name:.name, description:.description, id:.id,
          created:.createTime, age_days: age_days(.createTime; $now),
          quiesced:(.quiesced // false), state:(.state // null) },
        (.childSnapshotList | flatten_snaps($vm; $vmo; $now)) ) );
  def count_snaps: [ .. | objects | select(has("createTime")) ] | length;
  def oldest_snap_age($now): [ .. | objects | select(has("createTime")) | age_days(.createTime; $now) ] | (max // null);
  # build {deviceKey: usedBytes} from layoutEx (chain files summed per disk)
  def disk_used_map($lex):
    ($lex.file // []) as $files
    | ( reduce $files[] as $f ({}; .[$f.key|tostring] = ($f.size // 0)) ) as $fsz
    | reduce ($lex.disk // [])[] as $d ({};
        .[$d.key|tostring] =
          ( [ ($d.chain // [])[].fileKey[]? | $fsz[tostring] // 0 ] | add // 0) );
  # approximate total snapshot footprint: .vmsn/.vmem (snapshotData) + delta vmdks
  def snap_size_bytes($lex):
    [ ($lex.file // [])[]
      | select((.type == "snapshotData")
               or (((.name // "") | test("-[0-9]{6}(-delta)?\\.vmdk$"))))
      | .size ] | add // 0;
'

# Resolve the VM-scope root (folder or datacenter or whole inventory).
vms_scope_root() {
  if   [ -n "${SCOPE_FOLDER:-}" ];     then printf '%s' "$SCOPE_FOLDER"
  elif [ -n "${SCOPE_DATACENTER:-}" ]; then printf '/%s/vm' "$SCOPE_DATACENTER"
  else printf '/'; fi
}

# --- Folder map (for folder_path resolution) --------------------------------
collect_folders() {
  local out="$1" raw
  raw="$(govc_query folders object.collect -json -type f "$(infra_scope_root)" name parent 2>/dev/null)" \
    || { echo '{}' >"${out}/_folders.json"; return 0; }
  printf '%s' "$raw" | "$JQ_BIN" "$JQ_OC_HELPERS"'
    [ .[] | . as $o | { key: $o.obj.value,
        value: { name: p($o;"name"), parent: ((p($o;"parent")|.value) // null) } } ]
    | from_entries' >"${out}/_folders.json" 2>/dev/null || echo '{}' >"${out}/_folders.json"
}

# --- Tag map (best-effort; tags are non-critical) ---------------------------
# Produces {vmMoref: ["Category/Tag", ...]} in _vm_tags.json and a tags.csv.
build_tag_map() {
  local out="$1"
  if [ -n "${VMINV_FIXTURES:-}" ]; then
    cat "${VMINV_FIXTURES}/vm_tags.json" 2>/dev/null >"${out}/_vm_tags.json" || echo '{}' >"${out}/_vm_tags.json"
    cat "${VMINV_FIXTURES}/tags.json" 2>/dev/null | "$JQ_BIN" '
      [ (.[]?) | { category: (.category // .categoryName // null), tag: (.name // null), description: (.description // "") } ]' \
      2>/dev/null | _write_category "$out" tags "category,tag,description" 2>/dev/null || { printf '[]' >"${out}/tags.json"; : >"${out}/tags.csv"; }
    return 0
  fi
  # Live: enumerate tags, then objects attached to each tag (bounded by #tags).
  local tags cats
  tags="$(govc_ro tags.ls -json 2>/dev/null || echo '[]')"
  cats="$(govc_ro tags.category.ls -json 2>/dev/null || echo '[]')"
  if [ "$(printf '%s' "$tags" | "$JQ_BIN" 'length' 2>/dev/null || echo 0)" = "0" ]; then
    echo '{}' >"${out}/_vm_tags.json"; printf '[]' >"${out}/tags.json"; : >"${out}/tags.csv"; return 0
  fi
  # category id -> name
  local catmap; catmap="$(printf '%s' "$cats" | "$JQ_BIN" '[ .[] | {key:(.id//.Id), value:(.name//.Name)} ] | from_entries' 2>/dev/null || echo '{}')"
  # tags.csv (definitions)
  printf '%s' "$tags" | "$JQ_BIN" --argjson cm "$catmap" '
    [ .[] | { category: ($cm[(.categoryId//.category_id)] // (.categoryId//"")), tag: (.name//.Name), description: (.description//"") } ]' \
    2>/dev/null | _write_category "$out" tags "category,tag,description" 2>/dev/null || true
  # object -> [tags]; iterate each tag's attached objects
  local map='{}' tname tid objs
  while IFS= read -r tid; do
    [ -n "$tid" ] || continue
    tname="$(printf '%s' "$tags" | "$JQ_BIN" -r --arg id "$tid" '.[]|select((.id//.Id)==$id)|((($id) ) as $x | (.name//.Name))' 2>/dev/null)"
    objs="$(govc_ro tags.attached.ls -json "$tid" 2>/dev/null || echo '[]')"
    map="$(printf '%s' "$map" | "$JQ_BIN" --argjson objs "$objs" --arg t "$tname" '
      reduce ($objs[]? | (.value // .Value // .)) as $m (.; .[$m] += [$t])' 2>/dev/null || printf '%s' "$map")"
  done < <(printf '%s' "$tags" | "$JQ_BIN" -r '.[]|(.id//.Id)' 2>/dev/null)
  printf '%s' "$map" >"${out}/_vm_tags.json"
}

# --- Main VM collection -----------------------------------------------------
collect_vms() {
  local out="$1" root raw
  root="$(vms_scope_root)"
  info "Collecting VM inventory (full) from '${root}' ..."
  [ -n "${SCOPE_CLUSTER:-}" ] && warn "SCOPE_CLUSTER='${SCOPE_CLUSTER}' filtering is applied post-hoc by host placement."

  collect_folders "$out"
  build_tag_map   "$out"

  raw="$(govc_query vms object.collect -json -type m "$root" "${VM_PROPS[@]}")" \
    || { err "VM collection query failed."; return 1; }

  # Build cross-reference maps from infra output.
  local NOW dsmap netmap hostmap poolmap foldermap tagmap clmap
  NOW="$(now_epoch)"
  dsmap="$("$JQ_BIN" 'map({(.moref): .name}) | add // {}' "${out}/datastores.json" 2>/dev/null || echo '{}')"
  netmap="$("$JQ_BIN" 'map({(.moref): {name:.name, vlan:.vlan_id}}) | add // {}' "${out}/networks.json" 2>/dev/null || echo '{}')"
  clmap="$("$JQ_BIN" 'map({(.moref): .name}) | add // {}' "${out}/clusters.json" 2>/dev/null || echo '{}')"
  hostmap="$("$JQ_BIN" --argjson cl "$clmap" 'map({(.moref): {name:.name, cluster:($cl[.cluster_moref // ""] // null)}}) | add // {}' "${out}/hosts.json" 2>/dev/null || echo '{}')"
  poolmap="$("$JQ_BIN" 'map({(.moref): .name}) | add // {}' "${out}/resourcepools.json" 2>/dev/null || echo '{}')"
  foldermap="$(cat "${out}/_folders.json" 2>/dev/null || echo '{}')"
  tagmap="$(cat "${out}/_vm_tags.json" 2>/dev/null || echo '{}')"

  _vms_table   "$raw" "$out" "$NOW" "$dsmap" "$netmap" "$hostmap" "$poolmap" "$foldermap" "$tagmap"
  _disks_table "$raw" "$out" "$dsmap"
  _nics_table  "$raw" "$out" "$netmap"
  _snaps_table "$raw" "$out" "$NOW"

  local n; n="$(csv_count_rows "${out}/vms.csv")"
  ok "VMs: ${n} | disks: $(csv_count_rows "${out}/disks.csv") | nics: $(csv_count_rows "${out}/nics.csv") | snapshots: $(csv_count_rows "${out}/snapshots.csv")"
}

# Apply SCOPE_VM_GLOB (anchored, * and ? wildcards) to a normalized VM array.
_apply_vm_glob() {
  local glob="${SCOPE_VM_GLOB:-}"
  if [ -z "$glob" ]; then cat; return; fi
  "$JQ_BIN" --arg glob "$glob" '
    map(select(.name != null and (.name | test("^" + ($glob
      | gsub("\\."; "\\.") | gsub("\\*"; ".*") | gsub("\\?"; ".")) + "$"))))'
}

_vms_table() {
  local raw="$1" out="$2" now="$3" ds="$4" net="$5" hosts="$6" pools="$7" folders="$8" tags="$9"
  printf '%s' "$raw" | "$JQ_BIN" \
      --argjson ds "$ds" --argjson net "$net" --argjson hosts "$hosts" \
      --argjson pools "$pools" --argjson folders "$folders" --argjson tags "$tags" \
      --argjson now "$now" \
      "$JQ_OC_HELPERS$JQ_VM_HELPERS"'
    def folder_path($start):
      def walk($m): if ($m == null or $folders[$m] == null) then [] else walk($folders[$m].parent) + [$folders[$m].name] end;
      "/" + (walk($start) | join("/"));
    [ .[] | . as $o | ($o.obj.value) as $mo
      | (p($o;"config.hardware.device") // []) as $dev
      | [ $dev[] | select(is_disk) ] as $disks
      | [ $dev[] | select(is_nic)  ] as $nics
      | ((p($o;"snapshot")) // null) as $snap
      | ((p($o;"config.guestFullName") // p($o;"guest.guestFullName")) // null) as $gos
      | ((p($o;"config.guestId")) // "") as $gid
      | (((p($o;"runtime.host")) | .value) // null) as $hostmo
      | {
          name:            (p($o;"name") // null),
          power_state:     (p($o;"runtime.powerState") // null),
          guest_os:        ($gos // null),
          guest_family:    (p($o;"guest.guestFamily") // null),
          guest_arch:      (if (($gid + ($gos // "")) | test("64")) then "x86_64" else "x86" end),
          guest_id:        ($gid // null),
          vcpu:            (p($o;"config.hardware.numCPU") // 0),
          cores_per_socket:(p($o;"config.hardware.numCoresPerSocket") // 1),
          memory_mb:       (p($o;"config.hardware.memoryMB") // 0),
          cpu_reservation_mhz: (p($o;"config.cpuAllocation.reservation") // 0),
          cpu_limit_mhz:       (p($o;"config.cpuAllocation.limit") // -1),
          cpu_shares:          (p($o;"config.cpuAllocation.shares.shares") // null),
          mem_reservation_mib: (p($o;"config.memoryAllocation.reservation") // 0),
          mem_limit_mib:       (p($o;"config.memoryAllocation.limit") // -1),
          ballooned_mib:   (p($o;"summary.quickStats.balloonedMemory") // 0),
          swapped_mib:     (p($o;"summary.quickStats.swappedMemory") // 0),
          provisioned_gib: ( [ $disks[] | disk_cap_bytes ] | add // 0 | gib(.) ),
          used_gib:        gib(p($o;"summary.storage.committed")),
          disk_count:      ($disks | length),
          nic_count:       ($nics | length),
          snapshot_count:  (if $snap == null then 0 else ($snap.rootSnapshotList | count_snaps) end),
          oldest_snapshot_age_days: (if $snap == null then null else ($snap.rootSnapshotList | oldest_snap_age($now)) end),
          snapshot_size_gib: gib(snap_size_bytes(p($o;"layoutEx") // {})),
          firmware:        (p($o;"config.firmware") // null),
          secure_boot:     (p($o;"config.bootOptions.efiSecureBootEnabled") // false),
          hw_version:      ((p($o;"config.version") // "") | ltrimstr("vmx-")),
          tools_status:    (p($o;"guest.toolsStatus") // null),
          tools_running:   (p($o;"guest.toolsRunningStatus") // null),
          tools_version:   (p($o;"config.tools.toolsVersion") // null),
          vmware_tools_installed: ((p($o;"guest.toolsStatus") // "toolsNotInstalled") != "toolsNotInstalled"),
          encrypted:       (((p($o;"config.keyId")) // null) != null),
          fault_tolerance: (p($o;"runtime.faultToleranceState") // null),
          template:        (p($o;"config.template") // false),
          has_rdm:                 ([ $disks[] | select(is_rdm) ] | length > 0),
          has_multiwriter_disk:    ([ $disks[] | select(.backing.sharing == "sharingMultiWriter") ] | length > 0),
          has_independent_disk:    ([ $disks[] | select(((.backing.diskMode // "") | startswith("independent"))) ] | length > 0),
          has_vtpm:                ([ $dev[]   | select(._typeName == "VirtualTPM") ] | length > 0),
          has_pci_passthrough:     ([ $dev[]   | select(((._typeName // "") | startswith("VirtualPCIPassthrough"))) ] | length > 0),
          has_vgpu:                ([ $dev[]   | select((((.backing._typeName // "") | test("Vmiop"))) or ((.backing.vgpu // null) != null)) ] | length > 0),
          connected_cdrom:         ([ $dev[]   | select((._typeName == "VirtualCdrom") and ((.connectable.connected // false) == true)) ] | length > 0),
          has_usb:                 ([ $dev[]   | select(((._typeName // "") | test("USB"))) ] | length > 0),
          has_serial_parallel:     ([ $dev[]   | select(((._typeName // "") | test("Serial|Parallel"))) ] | length > 0),
          primary_ip:      (p($o;"guest.ipAddress") // null),
          guest_hostname:  (p($o;"guest.hostName") // null),
          uptime_days:     ((p($o;"summary.quickStats.uptimeSeconds") // 0) / 86400 | floor),
          boot_time:       (p($o;"runtime.bootTime") // null),
          host:            ($hosts[$hostmo // ""].name // null),
          cluster:         ($hosts[$hostmo // ""].cluster // null),
          resource_pool:   ($pools[((p($o;"resourcePool")|.value) // "")] // null),
          vapp:            ($pools[((p($o;"parentVApp")|.value) // "")] // null),
          folder_path:     folder_path((p($o;"parent")|.value)),
          annotation:      (p($o;"config.annotation") // null),
          tags:            ($tags[$mo] // []),
          instance_uuid:   (p($o;"config.instanceUuid") // null),
          bios_uuid:       (p($o;"config.uuid") // null),
          moref:           $mo
        } ]' \
    | _apply_vm_glob \
    | tee "${out}/vms.json" \
    | json_to_csv "$VMS_CSV_KEYS" >"${out}/vms.csv"
}

_disks_table() {
  local raw="$1" out="$2" ds="$3"
  printf '%s' "$raw" | "$JQ_BIN" --argjson ds "$ds" "$JQ_OC_HELPERS$JQ_VM_HELPERS"'
    [ .[] | . as $o | (p($o;"name")) as $vm | ($o.obj.value) as $mo
      | (p($o;"config.hardware.device") // []) as $dev
      | ((p($o;"layoutEx")) // {}) as $lex
      | (disk_used_map($lex)) as $used
      | ( [ $dev[] | select(is_ctrl) | {key:(.key|tostring), value:(._typeName|ctrl_type)} ] | from_entries ) as $ctrls
      | $dev[] | select(is_disk)
      | {
          vm: $vm, vm_moref: $mo,
          label:        (.deviceInfo.label // null),
          provisioned_gib: gib(disk_cap_bytes),
          used_gib:        gib(($used[(.key|tostring)] // 0)),
          provisioning:    disk_provisioning,
          disk_mode:       (.backing.diskMode // null),
          independent:     (((.backing.diskMode // "") | startswith("independent"))),
          sharing:         (.backing.sharing // "sharingNone"),
          is_rdm:          is_rdm,
          controller_type: ($ctrls[(.controllerKey|tostring)] // null),
          datastore:       ($ds[((.backing.datastore)|.value)] // null),
          vmdk_path:       (.backing.fileName // null)
        } ]' \
    | tee "${out}/disks.json" \
    | json_to_csv "$DISKS_CSV_KEYS" >"${out}/disks.csv"
}

_nics_table() {
  local raw="$1" out="$2" net="$3"
  printf '%s' "$raw" | "$JQ_BIN" --argjson net "$net" "$JQ_OC_HELPERS$JQ_VM_HELPERS"'
    [ .[] | . as $o | (p($o;"name")) as $vm | ($o.obj.value) as $mo
      | (p($o;"config.hardware.device") // []) as $dev
      | ( reduce (p($o;"guest.net") // [])[] as $n ({};
            .[($n.macAddress // "" | ascii_downcase)] =
              (($n.ipAddress // [ ($n.ipConfig.ipAddress // [])[].ipAddress ]) | map(select(. != null)))) ) as $ipmap
      | $dev[] | select(is_nic)
      | ((.backing.port.portgroupKey) // "") as $pgkey
      | {
          vm: $vm, vm_moref: $mo,
          label:        (.deviceInfo.label // null),
          adapter_type: (._typeName | nic_type),
          mac_address:  (.macAddress // null),
          portgroup:    ( .backing.deviceName // ($net[$pgkey].name) // (if $pgkey == "" then null else $pgkey end) ),
          vlan_id:      ( $net[$pgkey].vlan // null ),
          connected:    (.connectable.connected // false),
          ip_addresses: (($ipmap[(.macAddress // "" | ascii_downcase)] // []) | join(";"))
        } ]' \
    | tee "${out}/nics.json" \
    | json_to_csv "$NICS_CSV_KEYS" >"${out}/nics.csv"
}

_snaps_table() {
  local raw="$1" out="$2" now="$3"
  printf '%s' "$raw" | "$JQ_BIN" --argjson now "$now" "$JQ_OC_HELPERS$JQ_VM_HELPERS"'
    [ .[] | . as $o | (p($o;"name")) as $vm | ($o.obj.value) as $mo
      | (p($o;"snapshot")) as $snap
      | select($snap != null)
      | ($snap.rootSnapshotList | flatten_snaps($vm; $mo; $now)) ]' \
    | tee "${out}/snapshots.json" \
    | json_to_csv "$SNAPS_CSV_KEYS" >"${out}/snapshots.csv"
}
