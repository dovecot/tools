#!/usr/bin/perl

# Assumes dovecot-uidlist currently belongs to a working Dovecot POP3.
# Merges courierimapuiddb into dovecot-uidlist without losing POP3 UIDLs or
# changing the POP3 message order (by adding 'O' entries).
# Also merges other Courier IMAP stuff, like keywords and subscriptions.

# cpanel12 - maildir-migrate                      Copyright(c) 2008 cPanel, Inc.
#                                                           All Rights Reserved.
# copyright@cpanel.net                                         http://cpanel.net

# Based largely on courier-dovecot-migrate.pl v1.1.7
# Copyright 2008 Timo Sirainen

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

# Key files in maildirs
my $courier_imap_uidfile       = 'courierimapuiddb';
my $courier_subscriptions_file = 'courierimapsubscribed';
my $courier_keywords_dir       = 'courierimapkeywords/';
my $courier_keywords_file      = 'courierimapkeywords/:list';
my $dovecot_uidfile            = 'dovecot-uidlist';
my $dovecot_subscriptions_file = 'subscriptions';
my $dovecot_keywords_file      = 'dovecot-keywords';

# Globals
my $do_conversion = 0;
my $quiet         = 0;
my $recursive     = 0;

my $depth                     = 1;
my $maildir_subdirs           = -1;
my $global_error_count        = 0;
my $global_mailbox_count      = 0;
my $global_user_count         = 0;
my $uidlist_write_count       = 0;
my $help                      = 0;
my $maildir_name              = 'Maildir';
my $max_pop3_order            = 2147483647;

# Argument processing
my %opts = (
    'convert'    => \$do_conversion,
    'quiet'      => \$quiet,
    'recursive'  => \$recursive,
    'help'       => \$help,
);

Getopt::Long::GetOptions(%opts);
usage() if $help;

my $mailroot = shift @ARGV || '.';

my $conversion_type = 'dovecot';

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
    print "\nTotal: $global_mailbox_count mailboxes / $global_user_count users\n";
    print "       $global_error_count errors\n";

    if ( !$do_conversion ) {
        print "No actual conversion done, use --convert parameter\n";
    }
    else {
        print "$uidlist_write_count $dovecot_uidfile files written\n";
    }
    print "\nWARNING: Badly done migration will cause your IMAP and/or POP3 clients to re-download all mails. Read http://wiki.dovecot.org/Migration carefully.\n";
}

sub scan_maildir {
    my ( $dir, $map ) = @_;

    my @scan_maildir_files;
    if ( opendir my $scan_maildir_dh, $dir ) {
        @scan_maildir_files = readdir($scan_maildir_dh);
        closedir $scan_maildir_dh;
    }
    foreach my $real_filename (@scan_maildir_files) {
        next if ( $real_filename eq "." || $real_filename eq ".." );

        my $base_filename;
        if ( $real_filename =~ /^([^:]+):2,/ ) {
            $base_filename = $1;
        }
        else {
            $base_filename = $real_filename;
        }
        $$map{$base_filename} = $real_filename;
    }
}

sub read_courier_imap {
    my ( $dir, $filename_map ) = @_;

    my $imap_fname = "$dir/$courier_imap_uidfile";
    if ( !-f $imap_fname ) {
        print "$imap_fname: OK\n" if ( !$quiet );
        return;
    }

    my $f;
    open( $f, $imap_fname ) || die $!;
    my $imap_hdr = <$f>;
    if ( $imap_hdr !~ /^1 (\d+) (\d+)$/ ) {
        $global_error_count++;
        print STDERR "$imap_fname: Broken header: $imap_hdr\n";
        close $f;
        return;
    }
    my ( $uidv, $nextuid ) = ( $1, $2 );

    my %found_files;
    my $found_files_looked_up = 0;
    while (<$f>) {
        chomp $_;

        if (/^(\d+) (.*)$/) {
            my ( $uid, $full_fname ) = ( $1, $2 );

            # get the base filename
            my $fname = $full_fname;
            $fname =~ s/^([^:]+).*$/$1/;

            if ( defined $filename_map->{$fname} ) {
	      $global_error_count++;
	      print STDERR "$imap_fname: Duplicate entry: $fname\n";
            }
            else {
                $filename_map->{$fname} = [ $uid, $full_fname, "", $max_pop3_order ];
            }
            $nextuid = $uid + 1 if ($uid >= $nextuid);
        }
        else {
            $global_error_count++;
            print STDERR "$imap_fname: Broken entry: $_\n";
        }
    }
    close $f;

    return ( $uidv, $nextuid );
}

