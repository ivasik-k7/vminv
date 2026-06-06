#!/usr/bin/env pwsh
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Ivan Kovtun
# vminv.ps1 — Windows-native CLI entrypoint mirroring the bash `vminv` UX.
# Strictly read-only. Imports the Vminv module and dispatches subcommands.
#
#   pwsh ./vminv.ps1 [scan] [-Profile P] [-Fixtures DIR] [-Output DIR]
#                    [-Target aws|azure|gcp] [-NoPerf] [-DryRun] [-Quiet] [-Verbose]
#   pwsh ./vminv.ps1 version | help
#
# Profiles, upload, schedule and upgrade are shared with the bash CLI (same
# ~/.config/vminv); use that CLI for those, or a later PowerShell release.

[CmdletBinding()]
param(
  [Parameter(Position = 0)][string]$Command = 'scan',
  [string]$Profile,
  [string]$Fixtures,
  [string]$Output = './output',
  [ValidateSet('aws', 'azure', 'gcp')][string]$Target = 'aws',
  [switch]$NoPerf,
  [switch]$DryRun,
  [switch]$Quiet
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Vminv.psd1') -Force

$version = & (Get-Module Vminv) { Get-VminvVersion }   # private fn, run in module scope
function Show-Usage {
  @"
vminv — read-only VMware vSphere pre-migration inventory & assessment (PowerCLI)

USAGE:
  pwsh ./vminv.ps1 [scan] [options]      collect inventory + utilization + blockers
  pwsh ./vminv.ps1 -DryRun [options]     read-only connectivity check
  pwsh ./vminv.ps1 version | help

OPTIONS:
  -Profile NAME     use a configured profile (~/.config/vminv/profiles)
  -Fixtures DIR     OFFLINE: read canned JSON instead of contacting vCenter
  -Output DIR       base output directory (default ./output)
  -Target aws|azure|gcp
  -NoPerf           skip the utilization pass
  -DryRun           validate read-only connectivity, then exit
  -Quiet            errors only

Strictly read-only. Output schema is identical to the bash path (share/schema.json).
"@
}

switch ($Command) {
  'version' { Write-Output "vminv $version"; exit 0 }
  'help'    { Show-Usage; exit 0 }
  'scan'    {
    if ($Quiet) { Set-Variable -Name VminvVerbosity -Value 0 -Scope Script }
    try {
      Invoke-VminvScan -Profile $Profile -Fixtures $Fixtures -Output $Output -Target $Target -NoPerf:$NoPerf -DryRun:$DryRun | Out-Null
      exit 0
    } catch {
      [Console]::Error.WriteLine("vminv: $($_.Exception.Message)")
      exit 1
    }
  }
  default {
    [Console]::Error.WriteLine("vminv: unknown command '$Command'. Try 'help'.")
    exit 2
  }
}
