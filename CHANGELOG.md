# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] - 2026-06-06

Initial public release.

### Added
- **Strictly read-only** vSphere inventory & migration-readiness assessment,
  with the read-only guarantee enforced in code and tested.
- **Bash + govc** implementation: infrastructure (datacenters, clusters with
  DRS/HA/EVC, hosts + licenses, datastores, networks/VLANs, vDS, resource pools/
  vApps); full per-VM table with disks/NICs/snapshots, tags, and folder paths;
  utilization (CPU/mem/disk/net avg/peak/p95); migration blocker analysis;
  right-sizing to candidate cloud instances; licensing flags; and a
  `summary.md`/`summary.html` report. Outputs CSV per category plus a combined
  `inventory.json`.
- **PowerCLI implementation** (`powershell/`) producing byte-identical output,
  proven by a cross-implementation conformance test against the single-sourced
  `share/schema.json`.
- **Industry-standard CLI**: `scan`, `configure`, `config`, `doctor`, `demo`,
  `profiles`, `upload`, `schedule`, `upgrade`, `completion`; named profiles with
  optional OS-keyring secrets; pluggable upload destinations (S3 / GCS / Azure /
  SFTP / HTTPS-JFrog / local path); cron scheduling; shell completion; man page;
  distinct exit codes; and a machine-readable `--format json` mode.
- **Tooling & CI/CD**: `setup.sh` installs pinned, checksum-verified `govc`+`jq`
  and the CLI; git-tag-driven versioning; multi-OS CI (Linux/macOS + the PowerCLI
  path on Windows) with the bash⇄PowerShell conformance suite; downloadable build
  artifacts (source + offline Linux bundle); and a release pipeline publishing a
  verifiable `checksums.txt` that `vminv upgrade` checks against.
- Project governance: Apache-2.0 `LICENSE`/`NOTICE`, `CONTRIBUTING.md`,
  `CODE_OF_CONDUCT.md`, `SECURITY.md`, issue/PR templates, and `CODEOWNERS`.

[0.2.0]: https://github.com/ivasik-k7/vminv/releases/tag/v0.2.0