sub read_dovecot_uidlist {
    my ( $dir, $nextuid, $filename_map ) = @_;
    my $dovecot_uidfile = "$dir/$dovecot_uidfile";
    my @msguids;

    if ( !-f $dovecot_uidfile ) {
        print "$dovecot_uidfile: OK\n" if ( !$quiet );
	return ( "", $nextuid );
    }

    my $dovecot_uid_fh;
    my $guid = "";
    open( $dovecot_uid_fh, '<', $dovecot_uidfile ) || die $!;
    my $dovecot_hdr = readline($dovecot_uid_fh);
    if ( $dovecot_hdr =~ /^3 (.+)$/ ) {
        my $options = $1;
        foreach my $part ( split( /\s+/, $options ) ) {
            if ( $part =~ /(\w)(.+)/ ) {
                my $type = $1;
                my $val  = $2;
                if ( $type eq 'G' ) {
                    $guid = $val;
                }
            }
        }
    }
    else {
        $global_error_count++;
        print STDERR "$dovecot_uidfile: Broken header: $dovecot_hdr\n";
        close $dovecot_uid_fh;
	return ( "", $nextuid );
    }

    my $linenum = 0;
    while ( my $line = readline($dovecot_uid_fh) ) {
	$linenum++;
        chomp $line;
	if ($line =~ /^(\d+)( .*?)? :(.*)$/) {
	  my ($uid, $options, $full_fname) = ($1, $2, $3);
	  
	  $options = "" if (!defined($options));
	  foreach my $part ( split( /\s+/, $options ) ) {
	    if ( $part =~ /(\w)(.+)/ ) {
	      my $type = $1;
	      my $val  = $2;
	      if ( $type eq 'O' ) {
		print STDERR "$dovecot_uidfile: Already has POP3 order entries\n";
		close $dovecot_uid_fh;
		return ( "", $nextuid );
	      }
	    }
	  }
	  
	  # get the base filename
	  my $base_fname = $full_fname;
	  $base_fname =~ s/^([^:]+).*$/$1/;

	  if ( defined $filename_map->{$base_fname} ) {
	    # exists in courierimapuiddb, preserve UID
	    $filename_map->{$base_fname}->[1] = $full_fname;
	    $filename_map->{$base_fname}->[2] = $options;
	    $filename_map->{$base_fname}->[3] = $linenum;
	  }
	  else {
	    # pop3-only in dovecot-uidlist, give a new UID
	    $filename_map->{$base_fname} = [ $nextuid, $full_fname, $options, $max_pop3_order ];
	    $nextuid++;
	  }
	}
    }

    return ( $guid, $nextuid );
}

sub write_dovecot_uidlist {
    my ( $dir, $uidv, $nextuid, $guid, $owner_uid, $owner_gid, $filename_map ) = @_;
    
    my $uidlist_fname = "$dir/$dovecot_uidfile";
    return if ( !$do_conversion );

    die if ($uidv <= 0);

    my @files_by_uid = sort { 
      $filename_map->{$a}->[0] <=> $filename_map->{$b}->[0]
    } keys %{$filename_map};

    my @files_by_pop3_order = sort { 
      my $sort_ret = $filename_map->{$a}->[3] <=> $filename_map->{$b}->[3];
      if ($sort_ret == 0) {
	$sort_ret = $filename_map->{$a}->[0] <=> $filename_map->{$b}->[0];
      }
      return $sort_ret;
    } keys %{$filename_map};
    
    # remove all POP3 ordering from the end while it matches IMAP ordering
    for (my $i = (scalar @files_by_uid) - 1; $i >= 0; $i--) {
      last if ($files_by_uid[$i] ne $files_by_pop3_order[$i]);
      $filename_map->{$files_by_uid[$i]}->[3] = $max_pop3_order;
    }

    open( my $dovecot_uidlist_fh, '>', $uidlist_fname ) || die $!;
    print $dovecot_uidlist_fh "3 V$uidv N$nextuid";
    print $dovecot_uidlist_fh " G$guid" if ($guid ne "");
    print $dovecot_uidlist_fh "\n";
    foreach my $fname ( @files_by_uid ) {
        my $file_ar = $filename_map->{ $fname };
	print $dovecot_uidlist_fh $file_ar->[0] . $file_ar->[2];
	print $dovecot_uidlist_fh " O".$file_ar->[3] if ($file_ar->[3] != $max_pop3_order);
        print $dovecot_uidlist_fh ' :' . $file_ar->[1] . "\n";
    }
    close $dovecot_uidlist_fh;
    chown $owner_uid, $owner_gid, $uidlist_fname;
    $uidlist_write_count++;
}

