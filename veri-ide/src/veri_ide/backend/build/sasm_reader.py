"""
Read the sections of a `.sasm` image.

Layout is `spec/safeasm-spec.md` §2.2 (8-byte section header) and §4.3/§4.4/§4.6/§4.7/§4.8.
The field grammar mirrors `veri-runtime/core/loader.c` so the engineering station and
the safety core never disagree about what a deployed image contains; nothing here is
executed by the target.
"""

import struct
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional

MAGIC = 0x4D534153  # "SASM", little endian
VERSION = 1
HEADER_BYTES = 6  # magic(4) + version(1) + flags(1), spec §4.0
CRC_BYTES = 4
SECTION_HEADER_BYTES = 8

SECTION_NAMES = {
    0: "TYPE",
    1: "FUNC",
    2: "MEM",
    3: "IOMAP",
    4: "CODE",
    5: "SAFE",
    6: "WCET",
    7: "DEBUG",
}

# spec §4.3
SEGMENT_KINDS = {
    0: "IO_INPUT",
    1: "IO_OUTPUT",
    2: "GLOBAL",
    3: "FB_DATA",
    4: "STACK",
    5: "CONST",
    6: "QUALITY",
}

SAFETY_LEVELS = {0: "SIL2", 1: "SIL3"}


class SasmError(ValueError):
    """The bytes are not a module this reader can trust."""


@dataclass
class Segment:
    kind: str
    start: int
    size: int


@dataclass
class WcetRow:
    func_idx: int
    cycles: int
    ns: int


@dataclass
class Image:
    file_bytes: int
    flags: int
    sections: dict[str, int] = field(default_factory=dict)
    memory_total: int = 0
    segments: list[Segment] = field(default_factory=list)
    iomap_count: int = 0
    code_bytes: int = 0
    safety_level: Optional[str] = None
    cycle_limit: Optional[int] = None
    stack_depth: Optional[int] = None
    loop_bounds: list[dict] = field(default_factory=list)
    wcet: list[WcetRow] = field(default_factory=list)
    symbols: list[dict] = field(default_factory=list)

    def segment_bytes(self, *kinds: str) -> int:
        return sum(seg.size for seg in self.segments if seg.kind in kinds)

    def segment_count(self, kind: str) -> int:
        return sum(1 for seg in self.segments if seg.kind == kind)


def read_file(path: Path | str) -> Image:
    return read(Path(path).read_bytes())


def read(data: bytes) -> Image:
    if len(data) < HEADER_BYTES + CRC_BYTES:
        raise SasmError(f"module is {len(data)} bytes, too short for header and CRC")
    magic, version, flags = struct.unpack_from("<IBB", data, 0)
    if magic != MAGIC:
        raise SasmError(f"bad magic 0x{magic:08X}, expected 0x{MAGIC:08X}")
    if version != VERSION:
        raise SasmError(f"unsupported version {version}, expected {VERSION}")

    image = Image(file_bytes=len(data), flags=flags)
    body = len(data) - CRC_BYTES
    offset = HEADER_BYTES
    while offset + SECTION_HEADER_BYTES <= body:
        section_id = data[offset]
        length = struct.unpack_from("<I", data, offset + 1)[0]
        start = offset + SECTION_HEADER_BYTES
        stop = start + length
        if stop > body:
            raise SasmError(
                f"section {SECTION_NAMES.get(section_id, section_id)} runs past the CRC"
            )
        image.sections[SECTION_NAMES.get(section_id, str(section_id))] = length
        _decode(section_id, data[start:stop], image)
        offset = stop
    if offset != body:
        raise SasmError(f"section list ends at {offset}, but the body stops at {body}")
    return image


def _decode(section_id: int, body: bytes, image: Image) -> None:
    if section_id == 2:
        _memory(body, image)
    elif section_id == 3:
        _iomap(body, image)
    elif section_id == 4:
        _code(body, image)
    elif section_id == 5:
        _safety(body, image)
    elif section_id == 6:
        # The safety section carries the same table at its tail; section 6 is the
        # standalone copy, and reading only it keeps the total from doubling.
        image.wcet = _wcet(body, [])
    elif section_id == 7:
        image.symbols = _debug(body)


