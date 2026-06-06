<!-- Thanks for contributing to vminv! -->

## Summary

<!-- What does this change and why? -->

## Checklist

- [ ] `./tests/run_tests.sh` passes locally
- [ ] `bash -n` clean for changed shell files (shellcheck if available)
- [ ] Stays **strictly read-only** (no mutating vCenter calls)
- [ ] If output/schema changed: updated `share/schema.json` **and** both the
      bash and PowerCLI paths; conformance test still green
- [ ] No secrets in code/logs/output
- [ ] Docs / `--help` / CHANGELOG updated as needed

## Notes for reviewers

<!-- Anything to call out: tradeoffs, follow-ups, testing performed. -->
