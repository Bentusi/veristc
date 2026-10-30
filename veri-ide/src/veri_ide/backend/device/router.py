"""
Device configuration API routes, scoped by station.

Endpoints:
- station inventory (device type, cycle time, communication settings)
- hardware inventory (modules and channels) per station
- configuration I/O variable table per station
- channel bindings and point attributes (unit, quality, limits, fault hold)
- the external variable table the graphics stage consumes
- validation and `IOMAP` ST generation
- the derived `.plant` object table the simulator runs against
- persistence to `device/stations.toml` and `iomap/<station>.toml`
"""

from pathlib import Path
from typing import Optional

from fastapi import APIRouter, HTTPException, Query
from fastapi.responses import PlainTextResponse
from pydantic import BaseModel

from .models import ChannelBinding, HardwareModule, IoVariable, Station
from .service import get_device_project
from ..sim.plant import PlantValidationError, plant_from_external_variables


router = APIRouter(prefix="/device", tags=["device"])


class StationRequest(BaseModel):
    station_id: str
    label: str = ""
    device_type: str = "DCU"
    cycle_ms: int = 100
    comm_interface: str = "backplane"
    comm_address: str = ""


class ModuleRequest(BaseModel):
    module_id: str
    kind: str
    first_channel: int
    channel_count: int
    label: str = ""


class VariableRequest(BaseModel):
    name: str
    direction: str
    st_type: str
    description: str = ""


class ReplaceVariablesRequest(BaseModel):
    variables: list[VariableRequest]


class BindingRequest(BaseModel):
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


class ProjectRequest(BaseModel):
    project_path: str


def _service(station_id: str):
    try:
        return get_device_project().station(station_id)
    except KeyError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from None


# ---------- stations ----------


@router.get("/stations")
def list_stations() -> list[dict]:
    return get_device_project().stations()


@router.post("/stations", response_model=StationRequest)
def add_station(request: StationRequest) -> dict:
    try:
        get_device_project().add_station(Station(**request.model_dump()))
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))
    return request.model_dump()


@router.put("/stations/{station_id}", response_model=StationRequest)
def update_station(station_id: str, request: StationRequest) -> dict:
    try:
        get_device_project().update_station(station_id, Station(**request.model_dump()))
    except KeyError as exc:
        raise HTTPException(status_code=404, detail=str(exc))
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))
    return request.model_dump()


@router.delete("/stations/{station_id}")
def remove_station(station_id: str) -> dict:
    try:
        get_device_project().remove_station(station_id)
    except KeyError as exc:
        raise HTTPException(status_code=404, detail=str(exc))
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))
    return {"removed": station_id}


# ---------- hardware inventory ----------


@router.get("/stations/{station_id}/hardware")
def get_hardware(station_id: str) -> dict:
    """Hardware modules with each channel annotated by its binding."""
    return {"modules": _service(station_id).hardware_view()}


@router.post("/stations/{station_id}/modules", response_model=ModuleRequest)
def add_module(station_id: str, request: ModuleRequest) -> dict:
    try:
        _service(station_id).add_module(HardwareModule(**request.model_dump()))
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))
    return request.model_dump()


@router.delete("/stations/{station_id}/modules/{module_id}")
def remove_module(station_id: str, module_id: str) -> dict:
    try:
        _service(station_id).remove_module(module_id)
    except KeyError as exc:
        raise HTTPException(status_code=404, detail=str(exc))
    return {"removed": module_id}


# ---------- configuration variables ----------


@router.get("/stations/{station_id}/variables")
def list_variables(station_id: str) -> list[dict]:
    return [variable.to_dict() for variable in _service(station_id).variables()]


@router.put("/stations/{station_id}/variables")
def replace_variables(station_id: str, request: ReplaceVariablesRequest) -> list[dict]:
    """Sync the configuration I/O surface from the graph editor."""
    service = _service(station_id)
    try:
        service.set_variables(
            [IoVariable(v.name, v.direction, v.st_type, v.description) for v in request.variables]
        )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))
    return [variable.to_dict() for variable in service.variables()]


# ---------- bindings and point configuration ----------


@router.get("/stations/{station_id}/mappings")
def list_mappings(station_id: str) -> list[dict]:
    return _service(station_id).mapping_rows()


@router.get("/stations/{station_id}/external-variables")
def list_external_variables(station_id: str) -> list[dict]:
    """The external variable table stage 2 associates algorithm pins with."""
    return _service(station_id).external_variables()


@router.get("/stations/{station_id}/free-channels")
def free_channels(station_id: str, kind: Optional[str] = Query(default=None)) -> dict:
    return {"channels": _service(station_id).free_channels(kind)}


@router.put("/stations/{station_id}/mapping")
def bind(station_id: str, request: BindingRequest) -> dict:
    try:
        _service(station_id).bind(ChannelBinding(**request.model_dump()))
    except KeyError as exc:
        raise HTTPException(status_code=404, detail=str(exc))
    return {"bound": request.var_name, "channel": request.channel}


@router.delete("/stations/{station_id}/mapping/{var_name}")
def unbind(station_id: str, var_name: str) -> dict:
    try:
        _service(station_id).unbind(var_name)
    except KeyError as exc:
        raise HTTPException(status_code=404, detail=str(exc))
    return {"unbound": var_name}


# ---------- validation and emission ----------


@router.post("/stations/{station_id}/validate")
def validate(station_id: str) -> dict:
    issues = [issue.to_dict() for issue in _service(station_id).validate()]
    return {
        "ok": not any(i["severity"] == "error" for i in issues),
        "errors": [i for i in issues if i["severity"] == "error"],
        "warnings": [i for i in issues if i["severity"] == "warning"],
    }


@router.get("/stations/{station_id}/iomap.st", response_class=PlainTextResponse)
def iomap_st(station_id: str) -> str:
    """The VAR_GLOBAL + IOMAP block for injection into the generated ST."""
    return _service(station_id).render_st()


@router.get("/stations/{station_id}/plant", response_class=PlainTextResponse)
def plant_text(station_id: str) -> str:
    """
    The `.plant` object table this station simulates against.

    Derived, not hand-kept: direction, amplitude limits and the fault preset are
    already stated by the point configuration, which is exactly what a channel
    row of `spec/simulation-spec.md` section 1 asks for. Keeping a second copy in
    the editor would let the two disagree -- and the disagreement would show up
    as a simulation nobody believes.
    """
    try:
        model = plant_from_external_variables(
            station_id, _service(station_id).external_variables()
        )
    except PlantValidationError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from None
    return model.to_plant_text()


# ---------- persistence ----------


@router.post("/save")
def save(request: ProjectRequest) -> dict:
    try:
        return get_device_project().save_project(Path(request.project_path))
    except OSError as exc:
        raise HTTPException(status_code=400, detail=str(exc))


@router.post("/load")
def load(request: ProjectRequest) -> list[dict]:
    project = Path(request.project_path)
    if not project.is_dir():
        raise HTTPException(status_code=404, detail=f"Project directory not found: {project}")
    try:
        get_device_project().load_project(project)
    except (OSError, ValueError, KeyError, TypeError) as exc:
        raise HTTPException(status_code=400, detail=str(exc))
    return get_device_project().stations()
