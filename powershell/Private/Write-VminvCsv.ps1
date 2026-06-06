# Write-VminvCsv.ps1 — CSV writer that reproduces bash json_to_csv (jq @csv)
# EXACTLY, so output is byte-identical to the bash path:
#   * strings  -> quoted, internal " doubled
#   * numbers  -> bare, integral values without a trailing .0
#   * booleans -> bare lowercase true/false
#   * null     -> "" (quoted empty), matching jq's null->"" then @csv
# Lines are LF-terminated with a trailing newline (matches jq -r).

function Format-CsvField($v) {
  if ($null -eq $v) { return '""' }
  if ($v -is [bool]) { if ($v) { return 'true' } else { return 'false' } }
  if ($v -is [int] -or $v -is [long] -or $v -is [double] -or $v -is [decimal] -or $v -is [int64] -or $v -is [int32]) {
    return (Format-JqNumber $v)
  }
  # everything else is a string
  return '"' + ([string]$v -replace '"', '""') + '"'
}

# Write-VminvCsv -Records <array> -Table <name> -Path <file>
function Write-VminvCsv {
  param([object[]]$Records, [string]$Table, [string]$Path)
  $cols = Get-TableColumns $Table
  $sb = [System.Collections.Generic.List[string]]::new()
  $sb.Add( ($cols | ForEach-Object { '"' + ($_ -replace '"', '""') + '"' }) -join ',' )
  foreach ($r in $Records) {
    $fields = foreach ($c in $cols) {
      $val = if ($r.PSObject.Properties[$c]) { $r.$c } else { $null }
      Format-CsvField $val
    }
    $sb.Add( ($fields -join ',') )
  }
  [System.IO.File]::WriteAllText($Path, ($sb -join "`n") + "`n")
}

# Write a records array as pretty JSON (semantically matches the bash .json).
function Write-VminvJson {
  param([object[]]$Records, [string]$Path)
  $json = if ($Records -and $Records.Count -gt 0) {
    ConvertTo-Json -InputObject @($Records) -Depth 24
  } else { '[]' }
  [System.IO.File]::WriteAllText($Path, $json + "`n")
}
