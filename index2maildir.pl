#!/usr/bin/env perl

# Use like: doveadm dump dovecot.index|index2maildir.pl ~/Maildir-test
# Mainly useful for debugging other peoples' index file problems

use strict;

my $uidv = 0;
my $nextuid = 0;
my $dir = $ARGV[0];

if ($dir eq "") {
  die "Give dest maildir directory as parameter";
}
die "$dir already exists" if (-e $dir);

while (<STDIN>) {
  if (/^uid validity .* = (\d+) /) {
    $uidv = $1;
  } elsif (/^next uid .* = (.*)$/) {
    $nextuid = $1;
  } else {
    last if (/^-- RECORDS:/);
  }
}

if ($uidv == 0 || $nextuid == 0) {
  die "Give index dump output in stdin";
}

mkdir $dir || die "Can't create $dir";
mkdir "$dir/tmp";
mkdir "$dir/new";
mkdir "$dir/cur";

my $f;
open $f, ">$dir/dovecot-uidlist" || die "Can't create uidlist";
print $f "3 V$uidv N$nextuid\n";

while (<STDIN>) {
  if (/^RECORD: .*uid=(\d+), flags=(.*)$/) {
    my $uid = $1;
    my $flags = $2;
    my $fname = "u$uid";
    print $f "$uid :$fname\n";
    
    my ($mf, $destdir);
    if ($flags =~ /Recent/) {
      $destdir = "$dir/new";
    } else {
      $destdir = "$dir/cur";
    }
    open $mf, ">$destdir/$fname";
    close $mf;
  }
}
close $f;

print "Converted index input to Maildir in $dir\n";
