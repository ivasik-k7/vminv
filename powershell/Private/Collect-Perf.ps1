# Collect-Perf.ps1 — utilization, mirroring lib/collect_perf.sh.
# Fixture mode reads the same perf.json (govc metric.sample shape); live mode
# uses Get-Stat. Computes avg/peak/p95 per VM with identical unit conversions.

$script:PerfWindowDays = 30
$script:PerfInterval   = 'daily'
function Get-PerfIntervalSeconds {
  switch ($script:PerfInterval) {
    'realtime' { 300 } 'daily' { 86400 } 'weekly' { 7200 } 'monthly' { 7200 } default { 86400 }
  }
}

# round to 1dp, then collapse integral -> integer (matches jq r1 + number form)
function R1($v) { if ($null -eq $v) { return $null }; return (As-JqNum ([math]::Round([double]$v * 10, [MidpointRounding]::AwayFromZero) / 10)) }

# stats over an int array, ignoring negative "no data" markers (matches jq stat())
function Get-PerfStat($arr) {
  $v = @(@($arr) | Where-Object { $_ -ne $null -and [double]$_ -ge 0 } | ForEach-Object { [double]$_ })
  if ($v.Count -eq 0) { return @{ avg = $null; peak = $null; p95 = $null; n = 0 } }
  $s = @($v | Sort-Object)
  $len = $s.Count
  $raw = [int][math]::Ceiling($len * 0.95) - 1
  $i = if ($raw -lt 0) { 0 } elseif ($raw -ge $len) { $len - 1 } else { $raw }
  return @{ avg = (($v | Measure-Object -Sum).Sum / $len); peak = ($v | Measure-Object -Maximum).Maximum; p95 = $s[$i]; n = $len }
}

# aggregate-instance series for a counter from one entity-metric object
function Get-PerfSeries($entity, $counter) {
  if (-not $entity) { return @() }
  $m = @($entity.value) | Where-Object {
    ((($_.name) ?? ($_.Name)) -eq $counter) -and (((($_.instance) ?? ($_.Instance)) ?? '') -eq '')
  } | Select-Object -First 1
  if ($m) { return @(($m.value) ?? ($m.Value)) }
  return @()
}

function Collect-Perf([string]$OutDir) {
  $iv = Get-PerfIntervalSeconds
  Write-Info ("Collecting utilization over {0}d (interval {1}s) ..." -f $script:PerfWindowDays, $iv)
  $vmsFile = Join-Path $OutDir 'vms.json'
  if (-not (Test-Path $vmsFile)) { Write-VminvJson @() (Join-Path $OutDir 'utilization.json'); '' | Set-Content (Join-Path $OutDir 'utilization.csv'); return }
  $vms = @(ConvertFrom-JsonKeepStrings (Get-Content -Raw $vmsFile))

  # entity-metric data keyed by moref
  $pm = @{}
  $raw = Get-RoJson 'perf'   # live: replace with Get-Stat aggregation
  if ($raw) { foreach ($e in @($raw)) { $pm[(($e.entity.value) ?? ($e.entity.Value))] = $e } }

  $recs = foreach ($v in $vms) {
    $e = $pm[$v.moref]
    $cpu  = Get-PerfStat (Get-PerfSeries $e 'cpu.usage.average')
    $mhz  = Get-PerfStat (Get-PerfSeries $e 'cpu.usagemhz.average')
    $memc = Get-PerfStat (Get-PerfSeries $e 'mem.consumed.average')
    $mema = Get-PerfStat (Get-PerfSeries $e 'mem.active.average')
    $memp = Get-PerfStat (Get-PerfSeries $e 'mem.usage.average')
    $rd   = Get-PerfStat (Get-PerfSeries $e 'disk.numberReadAveraged.average')
    $wr   = Get-PerfStat (Get-PerfSeries $e 'disk.numberWriteAveraged.average')
    $dkb  = Get-PerfStat (Get-PerfSeries $e 'disk.usage.average')
    $lat  = Get-PerfStat (Get-PerfSeries $e 'disk.maxTotalLatency.latest')
    $net  = Get-PerfStat (Get-PerfSeries $e 'net.usage.average')
    $div100 = { param($x) if ($null -eq $x) { $null } else { $x / 100 } }
    $div1024 = { param($x) if ($null -eq $x) { $null } else { $x / 1024 } }
    [pscustomobject]@{
      vm = $v.name; vm_moref = $v.moref; window_days = $script:PerfWindowDays; interval_s = $iv
      samples = [int]$cpu.n
      insufficient_data = ($cpu.n -eq 0)
      cpu_pct_avg  = (R1 (& $div100 $cpu.avg));  cpu_pct_peak = (R1 (& $div100 $cpu.peak)); cpu_pct_p95 = (R1 (& $div100 $cpu.p95))
      cpu_mhz_avg  = (R1 $mhz.avg); cpu_mhz_peak = (As-JqNum $mhz.peak); cpu_mhz_p95 = (R1 $mhz.p95)
      mem_mb_avg   = (R1 (& $div1024 $memc.avg)); mem_mb_peak = (R1 (& $div1024 $memc.peak)); mem_mb_p95 = (R1 (& $div1024 $memc.p95))
      mem_active_mb_p95 = (R1 (& $div1024 $mema.p95)); mem_pct_p95 = (R1 (& $div100 $memp.p95))
      disk_iops_avg  = $(if (($rd.n + $wr.n) -eq 0) { $null } else { R1 ((($rd.avg ?? 0)) + (($wr.avg ?? 0))) })
      disk_iops_peak = $(if (($rd.n + $wr.n) -eq 0) { $null } else { As-JqNum ((($rd.peak ?? 0)) + (($wr.peak ?? 0))) })
      disk_kbps_avg  = (R1 $dkb.avg); disk_kbps_peak = (As-JqNum $dkb.peak); disk_latency_ms_peak = (As-JqNum $lat.peak)
      net_kbps_avg = (R1 $net.avg); net_kbps_peak = (As-JqNum $net.peak)
    }
  }
  $recs = @($recs)
  Write-VminvJson -Records $recs -Path (Join-Path $OutDir 'utilization.json')
  Write-VminvCsv  -Records $recs -Table 'utilization' -Path (Join-Path $OutDir 'utilization.csv')
  $got = @($recs | Where-Object { -not $_.insufficient_data }).Count
  Write-Ok "Utilization: $got/$($recs.Count) VMs with usable history"
}
