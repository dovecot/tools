#!/usr/bin/env perl
use strict;

# maildir-obfuscate.pl < maildir-file > maildir-file.obfuscated
# Check with text editor that everything appears to be obfuscated.
# This script isn't perfect..

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
  } elsif ($state == 1) {
    # mail body
    if (/^--(.*)$/ && find_boundary($1)) {
      if ($2 eq "") {
	# mime header
	$state = 0;
      }
      print "$_\n";
    } else {
      print obs($_)."\n";
    }
  }
}
