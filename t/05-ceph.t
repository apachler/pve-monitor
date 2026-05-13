use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/lib";
use PveMonitorTest qw(run_script data_dir);
use File::Spec;

sub conf { File::Spec->catfile(data_dir(), $_[0]) }
sub mock { File::Spec->catfile(data_dir(), $_[0]) }

my $cfg = conf('full.conf');

# HEALTH_OK -> exit 0, "Ceph HEALTH_OK".
{
    my $r = run_script(
        args           => ['--conf', $cfg, '--ceph', '--singlenode'],
        mock_responses => mock('mock-ceph-ok.json'),
    );
    is($r->{exit}, 0, 'HEALTH_OK -> exit 0');
    like($r->{stdout}, qr/CEPH OK : Ceph HEALTH_OK/, 'OK summary');
}

# HEALTH_WARN -> exit 1; per-check detail included.
{
    my $r = run_script(
        args           => ['--conf', $cfg, '--ceph', '--singlenode'],
        mock_responses => mock('mock-ceph-warn.json'),
    );
    is($r->{exit}, 1, 'HEALTH_WARN -> exit 1');
    like($r->{stdout}, qr/CEPH WARNING/, 'WARNING summary');
    like($r->{stdout}, qr/OSD_NEARFULL/, 'check detail included');
    like($r->{stdout}, qr/1 nearfull osd/, 'check summary text included');
}

# HEALTH_ERR -> exit 2.
{
    my $r = run_script(
        args           => ['--conf', $cfg, '--ceph', '--singlenode'],
        mock_responses => mock('mock-ceph-err.json'),
    );
    is($r->{exit}, 2, 'HEALTH_ERR -> exit 2');
    like($r->{stdout}, qr/CEPH CRITICAL/, 'CRITICAL summary');
    like($r->{stdout}, qr/MON_DOWN/, 'check detail included');
}

# No ceph data at all -> UNKNOWN.
{
    my $r = run_script(
        args           => ['--conf', $cfg, '--ceph', '--singlenode'],
        mock_responses => mock('mock-cluster-ok.json'),  # no /cluster/ceph/status key
    );
    is($r->{exit}, 3, 'absent ceph data -> exit 3 (UNKNOWN)');
    like($r->{stdout}, qr/CEPH UNKNOWN/, 'UNKNOWN summary');
    like($r->{stdout}, qr/Ceph status unavailable/, 'reports unavailable');
}

done_testing;
