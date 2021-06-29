#!/usr/bin/env perl

# v1.1.8

# Migrate Courier IMAP (any version) and Courier POP3 (v0.43+) to Dovecot v1.0
# by Timo Sirainen. This is public domain.

# Usage: [--quiet] [--convert] [--overwrite] [--recursive] [<conversion path>]
#   --quiet: Print only errors
#   --convert: Do the actual conversion. Without this it only shows if it works.
#   --overwrite: Ovewrite dovecot-uidlist file even if it exists already.
#   --recursive: Recursively find maildirs to convert
#   <conversion path>: Maildir directory, or with --recursive its parent
#                      directory or its parent's parent

#  - If courierpop3dsizelist is found, it makes its best effort to keep the
#    POP3 UIDLs, unless the file is more than 30 days older than
#    courierimapuiddb (user probably stopped using POP3).
#  - If an old format courierpop3dsizelist is found, it's ignored if the file
#    is older than 180 days (unless you're using an old Courier version,
#    the old format files mean that the user hasn't logged in for ages)
#  - If courierpop3dsizelist isn't found (or it's old), the dovecot-uidlist
#    is directly converted keeping all the UIDs.
#  - Keywords are converted from courierimapkeywords/ to maildir filename
#    flags and dovecot-keywords file
#  - Subscriptions from courierimapsubscribed are added to Dovecot's
#    subscriptions file. Note that you don't want to keep the INBOX. prefixes
#    even if you're using a INBOX. namespace with Dovecot.

use strict;
use warnings;
use POSIX;

my $imap_uidfile = "courierimapuiddb";
my $pop3_uidfile = "courierpop3dsizelist";
my $pop3_stale_uidlist_secs = 3600*24*30; # 30 days
my $pop3_oldformat_stale_uidlist_secs = 3600*24*180; # 180 days

my $do_conversion = 0;
my $quiet = 0;
my $recursive = 0;
my $overwrite = 0;

my $depth = 1;
my $maildir_subdirs = -1;
my $global_error_count = 0;
my $global_pop3_change_count = 0;
my $global_imap_change_count = 0;
my $global_pop3_mailbox_count = 0;
my $global_imap_mailbox_count = 0;
my $global_pop3_user_count = 0;
my $global_imap_user_count = 0;
my $uidlist_write_count = 0;

sub scan_maildir {
  my ($dir, $map) = @_;
  
  opendir my $dh, $dir || die $!;
  foreach (readdir($dh)) {
    next if ($_ eq "." || $_ eq "..");
   
    my $base_fname;
    if (/^([^:]+):2,/) {
      ($base_fname) = ($1);
    } else {
      $base_fname = $_;
    }
    $$map{$base_fname} = 1;
  }
  closedir $dh;
}

sub scan_curnew {
  my ($dir, $map) = @_;
  
  return if (scalar keys %$map > 0);
  
  $$map{'.'} = 1; # just to make sure the map is never empty
  scan_maildir("$dir/new", $map);
  scan_maildir("$dir/cur", $map);
}

