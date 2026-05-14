#!/usr/bin/perl

#####################################################
#
#    Proxmox VE cluster monitoring tool
#
#####################################################
#
#   Requires Net::Proxmox::VE from CPAN
#     https://metacpan.org/pod/Net::Proxmox::VE
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
use JSON ();

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
    'dry_run'        => undef,
    'json'           => undef,
    'ceph'           => undef,
    'subscriptions'  => undef,
    'sub_warn_days'  => 30,
    'sub_crit_days'  => 7,
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
    print "  --ceph\n";
    print "    Check the state of the cluster's Ceph deployment (HEALTH_OK/WARN/ERR)\n";
    print "  --subscriptions\n";
    print "    Check each node's PVE subscription validity and days-until-expiry\n";
    print "  --sub-warn-days N (default 30)\n";
    print "  --sub-crit-days N (default 7)\n";
    print "    WARNING/CRITICAL thresholds in days for --subscriptions\n";
    print "  --singlenode\n";
    print "    Consider there is no cluster, just a single node\n";
    print "  --verify-ssl\n";
    print "    Verify the PVE node's TLS certificate (default: disabled for self-signed certs)\n";
    print "  --check <list>\n";
    print "    Comma-separated list of checks (alias for the per-mode flags above).\n";
    print "    Example: --check nodes,storages,qemu,containers\n";
    print "  --dry-run\n";
    print "    Parse the config and exit OK; useful for CI/syntax-check workflows\n";
    print "  --json\n";
    print "    Emit results as a JSON document on STDOUT instead of the Nagios summary\n";
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
            "dry-run"     => \$arguments{dry_run},
            "json"        => \$arguments{json},
            "ceph"        => \$arguments{ceph},
            "subscriptions" => \$arguments{subscriptions},
            "sub-warn-days=i" => \$arguments{sub_warn_days},
            "sub-crit-days=i" => \$arguments{sub_crit_days},
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
        qdisk          => 'qdisk',
        ceph           => 'ceph',
        subscriptions  => 'subscriptions',
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
my $cfg_fh;
if (! open $cfg_fh, "<", "$arguments{conf}") {
    debug "$!\n";
    print "Cannot load configuration file $arguments{conf} !\n";
    exit $status{UNKNOWN};
}

