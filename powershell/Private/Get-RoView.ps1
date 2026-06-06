# Get-RoView.ps1 — the READ-ONLY vCenter accessor and the central safety
# chokepoint (mirrors govc_ro/govc_query). All vCenter reads go through here.
#
# Live mode uses Get-View -Property … (the PowerCLI property collector — the
# direct analog of govc object.collect). Fixture mode ($env:VMINV_FIXTURES)
# reads the SAME object.collect JSON fixtures the bash tests use, so the two
# implementations are tested against identical inputs.
#
# Both modes return a uniform shape: objects carrying a ._props hashtable keyed
# by the lowerCamel vSphere property paths (identical strings to govc), plus a
# .Moref. Normalizers read values via Get-Prop, so they are mode-agnostic.

# govc kind letter -> PowerCLI ViewType (live mode)
$script:ViewTypeMap = @{
  d = 'Datacenter'; c = 'ClusterComputeResource'; h = 'HostSystem'; s = 'Datastore'
  n = 'Network'; p = 'ResourcePool'; m = 'VirtualMachine'; f = 'Folder'
  g = 'DistributedVirtualPortgroup'; w = 'VmwareDistributedVirtualSwitch'; a = 'VirtualApp'
}

# Walk a native Get-View object by a dotted lowerCamel path (case-insensitive).
function Get-NativeProp($obj, [string]$path) {
  $cur = $obj
  foreach ($seg in ($path -split '\.')) {
    if ($null -eq $cur) { return $null }
    $prop = $cur.PSObject.Properties | Where-Object { $_.Name -ieq $seg } | Select-Object -First 1
    if (-not $prop) { return $null }
    $cur = $prop.Value
  }
  return $cur
}

# Value of a collected property (uniform across live/fixture).
function Get-Prop($obj, [string]$path) {
  if ($obj._props.ContainsKey($path)) { return $obj._props[$path] }
  return $null
}

# Build the uniform wrapper from a fixture ObjectContent entry.
function ConvertFrom-FixtureEntry($entry) {
  $props = @{}
  if ($entry.PSObject.Properties['propSet']) {
    foreach ($ps in $entry.propSet) { $props[$ps.name] = $ps.val }
  }
  [pscustomobject]@{ Moref = $entry.obj.value; Type = $entry.obj.type; _props = $props }
}

# Get-RoView -Name <fixture/query name> -Kind <govc-letter> -Property <paths...>
function Get-RoView {
  param([string]$Name, [string]$Kind, [string[]]$Property = @())
  $fixDir = $env:VMINV_FIXTURES
  if ($fixDir) {
    $f = Join-Path $fixDir "$Name.json"
    if (-not (Test-Path $f)) { return @() }
    $data = ConvertFrom-JsonKeepStrings (Get-Content -Raw $f)
    return @($data | ForEach-Object { ConvertFrom-FixtureEntry $_ })
  }
  # LIVE (requires an active Connect-VIServer; uses the property collector).
  $vt = $script:ViewTypeMap[$Kind]
  if (-not $vt) { Stop-Vminv "internal: unknown view kind '$Kind'" $script:EX_ERR }
  $views = Get-View -ViewType $vt -Property $Property
  return @($views | ForEach-Object {
    $native = $_
    $props = @{}
    foreach ($p in $Property) { $props[$p] = (Get-NativeProp $native $p) }
    [pscustomobject]@{ Moref = $native.MoRef.Value; Type = $native.MoRef.Type; _props = $props }
  })
}

# Raw fixture/text reader for non-ObjectContent queries (e.g. about, licenses).
function Get-RoJson([string]$Name) {
  $fixDir = $env:VMINV_FIXTURES
  if ($fixDir) {
    $f = Join-Path $fixDir "$Name.json"
    if (Test-Path $f) { return (ConvertFrom-JsonKeepStrings (Get-Content -Raw $f)) }
  }
  return $null
}
