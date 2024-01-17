#!/usr/bin/env python3

# This tool decompresses any dovecot LZ4 files
# Usage: python3 decompress-dovecot-lz4.py [filename]
#
# Can read from stdin or from given file
# Writes to stdout
#
# Requires: python-lz4

import lz4.block
import sys

MAGIC = b"Dovecot-LZ4\x0d\x2a\x9b\xc5"
MAX_CHUNK = 1024*1024


def read_frame(f):
    cs = int.from_bytes(f.read(4), 'big')
    if cs > MAX_CHUNK:
        raise RuntimeError("Frame too large")
    frame = f.read(cs)
    if len(frame) != cs:
        raise RuntimeError(f"Frame size corrupted ({len(frame)} != {cs})")
    return frame


def decompress_stream(f):
    if f.read(len(MAGIC)) != MAGIC:
        raise RuntimeError("Not a Dovecot LZ4 file")
    # max uncompressed chunk
    max_chunk = int.from_bytes(f.read(4), 'big')

    while True:
        indata = read_frame(f)
        if len(indata) == 0:
            break
        sys.stdout.buffer.write(lz4.block.decompress(indata, uncompressed_size=max_chunk))


if __name__ == "__main__":
    if len(sys.argv) == 1:
        f = sys.stdin.buffer
    else:
        f = open(sys.argv[1], "rb")
    decompress_stream(f)