while ( <$cfg_fh> ) {
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
                 my $nTokenId     = undef;
                 my $nTokenSecret = undef;
                 my $nRealm       = 'pam';
                 my $warnMemAlloc = undef;
                 my $critMemAlloc = undef;
                 my $warnCpuAlloc = undef;
                 my $critCpuAlloc = undef;

                 $readingObject = 1;

                 while (<$cfg_fh>) {
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
                                 close($cfg_fh);
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
                                 close($cfg_fh);
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
                                 close($cfg_fh);
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
                                 close($cfg_fh);
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
                                 close($cfg_fh);
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
                                 close($cfg_fh);
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
                         elsif ($token eq "monitor_token_id") {
                             $nTokenId = $2;
                         }
                         elsif ($token eq "monitor_token_secret") {
                             $nTokenSecret = $2;
                         }
                         elsif ($token eq "realm") {
                             $nRealm = $2;
                         }
                         else {
                             close($cfg_fh);
                             print "Invalid token $token in $name definition !\n";
                             exit $status{UNKNOWN};
                         }
                     }
                     elsif ( $objLine =~ m/\}/i ) {
                         # check object requirements are met, save it, break
                         if (! defined $name ) {
                             close($cfg_fh);
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
                                 token_id         => $nTokenId,
                                 token_secret     => $nTokenSecret,
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

                 while (<$cfg_fh>) {
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
                                 close($cfg_fh);
                                 print "Invalid DISK declaration " .
                                       "in $name definition\n";
                                 exit $status{UNKNOWN};
                             }
                         }
                         elsif ($token eq "node") {
                             $node = $2;
                         }
                         else {
                             close($cfg_fh);
                             print "Invalid token $token " .
                                   "in $name definition !\n";
                             exit $status{UNKNOWN};
                         }
                     }
                     elsif ( $objLine =~ m/\}/i ) {
                         # check object requirements are met, save it, break
                         if (! defined $name ) {
                             close($cfg_fh);
                             print "Invalid configuration !";
                             exit $status{UNKNOWN};
                         }

                         if (! defined $node ) {
                             close($cfg_fh);
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

                 while (<$cfg_fh>) {
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
                                 close($cfg_fh);
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
                                 close($cfg_fh);
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
                                 close($cfg_fh);
                                 print "Invalid DISK declaration " .
                                       "in $name definition\n";
                                 exit $status{UNKNOWN};
                             }
                         }
                         else {
                             close($cfg_fh);
                             print "Invalid token $token " .
                                   "in $name definition !\n";
                             exit $status{UNKNOWN};
                         }
                     }
                     elsif ( $objLine =~ m/\}/i ) {
                         # check object requirements are met, save it, break
                         if (! defined $name ) {
                             close($cfg_fh);
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

                 while (<$cfg_fh>) {
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
                                 close($cfg_fh);
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
                                 close($cfg_fh);
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
                                 close($cfg_fh);
                                 print "Invalid DISK declaration " .
                                       "in $name definition\n";
                                 exit $status{UNKNOWN};
                             }
                         }
                         else {
                             close($cfg_fh);
                             print "Invalid token $token " .
                                   "in $name definition !\n";
                             exit $status{UNKNOWN};
                         }
                     }
                     elsif ( $objLine =~ m/\}/i ) {
                         # check object requirements are met, save it, break
                         if (! defined $name ) {
                             close($cfg_fh);
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

                 while (<$cfg_fh>) {
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
                                 close($cfg_fh);
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
                                 close($cfg_fh);
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
                                 close($cfg_fh);
                                 print "Invalid DISK declaration " .
                                       "in $name definition\n";
                                 exit $status{UNKNOWN};
                             }
                         }
                         else {
                             close($cfg_fh);
                             print "Invalid token $token " .
                                   "in $name definition !\n";
                             exit $status{UNKNOWN};
                         }
                     }
                     elsif ( $objLine =~ m/\}/i ) {
                         # check object requirements are met, save it, break
                         if (! defined $name ) {
                             close($cfg_fh);
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
             close($cfg_fh);
             print "Invalid token $blockType " .
                   "in configuration file $arguments{conf} !\n";
             exit $status{UNKNOWN};
         }
    }
}

close($cfg_fh);

if ( $readingObject ) {
    print "Invalid configuration ! (Probably missing '}' ) \n";
    exit $status{UNKNOWN};
}

if (defined $arguments{dry_run}) {
    printf "OK config valid: %d nodes, %d storages, %d containers, %d qemu, %d pools\n",
        scalar(@monitoredNodes), scalar(@monitoredStorages),
        scalar(@monitoredOpenvz), scalar(@monitoredQemus),
        scalar(@monitoredPools);
    exit $status{OK};
}

