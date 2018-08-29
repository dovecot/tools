#!/usr/bin/perl

# qmail-pop3d uses maildir base filename as the UIDL, which Dovecot can easily
# support with pop3_uidl_format=%f. The problem is the ordering of the UIDLs:
# qmail-pop3d sorts by mtime, while Dovecot sorts by filename.
# This script writes dovecot-uidlist files such that Dovecot returns the UIDLs
# in the qmail-pop3d order.

# Assumes that dovecot-uidlist doesn't exist yet, if any IMAP UIDs need to be
# preserved another script will have to do that on top of the generated
# dovecot-uidlists.

# Copyright (c) 2008-2011 Timo Sirainen

# Somewhat based on courier-dovecot-migrate.pl
# Copyright (c) 2008 cPanel, Inc.

# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#     * Redistributions of source code must retain the above copyright
#       notice, this list of conditions and the following disclaimer.
#     * Redistributions in binary form must reproduce the above copyright
#       notice, this list of conditions and the following disclaimer in the
#       documentation and/or other materials provided with the distribution.
#     * Neither the name of the cPanel, Inc. nor the
#       names of its contributors may be used to endorse or promote products
#       derived from this software without specific prior written permission.
#
# THIS SOFTWARE IS PROVIDED BY CPANEL, INC. "AS IS" AND ANY
# EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
# WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
# DISCLAIMED. IN NO EVENT SHALL CPANEL, INC BE LIABLE FOR ANY
# DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
# (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
# LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
# ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
# (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
# SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

use strict;
use warnings;
use Getopt::Long ();

# Globals
my $do_conversion = 0;
my $quiet         = 0;
my $recursive     = 0;
my $overwrite     = 0;
my $help          = 0;

my $dovecot_uidfile = 'dovecot-uidlist';
my $maildir_name    = 'Maildir';

my $depth               = 1;
my $maildirs_seen_count = 0;
my $uidlist_write_count = 0;
my $maildir_subdirs     = -1;

# Argument processing
my %opts = (
    'convert'    => \$do_conversion,
    'quiet'      => \$quiet,
    'overwrite'  => \$overwrite,
    'recursive'  => \$recursive,
    'help'       => \$help,
);

Getopt::Long::GetOptions(%opts);
usage() if $help;

my $mailroot = shift @ARGV || '.';

# Check/Convert maildirs
print "Finding maildirs under $mailroot\n" if ( !$quiet );
if ( is_maildir($mailroot) ) {
    check_maildir($mailroot);
}
elsif ( -d "$mailroot/$maildir_name" ) {
    if ( !is_maildir("$mailroot/$maildir_name") ) {
        print STDERR "$mailroot/$maildir_name doesn't seem to contain a valid Maildir\n";
    }
    else {
        check_maildir("$mailroot/$maildir_name");
    }
}
elsif ($recursive) {
    if ( $depth > 0 || !userdir_check($mailroot) ) {
        $depth-- if ( $depth > 0 );
        if ( !depth_check( $mailroot, $depth ) ) {
            print STDERR "No maildirs found\n";
            exit;
        }
    }
}

# Totals
if ( !$quiet ) {
    print "\nTotal: $maildirs_seen_count mailboxes\n";

    if ( !$do_conversion ) {
        print "No actual conversion done, use --convert parameter\n";
    }
    else {
        print "$uidlist_write_count $dovecot_uidfile files written\n";
    }
    print "\nWARNING: Badly done migration will cause your IMAP and/or POP3 clients to re-download all mails. Read http://wiki.dovecot.org/Migration carefully.\n";
}

sub sort_add {
  my ($filename_map, $dir, $fname) = @_;

  return if ( $fname eq "." || $fname eq ".." );

  my @stat = stat("$dir/$fname");
  if (scalar @stat > 0) {
    my $base_fname;
    if ( $fname =~ /^([^:]+):2,/ ) {
	$base_fname = $1;
    } else {
	$base_fname = $fname;
    }
    
    my $mtime = $stat[9];
    $filename_map->{$base_fname} = $mtime;
  }
}

