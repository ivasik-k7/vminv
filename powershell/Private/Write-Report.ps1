# Write-Report.ps1 — summary.md + summary.html, mirroring lib/report.sh.
# Renders the exact same content so the Markdown is byte-identical (modulo the
# generated-at timestamp line, which is wall-clock).

function _pct($n, $d) {
  if ([double]$d -gt 0) { return ("" + (As-JqNum ([math]::Round([double]$n / [double]$d * 1000, [MidpointRounding]::AwayFromZero) / 10)) + "%") }
  return '—'
}
function _floorSum($items, [string]$prop) {
  $s = 0.0; foreach ($i in $items) { $s += [double]($i.$prop ?? 0) }; return [long][math]::Floor($s)
}
function _sum($items, [string]$prop) { $s = 0.0; foreach ($i in $items) { $s += [double]($i.$prop ?? 0) }; return (As-JqNum $s) }

function Get-ReportModel([string]$OutDir, [string]$Target) {
  $rd = { param($f) $p = Join-Path $OutDir $f; if (Test-Path $p) { @(ConvertFrom-JsonKeepStrings (Get-Content -Raw $p)) } else { @() } }
  # vCenter identity: vcenter.json if present (live/bash), else the about fixture.
  $vc = if (Test-Path (Join-Path $OutDir 'vcenter.json')) {
    ConvertFrom-JsonKeepStrings (Get-Content -Raw (Join-Path $OutDir 'vcenter.json'))
  } else {
    $ab = Get-RoJson 'about'
    if ($ab) { if ($ab.PSObject.Properties['about']) { $ab.about } else { $ab.About } } else { $null }
  }
  function _vp($o, $n, $d) { if ($o -and $o.PSObject.Properties[$n]) { $o.$n } else { $d } }
  $vms = & $rd 'vms.json'; $blk = & $rd 'blockers.json'; $cl = & $rd 'clusters.json'
  $ds = & $rd 'datastores.json'; $rs = & $rd 'rightsizing.json'; $lic = & $rd 'licensing.json'
  $rank = @{ high = 3; medium = 2; low = 1 }

  # top blockers: group by blocker; sort rank desc, count desc, blocker asc
  $tb = $blk | Group-Object blocker | ForEach-Object {
    [pscustomobject]@{ blocker = $_.Name; severity = $_.Group[0].severity; count = $_.Count }
  } | Sort-Object @{e = { $rank[$_.severity] }; Descending = $true }, @{e = 'count'; Descending = $true }, @{e = 'blocker'; Descending = $false }

  # per cluster: group by cluster (null -> "(none)"); sort vms desc, cluster asc
  $pc = $vms | Group-Object { $_.cluster ?? '(none)' } | ForEach-Object {
    $g = $_.Group
    [pscustomobject]@{ cluster = $_.Name; vms = $_.Count
      vcpu = [long](( $g | Measure-Object -Property vcpu -Sum).Sum)
      mem_gib = [long][math]::Floor((($g | Measure-Object -Property memory_mb -Sum).Sum) / 1024)
      blocked = @($g | Where-Object { $_.migration_status -eq 'blocked' }).Count }
  } | Sort-Object @{e = 'vms'; Descending = $true }, @{e = 'cluster'; Descending = $false }

  # per datastore: sort used_gib desc, original order tiebreak
  $i = 0
  $pd = $ds | ForEach-Object { [pscustomobject]@{ name = $_.name; type = $_.type; capacity_gib = $_.capacity_gib; used_gib = $_.used_gib; pct_used = $_.pct_used; vm_count = $_.vm_count; _i = ($i++) } } |
    Sort-Object @{e = { [double]$_.used_gib }; Descending = $true }, @{e = '_i'; Descending = $false }

  $j = 0
  $bv = $vms | Where-Object { $_.migration_status -eq 'blocked' } | ForEach-Object { [pscustomobject]@{ name = $_.name; cluster = $_.cluster; blocker_count = $_.blocker_count; _i = ($j++) } } |
    Sort-Object @{e = { [long]$_.blocker_count }; Descending = $true }, @{e = '_i'; Descending = $false }

  [pscustomobject]@{
    meta = [pscustomobject]@{ vcenter = (_vp $vc 'name' 'vCenter'); version = (_vp $vc 'version' '?'); build = (_vp $vc 'build' '?'); target = $Target; generated_at = ([DateTimeOffset]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")) }
    totals = [pscustomobject]@{ vms = $vms.Count; powered_on = @($vms | Where-Object { $_.power_state -eq 'poweredOn' }).Count
      templates = @($vms | Where-Object { $_.template -eq $true }).Count
      total_vcpu = [long]((($vms | Measure-Object -Property vcpu -Sum).Sum)); total_mem_gib = [long][math]::Floor((($vms | Measure-Object -Property memory_mb -Sum).Sum) / 1024)
      provisioned_gib = (_floorSum $vms 'provisioned_gib'); used_gib = (_floorSum $vms 'used_gib') }
    rightsizing = [pscustomobject]@{ sized_on_p95 = @($rs | Where-Object { $_.basis -eq 'p95' }).Count; sized_on_configured = @($rs | Where-Object { $_.basis -eq 'configured' }).Count
      configured_vcpu = (_sum $rs 'configured_vcpu'); recommended_vcpu = (_sum $rs 'req_vcpu')
      configured_mem_gib = (_floorSum $rs 'configured_mem_gib'); recommended_mem_gib = (_floorSum $rs 'req_mem_gib'); no_fit = @($rs | Where-Object { $_.fits -eq $false }).Count }
    readiness = [pscustomobject]@{ ready = @($vms | Where-Object { $_.migration_status -eq 'ready' }).Count; needs_work = @($vms | Where-Object { $_.migration_status -eq 'needs-work' }).Count; blocked = @($vms | Where-Object { $_.migration_status -eq 'blocked' }).Count }
    top_blockers = @($tb); per_cluster = @($pc); per_datastore = @($pd)
    licensing = [pscustomobject]@{ windows_server = @($lic | Where-Object { $_.windows_server }).Count; sql_server = @($lic | Where-Object { $_.sql_server }).Count; oracle = @($lic | Where-Object { $_.oracle }).Count }
    blocked_vms = @($bv)
  }
}

function _correctMemGib { } # placeholder (kept for diff stability)

function Write-Report([string]$OutDir, [string]$Target) {
  $m = Get-ReportModel $OutDir $Target
  $L = [System.Collections.Generic.List[string]]::new()
  $t = $m.totals; $r = $m.rightsizing; $rd = $m.readiness
  $L.Add("# vminv — VMware → $($Target.ToUpper()) Migration Assessment")
  $L.Add("")
  $L.Add("**$($m.meta.vcenter)** $($m.meta.version) (build $($m.meta.build)) · generated $($m.meta.generated_at)")
  $L.Add("")
  $L.Add("## Estate totals"); $L.Add(""); $L.Add("| Metric | Value |"); $L.Add("|---|---|")
  $L.Add("| VMs (powered on) | $($t.vms) ($($t.powered_on)) |")
  $L.Add("| Templates | $($t.templates) |")
  $L.Add("| Total vCPU | $($t.total_vcpu) |")
  $L.Add("| Total configured RAM | $($t.total_mem_gib) GiB |")
  $L.Add("| Provisioned storage | $($t.provisioned_gib) GiB |")
  $L.Add("| Used storage | $($t.used_gib) GiB ($(_pct $t.used_gib $t.provisioned_gib) of provisioned) |")
  $L.Add(""); $L.Add("## Migration readiness"); $L.Add(""); $L.Add("| Status | VMs | Share |"); $L.Add("|---|---|---|")
  $L.Add("| ✅ Ready | $($rd.ready) | $(_pct $rd.ready $t.vms) |")
  $L.Add("| ⚠️ Needs work | $($rd.needs_work) | $(_pct $rd.needs_work $t.vms) |")
  $L.Add("| ⛔ Blocked | $($rd.blocked) | $(_pct $rd.blocked $t.vms) |")
  $L.Add(""); $L.Add("## Right-sizing rollup"); $L.Add("")
  $L.Add("_Sized on observed p95 for $($r.sized_on_p95) VM(s); on configured capacity for $($r.sized_on_configured) (insufficient history)._")
  $L.Add(""); $L.Add("| Resource | Configured | Recommended (p95+headroom) |"); $L.Add("|---|---|---|")
  $L.Add("| vCPU (sum) | $($r.configured_vcpu) | $($r.recommended_vcpu) |")
  $L.Add("| RAM GiB (sum) | $($r.configured_mem_gib) | $($r.recommended_mem_gib) |")
  if ($r.no_fit -gt 0) { $L.Add(""); $L.Add("> ⚠️ $($r.no_fit) VM(s) exceed the largest instance in the matrix — review manually.") }
  $L.Add(""); $L.Add("## Top blockers"); $L.Add("")
  if ($m.top_blockers.Count -eq 0) { $L.Add("_No blockers detected._") }
  else { $L.Add("| Severity | Blocker | VMs |"); $L.Add("|---|---|---|"); foreach ($b in $m.top_blockers) { $L.Add("| $($b.severity) | $($b.blocker) | $($b.count) |") } }
  $L.Add(""); $L.Add("## Per-cluster rollup"); $L.Add(""); $L.Add("| Cluster | VMs | vCPU | RAM GiB | Blocked |"); $L.Add("|---|---|---|---|---|")
  foreach ($c in $m.per_cluster) { $L.Add("| $($c.cluster) | $($c.vms) | $($c.vcpu) | $($c.mem_gib) | $($c.blocked) |") }
  $L.Add(""); $L.Add("## Per-datastore rollup"); $L.Add(""); $L.Add("| Datastore | Type | Capacity GiB | Used GiB | % | VMs |"); $L.Add("|---|---|---|---|---|---|")
  foreach ($d in $m.per_datastore) { $L.Add("| $($d.name) | $($d.type) | $($d.capacity_gib) | $($d.used_gib) | $($d.pct_used)% | $($d.vm_count) |") }
  $L.Add(""); $L.Add("## Licensing considerations"); $L.Add(""); $L.Add("| Type | VMs |"); $L.Add("|---|---|")
  $L.Add("| Windows Server | $($m.licensing.windows_server) |")
  $L.Add("| SQL Server | $($m.licensing.sql_server) |")
  $L.Add("| Oracle | $($m.licensing.oracle) |")
  $L.Add("")
  if ($m.blocked_vms.Count -gt 0) {
    $L.Add("## Blocked VMs"); $L.Add(""); $L.Add("| VM | Cluster | Blockers |"); $L.Add("|---|---|---|")
    foreach ($v in $m.blocked_vms) { $L.Add("| $($v.name) | $($v.cluster ?? '—') | $($v.blocker_count) |") }
  }
  $L.Add(""); $L.Add("---"); $L.Add("_Generated by vminv (read-only). CSV/JSON tables accompany this report in the same directory._")
  [System.IO.File]::WriteAllText((Join-Path $OutDir 'summary.md'), ($L -join "`n") + "`n")
  Write-Ok "Report: summary.md, summary.html"
  Write-ReportHtml $OutDir $m
}

function Write-ReportHtml([string]$OutDir, $m) {
  $t = $m.totals; $r = $m.rightsizing; $rd = $m.readiness
  $H = [System.Collections.Generic.List[string]]::new()
  $H.Add("<!doctype html><html><head><meta charset=`"utf-8`"><title>vminv assessment — $($m.meta.vcenter)</title>")
  $H.Add("<style>body{font:14px/1.5 system-ui,sans-serif;max-width:980px;margin:2rem auto;padding:0 1rem;color:#1a1a1a}h1{font-size:1.5rem}h2{margin-top:2rem;border-bottom:1px solid #ddd;padding-bottom:.3rem}table{border-collapse:collapse;width:100%;margin:.5rem 0}th,td{border:1px solid #ddd;padding:6px 10px;text-align:left}th{background:#f5f5f7}.ready{color:#137333}.warn{color:#b06000}.blocked{color:#c5221f}.muted{color:#666}</style></head><body>")
  $H.Add("<h1>VMware → $($m.meta.target.ToUpper()) Migration Assessment</h1>")
  $H.Add("<p><strong>$($m.meta.vcenter)</strong> $($m.meta.version) (build $($m.meta.build)) · generated $($m.meta.generated_at)</p>")
  $H.Add("<h2>Estate totals</h2><table><tr><th>Metric</th><th>Value</th></tr>")
  $H.Add("<tr><td>VMs (powered on)</td><td>$($t.vms) ($($t.powered_on))</td></tr>")
  $H.Add("<tr><td>Total vCPU</td><td>$($t.total_vcpu)</td></tr>")
  $H.Add("<tr><td>Total configured RAM</td><td>$($t.total_mem_gib) GiB</td></tr>")
  $H.Add("<tr><td>Provisioned / Used storage</td><td>$($t.provisioned_gib) / $($t.used_gib) GiB ($(_pct $t.used_gib $t.provisioned_gib))</td></tr></table>")
  $H.Add("<h2>Migration readiness</h2><table><tr><th>Status</th><th>VMs</th><th>Share</th></tr>")
  $H.Add("<tr><td class=`"ready`">Ready</td><td>$($rd.ready)</td><td>$(_pct $rd.ready $t.vms)</td></tr>")
  $H.Add("<tr><td class=`"warn`">Needs work</td><td>$($rd.needs_work)</td><td>$(_pct $rd.needs_work $t.vms)</td></tr>")
  $H.Add("<tr><td class=`"blocked`">Blocked</td><td>$($rd.blocked)</td><td>$(_pct $rd.blocked $t.vms)</td></tr></table>")
  $H.Add("<h2>Right-sizing rollup</h2><p class=`"muted`">p95 for $($r.sized_on_p95) VM(s); configured for $($r.sized_on_configured).</p>")
  $H.Add("<table><tr><th>Resource</th><th>Configured</th><th>Recommended</th></tr>")
  $H.Add("<tr><td>vCPU (sum)</td><td>$($r.configured_vcpu)</td><td>$($r.recommended_vcpu)</td></tr>")
  $H.Add("<tr><td>RAM GiB (sum)</td><td>$($r.configured_mem_gib)</td><td>$($r.recommended_mem_gib)</td></tr></table>")
  $H.Add("<h2>Top blockers</h2><table><tr><th>Severity</th><th>Blocker</th><th>VMs</th></tr>")
  foreach ($b in $m.top_blockers) { $H.Add("<tr><td>$($b.severity)</td><td>$($b.blocker)</td><td>$($b.count)</td></tr>") }
  $H.Add("</table><h2>Per-cluster</h2><table><tr><th>Cluster</th><th>VMs</th><th>vCPU</th><th>RAM GiB</th><th>Blocked</th></tr>")
  foreach ($c in $m.per_cluster) { $H.Add("<tr><td>$($c.cluster)</td><td>$($c.vms)</td><td>$($c.vcpu)</td><td>$($c.mem_gib)</td><td>$($c.blocked)</td></tr>") }
  $H.Add("</table><h2>Per-datastore</h2><table><tr><th>Datastore</th><th>Type</th><th>Capacity</th><th>Used</th><th>%</th><th>VMs</th></tr>")
  foreach ($d in $m.per_datastore) { $H.Add("<tr><td>$($d.name)</td><td>$($d.type)</td><td>$($d.capacity_gib)</td><td>$($d.used_gib)</td><td>$($d.pct_used)%</td><td>$($d.vm_count)</td></tr>") }
  $H.Add("</table><h2>Licensing</h2><table><tr><th>Type</th><th>VMs</th></tr>")
  $H.Add("<tr><td>Windows Server</td><td>$($m.licensing.windows_server)</td></tr>")
  $H.Add("<tr><td>SQL Server</td><td>$($m.licensing.sql_server)</td></tr>")
  $H.Add("<tr><td>Oracle</td><td>$($m.licensing.oracle)</td></tr></table>")
  $H.Add("<p class=`"muted`">Generated by vminv (read-only).</p></body></html>")
  [System.IO.File]::WriteAllText((Join-Path $OutDir 'summary.html'), ($H -join "`n") + "`n")
}
