#!/usr/bin/perl -w
#!D:\strawberry\perl\bin\perl.exe -w
#
# Factordb composite evaluator version 1.5.2 - 21 April 2015
# Based on original Perl script by yoyo - http://www.rechenkraft.net/wiki/Benutzer_Diskussion:Yoyo/factordb
# Modified and extended by Antonio - http://mersenneforum.org/
# Written using Strawberry Perl 5.20.2.1-64bit
# Linux compatibility and formatting by ChristianB - http://mersenneforum.org/

use warnings;
use strict;
use LWP::Simple;                # Used to read/write web data
use Term::ReadKey;              # Used to read terminal key presses without requiring 'Enter' to be pressed
use Time::HiRes qw(sleep time); # Need better than 1sec resolution for time() and sleep()
use Getopt::Std;                # Handle command line (single letter) options
use IO::Handle qw( );			# Used to flush display buffer

my $mindig = 70;   # Default minimum size of composite to request, smaller composites are handled by the FactorDB server
my $maxdig = 98;   # Default maximum size of composite to factor (my SIQS/GNFS crossover)
my $range = 100;   # Default maximum random offset into composite data list, used to reduce collisions between multiple users
my $rangeinc = 0;  # Auto increment maximum random offset by this amount if a worker collision occurs
my $yafutext = 1;  # Default to displaying YAFU progress messages

my $pagerate = 1500; # Maximum page request rate (per hour) allowed by Factordb.com
my $pcrate = 3600/($pagerate*1.2); # per composite rate limit
my $ltrate = 3600/($pagerate*0.96); # long term rate limit
my $strate = 3600/($pagerate*0.98); # short term rate limit

my $yafupath = "./"; # Default yafu path on linux
my $logpath = "./"; # Default log file path on linux
if ($^O ne "linux") {
	# For Windows:- can be set if not in the same directory as yafu e.g. $yafupath = "F:\\yafu\\"
	# Note:- must use '\\' to get'\' in Perl text string.
	$yafupath = ""; # Default yafu path on Windows
	$logpath = ""; # Default log file path on Windows
}

my $fdburl = "http://factordb.com"; # URL to get composites from
my $fdbcookie = ""; # Cookie to use with the URL above
my $logfile = $logpath . "Fdb.csv"; # Default log file

my %numtoget = (); # Composites to get per call,
                   # altered by the throttling code when hourly page request limit is being approached or exceeded
                   # Normally we get one composite at a time at a cost of 2 page requests per composite (1 for the 'get' + 1 for the report)
                   # Increasing the number of composites we get each time increases the chance of  worker collisions, but, it also reduces
                   # the page request rate (1 for the 'get n' + 1 for each report) so a total of 1+n page requests for each 'get n'

$numtoget{'normal'} = 1;                    # 2 page requests per composite
$numtoget{'throttle'} = 10;                 # 11 page requests per 10 composites (normal would cause 20 page requests)
$numtoget{'current'} = $numtoget{'normal'}; # Start in 'normal' mode

my $shortstop = 60; # Number of samples to hold for short term rate calculations
my @short;          # Holds the time that each of the last ($shortstop) composite requests occurred
my @page;           # Holds the page requests invoked by each of the last ($shortstop) composite requests
my @nfa;            # Holds the new factors added by each of the last ($shortstop) composite requests
my @composites;
my $pages = 0;      # Holds a running total of the last ($shortstop) page requests
my $nfas = 0;       # Holds a running total of the last ($shortstop) new factors added to database
my $delay = 0;      # Memory for smoothing out forced delays when page request rate is high
my $waitrequests = 0;	# Page requests while waiting for valid composite size
my $logging;		# Flag - are we going to write to log file.
my $mincomposite = 1000;
my $maxcomposite = 0;

my %total = ();     # Store for all running totals displayed
$total{'composites'} = 0;
$total{'added'} = 0;
$total{'known'} = 0;
$total{'small'} = 0;
$total{'nofactors'} = 0;
$total{'nocomposites'} = 0;
$total{'noresults'} = 0;
$total{'only_small'} = 0;
$total{'collision'} = 0;
$total{'queries'} = 0;
$total{'no_ack'} = 0;
$total{'wait_for_comp'} = 0;

my $key; # Store for terminal key press
ReadMode 'raw';

# declare the perl command line flags/options
my %options = ();
getopts("hm:M:r:a:fql", \%options);

