# vminv — VMware vSphere pre-migration inventory & assessment

`vminv` performs a **strictly read-only** inventory and migration-readiness
assessment of a VMware vSphere environment, so you can plan a lift to AWS, Azure,
or GCP. It captures configuration, utilization, and migration risk across the
estate and emits machine-readable data (CSV + JSON) plus a human-readable report.

Two interchangeable implementations produce **byte-identical output**: a
**bash + govc** path (default, runs anywhere) and a **PowerCLI** path
(`powershell/`, Windows-native). The shared schema lives in `share/schema.json`.

## Read-only guarantee

vminv **never** creates, modifies, powers, reconfigures, snapshots, or deletes
anything in vCenter — only read/query calls. It's enforced, not just promised:
all vCenter access goes through one wrapper that **allowlists read-only verbs**,
and a test fails the build if any mutating verb appears in the code. Use a
vCenter account with the built-in **Read-only** role as defence in depth.

## Quick start

```bash
./setup.sh                 # downloads pinned govc + jq (checksum-verified), installs the `vminv` CLI
vminv demo                 # see the FULL pipeline on bundled sample data — no vCenter, no credentials
vminv configure prod       # set vCenter host + a read-only service account (aws-cli style)
vminv doctor               # check readiness; tells you exactly what's missing
vminv --profile prod --dry-run   # safe first contact: read-only login + list one object
vminv --profile prod             # full scan
```

Requires **bash 4+** (macOS: `brew install bash`), plus `curl`/`wget` and `tar`.
No root needed — tools install into `./bin`.

## Commands

| Command | What |
|---|---|
| `vminv [scan]` | collect inventory + utilization + migration blockers |
| `vminv demo` | full scan on bundled fixtures (no vCenter/credentials) |
| `vminv configure [P]` | create/update a profile — interactive or `--set KEY=VAL` |
| `vminv config` | print effective config + where the password comes from |
| `vminv doctor` | diagnose readiness + next steps |
| `vminv profiles [show P]` | list / print profiles |
| `vminv upload DIR --dest URL` | ship a run to s3://, gs://, az://, sftp://, https:// (JFrog), or a path |
| `vminv schedule add\|list\|remove\|run` | cron job that scans + uploads (5 presets) |
| `vminv upgrade` | self-update from GitHub Releases |
| `vminv completion bash\|zsh\|fish` | shell completion |

`vminv <command> --help` for details. Global flags: `-p/--profile`, `-n/--dry-run`,
`--target`, `--datacenter/--cluster/--folder/--vm`, `--no-perf`, `--format json`,
`-q/-v`, `--no-color`, `--fixtures DIR`.

## Configuration & credentials

Profiles (non-secret) live in `~/.config/vminv/profiles/<name>.env`. The vCenter
**password is never stored in a profile** — supply it via `$VCENTER_PASSWORD`,
the OS keyring, or an interactive prompt (chosen at `configure` time). Logs are
redacted; secrets never reach `run.log` or stdout. `.env`/profiles are mode 600.

Override precedence: CLI flag › env var › `--profile` › repo `.env` › defaults.

## What it collects

- **Infrastructure** — datacenters; clusters (DRS/HA/EVC); hosts (CPU/RAM, ESXi
  build, license); datastores (type, capacity/used, VM count); networks + VLANs;
  vDS; resource pools / vApps; licenses.
- **Per-VM** — identity, folder path, tags; compute & memory (reservations/limits);
  per-disk (size, thin/thick/RDM, sharing, controller, datastore); per-NIC
  (adapter, MAC, port group/VLAN, IPs); guest OS; firmware/Secure Boot; hardware
  version; VMware Tools; snapshots; placement; encryption/FT flags.
- **Utilization** — CPU/mem/disk/net **avg/peak/p95** over `PERF_WINDOW_DAYS`
  (insufficient-history VMs are flagged and sized on configured capacity).
- **Migration blockers** — RDM, multi-writer/shared disk, PCI/vGPU passthrough,
  vTPM, VM encryption, Fault Tolerance, connected ISO/USB/serial, stale snapshots,
  independent disks, old hardware, unsupported guest OS, oversized disks/VMs,
  missing Tools — severity-sorted, with per-VM **ready / needs-work / blocked**.

## Output

Each run writes `./output/<UTC-timestamp>/`: a CSV **and** JSON per category
(RVTools-style), a combined `inventory.json`, a `summary.md` + `summary.html`
assessment report (estate totals, readiness, right-sizing rollup, top blockers,
per-cluster/datastore rollups, licensing flags), and a redacted `run.log`.
Right-sizing maps each VM to a candidate cloud instance using the editable
matrices in `matrices/` (instance types per cloud, OS support allowlist).

## Required vCenter permissions

A dedicated service account with the built-in **`Read-only`** role at the vCenter
root, propagated to children. For tighter scoping, grant `Read-only` on specific
datacenters/clusters/folders and use the matching `--datacenter/--cluster/...`
filters.

## Exit codes

`0` ok · `2` usage/bad args · `3` connectivity/auth · `4` partial data · `130`
interrupted · `1` other. Human output goes to stderr; `--format json` puts a
machine-readable result on stdout.

## Project layout

```
setup.sh / setup.ps1     installers (CLI + tools / PowerCLI module)
vminv                    main bash entrypoint
lib/                     bash collection + analysis modules
powershell/              PowerCLI parallel implementation (mirrors the schema)
share/schema.json        single source of truth for output columns
matrices/                editable OS-support + instance-size tables
tests/                   fixture-based suite (no live vCenter needed)
docs/                    design notes (PowerCLI, CLI standards)
```

## Testing

```bash
./tests/run_tests.sh     # 240+ offline assertions, no live vCenter
```
Everything is developed against mock fixtures in `tests/fixtures/`. A
cross-implementation conformance test proves the bash and PowerCLI paths produce
identical output. The only thing fixtures can't cover is the first run against a
real vCenter — start with `--dry-run`, then a scoped `--cluster` scan, and verify
the output against what you know.

## Status

Feature-complete across all stages in **both** implementations, industry-standard
CLI, fully offline-tested. Pending: validation against a live vCenter (API-format
assumptions are isolated for an easy fix when you get there).
