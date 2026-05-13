# pve-monitor

[![test](https://github.com/apachler/pve-monitor/actions/workflows/test.yml/badge.svg)](https://github.com/apachler/pve-monitor/actions/workflows/test.yml)
[![coverage](https://github.com/apachler/pve-monitor/actions/workflows/coverage.yml/badge.svg)](https://github.com/apachler/pve-monitor/actions/workflows/coverage.yml)
[![release](https://img.shields.io/github/v/release/apachler/pve-monitor?display_name=tag&sort=semver)](https://github.com/apachler/pve-monitor/releases/latest)
[![license](https://img.shields.io/badge/license-GPL--3.0-blue.svg)](LICENSE)
[![perl](https://img.shields.io/badge/perl-5.14%2B-blue.svg)](#requirements)

A single-file Perl Nagios/Icinga2 plugin that monitors Proxmox VE clusters via the PVE API. No agent is installed on the cluster — the plugin authenticates to one node and reads cluster state from there.

It can check, in any combination:

- **Nodes** — uptime, CPU / memory / disk usage, plus over-allocation of CPU and memory across the VMs running on each node
- **Storages** — disk usage per storage backend
- **Qemu virtual machines** — running state plus CPU / memory / disk usage
- **Containers** (LXC and the legacy OpenVZ flag) — same as Qemu
- **Pools** — auto-expands membership against the live cluster, so VMs/storages added to a pool are picked up without re-editing the plugin config
- **Quorum disk** (`--qdisk`)
- **Ceph health** (`--ceph`) — maps `HEALTH_OK` / `HEALTH_WARN` / `HEALTH_ERR` to OK / WARNING / CRITICAL, plus per-check detail
- **Subscriptions** (`--subscriptions`) — per-node subscription status and days-until-expiry, with configurable warn/crit day thresholds

## Requirements

- Perl 5.14 or newer
- CPAN modules:
  - `Net::Proxmox::VE`
  - `IO::Socket::SSL`
  - `Getopt::Long`
  - `JSON`

On a Debian/Ubuntu monitoring host:

```sh
apt-get install -y libjson-perl libwww-perl libio-socket-ssl-perl cpanminus
cpanm Net::Proxmox::VE
```

## Install

The plugin is a single Perl script:

```sh
cp pve-monitor.pl /usr/lib/nagios/plugins/pve-monitor.pl   # or your Icinga2 PluginDir
cp icinga2/pve-monitor.conf /etc/icinga2/pve-monitor.conf
chmod +x /usr/lib/nagios/plugins/pve-monitor.pl
```

Then edit `/etc/icinga2/pve-monitor.conf` to point at your cluster (see *Configuration* below). Example Icinga2 `CheckCommand` / host / service definitions live under `icinga2/conf.d/`.

## Usage

```sh
perl ./pve-monitor.pl --conf ./pve-monitor.conf --nodes --storages --containers --qemu
```

Pick checks individually with their flags (`--nodes`, `--storages`, `--qemu`, `--containers`, `--ceph`, `--subscriptions`, `--qdisk`, `--pools <All|name>`), or use the `--check` selector:

```sh
perl ./pve-monitor.pl --conf ./pve-monitor.conf --check nodes,storages,qemu,containers,ceph
```

Useful flags:

| Flag | Effect |
| --- | --- |
| `--conf <file>` | Path to the plugin config file (required for actual checks) |
| `--check <list>` | Comma-separated list of checks (alias for the per-mode flags) |
| `--singlenode` | Skip the cluster-quorum probe; treat the target as a standalone node |
| `--verify-ssl` | Validate the PVE node's TLS certificate (default: disabled for self-signed certs) |
| `--timeout N` | HTTP timeout per node, in seconds (default: 5) |
| `--pools <name>` | Auto-expand a pool's members (`--pools All` for every defined pool) |
| `--ignoretemp` | Skip VM templates when expanding pools |
| `--perfdata` | Emit Nagios perfdata after the summary (PNP4Nagios / check_multi style) |
| `--html` | Replace `\n` line breaks with `<br>` in the summary |
| `--json` | Emit a single JSON document on stdout instead of the Nagios summary |
| `--dry-run` | Parse the config and exit OK with a count of loaded blocks |
| `--debug` | Verbose trace on STDERR (never mixed into the Nagios stdout summary) |
| `--sub-warn-days N` / `--sub-crit-days N` | WARN/CRIT thresholds for `--subscriptions` (defaults: 30 / 7) |
| `--help` | Full flag list |

Exit codes follow the Nagios convention: `0` OK, `1` WARNING, `2` CRITICAL, `3` UNKNOWN. When multiple checks are requested in one invocation, the overall exit code is the most severe of any individual check.

## Configuration

The plugin config is a small block-based format. See `icinga2/pve-monitor.conf` for a working example.

```conf
# Cluster nodes. The plugin will probe these in randomized order and use
# the first quorate (or, with --singlenode, the first reachable) member
# to query the cluster.
node pve01 {
    address              10.0.0.1
    port                 8006             # optional, default 8006
    monitor_account      icinga
    monitor_token_id     icinga-monitor
    monitor_token_secret 12345678-90ab-cdef-1234-567890abcdef
    realm                pam              # optional, default 'pam'
    mem                  80 90            # WARN  CRIT  percent
    cpu                  80 95
    disk                 80 90
    mem_alloc            90 100           # over-allocation: sum(VM maxmem) / node maxmem
    cpu_alloc            90 100
}

# Storage backends. 'node' is required and must match a 'node' block above.
storage local {
    node pve01
    disk 80 90
}

# VMs and containers. Threshold lines: 'metric warn crit'.
container web01 { mem 80 90; cpu 80 95; disk 80 90 }
qemu      db01  { mem 80 90; cpu 80 95; disk 80 90 }

# Pools — auto-expand to include any matching members from the cluster.
# Activated only when --pools <name> (or --pools All) is passed.
pool web-tier { mem 90 95; cpu 90 95; disk 90 95 }
```

### Authentication

A node block must declare **either** `monitor_password` **or** the pair `monitor_token_id` + `monitor_token_secret`. Token authentication is the recommended path: it's a per-purpose credential that PVE can scope and revoke without touching a real user. Create one on the PVE side under *Datacenter → Permissions → API Tokens* and grant it `PVEAuditor` on the resources you want to monitor.

If both are present, the token is used.

### JSON output

`--json` swaps the Nagios summary for a single JSON document with the same data the human format prints. Useful for Icinga2 API consumers, Prometheus textfile collectors, or anything else that prefers structured data:

```json
{
  "exit_code": 0,
  "plugin": "pve-monitor",
  "status": "OK",
  "version": "1.1",
  "nodes": [
    {
      "name": "pve01",
      "status": 0,
      "cpu_status": 0,
      "curcpu": "12.40",
      "...": "..."
    }
  ]
}
```

The connection-failure early-exit path also returns JSON when `--json` is set, so consumers never see two formats.

## Icinga2 integration

`icinga2/` contains an example deployment layout:

- `icinga2/pve-monitor.conf` — install to `/etc/icinga2/pve-monitor.conf`; this is the plugin's own config (cluster nodes, thresholds).
- `icinga2/conf.d/commands.conf` — `CheckCommand` objects, one per check mode.
- `icinga2/conf.d/hosts.conf` / `services.conf` — sample host + service applying those commands.
- `icinga2/conf.d/templates.conf` — generic host / service templates the samples import.

The script itself is expected to live in Icinga2's `PluginDir`. Adjust paths to match your distro layout.

## CI and tests

The test suite lives under `t/` and runs with `prove`:

```sh
prove -r t/
```

11 test files (149 individual assertions) cover option parsing, the config-file parser, the `--check` selector, every reporting block (nodes / storages / qemu / containers / ceph / subscriptions / qdisk), pool expansion, `--json` output, threshold edge cases, dead-node sentinels, and `--ignoretemp`. PVE API calls are stubbed by a small `Net::Proxmox::VE` mock at `t/lib/` that returns canned JSON keyed by the API path the script asks for.

`make test` is the lightweight smoke check from the original Makefile (`perl ./pve-monitor.pl --version`).

To produce a coverage report locally:

```sh
cpanm Devel::Cover    # one-time
PERL5OPT="-MDevel::Cover=-silent,1,-coverage,statement,branch,subroutine" prove -r t/
cover -summary
cover -report html_basic   # writes cover_db/coverage.html
```

GitHub Actions runs three workflows:

- **`.github/workflows/test.yml`** — on every push / PR, runs `make test`, `--help`, `--dry-run` against the example Icinga2 config, and `prove -r t/` across a Perl 5.14 / 5.20 / 5.38 matrix.
- **`.github/workflows/coverage.yml`** — runs the same suite once under `Devel::Cover`, prints the per-file summary into the GitHub step summary, and uploads the HTML report as a 14-day artifact.
- **`.github/workflows/release.yml`** — see [Releases](#releases).

There is no fully end-to-end test — the script ultimately needs a real PVE cluster for live API behavior. `--dry-run` against your real config is the fastest way to confirm the plugin's config file is well-formed.

## Releases

Releases are cut by `.github/workflows/release.yml`, triggered when a `v<version>` tag is pushed. The workflow:

1. Verifies the tag matches `$pluginVersion` inside `pve-monitor.pl` (refuses to publish if they disagree — the most common foot-gun on projects where the version lives in source).
2. Re-runs the smoke tests from the test workflow.
3. Builds `pve-monitor-<version>.tar.gz` with just the drop-in install set: `pve-monitor.pl`, `Makefile`, `README.md`, `LICENSE`, and the `icinga2/` example layout.
4. Creates a GitHub Release with auto-generated changelog notes and attaches the tarball plus its `.sha256` sidecar.

To cut a release:

```sh
# bump $pluginVersion in pve-monitor.pl first
git tag -a v1.2 -m 'pve-monitor 1.2'
git push origin v1.2
```

The artifact for the most recent release is linked from the [release badge](https://github.com/apachler/pve-monitor/releases/latest) at the top of this README.

## License

GPL-3.0. See `LICENSE`.

## History / upstream

This is the [`apachler/pve-monitor`](https://github.com/apachler/pve-monitor) fork. Original project documentation (which predates several of the flags above and still references the OpenVZ-era container model) lives at `http://pve-monitor.scriptutils.com`, with French notes at `http://pve-monitor.scriptutils.com/francais/presentation/`.
