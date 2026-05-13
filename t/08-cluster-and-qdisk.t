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

# Cluster quorum probe rejects an estranged-only node -> "Could not connect".
{
    my $r = run_script(
        args           => ['--conf', $cfg, '--nodes', '--timeout', '1'],
        mock_responses => mock('mock-no-quorum.json'),
    );
    is($r->{exit}, 3, 'no quorate node -> UNKNOWN');
    like($r->{stdout}, qr/Could not connect/, 'connection-fail message');
}

# --singlenode bypasses the quorum check entirely. The mock only lists
# one node in /cluster/resources while the config has two, so node2
# ends up UNKNOWN — what matters is that the script *reached* the
# report stage rather than bailing at the connection probe.
{
    my $r = run_script(
        args           => ['--conf', $cfg, '--nodes', '--singlenode'],
        mock_responses => mock('mock-no-quorum.json'),
    );
    unlike($r->{stdout}, qr/Could not connect/,
           '--singlenode reached the report stage despite no-quorum mock');
    like($r->{stdout}, qr/^NODES /m, 'NODES report line emitted');
}

# --qdisk: healthy qdisk -> OK.
{
    my $r = run_script(
        args           => ['--conf', $cfg, '--qdisk'],
        mock_responses => mock('mock-qdisk.json'),
    );
    is($r->{exit}, 0, 'qdisk OK exit 0');
    like($r->{stdout}, qr/Qdisk OK/, 'Qdisk OK summary');
}

# --qdisk: estranged + bad state -> non-OK status.
{
    my $r = run_script(
        args           => ['--conf', $cfg, '--qdisk'],
        mock_responses => mock('mock-qdisk-broken.json'),
    );
    isnt($r->{exit}, 0, 'broken qdisk non-zero exit');
    like($r->{stdout}, qr/Qdisk/, 'Qdisk summary present');
    like($r->{stdout}, qr/estranged|invalid status/, 'reason reported');
}

# --qdisk: no qdisk in cluster -> UNKNOWN.
{
    my $r = run_script(
        args           => ['--conf', $cfg, '--qdisk'],
        mock_responses => mock('mock-cluster-ok.json'),
    );
    is($r->{exit}, 3, 'no qdisk in cluster -> UNKNOWN');
    like($r->{stdout}, qr/No qdisk found/, 'no-qdisk message');
}

done_testing;