sub convert_keywords {
    my ( $dir, $owner_uid, $owner_gid ) = @_;

    my $courier_mtime = ( stat("$dir/$courier_keywords_file") )[9] || 0;
    my $dovecot_mtime = ( stat("$dir/$dovecot_keywords_file") )[9] || 0;

    # No need to convert if there are no keywords files
    return unless ( $courier_mtime || $dovecot_mtime );

    # If we're doing auto-conversion, find the newest keywords file
    my $convert_to = $conversion_type;
    if ( $convert_to eq 'auto' ) {
        $convert_to = $dovecot_mtime > $courier_mtime ? 'courier' : 'dovecot';
    }

    if ( $convert_to eq 'dovecot' ) {
        # Courier to Dovecot keyword conversion
        my $keyword_dir      = "$dir/courierimapkeywords";
        my $dovecot_keyfname = "$dir/dovecot-keywords";

        if ( !-f "$keyword_dir/:list" ) {

            # no keywords
            return;
        }

        my ( %keywords, %files );
        my $f;
        open( $f, "$keyword_dir/:list" ) || die $!;

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
                foreach ( sort { $a <=> $b } split( " ", $2 ) ) {
                    $files{$fname} .= chr( 97 + $_ );
                }
            }
            else {
                print STDERR "$keyword_dir/:list: Broken entry: $_\n";
            }
        }
        close $f;

        # read updates from the directory
        my %updates;
        my @update_files;
        if ( opendir my $kw_dh, $keyword_dir ) {
            @update_files = readdir($kw_dh);
            closedir $kw_dh;
        }
        foreach (@update_files) {
            next if ( $_ eq ":list" || $_ eq "." || $_ eq ".." );

            my $fname = $_;
            if (/^\.(\d+)\.(.*)$/) {
                my ( $num, $base_fname ) = ( $1, $2 );
                if ( !defined $updates{$fname} ) {
                    $updates{$fname} = $num;
                }
                else {
                    my $old = $updates{$fname};
                    if ( $old >= 0 && $num > $old ) {
                        $updates{$fname} = $num;
                    }
                }
            }
            else {

                # "fname" overrides .n.fnames
                $updates{$fname} = -1;
            }
        }

        # apply the updates
        foreach ( keys %updates ) {
            my $base_fname = $_;
            my $num        = $updates{$_};

            my $fname;
            if ( $num < 0 ) {
                $fname = $base_fname;
            }
            else {
                $fname = ".$num.$base_fname";
            }

            my @kw_list;
            open( $f, "$keyword_dir/$fname" ) || next;
            while (<$f>) {
                chomp $_;
                my $kw = $_;
                my $idx;

                if ( defined $keywords{$kw} ) {
                    $idx = $keywords{$kw};
                }
                else {
                    $idx = scalar keys %keywords;
                    $keywords{$kw} = $idx;
                }
                $kw_list[ scalar @kw_list ] = $idx;
            }
            close $f;

            $files{$fname} = "";
            foreach ( sort { $a <=> $b } @kw_list ) {
                $files{$fname} .= chr( 97 + $_ );
            }
        }

        return if ( !$do_conversion );

        # write dovecot-keywords file
        open( $f, ">$dovecot_keyfname" ) || die $!;
        foreach ( sort { $keywords{$a} <=> $keywords{$b} } keys %keywords ) {
            my $idx = $keywords{$_};
            print $f "$idx $_\n";
        }
        close $f;
        chown $owner_uid, $owner_gid, $dovecot_keyfname;

        # update the maildir files
        my $cur_dir = "$dir/cur";
        my @cur_files;
        if ( opendir my $cur_dir_dh, $cur_dir ) {
            @cur_files = readdir($cur_dir_dh);
            closedir $cur_dir_dh;
        }
        foreach (@cur_files) {
            my $fname = $cur_dir . '/' . $_;

            my ( $base_fname, $flags, $extra_flags );
            if (/^([^:]+):2,([^,]*)(,.*)?$/) {
                ( $base_fname, $flags, $extra_flags ) = ( $1, $2, $3 );
                $extra_flags = "" if ( !defined $extra_flags );
            }
            else {
                $base_fname  = $fname;
                $flags       = "";
                $extra_flags = "";
            }

            if ( defined $files{$base_fname} ) {

                # merge old and new flags
                my %newflags;
                foreach ( sort split( "", $files{$base_fname} ) ) {
                    $newflags{$_} = 1;
                }
                foreach ( sort split( "", $flags ) ) {
                    $newflags{$_} = 1;
                }
                $flags = "";
                foreach ( sort keys %newflags ) {
                    $flags .= $_;
                }
                my $new_fname = "$cur_dir/$base_fname:2,$flags$extra_flags";
                if ( $fname ne $new_fname ) {
                    rename( $fname, $new_fname )
                      || print STDERR "rename($fname, $new_fname) failed: $!\n";
                }
            }
        }
    }
    else {

        # Dovecot to Courier keywords conversion
        return unless $dovecot_mtime;

        # Read Dovecot keywords list into memory
        open my $dovecot_kw_fh, '<', "$dir/$dovecot_keywords_file" || die $!;
        my %keywords;
        while ( my $line = readline($dovecot_kw_fh) ) {
            chomp $line;
            if ( $line =~ /(\d+)\s+(.+)/ ) {

                # Number then Keyword
                $keywords{$1} = $2;
            }
        }
        close $dovecot_kw_fh;

        # Scan files in cur for keywords
        my $cur_dir = "$dir/cur";
        my %file_keyword_map;

        my @cur_files;
        if ( opendir my $cur_dir_dh, $cur_dir ) {
            @cur_files = readdir($cur_dir_dh);
            closedir $cur_dir_dh;
        }
        foreach my $basename (@cur_files) {
            my $flags;
            my $extra_flags;
            my $keywords = '';

            # Split out and process flags
            if ( $basename =~ /^([^:]+):2,([^,]*)(,.*)?$/ ) {
                ( $basename, $flags, $extra_flags ) = ( $1, $2, $3 );
                $extra_flags = "" unless ( defined $extra_flags );
            }
            else {
                $basename    = "";
                $flags       = "";
                $extra_flags = "";
            }
            foreach my $key ( sort split( //, $flags ) ) {
                my $val = ord($key) - 97;
                next unless ( $val >= 0 && $val < 26 );
                next unless ( defined $keywords{$val} );
                $keywords .= ' ' . $val;
            }
            if ($keywords) {
                $keywords =~ s/^\s+//;
                $file_keyword_map{$basename} = $keywords;
            }
        }

        return unless ($do_conversion);

        # Make courier keywords directory if necessary
        my $key_dir = "$dir/$courier_keywords_dir";
        unless ( -d $key_dir ) {
            unlink $key_dir;
            mkdir $key_dir;
            chown $owner_uid, $owner_gid, $key_dir;
        }

        # Remove any old courier keywords files
        my @courier_keywords_files;
        if ( opendir my $courier_keywords_dh, $key_dir ) {
            @courier_keywords_files = readdir($courier_keywords_dh);
            closedir $courier_keywords_dh;
        }
        foreach my $file (@courier_keywords_files) {
            $file = $key_dir . $file;
            next unless -f $file;
            unlink $file;
        }

        # Write courier keywords list
        return unless ( scalar %keywords );
        open my $courier_kw_fh, '>', "$dir/$courier_keywords_file" || die $!;
        foreach my $num ( sort keys %keywords ) {
            print $courier_kw_fh $keywords{$num} . "\n";
        }
        print $courier_kw_fh "\n";
        foreach my $file ( sort keys %file_keyword_map ) {
            print $courier_kw_fh $file . ':' . $file_keyword_map{$file} . "\n";
        }
        close $courier_kw_fh;
        chown $owner_uid, $owner_gid, "$dir/$courier_keywords_file";
    }
}

