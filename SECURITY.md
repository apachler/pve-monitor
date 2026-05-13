# Security policy

## Reporting a vulnerability

If you find a security issue in `pve-monitor`, please report it privately rather than opening a public issue. Suitable channels, in order of preference:

1. **GitHub's "Report a vulnerability"** flow on the [Security tab](https://github.com/apachler/pve-monitor/security/advisories/new). This opens a private advisory only visible to the repository maintainers.
2. Email the maintainer directly. The current maintainer is reachable through their GitHub profile at <https://github.com/apachler>.

Please include:

- The plugin version (`perl pve-monitor.pl --version`) and the version of `Net::Proxmox::VE` you're running against (`perl -MNet::Proxmox::VE -e 'print "$Net::Proxmox::VE::VERSION\n"'`).
- A reproduction recipe: minimal `pve-monitor.conf`, the command line, what you observed.
- An assessment of severity (credential leak, auth bypass, remote command execution, denial of service, etc.) and the kind of access required to trigger it.

## Scope

In scope:

- Anything that lets an attacker read or write the PVE API credentials configured in the plugin config (`monitor_password`, `monitor_token_secret`).
- Anything that lets a malicious response from a PVE node cause the monitoring host to execute attacker-supplied commands or read attacker-supplied files.
- Anything that lets a malicious config file (e.g., one a less-privileged user can write to) cause unintended host behavior — file disclosure, log injection, command injection.
- Anything that lets the plugin be redirected to attack an unrelated host.

Out of scope:

- The plugin authenticating to a PVE node over plain HTTPS without `--verify-ssl` is the *documented default*; that's not a finding. Configuring `--verify-ssl` is the user's responsibility.
- Denial of service caused by passing the plugin a deliberately-malformed config — the plugin is a sysadmin tool, not a sandbox.
- Findings against `Net::Proxmox::VE`, `IO::Socket::SSL`, or the Proxmox API itself. Please report those to the relevant upstream project.

## Disclosure

The maintainers aim to acknowledge a report within 5 business days and to publish a fix or a mitigation within 30 days of confirmation, coordinated with the reporter. We don't operate a bug-bounty program.
