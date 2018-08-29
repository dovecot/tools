#!/bin/sh

# NOTE: OBSOLETE - use maildir-size-fix.pl (v1.1+) instead

# Usage: maildir-size-check.sh [-f] /path/to/Maildir

# -f actually renames the files. The downside to actually fixing the sizes is
# that it doesn't update dovecot-uidlist file, so the mails will get new UIDs.
# maildir-size-fix.pl script doesn't have this problem, but it doesn't support
# compressed mails... Someone please merge these. :)

fix_with_rename=no

if [ "$1" = "-f" ]; then
  fix_with_rename=yes
  shift
fi

root=$1

find "$root" -print | while read path; do
  if echo "$path"|grep -q "$root.*/cur/" || echo "$path"|grep -q "$root.*/new/"; then
    if echo "$path" | grep -q ',S=[0-9]'; then
      maildir_s=`echo "$path"|sed 's/.*,S=\([0-9]*\).*/\1/'`
    else
      maildir_s=""
    fi
    if echo "$path" | grep -q ',W=[0-9]'; then
      maildir_w=`echo "$path"|sed 's/.*,W=\([0-9]*\).*/\1/'`
    else
      maildir_w=""
    fi
    
    type=`file -k "$path"`
    tmppath=`mktemp`
    if echo $type|grep -q gzip; then
      cat "$path" | gunzip > $tmppath
      sizes=`wc $tmppath`
      type2=`file -k $tmppath`
    elif echo $type|grep -q bzip2; then
      cat "$path" | bunzip2 > $tmppath
      sizes=`wc $tmppath`
      type2=`file -k $tmppath`
    else
      sizes=`wc "$path"`
      type2=""
    fi
    rm -f $tmppath

    lines=`echo $sizes|awk '{print $1}'`
    bytes=`echo $sizes|awk '{print $3}'`
    if echo $type2|grep -q 'gzip\|bzip2'; then
      echo "$path: Double compressed"
    elif [ "$type2" != "" -a "$maildir_s" = "" ]; then
      echo "$path: Compressed file missing S=$bytes"
    else
      vbytes=`expr $lines + $bytes`
      if [ "$maildir_s" != "" -a "$bytes" != "$maildir_s" ]; then
        echo "$path: Wrong S=$maildir_s value, should be S=$bytes"
        if [ "$fix_with_rename" = "yes" ]; then
	  new_path=`echo "$path"|sed "s/\\(.*\\),S=[0-9]*\\(.*\\)\$/\\1,S=$bytes\\2/"`
	  mv "$path" "$new_path"
	  path=$new_path
	fi
      fi
      if [ "$maildir_w" != "" -a "$vbytes" != "$maildir_w" ]; then
        echo "$path: Wrong W=$maildir_w value, should be W=$vbytes"
        if [ "$fix_with_rename" = "yes" ]; then
	  new_path=`echo "$path"|sed "s/\\(.*\\),W=[0-9]*\\(.*\\)\$/\\1,W=$vbytes\\2/"`
	  mv "$path" "$new_path"
	  path=$new_path
	fi
      fi
    fi
  fi
done
