<!--
Thanks for the PR. Use the sections below; delete what's not relevant.
For anything beyond a trivial fix, please link the issue that motivated
the change so reviewers have the context.
-->

## Summary

<!-- One or two sentences on what changed and why. -->

## Linked issue

<!-- Closes #123, or "n/a" for trivial fixes. -->

## Test plan

<!-- Mark each that applies; delete the rest. -->

- [ ] `prove -r t/` passes locally
- [ ] Added or updated tests under `t/` covering the new behavior
- [ ] Verified `--dry-run` against the example config still works
- [ ] Exercised the change against a real PVE cluster (describe below)

## Compatibility checklist

<!-- For non-trivial changes. Leave the boxes you've actually verified. -->

- [ ] Stays compatible with Perl 5.14 (the CI matrix floor)
- [ ] No new CPAN dependencies, or new deps are listed in `README.md` and `.github/workflows/*.yml`
- [ ] Status aggregation uses `max_status()`, not summing codes
- [ ] Threshold checks go through `evaluate_threshold()`
- [ ] Debug output goes through the `debug` helper (STDERR-bound)
- [ ] `--json` output reflects the new data, if applicable
- [ ] `CHANGELOG.md` Unreleased section updated
- [ ] `README.md` / `CLAUDE.md` updated if user-facing behavior changed

## Additional context

<!-- Anything reviewers should know that isn't obvious from the diff. -->
