# Collect-Vms.ps1 — full per-VM collection, mirroring lib/collect_vms.sh.
# Produces vms / disks / nics / snapshots with identical schema + values.
# Device polymorphism is discriminated by _typeName (fixtures / modern JSON) or
# the .NET type name (live Get-View) via Get-DeviceType.

$script:VM_PROPS = @(
  'name','config.instanceUuid','config.uuid','config.guestId','config.guestFullName',
  'config.annotation','config.version','config.firmware','config.bootOptions.efiSecureBootEnabled',
  'config.template','config.keyId',
  'config.hardware.numCPU','config.hardware.numCoresPerSocket','config.hardware.memoryMB',
  'config.cpuAllocation.reservation','config.cpuAllocation.limit','config.cpuAllocation.shares.shares',
  'config.memoryAllocation.reservation','config.memoryAllocation.limit','config.memoryAllocation.shares.shares',
  'config.hardware.device','config.tools.toolsVersion',
  'guest.hostName','guest.guestFamily','guest.guestFullName','guest.ipAddress','guest.net',
  'guest.toolsStatus','guest.toolsRunningStatus','guest.toolsVersionStatus2',
  'runtime.powerState','runtime.bootTime','runtime.host','runtime.faultToleranceState','runtime.connectionState',
  'summary.quickStats.uptimeSeconds','summary.quickStats.balloonedMemory','summary.quickStats.swappedMemory',
  'summary.storage.committed','summary.storage.uncommitted','summary.storage.unshared',
  'resourcePool','parentVApp','layoutEx','snapshot','parent'
)

# --- device helpers (mirror JQ_VM_HELPERS) ----------------------------------
function Get-DeviceType($dev) {
  $t = Get-NativeProp $dev '_typeName'
  if ($t) { return $t }
  return $dev.GetType().Name
}
function Test-IsDisk($d) { (Get-DeviceType $d) -eq 'VirtualDisk' }
function Test-IsNic($d)  { $null -ne (Get-NativeProp $d 'macAddress') }
function Test-IsCtrl($d) { (Get-DeviceType $d) -match 'Controller$' }
function Get-DiskCapBytes($d) {
  $b = Get-NativeProp $d 'capacityInBytes'
  if ($b) { return [double]$b }
  return ([double]((Get-NativeProp $d 'capacityInKB') ?? 0)) * 1024
}
function Test-IsRdm($d) { ([string]((Get-NativeProp $d 'backing._typeName'))) -match 'RawDiskMapping' }
function Get-NicType($tn) {
  switch ($tn) {
    'VirtualVmxnet3' { 'vmxnet3' } 'VirtualVmxnet2' { 'vmxnet2' } 'VirtualVmxnet' { 'vmxnet' }
    'VirtualE1000e' { 'e1000e' } 'VirtualE1000' { 'e1000' } 'VirtualPCNet32' { 'pcnet32' }
    'VirtualSriovEthernetCard' { 'sriov' } default { ($tn -replace '^Virtual','') }
  }
}
function Get-CtrlType($tn) {
  switch ($tn) {
    'ParaVirtualSCSIController' { 'pvscsi' } 'VirtualLsiLogicController' { 'lsilogic' }
    'VirtualLsiLogicSASController' { 'lsilogic-sas' } 'VirtualBusLogicController' { 'buslogic' }
    'VirtualAHCIController' { 'sata' } 'VirtualSATAController' { 'sata' } 'VirtualIDEController' { 'ide' }
    'VirtualNVMEController' { 'nvme' } default { ($tn -replace '^Virtual','') }
  }
}
function Get-DiskProvisioning($d) {
  if (Test-IsRdm $d) { return 'rdm' }
  if ((Get-NativeProp $d 'backing.thinProvisioned') -eq $true) { return 'thin' }
  if ((Get-NativeProp $d 'backing.eagerlyScrub') -eq $true) { return 'thick-eager' }
  return 'thick-lazy'
}

