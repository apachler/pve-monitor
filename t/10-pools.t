use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/lib";
use PveMonitorTest qw(run_script data_dir);
use File::Spec;

sub conf { File::Spec->catfile(data_dir(), $_[0]) }
sub mock { File::Spec->catfile(data_dir(), $_[0]) }

my $cfg = conf('pool-only.conf');
my $m   = mock('mock-pool.json');

# --pools <name>: auto-expand pool members into the monitored arrays.
{
    my $r = run_script(
        args           => ['--conf', $cfg, '--pools', 'everything',
                           '--qemu', '--containers', '--storages', '--singlenode'],
        mock_responses => $m,
    );
    is($r->{exit}, 0, 'pool expansion + report: exit 0');
    like($r->{stdout}, qr/vm-from-pool/,
         'qemu pool member auto-discovered');
    like($r->{stdout}, qr/ct-from-pool/,
         'container pool member auto-discovered');
    like($r->{stdout}, qr/pool-storage/,
         'storage pool member auto-discovered');
}

# --pools All: same effect for any matching pool.
{
    my $r = run_script(
        args           => ['--conf', $cfg, '--pools', 'All',
                           '--qemu', '--singlenode'],
        mock_responses => $m,
    );
    is($r->{exit}, 0, '--pools All: exit 0');
    like($r->{stdout}, qr/vm-from-pool/, 'qemu picked up under --pools All');
}

done_testing;
