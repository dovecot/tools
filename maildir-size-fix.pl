#!/usr/bin/env perl

# v1.1 by Timo Sirainen, public domain

# some maildir filenames created by .. courier? maildrop? .. has file sizes
# that don't match the file's real size. this script finds such files and
# renames them. if they're found from dovecot-uidlist, they're also renamed
# within there, so their IMAP UID doesn't change either. the POP3 UIDL
# is also optionally preserved then.

use File::Basename;
use strict;

my $maildirlock_path = "/usr/local/libexec/dovecot/maildirlock";
# Check if the maildirlock_path exists.
-e $maildirlock_path or die "maildirlock file /usr/local/libexec/dovecot/maildirlock does not seem to exist, consider checking its location and edit this script if required";

# If UIDLs are based on filename and no P<uidl> entry already exist for
# a message, write a P<original filename> entry so it doesn't change when
# renaming a file.
my $preserve_pop3_uidl = 1; # -p / -np
# If filename doesn't already have a S=size, add it.
my $add_missing_size = 0; # -a / -na
# If S=size already exists, verify that it is correct.
my $fix_existing_size = 1; # -f / -nf
# Check if the files are compressed. Use the uncompressed size for S=size.
my $check_compression = 0; # -c / -nc
# Recursively scan the maildir for subdirectories
my $recursive = 0; # -r / -nr
# Verbose logging
my $verbose = 0; # -v / -nv

sub maildir_get_size {
  my $path = shift;
  
  if (!$check_compression) {
    my @stat = stat($path);
    return undef if scalar @stat == 0;

    return $stat[7];
  }
  # Detecting all possible types (keep going) since some versions of the file
  # command can wrong detect gzip files as Minix filesystems.
  # See: https://bugs.launchpad.net/ubuntu/+source/file/+bug/1646233
  my $type=`file -k "$path"`;
  my $program = "";
  if ($type =~ /gzip/) {
    $program = "gunzip";
  } elsif ($type =~ /bzip2/) {
    $program = "bunzip2";
  } else {
    my @stat = stat($path);
    return undef if scalar @stat == 0;

    return $stat[7];
  }
  my $size = `cat '$path' | $program | wc | awk '{print \$3}'`;
  chop $size;
  return undef if ($? != 0);
  return undef if ($size !~ /^[0-9]+$/);
  return $size;
}

sub scan_maildir {
  my ($dir, $renames) = @_;

  my @files;
  if (opendir my $dh, $dir) {
    @files = readdir($dh);
    closedir $dh;
  }
  foreach my $fname (@files) {
    next if ($fname eq "." || $fname eq "..");
    
    my $newfname = $fname;
    my $path = "$dir/$fname";
    if ($fname =~ /^([^:]*),S=(\d+)[^:]*(.*)$/) {
      my ($base_fname_no_size, $fname_size, $flags) = ($1, $2, $3);
      
      if ($fix_existing_size) {
	my $real_size = maildir_get_size($path);
	next if $real_size == undef;
	if ($real_size != $fname_size) {
	  # incorrect size. fix the S=size, but remove W=size if it exists
	  $newfname = "$base_fname_no_size,S=$real_size$flags";
	}
      }
    } elsif ($add_missing_size) {
      # Missing S=size, add it
      my $real_size = maildir_get_size($path);
      next if $real_size == undef;
      
      if ($fname =~ /^([^:]*)(:.*)$/) {
	my ($base_fname, $flags) = ($1, $2);
	$newfname = "$base_fname,S=$real_size$flags";
      } else {
	$newfname = "$fname,S=$real_size";
      }
    }
    
    if ($newfname ne $fname) {
      print "Renaming: $fname -> $newfname\n" if ($verbose);
      $$renames{$path} = "$dir/$newfname";
    }
  }
}

