# Contributing to vminv

Thanks for your interest in improving **vminv**. Contributions of all kinds are
welcome — bug reports, fixes, docs, and features.

## Ground rules

- **Read-only is sacred.** vminv must never create, modify, power, reconfigure,
  snapshot, or delete anything in vCenter. All vCenter access goes through the
  read-only wrapper (`govc_ro`/`Get-RoView`), and `tests/test_readonly.sh` /
  `test_ps_conformance.sh` fail the build if any mutating verb appears. Don't
  bypass these.
- **Two implementations, one schema.** The bash (`lib/`) and PowerCLI
  (`powershell/`) paths must produce identical output. The columns live in
  `share/schema.json`; if you change a table, update the schema and **both**
  paths, and keep `tests/test_ps_conformance.sh` green.
- **No secrets in code, logs, or output.** Passwords come from env / OS keyring /
  prompt only and are redacted everywhere.

## Development setup

```bash
git clone https://github.com/ivasik-k7/vminv.git
cd vminv
./setup.sh               # vendors govc + jq into ./bin, installs the CLI
./tests/run_tests.sh     # full offline suite (no live vCenter needed)
```

To exercise the bash⇄PowerShell conformance test locally, have PowerShell 7+
available (`pwsh`) — the suite picks it up automatically (or set `PWSH=/path/to/pwsh`).

## Before opening a PR

1. `./tests/run_tests.sh` is green.
2. `bash -n` is clean for any shell file you touched; run `shellcheck` if you have it.
3. New behavior has a test (fixtures live in `tests/fixtures/`, no live vCenter).
4. Docs updated (README / `--help`) if you changed the CLI surface.

CI (`.github/workflows/ci.yml`) runs lint + the full suite on Linux, macOS, and
the PowerCLI path on Windows. PRs should pass it.

## Coding style

- Match the surrounding code: small functions, clear comments, consistent
  CSV/JSON schema shared between the two paths.
- New source files should carry an SPDX header: `# SPDX-License-Identifier: Apache-2.0`.

## Releasing (maintainers)

Versioning is git-tag driven (`git describe`). To cut a release:

```bash
git tag vX.Y.Z && git push origin vX.Y.Z
```

The Release workflow (`.github/workflows/release.yml`) gates on the test suite,
stamps the version from the tag into the artifacts, and publishes a GitHub
Release with the source tarball, the offline Linux bundle, and a `checksums.txt`
that `vminv upgrade` verifies against. (Re-tagging an existing release refreshes
its assets.)

## License

By contributing, you agree that your contributions are licensed under the
[Apache License 2.0](LICENSE), and that you have the right to submit them
(per the DCO/inbound-equals-outbound principle in the Apache License, §5).
