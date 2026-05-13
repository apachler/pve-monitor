# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

The next release will be the first cut on this branch since the upstream 1.1 tag. The changes below are accumulated on `master` and have not yet been released; bump `$pluginVersion` in `pve-monitor.pl` and push a matching `v*` tag to ship them.

### Added

- New `--ceph` mode: queries `/cluster/ceph/status` and maps `HEALTH_OK` / `HEALTH_WARN` / `HEALTH_ERR` onto OK / WARNING / CRITICAL, appending per-check detail (`OSD_NEARFULL`, `MON_DOWN`, etc.) to the report.
- New `--subscriptions` mode: per-node subscription validity + days-until-expiry. Thresholds configurable via `--sub-warn-days` (default 30) and `--sub-crit-days` (default 7).
- New `--check <list>` selector — comma-separated alias for the per-mode flags. Example: `--check nodes,storages,qemu,containers`.
- New `--json` output mode — emits a single JSON document instead of the Nagios-style summary; the connection-failure early-exit path also emits JSON when this is set.
- New `--dry-run` — parse the config and exit OK with a one-line summary. Useful for CI/syntax-check pipelines.
- New `--verify-ssl` — opt-in to `SSL_VERIFY_PEER + verify_hostname`. Default remains insecure for the typical self-signed Proxmox install.
- API-token authentication: new optional `monitor_token_id` and `monitor_token_secret` config fields. When both are present, the script authenticates via Net::Proxmox::VE's `tokenid` / `secret` rather than `monitor_password`.
- Test suite under `t/` (155 tests, 81%+ blended coverage) with a Net::Proxmox::VE mock and JSON-driven canned responses.
- Three GitHub Actions workflows (`test`, `coverage`, `release`) plus Dependabot for the actions themselves.

### Changed

- Status aggregation now uses `max_status()` rather than sum-and-clamp. Three WARNINGs no longer escalate to CRITICAL via the legacy `$score++ if eq UNKNOWN` bump; a single CRITICAL still dominates as before. The Nagios convention "max severity wins" is the standard.
- The `Switch` source filter is gone — the script uses native `if/elsif` dispatch. The `# nagios: -epn` directive (only needed because of `Switch`) was removed too: the plugin now runs cleanly under Nagios's embedded Perl interpreter.
- The `port` field in node config blocks is now actually passed to `Net::Proxmox::VE->new`; previously it was parsed but ignored.
- Debug output (`--debug`) goes to STDERR; previously it interleaved with the Nagios stdout summary that Icinga2 parses.
- The bespoke four-times-duplicated threshold check is now a single `evaluate_threshold($obj, $metric, $value)` helper.
- Node probe order is randomized — a dead head-of-config node no longer makes every check pay the full `--timeout` cost.
- `use warnings` is enabled.

### Fixed

- Node-CPU CRITICAL branch was writing to the threshold field (`crit_cpu`) instead of the status field (`cpu_status`), so a node exceeding the critical CPU threshold never raised its status.
- Pool blocks are always parsed; previously they were parsed only when `--pools` was passed, which left dangling block content for the outer parser to wade through silently.
- Qemu reporting now `defined`-checks the `alive` field before comparing to `"running"`, matching the openvz block's behavior.
- `cpu_alloc` is initialized to `0` (was `undef`), consistent with `mem_alloc`.
- `/cluster/resources` returning undef no longer crashes the script — the response is normalized to an empty list and reporting falls through to UNKNOWN gracefully.

### Removed

- Travis CI configuration (`travis-ci.org` shut down). Replaced by `.github/workflows/test.yml`.
- Unused `Data::Dump` dependency.

### Documentation

- `LICENSE` (renamed from `gpl-3.0.txt` for repo-host auto-detection).
- `README.md` rewritten to reflect the current feature set, CLI flags, config format, and Icinga2 integration layout.
- `CLAUDE.md` refreshed for the post-refactor architecture and the helpers added in this cycle (`max_status`, `evaluate_threshold`, `debug`).
- `SECURITY.md` documents the private vulnerability-report path.
- `CONTRIBUTING.md` covers branch/PR conventions and how to run the test suite.

## [1.1] - earlier

The previous release on the upstream tree. Reference point only; pre-fork history is preserved in `git log`.

[Unreleased]: https://github.com/apachler/pve-monitor/compare/v1.1...HEAD
[1.1]: https://github.com/apachler/pve-monitor/releases/tag/v1.1
