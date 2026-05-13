use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/lib";
use PveMonitorTest qw(run_script data_dir);
use File::Spec;

sub conf { File::Spec->catfile(data_dir(), $_[0]) }
sub mock { File::Spec->catfile(data_dir(), $_[0]) }

my $cfg     = conf('full.conf');
my $cfg_tok = conf('token-auth.conf');
my $m_ok    = mock('mock-cluster-ok.json');
my $m_stop  = mock('mock-cluster-stopped-vm.json');

# --nodes: healthy cluster -> NODES OK, exit 0.
{
    my $r = run_script(
        args           => ['--conf', $cfg, '--nodes', '--singlenode'],
        mock_responses => $m_ok,
    );
    is($r->{exit}, 0, '--nodes healthy: exit 0');
    like($r->{stdout}, qr/NODES OK/, 'NODES OK summary line');
    like($r->{stdout}, qr/node1 OK/, 'node1 detail present');
    like($r->{stdout}, qr/node2 OK/, 'node2 detail present');
}

# --storages: healthy backend -> STORAGE OK.
{
    my $r = run_script(
        args           => ['--conf', $cfg, '--storages', '--singlenode'],
        mock_responses => $m_ok,
    );
    is($r->{exit}, 0, '--storages healthy: exit 0');
    like($r->{stdout}, qr/STORAGE OK/, 'STORAGE OK summary line');
    like($r->{stdout}, qr/local-lvm/, 'storage name in detail');
}

# --containers: running LXC -> OPENVZ OK.
{
    my $r = run_script(
        args           => ['--conf', $cfg, '--containers', '--singlenode'],
        mock_responses => $m_ok,
    );
    is($r->{exit}, 0, '--containers running: exit 0');
    like($r->{stdout}, qr/OPENVZ OK/, 'OPENVZ OK summary');
    like($r->{stdout}, qr/ct100 \(node1\) OK/, 'ct100 detail present');
}

# --qemu: running -> QEMU OK.
{
    my $r = run_script(
        args           => ['--conf', $cfg, '--qemu', '--singlenode'],
        mock_responses => $m_ok,
    );
    is($r->{exit}, 0, '--qemu running: exit 0');
    like($r->{stdout}, qr/QEMU OK/, 'QEMU OK summary');
    like($r->{stdout}, qr/vm200 \(node1\) OK/, 'vm200 detail present');
}

# Stopped containers/qemu: report CRITICAL.
{
    my $r = run_script(
        args           => ['--conf', $cfg, '--containers', '--qemu', '--singlenode'],
        mock_responses => $m_stop,
    );
    is($r->{exit}, 2, 'stopped VMs: exit 2 (CRITICAL)');
    like($r->{stdout}, qr/VM is stopped/, 'stopped state in detail');
}

# --perfdata appends perfdata block.
{
    my $r = run_script(
        args           => ['--conf', $cfg, '--storages', '--singlenode', '--perfdata'],
        mock_responses => $m_ok,
    );
    is($r->{exit}, 0, '--storages --perfdata exit 0');
    like($r->{stdout}, qr/check_pve_storages/, 'perfdata block emitted');
}

# --html replaces newlines with <br>.
{
    my $r = run_script(
        args           => ['--conf', $cfg, '--nodes', '--singlenode', '--html'],
        mock_responses => $m_ok,
    );
    is($r->{exit}, 0, '--html exit 0');
    like($r->{stdout}, qr/<br>/, '--html emits <br>');
}

# Multiple modes combine; overall status is max severity.
{
    my $r = run_script(
        args           => ['--conf', $cfg, '--nodes', '--qemu', '--singlenode'],
        mock_responses => $m_stop,
    );
    is($r->{exit}, 2, 'mixed: CRITICAL wins via max_status');
    like($r->{stdout}, qr/NODES OK/, 'nodes still OK');
    like($r->{stdout}, qr/QEMU CRITICAL/, 'qemu CRITICAL');
}

done_testing;
