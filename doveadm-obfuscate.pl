#!/usr/bin/env perl

while (<>) {
  chop $_;
  $origlen = length $_;

  $suffix="";
  if (/^text:/) {
    # From_ line
    $hdr=1;
    $prefix="";
    $suffix="";
  } elsif ($hdr) {
    # header
    if (/^([\t ]+)(.*)$/) {
      # continues from previous line
      $prefix=$1;
      $value=$2;
    } elsif (/^([^:]*)(:.*)$/) {
      # new header
      $prefix=$1;
      $value=$2;
      if ($prefix =~ /^(X-UID|X-IMAP|X-Keywords|X-Status|Status|Content|Date|--)/) {
	# keep this header as-is
	$prefix .= $value;
	$value="";
      }
    } else {
      $prefix=$_;
      $value="";
      $hdr = 0;
    }
  } else {
    # body
    $prefix="";
    $value=$_;
  };
  $value =~ s/\w/x/g;
  print "$prefix$value$suffix\n";
}
