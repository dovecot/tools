#!/usr/bin/env perl
use strict;

# Usage mdbox-recover.pl m.123
# Try to extract as many mails from the input mdbox file as possible
# and write them to separate msg.* files in the current directory.

my $STATE_META = 0;
my $STATE_BODY = 1;
my $BYTES_MAX = 4096;

my $offset = 0;
my ($fin, $fout);

my $state = $STATE_META;
my $msgnum = 1;
open($fin, "<$ARGV[0]") || die "$!";
open($fout, ">msg.$msgnum") || die "$!";

while (1) {
  my $data;
  seek($fin, $offset, 0);
  my $bytes = read($fin, $data, $BYTES_MAX);
  last if ($bytes <= 0);
  
  my $idx = index($data, "\001\002N          00000000");
  my $idx2 = index($data, "\n\001\003\n");
  if ($idx != -1 && $idx + 50 > $bytes && $bytes == $BYTES_MAX) {
    $bytes -= 50;
    $data = substr($data, 0, $bytes);
    $idx = -1;
  }
  if ($idx != -1 && ($idx2 == -1 || $idx < $idx2)) {
    # pre-magic found. skip over it and we'll start writing the mail
    $idx2 = index(substr($data, $idx), "\n");
    #print "begin $offset $idx $idx2\n";
    if ($idx2 != -1) {
      # successfully skipped over the metadata headers
      $bytes = $idx + $idx2 + 1;
      if ($state == $STATE_META) {
	$state = $STATE_BODY;
      } else {
	# end of metadata block missing, finish the previous mail
	print $fout substr($data, 0, $idx);
      }
    } else {
      # truncated / broken data? just keep writing to previous file
      print $fout $data;
    }
  } elsif ($idx2 == -1 && $state == $STATE_META && $bytes < $BYTES_MAX) {
    # trailing metadata in file, skip
  } else {
    $idx = $idx2;
    if ($idx + 50 > $bytes && $bytes == $BYTES_MAX) {
      # check again in next loop
      $idx = -1;
    }
    if ($idx == -1 && $bytes == $BYTES_MAX) {
      # leave some extra to find the pre/post magics
      $bytes -= 50;
      $data = substr($data, 0, $bytes);
    }
    #print "end $offset $bytes $idx\n" if ($idx >= 0);
    if ($idx != -1 && substr($data, $idx + 4, 2) =~ /[ZR][0-9a-f]/) {
      # end of message, start new one
      #print "ok ".substr($data, $idx + 4, 100)."\n";
      $bytes = $idx + 4;
      print $fout substr($data, 0, $idx);
      
      close $fout; $msgnum++;
      open($fout, ">msg.$msgnum") || die "$!";
      $state = $STATE_META;
    } else {
      # continue writing to file
      print $fout $data;
    }
  }
  $offset += $bytes;
}
if (tell($fout) == 0) {
  unlink("msg.$msgnum");
}
close $fin;
close $fout;
