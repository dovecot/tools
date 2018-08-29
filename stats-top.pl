#!/usr/bin/env perl
use strict;
use File::Temp;

# config:
my $lines = 20; # how many lines to print (terminal height)
my $window_secs = 5; # show values' diff of last 5 secs
my $timestamp = `date +%s` - 60; # show only recently updated users
my $dump_script = "doveadm stats dump user since=$timestamp";

my $scriptdir = $0; $scriptdir =~ s,^(.*)/.*$,$1,;
my $stats_path = "$scriptdir/stats.pl";
my $tab_formatter_path = "$scriptdir/tab-formatter.pl";

# usage: doveadm-top.pl [parameters to stats.pl]
#
# Example: sort by cpu and show also user/sys cpus:
#   doveadm-top.pl -s cpu -e user_cpu -e sys_cpu

# code:
my $tmp_dir = mkdtemp("/tmp/dovecot-stats-XXXX");
sub cleanup {
  system "rm -rf $tmp_dir";
  exit(1);
};
$SIG{'INT'} = 'cleanup';

my $last_num = 1;
my $stats_args = join(" ", @ARGV);

sub add_total {
  my $path = $_[0];
  
  my $f;
  open $f, "<$path";
  my $hdr = <$f>;
  my @total;
  while (<$f>) {
    chop;
    my @fields = split "\t";
    for (my $i = 0; $i < scalar @fields; $i++) {
      if ($fields[$i] =~ /^[0-9]+(\.[0-9]+)?$/) {
	$total[$i] += $fields[$i];
      }
    }
    print "$_\n";
  }
  my $str = "TOTAL";
  for (my $i = 1; $i < scalar @total; $i++) {
    $str .= "\t".$total[$i];
  }
  $str .= "\n";
  close $f;
  
  open $f, ">>$path";
  print $f $str;
  close $f;
}

system "$dump_script > $tmp_dir/1";
sleep 1;

while (1) {
  my $i = $last_num < $window_secs ? $last_num : $window_secs-1;
  for (my $i = $last_num; $i > 0; $i--) {
    rename("$tmp_dir/$i", "$tmp_dir/".($i+1));
  }
  $last_num++ if ($last_num < $window_secs);
  system "$dump_script > $tmp_dir/1";
  system "$stats_path $stats_args $tmp_dir/$last_num $tmp_dir/1 2>&1 | head -$lines > $tmp_dir/output";
  add_total("$tmp_dir/output");
  system "clear;cat $tmp_dir/output | $tab_formatter_path";
  sleep 1;
}
