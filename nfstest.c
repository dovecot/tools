/*
   Compile:

   gcc nfstest.c -o nfstest -g -Wall -W

   On machine 1 use:

   ./nfstest <port> <path to a test file>

   On machine 2 use:

   ./nfstest <machine 1 hostname> <machine 1 port> <path to the same test file>

   Machine 2 must be NFS client. It probably doesn't matter if machine 1 is
   NFS client or the server, but run it in another NFS client just to be safe.

   The test file must not be in the current directory, or the test will fail
   in rmdir(".").
*/

#if !defined(__sun) && !defined(_AIX)
#  define HAVE_FLOCK
#endif

#if defined(__linux__) || defined(__sun)
#  define ST_NSECS(st) (st).st_mtim.tv_nsec
#  define HAVE_ST_NSECS
#elif defined (__FreeBSD__) || defined(__APPLE__)
#  define ST_NSECS(st) (st).st_mtimespec.tv_nsec
#  define HAVE_ST_NSECS
#else
#  define ST_NSECS(st) 0
#endif

#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>

#define __USE_GNU
#include <fcntl.h>
#include <unistd.h>
#include <assert.h>
#include <errno.h>
#include <time.h>
#include <sys/time.h>
#include <sys/stat.h>
#ifdef HAVE_FLOCK
#  include <sys/file.h>
#endif

#include <sys/socket.h>
#include <netinet/in.h>
#include <netdb.h>
#include <arpa/inet.h>

enum nfs_cache_flush_method {
	NFS_CACHE_FLUSH_METHOD_NONE,
	NFS_CACHE_FLUSH_METHOD_OPEN_CLOSE,
	NFS_CACHE_FLUSH_METHOD_CLOSE_OPEN,
	NFS_CACHE_FLUSH_METHOD_FCHOWN_1_1,
	NFS_CACHE_FLUSH_METHOD_FCHOWN_UID,
	NFS_CACHE_FLUSH_METHOD_FCHMOD,
	NFS_CACHE_FLUSH_METHOD_CHOWN_1_1,
	NFS_CACHE_FLUSH_METHOD_CHOWN_UID,
	NFS_CACHE_FLUSH_METHOD_CHMOD,
	NFS_CACHE_FLUSH_METHOD_RMDIR,
	NFS_CACHE_FLUSH_METHOD_RMDIR_PARENT,
	NFS_CACHE_FLUSH_METHOD_DUP_CLOSE,
	NFS_CACHE_FLUSH_METHOD_FCNTL_SHARED,
	NFS_CACHE_FLUSH_METHOD_FCNTL_EXCL,
#ifdef HAVE_FLOCK
	NFS_CACHE_FLUSH_METHOD_FLOCK_SHARED,
	NFS_CACHE_FLUSH_METHOD_FLOCK_EXCL,
#endif
	NFS_CACHE_FLUSH_METHOD_FSYNC,
	NFS_CACHE_FLUSH_METHOD_O_SYNC,
#ifdef O_DIRECT
	NFS_CACHE_FLUSH_METHOD_O_DIRECT,
#endif

	NFS_CACHE_FLUSH_METHOD_COUNT
};
static const char *
nfs_cache_flush_method_names[NFS_CACHE_FLUSH_METHOD_COUNT] = {
	"no caching",
	"open+close",
	"close+open",
	"fchown(-1, -1)",
	"fchown(uid, -1)",
	"fchmod(mode)",
	"chown(-1, -1)",
	"chown(uid, -1)",
	"chmod(mode)",
	"rmdir()",
	"rmdir(parent dir)",
	"dup+close",
	"fcntl(shared)",
	"fcntl(exclusive)",
#ifdef HAVE_FLOCK
	"flock(shared)",
	"flock(exclusive)",
#endif
	"fsync()",
	"fcntl(O_SYNC)"
#ifdef O_DIRECT
	,"O_DIRECT"
#endif
};

static int reverse = 0;

static void i_errorv(const char *fmt, va_list args)
{
	char fmt2[1024];
	unsigned int len = strlen(fmt);
	int orig_errno = errno;

	if (len > 2 && strcmp(fmt + len-2, "%m") == 0) {
		snprintf(fmt2, len-1, "%s", fmt);
		fmt = fmt2;
	}

	vprintf(fmt, args);
	if (fmt == fmt2)
		printf("%s", strerror(orig_errno));
	printf("\n");
}

static void i_error(const char *fmt, ...)
{
	va_list args;

	va_start(args, fmt);
	i_errorv(fmt, args);
	va_end(args);
}

static void i_fatal(const char *fmt, ...)
{
	va_list args;

	va_start(args, fmt);
	i_errorv(fmt, args);
	va_end(args);
	exit(1);
}

static void fcntl_lock(int fd, int lock_type)
{
	struct flock fl;

	fl.l_type = lock_type;
	fl.l_whence = SEEK_SET;
	fl.l_start = 0;
	fl.l_len = 0;

	if (fcntl(fd, F_SETLK, &fl) < 0) {
		i_error("fcntl(setlk, %s) failed: %m",
			lock_type == F_UNLCK ? "unlock" :
			(lock_type == F_RDLCK ? "read" : "write"));
	}
}

static void nfs_cache_flush_before(const char *path, int *fd_p,
				   enum nfs_cache_flush_method method)
{
	char *p, dir[1024];
	int fd = fd_p == NULL ? -1 : *fd_p;
	struct stat st;
	int fd2, old_flags;
	off_t old_offset;

