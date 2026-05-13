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

# Dead-node sentinel paths: every resource entry is missing 'status'/
# 'uptime'. Storage takes the 'on a dead node' branch (CRITICAL);
# qemu/openvz never get an 'alive' field populated and so fall to the
# 'is in status UNKNOWN' branch. max_status of CRITICAL(2) + UNKNOWN(3)
# returns UNKNOWN(3) by numeric comparison.
{
    my $r = run_script(
        args           => ['--conf', $cfg, '--storages', '--containers',
                           '--qemu', '--singlenode'],
        mock_responses => mock('mock-dead-node.json'),
    );
    is($r->{exit}, 3, 'dead-node mix: UNKNOWN dominates numerically');
    like($r->{stdout}, qr/storage is on a dead node/,
         'storage dead-node detail');
    like($r->{stdout}, qr/is in status UNKNOWN/,
         'VM-on-dead-node falls into UNKNOWN branch');
}

# Storage alone on a dead node -> CRITICAL.
{
    my $r = run_script(
        args           => ['--conf', $cfg, '--storages', '--singlenode'],
        mock_responses => mock('mock-dead-node.json'),
    );
    is($r->{exit}, 2, 'storage-only dead-node: CRITICAL');
    like($r->{stdout}, qr/STORAGE CRITICAL/, 'STORAGE CRITICAL summary');
}

# Dead-node nodes report: node section also handles 'uptime' undef.
{
    my $r = run_script(
        args           => ['--conf', $cfg, '--nodes', '--singlenode'],
        mock_responses => mock('mock-dead-node.json'),
    );
    isnt($r->{exit}, 0, 'dead-node nodes report: non-zero');
    like($r->{stdout}, qr/NODES/, 'NODES line emitted');
}

# Pool member already declared in the config -> grep-skip path fires:
# the config declares 'vm-from-pool' explicitly, and the pool mock
# lists a member of the same name. The script's grep guard at the
# auto-discovery point prevents a duplicate entry.
{
    my $r = run_script(
        args           => ['--conf', conf('pool-with-vm-overlap.conf'),
                           '--pools', 'everything', '--qemu', '--singlenode'],
        mock_responses => mock('mock-pool.json'),
    );
    is($r->{exit}, 0, 'overlap config + pool expansion: exit 0');
    my @count = $r->{stdout} =~ /vm-from-pool/g;
    is(scalar(@count), 1, 'vm-from-pool listed exactly once (no duplicate)');
}

# --ignoretemp: a pool member with template == 1 is skipped during
# expansion. With --ignoretemp, vm-template is filtered out; without
# it, vm-template is added and reports CRITICAL (status='stopped').
{
    my $with_ignore = run_script(
        args           => ['--conf', conf('pool-only.conf'), '--pools', 'everything',
                           '--qemu', '--singlenode', '--ignoretemp'],
        mock_responses => mock('mock-pool-with-template.json'),
    );
    my $without = run_script(
        args           => ['--conf', conf('pool-only.conf'), '--pools', 'everything',
                           '--qemu', '--singlenode'],
        mock_responses => mock('mock-pool-with-template.json'),
    );
    is($with_ignore->{exit}, 0, '--ignoretemp: template skipped, exit 0');
    unlike($with_ignore->{stdout}, qr/vm-template/,
           '--ignoretemp: vm-template absent from report');
    isnt($without->{exit}, 0, 'without --ignoretemp: template present, non-zero');
    like($without->{stdout}, qr/vm-template/,
           'without --ignoretemp: vm-template included');
}

# Node block with no password and no token pair: connection probe skips
# the node entirely (no auth credentials configured).
{
    my $r = run_script(
        args => ['--conf', conf('no-auth.conf'), '--nodes',
                 '--timeout', '1', '--debug'],
    );
    is($r->{exit}, 3, 'no auth fields -> UNKNOWN (no node reachable)');
    like($r->{stderr}, qr/no password and no token_id\+token_secret/,
         'debug message names the missing credential');
}

# Node block with token_id but no token_secret: same skip.
{
    my $r = run_script(
        args => ['--conf', conf('half-token.conf'), '--nodes',
                 '--timeout', '1', '--debug'],
    );
    is($r->{exit}, 3, 'token_id without token_secret -> UNKNOWN');
    like($r->{stderr}, qr/no password and no token_id\+token_secret/,
         'incomplete token pair flagged');
}

# Stopped VM + running VM: max_status climbs to CRITICAL.
{
    my $r = run_script(
        args           => ['--conf', $cfg, '--qemu', '--containers', '--singlenode'],
        mock_responses => mock('mock-cluster-stopped-vm.json'),
    );
    is($r->{exit}, 2, 'one stopped VM -> overall CRITICAL');
    like($r->{stdout}, qr/CRITICAL/, 'CRITICAL in summary');
}

done_testing;
