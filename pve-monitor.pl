#!/usr/bin/perl

#####################################################
#
#    Proxmox VE cluster monitoring tool
#
#####################################################
#
#   Requires Net::Proxmox::VE librairy:
#     git://github.com/dpiquet/proxmox-ve-api-perl.git
#
# License Information:
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
#
# Authors & contributors
#   Damien PIQUET damien.piquet@iutbeziers.fr || piqudam@gmail.com
#   Alexey Dvoryanchikov github.com/dvoryanchikov
#   Andreas Pachler https://github.com/apachler
#

use strict;
use warnings;

use Net::Proxmox::VE;
use IO::Socket::SSL;
use Getopt::Long;

my $configurationFile = './pve-monitor.conf';
my $pluginVersion = '1.1';

my %status = (
    'UNDEF'    => -1,
    'OK'       => 0,
    'WARNING'  => 1,
    'CRITICAL' => 2,
    'UNKNOWN'  => 3,
);

my %rstatus = reverse %status;

my %arguments = (
    'nodes'          => undef,
    'storages'       => undef,
    'openvz'         => undef,
    'qemu'           => undef,
    'pools'          => undef,
    'ignoretemp'     => undef,
    'qdisk'          => undef,
    'conf'           => undef,
    'show_help'      => undef,
    'show_version'   => undef,
    'timeout'        => 5,
    'debug'          => undef,
    'singlenode'     => undef,
    'verify_ssl'     => undef,
    'check'          => undef,
);

sub usage {
    print "Usage: $0 [--nodes] [--storages] [--qemu] [--openvz] [--pools <All|Pool>] [--perfdata] [--html] --conf <file>\n";
    print "\n";
    print "  --nodes\n";
    print "    Check the state of the cluster's members\n";
    print "  --storages\n";
    print "    Check the state of the cluster's storages\n";
    print "  --qemu\n";
    print "    Check the state of the cluster's Qemu virtual machines\n";
    print "  --openvz\n";
    print "    Check the state of the cluster's OpenVZ virtual machines\n";
    print "    [DEPRECATED] We keep it for pve-monitor < 1.07 back compat\n";
    print "  --containers\n";
    print "    Check the state of the cluster's containers (both openvz and lxc)\n";
    print "  --pools\n";
    print "    Check the state of the cluster's virtual machines and/or storages in defined pools\n";
    print "    Can be All or already defined Pool name\n";
    print "  --ignoretemp\n";
    print "    Ignore VMs defined as templates from pool list. Works only with --pools option\n";
    print "  --qdisk\n";
    print "    Check the state of the cluster's quorum disk\n";
    print "  --singlenode\n";
    print "    Consider there is no cluster, just a single node\n";
    print "  --verify-ssl\n";
    print "    Verify the PVE node's TLS certificate (default: disabled for self-signed certs)\n";
    print "  --check <list>\n";
    print "    Comma-separated list of checks (alias for the per-mode flags above).\n";
    print "    Example: --check nodes,storages,qemu,containers\n";
    print "  --perfdata\n";
    print "    Print nagios performance data for graphs (PNP4Nagios supported check_multi style) \n";
    print "  --html\n";
    print "    Replace linebreaks with <br> in output\n";
    print "  --debug\n";
    print "    Get more log output\n";
}

sub is_number {
    ($_[0] =~ m/^[0-9]+$/) ? return 1 : return 0;
}

sub debug {
    return unless $arguments{debug};
    print STDERR @_;
}

# Aggregate Nagios statuses: return the most severe among the supplied codes.
# Treats $status{UNDEF} (-1) as benign; OK/WARNING/CRITICAL/UNKNOWN order by value.
sub max_status {
    my $m = $status{OK};
    for my $s (@_) {
        next unless defined $s;
        $m = $s if $s > $m;
    }
    return $m;
}

# Compare $value against $obj->{warn_<metric>} / $obj->{crit_<metric>}
# and write the result into $obj->{<metric>_status}.
sub evaluate_threshold {
    my ($obj, $metric, $value) = @_;
    my $warn = $obj->{"warn_$metric"};
    my $crit = $obj->{"crit_$metric"};
    if (defined $warn && $value > $warn) {
        $obj->{"${metric}_status"} = $status{WARNING};
    }
    if (defined $crit && $value > $crit) {
        $obj->{"${metric}_status"} = $status{CRITICAL};
    }
}

GetOptions ("nodes"       => \$arguments{nodes},
            "storages"    => \$arguments{storages},
            "openvz"      => \$arguments{openvz},
            "containers"  => \$arguments{openvz},
            "qemu"        => \$arguments{qemu},
            "pools=s"     => \$arguments{pools},
            "ignoretemp"  => \$arguments{ignoretemp},
            "qdisk"       => \$arguments{qdisk},
            "singlenode"  => \$arguments{singlenode},
            "verify-ssl"  => \$arguments{verify_ssl},
            "check=s"     => \$arguments{check},
            "perfdata"    => \$arguments{perfdata},
            "html"        => \$arguments{html},
            "conf=s"      => \$arguments{conf},
            'version|V'   => \$arguments{show_version},
            'help|h'      => \$arguments{show_help},
            'timeout|t=s' => \$arguments{timeout},
            'debug'       => \$arguments{debug},
);

if (defined $arguments{check}) {
    # --check nodes,storages,qemu maps onto the existing per-flag arguments
    my %check_alias = (
        nodes      => 'nodes',
        storages   => 'storages',
        qemu       => 'qemu',
        openvz     => 'openvz',
        containers => 'openvz',
        qdisk      => 'qdisk',
    );
    for my $c (split /\s*,\s*/, $arguments{check}) {
        my $key = $check_alias{$c}
            or do { print "Unknown --check value: $c\n"; exit $status{UNKNOWN}; };
        $arguments{$key} = 1;
    }
}

debug "Starting pve-monitor $pluginVersion\n";

debug "Setting timeout to $arguments{timeout}\n";

