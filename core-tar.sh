#!/bin/sh

# Usage: ./core-tar.sh <binary> <core> <dest.tar.gz>
#
# For example: ./core-tar.sh /usr/libexec/dovecot/imap /var/core/core.1234 imap-core.1234.tar.gz

# Script for creating a tar.gz file containing a core file and all the
# binary + shared libraries that are needed to read the core dump.
# Also include the exact Dovecot version (dovecot --version) and how it
# was created (self-build, distribution package, etc) so that the matching
# debuginfo packages can be found.

binary=$1
core=$2
dest=$3

if [ "$binary" = "" ] || [ "$core" = "" ] || [ "$dest" = "" ]; then
  echo "Usage: $0 <binary> <core> <dest.tar.gz>"
  exit 1
fi

if ! [ -r "$binary" ]; then
  echo "$binary not readable"
  exit 1
fi
if ! [ -s "$core" ]; then
  echo "$core not found / is empty"
  exit 1
fi

gdb=`which gdb`
if [ "$gdb" = "" ]; then
  echo "gdb not found"
  exit 1
fi

(echo "info shared"; sleep 1) |
  $gdb $binary $core |
  grep '^0x.*/' | sed 's,^[^/]*,,' |
  xargs tar czf $dest --dereference $binary $core