sub read_courier_pop3 {
  my ($dir, $curnew_map, $mtime) = @_;
  
  my ($pop3_uidv, $pop3_nextuid) = (-1, 0);
  my %filename_map;

  my $f;
  my $pop3_fname = "$dir/$pop3_uidfile";
  open ($f, $pop3_fname) || die $!;
  my $pop3_hdr = <$f>;
  if ($pop3_hdr =~ /^\/2 (\d+) (\d+)$/) {
    $pop3_nextuid = $1;
    $pop3_uidv = $2;
  } elsif ($pop3_hdr !~ /^\//) {
    # plain UIDs
    $pop3_uidv = 0;
    # ignore the file if it's too old
    return (-1, 0) if (time - $mtime > $pop3_oldformat_stale_uidlist_secs);
  } else {
    print STDERR "$pop3_fname: Broken header: $pop3_hdr\n";
    close $f;
    return (-1, 0);
  }
  my %uidvals;
  
  my $max_uidv = -1;
  my $max_uidv_count = 0;
  my $max_uidv_nextuid = 0;
  
  my $curnew_read = 0;
  $curnew_read = 1 if (scalar keys %$curnew_map > 0);
  
  while (<$f>) {
    chomp $_;
    
    if ($pop3_uidv > 0 && /^([^ ]+) (\d+) (\d+):(\d+)$/) {
      my ($fname, $fsize, $uid, $uidv) = ($1, $2, $3, $4);
      # get base filename
      $fname =~ s/^([^:]+).*$/$1/;
      
      next if ($curnew_read && !defined($$curnew_map{$fname}));
      
      if ($uid == 0) {
	# use filename
	$filename_map{$fname} = $fname;
      } else {
	$filename_map{$fname} = "$uidv:$uid";
	$uidvals{$uidv}++;
	if ($uidvals{$uidv} > $max_uidv_count) {
	  $max_uidv = $uidv;
	  $max_uidv_count = $uidvals{$uidv};
	  $max_uidv_nextuid = $uid;
	}
      }
    } elsif ($pop3_uidv == 0 && /^([^ ]+) (\d+)$/) {
      my ($fname, $uid) = ($1, $2);
      $fname =~ s/^([^:]+).*$/$1/;
      
      next if ($curnew_read && !defined($$curnew_map{$fname}));
      $filename_map{$fname} = $uid;
    } else {
      $global_error_count++;
      print STDERR "$pop3_fname: Broken line: $_\n";
    }
  }
  close $f;
  
  if ($max_uidv == $pop3_uidv && $max_uidv_nextuid < $pop3_nextuid) {
    $max_uidv_nextuid = $pop3_nextuid;
  }
  
  my $mail_count = scalar keys %filename_map;
  if ($mail_count != $max_uidv_count && !$curnew_read) {
    # read the maildir and try again. if some of the files are already
    # deleted, we can ignore them
    scan_curnew($dir, $curnew_map);
    return read_courier_pop3($dir, $curnew_map, $mtime);
  }
  if ($mail_count != $max_uidv_count) {
    $global_pop3_change_count += $mail_count - $max_uidv_count;
    $global_pop3_mailbox_count++;
    if (!$quiet) {
      print "$pop3_fname: ".($mail_count - $max_uidv_count).
	" / $mail_count needs changing\n";
    }
  }
  $max_uidv = -1 if ($max_uidv == 0);
  return ($max_uidv, $max_uidv_nextuid, %filename_map);
}

sub read_courier_imap {
  my ($dir, $pop3_uidv, $pop3_nextuid, $curnew_map, %filename_map) = @_;
  
  # check if we can preserve IMAP UIDs
  my $imap_fname = "$dir/$imap_uidfile";
  if (!-f $imap_fname) {
    print "$imap_fname: OK\n" if (!$quiet);
    return;
  }
  
  my $f;
  open ($f, $imap_fname) || die $!;
  my $imap_hdr = <$f>;
  if ($imap_hdr !~ /^1 (\d+) (\d+)$/) {
    $global_error_count++;
    print STDERR "$imap_fname: Broken header: $imap_hdr\n";
    close $f;
    return;
  }
  my ($imap_uidv, $imap_nextuid) = ($1, $2);
  
  if ($pop3_uidv == -1) {
    # no pop3 uidlist file
    $pop3_uidv = $imap_uidv;
    $pop3_nextuid = 0;
  } elsif ($pop3_uidv != $imap_uidv) {
    # UIDVALIDITY is different with POP3 and IMAP, we can't use it.
    # But if no files actually exist, don't bother complaining.
    scan_curnew($dir, $curnew_map);
  }
  
  my $curnew_read = 0;
  $curnew_read = 1 if (scalar keys %$curnew_map > 0);

  my $imap_mail_count = 0;
  my $imap_changes = 0;
  my %found_files;
  my $found_files_looked_up = 0;
  while (<$f>) {
    chomp $_;
    
    if (/^(\d+) (.*)$/) {
      my ($uid, $fname) = ($1, $2);
      # get the base filename
      $fname =~ s/^([^:]+).*$/$1/;
      
      next if ($curnew_read && !defined($$curnew_map{$fname}));

      my $changed = 0;
      if (defined $filename_map{$fname}) {
	if ($pop3_uidv == $imap_uidv) {
	  if ($filename_map{$fname} ne "$imap_uidv:$uid") {
	    $changed = 1;
	  }
	} else {
	  $changed = 1;
	}
      } else {
	# not in pop3 list
	if ($pop3_uidv == $imap_uidv && $uid >= $pop3_nextuid) {
	  $filename_map{$fname} = "$imap_uidv:$uid";
	  $pop3_nextuid = $uid + 1;
	} else {
	  $changed = 1;
	}
      }
      if ($changed && !$curnew_read) {
	scan_curnew($dir, $curnew_map);
	$curnew_read = 1;
	next if (!defined($$curnew_map{$fname}));
      }
     
      $imap_changes++ if ($changed);
      $imap_mail_count++;
    } else {
      $global_error_count++;
      print STDERR "$imap_fname: Broken header\n";
    }
  }
  close $f;
  
  if ($pop3_uidv == $imap_uidv && $pop3_nextuid < $imap_nextuid) {
    $pop3_nextuid = $imap_nextuid;
  }
  
  if ($imap_changes == 0) {
    print "$imap_fname: OK\n" if (!$quiet);
  } else {
    $global_imap_change_count += $imap_changes;
    $global_imap_mailbox_count++;
    if (!$quiet) {
      print "$imap_fname: $imap_changes / $imap_mail_count needs changing\n";
    }
  }
  return ($pop3_uidv, $pop3_nextuid, %filename_map);
}