if (defined $arguments{show_version}) {
    print "$0 version $pluginVersion\n";
    exit $status{OK};
}

if (defined $arguments{show_help}) {
    usage();
    exit $status{UNKNOWN};
}

if (! defined $arguments{conf}) {
    usage();
    exit $status{UNKNOWN};
}

# Arrays for objects to monitor
my @monitoredStorages;
my @monitoredNodes;
my @monitoredOpenvz;
my @monitoredQemus;
my @monitoredPools;

my $connected = 0;
my $host = undef;
my $username = undef;
my $password = undef;
my $realm = undef;
my $pve;

my $qdiskStatus = undef;
my %qdisk = (
    id => undef,
    name => undef,
    estranged => undef,
    cstate => undef,
    status => $status{UNKNOWN},
);

my $readingObject = 0;

# Output option
my $br = "\n";
$br = "<br>" if (defined $arguments{html});

# Read the configuration file
if (! open FILE, "<", "$arguments{conf}") {
    debug "$!\n";
    print "Cannot load configuration file $arguments{conf} !\n";
    exit $status{UNKNOWN};
}

while ( <FILE> ) {
    my $line = $_;

    # Skip commented lines (starting with #)
    next if $line =~ m/^#/i;

    # we got an object definition here !
    if ( $line =~ m/([\S]+)\s+([\S]+)\s+\{/i ) {
         my ($blockType, $blockName) = ($1, $2);
         if ($blockType eq "node") {
                 my $name         = $blockName;
                 my $warnCpu      = undef;
                 my $warnMem      = undef;
                 my $warnDisk     = undef;
                 my $critCpu      = undef;
                 my $critMem      = undef;
                 my $critDisk     = undef;
                 my $nAddr        = undef;
                 my $nPort        = 8006;
                 my $nUser        = undef;
                 my $nPwd         = undef;
                 my $nRealm       = 'pam';
                 my $warnMemAlloc = undef;
                 my $critMemAlloc = undef;
                 my $warnCpuAlloc = undef;
                 my $critCpuAlloc = undef;

                 $readingObject = 1;

                 while (<FILE>) {
                     my $objLine = $_;

                     next if ( $objLine =~ m/^(\s+)?#/ );
                     if ( $objLine =~ m/([\S]+)\s+([\S]+)(\s+([\S]+))?/i ) {
                         my $token = $1;
                         if ($token eq "cpu") {
                             if ((is_number $2)and(is_number $4)) {
                                 $warnCpu = $2;
                                 $critCpu = $4;
                             }
                             else {
                                 close(FILE);
                                 print "Invalid CPU declaration " .
                                       "in $name definition\n";
                                 exit $status{UNKNOWN};
                             }
                         }
                         elsif ($token eq "cpu_alloc") {
                             if((is_number $2)and(is_number $4)) {
                                 $warnCpuAlloc = $2;
                                 $critCpuAlloc = $4;
                             }
                             else {
                                 close(FILE);
                                 print "Invalid CPU_ALLOC declaration " .
                                       "in $name definition\n";
                                 exit $status{UNKNOWN};
                             }
                         }
                         elsif ($token eq "mem") {
                             if ((is_number $2)and(is_number $4)) {
                                 $warnMem = $2;
                                 $critMem = $4;
                             }
                             else {
                                 close(FILE);
                                 print "Invalid MEM declaration " .
                                       "in $name definition\n";
                                 exit $status{UNKNOWN};
                             }
                         }
                         elsif ($token eq "disk") {
                             if ((is_number $2)and(is_number $4)) {
                                 $warnDisk = $2;
                                 $critDisk = $4;
                             }
                             else {
                                 close(FILE);
                                 print "Invalid DISK declaration " .
                                       "in $name definition\n";
                                 exit $status{UNKNOWN};
                             }
                         }
                         elsif ($token eq "mem_alloc") {
                             if ((is_number $2)and(is_number $4)) {
                                 $warnMemAlloc = $2;
                                 $critMemAlloc = $4;
                             }
                             else {
                                 close(FILE);
                                 print "Invalid MEM_ALLOC declaration " .
                                       "in $name definition\n";
                                 exit $status{UNKNOWN};
                             }
                         }
                         elsif ($token eq "address") {
                             $nAddr = $2;
                         }
                         elsif ($token eq "port") {
                             if (is_number $2) {
                                 $nPort = $2;
                             }
                             else {
                                 close(FILE);
                                 print "Invalid PORT declaration " .
                                       "in $name definition\n";
                                 exit $status{UNKNOWN};
                             }
                         }
                         elsif ($token eq "monitor_account") {
                             $nUser = $2;
                         }
                         elsif ($token eq "monitor_password") {
                             $nPwd = $2;
                         }
                         elsif ($token eq "realm") {
                             $nRealm = $2;
                         }
                         else {
                             close(FILE);
                             print "Invalid token $token in $name definition !\n";
                             exit $status{UNKNOWN};
                         }
                     }
                     elsif ( $objLine =~ m/\}/i ) {
                         # check object requirements are met, save it, break
                         if (! defined $name ) {
                             close(FILE);
                             print "Invalid configuration !";
                             exit $status{UNKNOWN};
                         }

                         debug "Loaded node $name\n";

                         $monitoredNodes[scalar(@monitoredNodes)] = ({
                                 name             => $name,
                                 address          => $nAddr,
                                 port             => $nPort,
                                 username         => $nUser,
                                 realm            => $nRealm,
                                 password         => $nPwd,
                                 warn_cpu         => $warnCpu,
                                 warn_cpu_alloc   => $warnCpuAlloc,
                                 warn_mem         => $warnMem,
                                 warn_mem_alloc   => $warnMemAlloc,
                                 warn_disk        => $warnDisk,
                                 crit_cpu         => $critCpu,
                                 crit_cpu_alloc   => $critCpuAlloc,
                                 crit_mem         => $critMem,
                                 crit_mem_alloc   => $critMemAlloc,
                                 crit_disk        => $critDisk,
                                 cpu_status       => $status{OK},
                                 mem_status       => $status{OK},
                                 disk_status      => $status{OK},
                                 mem_alloc_status => $status{OK},
                                 cpu_alloc_status => $status{OK},
                                 alive            => 0,
                                 curmem           => undef,
                                 curdisk          => undef,
                                 curcpu           => undef,
                                 status           => $status{UNDEF},
                                 uptime           => undef,
                                 mem_alloc        => 0,
                                 maxmem           => undef,
                                 cpu_alloc        => 0,
                                 maxcpu           => undef,
                             },
                         );
                         
                         $readingObject = 0;
                         last;
                     }
                     else {
                         debug "Invalid line " . chomp($objLine) . " at line $. !\n";
                     }
                 }
             }

         elsif ($blockType eq "storage") {
                 my $name     = $blockName;
                 my $warnDisk = undef;
                 my $critDisk = undef;
                 my $node = undef;

                 $readingObject = 1;

                 while (<FILE>) {
                     my $objLine = $_;

                     next if ( $objLine =~ m/^#/i );
                     if ( $objLine =~ m/([\S]+)\s+([\S]+)(\s+([\S]+))?/i ) {
                         my $token = $1;
                         if ($token eq "disk") {
                             if ((is_number $2)and(is_number $4)) {
                                 $warnDisk = $2;
                                 $critDisk = $4;
                             }
                             else {
                                 close(FILE);
                                 print "Invalid DISK declaration " .
                                       "in $name definition\n";
                                 exit $status{UNKNOWN};
                             }
                         }
                         elsif ($token eq "node") {
                             $node = $2;
                         }
                         else {
                             close(FILE);
                             print "Invalid token $token " .
                                   "in $name definition !\n";
                             exit $status{UNKNOWN};
                         }
                     }
                     elsif ( $objLine =~ m/\}/i ) {
                         # check object requirements are met, save it, break
                         if (! defined $name ) {
                             close(FILE);
                             print "Invalid configuration !";
                             exit $status{UNKNOWN};
                         }

                         if (! defined $node ) {
                             close(FILE);
                             print "Invalid configuration, " . 
                                   "missing node in $name storage definition !\n";
                             exit $status{UNKNOWN};
                         }

                         debug "Loaded storage $name\n";

                         $monitoredStorages[scalar(@monitoredStorages)] = ({
                                 name         => $name,
                                 node         => $node,
                                 warn_disk    => $warnDisk,
                                 crit_disk    => $critDisk,
                                 curdisk      => undef,
                                 disk_status  => $status{OK},
                                 status       => $status{UNDEF},
                             },
                         );
                         $readingObject = 0;
                         last;
                     }
                 }

             }
         elsif ($blockType =~ /openvz|lxc|container/) {
                 my $name     = $blockName;
                 my $warnCpu  = undef;
                 my $warnMem  = undef;
                 my $warnDisk = undef;
                 my $critCpu  = undef;
                 my $critMem  = undef;
                 my $critDisk = undef;

                 $readingObject = 1;

                 while (<FILE>) {
                     my $objLine = $_;

                     next if ( $objLine =~ m/^#/i );
                     if ( $objLine =~ m/([\S]+)\s+([\S]+)\s+([\S]+)/i ) {
                         my $token = $1;
                         if ($token eq "cpu") {
                             if ((is_number $2) and (is_number $3)) {
                                 $warnCpu = $2;
                                 $critCpu = $3;
                             }
                             else {
                                 close(FILE);
                                 print "Invalid CPU declaration " .
                                       "in $name definition\n";
                                 exit $status{UNKNOWN};
                             }
                         }
                         elsif ($token eq "mem") {
                             if ((is_number $2) and (is_number $3)) {
                                 $warnMem = $2;
                                 $critMem = $3;
                             }
                             else {
                                 close(FILE);
                                 print "Invalid MEM declaration " .
                                       "in $name definition\n";
                                 exit $status{UNKNOWN};
                             }
                         }
                         elsif ($token eq "disk") {
                             if ((is_number $2) and (is_number $3)) {
                                 $warnDisk = $2;
                                 $critDisk = $3;
                             }
                             else {
                                 close(FILE);
                                 print "Invalid DISK declaration " .
                                       "in $name definition\n";
                                 exit $status{UNKNOWN};
                             }
                         }
                         else {
                             close(FILE);
                             print "Invalid token $token " .
                                   "in $name definition !\n";
                             exit $status{UNKNOWN};
                         }
                     }
                     elsif ( $objLine =~ m/\}/i ) {
                         # check object requirements are met, save it, break
                         if (! defined $name ) {
                             close(FILE);
                             print "Invalid configuration !";
                             exit $status{UNKNOWN};
                         }

                         debug "Loaded openvz $name\n";

                         $monitoredOpenvz[scalar(@monitoredOpenvz)] = ({
                                 name         => $name,
                                 warn_cpu     => $warnCpu,
                                 warn_mem     => $warnMem,
                                 warn_disk    => $warnDisk,
                                 crit_cpu     => $critCpu,
                                 crit_mem     => $critMem,
                                 crit_disk    => $critDisk,
                                 alive        => undef,
                                 curmem       => undef,
                                 curdisk      => undef,
                                 curcpu       => undef,
                                 cpu_status   => $status{OK},
                                 mem_status   => $status{OK},
                                 disk_status  => $status{OK},
                                 status       => $status{UNDEF},
                                 uptime       => undef,
                                 node         => undef,
                             },
                         );
                         $readingObject = 0;
                         last;
                     }
                 }
             }
         elsif ($blockType eq "qemu") {
                 my $name     = $blockName;
                 my $warnCpu  = undef;
                 my $warnMem  = undef;
                 my $warnDisk = undef;
                 my $critCpu  = undef;
                 my $critMem  = undef;
                 my $critDisk = undef;

                 $readingObject = 1;

                 while (<FILE>) {
                     my $objLine = $_;

                     next if ( $objLine =~ m/^#/i );
                     if ( $objLine =~ m/([\S]+)\s+([\S]+)\s+([\S]+)/i ) {
                         my $token = $1;
                         if ($token eq "cpu") {
                             if ((is_number $2)and(is_number $3)) {
                                 $warnCpu = $2;
                                 $critCpu = $3;
                             }
                             else {
                                 close(FILE);
                                 print "Invalid CPU declaration " .
                                       "in $name definition\n";
                                 exit $status{UNKNOWN};
                             }
                         }
                         elsif ($token eq "mem") {
                             if ((is_number $2)and(is_number $3)) {
                                 $warnMem = $2;
                                 $critMem = $3;
                             }
                             else {
                                 close(FILE);
                                 print "Invalid MEM declaration " .
                                       "in $name definition\n";
                                 exit $status{UNKNOWN};
                             }
                         }
                         elsif ($token eq "disk") {
                             if ((is_number $2)and(is_number $3)) {
                                 $warnDisk = $2;
                                 $critDisk = $3;
                             }
                             else {
                                 close(FILE);
                                 print "Invalid DISK declaration " .
                                       "in $name definition\n";
                                 exit $status{UNKNOWN};
                             }
                         }
                         else {
                             close(FILE);
                             print "Invalid token $token " .
                                   "in $name definition !\n";
                             exit $status{UNKNOWN};
                         }
                     }
                     elsif ( $objLine =~ m/\}/i ) {
                         # check object requirements are met, save it, break
                         if (! defined $name ) {
                             close(FILE);
                             print "Invalid configuration !\n";
                             exit $status{UNKNOWN};
                         }

                         debug "Loaded qemu $name\n";

                         $monitoredQemus[scalar(@monitoredQemus)] = (
                             {
                                 name         => $name,
                                 warn_cpu     => $warnCpu,
                                 warn_mem     => $warnMem,
                                 warn_disk    => $warnDisk,
                                 crit_cpu     => $critCpu,
                                 crit_mem     => $critMem,
                                 crit_disk    => $critDisk,
                                 alive        => undef,
                                 curmem       => undef,
                                 curdisk      => undef,
                                 curcpu       => undef,
                                 cpu_status   => $status{OK},
                                 mem_status   => $status{OK},
                                 disk_status  => $status{OK},
                                 status       => $status{UNDEF},
                                 uptime       => undef,
                                 node         => undef,
                             },
                         );
                         $readingObject = 0;
                         last;
                     }
                 }
             }
         elsif ($blockType eq "pool") {
                 my $name     = $blockName;
                 my $warnCpu  = undef;
                 my $warnMem  = undef;
                 my $warnDisk = undef;
                 my $critCpu  = undef;
                 my $critMem  = undef;
                 my $critDisk = undef;

                 $readingObject = 1;

                 while (<FILE>) {
                     my $objLine = $_;

                     next if ( $objLine =~ m/^#/i );
                     if ( $objLine =~ m/([\S]+)\s+([\S]+)\s+([\S]+)/i ) {
                         my $token = $1;
                         if ($token eq "cpu") {
                             if ((is_number $2)and(is_number $3)) {
                                 $warnCpu = $2;
                                 $critCpu = $3;
                             }
                             else {
                                 close(FILE);
                                 print "Invalid CPU declaration " .
                                       "in $name definition\n";
                                 exit $status{UNKNOWN};
                             }
                         }
                         elsif ($token eq "mem") {
                             if ((is_number $2)and(is_number $3)) {
                                 $warnMem = $2;
                                 $critMem = $3;
                             }
                             else {
                                 close(FILE);
                                 print "Invalid MEM declaration " .
                                       "in $name definition\n";
                                 exit $status{UNKNOWN};
                             }
                         }
                         elsif ($token eq "disk") {
                             if ((is_number $2)and(is_number $3)) {
                                 $warnDisk = $2;
                                 $critDisk = $3;
                             }
                             else {
                                 close(FILE);
                                 print "Invalid DISK declaration " .
                                       "in $name definition\n";
                                 exit $status{UNKNOWN};
                             }
                         }
                         else {
                             close(FILE);
                             print "Invalid token $token " .
                                   "in $name definition !\n";
                             exit $status{UNKNOWN};
                         }
                     }
                     elsif ( $objLine =~ m/\}/i ) {
                         # check object requirements are met, save it, break
                         if (! defined $name ) {
                             close(FILE);
                             print "Invalid configuration !\n";
                             exit $status{UNKNOWN};
                         }

                         debug "Loaded pool $name\n";

                         $monitoredPools[scalar(@monitoredPools)] = (
                             {
                                 name         => $name,
                                 warn_cpu     => $warnCpu,
                                 warn_mem     => $warnMem,
                                 warn_disk    => $warnDisk,
                                 crit_cpu     => $critCpu,
                                 crit_mem     => $critMem,
                                 crit_disk    => $critDisk,
                             },
                         );
                         $readingObject = 0;
                         last;
                     }
                 }
             }
         else {
             close(FILE);
             print "Invalid token $blockType " .
                   "in configuration file $arguments{conf} !\n";
             exit $status{UNKNOWN};
         }
    }
}

close(FILE);

if ( $readingObject ) {
    print "Invalid configuration ! (Probably missing '}' ) \n";
    exit $status{UNKNOWN};
}

# Probe nodes in randomized order so a dead node at the head of the config
# doesn't make every check pay its connect-timeout cost.
my @probeOrder = sort { rand() <=> rand() } 0 .. $#monitoredNodes;
for my $a (@probeOrder) {
    my $host     = $monitoredNodes[$a]->{address}  or next;
    my $port     = $monitoredNodes[$a]->{port}     or next;
    my $username = $monitoredNodes[$a]->{username} or next;
    my $password = $monitoredNodes[$a]->{password} or next;
    my $realm    = $monitoredNodes[$a]->{realm}    or next;

    my $isClusterMember = 0;

    debug "Trying " . $host . "...\n";

    $pve = Net::Proxmox::VE->new(
        host     => $host,
        username => $username,
        password => $password,
        debug    => $arguments{debug},
        realm    => $realm,
        timeout  => $arguments{timeout},
		ssl_opts => $arguments{verify_ssl}
			? { SSL_verify_mode => SSL_VERIFY_PEER, verify_hostname => 1 }
			: { SSL_verify_mode => SSL_VERIFY_NONE, verify_hostname => 0 }
    );

    next unless $pve->login;
    next unless $pve->check_login_ticket;
    next unless $pve->api_version_check;

    # Here we are connected, quit the loop
    debug "Successfully connected to " . $host . " !\n";

    # skip cluster status checks if we are not in cluster
    if (defined $arguments{singlenode}) {
        debug "Skipping cluster checks (--singlenode passed to command line)\n";

        $connected = 1;
        last;
    }


    # check if node is quorate, if it's not then
    # we are probably on a dead node and data is irrelevant
    my $cstatuses = $pve->get('/cluster/status');
    foreach my $item( @$cstatuses ) {
        next unless $item->{type} eq "node";

        # qdisks are also type "node"
        if ($item->{qdisk} eq "1") {
            debug "Found qdisk $item->{name} in cluster\n";

            $qdisk{id}        = $item->{id};
            $qdisk{name}      = $item->{name};
            $qdisk{estranged} = $item->{estranged}; # boolean value
            $qdisk{cstate}    = $item->{state}; # boolean value
        }
        elsif ($item->{local} eq "1") {
            if ($item->{estranged} eq "0" || $item->{estranged} eq "") {
                 $isClusterMember = 1;
                 debug "Node $item->{ip} is in cluster and seems sane. Using it to query cluster status\n";
            }
            else {
                debug "Node $item->{ip} is estranged ! Skipping it !\n";
            }
        }
    }
    
    if ($isClusterMember) {
        $connected = 1;
        last; # we queried a valid cluster member, quit the loop
    }
}

if (! $connected ) {
    print "Could not connect to any server !";
    exit $status{UNKNOWN};
}

if (defined $arguments{qdisk}) {
    my $statusStr = '';

    if ( defined $qdisk{id} ) {
        $qdisk{status} = $status{OK};

        if ($qdisk{estranged} eq "1") {
            $statusStr .= "Qdisk $qdisk{name} is estranged !\n";
            $qdisk{status} += $status{WARNING};
        }

        if ($qdisk{cstate} eq "0") {
            $statusStr .= "Qdisk $qdisk{name} is in invalid status !\n";
            $qdisk{status} += $status{WARNING};
        }

        print "Qdisk $rstatus{$qdisk{status}}\n$statusStr";
        exit $qdisk{status};
    }
    else {
        print "No qdisk found in cluster !\n";
        exit $status{UNKNOWN};
    }
}

# list all ressources of the cluster
my $objects = $pve->get('/cluster/resources');

debug "Found " . scalar(@$objects) . " objects:\n";

# loop the objects to find our pool definitions
if (defined $arguments{pools}) {
    foreach my $item( @$objects ) {
        next unless (defined $item->{pool});
        # loop the pool array to see if that one is monitored
        foreach my $mpool( @monitoredPools ) {
            next unless ($item->{pool} eq $mpool->{name});

            debug "Found $mpool->{name} in resource list\n";

	    #get pool members
	    my $pool =  $pve->get('/pools/' . $mpool->{name});
	    my $members = $pool->{members};

	    #fill monitored pool members not defined in config already
	    foreach my $member( @$members ) {
	        if ($member->{type} =~ /openvz|lxc/) {
                        unless ( ( grep $_->{name} eq  $member->{name}, @monitoredOpenvz ) || ( $member->{template} eq 1 && defined $arguments{ignoretemp} ) ) {
                            $monitoredOpenvz[scalar(@monitoredOpenvz)] = (
                            {
                                name         => $member->{name},
                                warn_cpu     => $mpool->{warn_cpu},
                                warn_mem     => $mpool->{warn_mem},
                                warn_disk    => $mpool->{warn_disk},
                                crit_cpu     => $mpool->{crit_cpu},
                                crit_mem     => $mpool->{crit_mem},
                                crit_disk    => $mpool->{crit_disk},
                                alive        => undef,
                                curmem       => undef,
                                curdisk      => undef,
                                curcpu       => undef,
                                cpu_status   => $status{OK},
                                mem_status   => $status{OK},
                                disk_status  => $status{OK},
                                status       => $status{UNDEF},
                                uptime       => undef,
                                node         => undef,
		                pool         => $mpool->{name},
                            },);

	                    debug "Loaded container " . $member->{name} . " from pool " . $mpool->{name} . "\n";
	                }
	        }
	        elsif ($member->{type} eq "qemu") {
                        unless ( ( grep $_->{name} eq  $member->{name}, @monitoredQemus) || ( $member->{template} eq 1 && defined $arguments{ignoretemp} ) ) {
		            $monitoredQemus[scalar(@monitoredQemus)] = (
		            {
			        name         => $member->{name},
			        warn_cpu     => $mpool->{warn_cpu},
			        warn_mem     => $mpool->{warn_mem},
			        warn_disk    => $mpool->{warn_disk},
			        crit_cpu     => $mpool->{crit_cpu},
			        crit_mem     => $mpool->{crit_mem},
			        crit_disk    => $mpool->{crit_disk},
			        alive        => undef,
			        curmem       => undef,
			        curdisk      => undef,
			        curcpu       => undef,
			        cpu_status   => $status{OK},
			        mem_status   => $status{OK},
			        disk_status  => $status{OK},
			        status       => $status{UNDEF},
			        uptime       => undef,
			        node         => undef,
			        pool         => $mpool->{name},
		             },);
		 
                             debug "Loaded qemu " . $member->{name} . " from pool " . $mpool->{name} . "\n";
		        }
	        }
	        elsif ($member->{type} eq "storage") {
	                unless (grep $_->{name} eq  $member->{storage}, @monitoredStorages) {
			     $monitoredStorages[scalar(@monitoredStorages)] = ({
			         name         => $member->{storage},
			         node         => $member->{node},
			         warn_disk    => $mpool->{warn_disk},
			         crit_disk    => $mpool->{crit_disk},
			         curdisk      => undef,
			         disk_status  => $status{OK},
			         status       => $status{UNDEF},
			         pool         => $mpool->{name},
		             },);

		             debug "Loaded storage " . $member->{storage} . " from pool " . $mpool->{name} . "\n";
		         }
	        }
            }
        }
    }
}

# loop the objects to compare our definitions with the current state of the cluster
foreach my $item( @$objects ) {
    if ($item->{type} eq "node") {
            # loop the node array to see if that one is monitored
            foreach my $mnode( @monitoredNodes ) {
                next unless ($item->{node} eq $mnode->{name});

                debug "Found $mnode->{name} in resource list\n";

                # if a node is down, many values are not set
                if(defined $item->{uptime}) {
                    $mnode->{status} = $status{OK};
                    $mnode->{uptime} = $item->{uptime};
                    $mnode->{maxmem} = $item->{maxmem};
                    $mnode->{maxcpu} = $item->{maxcpu};

                    if ($item->{maxmem} > 0) {
                        my $curMem = $item->{mem} / $item->{maxmem} * 100;
                        $mnode->{curmem}  = sprintf("%.2f", $curMem);
                    }

                    if ($item->{maxdisk} > 0) {
                        my $curDisk = $item->{disk} / $item->{maxdisk} * 100;
                        $mnode->{curdisk} = sprintf("%.2f", $curDisk);
                    }

                    if ($item->{maxcpu} > 0) {
                        my $curCpu = $item->{cpu} / $item->{maxcpu} * 100;
                        $mnode->{curcpu}  = sprintf("%.2f", $curCpu);
                    }
                }
                else {
                    $mnode->{status}  = $status{UNDEF};
                    $mnode->{uptime}  = 0;
                    $mnode->{curmem}  = 0;
                    $mnode->{curdisk} = 0;
                    $mnode->{curcpu}  = 0;
                }

                last;
            }
        }
        elsif ($item->{type} eq "storage") {
            foreach my $mstorage( @monitoredStorages ) {
                next unless ($item->{storage} eq $mstorage->{name});
                next unless ($item->{node} eq $mstorage->{node});

                debug "Found $mstorage->{name} in resource list\n";

                if (defined $item->{disk} ) {
                    $mstorage->{status} = $status{OK};

                    if ($item->{maxdisk} > 0) {
                        my $curDisk = $item->{disk} / $item->{maxdisk} * 100;
                        $mstorage->{curdisk} = sprintf("%.2f", $curDisk);
                    }
                }
                else {
                    $mstorage->{status}  = $status{UNDEF};
                    $mstorage->{curdisk} = 0;
                }

                last;
            }

            next;
        }
        elsif ($item->{type} =~ /openvz|lxc/) {
            #loop monitored nodes to increase mem_hi_limit
            foreach my $mnode( @monitoredNodes ) {
                next unless $mnode->{name} eq $item->{node};

                if (defined $item->{status}) {
                    if ($item->{status} eq "running") {
                        $mnode->{mem_alloc} += $item->{maxmem};
                        $mnode->{cpu_alloc} += $item->{maxcpu};
                    }
                }

                last;
            }

            foreach my $mopenvz( @monitoredOpenvz ) {
                next unless ($item->{name} eq $mopenvz->{name});

                debug "Found $mopenvz->{name} in resource list\n";

                if (defined $item->{status}) {
                    $mopenvz->{status}  = $status{OK};
                    $mopenvz->{alive}   = $item->{status};
                    $mopenvz->{uptime}  = $item->{uptime};
                    $mopenvz->{node}    = $item->{node};

                    if ($item->{maxmem} > 0) {
                        my $curMem = $item->{mem} / $item->{maxmem} * 100;
                        $mopenvz->{curmem} = sprintf("%.2f", $curMem);
                    }

                    if ($item->{maxdisk} > 0) {
                        my $curDisk = $item->{disk} / $item->{maxdisk} * 100;
                        $mopenvz->{curdisk} = sprintf("%.2f", $curDisk);
                    }

                    if ($item->{maxcpu} > 0) {
                        my $curCpu = $item->{cpu} / $item->{maxcpu} * 100;
                        $mopenvz->{curcpu} = sprintf("%.2f", $curCpu);
                    }
                }
                else {
                    $mopenvz->{alive}   = "on dead node";
                    $mopenvz->{uptime}  = 0;
                    $mopenvz->{curmem}  = 0;
                    $mopenvz->{curdisk} = 0;
                    $mopenvz->{curcpu}  = 0;
                }

                last;
            }
            next;
        }
        elsif ($item->{type} eq "qemu") {
            #loop monitored nodes to increase mem_hi_limit
            foreach my $mnode( @monitoredNodes ) {
                next unless $mnode->{name} eq $item->{node};

                if (defined $item->{status}) {
                    if ($item->{status} eq "running") {
                         $mnode->{mem_alloc} += $item->{maxmem};
                         $mnode->{cpu_alloc} += $item->{maxcpu};
                    }
                }

                last;
            } 

            foreach my $mqemu( @monitoredQemus ) {
                next unless ($item->{name} eq $mqemu->{name});

                debug "Found $mqemu->{name} in resource list\n";

                if(defined $item->{status}) {
                    $mqemu->{status}  = $status{OK};
                    $mqemu->{alive}   = $item->{status};
                    $mqemu->{uptime}  = $item->{uptime};
                    $mqemu->{node}    = $item->{node};

                    if ($item->{maxmem} > 0) {
                        my $maxMem = $item->{mem} / $item->{maxmem} * 100;
                        $mqemu->{curmem}  = sprintf("%.2f", $maxMem);
                    }

                    if ($item->{maxdisk}) {
                        my $curDisk = $item->{disk} / $item->{maxdisk} * 100;
                        $mqemu->{curdisk} = sprintf("%.2f", $curDisk);
                    }

                    if ($item->{maxcpu} > 0) {
                        my $curCpu = $item->{cpu} / $item->{maxcpu} * 100;
                        $mqemu->{curcpu}  = sprintf("%.2f", $curCpu);
                    }
                }
                else {
                    $mqemu->{alive}   = "on dead node";
                    $mqemu->{uptime}  = 0;
                    $mqemu->{curmem}  = 0;
                    $mqemu->{curdisk} = 0;
                    $mqemu->{curcpu}  = 0;
                }

                last;
            }

            next;
        }
}

# Finally, loop the monitored objects arrays to report situation
my $totalScore = 0;
my $totalPerfData = "|";
if (defined $arguments{nodes}) {
    my $statusScore = 0;
    my $workingNodes = 0;

    my $reportSummary = '';

    foreach my $mnode( @monitoredNodes ) {
        $statusScore = max_status($statusScore, $mnode->{status});

        if ($mnode->{status} ne $status{UNDEF}) {
            # compute max memory usage
            my $memAlloc = 0;
            $memAlloc = sprintf("%.2f", $mnode->{mem_alloc} / $mnode->{maxmem} * 100)
              if ($mnode->{maxmem} > 0);

            my $cpuAlloc = 0;
            $cpuAlloc = sprintf("%.2f", $mnode->{cpu_alloc} / $mnode->{maxcpu} * 100)
              if ($mnode->{maxcpu} > 0);

            evaluate_threshold($mnode, 'mem_alloc', $memAlloc);
            evaluate_threshold($mnode, 'cpu_alloc', $cpuAlloc);
            evaluate_threshold($mnode, 'mem',       $mnode->{curmem});
            evaluate_threshold($mnode, 'disk',      $mnode->{curdisk});
            evaluate_threshold($mnode, 'cpu',       $mnode->{curcpu});

            my $curNodeStatus = max_status(
                $mnode->{cpu_status},
                $mnode->{mem_status},
                $mnode->{disk_status},
                $mnode->{cpu_alloc_status},
                $mnode->{mem_alloc_status},
            );

            if ($mnode->{status} ne $status{UNDEF}) {
                $reportSummary .= 
                    "$mnode->{name} $rstatus{$curNodeStatus} : " .
                    "cpu $rstatus{$mnode->{cpu_status}} ($mnode->{curcpu}%), " . 
                    "mem $rstatus{$mnode->{mem_status}} ($mnode->{curmem}%), " . 
                    "disk $rstatus{$mnode->{disk_status}} ($mnode->{curdisk}%) " .
                    "cpu alloc $rstatus{$mnode->{cpu_alloc_status}} ($cpuAlloc%), " .
                    "mem alloc $rstatus{$mnode->{mem_alloc_status}} ($memAlloc%), " .
                    "uptime $mnode->{uptime}" . $br;

                $workingNodes++
                  if $mnode->{status} eq $status{OK};
            }
            else {
                $reportSummary .= "$mnode->{name} $rstatus{$status{CRITICAL}} : ".
                                  "node is out of cluster (dead?)" . $br;
            }

            $statusScore = max_status($statusScore, $curNodeStatus);
        }
        else {
            $reportSummary .= "$mnode->{name} " .
                              "is in status $rstatus{$status{UNKNOWN}}" . $br;
            $statusScore = max_status($statusScore, $status{UNKNOWN});
        }
    }

    print "NODES $rstatus{$statusScore}  $workingNodes / " .
          scalar(@monitoredNodes) . " working nodes" . $br . $reportSummary;

     $totalScore = max_status($totalScore, $statusScore);
}; if (defined $arguments{storages}) {
    my $statusScore = 0;
    my $workingStorages = 0;

    my $reportSummary = '';
    my $perfData = '';

    foreach my $mstorage( @monitoredStorages ) {
        #Add pool name to output
	#$mstorage->{name} .= "/" . $mstorage->{pool} if defined $mstorage->{pool};

        if ($mstorage->{status} eq $status{UNDEF}) {
            $statusScore = max_status($statusScore, $status{CRITICAL});

            $reportSummary .= "$mstorage->{name} ($mstorage->{node}) " .
                              "$rstatus{$status{CRITICAL}}: " .
                              "storage is on a dead node" . $br;
        }
        elsif ($mstorage->{status} ne $status{UNKNOWN}) {
            evaluate_threshold($mstorage, 'disk', $mstorage->{curdisk});

            $reportSummary .= "$mstorage->{name} ($mstorage->{node}) " .
                              "$rstatus{$mstorage->{status}} : " .
                              "disk $mstorage->{curdisk}%" . $br;
            $perfData .= "$mstorage->{name}-$mstorage->{node}::check_pve_storage::" .
                              "disk=$mstorage->{curdisk}%;$mstorage->{warn_disk};$mstorage->{crit_disk} ";

            $workingStorages++;

	    $statusScore = max_status($statusScore, $mstorage->{disk_status});
        }
        else {
            $reportSummary .= "$mstorage->{name} " .
                              "is in status $rstatus{$status{UNKNOWN}}" . $br;
            $statusScore = max_status($statusScore, $status{UNKNOWN});
        }
    }

    print "STORAGE $rstatus{$statusScore} $workingStorages / " .
          scalar(@monitoredStorages) . " working storages" . $br . $reportSummary;
    $totalPerfData .= "STORAGE::check_pve_storages::storages=$workingStorages;;;0;" . scalar(@monitoredStorages) . " " . $perfData;

     $totalScore = max_status($totalScore, $statusScore);
}; if (defined $arguments{openvz}) {
    my $statusScore = 0;
    my $workingVms = 0;

    my $reportSummary = '';
    my $perfData = '';

    foreach my $mopenvz( @monitoredOpenvz ) {
        #Add pool name to output
	#$mopenvz->{name} .= "/" . $mopenvz->{pool} if defined $mopenvz->{pool};

        if ($mopenvz->{status} ne $status{UNDEF}) {
            evaluate_threshold($mopenvz, 'mem',  $mopenvz->{curmem});
            evaluate_threshold($mopenvz, 'disk', $mopenvz->{curdisk});
            evaluate_threshold($mopenvz, 'cpu',  $mopenvz->{curcpu});

            if (defined $mopenvz->{alive}) {
                if ($mopenvz->{alive} eq "running") {
                     $mopenvz->{status} = $status{OK};
                     $workingVms++;

                     $reportSummary .=
                         "$mopenvz->{name} ($mopenvz->{node}) " .
                         "$rstatus{$mopenvz->{status}} : " .
                         "cpu $rstatus{$mopenvz->{cpu_status}} ($mopenvz->{curcpu}%), " .
                         "mem $rstatus{$mopenvz->{mem_status}} ($mopenvz->{curmem}%), " .
                         "disk $rstatus{$mopenvz->{disk_status}} ($mopenvz->{curdisk}%) " .
                         "uptime $mopenvz->{uptime}" . $br;
                     $perfData .=
                         "$mopenvz->{name}::check_pve_openvz::" .
                         "cpu=$mopenvz->{curcpu}%;$mopenvz->{warn_cpu};$mopenvz->{crit_cpu} " .
                         "mem=$mopenvz->{curmem}%;$mopenvz->{warn_mem};$mopenvz->{crit_mem} ";
                }
                else {
                    $mopenvz->{status} = $status{CRITICAL};
                    $statusScore = max_status($statusScore, $status{CRITICAL});

                    $reportSummary .= "$mopenvz->{name} " .
                        "$rstatus{$mopenvz->{status}} : " .
                        "VM is $mopenvz->{alive}" . $br;
                }
            }

            $statusScore = max_status(
                $statusScore,
                $mopenvz->{cpu_status},
                $mopenvz->{mem_status},
                $mopenvz->{disk_status},
            );
        }
        else {
            $reportSummary .= "$mopenvz->{name} " .
                              "is in status $rstatus{$status{UNKNOWN}}" . $br;
            $statusScore = max_status($statusScore, $status{UNKNOWN});
        }
    }

    print "OPENVZ $rstatus{$statusScore} $workingVms / " .
          scalar(@monitoredOpenvz) . " working VMs" . $br . $reportSummary;
    $totalPerfData .= "OPENVZ::check_pve_vms::vmcount=$workingVms;;;0;" . scalar(@monitoredOpenvz) . " " . $perfData;

     $totalScore = max_status($totalScore, $statusScore);
}; if (defined $arguments{qemu}) {
    my $statusScore = 0;
    my $workingVms = 0;

    my $reportSummary = '';
    my $perfData = '';

    foreach my $mqemu( @monitoredQemus ) {
	#Add pool name to output
	#$mqemu->{name} .= "/" . $mqemu->{pool} if defined $mqemu->{pool};

        if ($mqemu->{status} ne $status{UNDEF}) {
            evaluate_threshold($mqemu, 'mem',  $mqemu->{curmem});
            evaluate_threshold($mqemu, 'disk', $mqemu->{curdisk});
            evaluate_threshold($mqemu, 'cpu',  $mqemu->{curcpu});

            if (defined $mqemu->{alive}) {
                if ($mqemu->{alive} eq "running") {
                    $mqemu->{status} = $status{OK};
                    $workingVms++;

                    $reportSummary .=
                        "$mqemu->{name} ($mqemu->{node}) $rstatus{$mqemu->{status}} : " .
                        "cpu $rstatus{$mqemu->{cpu_status}} ($mqemu->{curcpu}%), " .
                        "mem $rstatus{$mqemu->{mem_status}} ($mqemu->{curmem}%), " .
                        "disk $rstatus{$mqemu->{disk_status}} ($mqemu->{curdisk}%) " .
                        "uptime $mqemu->{uptime}" . $br;
                    $perfData .=
                        "$mqemu->{name}::check_pve_qemu::" .
                        "cpu=$mqemu->{curcpu}%;$mqemu->{warn_cpu};$mqemu->{crit_cpu} " .
                        "mem=$mqemu->{curmem}%;$mqemu->{warn_mem};$mqemu->{crit_mem} ";
                }
                else {
                    $mqemu->{status} = $status{CRITICAL};
                    $reportSummary .= "$mqemu->{name} $rstatus{$mqemu->{status}} : " .
                                      "VM is $mqemu->{alive}" . $br;
                    $statusScore = max_status($statusScore, $status{CRITICAL});
                }
            }

            $statusScore = max_status(
                $statusScore,
                $mqemu->{cpu_status},
                $mqemu->{mem_status},
                $mqemu->{disk_status},
            );
        }
        else {
            $reportSummary .= "$mqemu->{name} " .
                              "is in status $rstatus{$status{UNKNOWN}}" . $br;
            $statusScore = max_status($statusScore, $status{UNKNOWN});
        }
    }

    print "QEMU $rstatus{$statusScore} $workingVms / " .
          scalar(@monitoredQemus) . " working VMs" . $br .
          $reportSummary;
    $totalPerfData .= "QEMU::check_pve_vms::vmcount=$workingVms;;;0;" . scalar(@monitoredQemus) . " " . $perfData;

     $totalScore = max_status($totalScore, $statusScore);
}; if (not defined $arguments{qemu} and not defined $arguments{openvz} and not defined $arguments{storages} and not defined $arguments{nodes}) {
    usage();
    exit $status{UNKNOWN};
}

print $totalPerfData
   if (defined $arguments{perfdata} and $totalPerfData ne "|");
exit $totalScore;