sub dovecot_uidlist_fix {
  my ($path, $renames) = @_;
  
  my %base_renames;
  foreach my $src (keys %{$renames}) {
    my $fname = basename($src);
    $fname =~ s/:.*$//;
    
    my $dest = $$renames{$src};
    my $dest_fname = basename($dest);
    $dest_fname =~ s/:.*$//;

    $base_renames{$fname} = $dest_fname;
  }
  
  my $uidlist_path = "$path/dovecot-uidlist";
  my $uidlist_tmp = "$path/dovecot-uidlist.tmp2";
  open my $fin, $uidlist_path || return;
  my $fout;
  if (!open $fout, ">$uidlist_tmp") {
    close $fin;
    return;
  }
  my $hdr = <$fin>;
  print $fout $hdr;
  while (<$fin>) {
    chomp $_;
    if (/^(\d+) ([^:]*)?:(.*)$/) {
      my ($uid, $extra, $fname) = ($1, $2, $3);
      
      my $base_fname = $fname;
      $base_fname =~ s/:.*$//;
      my $new_fname = $base_renames{$base_fname};
      if (!$new_fname || !$preserve_pop3_uidl || $extra =~ /\bP/) {
	$fname = $new_fname if ($new_fname);
	print $fout "$uid $extra:$fname\n";
      } else {
	$fname =~ s/:.*$//;
	print $fout "$uid P$fname $extra:$new_fname\n";
      }
    } else {
      print $fout "$_\n";
    }
  }
  close $fin;
  close $fout;
  
  rename($uidlist_tmp, $uidlist_path);
}

sub maildir_fix_once {
  my ($path) = @_;

  my $retry = 0;
  my %renames;
  print "Scanning maildir: $path\n" if ($verbose);
  scan_maildir("$path/new", \%renames);
  scan_maildir("$path/cur", \%renames);

  return 0 if (scalar keys %renames == 0);
  
  open my $output, "-|", $maildirlock_path, ($path, "30");
  my $pid = <$output>;
  close $output;
  
  foreach my $src (keys %renames) {
    my $dest = $renames{$src};
    $retry = 1 if (!rename($src, $dest));
  }
  
  dovecot_uidlist_fix($path, \%renames);
  
  kill 15, $pid;
  return $retry;
}

sub maildir_fix {
  my ($maildir_path) = @_;
  
  if (maildir_fix_once($maildir_path)) {
    if (maildir_fix_once($maildir_path)) {
      print STDERR "Fixing failed: $maildir_path\n";
    }
  }
  if ($recursive) {
    my @files;
    if (opendir my $dh, $maildir_path) {
      @files = readdir($dh);
      foreach my $fname (@files) {
	next if ($fname eq "." || $fname eq "..");
	
	my $path = "$maildir_path/$fname";
	if (-d $path) {
	  maildir_fix($path);
	}
      }
      closedir $dh;
    }
  }
}

while (scalar @ARGV > 0 && $ARGV[0] =~ /^-(.*)$/) {
  my $c = $1;
  my $r = 1;
  if ($ARGV[0] =~ /^-n(.*)$/) {
    $c = $1;
    $r = 0;
  }
  if ($c eq "p") {
    $preserve_pop3_uidl = $r;
  } elsif ($c eq "a") {
    $add_missing_size = $r;
  } elsif ($c eq "c") {
    $check_compression = $r;
  } elsif ($c eq "f") {
    $fix_existing_size = $r;
  } elsif ($c eq "r") {
    $recursive = $r;
  } elsif ($c eq "v") {
    $verbose = $r;
  } else {
    print STDERR "Invalid parameter: ".$ARGV[0]."\n";
    exit 1;
  }
  shift @ARGV;
}

if (scalar @ARGV == 0) {
  print STDERR "Usage: maildir-size-fix.pl /path/to/Maildir\n";
  exit 1
}

my $dir = $ARGV[0];
maildir_fix($dir);
if (opendir my $dh, $dir) {
  foreach my $fname (readdir($dh)) {
    next if ($fname !~ /^\.[^\.]/);
    my $path = "$dir/$fname";
    maildir_fix($path) if (-d $path);
  }
  closedir $dh;
}
