#!/usr/bin/env perl

# v1.0
# Parse through IMAP and POP3 *.in *.out rawlogs and try to figure out which
# messages aren't found from each others' output. Probably not very useful
# if using a Dovecot version with
# http://hg.dovecot.org/dovecot-2.2/rev/b51dfee18fd2
# Also doesn't support LIST reply yet, added by
# http://hg.dovecot.org/dovecot-2.2/rev/4bebfbb32410
#
# Usage: <path to imap rawlog in|out file> <path to pop3 rawlog in|out file>

use strict;
use Digest::MD5 qw(md5);

my $imap_file = $ARGV[0];
my $pop3_file = $ARGV[1];

$imap_file =~ s/\.(in|out)$//;
$pop3_file =~ s/\.(in|out)$//;

my ($imap_in, $pop3_in, $pop3_out);

(open $imap_in, "<$imap_file.in") or die "$imap_file.in: $!";
(open $pop3_in, "<$pop3_file.in") or die "$pop3_file.in: $!";
(open $pop3_out, "<$pop3_file.out") or die "$pop3_file.out: $!";

my %headers;
my $hdr_seq = 0;
my $hdr_uid = 0;
my $hdr = "";
my @imap_sizes;
while (<$imap_in>) {
  s/^\d+\.\d+ //; # strip timestamp
  
  if (/\* (\d+) FETCH \(UID (\d+) BODY\[HEADER\] /) {
    ($hdr_seq, $hdr_uid) = ($1, $2);
  } elsif (/\* (\d+) FETCH \(UID (\d+) RFC822.SIZE (\d+)\)/) {
    $imap_sizes[$1] = $3;
  } elsif ($hdr_seq != 0) {
    if ($_ eq ")\r\n") {
      my $hdr_md5 = md5($hdr);
      $headers{$hdr_md5} = \($hdr, $hdr_seq, $hdr_uid);
      $hdr_seq = 0;
      $hdr_uid = 0;
      $hdr = "";
    } else {
      $hdr .= $_;
    }
  }
}
my %uidl;
my $linenum = 0;
my $pop3_sizes_ok = 1;
my $pop3_size_seq = 0;
my @pop3_matches;
my %pop3_missing;
while (<$pop3_out>) {
  s/^\d+\.\d+ //; # strip timestamp
  $linenum++;
  my $in_line = $_;
  
  my $ok = 0;
  if (/^USER /i || /^PASS/i) {
    <$pop3_in>; # +OK expected
    $ok = 1;
  } elsif (/^CAPA/) {
    while (<$pop3_in>) {
      s/^\d+\.\d+ //; # strip timestamp
      if ($_ eq ".\r\n") {
	$ok = 1;
	last;
      }
    }
  } elsif (/^UIDL/) {
    <$pop3_in>; # +OK
    while (<$pop3_in>) {
      s/^\d+\.\d+ //; # strip timestamp
      if ($_ eq ".\r\n") {
	$ok = 1;
	last;
      }
      die "Unknown input line $linenum: $_" if (!/^(\d+) (.*)\r/);
      $uidl{$1} = $2;
    }
  } elsif (/^TOP (\d+) /) {
    my $seq = $1;
    $hdr = "";
    <$pop3_in>; # +OK
    while (<$pop3_in>) {
      s/^\d+\.\d+ //; # strip timestamp
      if ($_ eq ".\r\n") {
	$ok = 1;
	last;
      }
      s/^\.//;
      $hdr .= $_;
    }
    die if !$ok;
    if (!defined($pop3_matches[$seq])) {
      my $hdr_md5 = md5($hdr);
      if (defined($headers{$hdr_md5})) {
	$pop3_matches[$seq] = 1;
      } else {
	$pop3_missing{$seq} = $hdr;
      }
    }
  } elsif (/^RETR (\d+)/) {
    my $seq = $1;
    my $size = 0;
    <$pop3_in>; # +OK
    while (<$pop3_in>) {
      s/^\d+\.\d+ //; # strip timestamp
      if (/^\.\r/) {
	$ok = 1;
	last;
      }
      $size += length($_);
    }
    if (!$pop3_sizes_ok) {
    } elsif ($imap_sizes[$seq] == $size && 
	     (!defined($imap_sizes[$seq+1]) || 
	      $imap_sizes[$seq+1] != $size)) {
      $pop3_matches[$seq] = 1;
      $pop3_size_seq = $seq;
    } else {
      $pop3_sizes_ok = 0;
    }
  }
  if (!$ok) {
    die "Invalid input in $pop3_file.out line $linenum: $in_line\n";
  }
}

foreach my $seq (sort keys %pop3_missing) {
  print "Missing pop3 msg: seq=$seq uidl=$uidl{$seq} hdr=\n";
  print $pop3_missing{$seq}."---\n";
}

print "\n";
print (scalar keys %headers);
print " IMAP messages found.\n";

print (scalar keys %uidl);
print " POP3 messages found, $pop3_size_seq found via size matches, ";
print (scalar keys %pop3_missing);
print " missing.\n";
