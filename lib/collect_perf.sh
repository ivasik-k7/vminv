#!/usr/bin/env bash
#
# lib/collect_perf.sh — utilization / right-sizing data collection.
#
# Pulls historical performance counters for every VM over PERF_WINDOW_DAYS and
# computes avg / peak / p95 for CPU, memory, disk and network. These feed
# right-sizing (Stage 7) so the migration is sized on real demand, not on the
# configured (often over-provisioned) capacity.
#
# Performance data is per-entity (the property collector cannot return it), so
# this is the one place we issue many queries — we BATCH VMs per metric.sample
# call and show progress. VMs with no usable history are flagged
# "insufficient_data" and later sized on configured capacity.
#
# govc metric.sample -json output shape (counters as int arrays per entity) is
# parsed in one isolated jq block; live-format variance is a localized fix.
#
# Sourced by vminv; requires lib/common.sh and a prior collect_vms run.

# Counters requested (govc/vSphere names). Units handled in jq below.
PERF_COUNTERS=(
  cpu.usage.average cpu.usagemhz.average
  mem.consumed.average mem.active.average mem.usage.average
  disk.usage.average disk.numberReadAveraged.average disk.numberWriteAveraged.average
  disk.maxTotalLatency.latest
  net.usage.average
)

UTIL_CSV_KEYS="vm,vm_moref,window_days,interval_s,samples,insufficient_data,cpu_pct_avg,cpu_pct_peak,cpu_pct_p95,cpu_mhz_avg,cpu_mhz_peak,cpu_mhz_p95,mem_mb_avg,mem_mb_peak,mem_mb_p95,mem_active_mb_p95,mem_pct_p95,disk_iops_avg,disk_iops_peak,disk_kbps_avg,disk_kbps_peak,disk_latency_ms_peak,net_kbps_avg,net_kbps_peak"

# Map PERF_INTERVAL -> vSphere historical sample period (seconds).
perf_interval_seconds() {
  case "${PERF_INTERVAL:-daily}" in
    realtime) echo 300 ;;     # 5-minute (short retention)
    daily)    echo 86400 ;;   # one sample/day — good for long windows
    weekly)   echo 7200 ;;    # 2-hour (≈ past-month granularity)
    monthly)  echo 7200 ;;
    *)        echo 86400 ;;
  esac
}