sub write_dovecot_uidlist {
  my ($dir, $uidv, $nextuid, $owner_uid, $owner_gid, %filename_map) = @_;
  
  return if ($uidv <= 0 || $nextuid == 0);
  
  my $uidlist_fname = "$dir/dovecot-uidlist";
  if (!$overwrite && -f $uidlist_fname) {
    print "$uidlist_fname already exists, not overwritten\n" if (!$quiet);
    return;
  }
  
  return if (!$do_conversion);
  
  my %uidlist_map;
  foreach (keys %filename_map) {
    my $fname = $_;
    
    if ($filename_map{$fname} =~ /^(\d+):(\d+)$/) {
      if ($1 == $uidv && $2 > 0) {
	$uidlist_map{$2} = $fname;
      }
    }
  }
 
  my $f;
  open ($f, ">$uidlist_fname") || die $!;
  print $f "1 $uidv $nextuid\n";
  foreach (sort { $a <=> $b } keys %uidlist_map) {
    print $f "$_ ".$uidlist_map{$_}."\n";
  }
  close $f;
  chown $owner_uid, $owner_gid, $uidlist_fname;
  $uidlist_write_count++;
}

sub convert_keywords {
  my ($dir, $owner_uid, $owner_gid) = @_;
  my $keyword_dir = "$dir/courierimapkeywords";
  my $dovecot_keyfname = "$dir/dovecot-keywords";
  
  if (!-f "$keyword_dir/:list") {
    # no keywords
    return;
  }
  
  if (!$overwrite && -f $dovecot_keyfname) {
    print "$dovecot_keyfname already exists, not overwritten\n" if (!$quiet);
    return;
  }
  
  my (%keywords, %files);
  my $f;
  open ($f, "$keyword_dir/:list") || die $!;
  # read keyword names
  while (<$f>) {
    chomp $_;
    
    last if (/^$/);
    $keywords{$_} = scalar keys %keywords;
  }
  # read filenames -> keywords mapping
  while (<$f>) {
    if (/([^:]+):([\d ]+)$/) {
      my $fname = $1;
      foreach (sort { $a <=> $b } split(" ", $2)) {
	$files{$fname} .= chr(97 + $_);
      }
    } else {
      print STDERR "$keyword_dir/:list: Broken entry: $_\n";
    }      
  }
  close $f;
  
  # read updates from the directory
  my %updates;
  opendir my $kw_dh, $keyword_dir || die $!;
  foreach (readdir($kw_dh)) {
    next if ($_ eq ":list");
    
    my $fname = $_;
    if (/^\.(\d+)\.(.*)$/) {
      my ($num, $base_fname) = ($1, $2);
      if (!defined $updates{$fname}) {
	$updates{$fname} = $num;
      } else {
	my $old = $updates{$fname};
	if ($old >= 0 && $num > $old) {
	  $updates{$fname} = $num;
	}
      }
    } else {
      # "fname" overrides .n.fnames
      $updates{$fname} = -1;
    }
  }
  closedir $kw_dh;
  
  # apply the updates
  foreach (keys %updates) {
    my $base_fname = $_;
    my $num = $updates{$_};
    
    my $fname;
    if ($num < 0) {
      $fname = $base_fname;
    } else {
      $fname = ".$num.$base_fname";
    }
    
    my @kw_list;
    open ($f, "$keyword_dir/$fname") || next;
    while (<$f>) {
      chomp $_;
      my $kw = $_;
      my $idx;
      
      if (defined $keywords{$kw}) {
	$idx = $keywords{$kw};
      } else {
	$idx = scalar keys %keywords;
	$keywords{$kw} = $idx;
      }
      $kw_list[scalar @kw_list] = $idx;
    }
    close $f;
    
    $files{$fname} = "";
    foreach (sort { $a <=> $b } @kw_list) {
      $files{$fname} .= chr(97 + $_);
    }
  }
  
  return if (!$do_conversion);
  
  # write dovecot-keywords file
  open ($f, ">$dovecot_keyfname") || die $!;
  foreach (sort { $keywords{$a} <=> $keywords{$b} } keys %keywords) {
    my $idx = $keywords{$_};
    print $f "$idx $_\n";
  }
  close $f;
  chown $owner_uid, $owner_gid, $dovecot_keyfname;
  
  # update the maildir files
  my $cur_dir = "$dir/cur";
  opendir my $dh, $cur_dir || die $!;
  foreach (readdir($dh)) {
    my $fname = "$cur_dir/$_";
    
    my ($base_fname, $flags, $extra_flags);
    if (/^([^:]+):2,([^,]*)(,.*)?$/) {
      ($base_fname, $flags, $extra_flags) = ($1, $2, $3);
      $extra_flags = "" if (!defined $extra_flags);
    } else {
      $base_fname = $fname;
      $flags = "";
      $extra_flags = "";
    }
    
    if (defined $files{$base_fname}) {
      # merge old and new flags
      my %newflags;
      foreach (sort split("", $files{$base_fname})) {
	$newflags{$_} = 1;
      }
      foreach (sort split("", $flags)) {
	$newflags{$_} = 1;
      }
      $flags = "";
      foreach (sort keys %newflags) {
	$flags .= $_;
      }
      my $new_fname = "$cur_dir/$base_fname:2,$flags$extra_flags";
      if ($fname ne $new_fname) {
	rename($fname, $new_fname) || 
	  print STDERR "rename($fname, $new_fname) failed: $!\n";
      }
    }
  }
  closedir $dh;
}

