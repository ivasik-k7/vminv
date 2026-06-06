#!/usr/bin/env bash
# Cross-implementation conformance: the PowerShell path must produce output
# IDENTICAL to the bash path for the same fixtures. CSV is compared byte-for-byte
# (the RVTools deliverable); JSON semantically (key-order-independent).
#
# Compares the COLLECT stage (infra + VMs/disks/nics/snapshots), before the
# analysis pass. Skips gracefully if PowerShell is unavailable (set PWSH).
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "${HERE}/.." && pwd)"
source "${HERE}/lib.sh"
JQ="${ROOT}/bin/jq"
NORM='map(to_entries|sort_by(.key)|from_entries)|sort_by(tojson)'

PWSH="${PWSH:-$(command -v pwsh || true)}"
[ -z "$PWSH" ] && [ -x /tmp/pwsh/pwsh ] && PWSH=/tmp/pwsh/pwsh

echo "== PowerShell read-only static guard =="
# vСenter-mutating PowerCLI cmdlets (scoped to vSphere nouns so benign cmdlets
# like Remove-Item / Set-Content / Set-Variable are not flagged).
mut='New-VM|Set-VM|Start-VM|Stop-VM|Restart-VM|Suspend-VM|Move-VM|Invoke-VMScript|New-Snapshot|Remove-Snapshot|Set-Snapshot|Set-VMHost|Remove-VMHost|New-HardDisk|Set-HardDisk|Remove-HardDisk|Remove-VM|Remove-Datastore|New-VDSwitch|Remove-VDSwitch|Set-VMHostNetwork|Mount-VMHostDatastore|Set-NetworkAdapter|New-VMHostNetworkAdapter'
if grep -rnE "$mut" "${ROOT}/powershell" --include='*.ps1' | grep -vE '^\s*#' >/dev/null 2>&1; then
  _fail "mutating PowerCLI verb found in powershell/"
else
  _pass "no mutating PowerCLI verbs in powershell/"
fi

if [ -z "$PWSH" ]; then
  echo "  (pwsh not found — skipping live conformance run; set PWSH=/path/to/pwsh)"; finish
fi

A="$(mktemp -d)"; B="$(mktemp -d)"
trap 'rm -rf "$A" "$B"' EXIT

# bash FULL reference scan (collect + utilization + analysis)
( cd "$ROOT" && ./vminv --fixtures "${HERE}/fixtures" --output "$A" >/dev/null 2>&1 ) || true
C="$(ls -d "$A"/*/ 2>/dev/null | head -1)"; C="${C%/}"
[ -n "$C" ] || _fail "bash reference scan produced no run dir"

# PowerShell full scan via the real public entrypoint (Invoke-VminvScan)
psrun="$("$PWSH" -NoProfile -Command "Import-Module '${ROOT}/powershell/Vminv.psd1' -Force; \$env:VMINV_FIXTURES='${HERE}/fixtures'; Invoke-VminvScan -Output '${B}' -Target aws 6>\$null 5>\$null 4>\$null 3>\$null 2>\$null | Select-Object -Last 1" 2>/dev/null | tail -1)"
B="${psrun%/}"
[ -n "$B" ] && [ -d "$B" ] || _fail "pwsh Invoke-VminvScan produced no run dir"

TABLES="datacenters clusters licenses hosts standard_switches standard_portgroups \
        datastores dvswitches networks resourcepools vms disks nics snapshots tags \
        utilization blockers rightsizing licensing"

echo "== CSV byte-identical (bash vs PowerShell) =="
for t in $TABLES; do
  if [ -f "${C}/${t}.csv" ] && [ -f "${B}/${t}.csv" ]; then
    if diff -q "${C}/${t}.csv" "${B}/${t}.csv" >/dev/null; then _pass "csv ${t}"; else _fail "csv ${t} differs"; fi
  else
    _fail "csv ${t} missing (bash:$( [ -f "${C}/${t}.csv" ] && echo y || echo n) ps:$( [ -f "${B}/${t}.csv" ] && echo y || echo n))"
  fi
done

echo "== JSON semantically equal =="
for t in $TABLES; do
  if [ -f "${C}/${t}.json" ] && [ -f "${B}/${t}.json" ]; then
    if diff -q <("$JQ" -S "$NORM" "${C}/${t}.json") <("$JQ" -S "$NORM" "${B}/${t}.json") >/dev/null; then _pass "json ${t}"; else _fail "json ${t} differs"; fi
  fi
done

echo "== inventory.json + vcenter.json semantically equal =="
if diff -q <("$JQ" -S 'del(.meta.generated_at, .meta.version)' "${C}/inventory.json") <("$JQ" -S 'del(.meta.generated_at, .meta.version)' "${B}/inventory.json") >/dev/null; then _pass "inventory.json"; else _fail "inventory.json differs"; fi
if diff -q <("$JQ" -S . "${C}/vcenter.json") <("$JQ" -S . "${B}/vcenter.json") >/dev/null; then _pass "vcenter.json"; else _fail "vcenter.json differs"; fi

echo "== report byte-identical (timestamp-normalized) =="
for f in summary.md summary.html; do
  if [ -f "${C}/${f}" ] && [ -f "${B}/${f}" ]; then
    if diff -q <(sed 's/ · generated .*//' "${C}/${f}") <(sed 's/ · generated .*//' "${B}/${f}") >/dev/null; then _pass "$f"; else _fail "$f differs"; fi
  else
    _fail "$f missing"
  fi
done

finish