sub sort_files_by_mtime {
    my ( $dir ) = @_;

    my $filename_map = {};

    my @files;
    if ( opendir my $dh, "$dir/cur" ) {
      while (my $fname = readdir($dh)) {
	sort_add($filename_map, "$dir/cur", $fname);
      }
      closedir $dh;
    }
    if ( opendir my $dh, "$dir/new" ) {
      while (my $fname = readdir($dh)) {
	sort_add($filename_map, "$dir/new", $fname);
      }
      closedir $dh;
    }
    
    return sort { 
      $filename_map->{$a} <=> $filename_map->{$b}
    } keys %{$filename_map};
}

sub write_dovecot_uidlist {
    my ( $dir, $owner_uid, $owner_gid, $files ) = @_;
    
    my $uidlist_fname = "$dir/$dovecot_uidfile";
    if ( !$overwrite && -f $uidlist_fname ) {
        print "$uidlist_fname already exists, not overwritten\n" if ( !$quiet );
        return;
    }
    my $files_count = scalar @{$files};
    return if ($files_count == 0);
    
    return if ( !$do_conversion );

    open( my $dovecot_uidlist_fh, '>', $uidlist_fname ) || die $!;
    my $uidv = time();
    my $uid = 1;
    print $dovecot_uidlist_fh "3 V$uidv N".($files_count+1)."\n";
    foreach my $fname ( @{$files} ) {
      print $dovecot_uidlist_fh "$uid :$fname\n";
      $uid++;
    }
    close $dovecot_uidlist_fh;
    chown $owner_uid, $owner_gid, $uidlist_fname;
    $uidlist_write_count++;
}

sub check_maildir {
    my ( $dir, $childbox ) = @_;

    $dir =~ s{^\./}{}g;
    
    my @stat = stat("$dir");
    if (scalar @stat == 0) {
      print "stat($dir) failed\n";
      return;
    }
    my $owner_uid = $stat[4];
    my $owner_gid = $stat[5];

    my @files = sort_files_by_mtime( $dir );

    $maildirs_seen_count++;
    write_dovecot_uidlist( $dir, $owner_uid, $owner_gid, \@files );
}

sub is_maildir {
    my ($dir) = @_;

    return ( -d "$dir/cur" );
}

sub userdir_check {
    my ($dir) = @_;
    my $found = 0;

    my @userdir_check_files;
    if ( opendir my $userdir_dh, $dir ) {
        @userdir_check_files = readdir($userdir_dh);
        closedir $userdir_dh;
    }
    foreach my $userdir (@userdir_check_files) {
        $userdir = $dir . '/' . $userdir;
        next if ( -l $userdir );
        next if ( !-d $userdir );

        if ( $maildir_subdirs == -1 ) {

            # unknown if we want $maildir_name/ or not
            if ( -d "$userdir/$maildir_name" && is_maildir("$userdir/$maildir_name") ) {
                $maildir_subdirs = 1;
            }
            elsif ( is_maildir($userdir) ) {
                $maildir_subdirs = 0;
            }
            else {
                next;
            }
        }

        if ( $maildir_subdirs == 1 ) {
            if ( is_maildir("$userdir/$maildir_name") ) {
                check_maildir("$userdir/$maildir_name");
                $found = 1;
            }
        }
        elsif ( $maildir_subdirs == 0 ) {
            if ( is_maildir($userdir) ) {
                check_maildir($userdir);
                $found = 1;
            }
        }
    }
    return $found;
}

sub depth_check {
    my ( $dir, $depth ) = @_;
    my $found = 0;

    my @depth_check_files;
    if ( opendir my $depth_check_dh, $dir ) {
        @depth_check_files = readdir($depth_check_dh);
        closedir $depth_check_dh;
    }
    foreach my $subdir (@depth_check_files) {
        next if ($subdir eq '.' || $subdir eq '..');
        $subdir = $dir . '/' . $subdir;
        next if ( !-d $subdir );

        if ( $depth > 0 ) {
            $found = 1 if ( depth_check( $subdir, $depth - 1 ) );
        }
        else {
            $found = 1 if ( userdir_check($subdir) );
        }
    }
    return $found;
}

sub usage {
    print "Usage: qmail-pop3d-dovecot-migrate [options] <maildir>\n\n";
    print "Options:\n";
    print "    --convert       Perform conversion\n";
    print "    --quiet         Silence output\n";
    print "    --overwrite     Overwrite existing files\n";
    print "    --recursive     Recursively look through maildir for subaccounts\n";
    exit 0;
}