	switch (method) {
	case NFS_CACHE_FLUSH_METHOD_NONE:
		break;
	case NFS_CACHE_FLUSH_METHOD_OPEN_CLOSE:
		fd2 = open(path, O_RDWR);
		if (fd2 != -1)
			close(fd2);
		break;
	case NFS_CACHE_FLUSH_METHOD_CLOSE_OPEN:
		if (fd == -1)
			break;
		old_offset = lseek(fd, 0, SEEK_CUR);
		old_flags = fcntl(fd, F_GETFL, 0);
		close(fd);
		*fd_p = fd = open(path, old_flags);
		if (fd == -1)
			i_fatal("flush reopen: open(%s) failed: %m");
		lseek(fd, old_offset, SEEK_CUR);
		break;
#ifdef O_DIRECT
	case NFS_CACHE_FLUSH_METHOD_O_DIRECT:
		if (fd == -1)
			break;
		old_flags = fcntl(fd, F_GETFL, 0);
		if (fcntl(fd, F_SETFL, old_flags | O_DIRECT) < 0)
			i_error("fcntl(%s, O_DIRECT) failed: %m", path);
		break;
#endif
	case NFS_CACHE_FLUSH_METHOD_O_SYNC:
		if (fd == -1)
			break;
		old_flags = fcntl(fd, F_GETFL, 0);
		if (fcntl(fd, F_SETFL, old_flags | O_SYNC) < 0)
			i_error("fcntl(%s, O_SYNC) failed: %m", path);
		break;
	case NFS_CACHE_FLUSH_METHOD_FCHOWN_1_1:
		if (fd == -1)
			break;
		if (fchown(fd, (uid_t)-1, (gid_t)-1) < 0)
			i_fatal("fchown(-1, -1) failed: %m");
		break;
	case NFS_CACHE_FLUSH_METHOD_FCHOWN_UID:
		if (fd == -1)
			break;
		if (fstat(fd, &st) < 0)
			i_fatal("fstat() failed: %m");
		if (fchown(fd, st.st_uid, (gid_t)-1) < 0 && errno != EPERM)
			i_fatal("fchown() failed: %m");
		break;
	case NFS_CACHE_FLUSH_METHOD_FCHMOD:
		if (fd == -1)
			break;
		if (fstat(fd, &st) < 0)
			i_fatal("fstat() failed: %m");
		if (fchmod(fd, st.st_mode) < 0)
			i_fatal("fchmod() failed: %m");
		break;
	case NFS_CACHE_FLUSH_METHOD_CHOWN_1_1:
		if (chown(path, (uid_t)-1, (gid_t)-1) < 0)
			i_fatal("chown(-1, -1) failed: %m");
		break;
	case NFS_CACHE_FLUSH_METHOD_CHOWN_UID:
		if (stat(path, &st) < 0)
			i_fatal("stat(%s) failed: %m", path);
		if (chown(path, st.st_uid, (gid_t)-1) < 0)
			i_fatal("chown() failed: %m");
		break;
	case NFS_CACHE_FLUSH_METHOD_CHMOD:
		if (stat(path, &st) < 0)
			i_fatal("stat(%s) failed: %m", path);
		if (chmod(path, st.st_mode) < 0)
			i_fatal("chmod() failed: %m");
		break;
	case NFS_CACHE_FLUSH_METHOD_RMDIR_PARENT:
		p = strrchr(path, '/');
		if (p == NULL)
			strcpy(dir, ".");
		else
			snprintf(dir, p-path+1, "%s", path);
		path = dir;
		/* fall through */
	case NFS_CACHE_FLUSH_METHOD_RMDIR:
		if (rmdir(path) == 0)
			i_fatal("Oops, rmdir(%s) actually worked", path);
		else if (errno != ENOTEMPTY && errno != ENOTDIR &&
			 errno != EBUSY && errno != EEXIST)
			i_error("rmdir(%s) failed: %m", path);
		break;
	case NFS_CACHE_FLUSH_METHOD_DUP_CLOSE:
		if (fd == -1)
			break;
		fd2 = dup(fd);
		if (fd2 < 0)
			i_fatal("dup() failed: %m");
		if (close(fd2) < 0)
			i_fatal("close(duped) failed: %m");
		break;
	case NFS_CACHE_FLUSH_METHOD_FCNTL_SHARED:
		if (fd == -1)
			break;
		fcntl_lock(fd, F_RDLCK);
		break;
	case NFS_CACHE_FLUSH_METHOD_FCNTL_EXCL:
		if (fd == -1)
			break;
		fcntl_lock(fd, F_WRLCK);
		break;
#ifdef HAVE_FLOCK
	case NFS_CACHE_FLUSH_METHOD_FLOCK_SHARED:
		if (fd == -1)
			break;
		if (flock(fd, LOCK_SH | LOCK_NB) < 0)
			i_error("flock() failed: %m");
		break;
	case NFS_CACHE_FLUSH_METHOD_FLOCK_EXCL:
		if (fd == -1)
			break;
		if (flock(fd, LOCK_EX | LOCK_NB) < 0)
			i_error("flock() failed: %m");
		break;
#endif
	case NFS_CACHE_FLUSH_METHOD_FSYNC:
		if (fd == -1)
			break;
		if (fsync(fd) < 0)
			i_fatal("fsync() failed: %m");
		break;
	case NFS_CACHE_FLUSH_METHOD_COUNT:
		abort();
	}
}

static void nfs_cache_flush_after(const char *path, int *fd_p,
				  enum nfs_cache_flush_method method)
{
	int old_flags, fd = fd_p == NULL ? -1 : *fd_p;

	switch (method) {
	case NFS_CACHE_FLUSH_METHOD_FCNTL_SHARED:
	case NFS_CACHE_FLUSH_METHOD_FCNTL_EXCL:
		if (fd == -1)
			break;
		fcntl_lock(fd, F_UNLCK);
		break;
#ifdef HAVE_FLOCK
	case NFS_CACHE_FLUSH_METHOD_FLOCK_SHARED:
	case NFS_CACHE_FLUSH_METHOD_FLOCK_EXCL:
		if (fd == -1)
			break;
		flock(fd, LOCK_UN);
		break;
#endif
	case NFS_CACHE_FLUSH_METHOD_O_SYNC:
#ifdef O_DIRECT
	case NFS_CACHE_FLUSH_METHOD_O_DIRECT:
#endif
		if (fd == -1)
			break;
		old_flags = fcntl(fd, F_GETFL, 0);
		old_flags &= ~O_SYNC;
#ifdef O_DIRECT
		old_flags &= ~O_DIRECT;
#endif
		if (fcntl(fd, F_SETFL, old_flags) < 0)
			i_error("fcntl(%s, restore flags) failed: %m", path);
		break;
	default:
		/* when flushing writes we called _before() before doing the
		   write. to get these methods working we have to do it
		   afterwards.. */
		nfs_cache_flush_before(path, fd_p, method);
		break;
	}
}