# test for the existence of the options on the command line.
if (defined $options{h}) {
	print "\tfdb_comp_evaluator ver. 1.5.2\n\n";
	print "\t-m xx\tset minimum composite size to xx(digits) (default=$mindig)\n";
	print "\t-M xx\tset maximum composite size to xx(digits) (default=$maxdig)\n";
	print "\t-r xx\tset maximum random offset into composite list (range is 0 to xx) (default=$range)\n";
	print "\t-a xx\tset auto-increment of maximum random offset if a collision occurs (default=0)\n";
	print "\t-f\tflag - if present YAFU log files (session.log & factor.log)\n\t\tare deleted when the program terminates.\n";
	print "\t-q\tflag - if present YAFU progress text is suppressed.\n";
	print "\t-l\tflag - if present log data to Fdb.csv\n\t\t(composite size, number of prime factors, time to factor in seconds).\n\n";
	die "\n";
}

if (defined $options{m}) {$mindig = int($options{m});}
if (defined $options{M}) {$maxdig = int($options{M});}
my $addrange = 0;
if (defined $options{r}) {$range = int($options{r});}
if (defined $options{a}) {$rangeinc = int($options{a});}
print "\tminimum composite size= $mindig digits\n\tmaximum composite size= $maxdig digits\n";
my $maxinc = ($maxdig - $mindig)*$rangeinc; # upper limit for the extra random offset that can be added
if ($rangeinc > 0) {
	print "\tadditional random offset increment set to $rangeinc if worker collision occurs\n";
	print "\trandom offset into composite list variable from 0 to $range up to 0 to " . sprintf ("%d", ($range + $maxinc)) . "\n";
}else {
	print "\trandom offset into composite list from 0 to $range)\n";
}
if (defined $options{f}) {print "\tDelete YAFU log files when done.\n";}
if (defined $options{q}) {
	print "\tSuppress YAFU progress display.\n";
	$yafutext=0;
}
if (defined $options{l}) {
	print "\tLogging results to $logfile\n";
	$logging=1;
	}else {
	$logging=0;
	}
print "\n\tCtrl-Q to exit after factoring composite(s) already queued.\n";

sleep(3);

# Allow to exit now if command line not as intended
$key = ReadKey(-1);
if ($key and (ord($key) == 17)) {
	ReadMode 'restore';
	die "\n\tCtrl-Q detected\n";
}

my $startime = time();

