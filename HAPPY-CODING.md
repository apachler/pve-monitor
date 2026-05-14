# HAPPY-CODING.md

Engineering backlog for `pve-monitor`. Items in this file are deliberately
deferred — the rationale and effort estimate are recorded so a future
maintainer (human or otherwise) can pick them up with full context.

Each item is tagged:

- **Priority**: P0 (next), P1 (soon), P2 (eventually), P3 (nice-to-have)
- **Effort**: S (<1h), M (a few hours), L (a day), XL (multi-day)
- **Impact**: short statement of what improves once it's done

Sections are roughly priority-ordered.

---

## Code quality / runtime

### Replace deprecated `JSON` with `JSON::PP` or `Cpanel::JSON::XS`
- **Priority**: P2
- **Effort**: S
- **Impact**: `JSON.pm` is in maintenance mode and resolves at runtime to whichever backend is installed, which makes the canary workflow's "latest CPAN deps" run a moving target. Pinning to `JSON::PP` (core since 5.14) drops one CPAN dep entirely; pinning to `Cpanel::JSON::XS` is faster but adds an XS dep.
- **Notes**: Test fixtures under `t/data/*.json` are already pure JSON; switching the writer is a one-line change. The reader (mock at `t/lib/Net/Proxmox/VE.pm`) decodes test data, so swap both call sites at once.

### Stricter Perl::Critic policy
- **Priority**: P2
- **Effort**: M
- **Impact**: Today `lint.yml` enforces severity 5 and reports severity 4 advisory. Move severity 4 to enforced after the codebase is clean (current advisory output is the punch list).
- **Notes**: Many sev-4 findings are PBP rules the codebase predates (`RequireArgUnpacking`, `ProhibitNoStrict` in specific scopes, `RequireExplicitReturn`). Fix mechanically, one rule per commit, so each PR is reviewable.

### Add `perltidy` + `.perltidyrc`
- **Priority**: P3
- **Effort**: M (initial diff is large)
- **Impact**: Removes formatting bikeshed from code review. Pairs well with the pre-commit-hook idea below.
- **Notes**: Apply the reformat as a single commit so `git blame` keeps the rest of history clean. Add `--ignore-rev` style note in `CONTRIBUTING.md`.

### Pre-commit hook config (`.pre-commit-config.yaml`)
- **Priority**: P2
- **Effort**: S
- **Impact**: Local feedback loop for the same checks CI runs (perlcritic sev 5, actionlint, gitleaks, EOL via editorconfig-checker). Contributors who install pre-commit get instant feedback instead of waiting on a PR run.
- **Notes**: Keep it opt-in — don't fail CI if a contributor doesn't run pre-commit. CI remains the source of truth.

### Pin GitHub Actions to commit SHAs
- **Priority**: P2
- **Effort**: M
- **Impact**: Defends against a compromised action publisher rotating a tag under our nose (real attack class: see tj-actions/changed-files Mar 2025 incident).
- **Notes**: Workflows currently pin to major tags (`actions/checkout@v4`, `shogo82148/actions-setup-perl@v1`, `actions/upload-artifact@v4`, `gitleaks/gitleaks-action@v2`, `github/codeql-action/upload-sarif@v3`, `ossf/scorecard-action@v2.4.0`). Pin each to a 40-char SHA with a trailing `# v4.1.7` style comment so Dependabot can still update. Trade-off is reduced readability and more Dependabot churn.

---

## Containerization

### Dockerfile for sidecar deployment
- **Priority**: P2
- **Effort**: M
- **Impact**: Icinga2 increasingly runs in containers (`icinga/icinga2`). A pre-built `ghcr.io/apachler/pve-monitor` image lets an Icinga2 sidecar mount this plugin without bothering with `cpanm` inside the running container.
- **Notes**: Multi-stage build — stage 1 installs CPAN deps under `local::lib`; stage 2 is `perl:5.38-slim` + the script + the prebuilt `local::lib`. Add a `.github/workflows/container.yml` that builds on tag, publishes to GHCR, and runs Trivy + Grype against the image. Skip on every-PR builds (slow).
- **Open question**: do we ship `--ceph` / `--subscriptions` features that need additional deps in the container, or does the runtime cpanfile match the host? Document explicitly.

### `cpanfile` for ergonomic install
- **Priority**: P3
- **Effort**: S
- **Impact**: `cpanm --installdeps .` replaces the README incantation listing each module. Useful for the container build, less useful for the typical "drop pve-monitor.pl into PluginDir" install.
- **Notes**: Don't remove the README's `cpanm Net::Proxmox::VE` example — that path still works.

---

## Release automation

