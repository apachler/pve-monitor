# Runtime CPAN dependencies for pve-monitor.
#
# Single source of truth: every CI workflow and the future container
# build install via `cpanm --installdeps --notest .` rather than
# listing modules inline. To add a new runtime dep, add it here and
# the entire CI matrix picks it up.
#
# Versions are pinned loosely. The matrix in .github/workflows/test.yml
# (Perl 5.14 / 5.20 / 5.38) and the weekly canary run together gate
# whether the latest CPAN release breaks us. Tightening pins here
# should be a deliberate response to a concrete breakage.

# Net::Proxmox::VE: the PVE API client. 0.10 is the first release on
# CPAN; 0.30+ adds the token auth ergonomics we rely on (`tokenid` /
# `secret` constructor args), so the floor is set there.
requires 'Net::Proxmox::VE', '>= 0.30';

# IO::Socket::SSL: HTTPS transport for the PVE API. Pulled transitively
# by LWP, but listed explicitly because --verify-ssl uses its
# SSL_VERIFY_PEER + verify_hostname constants directly.
requires 'IO::Socket::SSL';

# JSON: used by --json output mode and (indirectly) by the Net::Proxmox::VE
# response decoder. Backend selection (JSON::PP vs Cpanel::JSON::XS) is
# left to whichever the host has installed.
requires 'JSON';

# Getopt::Long is core since 5.000, no requires line needed.

# Dev-time only: coverage tooling. Installed by the coverage workflow
# and locally per CONTRIBUTING.md; not needed at plugin runtime.
on 'develop' => sub {
    requires 'Devel::Cover';
};

# Test deps are core (Test::More, FindBin, File::Spec) or already in
# the runtime requires (JSON for fixture decode in the mock). The
# Net::Proxmox::VE mock at t/lib/Net/Proxmox/VE.pm shadows the real
# module during tests via PERL5LIB.
