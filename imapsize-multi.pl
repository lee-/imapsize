#!/usr/bin/perl
#
#
# This program is free software: you can redistribute it and/or
# modify it under the terms of the GNU General Public License as
# published by the Free Software Foundation, either version 3 of the
# License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see
# <http://www.gnu.org/licenses/>.


# imapsize-multi.pl
#
# + check email account(s) via IMAP for how many messages there are and
#   compute their total size
#
# + compute "percentage full" of each account, using the specified
#   size-quota, and send an informative email about usage
#
# + write the obtained information to a CSV file
#
#
# usage:
#
# + adjust settings below
#
# + create a file listing the IMAP accounts to check, for example:
#
#
# server1.example.com, user1@example.com, password_user1, quotaMB
# server2.example.com, user2@example.com, password_user2, quotaMB
#
#
# + make sure the passwords cannot be read by unauthorized users!
#
# + run the script --- you may need to install additional perl modules
#
# + you can run the script from your contab to check the accounts regularly
#
#


use strict;
use warnings;
use autodie;
use Net::IMAP::Client;
use MIME::Lite;
use Scalar::Util qw(openhandle);
use File::Slurp;


# SETTINGS
#
# list of emailaccounts
# entries are SERVER, USERNAME, PASSWORD, QUOTA LIMIT
# items must be seperated by comma; QUOTA LIMIT is in MB
#
use constant ACCOUNTLIST => '/root/acctlst';

# send email with quota information from, to
# The recipient receives the OUTFILE.
#
use constant RCPT => 'recipient@example.com';
use constant FROM => 'sender@example.com';

# file for quota information summary
#
use constant OUTFILE => '/root/imapsize.out';

# file for statistics
#
use constant STATISTICSFILE => '/root/imapsize-stats.csv';
#
# how many lines in STATISTICSFILE before itÂ´s truncated
#
use constant STATSFILE_MAXLINES => 4096;
#
# truncate STATISTICSFILE by this many lines
# The file may grow indefinitely when more new lines are added
# each run than are being truncated.
# When STATSFILE_TRUNCLINES is greater than STATSFILE_MAXLINES,
# STATISTICSFILE will be unlinked rather than truncated.
#
use constant STATSFILE_TRUNCLINES => 5;
#
# When the STATISTICSFILE has more lines than STATSFILE_MAXLINES, a
# copy of the file is created without the first STATSFILE_MAXLINES
# lines which then replaces the STATISTICSFILE.  Specify the name to
# use for this file here.
#
use constant STATSFILE_COPY => STATISTICSFILE . '_tmp';
#
# Put a nice header on top of the STATISTICSFILE, telling what each field is.
# do not change
#
use constant STATSFILE_HEADER => "unixtime,msgs,size,percent quota,quota,username,server\n";

# internal factors for kilobyte, megabyte and gigabyte
# do not change
#
use constant KB => 1024;
use constant MB => KB * 1024;
use constant GB => MB * 1024;

# give warning when quota limit is almost reached
# (like when 85% full)
#
use constant QUOTA_WARNING_PERCENT => 85.0;
# / SETTINGS


# go through each account given and check
#
sub chkacct {
    my ($out, $stat, $server, $username, $pass, $quota) = @_;


    # create new imap connection ...
    #
    my $imap = Net::IMAP::Client->new(
	server => $server,
	user => $username,
	pass => $pass,
	ssl => 1,
	ssl_verify_peer => 0,
	port => 993)
	or die "connection to imap server ($server) failed";

    # ... and log in
    #
    return 1 unless $imap->login;


    # request all folders
    #
    my @folders = $imap->folders;
    my $msgsize = 0;
    my $nm = 0;

    # go through all messages in all folders and fetch their size
    #
    foreach my $this (@folders) {
	my $status = $imap->status($this);
	my $nofmsgs = $status->{MESSAGES};

	if ($nofmsgs) {
	    $nm += $nofmsgs;
	    $imap->examine($this);

	    foreach my $id ($imap->search('ALL')) {
		foreach my $msg (@$id) {
		    $msgsize += $imap->fetch($msg, 'RFC822.SIZE')->{'RFC822.SIZE'};
		}
	    }
	}
    }

    # done with imap
    #
    $imap->logout;


    # add info to outfile
    #
    my $megabyte = int($msgsize / MB + 0.5);

    # $msgsize is in bytes
    #
    $quota *= MB;
    my $percent_quota = int($msgsize * 100.0 / $quota + 0.5);
    printf $out "%6d email(s), %12d byte(s) (~%6d MB), ~%3d%% used <%s>@[%s]: ", $nm, $msgsize, $megabyte, $percent_quota, $username, $server;

    my $status = 'OK';
    if (QUOTA_WARNING_PERCENT < $percent_quota) {
	$status = 'WARNING';
    }

    print $out $status . "\n";


    # add info to statistics file
    #
    print $stat join(',', time, $nm, $msgsize, $percent_quota, $quota, $username, $server) . "\n";

    return 0;
}


