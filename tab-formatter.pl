#!/usr/bin/env perl

# pretty much what "column -t" does

my @lengths;
my @data;

$lengths[0] = 35; # min width of first field

while (<>) {
  chop;
  my @fields = split "\t";
  for (my $i = 0; $i < scalar @fields; $i++) {
    my $len = length($fields[$i]);
    if (!defined($lengths[$i]) || $lengths[$i] < $len) {
      $lengths[$i] = $len;
    }
  }
  push @data, \@fields;
}

foreach my $data (@data) {
  my @fields = @{$data};
  for (my $i = 0; $i < scalar @fields; $i++) {
    my $len = length($fields[$i]);
    print $fields[$i];
    print " "x($lengths[$i]-$len+1);
  }
  print "\n";
}