### Semantic versioning enforcement on tags
- **Priority**: P2
- **Effort**: S
- **Impact**: Release workflow today verifies tag == `$pluginVersion` but doesn't check that the tag looks like a real SemVer string. Add a regex guard so `v1.2a` or `v1.2-test` can't accidentally publish.
- **Notes**: `^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(\.(0|[1-9][0-9]*))?(-[0-9A-Za-z.-]+)?$`. `release-please` is overkill for a project with one human releasing once or twice a year.

### Sign release artifacts with Sigstore / cosign
- **Priority**: P3
- **Effort**: M
- **Impact**: Lets downstream package maintainers verify the tarball wasn't swapped on GitHub Releases. Public-key infra is "free" via keyless OIDC signing on the workflow.
- **Notes**: Adds `cosign sign-blob` to the release workflow, attaches `.sig` + `.crt` alongside the tarball. Pairs with the existing `.sha256` sidecar.

### SBOM generation on release
- **Priority**: P3
- **Effort**: M
- **Impact**: Small dep tree (4 modules) but supply-chain conformance audits increasingly expect a CycloneDX or SPDX SBOM attached to the release.
- **Notes**: `cpanfile` (above) + `cpanm --installdeps` + an SBOM tool that understands a `local::lib` tree (e.g. `cyclonedx-cli` after generating a manifest). Cheaper to defer until the cpanfile exists.

---

## Tests

### End-to-end test against a real (or stubbed) PVE API
- **Priority**: P2
- **Effort**: L
- **Impact**: The mock under `t/lib/Net/Proxmox::VE.pm` replays canned JSON; it does *not* exercise the real HTTP-error edge cases (5xx during pool expansion, redirect chains, TLS handshake failure with `--verify-ssl`). One synthetic HTTP server with `Test::TCP` + `HTTP::Server::PSGI` covers most of that without needing a real cluster.
- **Notes**: Run only on `ubuntu-latest` and only when env var `PVE_E2E=1` is set, so contributors without Net::Async don't pay the cost.

### Mutation testing
- **Priority**: P3
- **Effort**: L
- **Impact**: 81% statement coverage is fine on paper but says nothing about whether the tests would catch a real bug. `App::Stamp` / `Devel::Cover` doesn't do mutation; you'd add a tool like `Mutator::Perl` or hand-roll a tiny harness.
- **Notes**: Probably not worth the maintenance burden for a 1-file plugin. Listed for completeness.

### Property-based parser tests
- **Priority**: P3
- **Effort**: M
- **Impact**: The config-file parser is the most fragile piece of the script. A QuickCheck-style generator (`Test::LectroTest`) could fuzz block contents and confirm the parser never crashes on garbage input — only refuses cleanly.
- **Notes**: Today `t/02-parser.t` and `t/11-edge-cases.t` cover the known-bad inputs. Property-based testing extends that to inputs nobody thought of.

---

## Documentation

### `ROADMAP.md` extracted from `CLAUDE.md`'s "Feature Backlog"
- **Priority**: P2
- **Effort**: S
- **Impact**: The four deferred check modes (`--backups`, `--snapshots`, `--replication`, tag-based discovery) currently only live in `CLAUDE.md`, which non-AI contributors are less likely to read. A top-level `ROADMAP.md` makes intent visible.
- **Notes**: Keep `CLAUDE.md`'s copy as a stub that points at `ROADMAP.md` so the AI-context file doesn't go stale.

### `docs/` directory with deeper guides
- **Priority**: P3
- **Effort**: M
- **Impact**: README is at ~220 lines and growing. A `docs/icinga2.md`, `docs/auth.md`, `docs/troubleshooting.md` split keeps the front page short while letting individual topics be linkable.
- **Notes**: Resist GitHub Pages unless someone volunteers to maintain it. Plain markdown in `docs/` renders fine.

### Architecture diagram in README
- **Priority**: P3
- **Effort**: S
- **Impact**: A simple Mermaid `flowchart` of "monitoring host → PVE API → reporting" makes the no-agent-on-cluster story land for first-time readers.
- **Notes**: GitHub renders Mermaid inline — no PNG asset to maintain.

### `--man` flag that runs `pod2usage`
- **Priority**: P3
- **Effort**: S
- **Impact**: Today `perldoc pve-monitor.pl` works but isn't obvious to discover. A `--man` flag that calls `pod2usage(-verbose=>2)` puts that path in `--help`.
- **Notes**: Adds a `Pod::Usage` dep (core since 5.6, free).

---

## Security

### Drop `IO::Socket::SSL` default insecure mode footgun
- **Priority**: P2
- **Effort**: M
- **Impact**: `--verify-ssl` is opt-in today because PVE installs typically use self-signed certs. Flip the default to *on* in a future major release, document the migration in CHANGELOG, and let users opt out with `--no-verify-ssl`. Industry direction is opt-out-of-secure not opt-in-to-secure.
- **Notes**: This is a breaking change — bump to `2.0`. Plan a deprecation window where both forms work and the old default prints a deprecation warning on stderr.

