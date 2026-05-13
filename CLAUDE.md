# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

`pve-monitor.pl` is a single-file Perl script that acts as a Nagios/Icinga2 plugin for monitoring Proxmox VE clusters via the PVE API. There are no installable modules or build artifacts — the script is run directly by the monitoring system.

## Common Commands

- Syntax / smoke test (what `Makefile` and Travis run): `make test` — equivalent to `perl ./pve-monitor.pl --version`
- Run a check: `perl ./pve-monitor.pl --conf ./pve-monitor.conf [--nodes|--storages|--qemu|--containers|--ceph|--subscriptions|--pools <name|All>|--qdisk] [--singlenode] [--verify-ssl] [--perfdata] [--html] [--debug] [--timeout N]`
- Or pick multiple checks at once: `--check nodes,storages,qemu,containers,ceph`
- Validate config only: `--dry-run` (parses the file, prints one-line summary, exits OK)
- Structured output: `--json` (emits a single JSON document instead of the Nagios-style summary)
- Show usage: `perl ./pve-monitor.pl --help`

There is no test suite, linter config, or package manager in this repo. CI (`.travis.yml`) only validates that the script parses and runs `--version` under Perl 5.14–5.20 after installing CPAN deps.

## Runtime Dependencies

Perl 5.14+ and the following CPAN modules:

- `Net::Proxmox::VE` — PVE API client (the header comments still reference the old `git://github.com/dpiquet/proxmox-ve-api-perl.git` fork; the current Net::Proxmox::VE on CPAN works and supports API-token auth via `tokenid` / `secret` constructor args)
- `IO::Socket::SSL`
- `Getopt::Long`
- `JSON` (used directly by the `--json` output mode, in addition to being pulled transitively by Net::Proxmox::VE)
- `LWP` (pulled by `Net::Proxmox::VE`)

`Switch` is no longer needed — the script uses native `if/elsif` dispatch. The `# nagios: -epn` directive has been removed too: the only reason for it was that `Switch` (a source filter) misbehaved under Nagios's embedded Perl interpreter, and that constraint is now gone.

## Architecture

The script runs as a single linear pipeline with a handful of helpers (`usage`, `is_number`, `debug`, `max_status`, `evaluate_threshold`).

