"""
Device configuration data model.

Hardware I/O inventory (AI/AO/DI/DO modules and their channels) plus the
bindings that connect a physical channel to a configuration I/O variable.

The byte-level truth this model has to stay aligned with:
  - channel_id is a single flat space, 0..63 (`IO_MAX_CHANNELS` in
    `veri-runtime/io/io_mapping.h`, `spec/safeasm-spec.md` section 4.4)
  - io_type code: 0=AI, 1=AO, 2=DI, 3=DO
  - direction code: 0=INPUT, 1=OUTPUT
  - the module kind is **derived**, not chosen: it mirrors
    `st_type_to_io_type` in `veri-stc/src/codegen.v`
"""

from dataclasses import dataclass, field
import re
from typing import Optional

IO_MAX_CHANNELS = 64

#: SafeST identifier shape: also the shape a station id must have, because it
#: becomes part of file names and of the ST the device stage emits.
IDENTIFIER_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")

#: Numeric SafeST types that codegen routes to the analogue modules.
#: Mirrors `D_INPUT, T_INT | D_INPUT, T_DINT | D_INPUT, T_REAL` in
#: veri-stc/src/codegen.v:1024 -- any other type becomes DI/DO.
NUMERIC_IO_TYPES = ("INT", "DINT", "REAL")

#: Types accepted by the SafeST parser in an `IOMAP` entry's type slot.
ST_TYPES = (
    "BOOL",
    "BYTE",
    "WORD",
    "DWORD",
    "SINT",
    "INT",
    "DINT",
    "LINT",
    "REAL",
    "LREAL",
    "TIME",
    "QBOOL",
    "QINT",
    "QDINT",
    "QREAL",
)

IO_KINDS = ("AI", "AO", "DI", "DO")

IO_KIND_CODE = {"AI": 0, "AO": 1, "DI": 2, "DO": 3}

DIRECTIONS = ("input", "output")

#: ``异常后保持`` modes for a channel point. ``""`` means the behaviour is not
#: configured, i.e. the runtime default applies. Neither mode is expressible in
#: `.sasm` section 3 (``spec/safeasm-spec.md`` 4.4 has no hold field and the
#: quality offset is a documented dangling item), so these values are consumed
#: by the IDE-side simulation and monitoring layers only.
FAULT_HOLD_MODES = ("", "last_value", "preset")

#: Suggested station device types. The field is free-form: the device family
#: is an engineering choice, not something the compiler validates.
DEFAULT_DEVICE_TYPES = ("DCU", "RPS", "ESFAS", "SIM")

#: Suggested communication interfaces for inter-station data exchange.
COMM_INTERFACES = ("backplane", "modbus_tcp", "profibus_dp", "iec61850", "none")

#: Cycle time bounds accepted for a station, in milliseconds.
CYCLE_MS_MIN = 1
CYCLE_MS_MAX = 60000


def derive_io_kind(direction: str, st_type: str) -> str:
    """Return the hardware module kind the compiler will encode for a binding.

    Single source of truth is ``st_type_to_io_type`` in the codegen: an
    analogue module is chosen by *numeric type*, everything else is digital.
    Direction picks input (AI/DI) versus output (AO/DO).
    """
    if direction == "input":
        return "AI" if st_type in NUMERIC_IO_TYPES else "DI"
    if direction == "output":
        return "AO" if st_type in NUMERIC_IO_TYPES else "DO"
    raise ValueError(f"Invalid direction: {direction}")


@dataclass
class Station:
    """A configurable controller: the unit the whole device stage is scoped by.

    One station owns its own channel space (0..63), hardware inventory, I/O
    variable table and bindings, because each one compiles and downloads as a
    separate artifact for a separate runtime instance (`sim` / `veristc-agent`).
    """

    station_id: str
    label: str = ""
    device_type: str = "DCU"
    cycle_ms: int = 100
    comm_interface: str = "backplane"
    comm_address: str = ""

    def __post_init__(self) -> None:
        if not IDENTIFIER_RE.match(self.station_id):
            raise ValueError(f"Invalid station id: {self.station_id!r}")
        if not self.device_type.strip():
            raise ValueError("device_type must not be empty")
        if not isinstance(self.cycle_ms, int) or not CYCLE_MS_MIN <= self.cycle_ms <= CYCLE_MS_MAX:
            raise ValueError(
                f"cycle_ms must be an integer in {CYCLE_MS_MIN}..{CYCLE_MS_MAX}, "
                f"got {self.cycle_ms!r}"
            )

    @property
    def display_name(self) -> str:
        return self.label or self.station_id

    def to_dict(self) -> dict:
        return {
            "station_id": self.station_id,
            "label": self.label,
            "device_type": self.device_type,
            "cycle_ms": self.cycle_ms,
            "comm_interface": self.comm_interface,
            "comm_address": self.comm_address,
        }


