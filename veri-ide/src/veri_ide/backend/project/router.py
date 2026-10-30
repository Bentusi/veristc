"""
工程生命周期 API：新建、打开、保存、关闭 + 最近列表。

启动页是这些端点唯一的消费者：它把工程建在磁盘上（一个文件夹，全部文本文件），
打开时把设备/图页/算法块三个域一次性读进 sidecar，之后各阶段页面写的都是同一个
目录 —— 页面上不再有手输工程目录的地方。
"""

from pathlib import Path
from typing import Optional

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel

from .recent import get_recent_store
from .service import create_project, default_parent_dir, project_tree
from .workspace import close_workspace, current_workspace, open_workspace, save_workspace
from ..library.service import get_library_service


router = APIRouter(prefix="/project", tags=["project"])


class CreateProjectRequest(BaseModel):
    name: str
    parent_dir: Optional[str] = None
    safety_level: str = "SIL2"
    svm_version: str = "1.0.0"


class ProjectPathRequest(BaseModel):
    path: str


class ProjectResponse(BaseModel):
    name: str
    path: str
    safety_level: str
    svm_version: str = "1.0.0"
    description: str = ""
    tree: dict = {}


class LauncherState(BaseModel):
    current: Optional[ProjectResponse] = None
    recent_projects: list[dict] = []
    recent_blocks: list[dict] = []
    default_parent_dir: str = ""


def _response(path: Path) -> ProjectResponse:
    from .service import open_project

    meta = open_project(path)
    return ProjectResponse(
        name=meta.name,
        path=str(meta.path),
        safety_level=meta.safety_level,
        svm_version=meta.svm_version,
        description=meta.description or "",
        tree=project_tree(meta.path),
    )


@router.get("/state", response_model=LauncherState)
def launcher_state() -> LauncherState:
    """Everything the startup page shows: current project, histories, default location."""
    store = get_recent_store()
    available = {block.id for block in get_library_service().list_blocks()}
    state = current_workspace()
    return LauncherState(
        current=ProjectResponse(**state.descriptor()) if state else None,
        recent_projects=[row.to_dict() for row in store.projects()],
        recent_blocks=[row.to_dict() for row in store.blocks(available)],
        default_parent_dir=str(default_parent_dir()),
    )


@router.post("/create", response_model=ProjectResponse, status_code=201)
def create(request: CreateProjectRequest) -> ProjectResponse:
    """Create the project folder and open it."""
    parent = Path(request.parent_dir).expanduser() if request.parent_dir else default_parent_dir()
    target = parent / request.name
    try:
        meta = create_project(
            name=request.name,
            target_path=target,
            safety_level=request.safety_level,
            svm_version=request.svm_version,
        )
    except FileExistsError as exc:
        raise HTTPException(status_code=409, detail=f"工程名已被占用：{target} 已存在且不是空目录") from exc
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=f"工程参数不合法：{exc}") from exc

    open_workspace(meta.path)
    return _response(meta.path)


@router.post("/open", response_model=ProjectResponse)
def open_project_endpoint(request: ProjectPathRequest) -> ProjectResponse:
    """Load an existing project folder as the current one."""
    path = Path(request.path).expanduser()
    try:
        open_workspace(path)
    except FileNotFoundError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=f"project.yaml 不合法: {exc}") from exc
    return _response(path)


@router.post("/save", response_model=ProjectResponse)
def save() -> ProjectResponse:
    """Write stations, pages and project blocks to the current project folder."""
    try:
        save_workspace()
    except RuntimeError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    return _response(current_workspace().meta.path)


@router.get("/current", response_model=Optional[ProjectResponse])
def current() -> Optional[ProjectResponse]:
    state = current_workspace()
    return ProjectResponse(**state.descriptor()) if state else None


@router.post("/close")
def close() -> dict:
    return {"closed": close_workspace()}


@router.post("/forget")
def forget(request: ProjectPathRequest) -> dict:
    """Drop a project from the recent list; the folder on disk is untouched."""
    return {"forgotten": get_recent_store().forget_project(Path(request.path))}
