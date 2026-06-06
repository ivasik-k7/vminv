#!/usr/bin/env bash
#
# lib/rightsize.sh — candidate cloud instance per VM + licensing flags.
#
# Right-sizing uses observed demand (p95 CPU/RAM) where utilization history
# exists, otherwise the configured capacity (flagged as such). It sizes so the
# p95 demand sits at ~70% of the chosen instance (a headroom buffer), then picks
# the smallest matrix instance that fits. Matrices are editable CSVs in matrices/.
#
# Licensing flags surface BYOL-vs-license-included decisions (Windows Server,
# SQL Server, Oracle) detected from guest OS / name / annotation.
#
# Sourced by vminv; requires lib/common.sh and prior collect_vms (+ optional perf).

RIGHTSIZE_CSV_KEYS="vm,basis,configured_vcpu,configured_mem_gib,p95_cpu_pct,p95_mem_gib,req_vcpu,req_mem_gib,candidate_instance,candidate_vcpu,candidate_mem_gib,fits,vm_moref"
LICENSING_CSV_KEYS="vm,windows_server,sql_server,oracle,note,vm_moref"

# Headroom: target that p95 demand occupies this fraction of the instance.
RIGHTSIZE_TARGET_UTIL="${RIGHTSIZE_TARGET_UTIL:-0.7}"

_load_instance_matrix() { # _load_instance_matrix <target> -> JSON array (numeric, sorted)
  local target="$1" f="${ROOT_DIR}/matrices/instance_types_${1}.csv"
  [ -f "$f" ] || { echo '[]'; return 0; }
  csv_to_json <"$f" | "$JQ_BIN" '
    [ .[] | { instance_type, family, note,
              vcpu: (.vcpu|tonumber), mem_gib: (.mem_gib|tonumber) } ]
    | sort_by(.vcpu, .mem_gib)'
}

compute_rightsizing() { # compute_rightsizing <out_dir> <target>
  local out="$1" target="$2" matrix util
  [ -f "${out}/vms.json" ] || { printf '[]' >"${out}/rightsizing.json"; : >"${out}/rightsizing.csv"; return 0; }
  info "Right-sizing VMs for ${target} ..."
  matrix="$(_load_instance_matrix "$target")"
  util="$("$JQ_BIN" 'map({key:.vm_moref, value:.}) | from_entries' "${out}/utilization.json" 2>/dev/null || echo '{}')"

  "$JQ_BIN" --argjson mx "$matrix" --argjson util "$util" --argjson tgt "$RIGHTSIZE_TARGET_UTIL" '
    def ceil_pos($x): ($x | if . <= 0 then 1 else (.|ceil) end);
    # smallest instance that satisfies vcpu+mem; null if matrix empty
    def pick($vcpu; $mem):
      ([ $mx[] | select(.vcpu >= $vcpu and .mem_gib >= $mem) ] | .[0]) as $fit
      | if $fit != null then ($fit + {fits:true})
        elif ($mx|length) > 0 then ($mx[-1] + {fits:false})
        else null end;
    [ .[]
      | . as $v
      | ($util[$v.moref]) as $u
      | ($v.vcpu // 1) as $cv
      | (((($v.memory_mb // 0)|tonumber)/1024)) as $cm
      | (if ($u != null and ($u.insufficient_data|not)) then "p95" else "configured" end) as $basis
      | (if $basis=="p95" then ceil_pos(($cv * (($u.cpu_pct_p95 // 0)/100)) / $tgt) else $cv end) as $rv
      | (if $basis=="p95" then ceil_pos(((($u.mem_mb_p95 // 0)/1024)) / $tgt) else ($cm|ceil) end) as $rm
      | (pick($rv; $rm)) as $cand
      | {
          vm: $v.name, vm_moref: $v.moref, basis: $basis,
          configured_vcpu: $cv, configured_mem_gib: (($cm*10|round)/10),
          p95_cpu_pct: (if $basis=="p95" then $u.cpu_pct_p95 else null end),
          p95_mem_gib: (if $basis=="p95" then ((($u.mem_mb_p95 // 0)/1024*10|round)/10) else null end),
          req_vcpu: $rv, req_mem_gib: $rm,
          candidate_instance: ($cand.instance_type // null),
          candidate_vcpu: ($cand.vcpu // null),
          candidate_mem_gib: ($cand.mem_gib // null),
          fits: ($cand.fits // false)
        } ]' "${out}/vms.json" \
    | tee "${out}/rightsizing.json" \
    | json_to_csv "$RIGHTSIZE_CSV_KEYS" >"${out}/rightsizing.csv"
  ok "Right-sizing: $(csv_count_rows "${out}/rightsizing.csv") VM(s)"
}

compute_licensing() { # compute_licensing <out_dir>
  local out="$1"
  [ -f "${out}/vms.json" ] || { printf '[]' >"${out}/licensing.json"; : >"${out}/licensing.csv"; return 0; }
  "$JQ_BIN" '
    [ .[]
      | . as $v
      | (([$v.guest_os, $v.name, $v.annotation] | map(. // "") | join(" ")) | ascii_downcase) as $t
      | ($t | test("windows server")) as $ws
      | ($t | test("sql server|sqlserver")) as $sql
      | ($t | test("oracle")) as $ora
      | select($ws or $sql or $ora)
      | { vm: $v.name, vm_moref: $v.moref,
          windows_server: $ws, sql_server: $sql, oracle: $ora,
          note: ([ (if $ws then "Windows Server (BYOL vs license-included)" else empty end),
                   (if $sql then "SQL Server licensing — verify edition/cores" else empty end),
                   (if $ora then "Oracle licensing — review carefully (core factor)" else empty end) ] | join("; ")) } ]' \
    "${out}/vms.json" \
    | tee "${out}/licensing.json" \
    | json_to_csv "$LICENSING_CSV_KEYS" >"${out}/licensing.csv"
  ok "Licensing considerations: $(csv_count_rows "${out}/licensing.csv") VM(s)"
}