# Probe nodes in randomized order so a dead node at the head of the config
# doesn't make every check pay its connect-timeout cost.
my @probeOrder = sort { rand() <=> rand() } 0 .. $#monitoredNodes;
for my $a (@probeOrder) {
    my $host     = $monitoredNodes[$a]->{address}  or next;
    my $port     = $monitoredNodes[$a]->{port}     or next;
    my $username = $monitoredNodes[$a]->{username} or next;
    my $realm    = $monitoredNodes[$a]->{realm}    or next;

    my $password     = $monitoredNodes[$a]->{password};
    my $tokenId      = $monitoredNodes[$a]->{token_id};
    my $tokenSecret  = $monitoredNodes[$a]->{token_secret};

    # Require either a password or a complete token pair.
    unless ((defined $password) || (defined $tokenId && defined $tokenSecret)) {
        debug "Skipping $host: no password and no token_id+token_secret configured\n";
        next;
    }

    my $isClusterMember = 0;

    debug "Trying " . $host . "...\n";

    my %pve_args = (
        host     => $host,
        port     => $port,
        username => $username,
        debug    => $arguments{debug},
        realm    => $realm,
        timeout  => $arguments{timeout},
        ssl_opts => $arguments{verify_ssl}
            ? { SSL_verify_mode => SSL_VERIFY_PEER, verify_hostname => 1 }
            : { SSL_verify_mode => SSL_VERIFY_NONE, verify_hostname => 0 },
    );
    if (defined $tokenId && defined $tokenSecret) {
        $pve_args{tokenid} = $tokenId;
        $pve_args{secret}  = $tokenSecret;
    }
    else {
        $pve_args{password} = $password;
    }
    $pve = Net::Proxmox::VE->new(%pve_args);

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
    if ($arguments{json}) {
        print JSON->new->canonical->pretty->encode({
            status    => $rstatus{$status{UNKNOWN}},
            exit_code => 0 + $status{UNKNOWN},
            plugin    => 'pve-monitor',
            version   => $pluginVersion,
            error     => 'Could not connect to any server',
        });
    }
    else {
        print "Could not connect to any server !";
    }
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

# Guard against an empty / undef response (e.g. a node that returned 200
# with no body, or a stub PVE that doesn't expose this endpoint). The
# pre-fix behavior was a hard die at the next dereference. Treat it the
# same as 'no resources found' so the per-mode reporting blocks fall to
# their own UNKNOWN paths and the operator gets a useful diagnostic.
if (!defined $objects || ref($objects) ne 'ARRAY') {
    debug "Got no/invalid response from /cluster/resources\n";
    $objects = [];
}

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
          scalar(@monitoredNodes) . " working nodes" . $br . $reportSummary
        unless $arguments{json};

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
          scalar(@monitoredStorages) . " working storages" . $br . $reportSummary
        unless $arguments{json};
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
          scalar(@monitoredOpenvz) . " working VMs" . $br . $reportSummary
        unless $arguments{json};
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
          $reportSummary
        unless $arguments{json};
    $totalPerfData .= "QEMU::check_pve_vms::vmcount=$workingVms;;;0;" . scalar(@monitoredQemus) . " " . $perfData;

     $totalScore = max_status($totalScore, $statusScore);
}

my %cephReport;
if (defined $arguments{ceph}) {
    my $statusScore = $status{OK};
    my $reportSummary = '';
    my $cephStatus;

    # /cluster/ceph/status returns a hash whose 'health' sub-hash carries
    # 'status' = HEALTH_OK | HEALTH_WARN | HEALTH_ERR (plus 'checks' detail).
    eval { $cephStatus = $pve->get('/cluster/ceph/status'); 1 }
      or do { debug "ceph: API call failed: $@\n" };

    if (!defined $cephStatus || ref($cephStatus) ne 'HASH') {
        $statusScore = $status{UNKNOWN};
        $reportSummary = "Ceph status unavailable (cluster has no Ceph or API call failed)";
    }
    else {
        my $health = (ref($cephStatus->{health}) eq 'HASH')
            ? $cephStatus->{health}->{status}
            : undef;
        $health = '' unless defined $health;

        if ($health eq 'HEALTH_OK') {
            $statusScore = $status{OK};
            $reportSummary = "Ceph HEALTH_OK";
        }
        elsif ($health eq 'HEALTH_WARN') {
            $statusScore = $status{WARNING};
            $reportSummary = "Ceph HEALTH_WARN";
        }
        elsif ($health eq 'HEALTH_ERR') {
            $statusScore = $status{CRITICAL};
            $reportSummary = "Ceph HEALTH_ERR";
        }
        else {
            $statusScore = $status{UNKNOWN};
            $reportSummary = "Ceph health unknown ('$health')";
        }

        # Append per-check details (PVE 6+ reports checks as a hash keyed by check id).
        if (ref($cephStatus->{health}->{checks}) eq 'HASH') {
            for my $check_id (sort keys %{$cephStatus->{health}->{checks}}) {
                my $c = $cephStatus->{health}->{checks}->{$check_id};
                my $summary = (ref($c->{summary}) eq 'HASH' && defined $c->{summary}->{message})
                    ? $c->{summary}->{message}
                    : '';
                $reportSummary .= $br . "  [$check_id] $summary";
            }
        }
    }

    %cephReport = (status => $rstatus{$statusScore}, detail => $reportSummary);
    print "CEPH $rstatus{$statusScore} : $reportSummary" . $br
        unless $arguments{json};
    $totalScore = max_status($totalScore, $statusScore);
}

