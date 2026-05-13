package PveMonitorTest;
use strict;
use warnings;
use FindBin;
use File::Spec;
use Exporter 'import';

our @EXPORT_OK = qw(run_script script_path mock_dir data_dir);

sub script_path { File::Spec->catfile($FindBin::Bin, '..', 'pve-monitor.pl') }
sub mock_dir    { File::Spec->catdir($FindBin::Bin, 'lib') }
sub data_dir    { File::Spec->catdir($FindBin::Bin, 'data') }

# Invoke pve-monitor.pl as a subprocess so each test gets isolated
# global state (the script is a single-file linear program with lots
# of package-globals).
#
# Returns hashref { stdout, stderr, exit }.
#
# Options:
#   args           => [ '--conf', ..., ... ]
#   mock_responses => '/abs/path/to/responses.json' (sets PVE_MOCK_RESPONSES)
#   env            => { KEY => 'value', ... }
sub run_script {
    my (%opts) = @_;
    my $args    = $opts{args} || [];
    my $mock    = $opts{mock_responses};
    my $env_add = $opts{env} || {};

    local %ENV = %ENV;
    # Prepend t/lib so the script's `use Net::Proxmox::VE` resolves to
    # our mock before reaching site_perl. The PERL5OPT trick below lets
    # Devel::Cover instrument the subprocess when the test runner has
    # it active.
    my $sep = ($^O eq 'MSWin32') ? ';' : ':';
    $ENV{PERL5LIB} = join $sep, mock_dir(), ($ENV{PERL5LIB} // ());
    $ENV{PVE_MOCK_RESPONSES} = $mock if defined $mock;
    delete $ENV{PVE_MOCK_RESPONSES} unless defined $mock;
    $ENV{$_} = $env_add->{$_} for keys %$env_add;

    pipe(my $out_r, my $out_w) or die "pipe: $!";
    pipe(my $err_r, my $err_w) or die "pipe: $!";
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if ($pid == 0) {
        close $out_r; close $err_r;
        open STDOUT, '>&', $out_w or die "dup stdout: $!";
        open STDERR, '>&', $err_w or die "dup stderr: $!";
        exec $^X, script_path(), @$args;
        exit 127;
    }
    close $out_w; close $err_w;
    my $stdout = do { local $/; <$out_r> } // '';
    my $stderr = do { local $/; <$err_r> } // '';
    waitpid($pid, 0);
    my $exit = $? >> 8;
    return { stdout => $stdout, stderr => $stderr, exit => $exit };
}

1;
