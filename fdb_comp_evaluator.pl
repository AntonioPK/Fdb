#!/usr/bin/perl -w
#!D:\strawberry\perl\bin\perl.exe -w
#
# Factordb composite evaluator version 1.5.1 - 31 March 2015
# Based on original Perl script by yoyo - http://www.rechenkraft.net/wiki/Benutzer_Diskussion:Yoyo/factordb
# Modified and extended by Antonio - http://mersenneforum.org/
# Written using Strawberry Perl 5.20.2.1-64bit
# Linux compatability and formatting by ChristianB - http://mersenneforum.org/

use warnings;
use strict;
use LWP::Simple;                # Used to read/write web data
use Term::ReadKey;              # Used to read terminal key presses without requiring 'Enter' to be pressed
use Time::HiRes qw(sleep time); # Need better than 1sec resolution for time() and sleep()
use Getopt::Std;                # Handle command line (single letter) options

my $mindig=70;   # Default minimum size of composite to request, smaller composites are handled by the FactorDB server
my $maxdig=96;   # Default maximum size of composite to factor (my SIQS/GNFS crossover)
my $range=100;   # Default maximum random offset into composite data list, used to reduce collisions between multiple users
my $yafutext=1;  # Default to displaying YAFU progress messages

my $yafupath="./"; # Default yafu path on linux
if ($^O ne "linux") {$yafupath="";} # yafu path on Windows
#------------------------------------------------------------------------------------------
# For Windows:- can be set if not in the same directory as yafu e.g. $yafupath="F:\\yafu\\"
# Note:- must use '\\' to get'\' in Perl text string.
#------------------------------------------------------------------------------------------

my $fdburl="http://factorization.ath.cx"; # URL to get composites from
my $fdbcookie=""; # Cookie to use with the URL above

my %numtoget=(); # Composites to get per call,
                 # altered by the throttling code when hourly page request limit (1500 page requests/hour) is being approached or exceeded
                 # Normally we get one composite at a time at a cost of 2 page requests per composite (1 for the 'get' + 1 for the report)
                 # Increasing the number of composites we get each time increases the chance of  worker collisions, but, it also reduces
                 # the page request rate (1 for the 'get n' + 1 for each report) so a total of 1+n page requests for each 'get n'

$numtoget{'normal'}=1;                    # 2 page requests per composite
$numtoget{'throttle'}=10;                 # 11 page requests per 10 composites (normal would cause 20 page requests)
$numtoget{'current'}=$numtoget{'normal'}; # Start in 'normal' mode

my $shortstop=60; # Number of samples to hold for short term rate calculations
my @short;        # Holds the time that each of the last ($shortstop) composite requests occurred
my @page;         # Holds the page requests invoked by each of the last ($shortstop) composite requests
my @nfa;          # Holds the new factors added by each of the last ($shortstop) composite requests
my @composites;
my $pages=0;      # Holds a running total of the last ($shortstop) page requests
my $nfas=0;       # Holds a running total of the last ($shortstop) new factors added to database
my $delay=0;      # Memory for smoothing out forced delays when page request rate is high
my $waitrequests=0;	# Page requests while waiting for valid composite size

my $mincomposite=100000;
my $maxcomposite=0;

my %total=();     # Store for all running totals displayed
$total{'composites'}=0;
$total{'added'}=0;
$total{'known'}=0;
$total{'small'}=0;
$total{'nofactors'}=0;
$total{'nocomposites'}=0;
$total{'noresults'}=0;
$total{'only_small'}=0;
$total{'collision'}=0;
$total{'queries'}=0;
$total{'no_ack'}=0;
$total{'wait_for_comp'}=0;

my $key; # Store for terminal key press

ReadMode 'raw';

# declare the perl command line flags/options
my %options=();
getopts("hm:M:r:fq", \%options);

# test for the existence of the options on the command line.
if (defined $options{h}) {
	print "\t-m\tset minimum composite size (digits) (default=$mindig)\n\t-M\tset maximum composite size (digits) (default=$maxdig)\n";
	print "\t-r\tset maximum random offset into composite list (range is 0 to maximum-1) (default=$range)\n";
	print "\t-f\tflag - if present YAFU log files (session.log & factor.log)\n\t\tare deleted when the program terminates.\n";
	print "\t-q\tflag - if present YAFU progress text is suppressed.\n\n";
	print "\tPress Ctrl-Q to exit after factoring composite(s) already queued.\n";
	die "\n";
}

if (defined $options{m}) {$mindig = $options{m};}
if (defined $options{M}) {$maxdig = $options{M};}
if (defined $options{r}) {$range = $options{r}+1;}
print "\tminimum composite size= $mindig digits\n\tmaximum composite size= $maxdig digits\n";
print "\trandom offset into composite list= 0 to " . sprintf("%d",($range-1)) . "\n";

if (defined $options{f}) {print "\tDelete YAFU log files when done.\n";}
if (defined $options{q}) {print "\tSuppress YAFU progress display.\n"; $yafutext=0;}
print "\n\tCtrl-Q to exit after factoring composite(s) already queued.\n";

sleep(3);