static void send_cmd(int fd, char cmd)
{
	if (write(fd, &cmd, 1) != 1)
		i_fatal("write(cmd) failed: %m");
}

static char read_cmd(int fd)
{
	int ret;
	char cmd;

	ret = read(fd, &cmd, 1);
	if (ret <= 0) {
		if (ret == 0)
			i_fatal("Connection lost");
		i_fatal("read(cmd) failed: %m");
	}
	return cmd;
}

static void wait_cmd(int fd, char wanted_cmd)
{
	char cmd;

	cmd = read_cmd(fd);
	if (wanted_cmd != cmd)
		i_fatal("Unexpected command: %c != %c", cmd, wanted_cmd);
}

static int nfs_safe_open(const char *path, int flags)
{
	int fd, i;

	for (i = 0; i < 10; i++) {
		fd = open(path, flags);
		if (fd != -1 || errno != ESTALE)
			break;
	}
	return fd;
}

static int nfs_safe_create(const char *path, int flags, int mode)
{
	int fd, i;

	for (i = 0; i < 10; i++) {
		fd = open(path, flags, mode);
		if (fd != -1 || errno != ESTALE)
			break;
	}
	return fd;
}

static void nfs_test_estale_server(int socket_fd, const char *path)
{
	int fd;

	fd = nfs_safe_create(path, O_RDWR | O_CREAT, 0600);
	if (fd < 0)
		i_fatal("creat(%s) failed: %m", path);
	write(fd, "hello", 5);
	close(fd);

	send_cmd(socket_fd, '1');
	wait_cmd(socket_fd, '2');
	if (unlink(path) < 0)
		i_error("unlink(%s) failed: %m", path);
	send_cmd(socket_fd, '3');
}

static void nfs_test_estale_client(int socket_fd, const char *path)
{
	char buf[100];
	int fd, ret;

	send_cmd(socket_fd, 'S');
	wait_cmd(socket_fd, '1');
	fd = open(path, O_RDWR | O_CREAT, 0600);
	if (fd < 0)
		i_fatal("creat(%s) failed: %m", path);

	send_cmd(socket_fd, '2');
	wait_cmd(socket_fd, '3');
	if ((ret = read(fd, buf, sizeof(buf))) < 0) {
		if (errno == ESTALE)
			printf("ESTALE errors happen on read()\n");
		else if (errno == EIO) {
			printf("EIO errors happen on read()\n");
			if (fchown(fd, 0, (gid_t)-1) == 0)
				printf(" - fchown() succeeded..\n");
			else if (errno == ESTALE)
				printf(" - fchown() returned ESTALE\n");
			else
				i_error(" - fchown() failed: %m");
		} else
			i_fatal("read(%s) failed: %m", path);
	} else if (ret != 5) {
		i_error("read(%s) returned %d bytes instead of 5", path, ret);
	} else {
		printf("ESTALE errors don't happen\n");
	}
	close(fd);
	wait_cmd(socket_fd, '!');
}

static void nfs_test_oexcl_server(int socket_fd, const char *path)
{
	int fd;

	wait_cmd(socket_fd, '1');

	fd = nfs_safe_create(path, O_RDWR | O_CREAT | O_TRUNC, 0600);
	if (fd < 0)
		i_fatal("open(%s, O_CREAT) failed: %m", path);
	close(fd);
	send_cmd(socket_fd, '2');
}

static void nfs_test_oexcl_client(int socket_fd, const char *path)
{
	struct stat st;
	int fd;

	send_cmd(socket_fd, 'E');

	/* make sure it doesn't exist */
	if (unlink(path) < 0 && errno != ENOENT)
		i_fatal("unlink(%s) failed: %m", path);
	/* make sure its nonexistence is cached */
	if (stat(path, &st) < 0 && errno != ENOENT)
		i_fatal("stat(%s) failed: %m", path);

	send_cmd(socket_fd, '1');
	wait_cmd(socket_fd, '2');

	fd = nfs_safe_create(path, O_RDWR | O_CREAT | O_EXCL, 0600);
	if (fd < 0) {
		if (errno == EEXIST) {
			printf("O_EXCL appears to be working, "
			       "but this could be just faked by NFS client\n");
		} else
			i_error("open(%s) failed: %m", path);
	} else {
		printf("O_EXCL doesn't work\n");
		(void)close(fd);
	}
	wait_cmd(socket_fd, '!');
}

static void nfs_test_nsecs_server(int socket_fd, const char *path)
{
	struct timeval tv[2];
	int fd;
	char cmd;

	fd = nfs_safe_create(path, O_RDWR | O_CREAT | O_TRUNC, 0600);
	if (fd < 0)
		i_fatal("open(%s, O_CREAT) failed: %m", path);

	/* first test microseconds */
	tv[0].tv_sec = 123456789;
	tv[0].tv_usec = 123456;
	tv[1] = tv[0];
	if (utimes(path, tv) < 0)
		i_fatal("utimes(%s) failed: %m", path);

	send_cmd(socket_fd, '1');
	while ((cmd = read_cmd(socket_fd)) != '2') {
		if (write(fd, "1", 1) < 0)
			i_fatal("write(%s) failed: %m", path);
		if (fsync(fd) < 0)
			i_fatal("fsync(%s) failed: %m", path);
		send_cmd(socket_fd, '3');
	}

	close(fd);
}

