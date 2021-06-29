#!/usr/bin/env perl

# run also director-test-admin.sh

use IO::Socket::UNIX;
use Time::HiRes qw( usleep gettimeofday tv_interval );
use MIME::Base64;
use strict;

my $director_count = 4;
my $requests_per_sec = 10000;
my $total_num_users = 1000000;
# v2.2.17+ way of doing fast lookups without auth process:
my $authreply_socket = 1;

my @sockets;

sub socket_handshake {
  my $socknum = $_[0];
  my $socket = $sockets[$socknum];
  
  my $socket_pid = $socknum.$$;
  if ($authreply_socket) {
    print $socket "VERSION\tdirector-authreply-client\t1\t1\n";
    my $version_line = <$socket>;
    die if $version_line !~ /^VERSION\tdirector-authreply-server\t1\t/;
    return;
  }

  print $socket "VERSION\t1\t1\nCPID\t$socket_pid\n";
  
  my $version_line = <$socket>;
  die if $version_line !~ /^VERSION\t1\t/;
  while (<$socket>) {
    chomp;
    if (/^SPID\t/) {
    } elsif (/^CUID\t/) {
    } elsif (/^COOKIE\t/) {
    } elsif (/^MECH\t/) {
    } elsif (/^DONE$/) {
      last;
    } else {
      die "Unknown server input: $_";
    }
  }
  print "$socknum handshaked\n";
}

sub send_request {
  my ($socknum, $username) = @_;
  my $socket = $sockets[$socknum];
  my $resp = encode_base64("\0$username\0pass", "");
  
  if (!$authreply_socket)  {
    print $socket "AUTH\t$socknum\tPLAIN\tservice=test\tresp=$resp\n";
  }  else {
    print $socket "OK\t$socknum\tproxy\tuser=$username\n";
  }
  $_ = <$socket>;
  die if (!$_);
  chomp;
  if (/^OK\t$socknum\t(.*)$/) {
    my @args = split "\t", $1;
  } elsif (/^FAIL\t/) {
    print STDERR "Unexpected input: $_\n";
  } else {
    die "Failed: $_";
  }
}

for (my $socknum = 1; $socknum <= $director_count; $socknum++) {
  my $name = "/var/run/dovecot/director$socknum-authreply";
  $sockets[$socknum] = IO::Socket::UNIX->new(
    Type => SOCK_STREAM,
    Peer => $name,
  );
  die "Can't create socket $name: $!" unless $sockets[$socknum];
  
  socket_handshake($socknum);
}

my $sleep_per_requests = 100;
my $wait_usecs = 1000000/($requests_per_sec/$sleep_per_requests);
for (;;) {
  my $t0 = gettimeofday();

  for (my $i = 0; $i < $requests_per_sec; $i++) {
    my $username = "user".int(rand($total_num_users));
    # for trying to break weak users with director_user_expire=2min:
    #my $username = "user".(($t0 % (115)) * 100 + int(rand(1000)));
    send_request(($i % $director_count) + 1, $username);
    send_request((($i+$director_count/2) % $director_count) + 1, $username);
    if ($wait_usecs >= 1 && ($i % $sleep_per_requests) == 0) {
      usleep($wait_usecs);
    }
  }

  my $elapsed_secs = gettimeofday() - $t0;
  my $elapsed_usecs = int($elapsed_secs * 1000000);
  if ($elapsed_usecs > 1000000) {
    $wait_usecs -= (($elapsed_usecs - 1000000) / ($requests_per_sec/$sleep_per_requests)) / 2;
    $wait_usecs = 0 if ($wait_usecs < 0);
  } elsif ($elapsed_usecs < 1000000) {
    $wait_usecs += ((1000000 - $elapsed_usecs) / ($requests_per_sec/$sleep_per_requests)) / 2;
    $wait_usecs = 1 if ($wait_usecs == 0);
  }
  $wait_usecs = int($wait_usecs);
  printf("$requests_per_sec in %02fs (wait=$wait_usecs us)\n", $elapsed_secs);
}