my @subscriptionReport;
if (defined $arguments{subscriptions}) {
    my $statusScore = $status{OK};
    my $reportSummary = '';

    for my $mnode (@monitoredNodes) {
        my $nname = $mnode->{name};
        my $sub;
        eval { $sub = $pve->get("/nodes/$nname/subscription"); 1 }
          or do { debug "subscription[$nname]: $@\n" };

        if (!defined $sub || ref($sub) ne 'HASH') {
            $statusScore = max_status($statusScore, $status{UNKNOWN});
            $reportSummary .= "$nname: subscription unavailable" . $br;
            push @subscriptionReport,
                { node => $nname, status => $rstatus{$status{UNKNOWN}} };
            next;
        }

        my $sub_status = $sub->{status} // '';   # 'active' | 'notfound' | 'expired' | ...
        my $due        = $sub->{nextduedate};    # YYYY-MM-DD when present
        my $days_left;

        if (defined $due && $due =~ /^(\d{4})-(\d{2})-(\d{2})/) {
            # Plain integer day arithmetic — avoids dragging in Time::Piece for 5.14 compat.
            my ($y, $m, $d) = ($1, $2, $3);
            my @months = (31,28,31,30,31,30,31,31,30,31,30,31);
            my $leap = ($y % 4 == 0 && ($y % 100 != 0 || $y % 400 == 0)) ? 1 : 0;
            $months[1] += $leap;
            my $due_days = $y * 365 + int($y/4) - int($y/100) + int($y/400);
            if ($m > 1) { $due_days += $_ for @months[0 .. $m - 2] }
            $due_days += $d;

            my (undef, undef, undef, $cd, $cm, $cy) = localtime();
            $cm += 1; $cy += 1900;
            my @cm_arr = (31,28,31,30,31,30,31,31,30,31,30,31);
            $cm_arr[1] += (($cy % 4 == 0 && ($cy % 100 != 0 || $cy % 400 == 0)) ? 1 : 0);
            my $cur_days = $cy * 365 + int($cy/4) - int($cy/100) + int($cy/400);
            if ($cm > 1) { $cur_days += $_ for @cm_arr[0 .. $cm - 2] }
            $cur_days += $cd;

            $days_left = $due_days - $cur_days;
        }

        my $node_score;
        if ($sub_status ne 'active') {
            $node_score = $status{CRITICAL};
            $reportSummary .= "$nname: subscription is '$sub_status'" . $br;
        }
        elsif (defined $days_left && $days_left <= $arguments{sub_crit_days}) {
            $node_score = $status{CRITICAL};
            $reportSummary .= "$nname: $days_left days until expiry" . $br;
        }
        elsif (defined $days_left && $days_left <= $arguments{sub_warn_days}) {
            $node_score = $status{WARNING};
            $reportSummary .= "$nname: $days_left days until expiry" . $br;
        }
        else {
            $node_score = $status{OK};
            my $detail = defined $days_left ? "$days_left days until expiry" : 'active';
            $reportSummary .= "$nname: $detail" . $br;
        }

        $statusScore = max_status($statusScore, $node_score);
        push @subscriptionReport, {
            node       => $nname,
            sub_status => $sub_status,
            nextduedate => $due,
            days_left  => $days_left,
            status     => $rstatus{$node_score},
        };
    }

    print "SUBSCRIPTIONS $rstatus{$statusScore}" . $br . $reportSummary
        unless $arguments{json};
    $totalScore = max_status($totalScore, $statusScore);
}