static void nfs_test_nsecs_client(int socket_fd, const char *path)
{
	struct stat st;
	int i;

	send_cmd(socket_fd, 'N');
	wait_cmd(socket_fd, '1');

	nfs_cache_flush_before(path, NULL, NFS_CACHE_FLUSH_METHOD_OPEN_CLOSE);
	if (stat(path, &st) < 0)
		i_fatal("stat(%s) failed: %m", path);
	if (st.st_mtime != 123456789) {
		i_error("mtime test failed, timestamp %u != 123456789",
			st.st_mtime);
	} else if (ST_NSECS(st)/1000 == 123456) {
		/* we have microsecond resolution at least,
		   see if we have nanoseconds */
		for (i = 0; i < 10 && ST_NSECS(st) % 1000 == 0; i++) {
			send_cmd(socket_fd, 'x');
			wait_cmd(socket_fd, '3');
			nfs_cache_flush_before(path, NULL, NFS_CACHE_FLUSH_METHOD_OPEN_CLOSE);
			if (stat(path, &st) < 0)
				i_fatal("stat(%s) failed: %m", path);
		}
		if (ST_NSECS(st) % 1000 == 0)
			printf("timestamps resolution: microseconds\n");
		else
			printf("timestamps resolution: nanoseconds\n");
	} else if (ST_NSECS(st) != 0) {
		printf("timestamps resolution: other (%u)\n",
		       (unsigned int)ST_NSECS(st));
	} else {
#ifdef HAVE_ST_NSECS
		printf("timestamps resolution: seconds\n");
#else
		printf("timestamps resolution: unknown, "
		       "don't know how to get nanoseconds from stat()\n");
#endif
	}
	send_cmd(socket_fd, '2');
	wait_cmd(socket_fd, '!');
}

static void nfs_test_fattrcache_server(int socket_fd, const char *path)
{
	struct timeval tv[2];
	int fd;
	char cmd;

	if (unlink(path) < 0 && errno != ENOENT)
		i_fatal("unlink(%s) failed: %m", path);

	fd = nfs_safe_create(path, O_RDWR | O_CREAT | O_TRUNC, 0600);
	if (fd < 0)
		i_fatal("creat(%s) failed: %m", path);

	tv[0].tv_sec = time(NULL);
	tv[0].tv_usec = 0;
	tv[1] = tv[0];
	if (utimes(path, tv) < 0)
		i_fatal("utimes(%s) failed: %m", path);

	send_cmd(socket_fd, '1');
	wait_cmd(socket_fd, '2');

	do {
		if (write(fd, "hello", 5) != 5)
			i_fatal("write(%s) failed: %m", path);
		nfs_cache_flush_after(path, &fd, NFS_CACHE_FLUSH_METHOD_FSYNC);

		/* make sure the mtime changes */
		tv[0].tv_sec++;
		tv[1].tv_sec++;
		if (utimes(path, tv) < 0)
			i_fatal("utimes(%s) failed: %m", path);

		send_cmd(socket_fd, '3');
		cmd = read_cmd(socket_fd);
	} while (cmd == '2');

	if (cmd != '4')
		i_fatal("expected '4'");
	close(fd);
}

static void nfs_test_fattrcache_client(int socket_fd, const char *path)
{
	struct stat st1, st2;
	enum nfs_cache_flush_method method;
	int fd, fails = 0;

	printf("\nTesting file attribute cache..\n");

	send_cmd(socket_fd, 'F');
	wait_cmd(socket_fd, '1');

	fd = nfs_safe_open(path, O_RDWR);
	if (fd < 0)
		i_fatal("open(%s) failed: %m", path);
	for (method = 1; method < NFS_CACHE_FLUSH_METHOD_COUNT; ) {
		if (fstat(fd, &st1) < 0)
			i_fatal("fstat(%s) failed: %m", path);
		send_cmd(socket_fd, '2');
		wait_cmd(socket_fd, '3');

		if (fstat(fd, &st2) < 0)
			i_fatal("fstat(%s) failed: %m", path);

		if (st1.st_mtime == st2.st_mtime) {
			nfs_cache_flush_before(path, &fd, method);
			if (fstat(fd, &st2) < 0)
				i_fatal("fstat(%s) failed: %m", path);
			nfs_cache_flush_after(path, &fd, method);

			printf("Attr cache flush %s: %s\n",
			       nfs_cache_flush_method_names[method],
			       st1.st_mtime == st2.st_mtime ? "failed" : "OK");
			method++;
			fails = 0;
		} else {
			/* didn't even require flushing. try again a couple
			   of times. */
			if (++fails == 3) {
				printf("NFS attribute cache seems to be disabled\n");
				break;
			}
		}
	}
	close(fd);
	send_cmd(socket_fd, '4');
	wait_cmd(socket_fd, '!');
}

