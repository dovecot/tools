#!/bin/sh -e

# Make an obfuscated copy of mdbox using mdbox-obfuscate.pl, which needs
# to exist in the same directory. The indexes are copied without
# dovecot.index.cache files.

obfuscate_script=`dirname $0`/mdbox-obfuscate.pl
src=$1
dest=$2

if [ "$dest" = "" ]; then
  echo "Usage: <src mdbox directory> <dest obfuscated mdbox directory>"
  exit 1
fi

if [ ! -x $obfuscate_script ]; then
  if [ ! -f $obfuscate_script ]; then
    echo "$obfuscate_script doesn't exist" >&2
  else
    echo "$obfuscate_script isn't executable" >&2
  fi
  exit 1
fi

if [ ! -d $src/storage ]; then
  echo "not an mdbox path: $src/storage doesn't exist" >&2
  exit 1
fi

if [ -d $dest ]; then
  echo "$dest already exists" >&2
  exit 1
fi

mkdir -p $dest/storage
# copy storage
for src_path in $src/storage/m.*; do
  fname=`basename $src_path`
  $obfuscate_script < $src_path > $dest/storage/$fname
done
cp $src/storage/dovecot* $dest/storage/

# copy indexes without .cache files
cp -r $src/mailboxes $dest/
find $dest/mailboxes -name dovecot.index.cache -print0 | xargs -0 rm
