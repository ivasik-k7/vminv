#!/usr/bin/env bash
#
# lib/collect_infra.sh — infrastructure-level inventory collection.
#
#   datacenters, clusters (DRS/HA/EVC), hosts, datastores,
#   networks (standard + vDS port groups), distributed switches,
#   resource pools, vApps.
#
# All collection uses the property collector (govc object.collect) — one bulk
# query per object type — and tolerates per-category failure (a failing
# category logs and returns non-zero; the caller continues).
#
# govc -type KIND tokens used below (confirm against `govc find -type` on first
# live run): d=Datacenter c=ClusterComputeResource h=HostSystem s=Datastore
# n=Network p=ResourcePool g=DistributedVirtualPortgroup
# w=DistributedVirtualSwitch a=VirtualApp
#
# Sourced by vminv; requires lib/common.sh.

# Generic writer: given normalized JSON (stdin), write <base>.json + <base>.csv.
_write_category() { # _write_category <out_dir> <base> <csv_keys>
  local out="$1" base="$2" keys="$3" json
  json="$(cat)"
  printf '%s\n' "$json" >"${out}/${base}.json"
  printf '%s' "$json" | json_to_csv "$keys" >"${out}/${base}.csv"
  local n; n="$(printf '%s' "$json" | "$JQ_BIN" 'length')"
  ok "${base}: ${n}"
}

# --- Datacenters ------------------------------------------------------------
DC_CSV_KEYS="name,moref"
collect_datacenters() {
  local out="$1" raw
  info "Collecting datacenters ..."
  raw="$(oc_query datacenters d name)" || { err "datacenter query failed"; return 1; }
  printf '%s' "$raw" | "$JQ_BIN" "$JQ_OC_HELPERS"'
    [ .[] | . as $o | { name: p($o;"name"), moref: $o.obj.value } ]' \
    | _write_category "$out" datacenters "$DC_CSV_KEYS"
}

