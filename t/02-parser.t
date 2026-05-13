use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/lib";
use PveMonitorTest qw(run_script data_dir);
use File::Spec;

sub conf { File::Spec->catfile(data_dir(), $_[0]) }

# --dry-run on a known-good config exercises every block parser.
{
    my $r = run_script(args => ['--conf', conf('full.conf'), '--dry-run']);
    is($r->{exit}, 0, 'dry-run on full.conf exits 0');
    like($r->{stdout}, qr/2 nodes/,      'parsed 2 nodes');
    like($r->{stdout}, qr/1 storages/,   'parsed 1 storage');
    like($r->{stdout}, qr/1 containers/, 'parsed 1 container');
    like($r->{stdout}, qr/1 qemu/,       'parsed 1 qemu');
    like($r->{stdout}, qr/1 pools/,      'parsed 1 pool');
}

# Token-auth config parses cleanly.
{
    my $r = run_script(args => ['--conf', conf('token-auth.conf'), '--dry-run']);
    is($r->{exit}, 0, 'dry-run on token-auth.conf exits 0');
    like($r->{stdout}, qr/1 nodes/, 'parsed 1 node with token auth');
}

# Unclosed block: $readingObject stays true; parser flags this.
{
    my $r = run_script(args => ['--conf', conf('unclosed-block.conf'), '--nodes']);
    isnt($r->{exit}, 0, 'unclosed block non-zero exit');
    like($r->{stdout}, qr/Invalid configuration/, 'unclosed block reports invalid');
}

# Unknown block type at the top level.
{
    my $r = run_script(args => ['--conf', conf('invalid-block.conf'), '--nodes']);
    isnt($r->{exit}, 0, 'unknown block type non-zero exit');
    like($r->{stdout}, qr/Invalid token notreal/, 'unknown block type names culprit');
}

# Unknown field inside a node block.
{
    my $r = run_script(args => ['--conf', conf('invalid-token.conf'), '--nodes']);
    isnt($r->{exit}, 0, 'unknown field non-zero exit');
    like($r->{stdout}, qr/Invalid token bogus_field/,
         'unknown field names culprit');
}

# Non-numeric threshold value.
{
    my $r = run_script(args => ['--conf', conf('invalid-threshold.conf'), '--qemu']);
    isnt($r->{exit}, 0, 'non-numeric threshold non-zero exit');
    like($r->{stdout}, qr/Invalid MEM declaration/, 'invalid threshold flagged');
}

# Missing config file.
{
    my $r = run_script(args => ['--conf', '/nonexistent/path.conf', '--nodes']);
    isnt($r->{exit}, 0, 'missing conf non-zero exit');
    like($r->{stdout}, qr/Cannot load configuration/, 'missing conf reports error');
}

done_testing;
