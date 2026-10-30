"""
Simulation API: run the chart against the station's own object table.

`POST /sim/run` is the closed loop for one station: the checker's verdict first,
then the composed text is compiled, the `.plant` table is derived from the point
configuration, and `sim --watch` answers with the frames.

Stimulus comes with the request: `forces` holds values over the whole run and
`script` sets them per cycle, both in the shapes `spec/simulation-spec.md`
section 5 defines. Neither is applied here -- they are handed to the runner, and
the `forced` key of each frame says which displayed value came from outside.

The chart is never asked what its values are -- a value only ever comes from a
frame, keyed by the symbol name the compiler exported for it.
"""

from typing import Any, Optional

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, Field

from ..device.service import DeviceService
from ..graph.compose import block_defs, compile_unit, station_of
from ..graph.service import GraphProject, get_graph_project
from .plant import PlantValidationError, plant_from_external_variables
from .session import SimError, run_simulation


router = APIRouter(prefix="/sim", tags=["sim"])

#: `veri-runtime/sim/sim_main.c` refuses a scan count above this.
CYCLES_MAX = 100000


class ForceItem(BaseModel):
    """One immediate override: the symbol it pins and the value to pin it at."""

    name: str
    value: Any


class ScriptRecord(BaseModel):
    """One test-script record: the cycle it lands on and what to set there."""

    cycle: int
    name: str
    value: Any


class RunRequest(BaseModel):
    station: Optional[str] = None
    cycles: int = 20
    cycle_ms: Optional[int] = None
    forces: list[ForceItem] = Field(default_factory=list)
    script: list[ScriptRecord] = Field(default_factory=list)


def run_names(project: GraphProject, device: DeviceService, defs: dict[str, dict]) -> list[str]:
    """
    Every symbol a run has to report for this chart.

    The block outputs the pins read, the page variables that carry a value from
    one block to another, and the station variables the IOMAP fills each cycle.
    Sorted and de-duplicated: the table is cut into runs of 16, and the cut has
    to fall the same way wherever the same chart is simulated.
    """
    names = set(project.watch_symbols(defs))
    names.update(row["name"] for row in device.external_variables() if row["mapped"])
    return sorted(names)


@router.post("/run")
def run(request: RunRequest) -> dict:
    """Simulate the current chart for one station and return the watch timelines."""
    if request.cycles < 1 or request.cycles > CYCLES_MAX:
        raise HTTPException(status_code=400, detail=f"cycles must be in 1..{CYCLES_MAX}")

    project = get_graph_project()
    device = station_of(request.station)
    defs = block_defs()

    report = project.report(block_defs=defs, external_vars=_external(device))
    if not report["ok"]:
        return {
            "ok": False,
            "stage": "checker",
            "errors": report["errors"],
            "warnings": report["warnings"],
        }

    try:
        plant = plant_from_external_variables(
            device.station.station_id, device.external_variables()
        )
    except PlantValidationError as exc:
        return {"ok": False, "stage": "plant", "errors": [str(exc)]}

    try:
        result = run_simulation(
            compile_unit(device, project),
            plant.to_plant_text(),
            run_names(project, device, defs),
            cycles=request.cycles,
            cycle_ms=request.cycle_ms or device.station.cycle_ms,
            forces=[row.model_dump() for row in request.forces],
            script=[row.model_dump() for row in request.script],
        )
    except SimError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from None

    payload = result.payload
    payload["plant"] = {"name": plant.name, "text": plant.to_plant_text()}
    payload["station"] = device.station.to_dict()
    #: Which symbol each pin reads: the editor draws the frame value of the slot
    #: the generated statement writes, never a name it worked out itself.
    payload["pins"] = project.pin_symbols(defs)
    return payload


def _external(device: DeviceService) -> dict[str, dict]:
    return {row["name"]: row for row in device.external_variables()}
