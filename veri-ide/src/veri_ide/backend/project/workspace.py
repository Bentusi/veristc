"""The project the sidecar is working on.

Every stage page edits a process-wide model (stations, graph pages, blocks) that
is loaded from and saved to one project directory. This module is the single
place that directory is remembered, so opening a project loads all three domains
at once and saving writes all three back -- the per-page hand-typed project path
is gone.

A freshly created project is seeded with one empty station and one empty page,
which means the folder always holds text artifacts a Git diff can show.
"""

from dataclasses import dataclass
from pathlib import Path
from typing import Optional

from ..device.models import Station
from ..device.service import DeviceProject, DeviceService, get_device_project
from ..graph.service import GraphProject, get_graph_project
from ..library.service import get_library_service
from .recent import get_recent_store
from .service import ProjectMeta, is_project_dir, open_project, project_tree


@dataclass
class WorkspaceState:
    meta: ProjectMeta
    seeded: bool = False

    def descriptor(self) -> dict:
        return {
            "name": self.meta.name,
            "path": str(self.meta.path),
            "safety_level": self.meta.safety_level,
            "svm_version": self.meta.svm_version,
            "description": self.meta.description or "",
            "tree": project_tree(self.meta.path),
        }


_CURRENT: Optional[WorkspaceState] = None


def current_workspace() -> Optional[WorkspaceState]:
    return _CURRENT


def current_path() -> Optional[Path]:
    return _CURRENT.meta.path if _CURRENT else None


def open_workspace(path: Path, seed: bool = True) -> WorkspaceState:
    """Validate `path` as a project and load device, graph and block data into it."""
    global _CURRENT
    path = Path(path).expanduser().resolve()
    if not path.is_dir():
        raise FileNotFoundError(f"工程目录不存在：{path}")
    if not is_project_dir(path):
        raise FileNotFoundError(f"不是 VeriIDE 工程：{path} 下没有 project.yaml")

    meta = open_project(path)
    state = WorkspaceState(meta=meta)

    device = get_device_project()
    graph = get_graph_project()

    if seed and not _has_device_data(path) and not _has_graph_data(path):
        _seed(state, device, graph)

    if _has_device_data(path):
        device.load_project(path)
    else:
        device.reset([])

    if _has_graph_data(path):
        graph.load_project(path)
    else:
        graph.reset(name=meta.name.upper().replace("-", "_"))
        graph.add_page(label="页 1")

    get_library_service().set_project_dir(path)

    _CURRENT = state
    get_recent_store().touch_project(path, meta.name, meta.safety_level)
    return state


def save_workspace() -> dict:
    """Write every domain model back to the current project directory."""
    state = _require()
    path = state.meta.path
    written = {
        "device": get_device_project().save_project(path),
        "graph": get_graph_project().save_project(path),
        "blocks": get_library_service().save_project_blocks(path),
    }
    get_recent_store().touch_project(path, state.meta.name, state.meta.safety_level)
    return written


def close_workspace() -> bool:
    global _CURRENT
    if _CURRENT is None:
        return False
    _CURRENT = None
    get_library_service().set_project_dir(None)
    return True


def resolve_project_path(explicit: Optional[str] = None) -> Path:
    """The directory a save/load acts on: the caller's, or the open project's."""
    if explicit:
        return Path(explicit).expanduser()
    return _require().meta.path


def _require() -> WorkspaceState:
    if _CURRENT is None:
        raise RuntimeError("尚未打开工程：先在首页新建或打开一个工程文件夹")
    return _CURRENT


def _has_device_data(path: Path) -> bool:
    return (path / "device" / "stations.toml").is_file() or any(
        (path / "iomap").glob("*.toml")
    )


def _has_graph_data(path: Path) -> bool:
    return any((path / "logic").glob("*.FC.json"))


def _seed(state: WorkspaceState, device: DeviceProject, graph: GraphProject) -> None:
    """Lay down the starting artifacts of a new project."""
    station = DeviceService(
        station=Station("ST1", "主控站"), variables=[], bindings=[]
    )
    device.reset([station])
    device.save_project(state.meta.path)

    graph.reset(name=state.meta.name.upper().replace("-", "_"))
    graph.add_page(label="页 1")
    graph.save_project(state.meta.path)