if (not defined $arguments{qemu} and not defined $arguments{openvz} and not defined $arguments{storages} and not defined $arguments{nodes} and not defined $arguments{ceph} and not defined $arguments{subscriptions}) {
    usage();
    exit $status{UNKNOWN};
}

if ($arguments{json}) {
    # Build a stable, structured payload reflecting the same data the
    # Nagios-style printer would emit. Each section is only present if its
    # corresponding --<mode> was requested.
    my %payload = (
        status      => $rstatus{$totalScore},
        exit_code   => 0 + $totalScore,
        plugin      => 'pve-monitor',
        version     => $pluginVersion,
    );
    # Strip credentials before serializing the per-node array. password /
    # token_id / token_secret are config-side inputs the script never
    # needs to emit, and the JSON payload typically lands in the Icinga2
    # stdout stream (and from there in the IDO database / web UI), so
    # leaking them is the canonical foot-gun. t/13-debug-redaction.t
    # regression-guards this.
    my @nodes_safe = map {
        my %copy = %$_;
        delete @copy{qw(password token_id token_secret)};
        \%copy;
    } @monitoredNodes;
    $payload{nodes}      = \@nodes_safe        if defined $arguments{nodes};
    $payload{storages}   = \@monitoredStorages if defined $arguments{storages};
    $payload{containers} = \@monitoredOpenvz   if defined $arguments{openvz};
    $payload{qemu}       = \@monitoredQemus    if defined $arguments{qemu};
    $payload{ceph}       = \%cephReport        if defined $arguments{ceph};
    $payload{subscriptions} = \@subscriptionReport if defined $arguments{subscriptions};

    print JSON->new->canonical->pretty->encode(\%payload);
}
else {
    print $totalPerfData
        if (defined $arguments{perfdata} and $totalPerfData ne "|");
}
exit $totalScore;

__END__

=pod

=head1 NAME

pve-monitor.pl - Nagios/Icinga2 plugin for monitoring Proxmox VE clusters

=head1 SYNOPSIS

  pve-monitor.pl --conf FILE [--nodes] [--storages] [--qemu] [--containers]
                 [--ceph] [--subscriptions] [--qdisk] [--pools NAME|All]
                 [--check LIST] [--singlenode] [--verify-ssl]
                 [--ignoretemp] [--perfdata] [--html] [--json]
                 [--dry-run] [--timeout N] [--debug]

  pve-monitor.pl --help
  pve-monitor.pl --version

=head1 DESCRIPTION

C<pve-monitor.pl> is a single-file Perl Nagios plugin that monitors a
Proxmox VE cluster via the PVE API. It does not install software on
the monitored hosts; it authenticates to one cluster member and reads
state from C</cluster/resources>, C</cluster/status>, and (depending
on the requested checks) C</cluster/ceph/status> and
C</nodes/E<lt>nE<gt>/subscription>.

Exit codes follow the Nagios convention: C<0> OK, C<1> WARNING,
C<2> CRITICAL, C<3> UNKNOWN. When multiple checks are requested in
a single invocation, the overall exit code is the most severe of the
individual checks (Nagios "max severity wins").

=head1 OPTIONS

=head2 What to check

=over 4

=item B<--nodes>

Check the cluster's member nodes (CPU / memory / disk usage, plus
over-allocation of CPU and memory by the VMs running on each node).

=item B<--storages>

Check disk usage per storage backend.

=item B<--qemu>

Check running state plus CPU / memory / disk usage of QEMU VMs.

=item B<--containers>

Check running state plus CPU / memory / disk usage of LXC (and
legacy OpenVZ) containers. C<--openvz> is accepted as an alias.

=item B<--ceph>

Check the cluster's Ceph health. C<HEALTH_OK> maps to OK,
C<HEALTH_WARN> to WARNING, C<HEALTH_ERR> to CRITICAL. Per-check
detail (e.g. C<OSD_NEARFULL>, C<MON_DOWN>) is appended to the
report summary.

=item B<--subscriptions>