sub convert_subscriptions {
  my ($dir, $owner_uid, $owner_gid) = @_;
  
  my $in_fname = "$dir/courierimapsubscribed";
  my $out_fname = "$dir/subscriptions";
  return if (!-f $in_fname);
  
  if (!$overwrite && -f $out_fname) {
    print "$out_fname already exists, not overwritten\n" if (!$quiet);
    return;
  }
  
  return if (!$do_conversion);
  
  my ($fin, $fout);
  open ($fin, $in_fname) || die $!;
  open ($fout, ">$out_fname") || die $!;
  while (<$fin>) {
    chomp $_;
    
    if (/^INBOX$/i) {
      print $fout "INBOX\n";
    } elsif (/^INBOX\.(.*)$/i) {
      print $fout "$1\n";
    } else {
      # unknown. keep it as-is.
      print $fout "$_\n";
    }
  }
  close $fin;
  close $fout;
  chown $owner_uid, $owner_gid, $out_fname;
}

sub check_maildir_single {
  my ($dir, $childbox) = @_;
  my $uidv = -1;
  my $nextuid = 0;
  my %filename_map;
  my $found = 0;
  
  $dir =~ s,^\./,,g;
  
  my @pop3_stat = ();
  @pop3_stat = stat("$dir/$pop3_uidfile") if (!$childbox);
  my @imap_stat = stat("$dir/$imap_uidfile");
  my ($pop3_mtime, $imap_mtime) = (0, 0);
  $pop3_mtime = $pop3_stat[9] if (scalar @pop3_stat > 0);
  $imap_mtime = $imap_stat[9] if (scalar @imap_stat > 0);
  my %curnew_map;
  
  my ($owner_uid, $owner_gid);
  if (scalar @pop3_stat > 0) {
    $owner_uid = $pop3_stat[4];
    $owner_gid = $pop3_stat[5];
  } elsif (scalar @imap_stat > 0) {
    $owner_uid = $imap_stat[4];
    $owner_gid = $imap_stat[5];
  }

  if (scalar @pop3_stat > 0) {
    $found = 1;
    if ($imap_mtime < $pop3_mtime ||
	$imap_mtime - $pop3_mtime < $pop3_stale_uidlist_secs) {
      ($uidv, $nextuid, %filename_map) =
        read_courier_pop3($dir, \%curnew_map, $pop3_mtime);
    }
  }

  my $imap_uidv = 0;
  if (scalar @imap_stat > 0) {
    $found = 1;
    ($uidv, $nextuid, %filename_map) =
      read_courier_imap($dir, $uidv, $nextuid, \%curnew_map, %filename_map);
  }

  if (!$found) {
    print "$dir: No imap/pop3 uidlist files\n" if (!$quiet && !$childbox);
    return;
  }
  
  write_dovecot_uidlist($dir, $uidv, $nextuid, $owner_uid, $owner_gid, %filename_map);
  convert_subscriptions($dir, $owner_uid, $owner_gid);
  convert_keywords($dir, $owner_uid, $owner_gid);
}