### Bound the `--timeout` flag
- **Priority**: P3
- **Effort**: S
- **Impact**: `--timeout` accepts any positive integer today. A typo (`--timeout 50000`) silently turns a fast monitoring check into a 14-hour hang. Clamp to a sane upper bound (300s?) and error out loudly above it.
- **Notes**: Aligns with Nagios's own per-check timeout — Icinga2's default check_timeout is 60s, so anything above that is already suspect.

### Branch protection rules on `master`
- **Priority**: P1
- **Effort**: S (UI click, not code)
- **Impact**: OpenSSF Scorecard checks for this and it's the single largest score boost available. Require status checks (test, lint, coverage, gitleaks, actionlint), require linear history, require signed commits, disallow force push.
- **Notes**: Configure via repo Settings → Branches. Not a code change, but list here so it doesn't get forgotten.

---

## Observability / metrics from the plugin itself

### Native Prometheus textfile-collector output mode
- **Priority**: P2
- **Effort**: M
- **Impact**: `--json` already covers structured output for Icinga2 consumers. A `--prometheus` mode (or post-processor) would let the same script feed `node_exporter --collector.textfile` for users on a Prometheus stack instead of Icinga2.
- **Notes**: Mapping is mechanical: each `nodes[i].cpu_status` → a labeled gauge `pve_node_cpu_status{node="..."}`. Exit code stays Nagios-shaped so existing users aren't broken.

### Optional run-time metrics (own probe duration, error counts)
- **Priority**: P3
- **Effort**: S
- **Impact**: Today the plugin reports cluster health but nothing about *itself* — slow probes, retries, error counts per node. Add an internal `%metrics` hash and surface in `--json` as a `meta` block. Useful for diagnosing "why has the check been timing out every Tuesday at 03:00".
- **Notes**: Keep it strictly internal — don't add an HTTP listener or anything stateful. Append to the JSON output and stop.

---

## Community / maintainability

### Renovate as an alternative to Dependabot
- **Priority**: P3
- **Effort**: S
- **Impact**: Renovate is better at grouping related updates and at filtering noisy ones. Dependabot is fine for a single ecosystem (github-actions); the upside is small here. Listed for completeness.
- **Notes**: Don't run both — pick one.

### GitHub Discussions enabled, replace SUPPORT.md note
- **Priority**: P3
- **Effort**: S (UI click)
- **Impact**: Lets users ask "is this how I'm supposed to use --pools?" without polluting the issue tracker. Volunteer-time-sensitive — only enable if there's appetite to answer.
- **Notes**: If enabled, add `contact_links` entry in `.github/ISSUE_TEMPLATE/config.yml` and a "Questions / discussion" row to `SUPPORT.md`.

### GOVERNANCE.md
- **Priority**: P3
- **Effort**: S
- **Impact**: Not needed for a one-maintainer project. List for the day a second maintainer joins — then this becomes P1.

### `FUNDING.yml`
- **Priority**: P3
- **Effort**: S
- **Impact**: Adds the "Sponsor" button to the repo. Skipped today because the maintainer hasn't expressed a sponsor preference; trivial to add later (`github: [apachler]` or similar).

---

## Performance

### Cache `/cluster/resources` across check modes in one invocation
- **Priority**: P2
- **Effort**: M
- **Impact**: When `--check nodes,storages,qemu,containers,ceph,subscriptions` is passed, the script hits `/cluster/resources` repeatedly. Each call is cheap individually but they add up for clusters with hundreds of VMs. One fetch + reuse across reporting blocks.
- **Notes**: The architecture in `CLAUDE.md` already documents that resource collection walks `/cluster/resources` once — verify the per-block fetches mentioned in `--ceph` / `--subscriptions` actually duplicate it, and if so, factor out.

### Parallel node-probe in the connection loop
- **Priority**: P3
- **Effort**: M
- **Impact**: Connection loop tries nodes serially in randomized order. Probing all reachable members in parallel and racing to the first quorate response halves connect latency for the common case where the head-of-config node is alive. Trade-off is a small burst of API auth calls per check.
- **Notes**: Single-script Perl with no preferred async framework; `IO::Async` or `Parallel::ForkManager` would add deps. Probably not worth it unless someone reports the serial fallback as painful in practice.

---

## How to use this file

1. When picking work, prefer P0/P1 items first.
2. When closing an item, move its summary into `CHANGELOG.md` under `### Added` / `### Changed` / `### Fixed` and delete its section here. The file shrinks over time.
3. New items go in priority-sorted order, not at the bottom — chronological ordering would defeat the purpose.
4. If a P3 item ages for more than a year without anyone wanting it, it gets deleted, not promoted. This list is a backlog, not a graveyard.
