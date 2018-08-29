/*
   Put this file to dovecot v1.0.x sources' root directory. Dovecot must be
   compiled before this. The run:

   gcc nfstest.c -o nfstest -g -Wall -W -DHAVE_CONFIG_H -I. -Isrc/lib src/lib/liblib.a

   On machine 1 use:

   ./nfstest <port> <path to a test file>

   On machine 2 use:

   ./nfstest <machine 1 hostname> <machine 1 port> <path to the same test file>

   Don't use the NFS server as either machine 1 or 2!
*/
#include "lib.h"
#include "ioloop.h"
#include "fd-set-nonblock.h"
#include "read-full.h"
#include "write-full.h"
#include "network.h"

#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/stat.h>

static bool reverse = FALSE;

static void send_cmd(int fd, char cmd)
{
	if (write_full(fd, &cmd, 1) < 0)
		i_fatal("write() failed: %m");
}

static char read_cmd(int fd)
{
	int ret;
	char cmd;

	ret = read_full(fd, &cmd, 1);
	if (ret <= 0) {
		if (ret == 0)
			i_fatal("Connection lost");
		i_fatal("read() failed: %m");
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

static void nfs_test_link_server(int socket_fd, const char *path)
{
	const char *temp_path, *lock_path;
	char cmd, buf[100];
	int ret;
	int fd, fd2, last_server = FALSE;

	temp_path = t_strdup_printf("%s.server", path);
	lock_path = t_strdup_printf("%s.lock", path);

	if (unlink(path) < 0 && errno != ENOENT)
		i_fatal("unlink(%s) failed: %m", path);
	if (unlink(lock_path) < 0 && errno != ENOENT)
		i_fatal("unlink(%s) failed: %m", lock_path);

	cmd = '0';
	for (;;) {
		fd = open(temp_path, O_RDWR | O_CREAT | O_TRUNC, 0600);
		if (fd < 0)
			i_fatal("open(%s) failed: %m", path);
		if (write(fd, "server", 6) < 0)
			perror("write()");

		unlink(".");

		fd2 = open(path, O_RDONLY);
		if (fd2 == -1) {
			if (cmd != '0')
				i_fatal("%s not found", path);
		} else {
			ret = read(fd2, buf, sizeof(buf));
			if (ret < 0)
				i_fatal("read(%s) failed: %m", path);
			buf[ret] = '\0';
			if (last_server) {
				if (memcmp(buf, "server", 6) != 0)
					i_error("wrong file, got: %s", buf);
			} else {
				if (memcmp(buf, "client", 6) != 0)
					i_error("wrong file, got: %s", buf);
			}
			close(fd2);
		}

		if (link(temp_path, lock_path) < 0) {
			if (errno != EEXIST) {
				i_fatal("link(%s, %s) failed: %m",
					temp_path, lock_path);
			}
			if (cmd != '3') {
				i_error("link(%s, %s) failed: %m",
					temp_path, lock_path);
			}
			if (close(fd) < 0)
				i_fatal("close() failed: %m");
			if (cmd == '3') {
				send_cmd(socket_fd, '5');
				wait_cmd(socket_fd, '6');
				fd = open(path, O_RDONLY);
				if (fd == -1)
					i_fatal("open(%s) failed: %m", path);
				ret = read(fd, buf, sizeof(buf));
				if (ret < 0)
					i_fatal("read(%s) failed: %m", path);
				buf[ret] = '\0';
				if (memcmp(buf, "client", 6) != 0)
					i_error("wrong file, got: %s", buf);
				close(fd);

				last_server = FALSE;
				cmd = '4';
			}
			continue;
		}
		if (unlink(temp_path) < 0)
			i_fatal("unlink(%s) failed: %m", temp_path);

		send_cmd(socket_fd, '1');
		wait_cmd(socket_fd, '2');

		if (rename(lock_path, path) < 0)
			i_fatal("rename(%s, %s) failed: %m", lock_path, path);
		last_server = TRUE;
		if (close(fd) < 0)
			i_fatal("close() failed: %m");

		cmd = read_cmd(socket_fd);
	}
}

static void nfs_test_link_client(int socket_fd, const char *path)
{
	const char *temp_path, *lock_path;
	int fd, remote = 0, local = 0;
	time_t start, now, prev = 0;
	struct stat st;
	char cmd;

	i_info("Testing link()..");

	temp_path = t_strdup_printf("%s.client", path);
	lock_path = t_strdup_printf("%s.lock", path);

	fd = open(temp_path, O_RDWR | O_CREAT | O_TRUNC, 0600);
	if (fd < 0)
		i_fatal("open(%s) failed: %m", path);
	if (fstat(fd, &st) < 0)
		i_fatal("fstat() failed: %m");

	if (write(fd, "client", 6) != 6)
		i_fatal("write() failed: %m");

	start = time(NULL);
	do {
		wait_cmd(socket_fd, '1');

		if (link(temp_path, lock_path) != -1 && errno == EEXIST)
			i_fatal("broken: link() succeeded");
		remote++;

		send_cmd(socket_fd, '2');

		if (rand() % 2 == 0)
			usleep(200000);
		if (link(temp_path, lock_path) == 0)
			cmd = '3';
		else if (errno != EEXIST)
			i_fatal("broken: link() succeeded");
		else
			cmd = '4';
		send_cmd(socket_fd, cmd);

		if (cmd == '3') {
			local++;
			cmd = read_cmd(socket_fd);
			if (cmd != '5')
				i_fatal("broken: server's link() succeeded");
			if (rename(lock_path, path) < 0)
				i_fatal("unlink(%s) failed: %m", lock_path);
			send_cmd(socket_fd, '6');
		}

		now = time(NULL);
		if (prev != now) {
			if (prev != 0)
				i_info("%u remote, %u local", remote, local);
			prev = now;
		}
	} while (now - start < 10);

	if (close(fd) < 0)
		i_fatal("close() failed: %m");
}

static void nfs_test_client(int fd, const char *path)
{
	send_cmd(fd, 'a');
	wait_cmd(fd, 'b');
	i_info("Connected: client");

	nfs_test_link_client(fd, path);
}

static void nfs_test_server(int fd, const char *path)
{
	send_cmd(fd, 'b');
	wait_cmd(fd, 'a');
	i_info("Connected: server");

	nfs_test_link_server(fd, path);
}

static void nfs_listen(unsigned int port, const char *path)
{
	struct ip_addr ip;
	int listen_fd, fd;

	net_get_ip_any4(&ip);
	listen_fd = net_listen(&ip, &port, 2);
	if (listen_fd < 0)
		i_fatal("net_listen(%d) failed: %m", port);

	fd = net_accept(listen_fd, NULL, NULL);
	if (fd < 0)
		i_fatal("net_accept() failed: %m");

	if (!reverse)
		nfs_test_client(fd, path);
	else
		nfs_test_server(fd, path);
}

static void connect_finish(void *context)
{
	struct ioloop *ioloop = context;

	io_loop_stop(ioloop);
}

static void nfs_connect(const char *host, unsigned int port, const char *path)
{
	struct ip_addr *ips;
	unsigned int ips_count;
	int fd, ret;

	if ((ret = net_gethostbyname(host, &ips, &ips_count)) != 0) {
		i_fatal("net_gethostbyname(%s) failed: %s",
			host, net_gethosterror(ret));
	}

	fd = net_connect_ip(ips, port, NULL);
	if (fd < 0) {
		i_fatal("net_connect_ip(%s, %d) failed: %m",
			net_ip2addr(ips), port);
	}
	fd_set_nonblock(fd, FALSE);

	{
		/* ugly.. net_connect_ip() forces nonblocking connection. */
		struct ioloop *ioloop;
		struct io *io;

		ioloop = io_loop_create();
		io = io_add(fd, IO_WRITE, connect_finish, ioloop);
		io_loop_run(ioloop);
		io_remove(&io);
		io_loop_destroy(&ioloop);
	}

	if (!reverse)
		nfs_test_server(fd, path);
	else
		nfs_test_client(fd, path);
}

int main(int argc, char *argv[])
{
	lib_init();

	if (argc > 1 && strcmp(argv[1], "-rev") == 0) {
		/* reverse client and server roles. just to simplify bypassing
		   firewalls when testing different client kernels. */
		argc--;
		argv++;
		reverse = TRUE;
	}

	if (argc == 3)
		nfs_listen(atoi(argv[1]), argv[2]);
	else if (argc == 4)
		nfs_connect(argv[1], atoi(argv[2]), argv[3]);
	else
		i_fatal("Usage: nfstest [<host>] <port> <path>");
	return 0;
}
