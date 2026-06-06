# Analyze-Blockers.ps1 — migration blocker analysis, mirroring lib/analyze_blockers.sh.
# Pure analysis over vms.json + disks.json + the editable OS matrix + thresholds.
# Detail strings are copied verbatim (em-dashes included) for byte-identical CSV.

$script:ThresholdLargeDiskGb = 2048
$script:ThresholdLargeVmGb   = 8192
$script:ThresholdOldHw       = 9
$script:ThresholdSnapAgeDays = 7

function Get-OsSupport([string]$os, [string]$target, $matrix) {
  foreach ($row in $matrix) {
    if (($os ?? '') -match $row.pattern) { return ($row.$target ?? 'yes') }
  }
  return 'unknown'
}

function Analyze-Blockers([string]$OutDir, [string]$Target) {
  Write-Info "Analyzing migration blockers (target: $Target) ..."
  $vms = @(ConvertFrom-JsonKeepStrings (Get-Content -Raw (Join-Path $OutDir 'vms.json')))
  $matrix = @(Import-Csv (Join-Path $script:VminvMatrixDir 'os_support.csv'))
  # per-VM max disk GiB
  $diskmax = @{}
  $disksFile = Join-Path $OutDir 'disks.json'
  if (Test-Path $disksFile) {
    foreach ($d in (ConvertFrom-JsonKeepStrings (Get-Content -Raw $disksFile))) {
      $cur = if ($diskmax.ContainsKey($d.vm_moref)) { $diskmax[$d.vm_moref] } else { 0 }
      $diskmax[$d.vm_moref] = [math]::Max($cur, [double]($d.provisioned_gib ?? 0))
    }
  }

  $rank = @{ high = 3; medium = 2; low = 1 }
  $rows = New-Object System.Collections.Generic.List[object]
  $readiness = @{}
  $idx = 0
  foreach ($v in $vms) {
    $maxdisk = if ($diskmax.ContainsKey($v.moref)) { $diskmax[$v.moref] } else { 0 }
    $os = Get-OsSupport $v.guest_os $Target $matrix
    $bl = New-Object System.Collections.Generic.List[object]
    function add($b, $s, $d) { $bl.Add(@{ b = $b; s = $s; d = $d }) }

    if ($v.has_rdm)              { add 'rdm' 'high' 'Raw Device Mapping (RDM) present — not supported by cloud migration' }
    if ($v.has_multiwriter_disk) { add 'shared-multiwriter-disk' 'high' 'Multi-writer/shared disk (clustering) — blocks standard migration' }
    if ($v.has_pci_passthrough)  { add 'pci-passthrough' 'high' 'PCI passthrough / DirectPath I/O — no equivalent on standard cloud SKUs' }
    if ($v.has_vgpu)             { add 'vgpu' 'high' 'vGPU device — requires a specific GPU cloud SKU' }
    if ($v.has_vtpm)             { add 'vtpm' 'high' 'Virtual TPM present — commonly blocks migration tooling' }
    if ($v.encrypted)            { add 'vm-encryption' 'high' 'vSphere VM Encryption — must be decrypted before migration' }
    if (($v.fault_tolerance ?? '') -match 'running|enabled') { add 'fault-tolerance' 'high' 'Fault Tolerance enabled — must be disabled before migration' }
    if ($os -eq 'no')            { add 'unsupported-os' 'high' ("Guest OS not supported on " + $Target + ": " + ($v.guest_os ?? 'unknown')) }
    if (($v.snapshot_count ?? 0) -gt 0) {
      if (($v.oldest_snapshot_age_days ?? 0) -gt $script:ThresholdSnapAgeDays) {
        add 'stale-snapshot' 'medium' ("Snapshot older than " + $script:ThresholdSnapAgeDays + "d (" + ($v.oldest_snapshot_age_days ?? 0) + "d) — consolidate before migrating")
      } else {
        add 'active-snapshot' 'medium' (($v.snapshot_count) + " active snapshot(s) — consolidate before migrating")
      }
    }
    if ($v.has_independent_disk)  { add 'independent-disk' 'medium' 'Independent disk(s) — excluded from snapshots; verify migration handling' }
    if ($v.connected_cdrom)       { add 'connected-iso' 'medium' 'Connected CD/DVD (ISO) — disconnect before migration' }
    if ($v.has_usb)               { add 'usb-device' 'medium' 'USB device attached — cannot be migrated' }
    if ($v.has_serial_parallel)   { add 'serial-parallel-port' 'medium' 'Serial/parallel port present — may block migration' }
    $hw = 0; [int]::TryParse(([string]($v.hw_version ?? '0')), [ref]$hw) | Out-Null
    if ($hw -gt 0 -and $hw -le $script:ThresholdOldHw) { add 'old-hw-version' 'medium' ("Very old virtual hardware version (vmx-" + ($v.hw_version ?? '?') + ")") }
    if ($maxdisk -gt $script:ThresholdLargeDiskGb) { add 'large-disk' 'medium' ("Disk larger than " + $script:ThresholdLargeDiskGb + " GiB (" + (As-JqNum $maxdisk) + " GiB)") }
    if (($v.provisioned_gib ?? 0) -gt $script:ThresholdLargeVmGb) { add 'large-footprint' 'medium' ("Total provisioned > " + $script:ThresholdLargeVmGb + " GiB (" + ($v.provisioned_gib ?? 0) + " GiB)") }
    if ($os -eq 'unknown')        { add 'os-not-in-matrix' 'low' ("Guest OS not in support matrix — verify manually: " + ($v.guest_os ?? 'unknown')) }
    if (-not ($v.vmware_tools_installed ?? $true)) { add 'no-vmware-tools' 'low' 'VMware Tools not installed — harder to migrate/agent' }

    foreach ($b in $bl) {
      $rows.Add([pscustomobject]@{
        vm = $v.name; severity = $b.s; blocker = $b.b; detail = $b.d
        cluster = $v.cluster; vm_moref = $v.moref; _idx = $idx; _rank = $rank[$b.s]
      }); $idx++
    }
    $sevs = @($bl | ForEach-Object { $_.s })
    $top = if ($sevs -contains 'high') { 'high' } elseif ($sevs -contains 'medium') { 'medium' } elseif ($sevs -contains 'low') { 'low' } else { 'none' }
    $status = if ($sevs -contains 'high') { 'blocked' } elseif ($bl.Count -gt 0) { 'needs-work' } else { 'ready' }
    $readiness[$v.moref] = @{ count = $bl.Count; top = $top; status = $status }
  }

  $sorted = @($rows | Sort-Object @{Expression = '_rank'; Descending = $true }, @{Expression = 'vm'; Descending = $false }, @{Expression = '_idx'; Descending = $false } |
    ForEach-Object { $_ | Select-Object vm, severity, blocker, detail, cluster, vm_moref })
  Write-VminvJson -Records $sorted -Path (Join-Path $OutDir 'blockers.json')
  Write-VminvCsv  -Records $sorted -Table 'blockers' -Path (Join-Path $OutDir 'blockers.csv')

  # summary
  $bySev = @{}; $byBlk = @{}
  foreach ($r in $sorted) { $bySev[$r.severity] = ($bySev[$r.severity] ?? 0) + 1; $byBlk[$r.blocker] = ($byBlk[$r.blocker] ?? 0) + 1 }
  $summary = [pscustomobject]@{ total = $sorted.Count; by_severity = [pscustomobject]$bySev; by_blocker = [pscustomobject]$byBlk }
  [System.IO.File]::WriteAllText((Join-Path $OutDir 'blockers_summary.json'), (ConvertTo-Json -InputObject $summary -Depth 6) + "`n")

  # annotate VMs
  foreach ($v in $vms) {
    $r = $readiness[$v.moref] ?? @{ count = 0; top = 'none'; status = 'unknown' }
    $v | Add-Member -NotePropertyName migration_status -NotePropertyValue $r.status -Force
    $v | Add-Member -NotePropertyName blocker_count -NotePropertyValue ([int]$r.count) -Force
    $v | Add-Member -NotePropertyName top_severity -NotePropertyValue $r.top -Force
  }
  Write-VminvJson -Records $vms -Path (Join-Path $OutDir 'vms.json')
  Write-VminvCsv  -Records $vms -Table 'vms' -Path (Join-Path $OutDir 'vms.csv')

  Write-Ok ("Blockers: {0} high, {1} medium, {2} low across {3} finding(s)" -f ($bySev['high'] ?? 0), ($bySev['medium'] ?? 0), ($bySev['low'] ?? 0), $sorted.Count)
}