static void nfs_test_fhandlecache_server(int socket_fd, const char *path)
{
	char dir[1024], temp_path1[1024], temp_path2[1024], *p;
	struct timeval tv[2], dir_tv[2];
	int fd;
	char cmd;

	if (unlink(path) < 0 && errno != ENOENT)
		i_fatal("unlink(%s) failed: %m", path);

	p = strrchr(path, '/');
	if (p == NULL)
		strcpy(dir, ".");
	else
		snprintf(dir, p - path + 1, "%s", path);

	snprintf(temp_path1, sizeof(temp_path1), "%s.1", path);
	snprintf(temp_path2, sizeof(temp_path2), "%s.2", path);

	fd = nfs_safe_create(temp_path1, O_RDWR | O_CREAT | O_TRUNC, 0600);
	if (fd < 0)
		i_fatal("creat(%s) failed: %m", temp_path1);
	close(fd);

	fd = nfs_safe_create(temp_path2, O_RDWR | O_CREAT | O_TRUNC, 0600);
	if (fd < 0)
		i_fatal("creat(%s) failed: %m", temp_path2);
	close(fd);

	tv[0].tv_sec = 0;
	tv[0].tv_usec = 0;
	tv[1] = tv[0];

	dir_tv[0].tv_sec = time(NULL);
	dir_tv[0].tv_usec = 0;
	dir_tv[1] = dir_tv[0];

	if (link(temp_path1, path) < 0)
		i_fatal("link(%s, %s) failed: %m", temp_path1, path);

	if (utimes(path, tv) < 0)
		i_fatal("utimes(%s) failed: %m", path);
	if (utimes(dir, dir_tv) < 0)
		i_fatal("utimes(%s) failed: %m", dir);

	send_cmd(socket_fd, '1');

	while ((cmd = read_cmd(socket_fd)) != '4') {
		unlink(path);
		if (cmd == 'b') {
			if (link(temp_path1, path) < 0)
				i_fatal("link(%s, %s) failed: %m", temp_path1, path);
		} else {
			if (link(temp_path2, path) < 0)
				i_fatal("link(%s, %s) failed: %m", temp_path1, path);
		}

		tv[1].tv_sec++;
		if (utimes(path, tv) < 0)
			i_fatal("utimes(%s) failed: %m", path);
		/* keep directory's mtime the same so the flushing doesn't
		   happen because of it. */
		if (utimes(dir, dir_tv) < 0)
			i_fatal("utimes(%s) failed: %m", dir);

		send_cmd(socket_fd, '3');
	}

	if (cmd != '4')
		i_fatal("expected '4'");
	unlink(temp_path1);
	unlink(temp_path2);
}

static void nfs_test_fhandlecache_client(int socket_fd, const char *path)
{
	struct stat st1, st2;
	enum nfs_cache_flush_method method;
	char dir[1024], temp_path1[1024], temp_path2[1024], *p;
	const char *flush_path;
	time_t expected_mtime;
	ino_t ino1, ino2;
	int fd, file_fd, success = 0;

	printf("\nTesting file handle cache..\n");

	snprintf(temp_path1, sizeof(temp_path1), "%s.1", path);
	snprintf(temp_path2, sizeof(temp_path2), "%s.2", path);

	p = strrchr(path, '/');
	if (p == NULL)
		strcpy(dir, ".");
	else
		snprintf(dir, p - path + 1, "%s", path);

	send_cmd(socket_fd, 'H');
	wait_cmd(socket_fd, '1');

	fd = open(dir, O_RDONLY);
	if (fd == -1)
		i_fatal("open(%s) failed: %m", dir);

	if (stat(temp_path1, &st1) < 0)
		i_error("stat(%s) failed: %m", temp_path1);
	if (stat(temp_path2, &st2) < 0)
		i_error("stat(%s) failed: %m", temp_path2);
	if (st1.st_ino == st2.st_ino)
		i_error("Temp files' inodes are the same..");
	ino1 = st1.st_ino;
	ino2 = st2.st_ino;

	/* fill the file's attribute cache */
	file_fd = nfs_safe_create(path, O_RDWR | O_CREAT, 0600);
	if (file_fd == -1)
		i_fatal("open(%s) failed: %m", path);
	close(file_fd);

	expected_mtime = 1;
	for (method = 0; method < NFS_CACHE_FLUSH_METHOD_COUNT; ) {
		if (stat(path, &st1) < 0 ||
		    stat(path, &st1) < 0)
			i_fatal("stat(%s) failed: %m", path);

		if (st1.st_ino == ino1)
			send_cmd(socket_fd, 'a');
		else if (st1.st_ino == ino2)
			send_cmd(socket_fd, 'b');
		else
			i_fatal("%s has unexpected inode", path);
		wait_cmd(socket_fd, '3');

		flush_path = method == NFS_CACHE_FLUSH_METHOD_RMDIR ||
			method == NFS_CACHE_FLUSH_METHOD_RMDIR_PARENT ?
			path : dir;
		nfs_cache_flush_before(flush_path, &fd, method);
		if (stat(path, &st2) < 0)
			i_fatal("stat(%s) failed: %m", path);
		nfs_cache_flush_after(flush_path, &fd, method);

		if (st1.st_ino != st2.st_ino)
			success = 1;

		printf("File handle cache flush %s: %s\n",
		       nfs_cache_flush_method_names[method],
		       st1.st_ino == st2.st_ino ? "failed" : "OK");
		if (st1.st_ino == st2.st_ino &&
		    st2.st_mtime == expected_mtime)
			printf(" - inode didn't change, but mtime did\n");
		else if (st1.st_ino != st2.st_ino &&
			 st2.st_mtime != expected_mtime)
			printf(" - inode changed, but mtime is wrong\n");
		if (st1.st_ino != ino1 && st1.st_ino != ino2)
			printf(" - inode is neither temp1 nor temp2 file's\n");
		expected_mtime++;
		method++;
	}
	send_cmd(socket_fd, '4');

	if (!success)
		printf("Looks like there's no way to flush directory's attribute cache\n");
	close(fd);
	wait_cmd(socket_fd, '!');
}

static void nfs_test_neg_fhandlecache_server(int socket_fd, const char *path)
{
	struct timeval tv[2];
	int fd;
	char cmd;

	if (unlink(path) < 0 && errno != ENOENT)
		i_fatal("unlink(%s) failed: %m", path);

	tv[0].tv_sec = 0;
	tv[0].tv_usec = 0;
	tv[1] = tv[0];

	send_cmd(socket_fd, '1');
	while ((cmd = read_cmd(socket_fd)) == '2') {
		fd = open(path, O_CREAT | O_TRUNC, 0600);
		if (fd == -1)
			i_fatal("creat(%s) failed: %m", path);
		close(fd);
		if (utimes(path, tv) < 0)
			i_fatal("utimes(%s) failed: %m", path);
		tv[1].tv_sec++;

		send_cmd(socket_fd, '3');
		wait_cmd(socket_fd, '4');

		if (unlink(path) < 0 && errno != ENOENT)
			i_fatal("unlink(%s) failed: %m", path);
		send_cmd(socket_fd, '5');
	}
}

