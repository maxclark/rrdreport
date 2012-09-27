#!/usr/bin/perl -w

# Default Configuration
# -----
my $mrtgconfig = "/usr/local/etc/mrtg/mrtg.cfg";
my $dbname = "/home/mclark/report/manage.db";
my @interface_types = qw(transit);

# Load necessary perl modules
# --
use Getopt::Long;
use MRTG_lib;
use RRDs;
use Statistics::Descriptive;
use Time::Local;
use DBI;

my $VERSION = "0.1";

# Usage and Help
# -----
sub usage {
	print "\n";
	print "usage: mrtgreport [*options*]\n";
	print "  -h, --help           display this help and exit\n";
	print "      --version        output version information and exit\n";
	print "  -v, --verbose        display debug messages\n";
	print "  -l, --lastmonth      report for the previous month\n";
	print "  -y, --year           select the year in YYYY format\n";
	print "  -m, --month          select the month in MM format\n";
	print "\n";
	exit;
}

my %opt = ();
GetOptions(\%opt,
	'debug|d', 'month|m=s', 'year|y=s', 'lastmonth|l', 'help|h', 'verbose|v', 'version'
	) or exit(1);
usage if $opt{help};

if ($opt{version}) {
	print "report $VERSION by max\@clarksys.com\n";
	exit;
}

$DEBUG = "1" if defined $opt{debug};
$VERBOSE = "1" if defined $opt{verbose};

# Define Base Date Information
# -----
my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime(time);

$mon = --$opt{month} if defined $opt{month};
$year = $opt{year} - 1900 if defined $opt{year};
        
if (defined $opt{lastmonth}) {
	if ($mon == 0) {
		$mon = "11";
		$year--;
	} else {
		$mon--;
	}
}

my $starttime = timegm("0","0","0","1",$mon,$year);

if (defined $opt{month} || defined $opt{lastmonth}) {
	if ($mon == 11) {
		$endtime = timegm("0","0","0","1","0",++$year);
	} else {
		$endtime = timegm("0","0","0","1",++$mon,$year);
	}
} else {
	$endtime = timegm("0",$min,$hour,$mday,$mon,$year);
}

# Override defaults
# -----------------
my $configfile = $opt{config} ? defined $opt{config} : $mrtgconfig;

# Read in the Interfaces from MRTG
# --------------------------------
#exit unless -r "$configfile";
#readcfg($configfile, \@target_names, \%globalcfg, \%targetcfg);

# Connect to the Database
# -----------------------
my $dbh = DBI->connect("DBI:SQLite:dbname=$dbname", "", "") or die "Couldn't connect to database: " . DBI->errstr;

# SQL Queries
# -----------
my $get_interfaces = $dbh->prepare(q(
	select *
	from interfaces
	where type = ? and active = 1
	order by name
	)) || "Couldn't prepare statement: " . $dbh->errstr;

print "\nCurrent Date/Time is: ", scalar gmtime(time());

foreach (@interface_types) {

	print "\n $_ report from: ", scalar localtime($starttime), " to: ", scalar localtime($endtime), "\n\n";
  print "$starttime $endtime\n" if $VERBOSE;
	printf "%30s: %8s %8s %8s %8s\n", Heading, 95, 90, "In (TB)", "Out (TB)";

	$get_interfaces->execute($_);

	while (my ($name, $type, $device, $interface, $start_date, $end_date, $cir, $cir_rate, $overage_rate) = $get_interfaces->fetchrow_array) {

		$int = $device . "_" . $interface;
		print "interface: $int\n" if $DEBUG;

		my ($orig) = calc95($device,$int,$starttime,$endtime);
		my ($new) = calc90($device,$int,$starttime,$endtime);
		my ($inbound,$outbound) = calcBytes($device,$int,$starttime,$endtime);
		print "95th: $orig \t 90th: $new\n" if $DEBUG;

		printf "%30s: %8s %8s %8s %8s\n", $name, scaleBits($orig), scaleBits($new), scaleBytes($inbound), scaleBytes($outbound);
	}

	$get_interfaces->finish;

}

# Disconnect from the Database
# ----------------------------
#$dbh->disconnect;

# ----------
sub calc95 {
	my $device = shift;
	my $interface = shift;
	my $starttime = shift;
	my $lasttime = shift;

	# Subtract five (5) minutes so RRD behaves as desired
	# --
	$rrdstart = $starttime - 300;

	my $rrd = '/usr/local/mrtg/' . $device . '/' . $interface . '.rrd';

#	print "$rrd $starttime $lasttime\n" if $DEBUG;

	$stat = Statistics::Descriptive::Full->new();

	($start,$step,$names,$data) = RRDs::fetch ($rrd,'AVERAGE','-s',$rrdstart,'-e',$lasttime);

	if ($DEBUG) {
		print "RRD Start:   ", scalar localtime($start), " ($start)\n";
		print "Start:       ", scalar localtime($starttime), "\n";
		print "End:         ", scalar localtime($lasttime), "\n";
		print "Step size:   $step seconds\n";
		print "DS names:    ", join (", ", @$names)."\n";
		print "Data points: ", $#$data + 1, "\n";
#		print "Data:\n";
#
#		foreach my $line (@$data) {
#			print "  ", scalar localtime($start), " ($start) ";
#			$start += $step;
#			foreach my $val (@$line) {
#				# Define value if missing
#				# --
#				$val = 0 unless defined $val;
#				printf "%12.1f ", $val;
#			}
#		print "\n";
#		}
	}


	foreach (@$data) {

#		if ($DEBUG) {
#			die "\$_->[0] undefined" unless defined $_->[0];
#			die "\$_->[1] undefined" unless defined $_->[1];
#		}

		# Define values if missing
		# --
		$_->[0] = 0 unless defined $_->[0];
		$_->[1] = 0 unless defined $_->[1];

		#
		# -- Substitute zero for missing samples
		#
		if ($_->[0] eq "" || $_->[1] eq "") {
			$sam = 0;
		} else {
			$sam = $_->[0] >= $_->[1] ? $_->[0] * 8 : $_->[1] * 8;
		}
		$stat->add_data($sam);
	}

	$true = $stat->percentile(95); 

	return ($true);
}
# ==========