Check the PVE subscription status of each node defined in the config.
A non-active status is CRITICAL; an active subscription within
C<--sub-crit-days> of expiry is CRITICAL; within C<--sub-warn-days>
is WARNING.

=item B<--qdisk>

Check the cluster's quorum disk. Mutually exclusive with the
other checks (exits immediately after reporting).

=item B<--pools=NAME|All>

Auto-expand the named pool's members (or every defined pool, with
C<All>) into the corresponding C<--qemu> / C<--containers> /
C<--storages> reports. Thresholds default to the values declared in
the pool's config block.

=item B<--check=LIST>

Comma-separated alias for the per-mode flags above. Example:
C<--check nodes,storages,qemu,containers>.

=back

=head2 Behavior

=over 4

=item B<--conf=FILE>

Path to the plugin's config file. Required for any check.
See L</CONFIGURATION>.

=item B<--singlenode>

Skip the cluster quorum probe. Treat the first reachable host
as authoritative.

=item B<--verify-ssl>

Validate the PVE node's TLS certificate. Default is insecure
(C<SSL_VERIFY_NONE>) because typical Proxmox installs use
self-signed certificates.

=item B<--ignoretemp>

Skip VMs marked as templates when expanding pools.

=item B<--timeout=N>

HTTP timeout per node probe, in seconds. Default 5.

=item B<--sub-warn-days=N> / B<--sub-crit-days=N>

WARNING/CRITICAL thresholds in days for C<--subscriptions>.
Defaults: 30 / 7.

=back

=head2 Output

=over 4

=item B<--perfdata>

Emit Nagios perfdata after the human-readable summary
(PNP4Nagios / check_multi style).

=item B<--html>

Replace newlines with C<E<lt>brE<gt>> in the summary, for monitoring
systems that render HTML.

=item B<--json>

Emit a single JSON document on stdout instead of the Nagios-style
summary. The connection-failure early-exit path also emits JSON.

=item B<--dry-run>

Parse the config and exit OK with a one-line count summary,
without contacting any host.

=item B<--debug>

Verbose trace on STDERR (never mixed into the stdout summary).

=item B<--version>, B<--help>

Print the plugin version (exits OK) or the usage summary
(exits UNKNOWN, per Nagios convention).

=back

=head1 CONFIGURATION

The plugin config is a block-based format. See
F<icinga2/pve-monitor.conf> for a working example.

  node pve01 {
      address              10.0.0.1
      port                 8006             # optional, default 8006
      monitor_account      icinga
      monitor_token_id     icinga-monitor
      monitor_token_secret 12345678-90ab-cdef-...
      realm                pam              # optional, default 'pam'
      mem                  80 90            # WARN  CRIT  percent
      cpu                  80 95
      disk                 80 90
      mem_alloc            90 100
      cpu_alloc            90 100
  }
  storage local { node pve01; disk 80 90 }
  container web01 { mem 80 90; cpu 80 95; disk 80 90 }
  qemu      db01  { mem 80 90; cpu 80 95; disk 80 90 }
  pool      web   { mem 90 95; cpu 90 95; disk 90 95 }

A node block must declare either C<monitor_password>, or both
C<monitor_token_id> and C<monitor_token_secret>. Token authentication
is recommended.

=head1 EXIT CODES

  0  OK         All requested checks passed.
  1  WARNING    At least one check is in WARNING.
  2  CRITICAL   At least one check is in CRITICAL.
  3  UNKNOWN    The plugin could not determine status (e.g. no
                 reachable cluster member, missing config file,
                 parser error).

=head1 SEE ALSO

L<https://github.com/apachler/pve-monitor>,
L<Net::Proxmox::VE>,
L<https://pve.proxmox.com/pve-docs/api-viewer/>

=head1 AUTHORS

Damien Piquet <damien.piquet@iutbeziers.fr>,
Alexey Dvoryanchikov,
Andreas Pachler <https://github.com/apachler>.

=head1 LICENSE

GPL-3.0. See the F<LICENSE> file distributed with this script.

=cut

