#!/usr/bin/env python3
"""Generate a nuclear reactor protection and engineered-safety-feature case.

The SafeASM program models:
  1. Four independent protection channels (A/B/C/D).
  2. Each channel checks high power, low pressure and low level.
  3. Invalid or bypassed channels are removed from the trip vote.
  4. A 2-out-of-4 vote generates the reactor trip signal.
  5. Two engineered safety feature trains A and B have independent enables
     and permissives, then drive redundant outputs.
  6. A mismatch monitor reports disagreement between train A and train B.

Test inputs are read from fixed linear-memory offsets. The C integration test
loads scenarios into those offsets before each VM cycle.
"""

import struct
import zlib
from pathlib import Path


VAL_I32 = 0x7F

OP_RETURN = 0x06
OP_CALL = 0x10
OP_LOCAL_GET = 0x20
OP_LOCAL_SET = 0x21
OP_I32_LOAD = 0x28
OP_I32_STORE = 0x36
OP_I32_CONST = 0x41
OP_I32_EQZ = 0x45
OP_I32_LE_S = 0x49
OP_I32_GE_S = 0x4B
OP_I32_ADD = 0x6A
OP_I32_AND = 0x71
OP_I32_XOR = 0x73

POWER_TRIP = 1000
PRESSURE_TRIP = 120
LEVEL_TRIP = 20

CHANNEL_STRIDE = 20
CHANNEL_BASES = (0, 20, 40, 60)

TRAIN_A_ENABLE = 80
TRAIN_A_PERMISSIVE = 84
TRAIN_B_ENABLE = 88
TRAIN_B_PERMISSIVE = 92

REACTOR_TRIP_OUT = 96
TRAIN_A_OUT = 100
TRAIN_B_OUT = 104
VOTE_COUNT_OUT = 108
TRAIN_MISMATCH_OUT = 112
CHANNEL_OUT = (116, 120, 124, 128)

MEMORY_SIZE = 4096
CYCLE_LIMIT = 10000
STATIC_STACK_DEPTH = 3


def section(section_type, body):
    return struct.pack("<BIBH", section_type, len(body), 0, 0) + body


def u32(value):
    return struct.pack("<I", value)


def i32(value):
    return struct.pack("<Bi", OP_I32_CONST, value)


def call(func_idx):
    return struct.pack("<BI", OP_CALL, func_idx)


def local_get(index):
    return struct.pack("<BI", OP_LOCAL_GET, index)


def local_set(index):
    return struct.pack("<BI", OP_LOCAL_SET, index)


def load(address):
    return i32(address) + struct.pack("<BHH", OP_I32_LOAD, 2, 0)


def store(address, value):
    return i32(address) + value + struct.pack("<BHH", OP_I32_STORE, 2, 0)


def channel_trip():
    """Trip if power is high, pressure is low or level is low."""
    return (
        local_get(0)
        + i32(POWER_TRIP)
        + bytes([OP_I32_GE_S])
        + local_get(1)
        + i32(PRESSURE_TRIP)
        + bytes([OP_I32_LE_S, OP_I32_ADD, OP_I32_EQZ, OP_I32_EQZ])
        + local_get(2)
        + i32(LEVEL_TRIP)
        + bytes([OP_I32_LE_S, OP_I32_ADD, OP_I32_EQZ, OP_I32_EQZ])
        + local_get(3)
        + bytes([OP_I32_EQZ])
        + local_get(4)
        + bytes([OP_I32_EQZ, OP_I32_EQZ, OP_I32_ADD, OP_I32_EQZ, OP_I32_EQZ])
        + bytes([OP_I32_EQZ, OP_I32_AND, OP_RETURN])
    )


def channel_wrapper(base):
    return (
        load(base)
        + load(base + 4)
        + load(base + 8)
        + load(base + 12)
        + load(base + 16)
        + call(2)
        + bytes([OP_RETURN])
    )


def count_votes():
    return (
        local_get(0)
        + local_get(1)
        + bytes([OP_I32_ADD])
        + local_get(2)
        + bytes([OP_I32_ADD])
        + local_get(3)
        + bytes([OP_I32_ADD])
        + bytes([OP_RETURN])
    )


def train_logic():
    return (
        local_get(0)
        + local_get(1)
        + bytes([OP_I32_AND])
        + local_get(2)
        + bytes([OP_I32_AND, OP_RETURN])
    )


def consistency():
    return local_get(0) + local_get(1) + bytes([OP_I32_XOR, OP_RETURN])


