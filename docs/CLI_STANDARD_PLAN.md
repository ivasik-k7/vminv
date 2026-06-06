# Plan — industry-standard CLI interface hardening

> Status: **design.** Audits the current `vminv` CLI against established CLI
> guidelines (POSIX/GNU conventions, clig.dev, 12-factor CLI, and the de-facto
> patterns of `git`/`kubectl`/`aws`/`docker`) and defines the target plus a
> phased implementation. Goal: an interface that feels native to anyone who uses
> modern CLIs, is scriptable, and is robust under automation.

## A. Audit — where we are today

Already good:
- ✅ Subcommands (`scan/configure/profiles/upload/schedule/upgrade/version/help`)
- ✅ Long flags with `--flag value` **and** `--flag=value`
- ✅ Diagnostics/logs to **stderr**, structured `run.log` with secret redaction
- ✅ Color only on TTY; `--dry-run`; profiles + env + file precedence
- ✅ `set -euo pipefail`, bash-version preflight, read-only guarantee
- ✅ Non-zero exits via `die`

Gaps vs. industry standard:
- ❌ **Exit codes** are all `1` — no distinct, documented codes (usage vs auth vs
  partial-data vs connectivity).
- ❌ **No machine-output discipline**: scan prints human text; no `--output
  json|table`, no clean stdout-is-data contract for piping.
- ❌ **No short flags** (`-h` only); no `-n` dry-run, `-p` profile, `-v` verbose.
- ❌ **Per-command help is one global blob** — no `vminv <cmd> --help`.
- ❌ **No verbosity/quiet control** (`-v/-q`), no `--no-color` / `NO_COLOR`,
  `--no-progress`.
- ❌ **No shell completion** (bash/zsh/fish).
- ❌ **No temp-file/signal cleanup trap** — Ctrl-C mid-scan can leak temp dirs;
  partial run dirs aren't marked.
- ❌ **No `--` end-of-options terminator**; unknown flags are silently shoved to
  the subcommand.
- ❌ **No man page**; `--version` not machine-parseable beyond a string.
- ❌ Secret-file creation doesn't set a strict `umask` defensively.
- ❌ No "did you mean …" on unknown command; no consistent `usage:` on error.

## B. Target conventions (the standard we adopt)

1. **Streams**: machine data → stdout; everything else (logs, progress, prompts,
   errors) → stderr. A command's stdout must be safe to pipe.
2. **Exit codes** (documented in `--help` and README):
   | code | meaning |
   |---|---|
   | 0 | success |
   | 1 | generic runtime error |
   | 2 | usage / bad arguments |
   | 3 | connectivity / authentication failure |
   | 4 | completed with partial data (some objects unreadable) |
   | 130 | interrupted (SIGINT) |
3. **Flags**: GNU long + common short aliases; repeatable where sensible; `--`
   terminates option parsing; `--flag=value` and `--flag value` both work
   (already true). Global flags (`--profile`, `-v`, `-q`, `--no-color`,
   `--output`) accepted before or after the subcommand.
4. **Help**: `vminv`, `vminv help`, `vminv --help`, and `vminv <cmd> --help` all
   work; each subcommand has a focused usage block with **examples**.
5. **Output modes**: `--output table|json` (default `table`/human for TTY).
   `scan` already writes files; add a final machine summary to stdout when
   `--output json` (path to run dir + counts), so it composes in pipelines.
6. **Verbosity**: `-q/--quiet` (errors only), default (phases+results),
   `-v/--verbose` (debug to stderr). `--no-color` + honor `NO_COLOR` env.
   `--no-progress` for CI logs.
7. **Errors**: every error one line, `vminv: <context>: <message>` to stderr,
   with an actionable hint; usage errors print a short usage and exit 2.
   Unknown command → nearest-match suggestion.
8. **Completion**: `vminv completion bash|zsh|fish` emits a script; documented
   install one-liner. Completes commands, flags, and profile names.