# send info as email
#
sub file2mail {
    my ($filename, $from, $rcpt, $subj) = @_;


    my $file = read_file($filename);

    my $email = MIME::Lite->new(
	From     => $from,
	To       => $rcpt,
	Subject  => $subj,
	Data     => $file
	);
    $email->send;
}


###########################################################################


open my $outfile, ">", OUTFILE;
print $outfile "Email Quota check, " . localtime(time) . "\n\n";


# check statistics file before opening
#
my $statsfile_exists = 0;
#
if (-e STATISTICSFILE) {
    $statsfile_exists = 1;

    open my $origin_fh, "<", STATISTICSFILE;

    my $lines = 0;

  ORIGIN:
    while (<$origin_fh>) {
	$lines++;
	if (STATSFILE_MAXLINES < $lines) {
	    #
	    # unlink the file when there are more lines to truncate than the
	    # file is allowed to have
	    #
	    if (STATSFILE_TRUNCLINES >= $lines) {

		close $origin_fh;
		unlink(STATISTICSFILE);
		$statsfile_exists = 0;
		print $outfile STATISTICSFILE . " has been unlinked\n";
		print $outfile "because it would have been truncated by more lines than it had\n\n";

		# the file has been unlinked anyway
		#
		last ORIGIN;

	    } else {
		#
		# otherwise, truncate some lines from the top
		#

		# seek STATSFILE_TRUNCLINES into file
		#
		seek($origin_fh, 0, 0);
		$lines = 0;
		while (<$origin_fh>) {
		    $lines++;
		    last if(STATSFILE_TRUNCLINES < $lines);
		}

		# From there, create a forward copy of the remaining lines.
		# What is more awkward: Reading backwards or copying forwards? 

		open my $copy_fh, ">", STATSFILE_COPY;
		print $copy_fh STATSFILE_HEADER;
		$lines = 0;

	      COPY:
		while (my $thisline = <$origin_fh>) {
		    chomp $thisline;

		    # skip blank line at eof unless not first line
		    #
		    if (length($thisline) || $lines) {
			print $copy_fh $thisline . "\n";
			$lines++;
		    }
		}

		close $copy_fh;
		close $origin_fh;

		unlink(STATISTICSFILE);
		rename(STATSFILE_COPY, STATISTICSFILE);
		print $outfile STATISTICSFILE . " has been truncated forwardly because it had more than " . STATSFILE_MAXLINES . " lines\n";
		print $outfile "$lines line(s) remained\n\n";

		# at eof anyway
		#
		last ORIGIN;
	    }
	}
    }

    # only close when still open
    #
    if (defined(openhandle($origin_fh))) {
	close $origin_fh;
    }
}
#
# / check statistics file before opening


# check accounts

open my $statsfile, ">>", STATISTICSFILE;
#
# what it says
#
print $statsfile STATSFILE_HEADER unless($statsfile_exists);


my $linecount = 0;
open my $fh, "<", ACCOUNTLIST;

LINE:
    while (my $line = <$fh>) {
	$linecount++;

	unless($line =~ m/^#/)
	{
	    chomp $line;
	    my @acct = split(',', $line);

	    if(@acct == 4) {

		for (@acct) {
		    # trim them all
		    #
		    s/^\s+|\s+$//g;

		    unless(length) {
			printf $outfile "syntax error in %s, line %8d (zero-length item?)\n", ACCOUNTLIST, $linecount;
			next LINE;
		    }
		}

		# check an account
		#
		print $outfile "login for $acct[3] ($acct[2]) failed\n" if chkacct($outfile, $statsfile, @acct);
	    }
	    else
	    {
		printf $outfile "syntax error in %s, line %8d (missing item?)\n", ACCOUNTLIST, $linecount;
	    }
	}
}
close $fh;

close $statsfile;


if (STATSFILE_TRUNCLINES < $linecount) {
    #
    # be nice and give a warning
    #
    print $outfile "\n\n" . STATISTICSFILE . " may grow out of bounds because more lines are added\nthan may be truncated on each run unless\n" . ACCOUNTLIST . " has blank lines\n";
}


close $outfile;


file2mail(OUTFILE, FROM, RCPT, 'Email Quota Check, ' . localtime(time));


exit 0;
