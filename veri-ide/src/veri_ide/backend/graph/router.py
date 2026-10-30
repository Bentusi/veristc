"""
Graphical logic configuration API, scoped by page.

Endpoints:
- page inventory and the page documents themselves (add / read / write / delete / reorder)
- the merged view of every page, which is what the checker and the ST text use
- `check`: the inspector -- loops, pin type mismatch, unassociated variables,
  multi-driver pins, unknown blocks and ports, station binding consistency. Its
  findings locate a page, a block and a pin so the editor can jump there
- cross-page variable index, which is what the page tabs jump through
- `IOMAP`-side association: the checker reads the station external variable table
  produced by the device stage
- `analysis`: the compiler hand-off -- WCET against the station cycle budget,
  memory and variable footprint, hot-standby sync-region size. It refuses while
  the checker still reports an error, so an ill-formed chart never reaches
  simulation
- ST text for the whole chart, and persistence into the project directory
"""

from pathlib import Path
from typing import Any, Optional

from fastapi import APIRouter, HTTPException
from fastapi.responses import PlainTextResponse
from pydantic import BaseModel

from ..build.analysis import AnalysisError, run_analysis
from .compose import block_defs, compile_unit, station_of
from .service import GraphError, get_graph_project


router = APIRouter(prefix="/graph", tags=["graph"])


class PageCreateRequest(BaseModel):
    label: str = ""
    page_id: Optional[str] = None
    sheet: str = "A3"


class PageMoveRequest(BaseModel):
    index: int


class RenameRequest(BaseModel):
    name: str


class ProjectRequest(BaseModel):
    project_path: str


class CheckRequest(BaseModel):
    station: Optional[str] = None



def _external_vars(station: Optional[str]) -> dict[str, dict]:
    """One station's external variable table, keyed by variable name."""
    return {row["name"]: row for row in station_of(station).external_variables()}


@router.get("/pages")
def list_pages() -> list[dict]:
    return get_graph_project().pages()


@router.post("/pages")
def add_page(request: PageCreateRequest) -> dict:
    try:
        page = get_graph_project().add_page(
            label=request.label, page_id=request.page_id, sheet=request.sheet
        )
    except GraphError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from None
    return page


@router.get("/pages/{page_id}")
def get_page(page_id: str) -> dict:
    try:
        return get_graph_project().get_page(page_id)
    except KeyError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from None


@router.put("/pages/{page_id}")
def put_page(page_id: str, page: dict[str, Any]) -> dict:
    """Store one page document; the schema decides whether it is acceptable."""
    meta = dict(page.get("page") or {})
    meta["id"] = page_id
    try:
        return get_graph_project().put_page({**page, "page": meta})
    except GraphError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from None


@router.delete("/pages/{page_id}")
def delete_page(page_id: str) -> dict:
    try:
        get_graph_project().delete_page(page_id)
    except KeyError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from None
    except GraphError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from None
    return {"removed": page_id}


@router.post("/pages/{page_id}/move")
def move_page(page_id: str, request: PageMoveRequest) -> list[dict]:
    try:
        get_graph_project().move_page(page_id, request.index)
    except KeyError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from None
    return get_graph_project().pages()


@router.put("")
def rename(request: RenameRequest) -> dict:
    """Rename the program every page draws."""
    if not request.name.replace("_", "").isalnum() or not request.name.isupper():
        raise HTTPException(status_code=400, detail="Program name must be uppercase identifier")
    get_graph_project().set_name(request.name)
    return {"name": get_graph_project().name}


@router.get("/merged")
def merged() -> dict:
    try:
        return get_graph_project().merged_fc()
    except GraphError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from None


@router.post("/check")
def check(request: CheckRequest) -> dict:
    """Run the inspector over the merged graph of every page."""
    project = get_graph_project()
    try:
        external = _external_vars(request.station)
    except KeyError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from None
    report = project.report(block_defs=block_defs(), external_vars=external)
    if request.station:
        report["station"] = request.station
    return report


@router.post("/analysis")
def analysis(request: CheckRequest) -> dict:
    """Ask the compiler what the chart costs, once the checker has nothing left to say.

    The text handed over is one `VAR_GLOBAL + IOMAP` section (the station's
    configuration variables plus the chart's block instances, which the compiler
    only accepts as globals), then the library bodies of the blocks used, then the
    chart's `PROGRAM`. That is what a hand-written SafeST program looks like, and
    the compiler stays the only reader of it.
    """
    project = get_graph_project()
    try:
        device = station_of(request.station)
    except KeyError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from None

    report = project.report(
        block_defs=block_defs(),
        external_vars={row["name"]: row for row in device.external_variables()},
    )
    if not report["ok"]:
        return {
            "ok": False,
            "stage": "checker",
            "errors": report["errors"],
            "warnings": report["warnings"],
        }

    text = compile_unit(device, project)
    try:
        station = device.station.to_dict()
        result = run_analysis(text, station=station)
    except AnalysisError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from None
    payload = result.payload
    payload["station"] = station
    return payload


@router.get("/cross-page")
def cross_page() -> list[dict]:
    """Variables that join two or more pages."""
    return get_graph_project().cross_page_index()


@router.get("/st", response_class=PlainTextResponse)
def st_text() -> str:
    try:
        return get_graph_project().generate_st()
    except (GraphError, ValueError) as exc:
        # A chart with a loop has no execution order, so there is no text to emit.
        raise HTTPException(status_code=400, detail=str(exc)) from None


@router.post("/save")
def save(request: ProjectRequest) -> dict:
    try:
        written = get_graph_project().save_project(Path(request.project_path))
    except OSError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from None
    return {"graph": written}


@router.post("/load")
def load(request: ProjectRequest) -> list[dict]:
    project = Path(request.project_path)
    if not project.is_dir():
        raise HTTPException(status_code=404, detail=f"Project directory not found: {project}")
    try:
        get_graph_project().load_project(project)
    except (OSError, ValueError, KeyError, TypeError) as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from None
    return get_graph_project().pages()