# --- Clusters (DRS / HA / EVC) ----------------------------------------------
CLUSTER_CSV_KEYS="name,num_hosts,num_effective_hosts,drs_enabled,drs_behavior,ha_enabled,evc_mode,total_cpu_mhz,total_memory_gib,moref"
collect_clusters() {
  local out="$1" raw
  info "Collecting clusters (DRS/HA/EVC) ..."
  raw="$(oc_query clusters c \
            name \
            summary.numHosts summary.numEffectiveHosts \
            configuration.drsConfig.enabled \
            configuration.drsConfig.defaultVmBehavior \
            configuration.dasConfig.enabled \
            summary.currentEVCModeKey \
            summary.totalCpu summary.totalMemory)" \
    || { err "cluster query failed"; return 1; }
  printf '%s' "$raw" | "$JQ_BIN" "$JQ_OC_HELPERS"'
    [ .[] | . as $o | {
        name:                p($o;"name"),
        num_hosts:           (p($o;"summary.numHosts") // 0),
        num_effective_hosts: (p($o;"summary.numEffectiveHosts") // 0),
        drs_enabled:         (p($o;"configuration.drsConfig.enabled") // false),
        drs_behavior:        (p($o;"configuration.drsConfig.defaultVmBehavior") // null),
        ha_enabled:          (p($o;"configuration.dasConfig.enabled") // false),
        evc_mode:            (p($o;"summary.currentEVCModeKey") // "disabled"),
        total_cpu_mhz:       (p($o;"summary.totalCpu") // 0),
        total_memory_gib:    gib(p($o;"summary.totalMemory")),
        moref:               $o.obj.value
      } ]' \
    | _write_category "$out" clusters "$CLUSTER_CSV_KEYS"
}

# --- Licenses ---------------------------------------------------------------
# vCenter-wide license inventory (license.ls) and a moref->edition map for
# per-host license attribution (license.assigned.ls). Both tolerate the legacy
# CamelCase and modern lowerCamel govc JSON key spellings.
LICENSE_CSV_KEYS="name,edition,total,used,license_key_tail"
collect_licenses() {
  local out="$1" raw
  info "Collecting licenses ..."
  raw="$(govc_query licenses license.ls -json 2>/dev/null)" \
    || { warn "license.ls failed — skipping licenses"; printf '[]' >"${out}/licenses.json"; : >"${out}/licenses.csv"; return 0; }
  printf '%s' "$raw" | "$JQ_BIN" '
    [ (.[]?) | {
        name:            (.name // .Name // null),
        edition:         (.editionKey // .EditionKey // null),
        total:           (.total // .Total // 0),
        used:            (.used // .Used // 0),
        license_key_tail: ((.licenseKey // .LicenseKey // "") | if . == "" then "" else "..." + (.[-5:]) end)
      } ]' \
    | _write_category "$out" licenses "$LICENSE_CSV_KEYS"
}

# Build {hostMoref: editionName} from license.assigned.ls; echo "{}" if absent.
_host_license_map() {
  local raw
  raw="$(govc_query licenses_assigned license.assigned.ls -json 2>/dev/null)" || { echo '{}'; return 0; }
  printf '%s' "$raw" | "$JQ_BIN" '
    [ (.[]?)
      | { key:   (.EntityId // .entityId // null),
          value: ((.AssignedLicense // .assignedLicense // {}) | (.EditionKey // .editionKey // .Name // .name // null)) }
      | select(.key != null) ]
    | from_entries' 2>/dev/null || echo '{}'
}

# --- Hosts ------------------------------------------------------------------
HOST_CSV_KEYS="name,vendor,model,cpu_model,sockets,cores,threads,memory_gib,esxi_version,esxi_build,connection_state,power_state,license_edition,cluster_moref,moref"
collect_hosts() {
  local out="$1" raw licmap
  info "Collecting hosts ..."
  licmap="$(_host_license_map)"
  raw="$(oc_query hosts h \
            name \
            summary.hardware.vendor summary.hardware.model summary.hardware.cpuModel \
            summary.hardware.numCpuPkgs summary.hardware.numCpuCores summary.hardware.numCpuThreads \
            summary.hardware.memorySize \
            summary.config.product.version summary.config.product.build \
            summary.runtime.connectionState summary.runtime.powerState \
            parent)" \
    || { err "host query failed"; return 1; }
  printf '%s' "$raw" | "$JQ_BIN" --argjson lic "$licmap" "$JQ_OC_HELPERS"'
    [ .[] | . as $o | ($o.obj.value) as $mo | {
        name:             p($o;"name"),
        vendor:           (p($o;"summary.hardware.vendor") // null),
        model:            (p($o;"summary.hardware.model") // null),
        cpu_model:        (p($o;"summary.hardware.cpuModel") // null),
        sockets:          (p($o;"summary.hardware.numCpuPkgs") // 0),
        cores:            (p($o;"summary.hardware.numCpuCores") // 0),
        threads:          (p($o;"summary.hardware.numCpuThreads") // 0),
        memory_gib:       gib(p($o;"summary.hardware.memorySize")),
        esxi_version:     (p($o;"summary.config.product.version") // null),
        esxi_build:       (p($o;"summary.config.product.build") // null),
        connection_state: (p($o;"summary.runtime.connectionState") // null),
        power_state:      (p($o;"summary.runtime.powerState") // null),
        license_edition:  ($lic[$mo] // null),
        cluster_moref:    ((p($o;"parent")|.value) // null),
        moref:            $mo
      } ]' \
    | _write_category "$out" hosts "$HOST_CSV_KEYS"
}

# --- Standard (host) vSwitches & port groups with VLANs ---------------------
# Distributed port groups are captured in networks.csv; standard vSwitch port
# groups live in per-host network config and are reported per host here.
STDSW_CSV_KEYS="host,name,num_ports,mtu"
STDPG_CSV_KEYS="host,name,vlan_id,vswitch"
collect_standard_networking() {
  local out="$1" raw hostmap
  info "Collecting standard vSwitches & port groups ..."
  # host moref -> name, to label per-host rows.
  hostmap="$("$JQ_BIN" 'map({(.moref): .name}) | add // {}' "${out}/hosts.json" 2>/dev/null || echo '{}')"
  raw="$(oc_query host_networking h name config.network.vswitch config.network.portgroup 2>/dev/null)" \
    || { warn "host networking query failed — skipping standard switches/port groups";
         printf '[]' >"${out}/standard_switches.json"; : >"${out}/standard_switches.csv";
         printf '[]' >"${out}/standard_portgroups.json"; : >"${out}/standard_portgroups.csv"; return 0; }

  printf '%s' "$raw" | "$JQ_BIN" --argjson hm "$hostmap" "$JQ_OC_HELPERS"'
    [ .[] | . as $o | ($hm[$o.obj.value] // p($o;"name")) as $h
      | (p($o;"config.network.vswitch") // [])[]
      | { host: $h, name: .name, num_ports: (.numPorts // .spec.numPorts // 0), mtu: (.mtu // .spec.mtu // null) } ]' \
    | _write_category "$out" standard_switches "$STDSW_CSV_KEYS"

  printf '%s' "$raw" | "$JQ_BIN" --argjson hm "$hostmap" "$JQ_OC_HELPERS"'
    [ .[] | . as $o | ($hm[$o.obj.value] // p($o;"name")) as $h
      | (p($o;"config.network.portgroup") // [])[]
      | { host: $h, name: (.spec.name // .name), vlan_id: (.spec.vlanId // null), vswitch: (.spec.vswitchName // null) } ]' \
    | _write_category "$out" standard_portgroups "$STDPG_CSV_KEYS"
}

# --- Datastores -------------------------------------------------------------
DS_CSV_KEYS="name,type,capacity_gib,free_gib,used_gib,pct_used,vm_count,accessible,moref"
collect_datastores() {
  local out="$1" raw
  info "Collecting datastores ..."
  raw="$(oc_query datastores s \
            name summary.type summary.capacity summary.freeSpace summary.accessible vm)" \
    || { err "datastore query failed"; return 1; }
  printf '%s' "$raw" | "$JQ_BIN" "$JQ_OC_HELPERS"'
    [ .[] | . as $o
      | (p($o;"summary.capacity") // 0) as $cap
      | (p($o;"summary.freeSpace") // 0) as $free
      | {
          name:        p($o;"name"),
          type:        (p($o;"summary.type") // null),
          capacity_gib: gib($cap),
          free_gib:     gib($free),
          used_gib:     gib($cap - $free),
          pct_used:     (if ($cap|tonumber) > 0 then (( ($cap - $free) / $cap ) * 1000 | floor) / 10 else 0 end),
          vm_count:     ((p($o;"vm") // []) | length),
          accessible:   (p($o;"summary.accessible") // null),
          moref:        $o.obj.value
        } ]' \
    | _write_category "$out" datastores "$DS_CSV_KEYS"
}

# --- Distributed switches (vDS) ---------------------------------------------
DVS_CSV_KEYS="name,num_ports,version,uuid,moref"
collect_dvswitches() {
  local out="$1" raw
  info "Collecting distributed switches (vDS) ..."
  raw="$(oc_query dvswitches w \
            name summary.numPorts summary.productInfo.version uuid)" \
    || { warn "vDS query failed (none present, or unsupported) — skipping"; printf '[]' >"${out}/dvswitches.json"; : >"${out}/dvswitches.csv"; return 0; }
  printf '%s' "$raw" | "$JQ_BIN" "$JQ_OC_HELPERS"'
    [ .[] | . as $o | {
        name:      p($o;"name"),
        num_ports: (p($o;"summary.numPorts") // 0),
        version:   (p($o;"summary.productInfo.version") // null),
        uuid:      (p($o;"uuid") // null),
        moref:     $o.obj.value
      } ]' \
    | _write_category "$out" dvswitches "$DVS_CSV_KEYS"
}

# --- Networks (standard networks + distributed port groups) -----------------
# Produces one networks.csv combining both kinds. VLAN id is available for
# distributed port groups; standard Network objects carry name only at this
# level (per-host VLAN detail is collected with host networking later if needed).
# Switch names for dvportgroups are resolved from the dvswitches.json map.
NET_CSV_KEYS="name,kind,vlan_id,switch,moref"
collect_networks() {
  local out="$1" dvpg std switchmap
  info "Collecting networks / port groups ..."

  # moref -> name map for distributed switches (built from prior collection).
  switchmap="$("$JQ_BIN" 'map({(.moref): .name}) | add // {}' "${out}/dvswitches.json" 2>/dev/null || echo '{}')"

  dvpg="$(oc_query dvportgroups g \
            name config.defaultPortConfig.vlan.vlanId config.distributedVirtualSwitch 2>/dev/null \
          | "$JQ_BIN" --argjson sw "$switchmap" "$JQ_OC_HELPERS"'
            [ .[] | . as $o | {
                name:    p($o;"name"),
                kind:    "dvportgroup",
                vlan_id: (p($o;"config.defaultPortConfig.vlan.vlanId") // null),
                switch:  ( (p($o;"config.distributedVirtualSwitch").value) as $m | $sw[$m] // $m // null),
                moref:   $o.obj.value
              } ]' 2>/dev/null || echo '[]')"

  # `-type n` can also return DistributedVirtualPortgroup (a Network subtype);
  # restrict to exact type "Network" so port groups are not double-counted.
  std="$(oc_query standardnetworks n name 2>/dev/null \
          | "$JQ_BIN" "$JQ_OC_HELPERS"'
            [ .[] | . as $o | select($o.obj.type=="Network") | {
                name: p($o;"name"), kind: "standard", vlan_id: null, switch: null, moref: $o.obj.value
              } ]' 2>/dev/null || echo '[]')"

  "$JQ_BIN" -n --argjson a "${dvpg:-[]}" --argjson b "${std:-[]}" '$a + $b' \
    | _write_category "$out" networks "$NET_CSV_KEYS"
}

# --- Resource pools & vApps -------------------------------------------------
RP_CSV_KEYS="name,kind,cpu_reservation_mhz,cpu_limit_mhz,cpu_shares,mem_reservation_mib,mem_limit_mib,mem_shares,moref"
_rp_normalize() { # reads object.collect json, arg1 = kind label
  "$JQ_BIN" --arg kind "$1" "$JQ_OC_HELPERS"'
    [ .[] | . as $o | {
        name:                p($o;"name"),
        kind:                $kind,
        cpu_reservation_mhz: (p($o;"config.cpuAllocation.reservation") // 0),
        cpu_limit_mhz:       (p($o;"config.cpuAllocation.limit") // -1),
        cpu_shares:          (p($o;"config.cpuAllocation.shares.shares") // null),
        mem_reservation_mib: (p($o;"config.memoryAllocation.reservation") // 0),
        mem_limit_mib:       (p($o;"config.memoryAllocation.limit") // -1),
        mem_shares:          (p($o;"config.memoryAllocation.shares.shares") // null),
        moref:               $o.obj.value
      } ]'
}
RP_PROPS=(name config.cpuAllocation.reservation config.cpuAllocation.limit config.cpuAllocation.shares.shares
          config.memoryAllocation.reservation config.memoryAllocation.limit config.memoryAllocation.shares.shares)
collect_resource_pools() {
  local out="$1" pools vapps
  info "Collecting resource pools & vApps ..."
  pools="$(oc_query resourcepools p "${RP_PROPS[@]}" 2>/dev/null | _rp_normalize "resourcePool" 2>/dev/null || echo '[]')"
  vapps="$(oc_query vapps a "${RP_PROPS[@]}" 2>/dev/null | _rp_normalize "vApp" 2>/dev/null || echo '[]')"
  "$JQ_BIN" -n --argjson a "${pools:-[]}" --argjson b "${vapps:-[]}" '$a + $b' \
    | _write_category "$out" resourcepools "$RP_CSV_KEYS"
}

# --- Orchestrator -----------------------------------------------------------
# Runs every infra category; a failure in one is logged and does not abort.
collect_infra() {
  local out="$1"
  collect_datacenters       "$out" || true
  collect_clusters          "$out" || true
  collect_licenses          "$out" || true
  collect_hosts             "$out" || true
  collect_standard_networking "$out" || true
  collect_datastores        "$out" || true
  collect_dvswitches        "$out" || true
  collect_networks          "$out" || true
  collect_resource_pools    "$out" || true
}
