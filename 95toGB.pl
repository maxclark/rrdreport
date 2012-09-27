#!/usr/bin/perl -w

# Default Configuration
# -----
my $mrtgconfig = "/usr/local/etc/mrtg/mrtg-rrd.cfg";
my $dbname = "/home/mclark/rrdreport/manage.db";
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

# Create a formatted date that SQL will understand
# --
$y = $year + 1900;
$m = sprintf ('%02d', $mon + 1);
$d = sprintf ('%02d', 1);

print "$y-$m-$d\n" if $DEBUG;

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
	from interface
	where type = ? and active = 't' and start_date < ?
	order by name
	)) || "Couldn't prepare statement: " . $dbh->errstr;

print "\nCurrent Date/Time is: ", scalar gmtime(time());

foreach (@interface_types) {

	print "\n $_ report from: ", scalar localtime($starttime), " to: ", scalar localtime($endtime), "\n\n";
  print "$starttime $endtime\n" if $VERBOSE;

	printf "%20s %10s %10s %10s %10s %10s %10s\n", Interface, "95th", "GB", "GB/Mb", "Cost", "\$/Mbps", "\$/GB";

	$get_interfaces->execute($_, "$y-$m-$d");

	while (my ($id, $name, $type, $device, $interface, $ccn_rate, $cir, $cir_rate, $overage_rate) = $get_interfaces->fetchrow_array) {

		$int = $device . "_" . $interface;
		print "interface: $int\n" if $DEBUG;

		my ($nth,$gb) = calcTransfer($device,$int,$starttime,$endtime);
		print "nth = $nth \t gb = $gb\n" if $DEBUG;
		
		# Calculate the base cost for the circuit
		# --
		$cost = ($cir * $cir_rate) + $ccn_rate;
		
		print "cost = $cost\n" if $DEBUG;
		
		# Add any usage cost if necessary
		# --
		if ($nth > $cir) {
		  $cost += ($nth - $cir) * $overage_rate;
		}
		
		print "cost = $cost\n" if $DEBUG;

  		printf "%20s %10s %10s %10s %10s %10s %10s\n", $name, $nth, $gb, sprintf("%.2f", $gb / $nth),  $cost, sprintf("%.2f", $cost / $nth), sprintf("%.2f", $cost / $gb);
	}

	$get_interfaces->finish;

}

# Disconnect from the Database
# ----------------------------
#$dbh->disconnect;

# ----------
sub calcTransfer {
  # This subroutime takes an interface and date range as an input.
  # It otuputs the 95th Percentile and GB transfer for the interface.
  # --
	my $device = shift;
	my $interface = shift;
	my $starttime = shift;
	my $lasttime = shift;

  # Initialize variables we'll need in the routine
	my $nth_in;
	my $nth_out;
	my $gb_in;
	my $gb_out;

	# Subtract five (5) minutes so RRD behaves as desired
	# --
	$rrdstart = $starttime - 300;

	my $rrd = '/usr/local/mrtg-rrd/' . $device . '/' . $interface . '.rrd';

  #	print "$rrd $starttime $lasttime\n" if $DEBUG;

	$stat_in = Statistics::Descriptive::Full->new();
	$stat_out = Statistics::Descriptive::Full->new();

	($start,$step,$names,$data) = RRDs::fetch ($rrd,'AVERAGE','-s',$rrdstart,'-e',$lasttime);

	if ($DEBUG) {
		print "RRD Start:   ", scalar localtime($start), " ($start)\n";
		print "Start:       ", scalar localtime($starttime), "\n";
		print "End:         ", scalar localtime($lasttime), "\n";
		print "Step size:   $step seconds\n";
		print "DS names:    ", join (", ", @$names)."\n";
		print "Data points: ", $#$data + 1, "\n";
	}

	foreach (@$data) {
		# Define values if missing
		# --
		$_->[0] = 0 unless defined $_->[0];
		$_->[1] = 0 unless defined $_->[1];
		
		# Add the data to the culmulative GB transfer
		# --
		$gb_out += ($_->[0] * $step);
		$gb_in += ($_->[1] * $step);

		# Substitute zero for missing samples
		# The if statement is redundant, but JIK
		# Convert the date to bits from bytes and add to the sample
		# -- 
		if ($_->[0] eq "") {
			$sam_out = 0;
		} else {
			$sam_out = $_->[0] * 8;
		}
		$stat_out->add_data($sam_out);

		if ($_->[1] eq "") {
			$sam_in = 0;
		} else {
			$sam_in = $_->[1] * 8;
		}
		$stat_in->add_data($sam_in);
	}

  # Calculate the nth percentile based on the collected samples
  # --
	$nth_in = $stat_in->percentile(95); 
	$nth_out = $stat_out->percentile(95);
	
	# For this script, we only care about the higher of the in/out
	# figure out what it is and return the scaled values
	# --
	if ($gb_in >= $gb_out) {
		return (scaleBits($nth_in), scaleBytes($gb_in));
	} else {
		return (scaleBits($nth_out), scaleBytes($gb_out));
	}
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

  # Calculate GB as Barretbyte
  # http://www.blyon.com/tag/barretbyte/
  # 1 TB = 1000 GB
  # --
  # $gb = $bytes / 1048576000;

  # Calculate GB
  # --
  $gb = $bytes / 1024 / 1024 / 1024;

  $round = sprintf("%.2f", $gb);
  return $round;
}
# ==========
