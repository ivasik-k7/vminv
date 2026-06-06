# Get-Rightsizing.ps1 — candidate instance per VM + licensing flags,
# mirroring lib/rightsize.sh. Sizes on p95 demand (70% headroom) where history
# exists, else configured capacity; matrices are the editable CSVs in matrices/.

$script:RightsizeTargetUtil = 0.7

function _round1($v) { if ($null -eq $v) { return $null }; return (As-JqNum ([math]::Round([double]$v * 10, [MidpointRounding]::AwayFromZero) / 10)) }
function _ceilPos($x) { if ([double]$x -le 0) { return 1 }; return [long][math]::Ceiling([double]$x) }

function Get-InstanceMatrix([string]$target) {
  $f = Join-Path $script:VminvMatrixDir "instance_types_$target.csv"
  if (-not (Test-Path $f)) { return @() }
  @(Import-Csv $f | ForEach-Object {
      [pscustomobject]@{ instance_type = $_.instance_type; family = $_.family; note = $_.note
        vcpu = [long]$_.vcpu; mem_gib = [long]$_.mem_gib }
    } | Sort-Object vcpu, mem_gib)
}

function Compute-Rightsizing([string]$OutDir, [string]$Target) {
  Write-Info "Right-sizing VMs for $Target ..."
  $vms = @(ConvertFrom-JsonKeepStrings (Get-Content -Raw (Join-Path $OutDir 'vms.json')))
  $mx = Get-InstanceMatrix $Target
  $util = @{}
  $uf = Join-Path $OutDir 'utilization.json'
  if (Test-Path $uf) { foreach ($u in (ConvertFrom-JsonKeepStrings (Get-Content -Raw $uf))) { $util[$u.vm_moref] = $u } }

  $recs = foreach ($v in $vms) {
    $u = $util[$v.moref]
    $cv = [long]($v.vcpu ?? 1)
    $cm = [double]($v.memory_mb ?? 0) / 1024
    $basis = if ($u -and -not $u.insufficient_data) { 'p95' } else { 'configured' }
    if ($basis -eq 'p95') {
      $rv = _ceilPos ($cv * (([double]($u.cpu_pct_p95 ?? 0)) / 100) / $script:RightsizeTargetUtil)
      $rm = _ceilPos ((([double]($u.mem_mb_p95 ?? 0)) / 1024) / $script:RightsizeTargetUtil)
    } else {
      $rv = $cv; $rm = [long][math]::Ceiling($cm)
    }
    $fit = $mx | Where-Object { $_.vcpu -ge $rv -and $_.mem_gib -ge $rm } | Select-Object -First 1
    if ($fit) { $cand = $fit; $fits = $true }
    elseif ($mx.Count -gt 0) { $cand = $mx[-1]; $fits = $false }
    else { $cand = $null; $fits = $false }
    [pscustomobject]@{
      vm = $v.name; vm_moref = $v.moref; basis = $basis
      configured_vcpu = $cv; configured_mem_gib = (_round1 $cm)
      p95_cpu_pct = $(if ($basis -eq 'p95') { $u.cpu_pct_p95 } else { $null })
      p95_mem_gib = $(if ($basis -eq 'p95') { _round1 (([double]($u.mem_mb_p95 ?? 0)) / 1024) } else { $null })
      req_vcpu = [long]$rv; req_mem_gib = [long]$rm
      candidate_instance = $(if ($cand) { $cand.instance_type } else { $null })
      candidate_vcpu = $(if ($cand) { $cand.vcpu } else { $null })
      candidate_mem_gib = $(if ($cand) { $cand.mem_gib } else { $null })
      fits = $fits
    }
  }
  $recs = @($recs)
  Write-VminvJson -Records $recs -Path (Join-Path $OutDir 'rightsizing.json')
  Write-VminvCsv  -Records $recs -Table 'rightsizing' -Path (Join-Path $OutDir 'rightsizing.csv')
  Write-Ok "Right-sizing: $($recs.Count) VM(s)"
}

function Compute-Licensing([string]$OutDir) {
  $vms = @(ConvertFrom-JsonKeepStrings (Get-Content -Raw (Join-Path $OutDir 'vms.json')))
  $recs = foreach ($v in $vms) {
    $t = (@($v.guest_os, $v.name, $v.annotation) | ForEach-Object { $_ ?? '' }) -join ' '
    $t = $t.ToLower()
    $ws = $t -match 'windows server'
    $sql = $t -match 'sql server|sqlserver'
    $ora = $t -match 'oracle'
    if (-not ($ws -or $sql -or $ora)) { continue }
    $notes = @()
    if ($ws)  { $notes += 'Windows Server (BYOL vs license-included)' }
    if ($sql) { $notes += 'SQL Server licensing — verify edition/cores' }
    if ($ora) { $notes += 'Oracle licensing — review carefully (core factor)' }
    [pscustomobject]@{ vm = $v.name; vm_moref = $v.moref; windows_server = [bool]$ws; sql_server = [bool]$sql; oracle = [bool]$ora; note = ($notes -join '; ') }
  }
  $recs = @($recs)
  Write-VminvJson -Records $recs -Path (Join-Path $OutDir 'licensing.json')
  Write-VminvCsv  -Records $recs -Table 'licensing' -Path (Join-Path $OutDir 'licensing.csv')
  Write-Ok "Licensing considerations: $($recs.Count) VM(s)"
}
