#!/usr/bin/env python3
"""Decode the float immediates carried by a .sasm CODE section.

Independent of the compiler: it walks the section list per
spec/safeasm-spec.md and reads the instruction stream with the opcode lengths of
appendix A, then prints one `f32 <hex>` / `f64 <hex>` row per F32_CONST /
F64_CONST, in encoding order. The hex value is the little-endian bit pattern as
an unsigned integer, i.e. what IEEE-754 puts in memory on a little-endian target.

Unknown opcodes are an error rather than a skipped byte, so a drifted layout
fails loudly instead of reporting a shifted row.
"""
import struct
import sys

MAGIC = 0x4D534153
VERSION = 1
FIRST_SECTION = 6
SECTION_HEADER = 8
CODE_SECTION = 4
FUNC_HEADER = 8  # u32 index + u32 body length

# opcode -> total instruction length, spec/safeasm-spec.md appendix A
LENGTHS = {
    0x00: 1, 0x01: 1, 0x02: 5, 0x03: 5, 0x04: 5, 0x05: 5, 0x06: 1,
    0x10: 5, 0x1A: 1, 0x1B: 1,
    0x20: 5, 0x21: 5, 0x22: 5,
    0x41: 5, 0x43: 5, 0x44: 9,
    0x45: 1, 0x46: 1, 0x47: 1, 0x48: 1, 0x49: 1, 0x4A: 1, 0x4B: 1,
    0x50: 9,
    0x53: 1, 0x54: 1, 0x55: 1, 0x56: 1, 0x57: 1, 0x58: 1, 0x59: 1,
}
for opcode in list(range(0x28, 0x3A)):  # load/store take align+offset
    LENGTHS[opcode] = 5
for opcode in range(0x6A, 0x7C):  # i32 arithmetic and bit ops
    LENGTHS[opcode] = 1


def fail(message):
    sys.stderr.write("f32_immediates: %s\n" % message)
    raise SystemExit(1)


def section_body(data, section_id):
    end = len(data) - 4  # trailing CRC placeholder
    offset = FIRST_SECTION
    while offset + SECTION_HEADER <= end:
        length = struct.unpack_from("<I", data, offset + 1)[0]
        if length > end - offset - SECTION_HEADER:
            fail("section %d runs past the CRC placeholder" % data[offset])
        if data[offset] == section_id:
            return offset + SECTION_HEADER, length
        offset += SECTION_HEADER + length
    fail("section %d not found" % section_id)


def rows(data):
    body, length = section_body(data, CODE_SECTION)
    out = []
    consumed = 0
    while consumed < length:
        if consumed + FUNC_HEADER > length:
            fail("truncated function header at offset %d" % consumed)
        _, body_len = struct.unpack_from("<II", data, body + consumed)
        cursor = body + consumed + FUNC_HEADER
        stop = cursor + body_len
        if stop > body + length:
            fail("function body at offset %d runs past the code section" % consumed)
        while cursor < stop:
            opcode = data[cursor]
            width = LENGTHS.get(opcode)
            if width is None:
                fail("unknown opcode 0x%02X at offset %d" % (opcode, cursor - body))
            if width > 1 and cursor + width > stop:
                fail("instruction 0x%02X runs past the function body" % opcode)
            if opcode == 0x43:
                out.append(("f32", "%08x" % struct.unpack_from("<I", data, cursor + 1)[0]))
            elif opcode == 0x44:
                out.append(("f64", "%016x" % struct.unpack_from("<Q", data, cursor + 1)[0]))
            cursor += width
        consumed += FUNC_HEADER + body_len
    return out


def main():
    if len(sys.argv) != 2:
        fail("usage: f32_immediates.py <file.sasm>")
    with open(sys.argv[1], "rb") as handle:
        data = handle.read()
    magic, version = struct.unpack_from("<IB", data, 0)
    if magic != MAGIC or version != VERSION:
        fail("not a SASM v%d module (magic=0x%08X version=%d)" % (VERSION, magic, version))
    for kind, value in rows(data):
        print("%s %s" % (kind, value))


main()