static void nfs_test_neg_fhandlecache_client(int socket_fd, const char *path)
{
	struct stat st;
	enum nfs_cache_flush_method method;
	const char *flush_path;
	char dir[1024], *p;
	time_t expected_mtime;
	int fd, success = 0;

	printf("\nTesting negative file handle cache..\n");

	p = strrchr(path, '/');
	if (p == NULL)
		strcpy(dir, ".");
	else
		snprintf(dir, p - path + 1, "%s", path);

	send_cmd(socket_fd, 'G');
	wait_cmd(socket_fd, '1');

	fd = open(dir, O_RDONLY);
	if (fd == -1)
		i_fatal("open(%s) failed: %m", dir);

	if (unlink(path) < 0 && errno != ENOENT)
		i_fatal("unlink(%s) failed: %m", path);

	expected_mtime = 0;
	for (method = 0; method < NFS_CACHE_FLUSH_METHOD_COUNT; ) {
		/* stat() a couple of to make sure it gets cached */
		if (stat(path, &st) == 0 ||
		    stat(path, &st) == 0 ||
		    stat(path, &st) == 0) {
			i_error("stat() succeeded, can't continue this test");
			break;
		}

		send_cmd(socket_fd, '2');
		wait_cmd(socket_fd, '3');

		flush_path = method == NFS_CACHE_FLUSH_METHOD_RMDIR ||
			method == NFS_CACHE_FLUSH_METHOD_RMDIR_PARENT ?
			path : dir;
		nfs_cache_flush_before(flush_path, &fd, method);
		success = stat(path, &st) == 0;
		if (!success && errno != ENOENT)
			i_fatal("stat(%s) failed: %m", path);
		nfs_cache_flush_after(flush_path, &fd, method);

		printf("Negative file handle cache flush %s: %s\n",
		       nfs_cache_flush_method_names[method],
		       !success ? "failed" : "OK");
		if (success && st.st_mtime != expected_mtime)
			printf(" - mtime is wrong though\n");
		expected_mtime++;
		method++;

		if (unlink(path) < 0 && errno != ENOENT)
			i_fatal("unlink(%s) failed: %m", path);

		send_cmd(socket_fd, '4');
		wait_cmd(socket_fd, '5');
	}
	send_cmd(socket_fd, '6');

	close(fd);
	wait_cmd(socket_fd, '!');
}

static void nfs_test_data_cache_server(int socket_fd, const char *path)
{
	struct timeval tv[2];
	char buf[1024], cmd;
	int fd;

	memset(buf, 'a', sizeof(buf));

	tv[0].tv_sec = time(NULL);
	tv[0].tv_usec = 12345;
	tv[1] = tv[0];

	fd = nfs_safe_create(path, O_RDWR | O_CREAT | O_TRUNC, 0600);
	if (fd < 0)
		i_fatal("creat(%s) failed: %m", path);
	if (write(fd, buf, 1024) != 1024)
		i_fatal("write(%s) failed: %m", path);
	nfs_cache_flush_after(path, &fd, NFS_CACHE_FLUSH_METHOD_FSYNC);

	send_cmd(socket_fd, '1');
	wait_cmd(socket_fd, '2');

	cmd = 'b';
	do {
		/* keep mtime same all the time, so it doesn't affect checking.
		   use utimes() instead of utime() to make sure microseconds are
		   also reset (hopefully also resets nanoseconds) */
		tv[1].tv_sec++;
		if (utimes(path, tv) < 0)
			i_fatal("utimes(%s) failed: %m", path);
		send_cmd(socket_fd, '3');
		wait_cmd(socket_fd, '4');

		if (lseek(fd, 512, SEEK_SET) < 0)
			i_fatal("lseek() failed: %m");
		if (write(fd, &cmd, 1) != 1)
			i_fatal("write(%s) failed: %m", path);
		nfs_cache_flush_after(path, &fd, NFS_CACHE_FLUSH_METHOD_FSYNC);
		if (utimes(path, tv) < 0)
			i_fatal("utimes(%s) failed: %m", path);

		send_cmd(socket_fd, cmd);
		cmd = read_cmd(socket_fd);
	} while (cmd != '5');

	close(fd);
}

