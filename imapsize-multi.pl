#!/usr/bin/perl

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
# Check email account(s) via IMAP for how many messages there are and
# compute their total size.  Compute "percentage full" of each
# account, using the specified size-quota, and send an informative
# email about usage.
#
#
# usage:
#
# + adjust settings below
# + create a file listing the IMAP accounts to check, for example:
#
# server1.example.com, user1@example.com, password_user1
# server2.example.com, user2@example.com, password_user2
#
# + make sure the passwords cannot be read by unauthorized users!
# + run the script --- you may need to install additional perl modules
# + you can run the script from your contab to check the accounts regularly
#
# This version assumes that all accounts have the same quota-size
# limit and sends email only to one given recipient, so adjust to your
# requirements.
#
#
# TODO:
#
# + write info to log file for statistical purposes
#
# + create a single summary email instead of sending many to the same
#   recipient and optionally send email per account to inform users


use strict;
use warnings;
use autodie;
use Net::IMAP::Client;
use MIME::Lite;
use String::Util qw(trim);


# SETTINGS
#
# list of emailaccounts
# entries are SERVER, USERNAME, PASSWORD
# items must be seperated by comma
use constant ACCOUNTLIST => "acctlst";

# send email with quota information from, to
#
use constant RCPT => 'recipient@example.com';
use constant FROM => 'sender@example.com';

# give warning instead of info when quota is almost reached
#
use constant QUOTA_WARNING_PERCENT => 85.0;

# quota limit in bytes
#
use constant QUOTA_BYTES => 2 * 1024 * 1024 * 1024;
# / SETTINGS


# go through each account given and check
#
sub chkacct {
  my ($server, $username, $pass) = @_;


  # create new imap connection ...
  #
  my $imap = Net::IMAP::Client->new(
				    server => $server,
				    user => $username,
				    pass => $pass,
				    ssl => 1,
				    ssl_verify_peer => 0,
				    port => 993)
    or die "connection to imap server failed";

  # ... and log in
  #
  return 1 unless $imap->login;
# or die "no login for $username";


  # request all folders
  #
  my @folders = $imap->folders;
  my $msgsize = 0;
  my $nm = 0;
  #
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


  # generate email message
  #
  my $msgbody = "Email Quota check: $username auf $server\n\n";

  my $megabyte = int($msgsize / 1024 / 1024 + 0.5);
  my $percent_quota = int($msgsize * 100.0 / QUOTA_BYTES + 0.5);

  $msgbody .= $nm . " Emails\n". $msgsize . " bytes (~". $megabyte . "MB)\n~" . $percent_quota . "% voll\n";

  my $subj = "Email quota check: ~ $percent_quota% ($username auf $server)";
  if ($percent_quota >= QUOTA_WARNING_PERCENT) {
    $subj = "Email quota WARNING";
    $msgbody .= "\nWARNUNG: Das Postfach ist bald voll!\n";
  }


  # send info as email
  #
  my $semail = MIME::Lite->new(
			       From     => FROM,
			       To       => RCPT,
			       Subject  => $subj,
			       Data     => $msgbody
			      );

  $semail->send;
  return 0;
}


my $linecount = 0;
open my $fh, "<", ACCOUNTLIST;
while (my $line = <$fh>) {
  $linecount++;
  chomp $line;
  if (length $line) {
    my ($srv, $usr, $pwd) = split(',', $line);
    trim($srv);
    trim($usr);
    trim($pwd);
    if (length($srv) && length($usr) && length($pwd)) {
      if(1 == chkacct($srv, $usr, $pwd))
	{
	  print "login for $usr ($srv) failed\n";
	}
    } else {
      printf("syntax error in line %8d\n", $linecount);
    }
  }
}
close $fh;

exit 0;
