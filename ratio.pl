#!/usr/bin/perl -w

# Configuration
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
  'debug|d', 'month|m=s', 'year|y=s', 'lastmonth|l', 'ytd', 'help|h', 'verbose|v', 'version'
	) or exit(1);
usage if $opt{help};

if ($opt{version}) {
	print "report $VERSION by max\@clarksys.com\n";
	exit;
}

$DEBUG = "1" if defined $opt{debug};

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
  
  print "\n Ratio report from: ", scalar localtime($starttime), " to: ", scalar localtime($endtime), "\n\n";
  print "$starttime $endtime\n" if $VERBOSE;

  # printf "%20s %10s %10s %10s %10s %10s %10s\n", Interface, "95th", "GB", "GB/Mb", "Cost", "\$/Mbps", "\$/GB";

	$get_interfaces->execute($_, "$y-$m-$d");

  while (my ($id, $name, $type, $device, $interface, $ccn_rate, $cir, $cir_rate, $overage_rate) = $get_interfaces->fetchrow_array) {
    
    $int = $device . "_" . $interface;
		print "interface: $int\n" if $DEBUG;
		
		my ($inbound,$outbound) = calcRatio($device,$int,$starttime,$endtime);
		print "in = $inbound \t out = $outbound\n" if $DEBUG;
		
		$total_in += $inbound;
  	$total_out += $outbound;
  	
  	printf "%20s: In: %8s Out: %8s GByte\n", $name, scaleBytes($inbound), scaleBytes($outbound);
  	
	}
}

print "\n";
printf "%20s In: %8s Out: %8s GByte\n", "Total", scaleBytes($total_in), scaleBytes($total_out);
printf "%20s In: %.2f Out: %.2f\n", "Ratio", $total_in / ($total_in + $total_out), $total_out / ($total_in + $total_out);

# ----------
sub calcRatio {
	my $device = shift;
	my $interface = shift;
	my $starttime = shift;
	my $lasttime = shift;

	# Subtract five (5) minutes so RRD behaves as desired
	# --
	$rrdstart = $starttime - 300;

	my $rrd = '/usr/local/mrtg-rrd/' . $device . '/' . $interface . '.rrd';

#	print "$rrd $starttime $lasttime\n" if $DEBUG;

	($start,$step,$names,$data) = RRDs::fetch ($rrd,'AVERAGE','-s',$rrdstart,'-e',$lasttime);

	if ($DEBUG) {
		print "RRD Start:   ", scalar localtime($start), " ($start)\n";
		print "Start:       ", scalar localtime($starttime), "\n";
		print "End:         ", scalar localtime($lasttime), "\n";
		print "Step size:   $step seconds\n";
		print "DS names:    ", join (", ", @$names)."\n";
		print "Data points: ", $#$data + 1, "\n";
		print "Data:\n";

		foreach my $line (@$data) {
			print "  ", scalar localtime($start), " ($start) ";
			$start += $step;
			foreach my $val (@$line) {
				# Define value if missing
				# --
				$val = 0 unless defined $val;
				printf "%12.1f ", $val;
			}
		print "\n";
		}
	}

	my $in_total = "0";
	my $out_total = "0";

	foreach (@$data) {

#		if ($DEBUG) {
#			die "\$_->[0] undefined" unless defined $_->[0];
#			die "\$_->[1] undefined" unless defined $_->[1];
#		}

		# Define values if missing
		# --
		$_->[0] = 0 unless defined $_->[0];
		$_->[1] = 0 unless defined $_->[1];

		# Total Counters
		# --
		#if ($DEBUG) {
		#	print "In: $_->[0] \t Out: $_->[1]\n";
		#}

		$in_total = $in_total + ($_->[0] * 300);
		$out_total = $out_total + ($_->[1] * 300);

	}

	return ($in_total,$out_total);
}
# ==========

# ----------
sub scaleBytes {

        my $bytes = shift;
        $scale = $bytes / 1073741824;   # 1024 * 1024 * 1024 GByte
        $round = sprintf("%.2f", $scale);
        return $round;

}
# ==========
