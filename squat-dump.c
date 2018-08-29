/*
   gcc -DHAVE_CONFIG_H -g -Wall squat-dump.c -o squat-dump ../../lib/liblib.a -I../../.. -I../../lib
*/

#include "lib.h"
#include "squat-trie-private.h"

#include <stdio.h>
#include <unistd.h>
#include <fcntl.h>

#define MAX_LEVEL 4

static void dump_header(const struct squat_trie_header *hdr)
{
	printf("version: %u\n", hdr->version);
	printf("uidvalidity: %u\n", hdr->uidvalidity);
	printf("used_file_size: %u\n", hdr->used_file_size);
	printf("deleted_space: %u\n", hdr->deleted_space);
	printf("node_count: %u\n", hdr->node_count);
	printf("modify_counter: %u\n", hdr->modify_counter);
	printf("root_offset: %u\n", hdr->root_offset);
	printf("\n");
}

static uint32_t unpack_num(const uint8_t **p, const uint8_t *end)
{
	const uint8_t *c = *p;
	uint32_t value = 0;
	unsigned int bits = 0;

	while (c != end && *c >= 0x80) {
		value |= (*c & 0x7f) << bits;
		bits += 7;
		c++;
	}

	if (c == end) {
		/* last number shouldn't end with high bit */
		return 0;
	}
	if (bits > 32-7) {
		/* we have only 32bit numbers */
		return 0;
	}

	value |= (*c & 0x7f) << bits;
	*p = c + 1;
	return value;
}

static void indent(int level)
{
	int i;

	for (i = 0; i < (level-1) * 2; i++)
		printf(" ");
}
static void iprintf(int level, const char *format, ...)
{
	va_list args;

	va_start(args, format);
	indent(level);
	vprintf(format, args);
	va_end(args);
}

static const char *data_denormalize(int chr)
{
	static char str[20];

	if (chr == 0)
		return " ";

	str[1] = '\0';
	chr += 32;
	if (chr <= 'Z')
		str[0] = chr;
	else {
		chr += 26;
		if (chr < 128)
			str[0] = chr;
		else
			snprintf(str, sizeof(str), "#%02x", chr);
	}
	return str;
}

static void dump_uidlist(const uint16_t *path, uint32_t uidlist)
{
	int i;

	iprintf(MAX_LEVEL+1, "path: ");
	for (i = 0; i < MAX_LEVEL; i++)
		printf("<%s>", data_denormalize(path[i]));

	if (uidlist & 0x80000000)
		printf(" => uid=%u\n", uidlist & ~0x80000000);
	else
		printf(" => uidlist=#%u\n", uidlist);
}

static void dump_tree(int fd, uoff_t offset, uint16_t *path, int level)
{
	uint8_t buf[1 + 256*(sizeof(uint8_t) + sizeof(uint32_t)) + 8];
	const uint8_t *p = buf, *end, *chars8;
	const uint16_t *chars16 = NULL;
	const uint32_t *idx8, *idx16 = NULL;
	uint16_t my_path[MAX_LEVEL];
	uint32_t num, chars8_count, chars16_count = 0, i;
	ssize_t ret;
	bool have_16bits, nonsorted;

	if (level == MAX_LEVEL+1) {
		/* uidlist */
		dump_uidlist(path, offset);
		return;
	}

	iprintf(level, "offset: %"PRIuUOFF_T"\n", offset);
	iprintf(level, "path: [%d]: ", level);
	for (i = 1; i < level; i++)
		printf("<%s>", data_denormalize(path[i-1]));
	printf("\n");

	ret = pread(fd, buf, sizeof(buf), offset);
	if (ret < 0)
		i_fatal("read() failed at offset %"PRIuUOFF_T": %m", offset);
	if (ret == 0)
		i_fatal("ERROR: offset too large");

	end = buf + ret;
	num = unpack_num(&p, end);
	have_16bits = (num & 1) != 0;
	chars8_count = num >> 1;

	if (chars8_count > 255)
		i_fatal("ERROR: chars8_count too large");

	iprintf(level, "chars8_count: %u\n", chars8_count);
	if (p + chars8_count > end)
		i_fatal("ERROR: chars8_count points outside file");

	chars8 = p; nonsorted = FALSE;
	iprintf(level, "chars8: ");
	for (i = 0; i < chars8_count; i++) {
		if (i > 0 && p[i-1] > p[i])
			nonsorted = TRUE;
		printf("%s", data_denormalize(p[i]));
	}
	if (nonsorted)
		i_fatal("ERROR: chars8 not ordered");
	printf("\n");

	idx8 = (const uint32_t *)(p + chars8_count);
	p = (const uint8_t *)(idx8 + chars8_count);
	if (p > end)
		i_fatal("ERROR: chars8_idx points outside file");

	if (have_16bits) {
		chars16_count = unpack_num(&p, end);
		if ((size_t)p & 1) p++;
		chars16 = (const uint16_t *)p;

		iprintf(level, "chars16_count: %u\n", chars16_count);
		if ((const uint8_t *)(chars16 + chars16_count) > end)
			i_fatal("ERROR: chars16_count points outside file");
		iprintf(level, "chars16: ");
		for (i = 0; i < chars16_count; i++) {
			printf("%s ", data_denormalize(p[i]));
		}
		printf("\n");

		idx16 = (const uint32_t *)(chars16 + chars16_count);
	}

	for (i = 1; i < level; i++)
		my_path[i-1] = path[i-1];

	for (i = 0; i < chars8_count; i++) {
		my_path[level-1] = chars8[i];
		dump_tree(fd, idx8[i], my_path, level + 1);
	}
	for (i = 0; i < chars16_count; i++) {
		my_path[level-1] = chars16[i];
		dump_tree(fd, idx16[i], my_path, level + 1);
	}
}

int main(int argc, char *argv[])
{
	struct squat_trie_header hdr;
	int fd;
	ssize_t ret;

	lib_init();

	fd = open(argv[1], O_RDONLY);
	if (fd == -1)
		i_fatal("open(%s) failed: %m", argv[1]);

	ret = read(fd, &hdr, sizeof(hdr));
	if (ret < 0)
		i_fatal("read() failed: %m");
	if (ret != sizeof(hdr))
		i_fatal("read(header) returned only %ld", ret);

	dump_header(&hdr);
	dump_tree(fd, hdr.root_offset, NULL, 1);

	close(fd);
	return 0;
}
