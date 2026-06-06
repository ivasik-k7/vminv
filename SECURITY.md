# Security Policy

## Reporting a vulnerability

Please report security issues **privately** — do not open a public issue.

- Preferred: open a **GitHub private security advisory** for this repository
  (Security → *Report a vulnerability*).
- Alternatively, contact the maintainer **@ivasik-k7** privately.

Please include reproduction steps and the affected version (`vminv version`).
You can expect an acknowledgement within a few days.

## Supported versions

The latest released version receives security fixes.

## Security posture of vminv

vminv is designed defensively; keep these guarantees in mind when assessing risk:

- **Read-only by construction.** vminv only issues read/query calls to vCenter.
  All access goes through a single wrapper that allowlists read-only verbs, and a
  build test fails if any mutating verb appears in the code. Run it under a
  least-privilege **Read-only** vCenter account as defence in depth.
- **No secret persistence.** The vCenter password is never written to a profile,
  log, or output. It comes from `$VCENTER_PASSWORD`, the OS keyring, or an
  interactive prompt, and is redacted from all logs/console output.
- **Pinned, checksum-verified tooling.** `setup.sh` downloads pinned versions of
  `govc` and `jq` and verifies their SHA-256 against `checksums.txt`.
- **Verified self-update.** `vminv upgrade` pulls from the official GitHub
  Releases of `ivasik-k7/vminv` and verifies the download against the release
  `checksums.txt`.
- **TLS.** Certificate verification is on by default; `VCENTER_INSECURE=true`
  disables it (for labs) and warns loudly on every run.

If you believe any of these guarantees can be bypassed, that is a security issue
worth reporting.
