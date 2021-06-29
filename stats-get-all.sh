#!/bin/sh

hosts="backend1 backend2 backend3"
cmd="/usr/local/bin/doveadm stats dump user"

tmpfile=`mktemp`
trap "rm -f $tmpfile" 0 1 2 3 15

first=1
for host in $hosts; do
  if [ $first = 1 ]; then
    echo $cmd | ssh $host > $tmpfile
    first=0
  else
    echo $cmd | ssh $host | tail -n +2 > $tmpfile
  fi
done
cat $tmpfile