class _Read:
    """Every field read is checked against the section length, so a drifted layout
    raises instead of reporting a shifted number."""

    def __init__(self, body: bytes) -> None:
        self.body = body
        self.offset = 0

    def __enter__(self) -> "_Read":
        return self

    def __exit__(self, *_: object) -> None:
        return None

    @property
    def remaining(self) -> int:
        return len(self.body) - self.offset

    def u8(self) -> int:
        return self.raw(1)[0]

    def u16(self) -> int:
        return self._unpack("<H", 2)[0]

    def u32(self) -> int:
        return self._unpack("<I", 4)[0]

    def raw(self, count: int) -> bytes:
        self._need(count)
        chunk = self.body[self.offset : self.offset + count]
        self.offset += count
        return chunk

    def _need(self, count: int) -> None:
        if self.remaining < count:
            raise SasmError(f"section has {self.remaining} bytes left, a field needs {count}")

    def _unpack(self, fmt: str, count: int) -> tuple:
        return struct.unpack_from(fmt, self.raw(count), 0)


def _memory(body: bytes, image: Image) -> None:
    with _Read(body) as p:
        image.memory_total = p.u32()
        segments: list[Segment] = []
        for _ in range(p.u32()):
            kind_id = p.u8()
            kind = SEGMENT_KINDS.get(kind_id)
            if kind is None:
                raise SasmError(f"unknown memory segment type {kind_id}")
            segments.append(Segment(kind=kind, start=p.u32(), size=p.u32()))
        if p.remaining:
            raise SasmError(f"{p.remaining} bytes of the memory section were not consumed")
    image.segments = segments


def _iomap(body: bytes, image: Image) -> None:
    with _Read(body) as p:
        count = p.u32()
        entry_bytes = 4 + 4 + 4 + 1 + 1 + 4 + 8 + 8 + 4 + 4  # spec §4.4, 42 bytes
        if p.remaining != count * entry_bytes:
            raise SasmError(
                f"IOMAP section holds {p.remaining} bytes for {count} entries, "
                f"expected {count * entry_bytes}"
            )
    image.iomap_count = count


def _code(body: bytes, image: Image) -> None:
    with _Read(body) as p:
        total = 0
        while p.remaining:
            p.u32()  # func_idx
            size = p.u32()
            p.raw(size)
            total += size
    image.code_bytes = total


def _safety(body: bytes, image: Image) -> None:
    with _Read(body) as p:
        level = p.u8()
        image.safety_level = SAFETY_LEVELS.get(level, str(level))
        image.cycle_limit = p.u32()
        image.stack_depth = p.u32()
        image.loop_bounds = [
            {
                "func_idx": p.u32(),
                "instr_offset": p.u32(),
                "max_iterations": p.u32(),
            }
            for _ in range(p.u32())
        ]
        for _ in range(p.u32()):
            p.u32()
            p.u32()
        if p.remaining >= 4:
            image.wcet = _rows(p, image.wcet)
        if p.remaining:
            raise SasmError(f"{p.remaining} bytes of the safety section were not consumed")


def _wcet(body: bytes, existing: list[WcetRow]) -> list[WcetRow]:
    with _Read(body) as p:
        return _rows(p, existing)


def _rows(p: _Read, existing: list[WcetRow]) -> list[WcetRow]:
    rows = list(existing)
    for _ in range(p.u32()):
        rows.append(WcetRow(func_idx=p.u32(), cycles=p.u32(), ns=p.u32()))
    if p.remaining:
        raise SasmError(f"{p.remaining} bytes of the WCET list were not consumed")
    return rows


def _debug(body: bytes) -> list[dict]:
    with _Read(body) as p:
        pool: list[str] = []
        for _ in range(p.u32()):
            pool.append(p.raw(p.u32()).decode("utf-8", errors="replace"))
        rows = []
        for _ in range(p.u32()):
            name_off = p.u32()
            address = p.u32()
            type_tag = p.u8()
            size = p.u8()
            p.u16()  # flags, reserved and required to be 0 (spec §4.8)
            rows.append(
                {
                    "name": _name_at(pool, name_off),
                    "address": address,
                    "type_tag": type_tag,
                    "size": size,
                }
            )
        if p.remaining:
            raise SasmError(f"{p.remaining} bytes of the debug section were not consumed")
    return rows


def _name_at(pool: list[str], offset: int) -> str:
    """`name_off` is a byte offset into the pool, where each entry carries its own
    `u32 len` prefix (spec §4.8), so it lands on an entry boundary."""
    cursor = 0
    for entry in pool:
        if cursor == offset:
            return entry
        cursor += 4 + len(entry.encode("utf-8"))
    return f"0x{offset:x}"
