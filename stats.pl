#!/usr/bin/env perl
use strict;

# usage: stats.pl [parameters] <file1> [<file2>]
#
# If running with only one file, shows the file's contents sorted by wanted
# field. If running with two files, shows and sorts the the difference of the
# values.
#
# Parameters:
#   -s <sort field>: Field to sort by, e.g. disk_io, cpu
#   -g <group field>: doveadm dump type (session, user, domain)
#   -e <extra field>: Show also this field in output
#
# Example #1, show which user is using the most disk IO currently:
#
#   doveadm dump user > user1
#   sleep 2
#   doveadm dump user > user2
#   stats.pl user1 user2
#
# Example #2, show which user is using the most CPU currently:
#
#   doveadm dump user > user1
#   sleep 2
#   doveadm dump user > user2
#   stats.pl -s cpu user1 user2

my $group_field = "user";
my $sort_field = "disk_io";

my @calc_fields = (
  "cpu",
  "disk_io"
);

my @extra_fields;
while (1) {
  if ($ARGV[0] eq "-g") {
    shift;
    $group_field = shift;
  } elsif ($ARGV[0] eq "-s") {
    shift;
    $sort_field = shift;
  } elsif ($ARGV[0] eq "-e") {
    shift;
    push @extra_fields, shift;
  } elsif ($ARGV[0] =~ /^-/) {
    die "Unknown parameter: ".$ARGV[0];
  } else {
    last;
  }
}

my $fname1 = shift @ARGV;
my $fname2 = shift @ARGV;

die "Too many command parameters" if scalar @ARGV != 0;

my ($f1, $f2);

open $f1, "<$fname1" || die "Can't open $fname1";
if ($fname2) {
  open $f2, "<$fname2" || die "Can't open $fname2";
}
my @in_fields = split "\t", <$f1>;
my @fields = ( @in_fields, @calc_fields );

my %data;

my ($disk_input_idx, $disk_output_idx, $user_cpu_idx, $sys_cpu_idx);
my $group_idx = -1;
my $sort_idx = -1;
for (my $i = 0; $i < scalar @fields; $i++) {
  if ($fields[$i] eq $group_field) {
    $group_idx = $i;
  } elsif ($fields[$i] eq $sort_field) {
    $sort_idx = $i;
  } elsif ($fields[$i] eq "user_cpu") {
    $user_cpu_idx = $i;
  } elsif ($fields[$i] eq "sys_cpu") {
    $sys_cpu_idx = $i;
  } elsif ($fields[$i] eq "disk_input") {
    $disk_input_idx = $i;
  } elsif ($fields[$i] eq "disk_output") {
    $disk_output_idx = $i;
  }
}

die "Unknown -s field: $sort_field" if ($sort_idx < 0);
die "Unknown -g field: $group_field" if ($group_idx < 0);

my @extra_fields_idx;
foreach my $name (@extra_fields) {
  for (my $i = 0; $i < scalar @fields; $i++) {
    if ($fields[$i] eq $name) {
      push @extra_fields_idx, $i;
      last;
    }
  }
}

sub get_line {
  my $line = $_[0];
  chop $line;

  my @values = split "\t", $line;
  # cpu
  push @values, ($values[$user_cpu_idx] + $values[$sys_cpu_idx]);
  # disk io
  push @values, ($values[$disk_input_idx] + $values[$disk_output_idx]);
  return @values;
};

sub diff_values {
  my @v1 = @{$_[0]};
  my @v2 = @{$_[1]};
  
  my @diff;
  for (my $i = 0; $i < scalar @fields; $i++) {
    if ($i == $group_idx) {
      die if $v1[$i] ne $v2[$i];
      $diff[$i] = $v1[$i];
    } elsif ($v1[$i] =~ /^[0-9\.]+$/) {
      $diff[$i] = $v2[$i] - $v1[$i];
    } else {
      $diff[$i] = $v1[$i];
    }
  }
  return @diff;
}

sub prettify_value {
  my $value = $_[0];
  
  # truncate to two decimals
  $value =~ s/^([0-9]+\.[0-9]{2})[0-9]+$/$1/;
  return $value;
}

my $linenum = 2;
while (<$f1>) {
  my @line = get_line($_);

  my $group_value = $line[$group_idx];
  die "Duplicate $group_field in $fname1:$linenum: '$group_value'"
    if defined($data{$group_value});
  
  $linenum++;
  $data{$group_value} = \@line;
}

if ($fname2) {
  my %found;
  
  my @f2_in_fields = split "\t", <$f2>;
  for (my $i = 0; $i < scalar @in_fields; $i++) {
    die "Mismatching headers" if ($in_fields[$i] ne $f2_in_fields[$i]);
  }
  
  $linenum = 2;
  while (<$f2>) {
    my @line = get_line($_);

    my $group_value = $line[$group_idx];
    next if !defined($data{$group_value});
    
    die "Duplicate $group_field in $fname2:$linenum: '$group_value'" 
      if $found{$group_value};
    
    $found{$group_value} = 1;
    my @diff = diff_values($data{$group_value}, \@line);
    $data{$group_value} = \@diff;
    $linenum++;
  }
  foreach my $key (keys %data) {
    delete $data{$key} if (!$found{$key});
  }
}

print STDERR "$group_field\t$sort_field";
foreach my $ei (@extra_fields_idx) {
  print STDERR "\t".$fields[$ei];
}
print STDERR "\n";

foreach my $key (reverse sort {$data{$a}->[$sort_idx] <=> $data{$b}->[$sort_idx] } keys %data) {
  my @values = @{$data{$key}};
  my $sort_value = $values[$sort_idx];
  print "$key\t";
  print prettify_value($sort_value);
  foreach my $ei (@extra_fields_idx) {
    print "\t".prettify_value($values[$ei]);
  }
  print "\n";
}
