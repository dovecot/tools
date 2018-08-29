#!/bin/sh

# Run: maildir-metadata.sh user@domain
# or : maildir-metadata.sh /home/user/Maildir
#
# This creates ~/dovecot-metadata*.tar.gz file, which contains Dovecot index
# files and other metadata files. They don't contain any other sensitive
# information than mailbox names and mail keywords.

set -e

if [ "$1" = "" ]; then
  echo "Usage: $0 <user>|<path>" >&2
  exit 1
fi
if [ -d $1 ]; then
  home=$1
else
  home=`doveadm user -m -f home $1`
fi

destname=dovecot-metadata-`date +%Y%m%d-%H%M%S`
destdir=$HOME/$destname

cd $home
if [ -d Maildir ]; then
  cd Maildir
elif [ ! -d cur ]; then
  echo "$home is not a Maildir" >&2
  exit 1
fi

mkdir $destdir
ls -laR > $destdir/ls-laR
ls -lacR > $destdir/ls-lacR

(echo subscriptions; find . -name dovecot.index -o -name 'dovecot.index.log*' -o -name dovecot-uidlist -o -name 'courier*') |
  tar cf $destdir/metadata.tar -T -

cd $HOME
tar czf $destname.tar.gz $destname
echo "$HOME/$destname.tar.gz created"

rm -f $destdir/ls-laR $destdir/ls-lacR $destdir/metadata.tar
rmdir $destdir
