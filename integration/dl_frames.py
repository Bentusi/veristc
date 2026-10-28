#!/usr/bin/env python3
"""Reference sender for the download frame protocol.

This is the engineering-station side of spec/download-spec.md: it turns a
.sasm file into DATA frames on stdout. It exists twice on purpose -- the C
receiver in veri-runtime/hotstandby/download_wire.c and this independent
Python sender -- so a mistake in the MAC convention cannot agree with itself.

Only the standard library is used, and only deterministic bytes are emitted:
the same input and key always produce the same stream.

    dl_frames.py --key 0102...64 image.sasm > frames.bin
    dl_frames.py --key ... --tamper 40 image.sasm      # one payload byte flipped
    dl_frames.py --key ... --bad-crc image.sasm        # CRC field wrong, MAC right
    dl_frames.py --key ... --drop-last image.sasm      # stream ends mid-image
    dl_frames.py --key ... --image-len 1048577 image.sasm
    dl_frames.py --key ... --seq-start 1 image.sasm    # frame 0 missing
"""

import argparse
import binascii
import hashlib
import hmac
import struct
import sys

MAGIC = 0x31464C44          # "DLF1" little-endian
VER = 1
KIND_DATA = 0
FLAG_LAST = 0x0001
HEADER_LEN = 24
MAC_LEN = 32
MAX_PAYLOAD = 4096


def frame(image_len, seq, payload, key, flags=0, bad_crc=False):
    crc = binascii.crc32(payload) & 0xFFFFFFFF
    if bad_crc:
        crc ^= 0xFFFFFFFF
    head = struct.pack("<IBBHIIII", MAGIC, VER, KIND_DATA, flags,
                       image_len, seq, len(payload), crc)
    assert len(head) == HEADER_LEN
    # The MAC covers ver..payload, i.e. everything after the magic.
    mac = hmac.new(key, head[4:] + payload, hashlib.sha256).digest()
    return head + payload + mac


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--key", required=True, help="64 hex chars (32 bytes)")
    ap.add_argument("--image", required=True)
    ap.add_argument("--tamper", type=int, default=None,
                    help="flip bit 0 of the stream byte at this offset")
    ap.add_argument("--bad-crc", action="store_true")
    ap.add_argument("--drop-last", action="store_true")
    ap.add_argument("--image-len", type=int, default=None,
                    help="override the declared image length")
    ap.add_argument("--seq-start", type=int, default=0)
    args = ap.parse_args()

    try:
        key = binascii.unhexlify(args.key)
    except binascii.Error:
        sys.exit("key must be hex")
    if len(key) != MAC_LEN:
        sys.exit("key must be 32 bytes")

    with open(args.image, "rb") as f:
        image = f.read()
    if len(image) == 0:
        sys.exit("empty image")

    declared = args.image_len if args.image_len is not None else len(image)
    out = bytearray()
    off = 0
    seq = args.seq_start
    while off < len(image):
        n = min(MAX_PAYLOAD, len(image) - off)
        first = (off == 0)
        last = (off + n) == len(image)
        out += frame(declared, seq, image[off:off + n], key,
                     FLAG_LAST if last else 0, bad_crc=args.bad_crc and first)
        seq += 1
        off += n
        if args.drop_last and last:
            out = out[:-(HEADER_LEN + n + MAC_LEN)]

    if args.tamper is not None:
        if args.tamper >= len(out):
            sys.exit("tamper offset past end of stream")
        out[args.tamper] ^= 0x01

    sys.stdout.buffer.write(bytes(out))
    sys.stdout.buffer.flush()


if __name__ == "__main__":
    main()
