"""
Compose the one text the compiler is handed for a chart.

Three stages -- device configuration, algorithm library and graphic chart --
each own part of the program, and SafeST only accepts them in one shape:

* a single ``VAR_GLOBAL`` section, holding the station's configuration variables,
  the chart's function-block instances and its intermediate page variables;
* the library bodies of the blocks the chart instantiates, so a type resolves;
* the chart's ``PROGRAM`` body.

Analysis, simulation and download all consume this same text: a number measured
on one shape and deployed in another would mean nothing.
"""

import re
from typing import Optional

from ..device.service import DeviceService, get_device_project
from ..library.service import get_library_service
from .service import GraphProject


def compile_unit(device: DeviceService, project: GraphProject) -> str:
    """The compilable unit for `project` as prepared for `device`'s station."""
    globals_ = project.global_declarations()
    parts = (
        device.render_st(globals_),
        library_st({block_type for _, block_type in globals_}),
        project.generate_st(instances_global=True),
    )
    return "\n".join(part for part in parts if part.strip())


def library_st(type_names: set[str]) -> str:
    """
    Definitions of the blocks a chart instantiates, in library order.

    The chart generates calls only; the block bodies live in the algorithm
    library and the compiler needs them in the same text to resolve a type.
    A function block's ``block_kind`` distinguishes FB from FUN, but the
    template already carries the right POU keyword, so it is emitted verbatim.
    """
    if not type_names:
        return ""
    templates: list[str] = []
    for block in get_library_service().list_blocks():
        entry = block.to_dict()
        if st_type_of(entry) not in type_names:
            continue
        template = entry.get("st_template", "").strip()
        if template:
            templates.append(template)
    return "\n\n".join(templates) + "\n" if templates else ""


def st_type_of(block: dict) -> str:
    """The type name a library entry is written as in ST, from its template."""
    for keyword in ("FUNCTION_BLOCK", "FUNCTION"):
        match = re.search(
            r"\b%s\s+([A-Za-z_][A-Za-z0-9_]*)" % keyword, block.get("st_template", "")
        )
        if match:
            return match.group(1)
    return block["name"]


def station_of(request_station: Optional[str]) -> DeviceService:
    """Resolve the station a chart is prepared for; the first one when unnamed."""
    project = get_device_project()
    station_id = request_station or sorted(project.stations())[0]["station_id"]
    return project.station(station_id)


def _pins(entries: list[dict]) -> list[dict]:
    return [
        {"name": p["name"], "type": p["data_type"], "default_value": p.get("default_value")}
        for p in entries
    ]


def block_defs() -> dict[str, dict]:
    """
    Library port tables in the shape the checker and the simulator read.

    Keyed three ways -- by library id, by ST type name and by display name --
    because a chart records whichever of those the palette put there.
    """
    defs: dict[str, dict] = {}
    for block in get_library_service().list_blocks():
        entry = block.to_dict()
        normalized = {
            "id": entry["id"],
            "name": entry["name"],
            "type": st_type_of(entry),
            "block_kind": entry.get("block_kind", "FB"),
            "time_based": entry.get("time_based", False),
            "inputs": _pins(entry["inputs"]),
            "outputs": _pins(entry["outputs"]),
            "in_out": [],
            "parameters": entry["parameters"],
        }
        for key in (normalized["id"], normalized["type"], normalized["name"]):
            defs.setdefault(key, normalized)
    return defs
