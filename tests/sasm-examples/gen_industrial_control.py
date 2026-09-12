#!/usr/bin/env python3
"""Generate the engineering-grade SafeASM capacity test program.

The generated program models a feedwater pump control pipeline:
  1. The entry function applies an initial process demand.
  2. The active call chain uses 256 functions and 256 stack frames.
  3. The final active stage clamps the result to the safety range [0, 4095].
  4. The remaining functions fill the 4096-entry function table.

Function count and call depth are independent limits: the module proves the
4096-function table capacity without creating a 4096-frame runtime stack.
"""

import struct
import zlib
from pathlib import Path


FUNCTION_COUNT = 4096
CALL_CHAIN_DEPTH = 256
INITIAL_DEMAND = 3500
SAFETY_HIGH = 4095
CYCLE_LIMIT = 10000

VAL_I32 = 0x7F

OP_RETURN = 0x06
OP_CALL = 0x10
OP_LOCAL_GET = 0x20
OP_LOCAL_SET = 0x21
OP_I32_CONST = 0x41
OP_I32_LT_S = 0x48
OP_I32_GT_S = 0x4A
OP_I32_ADD = 0x6A
OP_SELECT = 0x1B


def section(section_type, body):
    header = struct.pack("<BIBH", section_type, len(body), 0, 0)
    return header + body


def i32(value):
    return struct.pack("<Bi", OP_I32_CONST, value)


def call(func_idx):
    return struct.pack("<BI", OP_CALL, func_idx)


def local_get(index):
    return struct.pack("<BI", OP_LOCAL_GET, index)


def local_set(index):
    return struct.pack("<BI", OP_LOCAL_SET, index)


def function_body(index):
    if index == 0:
        return i32(INITIAL_DEMAND) + call(1) + bytes([OP_RETURN])

    if index < CALL_CHAIN_DEPTH - 1:
        compensation = (index % 5) + 1
        return (
            local_get(0)
            + i32(compensation)
            + bytes([OP_I32_ADD])
            + call(index + 1)
            + bytes([OP_RETURN])
        )

    if index == CALL_CHAIN_DEPTH - 1:
        return (
            local_get(0)
            + i32(SAFETY_HIGH)
            + local_get(0)
            + i32(SAFETY_HIGH)
            + bytes([OP_I32_GT_S, OP_SELECT])
            + local_set(0)
            + local_get(0)
            + i32(0)
            + local_get(0)
            + i32(0)
            + bytes([OP_I32_LT_S, OP_SELECT, OP_RETURN])
        )

    # Unused capacity entries are valid, separately callable functions.
    return i32(0) + bytes([OP_RETURN])


def build_program():
    data = b"SASM" + struct.pack("<BB", 1, 0)

    type_body = struct.pack("<I", 1) + bytes([VAL_I32])
    type_body += struct.pack("<I", 1) + bytes([VAL_I32])
    data += section(0, type_body)

    func_body = bytearray()
    for index in range(FUNCTION_COUNT):
        local_count = 1 if 0 < index < CALL_CHAIN_DEPTH else 0
        func_body += struct.pack("<II", 0, local_count)
        func_body += bytes([VAL_I32]) * local_count
    data += section(1, bytes(func_body))

    memory_body = struct.pack("<II", 4096, 1)
    memory_body += struct.pack("<BII", 2, 0, 4096)
    data += section(2, memory_body)

    data += section(3, struct.pack("<I", 0))

    code_body = bytearray()
    for index in range(FUNCTION_COUNT):
        body = function_body(index)
        code_body += struct.pack("<II", index, len(body))
        code_body += body
    data += section(4, bytes(code_body))

    safety_body = struct.pack("<BII", 1, CYCLE_LIMIT, CALL_CHAIN_DEPTH)
    safety_body += struct.pack("<I", 0)
    safety_body += struct.pack("<I", 1)
    safety_body += struct.pack("<II", 0, 4096)
    data += section(5, safety_body)

    data += struct.pack("<I", zlib.crc32(data[6:]) & 0xFFFFFFFF)
    return data


def main():
    output = Path(__file__).with_name("industrial_control.sasm")
    program = build_program()
    output.write_bytes(program)
    print(f"generated {output} ({len(program)} bytes)")


if __name__ == "__main__":
    main()