sub convert_subscriptions {
    my ( $dir, $owner_uid, $owner_gid ) = @_;

    my $courier_mtime = ( stat("$dir/$courier_subscriptions_file") )[9] || 0;
    my $dovecot_mtime = ( stat("$dir/$dovecot_subscriptions_file") )[9] || 0;

    # No need to convert if there is no subscriptions files
    return unless ( $courier_mtime || $dovecot_mtime );

    # If we're doing auto-conversion, find the newest subscription file
    my $convert_to = $conversion_type;
    if ( $convert_to eq 'auto' ) {
        $convert_to = $dovecot_mtime > $courier_mtime ? 'courier' : 'dovecot';
    }

    my $src_file  = "$dir/$dovecot_subscriptions_file";
    my $dst_file  = "$dir/$courier_subscriptions_file";
    my $src_mtime = $dovecot_mtime;
    my $dst_mtime = $courier_mtime;
    if ( $convert_to eq 'dovecot' ) {
        $src_file  = "$dir/$courier_subscriptions_file";
        $dst_file  = "$dir/$dovecot_subscriptions_file";
        $src_mtime = $courier_mtime;
        $dst_mtime = $dovecot_mtime;
    }

    # Sanity checks..
    if ( $dst_mtime && !-f $dst_file ) {
        print "$dst_file already exists as something other than a file\n" if ( !$quiet );
        return;
    }
    unless ($src_mtime) {
        return;
    }
    unless ( -f $src_file ) {
        print "$src_file isn't a regular file\n" if ( !$quiet );
        return;
    }

    return unless ($do_conversion);

    open( my $src_fh, '<', $src_file ) || die $!;
    open( my $dst_fh, '>', $dst_file ) || die $!;
    while ( my $line = readline($src_fh) ) {
        chomp $line;
        if ( $line =~ /^INBOX$/i ) {
            print $dst_fh "INBOX\n";
        }
        elsif ( $convert_to eq 'dovecot' ) {
            if ( $line =~ /^INBOX\.(.*)$/i ) {
                print $dst_fh "$1\n";
            }
            else {

                # Unknown. The dovecot migrate script leaves these as-is...
                print $dst_fh "$line\n";
            }
        }
        else {

            # converting to Courier INBOX namespace
            if ( $line =~ /\S/ ) {
                print $dst_fh "INBOX.$line\n";
            }
        }
    }
    close $src_fh;
    close $dst_fh;
    chown $owner_uid, $owner_gid, $dst_file;
}