# --- layoutEx-derived sizes -------------------------------------------------
function Get-DiskUsedMap($lex) {
  $map = @{}
  if (-not $lex) { return $map }
  $files = @(Get-NativeProp $lex 'file')
  $fsz = @{}
  foreach ($f in $files) { if ($f) { $fsz["$($f.key)"] = [double]($f.size ?? 0) } }
  foreach ($d in @(Get-NativeProp $lex 'disk')) {
    if (-not $d) { continue }
    $sum = 0.0
    foreach ($c in @($d.chain)) { foreach ($fk in @($c.fileKey)) { if ($fsz.ContainsKey("$fk")) { $sum += $fsz["$fk"] } } }
    $map["$($d.key)"] = $sum
  }
  return $map
}
function Get-SnapSizeBytes($lex) {
  if (-not $lex) { return 0 }
  $sum = 0.0
  foreach ($f in @(Get-NativeProp $lex 'file')) {
    if (-not $f) { continue }
    $name = [string]$f.name
    if ($f.type -eq 'snapshotData' -or $name -match '-[0-9]{6}(-delta)?\.vmdk$') { $sum += [double]($f.size ?? 0) }
  }
  return $sum
}

# --- snapshot tree ----------------------------------------------------------
function Get-SnapFlat($list, $vm, $mo, $now) {
  $out = @()
  foreach ($s in @($list)) {
    if (-not $s) { continue }
    $out += [pscustomobject]@{
      vm = $vm; vm_moref = $mo; name = $s.name; description = $s.description; id = $s.id
      created = (Format-IsoMaybe $s.createTime); age_days = (Get-AgeDays ([string]$s.createTime) $now)
      quiesced = [bool]($s.quiesced ?? $false); state = $s.state
    }
    $out += Get-SnapFlat $s.childSnapshotList $vm $mo $now
  }
  return $out
}
function Get-SnapCount($snap) {
  if (-not $snap) { return 0 }
  (Get-SnapFlat $snap.rootSnapshotList '' '' 0).Count
}
function Get-SnapOldest($snap, $now) {
  if (-not $snap) { return $null }
  $ages = (Get-SnapFlat $snap.rootSnapshotList '' '' $now) | ForEach-Object { $_.age_days } | Where-Object { $_ -ne $null }
  if ($ages.Count -eq 0) { return $null }
  return (As-JqNum ($ages | Measure-Object -Maximum).Maximum)
}

# --- cross-reference maps ---------------------------------------------------
function Get-FolderMap {
  $m = @{}
  foreach ($o in (Get-RoView -Name 'folders' -Kind 'f' -Property @('name','parent'))) {
    $p = Get-Prop $o 'parent'
    $m[$o.Moref] = @{ name = (Get-Prop $o 'name'); parent = $(if ($p) { $p.value } else { $null }) }
  }
  return $m
}
function Resolve-FolderPath($startMoref, $fmap) {
  $acc = @(); $m = $startMoref
  while ($m -and $fmap.ContainsKey($m)) { $acc = @($fmap[$m].name) + $acc; $m = $fmap[$m].parent }
  return '/' + ($acc -join '/')
}
function Import-JsonMap($path, $keyProp, $scriptValue) {
  $m = @{}
  if (Test-Path $path) { foreach ($r in (Get-Content -Raw $path | ConvertFrom-Json)) { $m[$r.$keyProp] = (& $scriptValue $r) } }
  return $m
}

