#!/usr/bin/env python3
"""生成最小 .sasm 测试文件 (返回常量 42)"""
import struct
import zlib

def section(type_id, body):
    hdr = struct.pack("<B", type_id)     # type, 1 byte
    hdr += struct.pack("<I", len(body))  # length, 4 bytes
    hdr += struct.pack("<B", 0)          # reserved, 1 byte
    hdr += struct.pack("<H", 0)          # flags, 2 bytes
    return hdr + body

data = b"SASM"                           # Magic (4 bytes)
data += struct.pack("<B", 1)             # Version (1 byte)
data += struct.pack("<B", 0)             # Flags (1 byte)

# Type Section: 0 params, 1 return I32(0x7F)
# 格式: param_count(4) + param_types(pc×1) + return_count(4) + return_types(rc×1)
type_body = struct.pack("<I", 0)         # param_count = 0
type_body += struct.pack("<I", 1)        # return_count = 1
type_body += struct.pack("<B", 0x7F)     # return_type = I32 (1 byte)
data += section(0, type_body)

# Func Section: type_idx=0, 0 locals
data += section(1,
    struct.pack("<I", 0) +               # type_idx = 0
    struct.pack("<I", 0)                 # local_count = 0
)

# Memory Section: total=256, 0 segments
data += section(2,
    struct.pack("<I", 256) +             # total_size
    struct.pack("<I", 0)                 # segment_count
)

# IOMap Section: 0 entries
data += section(3,
    struct.pack("<I", 0)                 # entry_count
)

# Code Section: func_idx=0, body = I32_CONST 42, RETURN
code_body = struct.pack("<B", 0x41) + struct.pack("<i", 42) + struct.pack("<B", 0x06)
data += section(4,
    struct.pack("<I", 0) +               # func_idx = 0
    struct.pack("<I", len(code_body)) +  # body_size
    code_body
)

# Safety Section: SIL3, cycle_limit=1000 (so VM won't stop us), no loops
data += section(5,
    struct.pack("<B", 1) +               # safety_level = SIL3
    struct.pack("<I", 1000) +            # cycle_limit = 1000
    struct.pack("<I", 8) +               # stack_depth = 8
    struct.pack("<I", 0) +               # loop_count = 0
    struct.pack("<I", 0)                 # mem_range_count = 0
)

# CRC32 over all bytes after the six-byte file header.
data += struct.pack("<I", zlib.crc32(data[6:]) & 0xFFFFFFFF)

path = "tests/sasm-examples/return42.sasm"
with open(path, "wb") as f:
    f.write(data)
print(f"生成 {path} ({len(data)} bytes)")
print(f"Hex: {' '.join(f'{b:02X}' for b in data)}")