sub check_maildir_single {
    my ( $dir, $childbox ) = @_;

    $dir =~ s{^\./}{}g;

    my $owner_uid;
    my $owner_gid;

    # Store the relevant stats()
    my @courier_imap_stat = stat("$dir/$courier_imap_uidfile");
    my @dovecot_stat      = stat("$dir/$dovecot_uidfile");

    # Gather mtimes
    my $courier_imap_mtime = ( scalar @courier_imap_stat > 0 ) ? $courier_imap_stat[9] : 0;
    my $dovecot_mtime      = ( scalar @dovecot_stat > 0 )      ? $dovecot_stat[9]      : 0;

    # Determine conversion type
    my $convert_uidl_to = $conversion_type;

    # To Dovecot
    unless ( $courier_imap_mtime ) {
	print "$dir: No imap uidlist file\n" if ( !$quiet && !$childbox );
	return;
    }

    $owner_uid = $courier_imap_stat[4];
    $owner_gid = $courier_imap_stat[5];

    my $filename_map = {};
    my $guid = "";
    my ( $uidv, $nextuid ) = read_courier_imap( $dir, $filename_map );
    ( $guid, $nextuid ) = read_dovecot_uidlist( $dir, $nextuid, $filename_map );
    
    return if (!defined($nextuid)); # broken uidlist
    
    $global_mailbox_count++;
    write_dovecot_uidlist( $dir, $uidv, $nextuid, $guid, $owner_uid, $owner_gid, $filename_map );
    remove_dovecot_caches($dir);

    # If we get here we did a UIDL conversion.  Now convert subscriptions and keywords

    convert_subscriptions( $dir, $owner_uid, $owner_gid );
    convert_keywords( $dir, $owner_uid, $owner_gid );
}

sub remove_dovecot_caches {
    my $dir = shift;
    foreach my $file ( qw(dovecot.index dovecot.index.cache dovecot.index.log dovecot.index.log2) ) {
        unlink $dir . '/' . $file;
    }
}

sub check_maildir {
    my ($dir) = @_;

    my $orig_mailboxes = $global_mailbox_count;

    check_maildir_single( $dir, 0 );
    my @check_maildir_files;
    if ( opendir my $check_maildir_dh, $dir ) {
        @check_maildir_files = readdir($check_maildir_dh);
        closedir $check_maildir_dh;
    }
    foreach my $file (@check_maildir_files) {
        next unless ( $file =~ /^\./ );
        next if ( $file =~ /^\.?\.$/ );
        $file = $dir . '/' . $file;
        next if ( -l $file );
        check_maildir_single( $file, 1 );
    }

    $global_user_count++ if ( $orig_mailboxes != $global_mailbox_count );
}

sub is_maildir {
    my ($dir) = @_;

    # Do we need to check for the courier specific files here or is it enough to assume every maildir will have a cur directory?
    return ( -f "$dir/$courier_imap_uidfile" || -d "$dir/cur" );
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
    print "Usage: courier-dovecot-merge [options] <maildir>\n\n";
    print "Options:\n";
    print "    --convert       Perform conversion\n";
    print "    --quiet         Silence output\n";
    print "    --recursive     Recursively look through maildir for subaccounts\n";
    exit 0;
}

