use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/lib";
use PveMonitorTest qw(run_script data_dir);
use File::Spec;

my $conf = File::Spec->catfile(data_dir(), 'full.conf');

# --check with a list of valid names runs the corresponding modes.
# We use --conf with no mock so the script fails at the connection
# probe; the test asserts on early-stage behavior, not API output.
{
    my $r = run_script(
        args => ['--conf', $conf, '--check', 'nodes,storages', '--timeout', '1'],
    );
    isnt($r->{exit}, 0, '--check nodes,storages doesn\'t exit OK without a reachable cluster');
    like($r->{stdout}, qr/Could not connect/, 'reached the connection probe');
}

# --check with a bogus name exits UNKNOWN before contacting any host.
{
    my $r = run_script(args => ['--conf', $conf, '--check', 'bogus']);
    is($r->{exit}, 3, 'bogus --check value exits UNKNOWN');
    like($r->{stdout}, qr/Unknown --check value/, 'reports the unknown value');
}

# Mixed mode: --check containers maps to --openvz internally.
{
    my $r = run_script(
        args => ['--conf', $conf, '--check', 'containers', '--timeout', '1'],
    );
    isnt($r->{exit}, 0, '--check containers fails at connection (as expected without mock)');
    like($r->{stdout}, qr/Could not connect/, 'parsed --check containers');
}

# --check accepts a comma-separated list with whitespace.
{
    my $r = run_script(
        args => ['--conf', $conf, '--check', 'nodes, storages , qemu', '--timeout', '1'],
    );
    isnt($r->{exit}, 0, 'whitespace in --check list still parses');
    like($r->{stdout}, qr/Could not connect/, 'reached the connection probe');
}

done_testing;