function Collect-Vms([string]$OutDir) {
  Write-Info "Collecting VM inventory (full) ..."
  $now = Get-NowEpoch
  $dsmap = Import-JsonMap (Join-Path $OutDir 'datastores.json') 'moref' { param($r) $r.name }
  $netmap = Import-JsonMap (Join-Path $OutDir 'networks.json') 'moref' { param($r) @{ name = $r.name; vlan = $r.vlan_id } }
  $clmap = Import-JsonMap (Join-Path $OutDir 'clusters.json') 'moref' { param($r) $r.name }
  $hostmap = Import-JsonMap (Join-Path $OutDir 'hosts.json') 'moref' { param($r) @{ name = $r.name; cluster = $(if ($r.cluster_moref -and $clmap.ContainsKey($r.cluster_moref)) { $clmap[$r.cluster_moref] } else { $null }) } }.GetNewClosure()
  $poolmap = Import-JsonMap (Join-Path $OutDir 'resourcepools.json') 'moref' { param($r) $r.name }
  $fmap = Get-FolderMap
  $tagsRaw = Get-RoJson 'vm_tags'
  $tagmap = @{}
  if ($tagsRaw) { foreach ($p in $tagsRaw.PSObject.Properties) { $tagmap[$p.Name] = @($p.Value) } }

  $views = Get-RoView -Name 'vms' -Kind 'm' -Property $script:VM_PROPS
  $vms = @(); $disks = @(); $nics = @(); $snaps = @()

  foreach ($o in $views) {
    $mo = $o.Moref
    $vmName = Get-Prop $o 'name'
    $devs = @(Get-Prop $o 'config.hardware.device')
    $diskDevs = @($devs | Where-Object { Test-IsDisk $_ })
    $nicDevs  = @($devs | Where-Object { Test-IsNic $_ })
    $snap = Get-Prop $o 'snapshot'
    $lex = Get-Prop $o 'layoutEx'
    $gos = (Get-Prop $o 'config.guestFullName') ?? (Get-Prop $o 'guest.guestFullName')
    $gid = [string]((Get-Prop $o 'config.guestId') ?? '')
    $hostMo = $(if (Get-Prop $o 'runtime.host') { (Get-Prop $o 'runtime.host').value } else { $null })
    $rpMo = $(if (Get-Prop $o 'resourcePool') { (Get-Prop $o 'resourcePool').value } else { $null })
    $vappMo = $(if (Get-Prop $o 'parentVApp') { (Get-Prop $o 'parentVApp').value } else { $null })
    $parentMo = $(if (Get-Prop $o 'parent') { (Get-Prop $o 'parent').value } else { $null })
    $toolsStatus = Get-Prop $o 'guest.toolsStatus'
    $provBytes = ($diskDevs | ForEach-Object { Get-DiskCapBytes $_ } | Measure-Object -Sum).Sum

    $vms += [pscustomobject]@{
      name             = $vmName
      power_state      = (Get-Prop $o 'runtime.powerState')
      guest_os         = $gos
      guest_family     = (Get-Prop $o 'guest.guestFamily')
      guest_id         = $gid
      guest_arch       = $(if ("$gid$gos" -match '64') { 'x86_64' } else { 'x86' })
      vcpu             = [int]((Get-Prop $o 'config.hardware.numCPU') ?? 0)
      cores_per_socket = [int]((Get-Prop $o 'config.hardware.numCoresPerSocket') ?? 1)
      memory_mb        = [int]((Get-Prop $o 'config.hardware.memoryMB') ?? 0)
      cpu_reservation_mhz = [int]((Get-Prop $o 'config.cpuAllocation.reservation') ?? 0)
      cpu_limit_mhz       = [int]((Get-Prop $o 'config.cpuAllocation.limit') ?? -1)
      cpu_shares          = (Get-Prop $o 'config.cpuAllocation.shares.shares')
      mem_reservation_mib = [int]((Get-Prop $o 'config.memoryAllocation.reservation') ?? 0)
      mem_limit_mib       = [int]((Get-Prop $o 'config.memoryAllocation.limit') ?? -1)
      ballooned_mib    = [int]((Get-Prop $o 'summary.quickStats.balloonedMemory') ?? 0)
      swapped_mib      = [int]((Get-Prop $o 'summary.quickStats.swappedMemory') ?? 0)
      provisioned_gib  = (To-Gib $provBytes)
      used_gib         = (To-Gib (Get-Prop $o 'summary.storage.committed'))
      disk_count       = [int]$diskDevs.Count
      nic_count        = [int]$nicDevs.Count
      snapshot_count   = [int](Get-SnapCount $snap)
      oldest_snapshot_age_days = $(if ($snap) { Get-SnapOldest $snap $now } else { $null })
      snapshot_size_gib = (To-Gib (Get-SnapSizeBytes $lex))
      firmware         = (Get-Prop $o 'config.firmware')
      secure_boot      = [bool]((Get-Prop $o 'config.bootOptions.efiSecureBootEnabled') ?? $false)
      hw_version       = (([string]((Get-Prop $o 'config.version') ?? '')) -replace '^vmx-','')
      tools_status     = $toolsStatus
      tools_running    = (Get-Prop $o 'guest.toolsRunningStatus')
      tools_version    = (Get-Prop $o 'config.tools.toolsVersion')
      vmware_tools_installed = (($toolsStatus ?? 'toolsNotInstalled') -ne 'toolsNotInstalled')
      encrypted        = ($null -ne (Get-Prop $o 'config.keyId'))
      fault_tolerance  = (Get-Prop $o 'runtime.faultToleranceState')
      template         = [bool]((Get-Prop $o 'config.template') ?? $false)
      has_rdm                = (@($diskDevs | Where-Object { Test-IsRdm $_ }).Count -gt 0)
      has_multiwriter_disk   = (@($diskDevs | Where-Object { (Get-NativeProp $_ 'backing.sharing') -eq 'sharingMultiWriter' }).Count -gt 0)
      has_independent_disk   = (@($diskDevs | Where-Object { ([string]((Get-NativeProp $_ 'backing.diskMode'))) -like 'independent*' }).Count -gt 0)
      has_vtpm               = (@($devs | Where-Object { (Get-DeviceType $_) -eq 'VirtualTPM' }).Count -gt 0)
      has_pci_passthrough    = (@($devs | Where-Object { (Get-DeviceType $_) -like 'VirtualPCIPassthrough*' }).Count -gt 0)
      has_vgpu               = (@($devs | Where-Object { (([string]((Get-NativeProp $_ 'backing._typeName'))) -match 'Vmiop') -or ($null -ne (Get-NativeProp $_ 'backing.vgpu')) }).Count -gt 0)
      connected_cdrom        = (@($devs | Where-Object { (Get-DeviceType $_) -eq 'VirtualCdrom' -and (Get-NativeProp $_ 'connectable.connected') -eq $true }).Count -gt 0)
      has_usb                = (@($devs | Where-Object { (Get-DeviceType $_) -match 'USB' }).Count -gt 0)
      has_serial_parallel    = (@($devs | Where-Object { (Get-DeviceType $_) -match 'Serial|Parallel' }).Count -gt 0)
      primary_ip       = (Get-Prop $o 'guest.ipAddress')
      guest_hostname   = (Get-Prop $o 'guest.hostName')
      uptime_days      = [int][math]::Floor(([double]((Get-Prop $o 'summary.quickStats.uptimeSeconds') ?? 0)) / 86400)
      boot_time        = (Format-IsoMaybe (Get-Prop $o 'runtime.bootTime'))
      host             = $(if ($hostMo -and $hostmap.ContainsKey($hostMo)) { $hostmap[$hostMo].name } else { $null })
      cluster          = $(if ($hostMo -and $hostmap.ContainsKey($hostMo)) { $hostmap[$hostMo].cluster } else { $null })
      resource_pool    = $(if ($rpMo -and $poolmap.ContainsKey($rpMo)) { $poolmap[$rpMo] } else { $null })
      vapp             = $(if ($vappMo -and $poolmap.ContainsKey($vappMo)) { $poolmap[$vappMo] } else { $null })
      folder_path      = (Resolve-FolderPath $parentMo $fmap)
      annotation       = (Get-Prop $o 'config.annotation')
      tags             = [string[]]($tagmap[$mo] ?? @())
      instance_uuid    = (Get-Prop $o 'config.instanceUuid')
      bios_uuid        = (Get-Prop $o 'config.uuid')
      moref            = $mo
    }

    # disks
    $ctrls = @{}
    foreach ($c in @($devs | Where-Object { Test-IsCtrl $_ })) { $ctrls["$($c.key)"] = (Get-CtrlType (Get-DeviceType $c)) }
    $usedMap = Get-DiskUsedMap $lex
    foreach ($d in $diskDevs) {
      $dsRef = Get-NativeProp $d 'backing.datastore'
      $disks += [pscustomobject]@{
        vm = $vmName; vm_moref = $mo
        label           = (Get-NativeProp $d 'deviceInfo.label')
        provisioned_gib = (To-Gib (Get-DiskCapBytes $d))
        used_gib        = (To-Gib ($usedMap["$($d.key)"] ?? 0))
        provisioning    = (Get-DiskProvisioning $d)
        disk_mode       = (Get-NativeProp $d 'backing.diskMode')
        independent     = ([string]((Get-NativeProp $d 'backing.diskMode')) -like 'independent*')
        sharing         = ((Get-NativeProp $d 'backing.sharing') ?? 'sharingNone')
        is_rdm          = [bool](Test-IsRdm $d)
        controller_type = $(if ($null -ne (Get-NativeProp $d 'controllerKey')) { $ctrls["$((Get-NativeProp $d 'controllerKey'))"] } else { $null })
        datastore       = $(if ($dsRef -and $dsmap.ContainsKey($dsRef.value)) { $dsmap[$dsRef.value] } else { $null })
        vmdk_path       = (Get-NativeProp $d 'backing.fileName')
      }
    }

    # nics — per-NIC IPs from guest.net keyed by MAC
    $ipmap = @{}
    foreach ($n in @(Get-Prop $o 'guest.net')) {
      if (-not $n) { continue }
      $mac = ([string]($n.macAddress)).ToLower()
      $ips = Get-NativeProp $n 'ipAddress'
      if (-not $ips) { $ips = @(Get-NativeProp $n 'ipConfig.ipAddress' | ForEach-Object { $_.ipAddress }) }
      $ipmap[$mac] = @($ips | Where-Object { $_ })
    }
    foreach ($nd in $nicDevs) {
      $pgkey = (Get-NativeProp $nd 'backing.port.portgroupKey') ?? ''
      $mac = ([string]((Get-NativeProp $nd 'macAddress'))).ToLower()
      $nics += [pscustomobject]@{
        vm = $vmName; vm_moref = $mo
        label        = (Get-NativeProp $nd 'deviceInfo.label')
        adapter_type = (Get-NicType (Get-DeviceType $nd))
        mac_address  = (Get-NativeProp $nd 'macAddress')
        portgroup    = $(
          $dn = Get-NativeProp $nd 'backing.deviceName'
          if ($dn) { $dn } elseif ($pgkey -and $netmap.ContainsKey($pgkey)) { $netmap[$pgkey].name } elseif ($pgkey) { $pgkey } else { $null })
        vlan_id      = $(if ($pgkey -and $netmap.ContainsKey($pgkey)) { $netmap[$pgkey].vlan } else { $null })
        connected    = [bool]((Get-NativeProp $nd 'connectable.connected') ?? $false)
        ip_addresses = (($ipmap[$mac] ?? @()) -join ';')
      }
    }

    # snapshots
    if ($snap) { $snaps += Get-SnapFlat $snap.rootSnapshotList $vmName $mo $now }
  }

  Write-VminvJson -Records $vms   -Path (Join-Path $OutDir 'vms.json')
  Write-VminvCsv  -Records $vms   -Table 'vms'   -Path (Join-Path $OutDir 'vms.csv')
  Write-VminvJson -Records $disks -Path (Join-Path $OutDir 'disks.json')
  Write-VminvCsv  -Records $disks -Table 'disks' -Path (Join-Path $OutDir 'disks.csv')
  Write-VminvJson -Records $nics  -Path (Join-Path $OutDir 'nics.json')
  Write-VminvCsv  -Records $nics  -Table 'nics'  -Path (Join-Path $OutDir 'nics.csv')
  Write-VminvJson -Records $snaps -Path (Join-Path $OutDir 'snapshots.json')
  Write-VminvCsv  -Records $snaps -Table 'snapshots' -Path (Join-Path $OutDir 'snapshots.csv')

  # tag definitions table (category/tag/description)
  $tagsDef = Get-RoJson 'tags'
  $tagRecs = @()
  if ($tagsDef) { $tagRecs = @(foreach ($t in $tagsDef) { [pscustomobject]@{ category = ($t.category ?? $t.categoryName); tag = $t.name; description = ($t.description ?? '') } }) }
  Write-VminvJson -Records $tagRecs -Path (Join-Path $OutDir 'tags.json')
  Write-VminvCsv  -Records $tagRecs -Table 'tags' -Path (Join-Path $OutDir 'tags.csv')
  Write-Ok ("VMs: {0} | disks: {1} | nics: {2} | snapshots: {3}" -f $vms.Count, $disks.Count, $nics.Count, $snaps.Count)
}
