#!/usr/bin/env perl

use strict;
use warnings;

my %meta;
my $version = 0;
my $DBOX_MAGIC_PRE = "\001\002";
my $DBOX_MAGIC_POST = "\001\003";
my $fh;

sub open_fh {
  if (scalar @ARGV > 0) {
    open FH, "+<", $ARGV[0];
    $fh = \*FH;
  } else {
    $fh = \*STDIN;
  }
  binmode $fh;
}

sub read_metadata {
  my $seen_magic_post = 0;
  my $hdr_size;
  my $stamp;
  while(<$fh>) {
    chomp;
    next if ($_ eq '');

    ## Section: Reading the file header
    if ($version == 0) {
      ($version, $hdr_size, $stamp) = split / /;
      unless ($version == 2 and substr($hdr_size,0,1) eq 'M' and substr($stamp,0,1) eq 'C') {
	print($version, substr($hdr_size,0,1), substr($stamp,0,1), "\n");
        die "File does not seem to be DBOX file";
      }
      $hdr_size = substr $hdr_size, 1;
      $meta{'header_size'} = hex("0x$hdr_size");
      $stamp = substr $stamp, 1;
      $meta{'create_timestamp'} = hex("0x$stamp");
      next;
    }

    ## Section: Reading the start of file metadata
    if (substr($_, 0, 2) eq $DBOX_MAGIC_PRE) {
      # next is flags and message size
      my ($flags, $msg_size) = split / +/, substr $_, 2;
      $meta{'flags'} = $flags;
      $meta{'message_size'} = hex("0x$msg_size");
      return;
    }

    ## Section: Reading the end of file meta
    if (not $seen_magic_post) {
      die "Not a DBOX file" unless($_ eq $DBOX_MAGIC_POST);
      $seen_magic_post = 1;
      next;
    }
    my ($key, $value) = /^(\w)(.+)/;
    $key = 'guid' if $key eq 'G';
    $key = 'pop3_uidl' if $key eq 'P';
    $key = 'pop3_order' if $key eq 'O';
    $key = 'original_mailbox' if $key eq 'B';
    if ($key eq 'R') {
      $key = 'received_time';
      $value = hex("0x$value");
    }
    if ($key eq 'V') {
      $key = 'virtual_size';
      $value = hex("0x$value");
    }
    if ($key eq 'Z') {
      $key = 'physical_size';
      $value = hex("0x$value");
    }
    $meta{$key} = $value;
  }
}

open_fh;
read_metadata;
# the real header size is the size of header line,
# flags and message size
$meta{'real_header_size'} = tell $fh;
close $fh;
open_fh;
# reopen file to read the actual message
my $msg;
seek $fh, $meta{'real_header_size'}, 0;
read $fh, $msg, $meta{'message_size'};
close $fh;
# reopen file once more to read the post meta
open_fh;
seek $fh, $meta{'message_size'} + $meta{'real_header_size'}, 0;
read_metadata;

# print all metadata to stderr
foreach my $key (keys %meta) {
  print STDERR "$key = $meta{$key}\n";
}

# print actual message to stdout
binmode STDOUT;
print $msg;
