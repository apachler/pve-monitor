use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/lib";
use PveMonitorTest qw(run_script data_dir);
use File::Spec;
use JSON ();

sub conf { File::Spec->catfile(data_dir(), $_[0]) }
sub mock { File::Spec->catfile(data_dir(), $_[0]) }

my $cfg = conf('full.conf');

# --json on healthy cluster: stdout is a single JSON document, no
# Nagios-format STATUS line.
{
    my $r = run_script(
        args           => ['--conf', $cfg, '--nodes', '--storages',
                           '--qemu', '--containers', '--singlenode', '--json'],
        mock_responses => mock('mock-cluster-ok.json'),
    );
    is($r->{exit}, 0, '--json healthy: exit 0');
    unlike($r->{stdout}, qr/^NODES /m, 'no Nagios STATUS line on stdout');

    my $payload;
    eval { $payload = JSON::decode_json($r->{stdout}); 1 }
        or fail("stdout is valid JSON: $@");

    is($payload->{status},    'OK', 'top-level status OK');
    is($payload->{exit_code}, 0,    'top-level exit_code 0');
    is($payload->{plugin},    'pve-monitor', 'plugin identifier');
    ok(exists $payload->{nodes},      'nodes array present');
    ok(exists $payload->{storages},   'storages array present');
    ok(exists $payload->{qemu},       'qemu array present');
    ok(exists $payload->{containers}, 'containers array present');

    is(scalar(@{$payload->{nodes}}), 2, '2 node entries');
    is($payload->{nodes}->[0]->{name}, 'node1', 'first node name preserved');
    is($payload->{nodes}->[0]->{cpu_status}, 0, 'node1 cpu_status numeric OK');
}

# --json on connection failure: still emits JSON with the error key.
{
    my $r = run_script(
        args => ['--conf', $cfg, '--nodes', '--timeout', '1', '--json'],
    );
    is($r->{exit}, 3, 'connection failure exits UNKNOWN');
    my $p = JSON::decode_json($r->{stdout});
    is($p->{status}, 'UNKNOWN', 'JSON status UNKNOWN');
    like($p->{error}, qr/Could not connect/, 'error key set');
}

# --json with --ceph includes the ceph object.
{
    my $r = run_script(
        args           => ['--conf', $cfg, '--ceph', '--singlenode', '--json'],
        mock_responses => mock('mock-ceph-warn.json'),
    );
    is($r->{exit}, 1, '--ceph WARN exit 1 under --json');
    my $p = JSON::decode_json($r->{stdout});
    is($p->{status}, 'WARNING', 'JSON top-level WARNING');
    is($p->{ceph}->{status}, 'WARNING', 'ceph block WARNING');
    like($p->{ceph}->{detail}, qr/OSD_NEARFULL/, 'ceph detail includes check id');
}

done_testing;
