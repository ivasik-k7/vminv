# Invoke-CiCheck.ps1 — PowerShell-native CI smoke/assertion check (Windows job).
# Imports the module, runs a full fixture scan via the public entrypoint, and
# asserts the key outputs/values. No bash/jq/govc needed. Exit 1 on any failure.
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $repo 'powershell/Vminv.psd1') -Force

$env:VMINV_FIXTURES = (Join-Path $repo 'tests/fixtures')
$out = Join-Path ([IO.Path]::GetTempPath()) ("vminv-ci-" + [guid]::NewGuid().ToString('N'))
$run = Invoke-VminvScan -Output $out -Target aws

$fail = 0
function check([bool]$cond, [string]$msg) { if ($cond) { Write-Host "  ok   $msg" } else { Write-Host "  FAIL $msg"; $script:fail++ } }

check (Test-Path (Join-Path $run 'vms.csv'))        'vms.csv exists'
check (Test-Path (Join-Path $run 'summary.md'))     'summary.md exists'
check (Test-Path (Join-Path $run 'inventory.json')) 'inventory.json exists'
check (Test-Path (Join-Path $run 'blockers.csv'))   'blockers.csv exists'

$vms = Get-Content -Raw (Join-Path $run 'vms.json') | ConvertFrom-Json
check ($vms.Count -eq 4)                                              '4 VMs collected'
check ((@($vms | Where-Object { $_.name -eq 'web-01' })).Count -eq 1) 'web-01 present'
check ((@($vms | Where-Object { $_.name -eq 'db-prod-01' })[0]).migration_status -eq 'blocked') 'db-prod-01 blocked'

$disks = Get-Content -Raw (Join-Path $run 'disks.json') | ConvertFrom-Json
check ((@($disks | Where-Object { $_.is_rdm })).Count -ge 1) 'RDM disk detected'

Remove-Item -Recurse -Force $out -ErrorAction SilentlyContinue
if ($fail) { Write-Host "PowerShell CI check: $fail failure(s)"; exit 1 }
Write-Host 'PowerShell CI check passed.'
