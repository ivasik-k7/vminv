# Collect-Infra.ps1 — infrastructure collection, mirroring lib/collect_infra.sh.
# Each collector reads via Get-RoView (uniform shape), normalizes to the shared
# schema, and writes <table>.csv + <table>.json. Failures are isolated.

function Write-Category {
  param([object[]]$Records, [string]$Table, [string]$OutDir)
  $Records = @($Records)
  Write-VminvJson -Records $Records -Path (Join-Path $OutDir "$Table.json")
  Write-VminvCsv  -Records $Records -Table $Table -Path (Join-Path $OutDir "$Table.csv")
  Write-Ok "${Table}: $($Records.Count)"
}

function Collect-Datacenters([string]$OutDir) {
  Write-Info 'Collecting datacenters ...'
  $recs = Get-RoView -Name 'datacenters' -Kind 'd' -Property @('name') | ForEach-Object {
    [pscustomobject]@{ name = (Get-Prop $_ 'name'); moref = $_.Moref }
  }
  Write-Category -Records $recs -Table 'datacenters' -OutDir $OutDir
}

function Collect-Clusters([string]$OutDir) {
  Write-Info 'Collecting clusters (DRS/HA/EVC) ...'
  $props = @('name','summary.numHosts','summary.numEffectiveHosts','configuration.drsConfig.enabled',
             'configuration.drsConfig.defaultVmBehavior','configuration.dasConfig.enabled',
             'summary.currentEVCModeKey','summary.totalCpu','summary.totalMemory')
  $recs = Get-RoView -Name 'clusters' -Kind 'c' -Property $props | ForEach-Object {
    $o = $_
    [pscustomobject]@{
      name                = (Get-Prop $o 'name')
      num_hosts           = [int]((Get-Prop $o 'summary.numHosts')              ?? 0)
      num_effective_hosts = [int]((Get-Prop $o 'summary.numEffectiveHosts')     ?? 0)
      drs_enabled         = [bool]((Get-Prop $o 'configuration.drsConfig.enabled') ?? $false)
      drs_behavior        = (Get-Prop $o 'configuration.drsConfig.defaultVmBehavior')
      ha_enabled          = [bool]((Get-Prop $o 'configuration.dasConfig.enabled') ?? $false)
      evc_mode            = ((Get-Prop $o 'summary.currentEVCModeKey') ?? 'disabled')
      total_cpu_mhz       = [int]((Get-Prop $o 'summary.totalCpu') ?? 0)
      total_memory_gib    = (To-Gib (Get-Prop $o 'summary.totalMemory'))
      moref               = $o.Moref
    }
  }
  Write-Category -Records $recs -Table 'clusters' -OutDir $OutDir
}

function Get-HostLicenseMap {
  $map = @{}
  $assigned = Get-RoJson 'licenses_assigned'
  if ($assigned) {
    foreach ($a in $assigned) {
      $id = if ($a.PSObject.Properties['EntityId']) { $a.EntityId } elseif ($a.PSObject.Properties['entityId']) { $a.entityId } else { $null }
      if (-not $id) { continue }
      $lic = if ($a.PSObject.Properties['AssignedLicense']) { $a.AssignedLicense } elseif ($a.PSObject.Properties['assignedLicense']) { $a.assignedLicense } else { $null }
      $ed = $null
      if ($lic) {
        foreach ($k in 'EditionKey','editionKey','Name','name') { if ($lic.PSObject.Properties[$k]) { $ed = $lic.$k; break } }
      }
      $map[$id] = $ed
    }
  }
  return $map
}

function Collect-Licenses([string]$OutDir) {
  Write-Info 'Collecting licenses ...'
  $data = Get-RoJson 'licenses'
  $recs = @()
  if ($data) {
    $recs = foreach ($l in $data) {
      $key = ''
      foreach ($k in 'licenseKey','LicenseKey') { if ($l.PSObject.Properties[$k]) { $key = [string]$l.$k; break } }
      $tail = if ($key) { '...' + $key.Substring([math]::Max(0, $key.Length - 5)) } else { '' }
      [pscustomobject]@{
        name             = ($l.name ?? $l.Name)
        edition          = (($l.PSObject.Properties['editionKey']) ? $l.editionKey : $l.EditionKey)
        total            = [int](($l.PSObject.Properties['total']) ? $l.total : ($l.Total ?? 0))
        used             = [int](($l.PSObject.Properties['used']) ? $l.used : ($l.Used ?? 0))
        license_key_tail = $tail
      }
    }
  }
  Write-Category -Records $recs -Table 'licenses' -OutDir $OutDir
}