# Allow to exit now if command line not as intended
$key = ReadKey(-1);
if ($key and (ord($key) == 17)) {
	ReadMode 'restore';
	die "\n\tCtrl-Q detected\n";
}

my $startime=time();

do {
	my $current=time();
	# Store the start time for up to '$shortstop' queries so we can calculate the short term average rate later
	if (scalar(@short) == $shortstop) {shift(@short);}
	push(@short,$current);

	my $rand=int(rand($range));
	{
		print "\n";
		(my $sec,my $min,my $hour,my $mday,my $mon,my $year,my $wday,my $yday,my $isdst) = localtime();
		printf("%02d:%02d:%02d", $hour, $min, $sec);
		print "> get composite";
		($numtoget{'current'}>1) ? (print "s (offset=$rand)\n") : (print " (offset=$rand)\n");
	}

	$waitrequests=0;
	my $idle=0;
	do {
		(my $sec,my $min,my $hour,my $mday,my $mon,my $year,my $wday,my $yday,my $isdst) = localtime();
		my $contents = get("$fdburl/listtype.php?t=3&mindig=$mindig&perpage=$numtoget{'current'}&start=$rand&download=1");
		++$waitrequests;
		if (!defined $contents or $contents =~ /[a-z]/) {
			printf("%02d:%02d:%02d", $hour, $min, $sec);
			print "> No composite(s) received, waiting...($waitrequests)\n";
			$idle=1;
		}else {
			@composites=split(/\s/, $contents);
			my $compositelen=100000;
			foreach my $composite (@composites) {
				if (length($composite)< $compositelen) {
					$compositelen = length($composite);
				}
			}
			if ($compositelen > $maxdig) {
			# pause while composites are larger than maximum allowed
				printf("%02d:%02d:%02d", $hour, $min, $sec);
				print "> Max composite size exceeded, waiting...($waitrequests)\n";
				# All composites are too big so look at the start of the list from now on,
				# in case we missed some due to the random step into the list.
				$rand=0;
				$idle=1;
			}else {
				$idle=0;
			}
		}
		if ($idle) {sleep(600);}
	}while ($idle);

	my $pageinc=$numtoget{'current'}+$waitrequests;
	$total{'wait_for_comp'}+=($waitrequests-1);
	$total{'queries'}+=$waitrequests;
	push(@page,$pageinc);
	push(@nfa,0);
	$pages += $pageinc;
	if (scalar(@page) > $shortstop) {
	   $pages -=shift(@page);
	   $nfas -=shift(@nfa);
	}

	# Sort into ascending size - if more than one composite is requested
	if ($numtoget{'current'} > 1) {@composites = sort{$a<=>$b}@composites;}

	foreach my $composite (@composites) {
		my $localt = time();
		my $compositelen=length($composite);
		last if ($compositelen > $maxdig);

		if ($compositelen > $maxcomposite) {$maxcomposite = $compositelen;}
		if ($compositelen < $mincomposite) {$mincomposite = $compositelen;}
		print "\nFactoring $compositelen digits: $composite\n";

		my @results;
		open(YAFU, "${yafupath}yafu \"factor($composite)\" -p|") or die "\n\tCouldn't start yafu!";
		while (<YAFU>) {
			if ($yafutext) {print "$_";}
			chomp;
			if (/^[CP].*? = (\d+)/) {
				push(@results, $1);
				if (!$yafutext) {print "$_\n";}
			}
		}
		print "*****\n";
		close(YAFU);
		unlink("siqs.dat"); # I have seen this file re-used when factoring, so delete it here to redo entire factorization!

		if (scalar(@results) > 0) {
		# Sort factors into descending size order for reporting to database
			@results = sort{$b<=>$a}@results;
			++$total{'composites'};

			my $compute_time = time()-$localt;
			my $url="$fdburl/report.php?report=".$composite."%3D".join('*',@results);
			my $contents=get($url);
			++$total{'queries'};

			my $elapse = time()-$startime;
			my $hours= int($elapse /3600);
			my $minutes= int($elapse/60)%60;
			my $seconds= $elapse%60;

			if (defined $contents) {
				my $nofactors     = ($contents =~ s/Does not divide//g);
				my $already_known = ($contents =~ s/Factor already known//g);
				my $added         = ($contents =~ s/Factor added//g);
				my $small         = ($contents =~ s/Small factor//g);

				my $whrs = int($total{'wait_for_comp'}/6);
				my $wmin = ($total{'wait_for_comp'}%6)*10;

				if ($nofactors) {$total{'nofactors'} += $nofactors;}
				if ($already_known) {$total{'known'} += $already_known;}
				if ($added) {
					$total{'added'} += $added;
					push(@nfa,pop(@nfa)+$added);
					$nfas += $added;
				}
				if ($small) {$total{'small'} += $small;}
				if (!$added and $already_known) {++$total{'collision'};}
				if (!$added and !$already_known and $small) {++$total{'only_small'};}


				print "============================================================\n";
				print "Runtime (H:M:S).....................: " . sprintf("%04d",$hours) . ":" . sprintf("%02d",$minutes) . ":" . sprintf("%02d",$seconds) . "\n";
				print "Time waiting for composites (H:M)...: " . sprintf("%04d",$whrs) . ":" . sprintf("%02d",$wmin) . "\n";
				print "Composite range.....................: $mincomposite - $maxcomposite digits\n\n";
				print "Report factors for composite #......: " . $total{'composites'} . "\n";
				print "Factored C$compositelen in ....................: " . sprintf("%.1f",$compute_time) . " sec.\n\n";
				print "\tNew factors added...........: " . ($added         ? $added         : 0) . " / " . $total{'added'} . "\n";
				print "\tFactors already known.......: " . ($already_known ? $already_known : 0) . " / " . $total{'known'} . "\n";
				print "\tSmall factors...............: " . ($small         ? $small         : 0) . " / " . $total{'small'} . "\n";
				print "\tErrors (does not divide)....: " . ($nofactors     ? $nofactors     : 0) . " / " . $total{'nofactors'} . "\n\n";
				print "\tOnly small factors..........: " . $total{'only_small'} . "\n";
				print "\tNo composites received......: " . $total{'nocomposites'} . "\n";
				print "\tNo results from YAFU........: " . $total{'noresults'} . "\n";
				print "\tResults not acknowledged....: " . $total{'no_ack'} . "\n";
				print "\tWorker collisions...........: " . $total{'collision'} . "\n\n";
				print "\tTotal page requests.........: " . $total{'queries'} . "\n";
				print "============================================================\n";
			}else {
				print "\nError, no response from FactorDB when reporting results\n";
				++$total{'no_ack'};
				#sleep(60);
			}
		}else {
			print "Error in YAFU, no factors returned\n";
			++$total{'noresults'};
		}
	}
	# 'per composite request' rate limiting:
	# Limit the maximum rate to 1800 queries per hour (2 sec. per query)
	# by adding extra delay. Will be negative for slow factorizations
	# this should help to average out large changes in factorization times.
	$delay += (2*($numtoget{'current'}+1)-(time()-$current));

	# Display current database query rate
	$current=time();

	my $elapsed = $current-$startime; # Time to process all composites so far
	print sprintf("%7.1f",$total{'composites'}*3600/$elapsed) . " composites/hr\n";
	my $longterm = $total{'queries'}*3600/$elapsed;
	print sprintf("%7.1f",$longterm) . " page requests/hr\n";

	# Now try to ensure average rate does not exceed 1500 database page requests per hour
	# Use average of last '$shortstop' "get composite(s)" times for short term rate calculations.
	# Each "get composite(s)" request and each factored composite report generates a page request in the database
	# $pages holds the number of page requests invoked by the last '$shortstop' "get composite(s)"
	if (scalar(@short) == $shortstop) {
		my $shorterm = (3600*$pages) / ($current-$short[0]);
		my $shortnfas =(3600*$nfas) / ($current-$short[0]);
		print sprintf("%7.1f", $shorterm) . " page requests/hr (last $shortstop composite requests)\n";
		print sprintf("%7.1f", $shortnfas) . " new factors added/hr (last $shortstop composite requests)\n";

		if ($numtoget{'current'} == $numtoget{'throttle'}) {
			if ($longterm > 1500) {
				# Use 2.5 to limit queries to approx. 1440/hr
				$delay += (2.5*$total{'queries'} - $elapsed); # add to any previous delay(s)
				if ($delay > 0) {print "Waiting(Long term rate limit)..." . sprintf("%6.2f",$delay) . " sec.\n";}
			}elsif ($shorterm > 1500) {
				# Should take (2.4*$pages) sec. at 1500/hour, actually took ($current-$short[0]) sec. so wait.
				# Use 2.45 to limit queries to approx. 1470/hr
				$delay += (2.45*$pages-($current-$short[0])); # add to any previous delay(s)
				if ($delay > 0) { print "Waiting(Short term rate limit)." . sprintf("%6.2f",$delay) . " sec.\n";}
			} elsif ($delay > 0) {
				# Use any remaining delay -
				# from the smoothing function and the 'per request' rate limiting
				print "Waiting(Smoothing function)......................" . sprintf("%6.2f",$delay) . " sec.\n";
			}

			if ($delay > 0) {sleep($delay);}
			if ($shorterm < 1300) {$numtoget{'current'} = $numtoget{'normal'};}

		}elsif ($shorterm > 1400) {
			$numtoget{'current'} = $numtoget{'throttle'};
		}
	}
	# This is a sort of smoothing function - old delays decay away rather than just disappearing
	# Under sustained throttling this will increase calculated delays by approx. 11%
	if ($delay != 0) {
		$delay = int($delay*10+0.5)/100; # divide by 10 and round, retain 2 digits after decimal, old delays will decay to zero
	}

	# Now check for key press
	$key = ReadKey(-1);

	# Check to see if Ctrl-Q has been pressed, if not then continue otherwise quit program

	}while (!$key or (ord($key) != 17));

if (defined $options{f}) {
	# delete YAFU log files
	unlink("factor.log");
	unlink("session.log");
}

ReadMode 'restore';

die "\n\tCtrl-Q detected\n";