1. **Argument parsing** (`GetOptions`) populates `%arguments`. At least one of `--nodes`, `--storages`, `--qemu`, `--containers`, `--ceph`, `--subscriptions`, `--qdisk`, or `--dry-run` must be requested (or via `--check <list>`) or the script exits `UNKNOWN`.
2. **Config parser** reads `--conf` line-by-line, recognizing top-level blocks `node`, `storage`, `openvz|lxc|container`, `qemu`, `pool`. The outer regex captures the block type and name; subsequent `elsif` branches dispatch on those captures. Important: the outer match's `$1`/`$2` are bound to lexicals (`$blockType`, `$blockName`) before any inner regex runs, because a later non-capturing match would otherwise reset them.
3. **Cluster connection** iterates `@monitoredNodes` in randomized order (so a dead head-of-config node doesn't pay the full `--timeout` cost every check). Tries each as a PVE API endpoint, calling `/cluster/status` to find a quorate, non-estranged member. `--singlenode` skips the quorum check. SSL verification is off by default (most PVE installs use self-signed certs); pass `--verify-ssl` to enable `SSL_VERIFY_PEER + verify_hostname`.
4. **Auth**: node blocks may declare either `monitor_password` *or* `monitor_token_id` + `monitor_token_secret`. Token auth is preferred and wires straight into Net::Proxmox::VE's `tokenid` / `secret` constructor args.
5. **Pool expansion** — only if `--pools` was passed. For each matching pool in `/cluster/resources`, the script fetches `/pools/<name>` and appends any pool member (qemu / container / storage) not already declared in config into the corresponding `@monitored*` array, using the pool's thresholds as defaults. `--ignoretemp` skips members with `template == 1`. Pool *blocks* in the config are always parsed, regardless of whether `--pools` was passed; only the expansion step is gated.
6. **Resource collection** walks `/cluster/resources` once. For each item it matches the relevant `@monitored*` array by name and copies live values (`mem`, `cpu`, `disk`, `maxmem`, etc.) into the entry, converting absolute values to percentages. For containers/qemu it also accumulates `mem_alloc`/`cpu_alloc` totals onto the owning node, used later for over-allocation alarms. Items "on a dead node" (missing `status` field) get sentinel values.
7. **Reporting** — one block per requested subsystem (`--nodes`, `--storages`, `--openvz`/`--containers`, `--qemu`, `--ceph`, `--subscriptions`). Each computes a per-subsystem `$statusScore` using `max_status($a, $b, ...)` (which returns the most severe of the supplied codes), prints a summary line plus per-object detail (suppressed under `--json`), and updates `$totalScore`. `$totalScore` is the process exit code.

### Helpers worth knowing

- `debug $msg` — `$msg` goes to STDERR if `--debug` is set, so it never contaminates the Nagios stdout summary that Icinga2 parses.
- `max_status(@codes)` — Nagios status arithmetic. Use this for any new aggregation; *don't* sum codes.
- `evaluate_threshold($obj, $metric, $value)` — reads `$obj->{warn_$metric}` and `$obj->{crit_$metric}`, writes the result into `$obj->{${metric}_status}`. The repeated warn/crit pattern across reporting blocks goes through this single helper.

### Status / exit codes

The `%status` hash defines the Nagios convention: `OK=0, WARNING=1, CRITICAL=2, UNKNOWN=3` (plus an internal `UNDEF=-1`). `%rstatus` is the reverse for printing names. `--qdisk` is mutually exclusive: it exits early and does not combine with other checks.

### Config-file shape

See `icinga2/pve-monitor.conf` for a working example. Threshold lines inside each block are `metric warn crit` (e.g. `mem 80 90`). Node blocks additionally require `address`, `monitor_account`, optional `port` (default 8006), `realm` (default `pam`), and *either* `monitor_password` *or* (`monitor_token_id` + `monitor_token_secret`). Storage blocks require a `node` reference. The node-block parser uses a regex with an optional third field — `(\S+)\s+(\S+)(\s+(\S+))?` — because tokens like `address 10.0.0.1` only have two fields; the qemu/openvz/pool parsers require three (`metric warn crit`).

## Icinga2 Integration

`icinga2/` contains an example deployment layout: `pve-monitor.conf` is the plugin's own config (installed to `/etc/icinga2/pve-monitor.conf` per the CheckCommands), and `conf.d/` defines `CheckCommand` objects (one per check mode), a sample host, and services. The script itself is expected to live in Icinga2's `PluginDir`.

## Conventions When Editing

- Keep changes compatible with Perl 5.14 (oldest CI target). Avoid `say`, post-5.14 regex features, and signatures.
- `use warnings` is enabled. If a new code path emits an "uninitialized in ..." warning under `-w`, the right fix is almost always to initialize the field in the originating hashref (e.g. node init at config-parse time), not to silence the warning.
- The reporting blocks share `evaluate_threshold()` and `max_status()`. If you add a new metric, add it to the node/VM hashref init *and* call `evaluate_threshold` in the reporting block — don't re-inline the `if defined warn_X / if defined crit_X` pattern.
- The config parser is `if/elsif` dispatch on block type, then a second `if/elsif` on token name inside each block. To add a new keyword, add it to the relevant inner chain and (if it's a new field) initialize the corresponding lexical at the top of that block.
- Branch convention: development happens on feature branches (e.g. the current `claude/add-claude-documentation-*`); the main branch is `master`.

## Feature Backlog (not yet implemented)

These were proposed and deliberately deferred — they need a real PVE cluster to validate the API response shapes against:

- **Backup-job freshness** (`--backups`): scan `/cluster/tasks` filtered by `type=vzdump`, alert when the most recent successful task per VM is older than a configurable threshold.
- **Snapshot age** (`--snapshots`): per VM, list `/nodes/<n>/qemu/<vmid>/snapshot` (and the openvz/lxc equivalent), alert on forgotten snapshots older than N days.
- **Replication status** (`--replication`): pull `/cluster/replication` + `/nodes/<n>/replication`, alert when `last_sync` is stale or `fail_count > 0`.
- **Tag-based discovery**: PVE 7+ supports VM tags. Add a `tag <name> { mem 80 90; cpu 80 95; ... }` block type that auto-expands at resource-collection time the way pool blocks do today.

For each, the work shape is the same: add the CLI flag and usage entry, add to `--check`'s alias map, write a reporting block that uses `max_status()` for aggregation and (where relevant) `evaluate_threshold()` for warn/crit, and wire the result into the `--json` payload.
