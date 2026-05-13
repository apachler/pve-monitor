use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/lib";
use PveMonitorTest qw(run_script data_dir);
use File::Spec;
use File::Temp ();
use JSON ();

sub conf { File::Spec->catfile(data_dir(), $_[0]) }
my $cfg = conf('full.conf');

# Format a YYYY-MM-DD date $offset_days from today using the same coarse
# day arithmetic that the script does, so this test stays in lockstep
# with its under-test peer.
sub date_offset {
    my ($offset) = @_;
    my @t = localtime(time + $offset * 86400);
    return sprintf '%04d-%02d-%02d', $t[5] + 1900, $t[4] + 1, $t[3];
}

# Write a JSON mock file with two nodes whose subscriptions vary.
sub build_mock {
    my (%nodes) = @_;
    my %doc = (
        '/cluster/status' => [
            { type => 'node', name => 'node1', id => 'node/node1',
              ip => '127.0.0.1', local => '1', qdisk => '0',
              estranged => '0', state => '1' },
        ],
        '/cluster/resources' => [
            { type => 'node', node => 'node1', status => 'online',
              uptime => 100, mem => 1, maxmem => 100, cpu => 0.1,
              maxcpu => 2, disk => 1, maxdisk => 100 },
        ],
    );
    for my $n (sort keys %nodes) {
        $doc{"/nodes/$n/subscription"} = $nodes{$n};
    }
    my (undef, $path) = File::Temp::tempfile('subXXXXXX', SUFFIX => '.json',
                                              TMPDIR => 1, UNLINK => 0);
    open my $fh, '>', $path or die "open $path: $!";
    print $fh JSON::encode_json(\%doc);
    close $fh;
    return $path;
}

# Active sub, expiry far in the future -> OK.
{
    my $mock = build_mock(
        node1 => { status => 'active', nextduedate => date_offset(365) },
        node2 => { status => 'active', nextduedate => date_offset(180) },
    );
    my $r = run_script(
        args           => ['--conf', $cfg, '--subscriptions', '--singlenode'],
        mock_responses => $mock,
    );
    is($r->{exit}, 0, 'far-future expiry -> exit 0');
    like($r->{stdout}, qr/SUBSCRIPTIONS OK/, 'OK summary');
    unlink $mock;
}

# Within --sub-warn-days but not --sub-crit-days -> WARNING.
{
    my $mock = build_mock(
        node1 => { status => 'active', nextduedate => date_offset(20) },
        node2 => { status => 'active', nextduedate => date_offset(365) },
    );
    my $r = run_script(
        args           => ['--conf', $cfg, '--subscriptions', '--singlenode'],
        mock_responses => $mock,
    );
    is($r->{exit}, 1, 'expiry in 20 days -> WARNING');
    like($r->{stdout}, qr/SUBSCRIPTIONS WARNING/, 'WARNING summary');
    like($r->{stdout}, qr/node1: \d+ days/, 'node1 day count in detail');
    unlink $mock;
}

# Within --sub-crit-days -> CRITICAL.
{
    my $mock = build_mock(
        node1 => { status => 'active', nextduedate => date_offset(3) },
        node2 => { status => 'active', nextduedate => date_offset(365) },
    );
    my $r = run_script(
        args           => ['--conf', $cfg, '--subscriptions', '--singlenode'],
        mock_responses => $mock,
    );
    is($r->{exit}, 2, 'expiry in 3 days -> CRITICAL');
    like($r->{stdout}, qr/SUBSCRIPTIONS CRITICAL/, 'CRITICAL summary');
    unlink $mock;
}

# status != 'active' -> CRITICAL regardless of date.
{
    my $mock = build_mock(
        node1 => { status => 'notfound', nextduedate => date_offset(365) },
        node2 => { status => 'active',   nextduedate => date_offset(365) },
    );
    my $r = run_script(
        args           => ['--conf', $cfg, '--subscriptions', '--singlenode'],
        mock_responses => $mock,
    );
    is($r->{exit}, 2, 'inactive sub -> CRITICAL');
    like($r->{stdout}, qr/subscription is 'notfound'/, 'inactive status reported');
    unlink $mock;
}

# Configurable thresholds: tighten warn-days so 60-day expiry triggers.
{
    my $mock = build_mock(
        node1 => { status => 'active', nextduedate => date_offset(60) },
        node2 => { status => 'active', nextduedate => date_offset(365) },
    );
    my $r = run_script(
        args           => ['--conf', $cfg, '--subscriptions', '--singlenode',
                           '--sub-warn-days', '90'],
        mock_responses => $mock,
    );
    is($r->{exit}, 1, '60d expiry with --sub-warn-days 90 -> WARNING');
    unlink $mock;
}

# Missing subscription endpoint for the node -> UNKNOWN.
{
    my $mock = build_mock();   # no /nodes/*/subscription keys
    my $r = run_script(
        args           => ['--conf', $cfg, '--subscriptions', '--singlenode'],
        mock_responses => $mock,
    );
    is($r->{exit}, 3, 'absent subscription endpoint -> UNKNOWN');
    like($r->{stdout}, qr/subscription unavailable/, 'reports unavailable');
    unlink $mock;
}

done_testing;
