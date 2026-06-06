# Test entry: dot-source the module internals and run a phase against fixtures.
# Used by the bash conformance test (tests/test_ps_conformance.sh).
param(
  [Parameter(Mandatory)][string]$Out,
  [Parameter(Mandatory)][string]$Fixtures,
  [string]$Phase = 'infra'
)
$ErrorActionPreference = 'Stop'
$priv = Join-Path (Split-Path -Parent $PSScriptRoot) 'Private'
. (Join-Path $priv 'Common.ps1')
. (Join-Path $priv 'Write-VminvCsv.ps1')
. (Join-Path $priv 'Get-RoView.ps1')
. (Join-Path $priv 'Collect-Infra.ps1')
. (Join-Path $priv 'Collect-Vms.ps1')
. (Join-Path $priv 'Collect-Perf.ps1')
. (Join-Path $priv 'Analyze-Blockers.ps1')
. (Join-Path $priv 'Get-Rightsizing.ps1')
. (Join-Path $priv 'Write-Report.ps1')

$env:VMINV_FIXTURES = $Fixtures
$script:VminvVerbosity = 0
New-Item -ItemType Directory -Force -Path $Out | Out-Null

switch ($Phase) {
  'infra' { Collect-Infra $Out }
  'vms'   { Collect-Infra $Out; Collect-Vms $Out }
  'perf'  { Collect-Infra $Out; Collect-Vms $Out; Collect-Perf $Out }
  'analysis' { Collect-Infra $Out; Collect-Vms $Out; Collect-Perf $Out; Analyze-Blockers $Out 'aws'; Compute-Rightsizing $Out 'aws'; Compute-Licensing $Out }
  'full'  { Collect-Infra $Out; Collect-Vms $Out; Collect-Perf $Out; Analyze-Blockers $Out 'aws'; Compute-Rightsizing $Out 'aws'; Compute-Licensing $Out; Write-Report $Out 'aws' }
  default { Write-Error "unknown phase: $Phase"; exit 2 }
}
