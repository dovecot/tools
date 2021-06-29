#!/bin/bash

directors=4

while true; do
  IP=`expr $RANDOM % 255`
  IP=`expr $IP + 1`
  vhost1=`expr $RANDOM % 101`
  vhost2=`expr $RANDOM % 101`
  dir1=`expr $RANDOM % $directors`
  dir1=`expr $dir1 + 1`
  dir2=`expr $RANDOM % $directors`
  dir2=`expr $dir1 + 1`
  doveadm director update -a /var/run/dovecot/director$dir1-admin 127.0.2.$IP $vhost1
  doveadm director update -a /var/run/dovecot/director$dir2-admin 127.0.2.$IP $vhost2
  sleep 1
done
