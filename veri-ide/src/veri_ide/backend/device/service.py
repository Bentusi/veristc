"""
Device configuration service.

Owns three things and the consistency between them:
  1. the hardware inventory (modules and their channel ranges)
  2. the configuration I/O variable table (the algorithm side of a binding)
  3. the bindings channel <-> variable

`validate` is the gate that keeps a mapping compilable: the compiler derives
the module kind from direction + type (``st_type_to_io_type``) and resolves
every `IOMAP` name against `VAR_GLOBAL` (GATE-7), so a channel that disagrees
with the derived kind, or a name that is not a global, produces an artifact
that silently carries no I/O. `render_st` emits exactly the block the SafeST
parser accepts, so the IDE stays the only writer of section 3.
"""

import math
import tomllib
from pathlib import Path
from typing import Optional

from .models import (
    FAULT_HOLD_MODES,
    IO_MAX_CHANNELS,
    IDENTIFIER_RE,
    ST_TYPES,
    ChannelBinding,
    HardwareModule,
    IoVariable,
    Station,
    ValidationIssue,
    default_hardware,
    default_io_variables,
    derive_io_kind,
)


def _format_number(value: float) -> str:
    """Render a TOML float that round-trips and stays byte-deterministic."""
    if math.isfinite(value) and value == int(value) and abs(value) < 1e15:
        return f"{value:.1f}"
    return repr(value)


