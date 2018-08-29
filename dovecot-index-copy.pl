#!/usr/bin/env perl

# When you add :INDEX=path to Dovecot's mail_location, the indexes need to be
# recreated, which slows things down. This script can be used to copy the old
# index files to the new location to avoid it. The script doesn't copy files
# for index dirs that have already been created.

# WARNING: Currently there is no locking, so preferrably this should be run
# while Dovecot isn't running, or at least during a time when there is little
# email access. There is a possibility of index corruption otherwise.

# Usage:
#   dovecot-index-copy.pl -u <username> requires Dovecot v2.2+. This looks up
#     the user's current home and mail location and uses them to figure out
#     the source and destination.
#   dovecot-index-copy.pl -p <layout> <source root> <dest root>. The root dirs
#     must be absolute paths, not referring to home dir (~/) or use any
#     %variables. For example: -p maildir++ /var/vmail/domain.com/user/Maildir
#     /var/lib/indexes/domain.com/user

# v0.1: Initial version, support only Maildir++ for now.

use strict;
use File::Path;
use POSIX;

my ($layout, $root, $index);

if ($ARGV[0] eq "-u") {
  # username
  my $user = $ARGV[1];
  if (!$user) {
    die "-u missing username parameter";
  }

  my $doveadm_reply = `doveadm user $user`;
  if ($? == -1) {
    die "doveadm user $user failed: $!";
  } elsif ($? != 0) {
    my $code = $? >> 8;
    die "doveadm user $user failed: $code";
  }
  my @lines = split ("\n", $doveadm_reply);
  my $home = "";
  my $mail = "";
  foreach my $line (@lines) {
    if ($line =~ /^([^\t]+)\t(.*)$/) {
      my ($key, $value) = ($1, $2);
      if ($key eq "home") {
	$home = $value;
      } elsif ($key eq "mail") {
	$mail = $value;
      }
    }
  }
  if ($home eq "" && $mail =~ /~/) {
    die "mail location uses ~ but we have no home die";
  }
  $mail =~ s,~,$home,g;
  if ($mail !~ /^([^:]+):([^:]+):.*INDEX=([^:]+)/) {
    die "mail location has no INDEX=path: $mail";
  }
  my $format = $1;
  ($root, $index) = ($2, $3);
  if ($mail =~ /:LAYOUT=([^:]+)/) {
    $layout = $1;
  } elsif ($format eq "maildir") {
    $layout = "maildir++";
  } else {
    $layout = "fs";
  }
} elsif ($ARGV[0] eq "-p") {
  ($layout, $root, $index) = ($ARGV[1], $ARGV[2], $ARGV[3]);
  if (!$index) {
    die "-p missing fs, root and/or index parameters";
  }
  if ($root =~ /~/) {
    die "root uses ~ but we don't know the home dir";
  }
  if ($index =~ /~/) {
    die "index uses ~ but we don't know the home dir";
  }
} else {
  die "Usage: -u <username> | -p <layout> <mail root> <index root>";
}

if ($root !~ /^\//) {
  die "mail root is relative: $root";
}
if ($index !~ /^\//) {
  die "index root is relative: $index";
}
if ($root =~ /%/) {
  die "root still has %vars: $root";
}
if ($index =~ /%/) {
  die "index still has %vars: $index";
}
if ($layout eq "maildir++") {
  copy_indexes_maildir($root, $index);
} else {
  die "Can't handle LAYOUT=$layout currently";
}

sub copy_indexes_maildir {
  my ($root, $index) = @_;
  
  my $nocopy = (-x $index); # already accessed, don't copy old indexes
  my $dir;
  my $fname;
  opendir ($dir, $root) || die "Can't open $root: $!";
  while (($fname = readdir($dir))) {
    if ($fname =~ /^\.([^\.])/) {
      copy_indexes_maildir_sub("$root/$fname", "$index/$fname");
    } elsif (!$nocopy) {
      copy_index_file($root, $index, $fname);
    }
  }
  closedir $dir;
}

sub copy_indexes_maildir_sub {
  my ($root, $index) = @_;
  
  return if (-x $index); # already accessed, don't copy old indexes
  
  my $dir;
  my $fname;
  opendir ($dir, $root) || return;
  while (($fname = readdir($dir))) {
    copy_index_file($root, $index, $fname);
  }
  closedir $dir;
}

sub copy_index_file {
  my ($root, $index, $fname) = @_;
  
  if ($fname =~ /^dovecot.list.index/ || 
      $fname =~ /^dovecot.index/ ||
      $fname =~ /^dovecot.mailbox.log/) {
    my $src = "$root/$fname";
    my $dest = "$index/$fname";
    if (!copy_with_perms($src, $dest)) {
      (my @st = stat($root)) || die "stat($root) failed: $!";
      my $src_mode = $st[2];
      my $src_uid = $st[4];
      my $src_gid = $st[5];
      File::Path::make_path($index, { mode => $src_mode, owner => $src_uid, group => $src_gid });
      copy_with_perms($src, $dest) || die "copy($src, $dest) failed: $!";
    }
  }
}

sub copy_with_perms {
  my ($src, $dest) = @_;
  
  (my @st = stat($src)) || return 1;
  my $src_mode = $st[2];
  my $src_uid = $st[4];
  my $src_gid = $st[5];
  
  my ($srcfd, $destfd);
  (open $srcfd, "<$src") || return 1;
  if (!sysopen($destfd, $dest, O_RDWR | O_CREAT | O_TRUNC, $src_mode)) {
    close $srcfd; 
    return 0;
  }
  chown $src_uid, $src_gid, $destfd;
  
  while (<$srcfd>) {
    print $destfd $_;
  }
  close $srcfd;
  close $destfd;
}
