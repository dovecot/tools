#!/usr/bin/perl -w
############################################################
#
# File: mig.pl
#
# Authors:       gerald hermant <dev.gerald.hmt@free.fr>
#             
# Maintainer:    $Author: ghermant $
#                gerald hermant <dev.gerald.hmt@free.fr>
# Created:       Thu Dec  2 15:52:29 2004
# Last CVS Date: $Date: 2004/12/26 10:04:16 $
# Last Modified: Sun Dec 26 11:04:00 2004 by gerald hermant <dev.gerald.hmt [at] free.fr>
# Version:       $Revision: 1.4 $
# Keywords:      
#
# Licence 2004 - GNU General Public License 2 or newer
# Additional request is that you include author's name and email on all copies
# $Header: /home/cvsroot/dev/mini-tools/migration_wuimp_to_dovecot/src/migration_wuimp_to_dovecot.pl,v 1.4 2004/12/26 10:04:16 ghermant Exp $
# Description: This tool migrate wuimp configuration mail box and subscribe to dovecot standand file name
#
#              Call it with all personal directory in stdin
#              ls /home/ | ./migration_wuimp_to_dovecot.pl
#              or ls /home > /tmp/account.txt ; ./migration_wuimp_to_dovecot.pl /tmp/account.txt
#
# See informations on : http://wiki.dovecot.org/moin.cgi/Migration
#
############################################################/

require 'dumpvar.pl';
use strict qw(refs vars subs);
use diagnostics;
use Fcntl;
use FileHandle;
use File::Basename;

print ("[Starting at " . gmtime() . " - Ctrl-D for help]\n");
my $gNbProcess = 0;
while ( my $ligne = <> ) {
  $gNbProcess++;
  chomp($ligne);
  print ("[*** WORKING on $ligne : ]\n");

# TODO : Gestion d'un .lock de compte avant les modifications
# TODO : use a .lock for avoid concurent modifications or stop imap services before run this script

  my $userName= basename($ligne);
  my ($login,$pass,$uid,$gid) = getpwnam($userName);
  if (!defined($uid)) {$uid=0;}
  if (!defined($gid)) {$gid=0;}

  my @LISTE_MAILBOX = ();
  my $gNoDotMailboxWarn=0;
  print (" user : $userName ,  uid=$uid, gid=$gid\n");

  if ( ! ( -d "$ligne/mail") && ! mkdir ("$ligne/mail")) {
    print ("[ERROR : Can't mkdir $ligne/mail : $!]\n");
    print (" [SKIP]\n");
    #die ("Can't mkdir $ligne/mail : $!");
    next;
  };
  chown($uid, $gid , "$ligne/mail");
  ( -d "$ligne/mail/impfolders") || mkdir ("$ligne/mail/impfolders") || die ("Can't mkdir $ligne/mail/impfolders : $!");
  chown($uid, $gid , "$ligne/mail/impfolders");
  if ( -r "$ligne/.mailboxlist" ) {
    print ("#Process $ligne/.mailboxlist...\n");
    open (MAILBOXLIST , "$ligne/.mailboxlist") || die ("Can't open $ligne/.mailboxlist : $!");
    while ( my $file = <MAILBOXLIST> ) {
      chomp($file);
      print (" in $ligne/ rename $file to mail/$file ");
      if ( -e "$ligne/$file") {
	rename ("$ligne/$file" , "$ligne/mail/$file") || die ("Can't rename '$ligne/$file ' to '$ligne/mail/$file'");
	push (@LISTE_MAILBOX , $file);
	print ("OK\n");
	print ("#Add LISTE_MAILBOX : $file\n");
      } else {
	print ("\n [WARNING : $ligne/$file Don't EXIST]\n");
	if ( -e "$ligne/mail/$file" ) {	push(@LISTE_MAILBOX , $file);}
      }
    }
    close (MAILBOXLIST);
  } else {
    print ("[WARNING: NO $ligne/.mailboxlist File]\n");
    $gNoDotMailboxWarn=1;
  }

# Rajout des anciens elements encores présents dans le répertoire ~/impfolders/ en tant que mail/impfolders/OLD_xxx
# Add old part still here in directory ~/impfolders/ to mail/impfolders/OLD_xxx
  if ( -d "$ligne/impfolders" ) {
    if (opendir (OLDFILES , "$ligne/impfolders")) {
      while (my $dirent = readdir(OLDFILES)) {
	if ($dirent ne "." && $dirent ne ".." ) {
	  my $NEWNAME = "OLD-$dirent";
	  if (-e "$ligne/mail/impfolders/$NEWNAME") {$NEWNAME .= int(rand(100));}

# TODO : gestion des sous répertoires exp impfolder/job/stage
# en créant le répertoire de destination...
	  print (" in $ligne/ rename impfolders/$dirent to mail/impfolders/$NEWNAME ");
	  rename ("$ligne/impfolders/$dirent" , "$ligne/mail/impfolders/$NEWNAME") || die ("Can't rename '$ligne/impfolders/$dirent ' to '$ligne/mail/impfolders/$NEWNAME'");
	  push (@LISTE_MAILBOX , "impfolders/$NEWNAME");
	  print ("OK\n");
	  print (" Rajout LISTE_MAILBOX : impfolders/$NEWNAME\n");
	}
      }
    }
    print (" Delete empty $ligne/impfolders\n");
    rmdir("$ligne/impfolders") || print  ("\n [WARNING : Can't delete $ligne/impfolders : $!]\n");
  }
  # Merge with still subscribe
  my @tab_copie = @LISTE_MAILBOX;
  while ( $_ = pop (@tab_copie)) {print (" Still : $_\n");}
  print (" Merge with .sub still exist ...\n");
  if (-r "$ligne/mail/.subscriptions" ) {
    open (LIST_SUB , "$ligne/mail/.subscriptions") || die ("Can't read $ligne/mail/.subscriptions : $!");
    while (my $lineSUB = <LIST_SUB> ) {
      chomp($lineSUB);
      push(@LISTE_MAILBOX ,  $lineSUB );
      print(" Rajout liste : $lineSUB\n");
    }
    close(LIST_SUB);
  }
  @LISTE_MAILBOX = sort(@LISTE_MAILBOX);
  open (LIST_SUB , "> $ligne/mail/.subscriptions") || die ("Cant open $ligne/mail/.subscriptions for write it : $!");
  while (my $l = pop (@LISTE_MAILBOX)) {
    print ( LIST_SUB  "$l\n");
    print (" Ecriture dans .sub de '$l'\n");
  }
  close(LIST_SUB);
  chown($uid, $gid , "$ligne/mail/.subscriptions");
  print ("OK\n");
  if (!$gNoDotMailboxWarn) {
    print (" unlink : $ligne/.mailboxlist ...\n");
    unlink  ( "$ligne/.mailboxlist") || print (" [WARNING : Can't unlink $ligne/.mailboxlist : $!]\n");
  }
}
if (!$gNbProcess) {
  print ("\nCall this migration tool with list of account you want migrate from wuimp to dovecot\n");
  print ('Version : $Revision: 1.4 $  $Date: 2004/12/26 10:04:16 $'."\n");
  print ("You can apply this tool many time on same account (it's not a destructive tool)\n");
  print ("\n sample : ls /home/ | ./migration_wuimp_to_dovecot.pl\n");
  print (  " sample : ls /home > /tmp/account.txt ; ./migration_wuimp_to_dovecot.pl /tmp/account.txt\n");
  exit (1);
}
exit (0);
