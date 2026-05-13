# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

`pve-monitor.pl` is a single-file Perl script that acts as a Nagios/Icinga2 plugin for monitoring Proxmox VE clusters via the PVE API. There are no installable modules or build artifacts — the script is run directly by the monitoring system.

## Common Commands

- Syntax / smoke test (what `Makefile` and Travis run): `make test` — equivalent to `perl ./pve-monitor.pl --version`
- Run against a config: `perl ./pve-monitor.pl --conf ./pve-monitor.conf [--nodes|--storages|--qemu|--containers|--pools <name|All>|--qdisk] [--singlenode] [--perfdata] [--html] [--debug] [--timeout N]`
- Show usage: `perl ./pve-monitor.pl --help`

There is no test suite, linter config, or package manager in this repo. CI (`.travis.yml`) only validates that the script parses and runs `--version` under Perl 5.14–5.20 after installing CPAN deps.

## Runtime Dependencies

Perl 5.14+ and the following CPAN modules (installed by `.travis.yml` as the canonical list):

- `Net::Proxmox::VE` — PVE API client (note the script's header comments still reference the old `git://github.com/dpiquet/proxmox-ve-api-perl.git` fork)
- `IO::Socket::SSL`
- `Getopt::Long`
- `Switch` — used heavily for config-token and resource-type dispatch; `Switch` is a source filter and is deprecated/removed in recent Perl, so be cautious about migrating to native `given/when` or `if/elsif` chains
- `JSON`, `LWP` (pulled by `Net::Proxmox::VE`)
- `Data::Dump` (debug only)

The shebang carries `# nagios: -epn`, which disables the Nagios embedded Perl interpreter — required because `Switch`/`Net::Proxmox::VE` don't play nicely with ePN. Do not remove it.

## Architecture

The script runs as a single linear pipeline; there are no packages or subs beyond `usage` and `is_number`.

1. **Argument parsing** (`GetOptions`) populates `%arguments`. One of `--nodes / --storages / --qemu / --containers (alias of --openvz) / --qdisk` must be requested or the script exits `UNKNOWN`.
2. **Custom config parser** (`pve-monitor.pl:174–727`) reads the file referenced by `--conf` line-by-line, recognizing top-level blocks `node`, `storage`, `openvz|lxc|container`, `qemu`, `pool`. Each block is parsed by a nested `while (<FILE>)` loop that consumes lines until a `}` is hit. The parser is stateful (`$readingObject`) and intolerant of formatting; any unrecognized token aborts with `UNKNOWN`. Parsed objects are pushed into `@monitoredNodes`, `@monitoredStorages`, `@monitoredOpenvz`, `@monitoredQemus`, `@monitoredPools`.
3. **Cluster connection** (`pve-monitor.pl:736–822`) iterates `@monitoredNodes` and tries each as a PVE API endpoint. SSL verification is intentionally disabled (`SSL_VERIFY_NONE`). It calls `/cluster/status` to find a quorate, non-estranged node to use as the query endpoint; the first such node wins and the loop breaks. `--singlenode` skips the quorum check entirely. Also during this pass it detects a `qdisk` entry.
4. **Pool expansion** (`pve-monitor.pl:856–950`) — only if `--pools` was passed. For each matching pool in `/cluster/resources`, the script fetches `/pools/<name>` and appends any pool member (qemu / container / storage) not already declared in config into the corresponding `@monitored*` array, using the pool's thresholds as defaults. `--ignoretemp` skips members with `template == 1`.
5. **Resource collection** (`pve-monitor.pl:952–1132`) walks `/cluster/resources` once. For each item it matches the relevant `@monitored*` array by name and copies live values (`mem`, `cpu`, `disk`, `maxmem`, etc.) into the entry, converting absolute values to percentages. For containers/qemu it also accumulates `mem_alloc`/`cpu_alloc` totals onto the owning node, used later for over-allocation alarms. Items "on a dead node" (missing `status` field) get sentinel values.
6. **Reporting** (`pve-monitor.pl:1134–1495`) is four near-duplicated blocks (`--nodes`, `--storages`, `--openvz`, `--qemu`), each computing a per-subsystem `$statusScore`, capping it at `CRITICAL` if it would exceed `UNKNOWN`, and printing a summary line plus per-object detail. Scores are summed into `$totalScore`, which becomes the process exit code.

### Status / exit codes

The `%status` hash defines the Nagios convention: `OK=0, WARNING=1, CRITICAL=2, UNKNOWN=3` (plus an internal `UNDEF=-1`). `%rstatus` is the reverse for printing names. Status arithmetic deliberately *sums* sub-statuses then clamps — be careful: changing what gets added (e.g. adding a new sub-status field) can flip a check from WARNING to UNKNOWN to CRITICAL because of the clamping rule `$statusScore = CRITICAL if $statusScore > UNKNOWN`. Note also that `--qdisk` is mutually exclusive: it exits early and does not combine with other checks.

### Config-file shape

See `icinga2/pve-monitor.conf` for a working example. Threshold lines inside each block are `metric warn crit` (e.g. `mem 80 90`). Node blocks additionally require `address`, `monitor_account`, `monitor_password`, optional `port` (default 8006) and `realm` (default `pam`). Storage blocks require a `node` reference. Note that the **node-block parser uses a different regex** (`(\S+)\s+(\S+)(\s+(\S+))?`) than the qemu/openvz/pool parsers (`(\S+)\s+(\S+)\s+(\S+)`) — the node parser tolerates single-value tokens like `address 10.0.0.1`, the others require three whitespace-separated fields.

## Icinga2 Integration

`icinga2/` contains an example deployment layout: `pve-monitor.conf` is the plugin's own config (installed to `/etc/icinga2/pve-monitor.conf` per the CheckCommands), and `conf.d/` defines `CheckCommand` objects (one per check mode), a sample host, and services. The script itself is expected to live in Icinga2's `PluginDir`.

## Conventions When Editing

- Keep changes compatible with Perl 5.14 (oldest CI target). Avoid `say`, post-5.14 regex features, and signatures.
- Don't rely on `use warnings` — the pragma is intentionally commented out at the top, and the existing code triggers many warnings (uninitialized comparisons against `eq`, string/numeric mixing for status codes, etc.). Adding `use warnings` is a deliberate, repo-wide decision, not a bug fix.
- The four reporting blocks (nodes/storages/openvz/qemu) are intentionally duplicated. If you change threshold logic in one, audit the other three.
- The config parser swallows whitespace-tolerant input but is regex-fragile. New block types or keywords must be added to *both* the outer block-type `switch` and the inner per-block `switch` that lists valid keys.
- Branch convention: development happens on feature branches (see e.g. the current `claude/add-claude-documentation-*` branch); the main branch is `master`.
