use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/lib";
use PveMonitorTest qw(run_script);

# --version: stdout has the version string, exit OK.
{
    my $r = run_script(args => ['--version']);
    is($r->{exit}, 0, '--version exit 0');
    like($r->{stdout}, qr/version \d+\.\d+/, '--version stdout has version');
}

# --help: usage text is printed; exits UNKNOWN(3) per Nagios convention.
{
    my $r = run_script(args => ['--help']);
    is($r->{exit}, 3, '--help exit 3 (UNKNOWN)');
    like($r->{stdout}, qr/--nodes/,    'usage mentions --nodes');
    like($r->{stdout}, qr/--storages/, 'usage mentions --storages');
    like($r->{stdout}, qr/--qemu/,     'usage mentions --qemu');
    like($r->{stdout}, qr/--ceph/,     'usage mentions --ceph');
    like($r->{stdout}, qr/--subscriptions/, 'usage mentions --subscriptions');
    like($r->{stdout}, qr/--json/,     'usage mentions --json');
    like($r->{stdout}, qr/--dry-run/,  'usage mentions --dry-run');
    like($r->{stdout}, qr/--check/,    'usage mentions --check');
    like($r->{stdout}, qr/--verify-ssl/, 'usage mentions --verify-ssl');
}

# Missing --conf: prints usage and exits UNKNOWN.
{
    my $r = run_script(args => ['--nodes']);
    is($r->{exit}, 3, 'missing --conf exit 3');
}

# Unknown CLI option: Getopt::Long prints a warning and the script
# treats it as missing-conf (still exits UNKNOWN).
{
    my $r = run_script(args => ['--nope']);
    isnt($r->{exit}, 0, 'unknown option non-zero exit');
}

done_testing;
