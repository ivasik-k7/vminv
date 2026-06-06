# Common.ps1 — shared foundation for the vminv PowerShell implementation.
# Mirrors lib/common.sh: logging to stderr, secret redaction, exit codes, the
# single-sourced schema, and the math/number formatting that must match jq so
# CSV/JSON output is byte-identical to the bash path.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Exit codes (mirror lib/common.sh) --------------------------------------
$script:EX_OK = 0; $script:EX_ERR = 1; $script:EX_USAGE = 2
$script:EX_CONN = 3; $script:EX_PARTIAL = 4; $script:EX_INTERRUPT = 130

# --- Paths ------------------------------------------------------------------
# $PSScriptRoot = powershell/Private ; module root = powershell ; repo = ../..
$script:VminvPsRoot = Split-Path -Parent $PSScriptRoot
$script:VminvRepoRoot = Split-Path -Parent $script:VminvPsRoot
$script:VminvShareDir = Join-Path $script:VminvRepoRoot 'share'
$script:VminvMatrixDir = Join-Path $script:VminvRepoRoot 'matrices'

# --- Output controls --------------------------------------------------------
$script:VminvVerbosity = 1   # 0 quiet, 1 normal, 2 verbose
$script:VminvPartial = 0
function Set-Partial { $script:VminvPartial = 1 }

$script:RedactValues = [System.Collections.Generic.List[string]]::new()
function Register-Redact([string]$v) { if ($v) { [void]$script:RedactValues.Add($v) } }
function Protect-Secret([string]$s) {
  foreach ($v in $script:RedactValues) { if ($v) { $s = $s.Replace($v, '***REDACTED***') } }
  return $s
}

# Human output -> stderr (stdout is reserved for machine data), mirroring bash.
function Write-Info([string]$m) { if ($script:VminvVerbosity -ge 1) { [Console]::Error.WriteLine("[*] $(Protect-Secret $m)") } }
function Write-Ok([string]$m)   { if ($script:VminvVerbosity -ge 1) { [Console]::Error.WriteLine("[+] $(Protect-Secret $m)") } }
function Write-Warn2([string]$m){ [Console]::Error.WriteLine("[!] $(Protect-Secret $m)") }
function Write-Err([string]$m)  { [Console]::Error.WriteLine("vminv: $(Protect-Secret $m)") }
function Write-Phase([string]$m){ if ($script:VminvVerbosity -ge 1) { [Console]::Error.WriteLine("`n== $(Protect-Secret $m) ==") } }
function Stop-Vminv([string]$m, [int]$code = 1) { Write-Err $m; exit $code }

# --- Schema (single source: share/schema.json) ------------------------------
$script:VminvSchema = $null
function Get-Schema {
  if (-not $script:VminvSchema) {
    $script:VminvSchema = Get-Content -Raw (Join-Path $script:VminvShareDir 'schema.json') | ConvertFrom-Json
  }
  return $script:VminvSchema
}
function Get-TableColumns([string]$table) {
  # returns the ordered column list for a table
  ,@((Get-Schema).tables.$table)
}

# --- jq-compatible number / value formatting --------------------------------
# jq prints integral doubles without a trailing .0 ("1024", not "1024.0") and
# booleans/numbers bare; CSV null -> "" (quoted empty). These helpers reproduce
# that so output matches the bash path exactly.
function Format-JqNumber($n) {
  if ($null -eq $n) { return '' }
  $d = [double]$n
  if ([math]::Floor($d) -eq $d -and [math]::Abs($d) -lt 1e15) {
    return [long]$d -as [string]
  }
  return $d.ToString([System.Globalization.CultureInfo]::InvariantCulture)
}

# Return an integer type when integral (so ConvertTo-Json emits 1024 not 1024.0,
# matching jq); otherwise a double. Keeps JSON byte-comparable with the bash path.
function As-JqNum($d) {
  if ($null -eq $d) { return $null }
  $x = [double]$d
  if ([math]::Floor($x) -eq $x -and [math]::Abs($x) -lt 1e15) { return [long]$x }
  return $x
}

# bytes -> GiB rounded to 2dp, matching jq gib(): floor(b/1073741824*100)/100
function To-Gib($bytes) {
  if (-not $bytes) { return 0 }
  return (As-JqNum ([math]::Floor([double]$bytes / 1073741824 * 100) / 100))
}
function To-Mib($bytes) {
  if (-not $bytes) { return 0 }
  return [long][math]::Floor([double]$bytes / 1048576)
}

# whole days between an ISO-8601 timestamp and a reference epoch (matches age_days)
function Get-AgeDays([string]$iso, [long]$nowEpoch) {
  if (-not $iso) { return $null }
  try {
    $t = [DateTimeOffset]::Parse($iso, [System.Globalization.CultureInfo]::InvariantCulture).ToUnixTimeSeconds()
    return [long][math]::Floor(($nowEpoch - $t) / 86400)
  } catch { return $null }
}
function Get-NowEpoch { [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }

# ConvertFrom-Json auto-converts ISO date strings to [DateTime], which mangles
# timestamps (2026-05-01T08:00:00Z -> 05/01/2026 08:00:00). Parse via
# System.Text.Json instead, which keeps strings as strings — required for
# byte-identical output with the bash path. (-DateKind isn't in PS < 7.5.)
function ConvertFrom-JsonElement($el) {
  switch ($el.ValueKind) {
    'Object' { $o = [ordered]@{}; foreach ($p in $el.EnumerateObject()) { $o[$p.Name] = ConvertFrom-JsonElement $p.Value }; [pscustomobject]$o }
    'Array'  {
      # build explicitly and return with the unary-comma idiom so an EMPTY array
      # is preserved (a bare `@()` return unwraps to $null in PowerShell).
      $arr = [System.Collections.Generic.List[object]]::new()
      foreach ($it in $el.EnumerateArray()) { $arr.Add((ConvertFrom-JsonElement $it)) }
      return , $arr.ToArray()
    }
    'String' { $el.GetString() }
    'Number' { $n = [long]0; if ($el.TryGetInt64([ref]$n)) { $n } else { $el.GetDouble() } }
    'True'   { $true }
    'False'  { $false }
    default  { $null }
  }
}
function ConvertFrom-JsonKeepStrings([string]$json) {
  if (-not $json) { return $null }
  $doc = [System.Text.Json.JsonDocument]::Parse($json)
  try { return (ConvertFrom-JsonElement $doc.RootElement) } finally { $doc.Dispose() }
}

# Format a value as a govc-style ISO-8601 'Z' timestamp if it's a [DateTime]
# (live Get-View returns DateTime); pass strings through unchanged (fixtures).
function Format-IsoMaybe($v) {
  if ($v -is [datetime]) { return ([datetime]$v).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ") }
  return $v
}