9. **Robustness**: a single `trap` cleans temp dirs on EXIT/INT/TERM; partial run
   dirs get a `INCOMPLETE` marker on interrupt; `umask 077` before writing
   secrets/profiles; strict validation of enums (target/interval) already partly
   present — extend with clear exit 2.
10. **Discoverability**: `--version` prints `vminv X.Y.Z` (parseable);
    `vminv version --json` prints `{ "version": "...", "govc": "...", "jq": "..." }`.
11. **Docs**: a `man/vminv.1` man page generated/maintained; `setup.sh` optionally
    installs it to the user man path.
12. **Config**: keep precedence (CLI > env > profile > .env > default); add
    `vminv config get|set KEY [VALUE]` later (optional) for parity with `git config`.

## C. Design decisions to confirm

- **Backwards compatibility**: current flags keep working; we *add* short aliases
  and modes, change exit codes (a behavior change, but for the better), and route
  human text to stderr while reserving stdout for `--output json`. The default
  human experience stays the same.
- **Scope of v1 of this work**: B-1..B-9 (streams, exit codes, flags, per-command
  help, output modes, verbosity, errors, completion, robustness). Man page (B-11)
  and `config get/set` (B-12) are a fast-follow.

## D. Implementation plan (phased, each independently shippable)

1. **Error/exit-code framework** — introduce `EX_USAGE=2 EX_CONN=3 EX_PARTIAL=4`;
   `die [code] msg`; `usage_error` (exit 2 + short usage); a `PARTIAL` flag that
   makes `scan` exit 4 when any collector logged a failure. Update `prepare_
   connection` to exit 3 on auth/connect failure. Document in `--help`.
2. **Stream + verbosity + color discipline** — add `-q/--quiet`, `-v/--verbose`
   (sets debug-to-stderr), `--no-color`, honor `NO_COLOR`, `--no-progress`.
   Gate `info/ok/progress` on the level. Confirm nothing non-data hits stdout.
3. **Flag system polish** — short aliases (`-n` dry-run, `-p` profile, `-o`
   output, `-C` config), `--` terminator, accept global flags pre/post command,
   reject truly-unknown flags with exit 2 + suggestion.
4. **Per-command help** — a `help_<cmd>` for each subcommand with synopsis,
   options, and 2–3 examples; `vminv <cmd> --help` and `vminv help <cmd>` route to it.
5. **Output modes** — `--output table|json`; `scan` emits a JSON result object on
   stdout in json mode (`{run_dir, counts, readiness, summary_md}`); `profiles`,
   `schedule list`, `blockers` gain `--output json`.
6. **Robustness** — global `trap` cleanup of temp dirs (also in `upload.sh`’s
   `pack_run`), INT/TERM → exit 130 + mark run dir `INCOMPLETE`; `umask 077`
   before writing `.env`/profiles; validate enums → exit 2.
7. **Shell completion** — `vminv completion <shell>`; dynamic profile-name
   completion; install hint in README + `setup.sh` (optional).
8. **Suggestions & polish** — Levenshtein-ish nearest command on typo; consistent
   `vminv: <cmd>: <error>` prefix.
9. **Man page + docs** — `man/vminv.1`; `setup.sh --man` install; README CLI
   reference table of every command/flag/exit-code.
10. **Interface tests** — golden `--help` output per command; exit-code tests
    (usage=2, bad target=2, fixture connect path); `--output json` schema test;
    "stdout is clean data in json mode" test; completion script smoke test.

## E. Acceptance criteria

- `vminv <cmd> --help` exists for every command, with examples.
- Distinct, documented exit codes; verified by tests.
- `vminv scan --output json --quiet` prints **only** a JSON object to stdout.
- `NO_COLOR=1` and non-TTY produce no escape codes.
- Ctrl-C during a scan leaves no orphan temp dir; run dir marked incomplete.
- `vminv completion bash` produces a working completion (commands + flags + profiles).
- Secret files are mode 600 created under `umask 077`.
- A test suite (`tests/test_cli_iface.sh`) covers help/exit-codes/output-modes.