function Collect-Hosts([string]$OutDir) {
  Write-Info 'Collecting hosts ...'
  $lic = Get-HostLicenseMap
  $props = @('name','summary.hardware.vendor','summary.hardware.model','summary.hardware.cpuModel',
             'summary.hardware.numCpuPkgs','summary.hardware.numCpuCores','summary.hardware.numCpuThreads',
             'summary.hardware.memorySize','summary.config.product.version','summary.config.product.build',
             'summary.runtime.connectionState','summary.runtime.powerState','parent')
  $recs = Get-RoView -Name 'hosts' -Kind 'h' -Property $props | ForEach-Object {
    $o = $_; $mo = $o.Moref
    $parent = Get-Prop $o 'parent'
    [pscustomobject]@{
      name             = (Get-Prop $o 'name')
      vendor           = (Get-Prop $o 'summary.hardware.vendor')
      model            = (Get-Prop $o 'summary.hardware.model')
      cpu_model        = (Get-Prop $o 'summary.hardware.cpuModel')
      sockets          = [int]((Get-Prop $o 'summary.hardware.numCpuPkgs') ?? 0)
      cores            = [int]((Get-Prop $o 'summary.hardware.numCpuCores') ?? 0)
      threads          = [int]((Get-Prop $o 'summary.hardware.numCpuThreads') ?? 0)
      memory_gib       = (To-Gib (Get-Prop $o 'summary.hardware.memorySize'))
      esxi_version     = (Get-Prop $o 'summary.config.product.version')
      esxi_build       = (Get-Prop $o 'summary.config.product.build')
      connection_state = (Get-Prop $o 'summary.runtime.connectionState')
      power_state      = (Get-Prop $o 'summary.runtime.powerState')
      license_edition  = ($lic[$mo])
      cluster_moref    = $(if ($parent) { $parent.value } else { $null })
      moref            = $mo
    }
  }
  Write-Category -Records $recs -Table 'hosts' -OutDir $OutDir
}

function Collect-Datastores([string]$OutDir) {
  Write-Info 'Collecting datastores ...'
  $props = @('name','summary.type','summary.capacity','summary.freeSpace','summary.accessible','vm')
  $recs = Get-RoView -Name 'datastores' -Kind 's' -Property $props | ForEach-Object {
    $o = $_
    $cap = [double]((Get-Prop $o 'summary.capacity') ?? 0)
    $free = [double]((Get-Prop $o 'summary.freeSpace') ?? 0)
    $vms = Get-Prop $o 'vm'
    [pscustomobject]@{
      name         = (Get-Prop $o 'name')
      type         = (Get-Prop $o 'summary.type')
      capacity_gib = (To-Gib $cap)
      free_gib     = (To-Gib $free)
      used_gib     = (To-Gib ($cap - $free))
      pct_used     = $(if ($cap -gt 0) { As-JqNum ([math]::Floor((($cap - $free) / $cap) * 1000) / 10) } else { 0 })
      vm_count     = [int]$(if ($vms) { @($vms).Count } else { 0 })
      accessible   = (Get-Prop $o 'summary.accessible')
      moref        = $o.Moref
    }
  }
  Write-Category -Records $recs -Table 'datastores' -OutDir $OutDir
}

function Collect-Dvswitches([string]$OutDir) {
  Write-Info 'Collecting distributed switches (vDS) ...'
  $props = @('name','summary.numPorts','summary.productInfo.version','uuid')
  $recs = Get-RoView -Name 'dvswitches' -Kind 'w' -Property $props | ForEach-Object {
    $o = $_
    [pscustomobject]@{
      name      = (Get-Prop $o 'name')
      num_ports = [int]((Get-Prop $o 'summary.numPorts') ?? 0)
      version   = (Get-Prop $o 'summary.productInfo.version')
      uuid      = (Get-Prop $o 'uuid')
      moref     = $o.Moref
    }
  }
  Write-Category -Records $recs -Table 'dvswitches' -OutDir $OutDir
}

