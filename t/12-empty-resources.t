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

# Regression: when /cluster/resources returns undef (no body, or stub
# PVE that doesn't expose the endpoint), the script used to die with
# 'Can't use an undefined value as an ARRAY reference'. Now it must
# survive and report UNKNOWN cleanly.
{
    my $r = run_script(
        args           => ['--conf', $cfg, '--nodes', '--singlenode'],
        mock_responses => mock('mock-empty-resources.json'),
    );
    # Exit code can be UNKNOWN or CRITICAL depending on aggregation,
    # but it must not be a "killed by signal" exit (>= 128) and the
    # output must not contain the Perl "undefined value as ARRAY"
    # diagnostic that the old code path raised.
    ok($r->{exit} < 128, "doesn't die on undef /cluster/resources (exit=$r->{exit})");
    unlike($r->{stderr}, qr/undefined value as an ARRAY/,
           'no array-deref-of-undef in stderr');
    unlike($r->{stdout}, qr/undefined value as an ARRAY/,
           'no array-deref-of-undef in stdout');
}

# Same scenario, --json mode: must produce parsable JSON (not a
# half-printed Perl trace).
{
    my $r = run_script(
        args           => ['--conf', $cfg, '--nodes', '--singlenode', '--json'],
        mock_responses => mock('mock-empty-resources.json'),
    );
    ok($r->{exit} < 128, '--json + empty resources doesn\'t crash');
    require JSON;
    my $payload;
    eval { $payload = JSON::decode_json($r->{stdout}); 1 }
        or fail("stdout parses as JSON: $@");
    ok($payload, 'JSON payload present');
}

# All checks should survive the empty-resources mock simultaneously.
{
    my $r = run_script(
        args           => ['--conf', $cfg, '--nodes', '--storages',
                           '--containers', '--qemu', '--ceph',
                           '--subscriptions', '--singlenode'],
        mock_responses => mock('mock-empty-resources.json'),
    );
    ok($r->{exit} < 128, 'every mode + empty resources: no crash');
}

done_testing;
