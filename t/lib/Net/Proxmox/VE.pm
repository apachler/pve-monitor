package Net::Proxmox::VE;
# Test mock for Net::Proxmox::VE. Loaded by t/*.t via PERL5LIB and
# preempts the real CPAN module in the script's @INC. Returns canned
# data keyed by API path; the canned set is loaded from the JSON file
# named in $ENV{PVE_MOCK_RESPONSES} (absent = empty set, every get()
# returns undef so the script falls into its connection-fail path).
use strict;
use warnings;
use JSON ();

our $RESPONSES;

sub _load_responses {
    my $file = $ENV{PVE_MOCK_RESPONSES} or return {};
    return {} unless -r $file;
    open my $fh, '<', $file or die "mock: open $file: $!";
    local $/;
    my $raw = <$fh>;
    close $fh;
    return JSON::decode_json($raw);
}

sub new {
    my ($class, %args) = @_;
    $RESPONSES //= _load_responses();
    return bless { args => \%args }, $class;
}

# Always succeed at the auth handshake — tests that care about auth
# failure assert against the path *before* this (config parsing or
# token-field requirements), not the HTTPS round-trip.
sub login              { 1 }
sub check_login_ticket { 1 }
sub api_version_check  { 1 }

sub get {
    my ($self, $path) = @_;
    return exists $RESPONSES->{$path} ? $RESPONSES->{$path} : undef;
}

1;
