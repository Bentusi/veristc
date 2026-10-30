"""
Device configuration module.

Stations (controllers with a device type, cycle time and communication
settings), their hardware I/O inventory and the bindings that map a channel
point onto a configuration variable. The module emits the SafeST
`VAR_GLOBAL + IOMAP` block the compiler encodes as `.sasm` section 3, and the
external variable table the graphics stage associates its pins with.
"""

from .models import (
    ChannelBinding,
    HardwareModule,
    IoVariable,
    Station,
    ValidationIssue,
    derive_io_kind,
)
from .service import DeviceProject, DeviceService, get_device_project

__all__ = [
    "ChannelBinding",
    "DeviceProject",
    "DeviceService",
    "HardwareModule",
    "IoVariable",
    "Station",
    "ValidationIssue",
    "derive_io_kind",
    "get_device_project",
]