static void nfs_test_data_cache_client(int socket_fd, const char *path)
{
	struct stat st;
	char buf[1024], chr;
	time_t mtime;
	long mtime_nsecs;
	int fd, ret, i, method;

	printf("\nTesting data cache..\n");

	send_cmd(socket_fd, 'D');
	wait_cmd(socket_fd, '1');

	fd = nfs_safe_open(path, O_RDWR);
	if (fd < 0)
		i_fatal("open(%s) failed: %m", path);
	nfs_cache_flush_before(path, &fd, NFS_CACHE_FLUSH_METHOD_CLOSE_OPEN);

	/* initial read, should work */
	ret = read(fd, buf, sizeof(buf));
	if (ret < 0)
		i_fatal("read(%s) failed: %m", path);
	if (ret == 0) {
		i_error("data cache: Initial read failed to return everything");
		return;
	}
	for (i = 0; i < ret; i++) {
		if (buf[i] != 'a') {
			i_error("Invalid data read, [%d] != 'a'", i);
			return;
		}
	}

	/* check overwrites */
	send_cmd(socket_fd, '2');

	chr = 'b';
	for (method = 0;;) {
		wait_cmd(socket_fd, '3');

		/* flush attribute cache */
		nfs_cache_flush_before(path, &fd, NFS_CACHE_FLUSH_METHOD_CLOSE_OPEN);

		if (fstat(fd, &st) < 0)
			i_fatal("fstat() failed: %m");
		mtime = st.st_mtime;
		mtime_nsecs = ST_NSECS(st);

		/* fill data cache */
		if (lseek(fd, 0, SEEK_SET) < 0)
			i_fatal("lseek() failed: %m");
		ret = read(fd, buf, sizeof(buf));
		if (ret != sizeof(buf)) {
			if (ret < 0)
				i_error("read(%s) failed: %m", path);
			else
				i_error("read(%s) returned partial data", path);
		}

		send_cmd(socket_fd, '4');
		wait_cmd(socket_fd, chr);
		nfs_cache_flush_before(path, &fd, method);

		if (lseek(fd, 0, SEEK_SET) < 0)
			i_fatal("lseek() failed: %m");
		ret = read(fd, buf, sizeof(buf));
		if (ret != sizeof(buf)) {
			if (ret < 0)
				i_error("read(%s) failed: %m", path);
			else
				i_error("read(%s) returned partial data", path);
		}
		if (fstat(fd, &st) < 0)
			i_fatal("fstat() failed: %m");
		nfs_cache_flush_after(path, &fd, method);

		if (buf[511] != 'a')
			i_fatal("data cache: [511] != 'a'");

		printf("Data cache flush %s: %s\n",
		       nfs_cache_flush_method_names[method],
		       buf[512] == chr ? "OK" : "failed");

		if (st.st_mtime != mtime ||
			 ST_NSECS(st) != mtime_nsecs) {
			printf(" - mtime changed! %ld.%ld -> %ld.%ld\n",
			       (long)mtime, mtime_nsecs, (long)st.st_mtime,
			       (long)ST_NSECS(st));
			mtime = st.st_mtime;
			mtime_nsecs = ST_NSECS(st);
		}

		if (++method == NFS_CACHE_FLUSH_METHOD_COUNT)
			break;
		send_cmd(socket_fd, ++chr);
	}
	send_cmd(socket_fd, '5');

	close(fd);
	wait_cmd(socket_fd, '!');
}

static void nfs_test_write_flush_server(int socket_fd, const char *path)
{
	struct stat st;
	char cmd;
	int fd, size;

	wait_cmd(socket_fd, '1');

	fd = nfs_safe_open(path, O_RDWR);
	if (fd < 0)
		i_fatal("open(%s) failed: %m", path);

	size = 1;
	while ((cmd = read_cmd(socket_fd)) == '2') {
		nfs_cache_flush_before(path, &fd, NFS_CACHE_FLUSH_METHOD_CLOSE_OPEN);
		if (fstat(fd, &st) < 0)
			i_fatal("fstat(%s) failed: %m", path);

		send_cmd(socket_fd, st.st_size == size ? 'O' : 'E');
		size++;
	}

	close(fd);
}

static void nfs_test_write_flush_client(int socket_fd, const char *path)
{
	int fd, method = 0;
	char cmd;

	send_cmd(socket_fd, 'W');
	printf("\nTesting write flushing..\n");

	fd = nfs_safe_create(path, O_RDWR | O_CREAT | O_TRUNC, 0600);
	if (fd < 0)
		i_fatal("creat(%s) failed: %m", path);

	send_cmd(socket_fd, '1');
	for (method = 0; method < NFS_CACHE_FLUSH_METHOD_COUNT; method++) {
		nfs_cache_flush_before(path, &fd, method);
		if (write(fd, "a", 1) != 1) {
			i_error("write(%s) failed, method=%s: %m", path,
				nfs_cache_flush_method_names[method]);
		}
		nfs_cache_flush_after(path, &fd, method);

		send_cmd(socket_fd, '2');
		cmd = read_cmd(socket_fd);
		printf("Write flush %s: %s\n",
		       nfs_cache_flush_method_names[method],
		       cmd == 'O' ? "OK" : "failed");
	}
	send_cmd(socket_fd, '3');

	close(fd);
	wait_cmd(socket_fd, '!');
}

static void nfs_test_write_partial_server(int socket_fd, const char *path)
{
#define PARTIAL_TOTSIZE 16384
#define PARTIAL_BLOCKIZE 16
	char b[PARTIAL_BLOCKIZE];
	unsigned int i;
	int fd;

	fd = nfs_safe_create(path, O_RDWR | O_CREAT | O_TRUNC, 0600);
	if (fd < 0)
		i_fatal("creat(%s) failed: %m", path);

	send_cmd(socket_fd, '1');
	wait_cmd(socket_fd, '2');

	memset(b, 'S', sizeof(b));
	for (i = 0; i < PARTIAL_TOTSIZE/sizeof(b); i++) {
		usleep(100);
		lseek(fd, i*sizeof(b), SEEK_SET);
		write(fd, b, sizeof(b)/2);
	}
	close(fd);
	wait_cmd(socket_fd, '3');
	send_cmd(socket_fd, '4');
}

static void nfs_test_write_partial_client(int socket_fd, const char *path)
{
	char data[PARTIAL_TOTSIZE], b[PARTIAL_BLOCKIZE], b2[PARTIAL_BLOCKIZE];
	unsigned int i;
	int fd;
	ssize_t ret;

	send_cmd(socket_fd, 'P');
	printf("\nTesting partial writing..\n");

	wait_cmd(socket_fd, '1');

	fd = nfs_safe_open(path, O_RDWR);
	if (fd < 0)
		i_fatal("open(%s) failed: %m", path);

	send_cmd(socket_fd, '2');

	memset(b, 'C', sizeof(b));
	for (i = 0; i < sizeof(data)/sizeof(b); i++) {
		usleep(100);
		lseek(fd, i*sizeof(b) + sizeof(b)/2, SEEK_SET);
		write(fd, &b, sizeof(b)/2);
	}
	close(fd);
	send_cmd(socket_fd, '3');
	wait_cmd(socket_fd, '4');

	fd = open(path, O_RDWR, 0600);
	if (fd < 0)
		i_fatal("open(%s) failed: %m", path);
	nfs_cache_flush_before(path, &fd, NFS_CACHE_FLUSH_METHOD_FCNTL_EXCL);
	nfs_cache_flush_after(path, &fd, NFS_CACHE_FLUSH_METHOD_FCNTL_EXCL);

	ret = read(fd, data, sizeof(data));
	if (ret < 0)
		i_fatal("read(%s) failed: %m", path);
	if (ret != sizeof(data))
		i_fatal("read(%s) returned %d", path, (int)ret);

	memset(b2, 'S', sizeof(b2));
	for (i = 0; i < sizeof(data)/sizeof(b); i += sizeof(b)) {
		if (memcmp(data + i, b2, sizeof(b2)/2) != 0)
			break;
		if (memcmp(data + i + sizeof(b)/2, b, sizeof(b)/2) != 0)
			break;
	}
	if (i == sizeof(data)/sizeof(b))
		printf("OK\n");
	else
		printf("Failed at [%d]\n", i);
	close(fd);

	wait_cmd(socket_fd, '!');
}

