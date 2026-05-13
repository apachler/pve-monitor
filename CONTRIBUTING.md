# Contributing to pve-monitor

Thanks for considering a contribution. This document is short on purpose — it's a small, single-file Perl plugin, not a framework.

## Reporting bugs and asking for features

- Bugs: open a GitHub issue using the **Bug report** template. The template asks for the plugin version, the `Net::Proxmox::VE` version, the PVE version, the exact `perl pve-monitor.pl --debug ...` command, and `--debug --json` output for the run. Triaging is much faster when those fields are populated.
- Features: open an issue using the **Feature request** template before sending code, especially for new check modes. The four most-asked-for modes (backup-job freshness, snapshot age, replication status, tag-based discovery) are tracked in `CLAUDE.md`'s "Feature Backlog" section.
- **Security issues** go to a private channel — see [`SECURITY.md`](SECURITY.md). Do not open a public issue for those.

## Branching and commits

- The protected branch is `master`. All work happens on a feature branch (any name; descriptive is better than terse).
- Open the PR against `master`. The CI workflows (`test`, `coverage`) must pass before merge. The coverage workflow enforces a floor — see `.github/workflows/coverage.yml`.
- Commit messages are imperative-mood subject + a body that explains the *why*. Example:
  ```
  Fix die on undef /cluster/resources; add regression test

  If a PVE node returns 200-with-no-body for /cluster/resources, ...
  ```
  One commit per logical change; intermediate refactors are encouraged over one giant squash.
- Don't merge with merge commits — prefer rebase or squash so the history reads linearly.

## Running the test suite locally

```sh
# One-time, on a fresh machine
sudo apt-get install -y libjson-perl libio-socket-ssl-perl libwww-perl cpanminus libdevel-cover-perl
cpanm Net::Proxmox::VE

# The tests themselves
prove -r t/

# With coverage
PERL5OPT="-MDevel::Cover=-silent,1,-coverage,statement,branch,subroutine" prove -r t/
cover -summary
cover -report html_basic    # writes cover_db/coverage.html
```

The test suite uses a `Net::Proxmox::VE` mock at `t/lib/`, so it doesn't need a real Proxmox cluster. Test data files live in `t/data/`.

## Adding a new check mode

The feature backlog in `CLAUDE.md` documents the recipe (CLI flag + `--check` alias + reporting block using `max_status()` and `evaluate_threshold()` + JSON payload key + tests). Follow it; that's how `--ceph` and `--subscriptions` landed.

## Style

- Keep changes compatible with Perl 5.14 (the matrix floor in `test.yml`). Avoid `say`, post-5.14 regex features, signatures.
- `use warnings` is on. If new code triggers `Use of uninitialized value...`, initialize the field at the source rather than silencing the warning.
- No new CPAN dependencies without good reason. The current dep tree is `Net::Proxmox::VE`, `IO::Socket::SSL`, `Getopt::Long`, `JSON` — keep it that small.
- Don't add `print "X"` for debug output. Use the `debug` helper, which routes to STDERR and is gated by `--debug`.
- Don't add new copies of the warn/crit threshold pattern. Use `evaluate_threshold($obj, $metric, $value)`.
- Don't sum status codes. Use `max_status(@codes)`.
- Don't write `# nagios: -epn` back into the shebang. The `Switch` source filter that required it is gone.

## Release process

See the **Releases** section of `README.md`. Short version:

1. Update the **Unreleased** section of `CHANGELOG.md`, rename it to the new version with the date.
2. Bump `$pluginVersion` in `pve-monitor.pl` to match.
3. `git commit`, `git tag -a vX.Y -m 'pve-monitor X.Y'`, `git push && git push --tags`.
4. The release workflow runs the smoke + suite, refuses the release if the tag and `$pluginVersion` disagree, then publishes the tarball.