# jq prelude: stats over an int array, ignoring negative "no data" markers.
JQ_PERF_HELPERS='
  def r1: if . == null then null else (. * 10 | round) / 10 end;
  def stat($arr):
    ([ ($arr // [])[]? | select(. != null and . >= 0) ]) as $v
    | if ($v | length) == 0 then { avg: null, peak: null, p95: null, n: 0 }
      else ($v | sort) as $s
      | ($s | length) as $len
      | ((($len * 0.95) | ceil) - 1) as $raw
      | (if $raw < 0 then 0 elif $raw >= $len then ($len - 1) else $raw end) as $i
      | { avg: (($v | add) / $len), peak: ($v | max), p95: $s[$i], n: $len } end;
  # pull the aggregate-instance series for a counter from one entity metric obj
  def series($e; $ctr):
    ( ((($e.value // $e.Value) // [])[]
       | select(((.name // .Name) == $ctr) and (((.instance // .Instance) // "") == ""))
       | (.value // .Value)) // [] ) | (if type=="array" then . else [] end);
'

# Resolve VM inventory paths to sample (live mode only).
_perf_vm_paths() {
  local root; root="$(vms_scope_root)"
  govc_ro find "$root" -type m 2>/dev/null
}

# collect_perf <out_dir>
collect_perf() {
  local out="$1" iv n raw vmsjson
  [ -f "${out}/vms.json" ] || { warn "No vms.json; skipping utilization."; printf '[]' >"${out}/utilization.json"; : >"${out}/utilization.csv"; return 0; }
  vmsjson="$(cat "${out}/vms.json")"
  iv="$(perf_interval_seconds)"
  n=$(( (PERF_WINDOW_DAYS * 86400) / iv )); [ "$n" -lt 1 ] && n=1; [ "$n" -gt 1000 ] && n=1000
  info "Collecting utilization over ${PERF_WINDOW_DAYS}d (interval ${iv}s, up to ${n} samples/VM) ..."

  if [ -n "${VMINV_FIXTURES:-}" ]; then
    raw="$(cat "${VMINV_FIXTURES}/perf.json" 2>/dev/null || echo '[]')"
  else
    # Live: batch VM paths through metric.sample to bound the number of calls.
    local -a paths=(); local p
    while IFS= read -r p; do [ -n "$p" ] && paths+=("$p"); done < <(_perf_vm_paths)
    local total="${#paths[@]}"
    if [ "$total" -eq 0 ]; then warn "No VM paths found for perf."; printf '[]' >"${out}/utilization.json"; : >"${out}/utilization.csv"; return 0; fi
    local batch=40 i=0 chunks="" part
    while [ "$i" -lt "$total" ]; do
      progress "utilization $((i)) / ${total}"
      local slice=("${paths[@]:i:batch}")
      part="$(govc_ro metric.sample -json -i "$iv" -n "$n" "${slice[@]}" "${PERF_COUNTERS[@]}" 2>/dev/null || echo '[]')"
      # metric.sample may wrap results under .sample; normalize to a flat array
      part="$(printf '%s' "$part" | "$JQ_BIN" 'if type=="object" then (.sample // .Sample // []) else . end' 2>/dev/null || echo '[]')"
      chunks="${chunks}${part}"$'\n'
      i=$(( i + batch ))
    done
    raw="$(printf '%s' "$chunks" | "$JQ_BIN" -s 'add // []' 2>/dev/null || echo '[]')"
  fi

  printf '%s' "$vmsjson" | "$JQ_BIN" \
      --argjson perf "$raw" --argjson win "$PERF_WINDOW_DAYS" --argjson iv "$iv" \
      "$JQ_PERF_HELPERS"'
    ( [ ($perf[]?) | { key: (((.entity // .Entity) // {}) | (.value // .Value // "")), value: . } ]
      | from_entries ) as $pm
    | [ .[]
        | .name as $vm | .moref as $mo
        | ($pm[$mo]) as $e
        | (if $e == null then [] else series($e; "cpu.usage.average") end) as $cpu
        | (stat($cpu)) as $cpus
        | (stat(if $e==null then [] else series($e;"cpu.usagemhz.average") end)) as $mhz
        | (stat(if $e==null then [] else series($e;"mem.consumed.average") end)) as $memc
        | (stat(if $e==null then [] else series($e;"mem.active.average") end)) as $mema
        | (stat(if $e==null then [] else series($e;"mem.usage.average") end)) as $memp
        | (stat(if $e==null then [] else series($e;"disk.numberReadAveraged.average") end)) as $rd
        | (stat(if $e==null then [] else series($e;"disk.numberWriteAveraged.average") end)) as $wr
        | (stat(if $e==null then [] else series($e;"disk.usage.average") end)) as $dkb
        | (stat(if $e==null then [] else series($e;"disk.maxTotalLatency.latest") end)) as $lat
        | (stat(if $e==null then [] else series($e;"net.usage.average") end)) as $net
        | {
            vm: $vm, vm_moref: $mo, window_days: $win, interval_s: $iv,
            samples: $cpus.n,
            insufficient_data: ($cpus.n == 0),
            cpu_pct_avg:  (($cpus.avg  // null) | if .==null then null else (./100) end | r1),
            cpu_pct_peak: (($cpus.peak // null) | if .==null then null else (./100) end | r1),
            cpu_pct_p95:  (($cpus.p95  // null) | if .==null then null else (./100) end | r1),
            cpu_mhz_avg:  ($mhz.avg  | r1), cpu_mhz_peak: $mhz.peak, cpu_mhz_p95: ($mhz.p95 | r1),
            mem_mb_avg:   (($memc.avg  // null) | if .==null then null else (./1024) end | r1),
            mem_mb_peak:  (($memc.peak // null) | if .==null then null else (./1024) end | r1),
            mem_mb_p95:   (($memc.p95  // null) | if .==null then null else (./1024) end | r1),
            mem_active_mb_p95: (($mema.p95 // null) | if .==null then null else (./1024) end | r1),
            mem_pct_p95:  (($memp.p95 // null) | if .==null then null else (./100) end | r1),
            disk_iops_avg:  (if ($rd.n + $wr.n) == 0 then null else ((($rd.avg // 0) + ($wr.avg // 0)) | r1) end),
            disk_iops_peak: (if ($rd.n + $wr.n) == 0 then null else (($rd.peak // 0) + ($wr.peak // 0)) end),
            disk_kbps_avg:  ($dkb.avg | r1), disk_kbps_peak: $dkb.peak,
            disk_latency_ms_peak: $lat.peak,
            net_kbps_avg: ($net.avg | r1), net_kbps_peak: $net.peak
          } ]' \
    | tee "${out}/utilization.json" \
    | json_to_csv "$UTIL_CSV_KEYS" >"${out}/utilization.csv"

  local got; got="$("$JQ_BIN" '[ .[] | select(.insufficient_data | not) ] | length' "${out}/utilization.json" 2>/dev/null || echo 0)"
  local tot; tot="$("$JQ_BIN" 'length' "${out}/utilization.json" 2>/dev/null || echo 0)"
  ok "Utilization: ${got}/${tot} VMs with usable history (rest sized on configured capacity)"
}