struct command {
	char cmd;
	void (*server)(int fd, const char *path);
	void (*client)(int fd, const char *path);
};

#define ENTRY(cmd, func) \
	{ cmd, nfs_test_ ## func ## _server, nfs_test_ ## func ## _client }
#define N_COMMANDS (sizeof(commands)/sizeof(commands[0]))
static struct command commands[] = {
	ENTRY('S', estale),
	ENTRY('E', oexcl),
	ENTRY('N', nsecs),
	ENTRY('F', fattrcache),
	ENTRY('D', data_cache),
	ENTRY('W', write_flush),
	ENTRY('P', write_partial),
	ENTRY('H', fhandlecache),
	/* keep negative dir attr cache last so it won't break other tests */
	ENTRY('G', neg_fhandlecache)
};

static struct command *command_find(char cmd)
{
	unsigned int i;

	for (i = 0; i < N_COMMANDS; i++) {
		if (commands[i].cmd == cmd)
			return &commands[i];
	}
	return NULL;
}

static void nfs_test_server(int fd, const char *path)
{
	struct command *cmd;

	if (unlink(path) < 0 && errno != ENOENT)
		i_fatal("unlink(%s) failed: %m", path);

	send_cmd(fd, 'S');
	wait_cmd(fd, 'C');
	printf("Connected: Acting as test server\n");

	for (;;) {
		cmd = command_find(read_cmd(fd));
		if (cmd == NULL)
			break;

		cmd->server(fd, path);
		send_cmd(fd, '!');
	}
}

static void nfs_test_client(int fd, const char *path, const char *cmdstr)
{
	unsigned int i;

	if (unlink(path) < 0 && errno != ENOENT)
		i_fatal("unlink(%s) failed: %m", path);

	send_cmd(fd, 'C');
	wait_cmd(fd, 'S');
	printf("Connected: Acting as test client\n");

	for (i = 0; i < N_COMMANDS; i++) {
		if (cmdstr == NULL || strchr(cmdstr, commands[i].cmd) != NULL)
			commands[i].client(fd, path);
	}

	send_cmd(fd, 'X');
}

static void nfs_listen(unsigned int port, const char *path, const char *cmdstr)
{
	struct sockaddr_in so;
	socklen_t addrlen = sizeof(so);
	int listen_fd, fd;

	memset(&so, 0, sizeof(so));
	so.sin_family = AF_INET;
	so.sin_port = htons(port);
	so.sin_addr.s_addr = INADDR_ANY;

	/* listen */
	listen_fd = socket(AF_INET, SOCK_STREAM, 0);
	if (listen_fd == -1)
		i_fatal("socket() failed: %m");
	if (bind(listen_fd, (void *)&so, sizeof(so)) < 0)
		i_fatal("bind() failed: %m");
	if (listen(listen_fd, 1) < 0)
		i_fatal("listen() failed: %m");

	/* wait for connect */
	do {
		printf("Listening for client on port %u..\n", port);
		fd = accept(listen_fd, (void *)&so, &addrlen);
		if (fd < 0)
			i_fatal("accept() failed: %m");

		if (!reverse)
			nfs_test_server(fd, path);
		else
			nfs_test_client(fd, path, cmdstr);
		close(fd);
	} while (!reverse);
	close(listen_fd);
}

static void nfs_connect(const char *host, unsigned int port, const char *path,
			const char *cmdstr)
{
	struct sockaddr_in so;
	struct hostent *hp;
	int fd;

	hp = gethostbyname(host);
	if (hp == NULL || hp->h_addr_list[0] == NULL)
		i_fatal("gethostbyname(%s) failed", host);

	memset(&so, 0, sizeof(so));
        so.sin_family = AF_INET;
	so.sin_port = htons(port);
	memcpy(&so.sin_addr.s_addr, hp->h_addr_list[0], 4);

	fd = socket(AF_INET, SOCK_STREAM, 0);
	if (fd < 0)
		i_fatal("socket() failed: %m");
	if (connect(fd, (void *)&so, sizeof(so)) < 0)
		i_fatal("connect() failed: %m");

	if (!reverse)
		nfs_test_client(fd, path, cmdstr);
	else
		nfs_test_server(fd, path);
	close(fd);
}

int main(int argc, char *argv[])
{
	const char *p;
	int listen = 1;

	if (argc > 1 && strcmp(argv[1], "-rev") == 0) {
		/* reverse client and server roles. just to simplify bypassing
		   firewalls when testing different client kernels. */
		argc--;
		argv++;
		reverse = 1;
	}

	if (argv[1] != NULL) {
		for (p = argv[1]; *p != '\0'; p++) {
			if (*p < '0' || *p > '9') {
				listen = 0;
				break;
			}
		}
	}

	if (listen && argc >= 3)
		nfs_listen(atoi(argv[1]), argv[2], argv[3]);
	else if (!listen && argc >= 4)
		nfs_connect(argv[1], atoi(argv[2]), argv[3], argv[4]);
	else
		i_fatal("Usage: nfstest [<host>] <port> <path> [<commands>]");
	return 0;
}