do {
	my $current = time();
	# Store the start time for up to '$shortstop' queries so we can calculate the short term average rate later
	if (scalar(@short) == $shortstop) {shift(@short);}
	push(@short,$current);

	my $rangenow = $range + int($addrange+0.5);
	my $rand = int(rand($rangenow+1));
	{
		(my $sec,my $min,my $hour,my $mday,my $mon,my $year,my $wday,my $yday,my $isdst) = localtime();
		print "\n" . sprintf("%02d:%02d:%02d", $hour, $min, $sec) . "> get composite";
		($numtoget{'current'}>1) ? (print "s (offset=$rand/$rangenow)\n") : (print " (offset=$rand/$rangenow)\n");
	}

	$waitrequests = 0;
	my $idle = 0;
	do {
		(my $sec,my $min,my $hour,my $mday,my $mon,my $year,my $wday,my $yday,my $isdst) = localtime();
		my $contents = get("$fdburl/listtype.php?t=3&mindig=$mindig&perpage=$numtoget{'current'}&start=$rand&download=1");
		++$waitrequests;
		if (!defined $contents or $contents =~ /[a-z]/) {
			$total{'nocomposites'} +=1;
			print sprintf("%02d:%02d:%02d", $hour, $min, $sec) . "> No composite(s) received, waiting......($waitrequests)\r";
			STDOUT->flush();
			$idle = 1;
		}else {
			@composites = split(/\s/, $contents);
			my $compositelen = $maxdig+1;
			foreach my $composite (@composites) {
				my $comlen = length($composite);
				if ($comlen< $compositelen) {$compositelen = $comlen;}
			}
			if ($compositelen > $maxdig) {
				# pause while all composites are larger than maximum allowed
				print sprintf("%02d:%02d:%02d", $hour, $min, $sec) . "> Max composite size exceeded, waiting...($waitrequests)\r";
				STDOUT->flush();
				# All composites are too big so look at the start of the list from now on,
				# in case we missed some due to the random step into the list.
				$rand = 0;
				$addrange *= 0.5; # decrease additional random offset into composite list
				$idle = 1;
			}else {
				if ($idle) {
					# If we are going from idle state back to active state
					(my $sec,my $min,my $hour,my $mday,my $mon,my $year,my $wday,my $yday,my $isdst) = localtime();
					print "\n" . sprintf("%02d:%02d:%02d", $hour, $min, $sec) . ">";
					$idle = 0;
				}
			}
		}
		if ($idle) {
			for (my $i=0; $i<60; $i++) {
				sleep(10);
				# Now check for key press
				$key = ReadKey(-1);
				if ($key and (ord($key) == 17)) {
					if (defined $options{f}) {
						# delete YAFU log files
						unlink("factor.log");
						unlink("session.log");
					}
					ReadMode 'restore';
					die "\n\n\tCtrl-Q detected\n";
				}
			}
		}
	}while ($idle);

	my $pageinc = $numtoget{'current'}+$waitrequests;
	$total{'wait_for_comp'} += ($waitrequests-1);
	$total{'queries'} += $waitrequests;
	push(@page,$pageinc);
	push(@nfa,0);
	$pages += $pageinc;
	if (scalar(@page) > $shortstop) {
	   $pages -= shift(@page);
	   $nfas -= shift(@nfa);
	}

	# Sort into ascending size - if more than one composite is requested
	if ($numtoget{'current'} > 1) {@composites = sort{$a<=>$b}@composites;}

	foreach my $composite (@composites) {
		my $localt = time();
		my $compositelen = length($composite);
		last if ($compositelen > $maxdig);

		if ($compositelen > $maxcomposite) {$maxcomposite = $compositelen;}
		if ($compositelen < $mincomposite) {$mincomposite = $compositelen;}
		print "\nFactoring C$compositelen: $composite\n";

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
			my $url = "$fdburl/report.php?report=".$composite."%3D".join('*',@results);
			my $contents = get($url);
			++$total{'queries'};

			my $elapse = time()-$startime;
			my $hours = int($elapse /3600);
			my $minutes = int($elapse/60)%60;
			my $seconds = $elapse%60;

			if (defined $contents) {
				my $nofactors     = ($contents =~ s/Does not divide//g);
				my $already_known = ($contents =~ s/Factor already known//g);
				my $added         = ($contents =~ s/Factor added//g);
				my $small         = ($contents =~ s/Small factor//g);

				if ($logging) {
					my $numfac = $already_known+$added+$small;
					open (my $filehandle, '>>', $logfile);
					print $filehandle sprintf("%4d",$compositelen) . "," . sprintf("%4d",$numfac) . ", " . sprintf("%.3f",$compute_time) . "\n";
					close ($filehandle);
				}

				my $whrs = int($total{'wait_for_comp'}/6);
				my $wmin = ($total{'wait_for_comp'}%6)*10;

				if ($nofactors) {$total{'nofactors'} += $nofactors;}
				if ($already_known) {$total{'known'} += $already_known;}
				if ($small) {$total{'small'} += $small;}
				if ($added) {
					$total{'added'} += $added;
					push(@nfa,pop(@nfa)+$added);
					$nfas += $added;
				}
				if (!$added and !$already_known and $small) {++$total{'only_small'};}

				$addrange *= 0.933; # reduce any existing additional random offset (halves after 10 consecutive non-collisions)
				if (!$added and $already_known) {
					++$total{'collision'};
					#increase additional random offset if number of collisions > 5% of composites factored
					if (($total{'collision'}/$total{'composites'})>0.05) {
						$addrange += $rangeinc;
						if($addrange > $maxinc) {$addrange = $maxinc;} # limit the additional random offset
					}
				}

				print "============================================================\n";
				print "Runtime (H:M:S).....................: " . sprintf("%04d",$hours) . ":" . sprintf("%02d",$minutes) . ":" . sprintf("%02d",$seconds) . "\n";
				print "Time waiting for composites (H:M)...: " . sprintf("%04d",$whrs) . ":" . sprintf("%02d",$wmin) . "\n";
				print "Composite range.....................: $mincomposite - $maxcomposite digits\n\n";
				print "Report factors for composite #......: " . $total{'composites'} . "\n";
				print "Factored C$compositelen in....................";
				if ($compositelen < 10) {
					print "..: ";
				}elsif ($compositelen < 100) {
					print ".: ";
				}else {
					print ": ";
				}
				print sprintf("%.1f",$compute_time) . " sec.\n\n";
				print "\tNew factors added...........: " . ($added         ? $added         : 0) . " / " . $total{'added'} . "\n";
				print "\tFactors already known.......: " . ($already_known ? $already_known : 0) . " / " . $total{'known'} . "\n";
				print "\tSmall factors...............: " . ($small         ? $small         : 0) . " / " . $total{'small'} . "\n\n";
				print "\tOnly small factors..........: " . $total{'only_small'} . "\n";
				print "\tWorker collisions...........: " . $total{'collision'} . "\n";
				if ($total{'nocomposites'} || $total{'noresults'} || $total{'no_ack'} || $total{'nofactors'}) {print "\n"}
				if ($total{'nocomposites'}) {print "\tNo composites received......: " . $total{'nocomposites'} . "\n";}
				if ($total{'noresults'}) {print "\tNo results from YAFU........: " . $total{'noresults'} . "\n";}
				if ($total{'no_ack'}) {print "\tResults not acknowledged....: " . $total{'no_ack'} . "\n";}
				if ($total{'nofactors'}) {
					print "\tErrors......................: " . ($nofactors     ? $nofactors     : 0) . " / " . $total{'nofactors'} . "\n";
					print "\t(Factor did not divide composite)\n";
				}
				print "\n\tTotal page requests.........: " . $total{'queries'} . "\n";
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
	# Limit the maximum rate by adding extra delay. Will be negative for slow factorisations
	# this should help to average out large changes in factorization times.
	$delay += ($pcrate*($numtoget{'current'}+1)-(time()-$current));

	# Display current database query rate
	$current = time();

	my $elapsed = $current-$startime; # Time to process all composites so far
	print sprintf("%7.1f",$total{'composites'}*3600/$elapsed) . " composites/hr\n";
	my $longterm = $total{'queries'}*3600/$elapsed;
	print sprintf("%7.1f",$longterm) . " page requests/hr\n";

	# Now try to ensure average rate does not exceed the database page requests per hour limit
	# Use average of last '$shortstop' "get composite(s)" times for short term rate calculations.
	# Each "get composite(s)" request and each factored composite report generates a page request in the database
	# $pages holds the number of page requests invoked by the last '$shortstop' "get composite(s)"
	if (scalar(@short) == $shortstop) {
		my $shorterm = (3600*$pages) / ($current-$short[0]);
		my $shortnfas = (3600*$nfas) / ($current-$short[0]);
		print sprintf("%7.1f", $shorterm) . " page requests/hr (last $shortstop composite requests)\n";
		print sprintf("%7.1f", $shortnfas) . " new factors added/hr (last $shortstop composite requests)\n";

		if ($numtoget{'current'} == $numtoget{'throttle'}) {
			if ($longterm > $pagerate) {
				$delay += ($ltrate*$total{'queries'} - $elapsed); # add to any previous delay(s)
				if ($delay > 0) {print "Waiting(Long term rate limit)..." . sprintf("%6.2f",$delay) . " sec.\n";}
			}elsif ($shorterm > $pagerate) {
				$delay += ($strate*$pages-($current-$short[0])); # add to any previous delay(s)
				if ($delay > 0) { print "Waiting(Short term rate limit)." . sprintf("%6.2f",$delay) . " sec.\n";}
			} elsif ($delay > 0) {
				# Use any remaining delay -
				# from the smoothing function and the 'per request' rate limiting
				print "Waiting(Smoothing function)......................" . sprintf("%6.2f",$delay) . " sec.\n";
			}

			if ($delay > 0) {sleep($delay);}
			if ($shorterm < (0.86*$pagerate)) {$numtoget{'current'} = $numtoget{'normal'};}

		}elsif ($shorterm > (0.93*$pagerate)) {
			$numtoget{'current'} = $numtoget{'throttle'};
		}
	}
	# This is a sort of smoothing function
	# divide by 10 and round, retain 2 digits after decimal, old delays will decay to zero
	# Under sustained throttling this will increase calculated delays by approx. 11%
	if ($delay > 0) {
		$delay = int($delay*10+0.5)/100;
	}elsif ($delay < 0) {
		$delay = int($delay*10-0.5)/100;
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
