/*
   gcc pop3test.c -o pop3test -Wall -W -I. -Isrc/lib -DHAVE_CONFIG_H src/lib/liblib.a
*/

#include "lib.h"
#include "network.h"
#include "istream.h"
#include "ostream.h"

#include <stdio.h>
#include <stdlib.h>

#define IP "127.0.0.1"
#define PORT 110
#define PASSWORD "test"
#define CLIENTS_COUNT 25

/* u0001@d0001.domain.org .. u0099@d0099.domain.org */
#define USERNAME_TEMPLATE "u%04lu@d%04lu.domain.org"
#define USER_RAND 99
#define DOMAIN_RAND 99

enum client_state {
	STATE_BANNER,
	STATE_USER,
	STATE_PASS,
	STATE_STAT,
	STATE_RETR,
	STATE_RETR_DATA,
	STATE_DELE,
	STATE_QUIT
};

struct client {
	unsigned int cur, messages, deleted;
	struct istream *input;
	struct ostream *output;
	struct io *io;
	enum client_state state;
	char *username;
};

static int clients_count = 0;
static struct ioloop *ioloop;

void client_free(struct client *client);

static void client_input(void *context)
{
	struct client *client = context;
	const char *line, *str;
	unsigned int i;

	switch (i_stream_read(client->input)) {
	case 0:
		return;
	case -1:
		/* disconnected */
		client_free(client);
		return;
	case -2:
		/* buffer full */
		i_error("line too long");
		client_free(client);
		return;
	}

	while ((line = i_stream_next_line(client->input)) != NULL) {
		switch (client->state) {
		case STATE_BANNER:
			str = t_strdup_printf("USER %s\r\n", client->username);
			o_stream_send_str(client->output, str);
			client->state = STATE_USER;
			break;
		case STATE_USER:
			if (*line != '+') {
				i_error("USER failed: %s", line);
				client_free(client);
				return;
			}
			str = t_strdup_printf("PASS %s\r\n", PASSWORD);
			o_stream_send_str(client->output, str);
			client->state = STATE_PASS;
			break;
		case STATE_PASS:
			if (*line != '+') {
				i_error("Login failed: %s", line);
				client_free(client);
				return;
			}
			o_stream_send_str(client->output, "STAT\r\n");
			client->state = STATE_STAT;
			break;
		case STATE_STAT:
			if (*line != '+') {
				i_error("STAT failed: %s", line);
				client_free(client);
				return;
			}
			sscanf(line, "+OK %u", &client->messages);
			i_info("%s: %u messages", client->username,
			       client->messages);
			if (client->messages == 0) {
				client_free(client);
				return;
			}

			for (i = 1; i <= client->messages; i++) {
				t_push();
				str = t_strdup_printf("RETR %u\r\n", i);
				o_stream_send_str(client->output, str);
				t_pop();
			}
			client->state = STATE_RETR;
			break;
		case STATE_RETR:
			client->cur++;
			if (*line != '+') {
				/*i_error("RETR %u failed: %s",
					client->cur, line);*/
				if (client->cur == client->messages)
					goto __kludge;
				break;
			}
			client->state = STATE_RETR_DATA;
			break;
		case STATE_RETR_DATA:
			if (strcmp(line, ".") != 0)
				break;

			if (client->cur != client->messages) {
				client->state = STATE_RETR;
				break;
			}

		__kludge:
			/* all fetched, delete them randomly */
			for (i = 1; i <= client->messages; i++) {
				if ((random() % 2) == 0) {
					t_push();
					str = t_strdup_printf("DELE %u\r\n", i);
					o_stream_send_str(client->output, str);
					t_pop();
					client->deleted++;
				}
			}
			client->state = STATE_DELE;
			if (client->deleted == 0)
				goto __kludge2;
			break;
		case STATE_DELE:
			if (*line != '+') {
				i_error("DELE failed: %s", line);
				client_free(client);
				return;
			}
			client->deleted--;
			if (client->deleted != 0)
				break;

		__kludge2:
			/* processed all DELE commands. */
			o_stream_send_str(client->output, "QUIT\r\n");
			client->state = STATE_QUIT;
			break;
		case STATE_QUIT:
			break;
		}
	}
}

struct client *client_new(void)
{
	struct client *client;
	struct ip_addr ip;
	int fd;

	net_addr2ip(IP, &ip);
	fd = net_connect_ip(&ip, PORT, NULL);
	if (fd < 0) {
		i_error("connect() failed: %m");
		return NULL;
	}

	client = i_new(struct client, 1);
	client->input = i_stream_create_file(fd, default_pool, 65536, TRUE);
	client->output = o_stream_create_file(fd, default_pool, (size_t)-1, FALSE);
	client->io = io_add(fd, IO_READ, client_input, client);
	client->username = i_strdup_printf(USERNAME_TEMPLATE,
					   (random() % USER_RAND) + 1,
					   (random() % DOMAIN_RAND) + 1);
	clients_count++;
	return client;
}

void client_free(struct client *client)
{
	--clients_count;
	/*if (--clients_count == 0)
		io_loop_stop(ioloop);*/
	io_remove(client->io);
	o_stream_unref(client->output);
	i_stream_unref(client->input);
	i_free(client->username);
	i_free(client);

	client_new();
}

int main(void)
{
	int i;

	lib_init();
	ioloop = io_loop_create(system_pool);

	for (i = 0; i < CLIENTS_COUNT; i++)
		client_new();
        io_loop_run(ioloop);

	io_loop_destroy(ioloop);
	lib_deinit();
	return 0;
}