# ----------
sub calc90 {
	my $device = shift;
	my $interface = shift;
	my $starttime = shift;
	my $lasttime = shift;

	# Subtract five (5) minutes so RRD behaves as desired
	# --
	$rrdstart = $starttime - 300;

	my $rrd = '/usr/local/mrtg/' . $device . '/' . $interface . '.rrd';

#	print "$rrd $starttime $lasttime\n" if $DEBUG;

	$stat = Statistics::Descriptive::Full->new();

	($start,$step,$names,$data) = RRDs::fetch ($rrd,'AVERAGE','-s',$rrdstart,'-e',$lasttime);

	if ($DEBUG) {
		print "RRD Start:   ", scalar localtime($start), " ($start)\n";
		print "Start:       ", scalar localtime($starttime), "\n";
		print "End:         ", scalar localtime($lasttime), "\n";
		print "Step size:   $step seconds\n";
		print "DS names:    ", join (", ", @$names)."\n";
		print "Data points: ", $#$data + 1, "\n";
#		print "Data:\n";
#
#		foreach my $line (@$data) {
#			print "  ", scalar localtime($start), " ($start) ";
#			$start += $step;
#			foreach my $val (@$line) {
#				# Define value if missing
#				# --
#				$val = 0 unless defined $val;
#				printf "%12.1f ", $val;
#			}
#		print "\n";
#		}
	}


	foreach (@$data) {

#		if ($DEBUG) {
#			die "\$_->[0] undefined" unless defined $_->[0];
#			die "\$_->[1] undefined" unless defined $_->[1];
#		}

		# Define values if missing
		# --
		$_->[0] = 0 unless defined $_->[0];
		$_->[1] = 0 unless defined $_->[1];

		$sam = ($_->[0] + $_->[1]) * 8;

		$stat->add_data($sam);
	}

	$true = $stat->percentile(90); 

	return ($true);
}
# ==========

sub calcBytes {
	my $device = shift;
	my $interface = shift;
	my $starttime = shift;
	my $lasttime = shift;
	
	my $inbound;
	my $outbound;

	# Subtract five (5) minutes so RRD behaves as desired
	# --
	$rrdstart = $starttime - 300;

	my $rrd = '/usr/local/mrtg/' . $device . '/' . $interface . '.rrd';

  print "$rrd $starttime $lasttime\n" if $VERBOSE;

	($start,$step,$names,$data) = RRDs::fetch ($rrd,'AVERAGE','-s',$rrdstart,'-e',$lasttime);

	if ($DEBUG) {
		print "RRD Start:   ", scalar localtime($start), " ($start)\n";
		print "Start:       ", scalar localtime($starttime), "\n";
		print "End:         ", scalar localtime($lasttime), "\n";
		print "Step size:   $step seconds\n";
		print "DS names:    ", join (", ", @$names)."\n";
		print "Data points: ", $#$data + 1, "\n";
#		print "Data:\n";
#
#		foreach my $line (@$data) {
#			print "  ", scalar localtime($start), " ($start) ";
#			$start += $step;
#			foreach my $val (@$line) {
#				# Define value if missing
#				# --
#				$val = 0 unless defined $val;
#				printf "%12.1f ", $val;
#			}
#		print "\n";
#		}
	}


	foreach (@$data) {

#		if ($DEBUG) {
#			die "\$_->[0] undefined" unless defined $_->[0];
#			die "\$_->[1] undefined" unless defined $_->[1];
#		}

		# Define values if missing
		# --
		$_->[0] = 0 unless defined $_->[0];
		$_->[1] = 0 unless defined $_->[1];

		$outbound += ($_->[0] * $step);
		$inbound += ($_->[1] * $step);

	}

	return ($inbound, $outbound);
}
# ==========

# ----------
sub scaleBits {

        my $bits = shift;
        $scale = $bits > 0 ? $bits / 1000000 : 0;   # 1000* 1000 Mbit
        $round = sprintf("%.2f", $scale);
        return $round;

}
# ==========

# ----------
sub scaleBytes {

        my $bytes = shift;
        # my @args = qw(B KB MB GB TB);
        # 
        # while (@args && $bytes > 1024) {
        #   shift @args;
        #   $bytes /= 1024;
        # }
        # 
        # $bytes = sprintf("%.2f",$bytes);
        # 
        # return "$bytes $args[0]";
        
        # $gb = $bytes / 1024 / 1024 / 1024;
        
        # Calculate GB as Barretbyte
        # http://www.blyon.com/tag/barretbyte/
        # 1 TB = 1000 GB
        $gb = $bytes / 1048576000;
        
        $round = sprintf("%.2f", $gb);
        return $round;
}
# ==========