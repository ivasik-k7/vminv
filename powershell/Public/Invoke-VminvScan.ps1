# Invoke-VminvScan — orchestrates a full read-only scan, mirroring bash cmd_scan.
# Live mode connects with Connect-VIServer (read-only); fixture mode (-Fixtures
# or $env:VMINV_FIXTURES) runs the whole pipeline offline. Produces the same
# files as the bash path, including inventory.json + summary.md/html.

function Connect-VminvAbout {
  # Returns the vCenter "about" object ({name,fullName,version,build,apiType,apiVersion}).
  if ($env:VMINV_FIXTURES) {
    $ab = Get-RoJson 'about'
    if ($ab) { $a = if ($ab.PSObject.Properties['about']) { $ab.about } else { $ab.About }
      return [pscustomobject]@{ name = $a.name; fullName = $a.fullName; version = $a.version; build = $a.build; apiType = $a.apiType; apiVersion = $a.apiVersion } }
    return $null
  }
  # LIVE: requires a prior Connect-VIServer; read identity from the session.
  $s = $global:DefaultVIServer
  if (-not $s) { return $null }
  $c = (Get-View ServiceInstance).Content.About
  return [pscustomobject]@{ name = $c.Name; fullName = $c.FullName; version = $c.Version; build = $c.Build; apiType = $c.ApiType; apiVersion = $c.ApiVersion }
}

function Build-Inventory([string]$OutDir, [string]$Target) {
  # Splice the already-correct per-table JSON text (Write-VminvJson output) rather
  # than re-serialize, so single-element arrays stay arrays (ConvertTo-Json would
  # unwrap them). Mirrors the bash jq --argjson assembler.
  $schema = Get-Schema
  $meta = ConvertTo-Json -Compress -InputObject ([ordered]@{ tool = 'vminv'; version = '0.3.0'; generated_at = ([DateTimeOffset]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")); target = $Target })
  $vcFile = Join-Path $OutDir 'vcenter.json'
  $vc = if (Test-Path $vcFile) { (Get-Content -Raw $vcFile).TrimEnd() } else { '{}' }
  $parts = [System.Collections.Generic.List[string]]::new()
  $parts.Add('"meta":' + $meta)
  $parts.Add('"vcenter":' + $vc)
  $counts = [ordered]@{}
  foreach ($p in $schema.inventory_keys.PSObject.Properties) {
    $table = $p.Name; $key = $p.Value
    $f = Join-Path $OutDir "$table.json"
    $txt = if (Test-Path $f) { (Get-Content -Raw $f).TrimEnd() } else { '[]' }
    if (-not $txt) { $txt = '[]' }
    $parts.Add(('"' + $key + '":' + $txt))
    $arr = if (Test-Path $f) { @(ConvertFrom-JsonKeepStrings (Get-Content -Raw $f)) } else { @() }
    $counts[$table] = $arr.Count
  }
  $parts.Add('"counts":' + (ConvertTo-Json -Compress -InputObject $counts))
  [System.IO.File]::WriteAllText((Join-Path $OutDir 'inventory.json'), '{' + ($parts -join ',') + "}`n")
}

function Invoke-VminvScan {
  [CmdletBinding()]
  param(
    [string]$Profile,
    [string]$Fixtures = $env:VMINV_FIXTURES,
    [string]$Output = './output',
    [ValidateSet('aws', 'azure', 'gcp')][string]$Target = 'aws',
    [switch]$NoPerf,
    [switch]$DryRun
  )
  if ($Fixtures) { $env:VMINV_FIXTURES = $Fixtures }
  $about = Connect-VminvAbout

  if ($DryRun) {
    if (-not $about) { Stop-Vminv "could not query vCenter 'about' — check host, credentials, TLS." $script:EX_CONN }
    Write-Ok "Connected: $($about.name) $($about.version) (build $($about.build))"
    Write-Ok 'Dry run OK — read-only access verified.'
    return
  }

  $runTs = [DateTimeOffset]::UtcNow.ToString("yyyyMMddTHHmmssZ")
  $runDir = Join-Path $Output $runTs
  New-Item -ItemType Directory -Force -Path $runDir | Out-Null
  Write-Info "Run output: $runDir"

  if ($about) {
    [System.IO.File]::WriteAllText((Join-Path $runDir 'vcenter.json'), (ConvertTo-Json -InputObject $about -Depth 6) + "`n")
    Write-Ok "vCenter: $($about.name) $($about.version) build $($about.build)"
  } elseif (-not $env:VMINV_FIXTURES) {
    Stop-Vminv "cannot reach vCenter (read of 'about' failed)." $script:EX_CONN
  }

  Write-Phase 'Infrastructure'; Collect-Infra $runDir
  Write-Phase 'Virtual machines'; Collect-Vms $runDir
  if (-not $NoPerf) { Write-Phase 'Utilization'; Collect-Perf $runDir } else { Write-Info 'Skipping utilization pass (-NoPerf).' }
  Write-Phase 'Blocker analysis'; Analyze-Blockers $runDir $Target
  Write-Phase 'Right-sizing & report'; Compute-Rightsizing $runDir $Target; Compute-Licensing $runDir; Write-Report $runDir $Target
  Write-Phase 'Assembly'; Build-Inventory $runDir $Target

  Write-Ok "Scan complete. Output in $runDir"
  return $runDir
}