def entry_function():
    code = bytearray()

    for channel_index, func_index in enumerate((3, 4, 5, 6)):
        code += call(func_index)
        code += local_set(channel_index)

    code += local_get(0) + local_get(1) + local_get(2) + local_get(3)
    code += call(1) + local_set(4)
    code += local_get(4) + i32(2) + bytes([OP_I32_GE_S]) + local_set(8)

    code += local_get(8) + load(TRAIN_A_ENABLE) + load(TRAIN_A_PERMISSIVE)
    code += call(7) + local_set(5)
    code += local_get(8) + load(TRAIN_B_ENABLE) + load(TRAIN_B_PERMISSIVE)
    code += call(8) + local_set(6)

    code += local_get(5) + local_get(6) + call(9) + local_set(7)

    for channel_index, output in enumerate(CHANNEL_OUT):
        code += store(output, local_get(channel_index))

    code += store(REACTOR_TRIP_OUT, local_get(8))
    code += store(TRAIN_A_OUT, local_get(5))
    code += store(TRAIN_B_OUT, local_get(6))
    code += store(VOTE_COUNT_OUT, local_get(4))
    code += store(TRAIN_MISMATCH_OUT, local_get(7))
    code += local_get(8) + bytes([OP_RETURN])

    return bytes(code)


def build_type_section():
    signatures = (
        (0, 1),
        (4, 1),
        (5, 1),
        (3, 1),
        (2, 1),
    )
    body = bytearray()
    for param_count, return_count in signatures:
        body += u32(param_count) + bytes([VAL_I32]) * param_count
        body += u32(return_count) + bytes([VAL_I32]) * return_count
    return section(0, bytes(body))


def build_function_section():
    type_indices = (0, 1, 2, 0, 0, 0, 0, 3, 3, 4)
    local_counts = (9, 4, 5, 0, 0, 0, 0, 3, 3, 2)
    body = bytearray()
    for type_idx, local_count in zip(type_indices, local_counts):
        body += u32(type_idx) + u32(local_count)
        body += bytes([VAL_I32]) * local_count
    return section(1, bytes(body))


def build_memory_section():
    body = u32(MEMORY_SIZE) + u32(1)
    body += struct.pack("<BII", 2, 0, MEMORY_SIZE)
    return section(2, body)


def io_entry(mem_offset, channel_id, direction, io_type, bit_width):
    body = u32(0) + u32(mem_offset) + u32(channel_id)
    body += struct.pack("<BBI", direction, io_type, bit_width)
    body += struct.pack("<dd", 1.0, 0.0)
    body += struct.pack("<ii", -32768, 32767)
    return body


def build_iomap_section():
    entries = []
    channel_id = 0
    for base in CHANNEL_BASES:
        for offset, io_type, bit_width in (
            (0, 0, 32),
            (4, 0, 32),
            (8, 0, 32),
            (12, 2, 1),
            (16, 2, 1),
        ):
            entries.append(io_entry(base + offset, channel_id, 0, io_type, bit_width))
            channel_id += 1

    for offset in (
        TRAIN_A_ENABLE,
        TRAIN_A_PERMISSIVE,
        TRAIN_B_ENABLE,
        TRAIN_B_PERMISSIVE,
    ):
        entries.append(io_entry(offset, channel_id, 0, 2, 1))
        channel_id += 1

    for offset in (
        REACTOR_TRIP_OUT,
        TRAIN_A_OUT,
        TRAIN_B_OUT,
        *CHANNEL_OUT,
        TRAIN_MISMATCH_OUT,
    ):
        entries.append(io_entry(offset, channel_id, 1, 3, 1))
        channel_id += 1

    return section(3, u32(len(entries)) + b"".join(entries))


def build_code_section():
    bodies = (
        entry_function(),
        count_votes(),
        channel_trip(),
        channel_wrapper(CHANNEL_BASES[0]),
        channel_wrapper(CHANNEL_BASES[1]),
        channel_wrapper(CHANNEL_BASES[2]),
        channel_wrapper(CHANNEL_BASES[3]),
        train_logic(),
        train_logic(),
        consistency(),
    )
    body = bytearray()
    for func_idx, code in enumerate(bodies):
        body += u32(func_idx) + u32(len(code)) + code
    return section(4, bytes(body))


def build_safety_section():
    body = struct.pack("<BII", 1, CYCLE_LIMIT, STATIC_STACK_DEPTH)
    body += u32(0)
    body += u32(1) + struct.pack("<II", 0, MEMORY_SIZE)
    return section(5, body)


def build_program():
    data = b"SASM" + struct.pack("<BB", 1, 0)
    data += build_type_section()
    data += build_function_section()
    data += build_memory_section()
    data += build_iomap_section()
    data += build_code_section()
    data += build_safety_section()
    data += u32(zlib.crc32(data[6:]) & 0xFFFFFFFF)
    return data


def main():
    output = Path(__file__).with_name("nuclear_protection.sasm")
    program = build_program()
    output.write_bytes(program)
    print(f"generated {output} ({len(program)} bytes)")


if __name__ == "__main__":
    main()
