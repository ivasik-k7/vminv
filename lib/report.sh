#!/usr/bin/env bash
#
# lib/report.sh — human-readable assessment report (summary.md + summary.html).
#
# Aggregates the collected tables into a single report model, then renders a
# Markdown report (primary) and a lightweight styled HTML version. Covers estate
# totals, right-sizing rollup, migration-readiness breakdown, top blockers, and
# per-cluster / per-datastore rollups.
#
# Sourced by vminv; requires lib/common.sh and prior collect/analyze/rightsize.

# Build the report model JSON from the run's tables.
_report_model() { # _report_model <out_dir> <target>
  local d="$1" target="$2"
  "$JQ_BIN" -n \
    --argjson vcenter   "$(cat "${d}/vcenter.json"     2>/dev/null || echo '{}')" \
    --argjson vms       "$(cat "${d}/vms.json"         2>/dev/null || echo '[]')" \
    --argjson blockers  "$(cat "${d}/blockers.json"    2>/dev/null || echo '[]')" \
    --argjson clusters  "$(cat "${d}/clusters.json"    2>/dev/null || echo '[]')" \
    --argjson datastores "$(cat "${d}/datastores.json" 2>/dev/null || echo '[]')" \
    --argjson rs        "$(cat "${d}/rightsizing.json" 2>/dev/null || echo '[]')" \
    --argjson lic       "$(cat "${d}/licensing.json"   2>/dev/null || echo '[]')" \
    --arg target "$target" --arg generated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
    def sumby(f): (map(f) | add) // 0;
    {
      meta: {
        vcenter: ($vcenter.name // "vCenter"), version: ($vcenter.version // "?"),
        build: ($vcenter.build // "?"), target: $target, generated_at: $generated
      },
      totals: {
        vms: ($vms|length),
        powered_on: ([ $vms[] | select(.power_state=="poweredOn") ] | length),
        templates: ([ $vms[] | select(.template==true) ] | length),
        total_vcpu: ($vms | sumby(.vcpu // 0)),
        total_mem_gib: (($vms | sumby(.memory_mb // 0)) / 1024 | floor),
        provisioned_gib: ($vms | sumby(.provisioned_gib // 0) | floor),
        used_gib: ($vms | sumby(.used_gib // 0) | floor)
      },
      rightsizing: {
        sized_on_p95: ([ $rs[] | select(.basis=="p95") ] | length),
        sized_on_configured: ([ $rs[] | select(.basis=="configured") ] | length),
        configured_vcpu: ($rs | sumby(.configured_vcpu // 0)),
        recommended_vcpu: ($rs | sumby(.req_vcpu // 0)),
        configured_mem_gib: ($rs | sumby(.configured_mem_gib // 0) | floor),
        recommended_mem_gib: ($rs | sumby(.req_mem_gib // 0) | floor),
        no_fit: ([ $rs[] | select(.fits==false) ] | length)
      },
      readiness: {
        ready:      ([ $vms[] | select(.migration_status=="ready") ] | length),
        needs_work: ([ $vms[] | select(.migration_status=="needs-work") ] | length),
        blocked:    ([ $vms[] | select(.migration_status=="blocked") ] | length)
      },
      top_blockers: (
        $blockers | group_by(.blocker)
        | map({ blocker: .[0].blocker, severity: .[0].severity, count: length })
        | sort_by(({"high":3,"medium":2,"low":1}[.severity]) * -1000 + (-.count)) ),
      per_cluster: (
        ($vms | group_by(.cluster // "(none)"))
        | map({ cluster: (.[0].cluster // "(none)"),
                vms: length,
                vcpu: (map(.vcpu // 0)|add),
                mem_gib: ((map(.memory_mb // 0)|add)/1024|floor),
                blocked: ([ .[] | select(.migration_status=="blocked") ]|length) })
        | sort_by(-.vms) ),
      per_datastore: (
        $datastores | map({ name, type, capacity_gib, used_gib, pct_used, vm_count })
        | sort_by(-.used_gib) ),
      licensing: {
        windows_server: ([ $lic[] | select(.windows_server) ] | length),
        sql_server:     ([ $lic[] | select(.sql_server) ] | length),
        oracle:         ([ $lic[] | select(.oracle) ] | length)
      },
      blocked_vms: ([ $vms[] | select(.migration_status=="blocked") | {name, cluster, blocker_count} ] | sort_by(-.blocker_count))
    }'
}

_render_markdown() { # stdin: model JSON
  "$JQ_BIN" -r '
    def pct($n;$d): if ($d|tonumber) > 0 then (($n/$d*1000|round)/10|tostring) + "%" else "—" end;
    .meta as $m | .totals as $t | .rightsizing as $r | .readiness as $rd |
    "# vminv — VMware → \($m.target|ascii_upcase) Migration Assessment",
    "",
    "**\($m.vcenter)** \(.meta.version) (build \($m.build)) · generated \($m.generated_at)",
    "",
    "## Estate totals",
    "",
    "| Metric | Value |",
    "|---|---|",
    "| VMs (powered on) | \($t.vms) (\($t.powered_on)) |",
    "| Templates | \($t.templates) |",
    "| Total vCPU | \($t.total_vcpu) |",
    "| Total configured RAM | \($t.total_mem_gib) GiB |",
    "| Provisioned storage | \($t.provisioned_gib) GiB |",
    "| Used storage | \($t.used_gib) GiB (\(pct($t.used_gib; $t.provisioned_gib)) of provisioned) |",
    "",
    "## Migration readiness",
    "",
    "| Status | VMs | Share |",
    "|---|---|---|",
    "| ✅ Ready | \($rd.ready) | \(pct($rd.ready; $t.vms)) |",
    "| ⚠️ Needs work | \($rd.needs_work) | \(pct($rd.needs_work; $t.vms)) |",
    "| ⛔ Blocked | \($rd.blocked) | \(pct($rd.blocked; $t.vms)) |",
    "",
    "## Right-sizing rollup",
    "",
    "_Sized on observed p95 for \($r.sized_on_p95) VM(s); on configured capacity for \($r.sized_on_configured) (insufficient history)._",
    "",
    "| Resource | Configured | Recommended (p95+headroom) |",
    "|---|---|---|",
    "| vCPU (sum) | \($r.configured_vcpu) | \($r.recommended_vcpu) |",
    "| RAM GiB (sum) | \($r.configured_mem_gib) | \($r.recommended_mem_gib) |",
    (if $r.no_fit > 0 then "\n> ⚠️ \($r.no_fit) VM(s) exceed the largest instance in the matrix — review manually." else empty end),
    "",
    "## Top blockers",
    "",
    (if (.top_blockers|length)==0 then "_No blockers detected._" else
      ( "| Severity | Blocker | VMs |", "|---|---|---|",
        (.top_blockers[] | "| \(.severity) | \(.blocker) | \(.count) |") ) end),
    "",
    "## Per-cluster rollup",
    "",
    "| Cluster | VMs | vCPU | RAM GiB | Blocked |",
    "|---|---|---|---|---|",
    (.per_cluster[] | "| \(.cluster) | \(.vms) | \(.vcpu) | \(.mem_gib) | \(.blocked) |"),
    "",
    "## Per-datastore rollup",
    "",
    "| Datastore | Type | Capacity GiB | Used GiB | % | VMs |",
    "|---|---|---|---|---|---|",
    (.per_datastore[] | "| \(.name) | \(.type) | \(.capacity_gib) | \(.used_gib) | \(.pct_used)% | \(.vm_count) |"),
    "",
    "## Licensing considerations",
    "",
    "| Type | VMs |",
    "|---|---|",
    "| Windows Server | \(.licensing.windows_server) |",
    "| SQL Server | \(.licensing.sql_server) |",
    "| Oracle | \(.licensing.oracle) |",
    "",
    (if (.blocked_vms|length)>0 then
      ("## Blocked VMs", "", "| VM | Cluster | Blockers |", "|---|---|---|",
       (.blocked_vms[] | "| \(.name) | \(.cluster // "—") | \(.blocker_count) |")) else empty end),
    "",
    "---",
    "_Generated by vminv (read-only). CSV/JSON tables accompany this report in the same directory._"
  '
}

_render_html() { # stdin: model JSON
  "$JQ_BIN" -r '
    def pct($n;$d): if ($d|tonumber) > 0 then (($n/$d*1000|round)/10|tostring) + "%" else "—" end;
    .meta as $m | .totals as $t | .rightsizing as $r | .readiness as $rd |
    "<!doctype html><html><head><meta charset=\"utf-8\"><title>vminv assessment — \($m.vcenter)</title>",
    "<style>body{font:14px/1.5 system-ui,sans-serif;max-width:980px;margin:2rem auto;padding:0 1rem;color:#1a1a1a}h1{font-size:1.5rem}h2{margin-top:2rem;border-bottom:1px solid #ddd;padding-bottom:.3rem}table{border-collapse:collapse;width:100%;margin:.5rem 0}th,td{border:1px solid #ddd;padding:6px 10px;text-align:left}th{background:#f5f5f7}.ready{color:#137333}.warn{color:#b06000}.blocked{color:#c5221f}.muted{color:#666}</style></head><body>",
    "<h1>VMware → \($m.target|ascii_upcase) Migration Assessment</h1>",
    "<p><strong>\($m.vcenter)</strong> \($m.version) (build \($m.build)) · generated \($m.generated_at)</p>",
    "<h2>Estate totals</h2><table><tr><th>Metric</th><th>Value</th></tr>",
    "<tr><td>VMs (powered on)</td><td>\($t.vms) (\($t.powered_on))</td></tr>",
    "<tr><td>Total vCPU</td><td>\($t.total_vcpu)</td></tr>",
    "<tr><td>Total configured RAM</td><td>\($t.total_mem_gib) GiB</td></tr>",
    "<tr><td>Provisioned / Used storage</td><td>\($t.provisioned_gib) / \($t.used_gib) GiB (\(pct($t.used_gib;$t.provisioned_gib)))</td></tr></table>",
    "<h2>Migration readiness</h2><table><tr><th>Status</th><th>VMs</th><th>Share</th></tr>",
    "<tr><td class=\"ready\">Ready</td><td>\($rd.ready)</td><td>\(pct($rd.ready;$t.vms))</td></tr>",
    "<tr><td class=\"warn\">Needs work</td><td>\($rd.needs_work)</td><td>\(pct($rd.needs_work;$t.vms))</td></tr>",
    "<tr><td class=\"blocked\">Blocked</td><td>\($rd.blocked)</td><td>\(pct($rd.blocked;$t.vms))</td></tr></table>",
    "<h2>Right-sizing rollup</h2><p class=\"muted\">p95 for \($r.sized_on_p95) VM(s); configured for \($r.sized_on_configured).</p>",
    "<table><tr><th>Resource</th><th>Configured</th><th>Recommended</th></tr>",
    "<tr><td>vCPU (sum)</td><td>\($r.configured_vcpu)</td><td>\($r.recommended_vcpu)</td></tr>",
    "<tr><td>RAM GiB (sum)</td><td>\($r.configured_mem_gib)</td><td>\($r.recommended_mem_gib)</td></tr></table>",
    "<h2>Top blockers</h2><table><tr><th>Severity</th><th>Blocker</th><th>VMs</th></tr>",
    (.top_blockers[] | "<tr><td>\(.severity)</td><td>\(.blocker)</td><td>\(.count)</td></tr>"),
    "</table><h2>Per-cluster</h2><table><tr><th>Cluster</th><th>VMs</th><th>vCPU</th><th>RAM GiB</th><th>Blocked</th></tr>",
    (.per_cluster[] | "<tr><td>\(.cluster)</td><td>\(.vms)</td><td>\(.vcpu)</td><td>\(.mem_gib)</td><td>\(.blocked)</td></tr>"),
    "</table><h2>Per-datastore</h2><table><tr><th>Datastore</th><th>Type</th><th>Capacity</th><th>Used</th><th>%</th><th>VMs</th></tr>",
    (.per_datastore[] | "<tr><td>\(.name)</td><td>\(.type)</td><td>\(.capacity_gib)</td><td>\(.used_gib)</td><td>\(.pct_used)%</td><td>\(.vm_count)</td></tr>"),
    "</table><h2>Licensing</h2><table><tr><th>Type</th><th>VMs</th></tr>",
    "<tr><td>Windows Server</td><td>\(.licensing.windows_server)</td></tr>",
    "<tr><td>SQL Server</td><td>\(.licensing.sql_server)</td></tr>",
    "<tr><td>Oracle</td><td>\(.licensing.oracle)</td></tr></table>",
    "<p class=\"muted\">Generated by vminv (read-only).</p></body></html>"
  '
}

# generate_report <out_dir> <target>
generate_report() {
  local out="$1" target="$2" model
  model="$(_report_model "$out" "$target")" || { err "Report model build failed."; return 1; }
  printf '%s' "$model" | _render_markdown >"${out}/summary.md"
  printf '%s' "$model" | _render_html >"${out}/summary.html"
  ok "Report: summary.md, summary.html"
}