@dataclass
class HardwareModule:
    """A physical I/O module occupying a contiguous slice of the channel space."""

    module_id: str
    kind: str  # AI / AO / DI / DO
    first_channel: int
    channel_count: int
    label: str = ""

    def __post_init__(self) -> None:
        if self.kind not in IO_KINDS:
            raise ValueError(f"Invalid module kind: {self.kind} (must be one of {IO_KINDS})")
        if self.channel_count <= 0:
            raise ValueError(f"channel_count must be positive, got {self.channel_count}")
        if self.first_channel < 0:
            raise ValueError(f"first_channel must be >= 0, got {self.first_channel}")
        if not isinstance(self.channel_count, int) or not isinstance(self.first_channel, int):
            raise ValueError("first_channel and channel_count must be integers")

    @property
    def channels(self) -> list[int]:
        return list(range(self.first_channel, self.first_channel + self.channel_count))

    @property
    def last_channel(self) -> int:
        return self.first_channel + self.channel_count - 1

    def to_dict(self) -> dict:
        return {
            "module_id": self.module_id,
            "kind": self.kind,
            "first_channel": self.first_channel,
            "channel_count": self.channel_count,
            "last_channel": self.last_channel,
            "label": self.label,
        }


@dataclass
class IoVariable:
    """A configuration I/O variable -- one end of a device binding.

    GATE-7 in ``spec/safest-spec.md`` requires every `IOMAP` entry name to
    resolve against `VAR_GLOBAL` declarations, so these are emitted as
    globals by the renderer, not as PROGRAM interface ports.
    """

    name: str
    direction: str  # input / output
    st_type: str  # SafeST type name
    description: str = ""

    @property
    def io_kind(self) -> str:
        return derive_io_kind(self.direction, self.st_type)

    def to_dict(self) -> dict:
        return {
            "name": self.name,
            "direction": self.direction,
            "st_type": self.st_type,
            "io_kind": self.io_kind,
            "description": self.description,
        }


@dataclass
class ChannelBinding:
    """Binds one I/O variable to one hardware channel, with its point config.

    The scale/bias/limit fields are the engineering values the IDE records; only
    the limits reach the artifact (`.sasm` section 3 `[34-41]`), and scale/bias
    are emitted as identity by the compiler today (spec 4.4). ``has_quality``
    and ``fault_hold`` have **no byte-level counterpart** -- section 3 has no
    quality offset (`SEG_QUALITY` is a documented dangling item) and no hold
    field -- so they drive the IDE-side simulation and monitoring only.
    """

    var_name: str
    channel: int
    scale: float = 1.0
    bias: float = 0.0
    safety_min: Optional[int] = None
    safety_max: Optional[int] = None
    point_name: str = ""
    unit: str = ""
    has_quality: bool = False
    fault_hold: str = ""
    preset_value: Optional[float] = None

    def to_dict(self) -> dict:
        return {
            "var_name": self.var_name,
            "channel": self.channel,
            "scale": self.scale,
            "bias": self.bias,
            "safety_min": self.safety_min,
            "safety_max": self.safety_max,
            "point_name": self.point_name,
            "unit": self.unit,
            "has_quality": self.has_quality,
            "fault_hold": self.fault_hold,
            "preset_value": self.preset_value,
        }


@dataclass
class ValidationIssue:
    """One device-configuration defect, keyed to a variable and/or channel."""

    code: str
    severity: str  # error / warning
    message: str
    var_name: Optional[str] = None
    channel: Optional[int] = None

    def to_dict(self) -> dict:
        return {
            "code": self.code,
            "severity": self.severity,
            "message": self.message,
            "var_name": self.var_name,
            "channel": self.channel,
        }


def default_hardware() -> list[HardwareModule]:
    """A representative DCU I/O inventory covering the four module kinds."""
    return [
        HardwareModule("AI1", "AI", 0, 8, "模拟量输入 8 通道"),
        HardwareModule("AO1", "AO", 8, 4, "模拟量输出 4 通道"),
        HardwareModule("DI1", "DI", 12, 8, "数字量输入 8 通道"),
        HardwareModule("DO1", "DO", 20, 4, "数字量输出 4 通道"),
    ]


def default_io_variables() -> list[IoVariable]:
    """The demo PID configuration surface, matching the graph editor canvas."""
    return [
        IoVariable("SP", "input", "REAL", "设定值"),
        IoVariable("PV", "input", "REAL", "过程值"),
        IoVariable("OUT", "output", "REAL", "控制输出"),
        IoVariable("PUMP_ON", "output", "BOOL", "泵启动指令"),
        IoVariable("LS_LOW", "input", "BOOL", "低液位开关"),
    ]