class DeviceService:
    """One station's device configuration: inventory, points and bindings."""

    def __init__(
        self,
        station: Optional[Station] = None,
        modules: Optional[list[HardwareModule]] = None,
        variables: Optional[list[IoVariable]] = None,
        bindings: Optional[list[ChannelBinding]] = None,
    ) -> None:
        self.station = station if station is not None else Station("ST1", "主控站")
        self._modules: dict[str, HardwareModule] = {}
        self._variables: dict[str, IoVariable] = {}
        self._bindings: dict[str, ChannelBinding] = {}

        for module in modules if modules is not None else default_hardware():
            self._modules[module.module_id] = module
        for variable in variables if variables is not None else default_io_variables():
            self._variables[variable.name] = variable
        for binding in bindings if bindings is not None else self._default_bindings():
            self._bindings[binding.var_name] = binding

    @staticmethod
    def _default_bindings() -> list[ChannelBinding]:
        """A valid demo mapping over the default inventory and variable table."""
        return [
            ChannelBinding("SP", 2, unit="%", point_name="SP-001"),
            ChannelBinding("PV", 0, unit="%", point_name="PV-001",
                           safety_min=0, safety_max=1000, has_quality=True,
                           fault_hold="last_value"),
            ChannelBinding("OUT", 8, unit="%", point_name="OUT-001",
                           safety_min=0, safety_max=1000, fault_hold="preset",
                           preset_value=0.0),
            ChannelBinding("PUMP_ON", 20, point_name="DO-PUMP", fault_hold="last_value"),
            ChannelBinding("LS_LOW", 12, point_name="DI-LS", has_quality=True),
        ]

    # ---------- station ----------

    def set_station(self, station: Station) -> None:
        self.station = station

    # ---------- hardware inventory ----------

    def modules(self) -> list[HardwareModule]:
        return sorted(self._modules.values(), key=lambda m: (m.first_channel, m.module_id))

    def add_module(self, module: HardwareModule) -> None:
        if module.module_id in self._modules:
            raise ValueError(f"Module already exists: {module.module_id}")
        if module.last_channel >= IO_MAX_CHANNELS:
            raise ValueError(
                f"Channel range ends at {module.last_channel}, beyond the "
                f"{IO_MAX_CHANNELS}-channel space"
            )
        for other in self._modules.values():
            if not (module.last_channel < other.first_channel
                    or module.first_channel > other.last_channel):
                raise ValueError(
                    f"Channel range {module.first_channel}..{module.last_channel} "
                    f"overlaps module {other.module_id} "
                    f"({other.first_channel}..{other.last_channel})"
                )
        self._modules[module.module_id] = module

    def remove_module(self, module_id: str) -> None:
        module = self._modules.pop(module_id, None)
        if module is None:
            raise KeyError(f"Module not found: {module_id}")
        claimed = set(module.channels)
        for name in [b.var_name for b in self._bindings.values() if b.channel in claimed]:
            del self._bindings[name]

    def module_of(self, channel: int) -> Optional[HardwareModule]:
        for module in self._modules.values():
            if channel in module.channels:
                return module
        return None

    def channel_index(self) -> dict[int, str]:
        """channel -> module_id, for the modules that own a channel."""
        index: dict[int, str] = {}
        for module in self.modules():
            for channel in module.channels:
                index.setdefault(channel, module.module_id)
        return index

    # ---------- configuration I/O variables ----------

    def variables(self) -> list[IoVariable]:
        return sorted(self._variables.values(), key=lambda v: v.name)

    def set_variables(self, variables: list[IoVariable]) -> None:
        """Replace the I/O variable table (synced from the graph configuration)."""
        self._variables = {v.name: v for v in variables}
        for name in [b.var_name for b in self._bindings.values() if b.var_name not in self._variables]:
            del self._bindings[name]

    def add_variable(self, variable: IoVariable) -> None:
        if variable.st_type not in ST_TYPES:
            raise ValueError(f"Unsupported SafeST type: {variable.st_type}")
        if variable.direction not in ("input", "output"):
            raise ValueError(f"Invalid direction: {variable.direction}")
        if not IDENTIFIER_RE.match(variable.name):
            raise ValueError(f"Invalid variable name: {variable.name}")
        self._variables[variable.name] = variable

    def remove_variable(self, name: str) -> None:
        if self._variables.pop(name, None) is None:
            raise KeyError(f"Variable not found: {name}")
        self._bindings.pop(name, None)

    # ---------- bindings ----------

    def bindings(self) -> list[ChannelBinding]:
        return [self._bindings[name] for name in sorted(self._bindings)]

    def binding_for(self, var_name: str) -> Optional[ChannelBinding]:
        return self._bindings.get(var_name)

    def bind(self, binding: ChannelBinding) -> None:
        """Create or replace the binding for ``binding.var_name``."""
        if binding.var_name not in self._variables:
            raise KeyError(f"Unknown configuration variable: {binding.var_name}")
        self._bindings[binding.var_name] = binding

    def unbind(self, var_name: str) -> None:
        if self._bindings.pop(var_name, None) is None:
            raise KeyError(f"No binding for variable: {var_name}")

    def hardware_view(self) -> list[dict]:
        """Modules with each channel annotated by its binding, for the tree UI."""
        bound = {b.channel: b.var_name for b in self._bindings.values()}
        view = []
        for module in self.modules():
            view.append(
                {
                    **module.to_dict(),
                    "channel_list": [
                        {
                            "channel": channel,
                            "var_name": bound.get(channel),
                            "bound": channel in bound,
                        }
                        for channel in module.channels
                    ],
                }
            )
        return view

    def mapping_rows(self) -> list[dict]:
        """Flat table rows: one per binding, joined with variable and module."""
        index = self.channel_index()
        rows = []
        for name in sorted(self._bindings):
            binding = self._bindings[name]
            variable = self._variables.get(name)
            module_id = index.get(binding.channel)
            module = self._modules.get(module_id) if module_id else None
            rows.append(
                {
                    **binding.to_dict(),
                    "direction": variable.direction if variable else None,
                    "st_type": variable.st_type if variable else None,
                    "derived_kind": variable.io_kind if variable else None,
                    "module_id": module_id,
                    "module_kind": module.kind if module else None,
                    "kind_match": bool(module and variable and module.kind == variable.io_kind),
                }
            )
        return rows

    def external_variables(self) -> list[dict]:
        """The station's external variable table -- what stage 2 associates pins with.

        One row per declared configuration variable, mapped or not: an unmapped
        variable still has to appear in `VAR_GLOBAL` for the graph stage to
        reference it, so the table is driven by the variable list, not by the
        bindings.
        """
        index = self.channel_index()
        rows = []
        for name, variable in sorted(self._variables.items()):
            binding = self._bindings.get(name)
            module_id = index.get(binding.channel) if binding else None
            rows.append(
                {
                    "name": name,
                    "direction": variable.direction,
                    "st_type": variable.st_type,
                    "io_kind": variable.io_kind,
                    "description": variable.description,
                    "mapped": binding is not None,
                    "channel": binding.channel if binding else None,
                    "module_id": module_id,
                    "point_name": binding.point_name if binding else "",
                    "unit": binding.unit if binding else "",
                    "has_quality": binding.has_quality if binding else False,
                    "scale": binding.scale if binding else 1.0,
                    "bias": binding.bias if binding else 0.0,
                    "safety_min": binding.safety_min if binding else None,
                    "safety_max": binding.safety_max if binding else None,
                    "fault_hold": binding.fault_hold if binding else "",
                    "preset_value": binding.preset_value if binding else None,
                }
            )
        return rows

    def free_channels(self, kind: Optional[str] = None) -> list[int]:
        """Channels owned by a module and not yet bound, optionally one kind."""
        bound = {b.channel for b in self._bindings.values()}
        free = []
        for module in self.modules():
            if kind is not None and module.kind != kind:
                continue
            free.extend(c for c in module.channels if c not in bound)
        return sorted(free)

    # ---------- validation ----------

    def validate(self) -> list[ValidationIssue]:
        issues: list[ValidationIssue] = []
        index = self.channel_index()

        for name, binding in sorted(self._bindings.items()):
            variable = self._variables.get(name)

            if not IDENTIFIER_RE.match(name):
                issues.append(
                    ValidationIssue(
                        code="invalid_name",
                        severity="error",
                        message=f"'{name}' is not a valid SafeST identifier",
                        var_name=name,
                        channel=binding.channel,
                    )
                )

            if variable is None:
                issues.append(
                    ValidationIssue(
                        code="unknown_var",
                        severity="error",
                        message=(
                            f"'{name}' is bound to channel {binding.channel} but is not a "
                            "configuration variable; the compiler rejects the unbound name (GATE-7)"
                        ),
                        var_name=name,
                        channel=binding.channel,
                    )
                )

            if not 0 <= binding.channel < IO_MAX_CHANNELS:
                issues.append(
                    ValidationIssue(
                        code="channel_out_of_range",
                        severity="error",
                        message=f"Channel {binding.channel} is outside 0..{IO_MAX_CHANNELS - 1}",
                        var_name=name,
                        channel=binding.channel,
                    )
                )
            elif index.get(binding.channel) is None:
                issues.append(
                    ValidationIssue(
                        code="no_hardware",
                        severity="error",
                        message=(
                            f"Channel {binding.channel} does not belong to any configured "
                            "hardware module"
                        ),
                        var_name=name,
                        channel=binding.channel,
                    )
                )

            if not math.isfinite(binding.scale) or not math.isfinite(binding.bias):
                issues.append(
                    ValidationIssue(
                        code="non_finite_cal",
                        severity="error",
                        message=f"'{name}': scale/bias must be finite, the loader rejects NaN and Inf",
                        var_name=name,
                        channel=binding.channel,
                    )
                )

            if (
                binding.safety_min is not None
                and binding.safety_max is not None
                and binding.safety_min >= binding.safety_max
            ):
                issues.append(
                    ValidationIssue(
                        code="bad_safety_limit",
                        severity="error",
                        message=(
                            f"'{name}': safety min ({binding.safety_min}) must be below "
                            f"max ({binding.safety_max})"
                        ),
                        var_name=name,
                        channel=binding.channel,
                    )
                )

        for name, binding in sorted(self._bindings.items()):
            if binding.fault_hold not in FAULT_HOLD_MODES:
                issues.append(
                    ValidationIssue(
                        code="bad_hold_mode",
                        severity="error",
                        message=(
                            f"'{name}': fault hold mode {binding.fault_hold!r} is not one of "
                            f"{FAULT_HOLD_MODES}"
                        ),
                        var_name=name,
                        channel=binding.channel,
                    )
                )
            if binding.fault_hold == "preset" and (
                binding.preset_value is None or not math.isfinite(binding.preset_value)
            ):
                issues.append(
                    ValidationIssue(
                        code="preset_missing",
                        severity="error",
                        message=(
                            f"'{name}': hold mode 'preset' needs a finite preset value, "
                            "otherwise the fallback on fault is undefined"
                        ),
                        var_name=name,
                        channel=binding.channel,
                    )
                )
            if binding.has_quality:
                issues.append(
                    ValidationIssue(
                        code="quality_not_in_artifact",
                        severity="warning",
                        message=(
                            f"'{name}': quality bit is configured but section 3 has no quality "
                            "field (spec/safeasm-spec.md 4.4 dangling item), so it is carried by "
                            "the station configuration and enforced by simulation only"
                        ),
                        var_name=name,
                        channel=binding.channel,
                    )
                )
            if binding.fault_hold:
                issues.append(
                    ValidationIssue(
                        code="hold_not_in_artifact",
                        severity="warning",
                        message=(
                            f"'{name}': fault hold '{binding.fault_hold}' is not expressible in "
                            "the .sasm IOMAP entry; the runtime keeps its own last value "
                            "(IOMapEntryRuntime.raw_value) and the preset path is enforced by "
                            "the IDE simulator, not the controller"
                        ),
                        var_name=name,
                        channel=binding.channel,
                    )
                )

        seen_channels: dict[int, str] = {}
        for name, binding in sorted(self._bindings.items()):
            owner = seen_channels.get(binding.channel)
            if owner is not None:
                issues.append(
                    ValidationIssue(
                        code="duplicate_channel",
                        severity="error",
                        message=(
                            f"Channel {binding.channel} is already bound to '{owner}'"
                        ),
                        var_name=name,
                        channel=binding.channel,
                    )
                )
            else:
                seen_channels[binding.channel] = name

            module_id = index.get(binding.channel)
            variable = self._variables.get(name)
            if module_id and variable:
                expected = derive_io_kind(variable.direction, variable.st_type)
                actual = self._modules[module_id].kind
                if actual != expected:
                    hint = ""
                    if variable.st_type.startswith("Q"):
                        hint = (
                            " -- quality types (Q*) route to the digital modules because "
                            "st_type_to_io_type only treats INT/DINT/REAL as analogue"
                        )
                    issues.append(
                        ValidationIssue(
                            code="kind_mismatch",
                            severity="error",
                            message=(
                                f"'{name}' ({variable.direction} {variable.st_type}) compiles to "
                                f"{expected}, but channel {binding.channel} is on {actual} "
                                f"module {module_id}{hint}"
                            ),
                            var_name=name,
                            channel=binding.channel,
                        )
                    )

        for name in sorted(set(self._variables) - set(self._bindings)):
            issues.append(
                ValidationIssue(
                    code="unmapped_variable",
                    severity="warning",
                    message=f"'{name}' has no hardware channel bound",
                    var_name=name,
                )
            )

        seen_points: dict[str, str] = {}
        for name, binding in sorted(self._bindings.items()):
            if not binding.point_name:
                continue
            owner = seen_points.get(binding.point_name)
            if owner is not None:
                issues.append(
                    ValidationIssue(
                        code="duplicate_point",
                        severity="error",
                        message=(
                            f"Point name {binding.point_name!r} is already used by '{owner}'"
                        ),
                        var_name=name,
                        channel=binding.channel,
                    )
                )
            else:
                seen_points[binding.point_name] = name

        return issues

    def has_errors(self) -> bool:
        return any(issue.severity == "error" for issue in self.validate())

    # ---------- ST emission ----------

    def render_st(self, extra_globals: list[tuple[str, str]] | None = None) -> str:
        """Emit the VAR_GLOBAL + IOMAP block the SafeST parser accepts.

        Entry order is sorted by variable name so two IDE runs produce
        byte-identical text, which the artifact determinism checks rely on.

        `extra_globals` appends `name : type` pairs that the compiler needs but
        the station does not own -- a chart's function-block instances, which
        only compile as globals. SafeST allows one global section, so anything
        the program declares has to be emitted here.
        """
        entries = [
            (name, self._bindings[name])
            for name in sorted(self._bindings)
            if name in self._variables
        ]
        rows = sorted(set(extra_globals or []))
        if not entries and not rows:
            return ""

        lines = ["VAR_GLOBAL"]
        lines.extend(f"    {name} : {self._variables[name].st_type};" for name, _ in entries)
        lines.extend(f"    {name} : {st_type};" for name, st_type in rows)
        lines.append("END_VAR")
        if not entries:
            return "\n".join(lines) + "\n"
        lines.append("IOMAP")
        for name, binding in entries:
            variable = self._variables[name]
            direction = "INPUT" if variable.direction == "input" else "OUTPUT"
            lines.append(f"    {name}, {binding.channel}, {direction}, {variable.st_type};")
        lines.append("END_IOMAP")
        return "\n".join(lines) + "\n"

    # ---------- persistence (iomap/*.toml) ----------

    def to_toml(self) -> str:
        """Serialize bindings as a project `iomap` TOML that passes the schema.

        Only bindings whose variable exists are written: an orphan binding has
        no direction or type to record and would not survive a reload.
        """
        blocks = ["# VeriIDE device configuration"]
        for name in sorted(set(self._bindings) & set(self._variables)):
            binding = self._bindings[name]
            variable = self._variables[name]
            rows = [
                f"[{name}]",
                f"channel = {binding.channel}",
                f"scale = {_format_number(binding.scale)}",
                f"bias = {_format_number(binding.bias)}",
                f'direction = "{variable.direction}"',
                f'st_type = "{variable.st_type}"',
            ]
            if binding.safety_min is not None and binding.safety_max is not None:
                rows.append(
                    "safety_limit = {min = %d, max = %d}" % (binding.safety_min, binding.safety_max)
                )
            if binding.point_name:
                rows.append(f'point_name = "{binding.point_name}"')
            if binding.unit:
                rows.append(f'unit = "{binding.unit}"')
            if binding.has_quality:
                rows.append("has_quality = true")
            if binding.fault_hold:
                rows.append(f'fault_hold = "{binding.fault_hold}"')
            if binding.preset_value is not None:
                rows.append(f"preset_value = {_format_number(binding.preset_value)}")
            blocks.append("\n".join(rows))
        return "\n\n".join(blocks) + "\n"

    def save_project(self, project_path: Path, filename: Optional[str] = None) -> Path:
        project_path = Path(project_path)
        iomap_dir = project_path / "iomap"
        iomap_dir.mkdir(parents=True, exist_ok=True)
        target = iomap_dir / (filename or f"{self.station.station_id}.toml")
        target.write_text(self.to_toml(), encoding="utf-8")
        return target

    def load_project(self, project_path: Path, filename: Optional[str] = None) -> None:
        """Rebind from a project `iomap` TOML, replacing variables and bindings."""
        source = Path(project_path) / "iomap" / (filename or f"{self.station.station_id}.toml")
        with open(source, "rb") as handle:
            data = tomllib.load(handle)

        variables: list[IoVariable] = []
        bindings: list[ChannelBinding] = []
        for name, entry in data.items():
            if not isinstance(entry, dict):
                continue
            direction = entry.get("direction", "input")
            st_type = entry.get("st_type", "REAL")
            limit = entry.get("safety_limit", {})
            variables.append(IoVariable(name, direction, st_type))
            bindings.append(
                ChannelBinding(
                    var_name=name,
                    channel=int(entry["channel"]),
                    scale=float(entry.get("scale", 1.0)),
                    bias=float(entry.get("bias", 0.0)),
                    safety_min=limit.get("min"),
                    safety_max=limit.get("max"),
                    point_name=entry.get("point_name", ""),
                    unit=entry.get("unit", ""),
                    has_quality=bool(entry.get("has_quality", False)),
                    fault_hold=entry.get("fault_hold", ""),
                    preset_value=(
                        None if entry.get("preset_value") is None
                        else float(entry["preset_value"])
                    ),
                )
            )

        self._variables = {v.name: v for v in variables}
        self._bindings = {b.var_name: b for b in bindings}


