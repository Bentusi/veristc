"""
The variables the runtime supplies, so a chart can read the cycle it runs in.

Only names with a byte behind them are listed. `CYCLE_TICK` is the compiler's
`CycleCounter()` builtin, `CYCLE_MS` the cycle the station was configured with:
the generator assigns both as the first statements of the program body, so each
one is a global the debug section exports and a simulation frame or a monitor can
read. A timestamp, a hot-standby role or a watchdog margin would be a number the
chart is simply told to trust, so they stay off this list until the runtime
actually carries them.

The chart reads them; nothing in the chart writes them. That is the checker's job
to enforce, and the reason a palette entry is marked read-only.
"""

from dataclasses import dataclass
from typing import Iterable


#: The cycle a station is created with, so the standalone ST preview can name a
#: value even before the device stage has a station to ask.
DEFAULT_CYCLE_MS = 100


@dataclass(frozen=True)
class SystemVariable:
    #: `{cycle_ms}` in `source` is filled with the station's configured cycle;
    #: anything else is ST exactly as the generated program body writes it.
    name: str
    st_type: str
    description: str
    source: str

    def expression(self, cycle_ms: int) -> str:
        return self.source.format(cycle_ms=cycle_ms)

    def to_dict(self) -> dict:
        return {
            "name": self.name,
            "st_type": self.st_type,
            "description": self.description,
            "readonly": True,
        }


SYSTEM_VARIABLES = (
    SystemVariable("CYCLE_TICK", "DINT", "本周期序号，每周期取 CycleCounter()", "CycleCounter()"),
    SystemVariable("CYCLE_MS", "DINT", "控制站组态周期，毫秒", "{cycle_ms}"),
)

BY_NAME = {variable.name: variable for variable in SYSTEM_VARIABLES}


def is_system(name: str) -> bool:
    return name in BY_NAME


def referenced(names: Iterable[str]) -> list[SystemVariable]:
    """The system variables a chart declares, in the order of the list above."""
    used = set(names)
    return [variable for variable in SYSTEM_VARIABLES if variable.name in used]


def declarations(names: Iterable[str]) -> list[tuple[str, str]]:
    """`(name, type)` pairs the caller must hold as globals for them to be readable."""
    return [(variable.name, variable.st_type) for variable in referenced(names)]


def assignments(names: Iterable[str], cycle_ms: int) -> list[str]:
    """Statements that give each referenced system variable its value this cycle."""
    return [
        f"{variable.name} := {variable.expression(cycle_ms)};"
        for variable in referenced(names)
    ]
