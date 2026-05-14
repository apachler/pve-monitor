use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/lib";
use PveMonitorTest qw(run_script data_dir);
use File::Spec;

# Regression guard against credential leakage on stdout / stderr.
#
# The Nagios plugin convention is that stdout is parsed by the monitoring
# host (Icinga2) into the service-state display, and --debug output goes
# to stderr. Neither stream should ever carry the configured
# monitor_password or monitor_token_secret value, because:
#
# - stdout ends up in the Icinga2 web UI and IDO database;
# - stderr typically ends up in the monitoring host's notification logs.
#
# The fixture t/data/redaction-canary.conf uses sentinel strings unique
# enough to survive any reasonable false-positive (no "secret" /
# "token" / "password" word fragments) so a substring match here is a
# real leak, not a collision with the script's own debug vocabulary
# ("Skipping $host: no password ... configured", etc.).

sub conf { File::Spec->catfile(data_dir(), $_[0]) }
sub mock { File::Spec->catfile(data_dir(), $_[0]) }

my $cfg          = conf('redaction-canary.conf');
my $PASSWORD     = 'CANARY-PASSWORD-7d3e9f1a-DO-NOT-LOG';
my $TOKEN_SECRET = 'CANARY-TOKENSECRET-b8c2e4a9-DO-NOT-LOG';

sub assert_no_canaries {
    my ($r, $label) = @_;
    unlike($r->{stdout}, qr/\Q$PASSWORD\E/,
           "$label: password literal absent from stdout");
    unlike($r->{stderr}, qr/\Q$PASSWORD\E/,
           "$label: password literal absent from stderr");
    unlike($r->{stdout}, qr/\Q$TOKEN_SECRET\E/,
           "$label: token secret literal absent from stdout");
    unlike($r->{stderr}, qr/\Q$TOKEN_SECRET\E/,
           "$label: token secret literal absent from stderr");
}

# Connection-failure path (no mock): the script iterates @monitoredNodes
# trying to connect, fails each, exits UNKNOWN. --debug exercises every
# debug() call on the loop including "Trying $host..." and "Skipping
# $host: no password and no token_id+token_secret configured".
{
    my $r = run_script(
        args => ['--conf', $cfg, '--nodes', '--debug',
                 '--timeout', '1'],
    );
    is($r->{exit}, 3, 'connection-fail path: exit UNKNOWN');
    assert_no_canaries($r, 'connection-fail + --debug');
}

# Same path with --json: the JSON early-exit branch is where a future
# "include config snapshot in error payload" patch would most plausibly
# leak credentials.
{
    my $r = run_script(
        args => ['--conf', $cfg, '--nodes', '--debug', '--json',
                 '--timeout', '1'],
    );
    is($r->{exit}, 3, 'connection-fail + --json: exit UNKNOWN');
    assert_no_canaries($r, 'connection-fail + --debug + --json');
}

# Successful-connect path under the mock: hits the post-connect debug
# lines ("Successfully connected to $host !", per-resource "Loaded ...")
# and the full reporting block.
{
    my $r = run_script(
        args           => ['--conf', $cfg, '--nodes', '--debug',
                           '--singlenode'],
        mock_responses => mock('mock-cluster-ok.json'),
    );
    isnt($r->{exit}, undef, 'mock-connect path: ran to exit');
    assert_no_canaries($r, 'mock-connect + --debug');
}

# Successful-connect with --json: the JSON serializer walks every node
# hashref. A bug where monitor_password / monitor_token_secret get
# included in the per-node payload would surface here.
{
    my $r = run_script(
        args           => ['--conf', $cfg, '--nodes', '--debug', '--json',
                           '--singlenode'],
        mock_responses => mock('mock-cluster-ok.json'),
    );
    isnt($r->{exit}, undef, 'mock-connect + --json: ran to exit');
    assert_no_canaries($r, 'mock-connect + --debug + --json');
}

done_testing;
