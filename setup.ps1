# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Ivan Kovtun
<#
.SYNOPSIS
    setup.ps1 — prepare a Windows machine for the vminv PowerShell (PowerCLI) path.

.DESCRIPTION
    Installs VMware PowerCLI for the CURRENT USER (no admin required) and applies
    non-interactive PowerCLI settings:
      - InvalidCertificateAction (controlled by VCENTER_INSECURE)
      - CEIP / participation disabled
    Then scaffolds .env from config.example.env if missing and prints a readiness
    summary.

    This setup NEVER contacts a vCenter. Like the bash path, the vminv PowerShell
    collector (added in a later stage) is strictly read-only.

    NOTE: The bash path (setup.sh + ./vminv) is the reference implementation. The
    PowerCLI collector is mirrored from it in a later stage; this installer is
    provided now so the environment can be prepared in advance. It has not yet been
    exercised end-to-end against a live vCenter.

.PARAMETER Force
    Reinstall/update PowerCLI even if already present.

.EXAMPLE
    pwsh ./setup.ps1
#>
[CmdletBinding()]
param(
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$ScriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$EnvExample  = Join-Path $ScriptDir 'config.example.env'
$EnvFile     = Join-Path $ScriptDir '.env'

function Write-Info($m) { Write-Host "[*] $m" -ForegroundColor Cyan }
function Write-Ok($m)   { Write-Host "[+] $m" -ForegroundColor Green }
function Write-Warn($m) { Write-Warning $m }

Write-Info "vminv PowerShell setup starting"
Write-Info ("PowerShell: {0} on {1}" -f $PSVersionTable.PSVersion, $PSVersionTable.Platform)

# --- Install PowerCLI (current user) ----------------------------------------
$haveModule = Get-Module -ListAvailable -Name VMware.PowerCLI
if ($haveModule -and -not $Force) {
    Write-Ok ("VMware.PowerCLI already installed (v{0})." -f ($haveModule | Select-Object -First 1).Version)
}
else {
    Write-Info "Installing VMware.PowerCLI for the current user (this can take a few minutes)..."
    if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
        Install-PackageProvider -Name NuGet -Scope CurrentUser -Force | Out-Null
    }
    # Trust PSGallery for this user so install is non-interactive.
    if ((Get-PSRepository -Name PSGallery).InstallationPolicy -ne 'Trusted') {
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
    }
    Install-Module -Name VMware.PowerCLI -Scope CurrentUser -Force -AllowClobber
    Write-Ok "VMware.PowerCLI installed."
}

# --- Non-interactive PowerCLI configuration ---------------------------------
Import-Module VMware.PowerCLI -ErrorAction Stop

# Respect VCENTER_INSECURE if already exported in this shell; default to Fail.
$insecure = $env:VCENTER_INSECURE
$certAction = if ($insecure -and $insecure.ToLower() -eq 'true') { 'Ignore' } else { 'Fail' }
if ($certAction -eq 'Ignore') {
    Write-Warn "VCENTER_INSECURE=true -> PowerCLI InvalidCertificateAction=Ignore (self-signed certs accepted)."
}
Set-PowerCLIConfiguration -InvalidCertificateAction $certAction -Confirm:$false -Scope User | Out-Null
Set-PowerCLIConfiguration -ParticipateInCEIP $false -Confirm:$false -Scope User | Out-Null
Write-Ok ("PowerCLI configured (InvalidCertificateAction={0}, CEIP=off)." -f $certAction)

# --- Config scaffold --------------------------------------------------------
if (-not (Test-Path $EnvExample)) {
    throw "Missing $EnvExample (repo incomplete?)"
}
if (Test-Path $EnvFile) {
    Write-Ok ".env already exists — leaving it untouched."
}
else {
    Copy-Item $EnvExample $EnvFile
    Write-Ok "Created .env from config.example.env."
    Write-Warn "Edit .env: set VCENTER_HOST / VCENTER_USER. Do NOT store the password there."
}

# --- Install the Vminv module onto the user module path ---------------------
$srcMod = Join-Path $ScriptDir 'powershell'
$modBase = if ($IsWindows) { Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PowerShell\Modules' }
           else { Join-Path $HOME '.local/share/powershell/Modules' }
$modDest = Join-Path $modBase 'Vminv'
try {
    New-Item -ItemType Directory -Force -Path $modDest | Out-Null
    Copy-Item (Join-Path $srcMod 'Vminv.psd1') $modDest -Force
    Copy-Item (Join-Path $srcMod 'Vminv.psm1') $modDest -Force
    foreach ($d in 'Private', 'Public') {
        $dd = Join-Path $modDest $d
        New-Item -ItemType Directory -Force -Path $dd | Out-Null
        Copy-Item (Join-Path (Join-Path $srcMod $d) '*.ps1') $dd -Force -ErrorAction SilentlyContinue
    }
    Write-Ok "Installed Vminv module -> $modDest (Import-Module Vminv)"
}
catch { Write-Warn "Could not install Vminv module: $($_.Exception.Message)" }

# --- Readiness --------------------------------------------------------------
Write-Host ""
Write-Host "================ vminv readiness (PowerShell) ================"
$mod = Get-Module -ListAvailable -Name VMware.PowerCLI | Select-Object -First 1
if ($mod) { Write-Ok ("VMware.PowerCLI v{0}" -f $mod.Version) } else { Write-Warn "VMware.PowerCLI missing" }
if (Test-Path $modDest) { Write-Ok "Vminv module installed" } else { Write-Warn "Vminv module not installed" }
if (Test-Path $EnvFile) { Write-Ok ".env present" } else { Write-Warn ".env missing" }
Write-Host "============================================================="
Write-Host ""
Write-Info "Next: 'vminv configure' (bash) or set `$env:VCENTER_PASSWORD, then:"
Write-Info "  Import-Module Vminv; Invoke-VminvScan -Profile <name>    (or: pwsh ./powershell/vminv.ps1 -DryRun)"
