# Vminv.psm1 — module loader. Dot-sources Private (internal) then Public
# (exported) functions. The read-only safety model and schema parity live in
# Private/; see docs/POWERSHELL_PLAN.md.

$ErrorActionPreference = 'Stop'

# Load order matters: Common first (helpers, schema, exit codes), then the
# accessor + writers, then collectors/analysis, then public entrypoints.
$private = @(
  'Common.ps1','Get-RoView.ps1','Write-VminvCsv.ps1','Collect-Infra.ps1','Collect-Vms.ps1','Collect-Perf.ps1','Analyze-Blockers.ps1','Get-Rightsizing.ps1','Write-Report.ps1'
) | ForEach-Object { Join-Path $PSScriptRoot "Private/$_" } | Where-Object { Test-Path $_ }
foreach ($f in $private) { . $f }

# Any additional Private/*.ps1 not listed above (added as phases land).
Get-ChildItem -Path (Join-Path $PSScriptRoot 'Private') -Filter *.ps1 -ErrorAction SilentlyContinue |
  Where-Object { $private -notcontains $_.FullName } | ForEach-Object { . $_.FullName }

$public = Get-ChildItem -Path (Join-Path $PSScriptRoot 'Public') -Filter *.ps1 -ErrorAction SilentlyContinue
foreach ($f in $public) { . $f.FullName }
if ($public) { Export-ModuleMember -Function ($public.BaseName) }
