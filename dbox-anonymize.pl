#!/usr/bin/env perl

my $text = 0;
while (<>) {
  if (/^\001\002/) {
    $text = 1;
    print $_;
    $hdr = 1;
    next;
  }
  if (/^\001\003/) {
    $text = 0;
    print $_;
    next;
  }
  $hdr = 0 if (/^$/);
  if ($text) {
    my $key = 1;
    $key = 0 if (substr($_, 0, 1) =~ /[ \t]/);
    my $len = length($_);
    for ($i = 0; $i < $len; $i++) {
      my $chr = substr($_, $i, 1);
      if ($hdr && $key) {
	print $chr;
	$key = 0 if ($chr eq ":");
      } elsif ($chr =~ /[ \t,.;<>:\[\]]/ && $hdr) {
	print $chr;
      } else {
	print "x";
      }
    }
    print "\n";
  } else {
    print $_;
  }
}