function Collect-Networks([string]$OutDir) {
  Write-Info 'Collecting networks / port groups ...'
  # switch moref -> name map from the dvswitches we just wrote
  $swmap = @{}
  $dvsFile = Join-Path $OutDir 'dvswitches.json'
  if (Test-Path $dvsFile) { (Get-Content -Raw $dvsFile | ConvertFrom-Json) | ForEach-Object { $swmap[$_.moref] = $_.name } }

  $dvpg = Get-RoView -Name 'dvportgroups' -Kind 'g' -Property @('name','config.defaultPortConfig.vlan.vlanId','config.distributedVirtualSwitch') | ForEach-Object {
    $o = $_; $sw = Get-Prop $o 'config.distributedVirtualSwitch'
    $swval = if ($sw) { $sw.value } else { $null }
    [pscustomobject]@{
      name    = (Get-Prop $o 'name'); kind = 'dvportgroup'
      vlan_id = (Get-Prop $o 'config.defaultPortConfig.vlan.vlanId')
      switch  = $(if ($swval -and $swmap.ContainsKey($swval)) { $swmap[$swval] } else { $swval })
      moref   = $o.Moref
    }
  }
  $std = Get-RoView -Name 'standardnetworks' -Kind 'n' -Property @('name') | Where-Object { $_.Type -eq 'Network' } | ForEach-Object {
    [pscustomobject]@{ name = (Get-Prop $_ 'name'); kind = 'standard'; vlan_id = $null; switch = $null; moref = $_.Moref }
  }
  Write-Category -Records (@($dvpg) + @($std)) -Table 'networks' -OutDir $OutDir
}

function Collect-ResourcePools([string]$OutDir) {
  Write-Info 'Collecting resource pools & vApps ...'
  $props = @('name','config.cpuAllocation.reservation','config.cpuAllocation.limit','config.cpuAllocation.shares.shares',
             'config.memoryAllocation.reservation','config.memoryAllocation.limit','config.memoryAllocation.shares.shares')
  function _rp($o, $kind) {
    [pscustomobject]@{
      name                = (Get-Prop $o 'name'); kind = $kind
      cpu_reservation_mhz = [int]((Get-Prop $o 'config.cpuAllocation.reservation') ?? 0)
      cpu_limit_mhz       = [int]((Get-Prop $o 'config.cpuAllocation.limit') ?? -1)
      cpu_shares          = (Get-Prop $o 'config.cpuAllocation.shares.shares')
      mem_reservation_mib = [int]((Get-Prop $o 'config.memoryAllocation.reservation') ?? 0)
      mem_limit_mib       = [int]((Get-Prop $o 'config.memoryAllocation.limit') ?? -1)
      mem_shares          = (Get-Prop $o 'config.memoryAllocation.shares.shares')
      moref               = $o.Moref
    }
  }
  $pools = Get-RoView -Name 'resourcepools' -Kind 'p' -Property $props | ForEach-Object { _rp $_ 'resourcePool' }
  $vapps = Get-RoView -Name 'vapps' -Kind 'a' -Property $props | ForEach-Object { _rp $_ 'vApp' }
  Write-Category -Records (@($pools) + @($vapps)) -Table 'resourcepools' -OutDir $OutDir
}

function Collect-StandardNetworking([string]$OutDir) {
  Write-Info 'Collecting standard vSwitches & port groups ...'
  $hostmap = @{}
  $hf = Join-Path $OutDir 'hosts.json'
  if (Test-Path $hf) { (Get-Content -Raw $hf | ConvertFrom-Json) | ForEach-Object { $hostmap[$_.moref] = $_.name } }
  $views = Get-RoView -Name 'host_networking' -Kind 'h' -Property @('name','config.network.vswitch','config.network.portgroup')
  $sw = @(); $pg = @()
  foreach ($o in $views) {
    $h = if ($hostmap.ContainsKey($o.Moref)) { $hostmap[$o.Moref] } else { (Get-Prop $o 'name') }
    foreach ($v in @((Get-Prop $o 'config.network.vswitch'))) {
      if ($null -eq $v) { continue }
      $sw += [pscustomobject]@{ host = $h; name = $v.name; num_ports = [int]($v.numPorts ?? 0); mtu = $v.mtu }
    }
    foreach ($p in @((Get-Prop $o 'config.network.portgroup'))) {
      if ($null -eq $p) { continue }
      $sp = $p.spec
      $pg += [pscustomobject]@{ host = $h; name = $sp.name; vlan_id = $sp.vlanId; vswitch = $sp.vswitchName }
    }
  }
  Write-Category -Records $sw -Table 'standard_switches' -OutDir $OutDir
  Write-Category -Records $pg -Table 'standard_portgroups' -OutDir $OutDir
}

function Collect-Infra([string]$OutDir) {
  Collect-Datacenters       $OutDir
  Collect-Clusters          $OutDir
  Collect-Licenses          $OutDir
  Collect-Hosts             $OutDir
  Collect-StandardNetworking $OutDir
  Collect-Datastores        $OutDir
  Collect-Dvswitches        $OutDir
  Collect-Networks          $OutDir
  Collect-ResourcePools     $OutDir
}
