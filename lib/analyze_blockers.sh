#!/usr/bin/env bash
#
# lib/analyze_blockers.sh — migration blocker / risk analysis.
#
# Pure analysis over already-collected data (vms.json + disks.json) plus the
# editable OS support matrix and the configurable THRESHOLD_* values. Produces:
#   blockers.json/csv   one row per (vm, blocker), severity-sorted
#   blockers_summary.json   counts by severity and by blocker type
# and annotates each VM in vms.json/csv with migration_status + blocker_count.
#
# Severity: high = hard blocker for AWS/Azure/GCP import tooling;
#           medium = needs remediation before/around migration;
#           low = advisory.
#
# Sourced by vminv; requires lib/common.sh and prior collect_vms.

# analyze_blockers <out_dir> <target-provider>
analyze_blockers() {
  local out="$1" target="$2"
  [ -f "${out}/vms.json" ] || { warn "No vms.json; skipping blocker analysis."; printf '[]' >"${out}/blockers.json"; : >"${out}/blockers.csv"; return 0; }
  info "Analyzing migration blockers (target: ${target}) ..."

  local matrix
  matrix="$(csv_to_json <"${ROOT_DIR}/matrices/os_support.csv" 2>/dev/null || echo '[]')"
  # per-VM max disk size (GiB), for the large-disk rule
  local diskmax
  diskmax="$("$JQ_BIN" 'reduce .[] as $d ({}; .[$d.vm_moref] = ([ (.[$d.vm_moref] // 0), ($d.provisioned_gib // 0) ] | max))' "${out}/disks.json" 2>/dev/null || echo '{}')"

  local result
  result="$("$JQ_BIN" \
      --argjson mx "$matrix" --argjson dm "$diskmax" --arg target "$target" \
      --argjson largeDisk "${THRESHOLD_LARGE_DISK_GB:-2048}" \
      --argjson largeVM "${THRESHOLD_LARGE_VM_GB:-8192}" \
      --argjson oldHw "${THRESHOLD_OLD_HW_VERSION:-9}" \
      --argjson snapAge "${THRESHOLD_SNAPSHOT_AGE_DAYS:-7}" '
    # OS support: "yes" | "no" | "unknown"
    def os_support($os):
      ( [ $mx[] | select(.pattern as $p | (($os // "") | test($p; "i"))) ] | .[0] ) as $m
      | if $m == null then "unknown" else ($m[$target] // "yes") end;

    def vm_blockers($v):
      ($dm[$v.moref] // 0) as $maxdisk
      | (os_support($v.guest_os)) as $os
      | [
          (if ($v.has_rdm // false)              then {b:"rdm",                s:"high",   d:"Raw Device Mapping (RDM) present — not supported by cloud migration"} else empty end),
          (if ($v.has_multiwriter_disk // false) then {b:"shared-multiwriter-disk", s:"high", d:"Multi-writer/shared disk (clustering) — blocks standard migration"} else empty end),
          (if ($v.has_pci_passthrough // false)  then {b:"pci-passthrough",    s:"high",   d:"PCI passthrough / DirectPath I/O — no equivalent on standard cloud SKUs"} else empty end),
          (if ($v.has_vgpu // false)             then {b:"vgpu",               s:"high",   d:"vGPU device — requires a specific GPU cloud SKU"} else empty end),
          (if ($v.has_vtpm // false)             then {b:"vtpm",               s:"high",   d:"Virtual TPM present — commonly blocks migration tooling"} else empty end),
          (if ($v.encrypted // false)            then {b:"vm-encryption",      s:"high",   d:"vSphere VM Encryption — must be decrypted before migration"} else empty end),
          (if (($v.fault_tolerance // "") | test("running|enabled"; "i")) then {b:"fault-tolerance", s:"high", d:"Fault Tolerance enabled — must be disabled before migration"} else empty end),
          (if $os == "no"      then {b:"unsupported-os", s:"high", d:("Guest OS not supported on " + $target + ": " + ($v.guest_os // "unknown"))} else empty end),
          (if (($v.snapshot_count // 0) > 0) then
             (if (($v.oldest_snapshot_age_days // 0) > $snapAge)
              then {b:"stale-snapshot",  s:"medium", d:("Snapshot older than " + ($snapAge|tostring) + "d (" + (($v.oldest_snapshot_age_days // 0)|tostring) + "d) — consolidate before migrating")}
              else {b:"active-snapshot", s:"medium", d:(($v.snapshot_count|tostring) + " active snapshot(s) — consolidate before migrating")} end)
           else empty end),
          (if ($v.has_independent_disk // false) then {b:"independent-disk", s:"medium", d:"Independent disk(s) — excluded from snapshots; verify migration handling"} else empty end),
          (if ($v.connected_cdrom // false)      then {b:"connected-iso",     s:"medium", d:"Connected CD/DVD (ISO) — disconnect before migration"} else empty end),
          (if ($v.has_usb // false)              then {b:"usb-device",        s:"medium", d:"USB device attached — cannot be migrated"} else empty end),
          (if ($v.has_serial_parallel // false)  then {b:"serial-parallel-port", s:"medium", d:"Serial/parallel port present — may block migration"} else empty end),
          ( (((($v.hw_version // "0") | tonumber?) // 0)) as $hw
            | if ($hw > 0 and $hw <= $oldHw) then {b:"old-hw-version", s:"medium", d:("Very old virtual hardware version (vmx-" + ($v.hw_version // "?") + ")")} else empty end ),
          (if ($maxdisk > $largeDisk)            then {b:"large-disk",        s:"medium", d:("Disk larger than " + ($largeDisk|tostring) + " GiB (" + ($maxdisk|tostring) + " GiB)")} else empty end),
          (if (($v.provisioned_gib // 0) > $largeVM) then {b:"large-footprint", s:"medium", d:("Total provisioned > " + ($largeVM|tostring) + " GiB (" + (($v.provisioned_gib // 0)|tostring) + " GiB)")} else empty end),
          (if ($os == "unknown") then {b:"os-not-in-matrix", s:"low", d:("Guest OS not in support matrix — verify manually: " + ($v.guest_os // "unknown"))} else empty end),
          (if (($v.vmware_tools_installed) == false) then {b:"no-vmware-tools", s:"low", d:"VMware Tools not installed — harder to migrate/agent"} else empty end)
        ];

    { sevrank: {"high":3,"medium":2,"low":1} } as $C
    | [ .[] | . as $v | (vm_blockers($v)) as $bl | { v:$v, bl:$bl } ] as $rows
    | {
        blockers:
          ( [ $rows[] | .v as $v | .bl[] | { vm:$v.name, vm_moref:$v.moref, cluster:($v.cluster // null), blocker:.b, severity:.s, detail:.d } ]
            | sort_by(-($C.sevrank[.severity]), .vm) ),
        readiness:
          ( [ $rows[] | { moref: .v.moref,
                          blocker_count: (.bl | length),
                          top_severity: ( [ .bl[].s ] | (if (any(. == "high")) then "high" elif (any(. == "medium")) then "medium" elif (any(. == "low")) then "low" else "none" end) ),
                          migration_status: ( [ .bl[].s ] | (if (any(. == "high")) then "blocked" elif (length > 0) then "needs-work" else "ready" end) ) } ] )
      }' "${out}/vms.json")"

  # blockers table (severity-sorted), CSV + JSON
  printf '%s' "$result" | "$JQ_BIN" '.blockers' >"${out}/blockers.json"
  json_to_csv "vm,severity,blocker,detail,cluster,vm_moref" <"${out}/blockers.json" >"${out}/blockers.csv"

  # severity / type summary
  printf '%s' "$result" | "$JQ_BIN" '.blockers
    | { total: length,
        by_severity: (reduce .[] as $b ({}; .[$b.severity] = ((.[$b.severity] // 0) + 1))),
        by_blocker:  (reduce .[] as $b ({}; .[$b.blocker]  = ((.[$b.blocker]  // 0) + 1))) }' \
    >"${out}/blockers_summary.json"

  # annotate VMs with readiness, then rewrite vms.json + vms.csv
  local rmap; rmap="$(printf '%s' "$result" | "$JQ_BIN" '.readiness | map({key:.moref, value:.}) | from_entries')"
  "$JQ_BIN" --argjson r "$rmap" '
    [ .[] | . as $v | ($r[$v.moref] // {migration_status:"unknown",blocker_count:0,top_severity:"none"}) as $rr
      | . + { migration_status:$rr.migration_status, blocker_count:$rr.blocker_count, top_severity:$rr.top_severity } ]' \
    "${out}/vms.json" >"${out}/vms.json.tmp" && mv "${out}/vms.json.tmp" "${out}/vms.json"
  "$JQ_BIN" '.' "${out}/vms.json" | json_to_csv "$VMS_CSV_KEYS" >"${out}/vms.csv"

  local hi me lo
  hi="$("$JQ_BIN" '.by_severity.high // 0' "${out}/blockers_summary.json")"
  me="$("$JQ_BIN" '.by_severity.medium // 0' "${out}/blockers_summary.json")"
  lo="$("$JQ_BIN" '.by_severity.low // 0' "${out}/blockers_summary.json")"
  ok "Blockers: ${hi} high, ${me} medium, ${lo} low across $(csv_count_rows "${out}/blockers.csv") finding(s)"
}
