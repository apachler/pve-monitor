use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/lib";
use PveMonitorTest qw(run_script data_dir);
use File::Spec;

sub conf { File::Spec->catfile(data_dir(), $_[0]) }
sub mock { File::Spec->catfile(data_dir(), $_[0]) }

my $m = mock('mock-single-node.json');   # node at 50% mem, 5% cpu, 50% disk

# Thresholds set so observed usage exceeds crit_*: node reports CRITICAL.
{
    my $r = run_script(
        args           => ['--conf', conf('over-threshold.conf'),
                           '--nodes', '--singlenode'],
        mock_responses => $m,
    );
    is($r->{exit}, 2, 'observed > crit_X -> CRITICAL');
    like($r->{stdout}, qr/NODES CRITICAL/, 'NODES CRITICAL summary');
    like($r->{stdout}, qr/mem CRITICAL/, 'mem CRITICAL flagged');
}

# Thresholds set so observed usage is between warn and crit on mem/disk
# and above warn but below crit on cpu (5% > 1% warn, < 99% crit).
# Aggregate is WARNING (max_status of WARN, WARN, WARN).
{
    my $r = run_script(
        args           => ['--conf', conf('warn-threshold.conf'),
                           '--nodes', '--singlenode'],
        mock_responses => $m,
    );
    is($r->{exit}, 1, 'observed > warn_X (not crit) -> WARNING');
    like($r->{stdout}, qr/NODES WARNING/, 'NODES WARNING summary (max_status of WARN+WARN+WARN)');
}

# --json output reflects the WARNING numerically.
{
    my $r = run_script(
        args           => ['--conf', conf('warn-threshold.conf'),
                           '--nodes', '--singlenode', '--json'],
        mock_responses => $m,
    );
    is($r->{exit}, 1, '--json WARN exit 1');
    require JSON;
    my $p = JSON::decode_json($r->{stdout});
    is($p->{status},    'WARNING', 'JSON top-level WARNING');
    is($p->{exit_code}, 1,         'JSON exit_code 1');
}

done_testing;
