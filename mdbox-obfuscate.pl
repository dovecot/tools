#!/usr/bin/env perl
use strict;

# mdbox-obfuscate.pl < ~/mdbox/storage/m.1 > m.obfuscated
# Check with text editor that everything appears to be obfuscated.
# This script isn't perfect..

# For testing that you can reproduce problem:
# mkdir -p ~/mdbox-test/storage
# cp m.obfuscated ~/mdbox-test/storage/m.1
# doveadm -o mail=mdbox:~/mdbox-test force-resync INBOX
# /usr/local/libexec/dovecot/imap -o mail=mdbox:~/mdbox-test

my $state = 0;
my $hdr_name = "";
my @boundaries = ();

sub obs {
  my $len = length($_[0]);
  return "x"x$len;
}

sub find_boundary {
  my $str = $_[0];
  $str =~ s/--$//;
  
  foreach $b (@boundaries) {
    return 1 if $b eq $str;
  }
  return 0;
}

while (<>) {
  chop $_;
  if ($state == 0) {
    # file header
    die "Not a valid dbox" if !/^2 /;
    print "$_\n";
    $state++;
  } elsif ($state == 1) {
    # dbox mail header
    die "Invalid mail header" if !/^\001\002/;
    print "$_\n";
    @boundaries = ();
    $state++;
  } elsif ($state == 2) {
    # mail header
    my ($key, $ws, $value);
    my $continued = 0;
    if (/^([ \t])(.*)$/) {
      $key = $hdr_name;
      $ws = $1;
      $value = $2;
      $continued = 1;
    } elsif (/^([^:]+)(:[ \t]*)(.*)$/) {
      ($key, $ws, $value) = ($1, $2, $3);
      $hdr_name = $key;
    } elsif (/^$/) {
      print "\n";
      $state++;
      next;
    } else {
      print obs($_)."\n";
      next;
    }
    
    if ($key =~ /^Content-/i && $key !~ /^Content-Description/i) {
      if ($key =~ /^Content-Type/) {
	if ($value =~ /boundary="([^"]+)"/i || $value =~ /boundary=([^ \t]+)/i) {
	  push @boundaries, $1;
	}
      }
      $_ =~ s/(name=")([^"]*)(")/$1.obs($2).$3/ge;
      $_ =~ s/(name=)([^ \t]*)/$1.obs($2)/ge;
      print "$_\n";
    } else {
      print $key if (!$continued);
      print $ws.obs($value)."\n";
    }
  } elsif ($state == 3) {
    # mail body
    if (/^\001\003$/) {
      print "$_\n";
      $state++;
    } elsif (/^--(.*)$/ && find_boundary($1)) {
      if ($2 eq "") {
	# mime header
	$state = 2;
      }
      print "$_\n";
    } else {
      print obs($_)."\n";
    }
  } elsif ($state == 4) {
    # dbox metadata
    if (/^$/) {
      $state = 1;
    }
    print "$_\n";
  }
}
