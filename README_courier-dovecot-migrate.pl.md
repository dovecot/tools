Courier IMAP/POP3
=================

**WARNING: Badly done migration will cause your IMAP and/or POP3 clients to re-download all mails. Read [Migration](https://doc.dovecot.org/admin_manual/migrating_mailboxes/) page first carefully.**

Courier v0.43 and later to Dovecot v1.1+
----------------------------------------

[courier-dovecot-migrate.pl](courier-dovecot-migrate.pl) does a perfect migration from Courier IMAP and POP3, preserving IMAP UIDs and POP3 UIDLs. It reads Courier's `courierimapuiddb` and `courierpop3dsizelist` files and produces `dovecot-uidlist` files from it.

Before doing the actual conversion you can run the script and see if it complains about any errors and such, e.g.:

```
# ./courier-dovecot-migrate.pl --to-dovecot --recursive /home
Finding maildirs under /home
/home/user/Maildir/dovecot-uidlist already exists, not overwritten
/home/user/Maildir2: No imap/pop3 uidlist files
Total: 69 mailboxes / 6 users
       0 errors
No actual conversion done, use --convert parameter
```
The actual conversion can be done for all users at once by running the script with `--convert --recursive` parameters, e.g.:

    ./courier-dovecot-migrate.pl --to-dovecot --convert --recursive /home

Make sure the conversion worked by checking that `dovecot-uidlist` files were created to all maildirs (including to subfolders).

The `--recursive` option goes through only one level down in directory hierarchies. This means that if you have some kind of a directory hashing scheme (or even domain/username/), it won't convert all of the files.

You can also convert each user as they log in for the first time, using [PostLoginScripting](https://doc.dovecot.org/admin_manual/post_login_scripting/) with a script something like:
```
#!/bin/sh
# WARNING: Be sure to use mail_drop_priv_before_exec=yes,
# otherwise the files are created as root!

courier-dovecot-migrate.pl --quiet --to-dovecot --convert Maildir
# This is for imap, create a similar script for pop3 too
exec /usr/local/libexec/dovecot/imap
```
FIXME: The script should rename also folder names that aren't valid mUTF-7. Dovecot can't otherwise access such folders.

Dovecot configuration
---------------------

Courier by default uses "INBOX." as the IMAP namespace for private mailboxes. If you want a transparent migration, you'll need to configure Dovecot to use a namespace with "INBOX." prefix as well.
```
mail_location = maildir:~/Maildir

namespace {
  prefix = INBOX.
  separator = .
  inbox = yes
}
```

### Source:
https://web.archive.org/web/20161208093331/http://wiki.dovecot.org/Migration/Courier
