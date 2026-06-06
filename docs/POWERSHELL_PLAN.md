# Plan — PowerCLI parallel implementation (`powershell/`)

> Status: **BUILT.** The Windows-native PowerCLI path is implemented end-to-end
> (collection → utilization → analysis → report → inventory) and produces output
> **byte-identical** to the bash path, proven by the cross-implementation
> conformance test (`tests/test_ps_conformance.sh`, 43 checks) against the
> single-sourced `share/schema.json`. Live mode uses `Get-View`/`Get-Stat`; the
> read-only guard is enforced and tested. Remaining: validate against a live
> vCenter (the one thing fixtures can't cover). This document is the original
> design; it matched the build closely.

## 1. Goal & non-negotiables

A self-contained PowerShell implementation that, given the same vCenter and
config, produces **byte-for-byte schema-compatible** output (same files, same
CSV headers, same JSON keys) as the bash path — so downstream consumers don't
care which path produced a run.

Inherited, non-negotiable from the bash tool:

1. **Strictly read-only.** Never call a mutating cmdlet. Enforced in code +
   tested (see §5), and run under a read-only vCenter account as defence in depth.
2. **No credential leakage.** Password via `$env:VCENTER_PASSWORD`, SecretManagement
   vault, or prompt (`Read-Host -AsSecureString`). Never written to logs/profiles.
3. **Schema parity.** The output is the contract (§3). Headers/keys must not drift.
4. **Fixture-testable offline.** A `Get-RoView` abstraction reads canned data when
   `$env:VMINV_FIXTURES` is set — mirroring the bash fixture mode — so the whole
   pipeline runs and is unit-tested with no live vCenter.
5. **Scale.** Use the property collector (`Get-View -Property …`) and bulk
   `Get-Stat`, never per-object round-trips.

## 2. The parity contract (output the PS path must reproduce)

Per run, identical to bash — each category as `<name>.csv` + `<name>.json`, plus
`inventory.json`, `summary.md`, `summary.html`, `run.log`:

| Category | CSV columns (authoritative) |
|---|---|
| datacenters | `name,moref` |
| clusters | `name,num_hosts,num_effective_hosts,drs_enabled,drs_behavior,ha_enabled,evc_mode,total_cpu_mhz,total_memory_gib,moref` |
| licenses | `name,edition,total,used,license_key_tail` |
| hosts | `name,vendor,model,cpu_model,sockets,cores,threads,memory_gib,esxi_version,esxi_build,connection_state,power_state,license_edition,cluster_moref,moref` |
| standard_switches | `host,name,num_ports,mtu` |
| standard_portgroups | `host,name,vlan_id,vswitch` |
| datastores | `name,type,capacity_gib,free_gib,used_gib,pct_used,vm_count,accessible,moref` |
| dvswitches | `name,num_ports,version,uuid,moref` |
| networks | `name,kind,vlan_id,switch,moref` |
| resourcepools | `name,kind,cpu_reservation_mhz,cpu_limit_mhz,cpu_shares,mem_reservation_mib,mem_limit_mib,mem_shares,moref` |
| vms | 43 cols (`name,power_state,migration_status,blocker_count,guest_os,…,instance_uuid,moref`) |
| disks | `vm,label,provisioned_gib,used_gib,provisioning,disk_mode,independent,sharing,is_rdm,controller_type,datastore,vmdk_path,vm_moref` |
| nics | `vm,label,adapter_type,mac_address,portgroup,vlan_id,connected,ip_addresses,vm_moref` |
| snapshots | `vm,name,description,created,age_days,quiesced,state,id,vm_moref` |
| utilization | 24 cols (avg/peak/p95 for cpu/mem/disk/net + `insufficient_data`) |
| blockers | `vm,severity,blocker,detail,cluster,vm_moref` |
| rightsizing | `vm,basis,configured_vcpu,…,candidate_instance,candidate_vcpu,candidate_mem_gib,fits,vm_moref` |
| licensing | `vm,windows_server,sql_server,oracle,note,vm_moref` |

**Single-sourcing the schema (recommended refactor):** extract these column
lists + the assembler key map into one `share/schema.json` consumed by **both**
implementations (bash replaces its `*_CSV_KEYS` literals by reading it; PS reads
it directly). A conformance test then guarantees neither path can drift. This is
the single highest-leverage step for guaranteeing parity.

## 3. govc → PowerCLI mapping

| Concern | bash (govc) | PowerCLI |
|---|---|---|
| Connect | `GOVC_URL` env | `Connect-VIServer -Server -User -Password` (read-only acct) |
| Bulk props | `govc object.collect -type X / p1 p2` | `Get-View -ViewType X -Property p1,p2` |
| about | `govc about -json` | `$global:DefaultVIServer` / `$svc.Content.About` |
| hosts/clusters/ds/net/rp | `object.collect -type h/c/s/n/p` | `Get-View -ViewType HostSystem/ClusterComputeResource/Datastore/Network/ResourcePool` |
| dvSwitch / dvPortgroup | `-type w` / `-type g` | `Get-View -ViewType VmwareDistributedVirtualSwitch / DistributedVirtualPortgroup` |
| VMs (full) | `-type m … config.hardware.device snapshot layoutEx` | `Get-View -ViewType VirtualMachine -Property Name,Config.*,Guest.*,Runtime.*,Summary.*,Snapshot,LayoutEx` |
| folders | `-type f name parent` | `Get-View -ViewType Folder -Property Name,Parent` |
| perf | `govc metric.sample -i -n …` | `Get-Stat -Entity -Stat … -IntervalMins/-MaxSamples -Start -Finish` |
| tags | `govc tags.*` | `Get-TagAssignment` / `Get-Tag` / `Get-TagCategory` |
| licenses | `license.ls` / `license.assigned.ls` | `Get-View LicenseManager` → `.Licenses`; `LicenseAssignmentManager.QueryAssignedLicenses()` |

**Key insight:** because we already collect via the property collector, the PS
path uses the *same* managed-object property paths — only the access call and the
JSON casing differ. The normalization layer per impl produces the shared schema.

## 4. Project layout (`powershell/`)

```
powershell/
  Vminv.psd1                 # module manifest (version, exports, PowerCLI dependency)
  Vminv.psm1                 # dot-sources Public/ + Private/
  Public/
    Invoke-VminvScan.ps1     # = `vminv scan`
    Connect-Vminv.ps1        # connection + dry-run
    Invoke-VminvConfigure.ps1, ...   # configure/profiles/upload/schedule/upgrade parity
  Private/
    Get-RoView.ps1           # READ-ONLY view accessor + fixture mode (the chokepoint)
    Collect-Infra.ps1, Collect-Vms.ps1, Collect-Perf.ps1
    Analyze-Blockers.ps1, Get-Rightsizing.ps1, Write-Report.ps1
    Write-VminvCsv.ps1       # CSV writer that MATCHES json_to_csv quoting exactly
    Common.ps1               # logging+redaction, config/profiles, schema loader
  vminv.ps1                  # thin console entrypoint: same `vminv <cmd> --flags` UX
  tests/
    fixtures/                # canned views (JSON) mirroring ../tests/fixtures
    *.Tests.ps1              # Pester v5
```

## 5. Read-only enforcement (mirrors the govc allowlist)

Three layers, same philosophy as bash:

1. **Single chokepoint.** All vCenter reads go through `Get-RoView` (and a small
   set of read accessors: `Get-Stat`, `Get-TagAssignment`, `Get-VIPermission`).
   No other cmdlet touches vCenter.
2. **Deny-by-default static test.** A Pester test greps the module for any
   mutating PowerCLI verb — `Set-`, `New-`, `Remove-`, `Start-`, `Stop-`,
   `Restart-`, `Suspend-`, `Move-`, `Mount-`, `Copy-`, `Update-`, `Invoke-VM*`,
   `*-Snapshot` (write), `*-HardDisk` (write) — and **fails the build** if found.
   (A custom PSScriptAnalyzer rule is the stronger version.)
3. **Least privilege account** (documented requirement, same as bash README).

`Set-PowerCLIConfiguration` (cert action / CEIP) is local client config, not a
vCenter mutation — allowed in `setup.ps1` only.

## 6. Two genuine parity gotchas (call them out early)

- **CSV quoting.** Bash `json_to_csv` quotes strings, leaves numbers/bools bare,
  empty for null. `Export-Csv` quotes *everything* and adds types. → Ship a
  `Write-VminvCsv` that reproduces the bash rules exactly; test header+row parity.
- **JSON casing & null handling.** PowerCLI returns PascalCase; govc JSON is
  lowerCamel. Both normalize into the shared schema in their `Collect-*` layer,
  so the *output* matches even though the *source* differs. `ConvertTo-Json
  -Depth 12 -Compress`; map absent → `$null`; booleans as real JSON booleans.

## 7. Analysis reuse strategy

`blockers`, `rightsizing`, `report` are **pure transforms over normalized data**.
- The **rules stay single-sourced as data**: `matrices/os_support.csv`,
  `matrices/instance_types_*.csv`, and the `THRESHOLD_*` values are shared files
  both impls read.
- The **algorithms are re-implemented in PS** (so Windows users need no bash/jq),
  but a conformance test runs both impls on identical fixtures and asserts the
  blocker findings, readiness, right-sizing candidates, and report totals match.

## 8. Testing

- **Pester v5** unit tests per `Collect-*`/`Analyze-*` against JSON fixtures via
  `Get-RoView` fixture mode (no live vCenter) — mirrors `tests/test_*_parse.sh`.
- **Read-only guard test** (§5.2).
- **Cross-implementation conformance test** (can live in `tests/`): run bash and
  PS against equivalent fixtures → diff CSV headers, JSON keys, and analysis
  results. This is what *proves* parity and prevents drift.
- CI matrix: pwsh on Windows + Linux (PowerShell 7 is cross-platform; PowerCLI
  core cmdlets run on both, easing fixture-mode testing in Linux CI).

## 9. Risks & mitigations

| Risk | Mitigation |
|---|---|
| PowerCLI property paths differ subtly from govc | Normalize per-impl into shared schema; conformance test catches mismatches |
| `Get-Stat` interval/instance semantics ≠ govc metric.sample | Encapsulate in `Collect-Perf`; assert stats on a fixture with known values |
| CSV/JSON formatting drift | Custom `Write-VminvCsv`; golden-file tests |
| Windows execution policy / module install friction | `setup.ps1` handles install + `-Scope CurrentUser`; document `Set-ExecutionPolicy` |
| Maintaining two codebases | Single-sourced schema + rules data + conformance test minimize divergence |

## 10. Phased delivery (each phase runnable + conformance-tested)

1. **Foundation** — module skeleton, `Common.ps1` (logging/redaction/profiles/
   schema loader), `Get-RoView` (+ fixture mode), `Write-VminvCsv`, `setup.ps1`
   module install. Read-only guard test.
2. **Connection + dry-run** — `Connect-Vminv`, about/version, single-list proof.
3. **Infrastructure** — clusters/hosts/datastores/networks/dvs/rp/licenses +
   standard switching. Conformance vs bash infra fixtures.
4. **VMs + sub-tables** — full vms + disks/nics/snapshots + tags + folder paths.
5. **Utilization** — `Get-Stat` → avg/peak/p95, insufficient-data flag.
6. **Analysis** — blockers, rightsizing, licensing, report (md+html).
7. **CLI surface** — `vminv.ps1` subcommands/flags parity; configure/profiles/
   upload/schedule (Windows Task Scheduler analog of cron)/upgrade.
8. **Conformance suite** — full bash⇄PS diff on the shared fixtures; CI.

## 11. Rough effort

~Comparable to the bash build: foundation + infra + VMs are the bulk. The shared
schema/rules data removes most analysis re-derivation risk. Biggest unknowns are
`Get-Stat` semantics and CSV-format parity — both isolated and fixture-testable.