sub check_maildir {
  my ($dir) = @_;
  
  my $orig_pop3_mailboxes = $global_pop3_mailbox_count;
  my $orig_imap_mailboxes = $global_imap_mailbox_count;
  
  check_maildir_single($dir, 0);
  foreach (<$dir/.*>) {
    next if ($_ =~ /\/\.?\.$/);
    check_maildir_single($_, 1);
  }
  
  $global_pop3_user_count++ if ($orig_pop3_mailboxes != $global_pop3_mailbox_count);
  $global_imap_user_count++ if ($orig_imap_mailboxes != $global_imap_mailbox_count);
}

sub is_maildir {
  my ($dir) = @_;
  
  return (-f "$dir/$pop3_uidfile" || -f "$dir/$imap_uidfile" || -d "$dir/cur");
}

sub userdir_check {
  my ($dir) = @_;
  my $found = 0;
  
  opendir my $dh, $dir || die $!;
  foreach (readdir($dh)) {
    my $userdir = "$dir/$_";
    next if (!-d $userdir);
    
    if ($maildir_subdirs == -1) {
      # unknown if we want Maildir/ or not
      if (-d "$userdir/Maildir" && is_maildir("$userdir/Maildir")) {
	$maildir_subdirs = 1;
      } elsif (is_maildir($userdir)) {
	$maildir_subdirs = 0;
      } else {
	next;
      }
    }
    
    if ($maildir_subdirs == 1) {
      if (is_maildir("$userdir/Maildir")) {
	check_maildir("$userdir/Maildir");
	$found = 1;
      }
    } elsif ($maildir_subdirs == 0) {
      if (is_maildir($userdir)) {
	check_maildir($userdir);
	$found = 1;
      }
    }
  }
  closedir $dh;
  return $found;
}

sub depth_check {
  my ($dir, $depth) = @_;
  my $found = 0;
  
  opendir my $dh, $dir || die $!;
  foreach (readdir($dh)) {
    my $subdir = "$dir/$_";
    next if (!-d $subdir);
    
    if ($depth > 0) {
      $found = 1 if (depth_check($subdir, $depth - 1))
    } else {
      $found = 1 if (userdir_check($subdir));
    }
  }
  closedir $dh;
  return $found;
}

my $mailroot = ".";
for (my $i = 0; $i < scalar @ARGV; $i++) {
  if ($ARGV[$i] eq "--convert") {
    $do_conversion = 1;
  } elsif ($ARGV[$i] eq "--quiet" || $ARGV[$i] eq "-q") {
    $quiet = 1;
  } elsif ($ARGV[$i] eq "--overwrite") {
    $overwrite = 1;
  } elsif ($ARGV[$i] eq "--recursive") {
    $recursive = 1;
  } else {
    $mailroot = $ARGV[$i];
  }
}

print "Finding maildirs under $mailroot\n" if (!$quiet);
if (is_maildir($mailroot)) {
  check_maildir($mailroot);
} elsif (-d "$mailroot/Maildir") {
  if (!is_maildir("$mailroot/Maildir")) {
    print STDERR "$mailroot/Maildir doesn't seem to contain a valid Maildir\n";
  } else {
    check_maildir("$mailroot/Maildir");
  }
} elsif ($recursive) {
  if ($depth > 0 || !userdir_check($mailroot)) {
    $depth-- if ($depth > 0);
    if (!depth_check($mailroot, $depth)) {
      print STDERR "No maildirs found\n";
      exit;
    }
  }
}

if (!$quiet) {
  print "\nTotal: $global_pop3_change_count POP3 changes for ".
    "$global_pop3_mailbox_count mailboxes / $global_pop3_user_count users\n";
  print "       $global_imap_change_count IMAP changes for ".
    "$global_imap_mailbox_count mailboxes / $global_imap_user_count users\n";
  print "       $global_error_count errors\n";

  if (!$do_conversion) {
    print "No actual conversion done, use --convert parameter\n";
  } else {
    print "$uidlist_write_count dovecot-uidlist files written\n";
  }
}