class DeviceProject:
    """Multi-station container: station 1..N, each with its own channel space.

    Stations are separate controllers, so each owns an independent 0..63 channel
    space, hardware inventory, variable table and bindings -- channel 3 on two
    stations is two different pieces of hardware, not a conflict.
    """

    def __init__(self, services: Optional[list[DeviceService]] = None) -> None:
        self._stations: dict[str, DeviceService] = {}
        for service in services if services is not None else [DeviceService()]:
            self._stations[service.station.station_id] = service

    def stations(self) -> list[dict]:
        rows = []
        for station_id in sorted(self._stations):
            service = self._stations[station_id]
            issues = service.validate()
            rows.append(
                {
                    **service.station.to_dict(),
                    "modules": len(service.modules()),
                    "variables": len(service.variables()),
                    "mapped": len(service.bindings()),
                    "errors": sum(1 for i in issues if i.severity == "error"),
                    "warnings": sum(1 for i in issues if i.severity == "warning"),
                }
            )
        return rows

    def station(self, station_id: str) -> DeviceService:
        try:
            return self._stations[station_id]
        except KeyError:
            raise KeyError(f"Station not found: {station_id}") from None

    def add_station(self, station: Station) -> DeviceService:
        """Create an empty station: default inventory, no points configured yet."""
        if station.station_id in self._stations:
            raise ValueError(f"Station already exists: {station.station_id}")
        service = DeviceService(station=station, variables=[], bindings=[])
        self._stations[station.station_id] = service
        return service

    def remove_station(self, station_id: str) -> None:
        if station_id not in self._stations:
            raise KeyError(f"Station not found: {station_id}")
        if len(self._stations) <= 1:
            raise ValueError("Cannot remove the last station")
        self._stations.pop(station_id)

    def update_station(self, station_id: str, station: Station) -> None:
        """Replace a station's metadata; renaming re-keys it in the project."""
        service = self.station(station_id)
        if station.station_id != station_id and station.station_id in self._stations:
            raise ValueError(f"Station already exists: {station.station_id}")
        self._stations.pop(station_id, None)
        service.set_station(station)
        self._stations[station.station_id] = service

    # ---------- persistence ----------

    def stations_toml(self) -> str:
        blocks = ["# VeriIDE station configuration"]
        for row in self.stations():
            entries = [
                f"{key} = {_toml_value(row[key])}"
                for key in (
                    "station_id",
                    "label",
                    "device_type",
                    "cycle_ms",
                    "comm_interface",
                    "comm_address",
                )
            ]
            blocks.append("[[station]]\n" + "\n".join(entries))
        return "\n\n".join(blocks) + "\n"

    def save_project(self, project_path: Path) -> dict:
        project_path = Path(project_path)
        device_dir = project_path / "device"
        device_dir.mkdir(parents=True, exist_ok=True)
        stations_file = device_dir / "stations.toml"
        stations_file.write_text(self.stations_toml(), encoding="utf-8")
        iomap_files = [
            service.save_project(project_path)
            for service in (self._stations[k] for k in sorted(self._stations))
        ]
        return {"stations": str(stations_file), "iomap": [str(p) for p in iomap_files]}

    def load_project(self, project_path: Path) -> None:
        """Rebuild the station set from `device/stations.toml` plus `iomap/*.toml`."""
        project_path = Path(project_path)
        stations_file = project_path / "device" / "stations.toml"
        services: list[DeviceService] = []

        if stations_file.is_file():
            with open(stations_file, "rb") as handle:
                data = tomllib.load(handle)
            for entry in data.get("station", []):
                service = DeviceService(
                    station=Station(
                        station_id=entry["station_id"],
                        label=entry.get("label", ""),
                        device_type=entry.get("device_type", "DCU"),
                        cycle_ms=int(entry.get("cycle_ms", 100)),
                        comm_interface=entry.get("comm_interface", "backplane"),
                        comm_address=entry.get("comm_address", ""),
                    ),
                    variables=[],
                    bindings=[],
                )
                service.load_project(project_path)
                services.append(service)
        else:
            for source in sorted((project_path / "iomap").glob("*.toml")):
                service = DeviceService(
                    station=Station(source.stem), variables=[], bindings=[]
                )
                service.load_project(project_path, filename=source.name)
                services.append(service)

        if not services:
            raise FileNotFoundError(
                f"No station configuration under {project_path}: expected "
                "device/stations.toml or iomap/*.toml"
            )
        self._stations = {s.station.station_id: s for s in services}


def _toml_value(value) -> str:
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int):
        return str(value)
    return '"' + str(value).replace("\\", "\\\\").replace('"', '\\"') + '"'


_PROJECT: Optional[DeviceProject] = None


def get_device_project() -> DeviceProject:
    global _PROJECT
    if _PROJECT is None:
        _PROJECT = DeviceProject()
    return _PROJECT
