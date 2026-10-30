"""Recently opened projects and algorithm blocks.

The list is a convenience, not a source of truth: it lives in the user's home
directory so it survives sidecar restarts, and every read re-checks the path on
disk. A project that was moved or deleted still shows up, marked missing, so the
user can see where it used to be and forget it deliberately.
"""

import json
import os
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Optional

MAX_ENTRIES = 12


def veride_home() -> Path:
    """VeriIDE's per-user state directory (HMAC keys live beside this file)."""
    return Path(os.environ.get("VERIDE_HOME", Path.home() / ".veride"))


@dataclass
class RecentProject:
    path: str
    name: str
    safety_level: str = "SIL2"
    opened_at: str = ""
    exists: bool = True
    pages: int = 0
    stations: int = 0
    blocks: int = 0

    def to_dict(self) -> dict:
        return {
            "path": self.path,
            "name": self.name,
            "safety_level": self.safety_level,
            "opened_at": self.opened_at,
            "exists": self.exists,
            "pages": self.pages,
            "stations": self.stations,
            "blocks": self.blocks,
        }


@dataclass
class RecentBlock:
    id: str
    name: str
    version: str = "1.0.0"
    category: str = "custom"
    scope: str = "user"
    project: str = ""
    touched_at: str = ""

    def to_dict(self) -> dict:
        return {
            "id": self.id,
            "name": self.name,
            "version": self.version,
            "category": self.category,
            "scope": self.scope,
            "project": self.project,
            "touched_at": self.touched_at,
        }


@dataclass
class RecentStore:
    """JSON-backed MRU lists for projects and algorithm blocks."""

    file: Path = field(default_factory=lambda: veride_home() / "recent.json")

    def _read(self) -> dict:
        if not self.file.is_file():
            return {"projects": [], "blocks": []}
        try:
            data = json.loads(self.file.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError):
            return {"projects": [], "blocks": []}
        return {
            "projects": data.get("projects", []),
            "blocks": data.get("blocks", []),
        }

    def _write(self, data: dict) -> None:
        self.file.parent.mkdir(parents=True, exist_ok=True)
        self.file.write_text(
            json.dumps(data, indent=2, ensure_ascii=False, sort_keys=True) + "\n",
            encoding="utf-8",
        )

    # ---------- projects ----------

    def touch_project(self, path: Path, name: str, safety_level: str = "SIL2") -> None:
        resolved = str(Path(path).expanduser().resolve())
        data = self._read()
        entries = [e for e in data["projects"] if e.get("path") != resolved]
        entries.insert(
            0,
            {
                "path": resolved,
                "name": name,
                "safety_level": safety_level,
                "opened_at": datetime.now().isoformat(timespec="seconds"),
            },
        )
        data["projects"] = entries[:MAX_ENTRIES]
        self._write(data)

    def forget_project(self, path: Path) -> bool:
        resolved = str(Path(path).expanduser().resolve())
        data = self._read()
        entries = [e for e in data["projects"] if e.get("path") != resolved]
        self._write({**data, "projects": entries})
        return len(entries) != len(data["projects"])

    def projects(self) -> list[RecentProject]:
        from .service import count_artifacts, is_project_dir

        rows: list[RecentProject] = []
        for entry in self._read()["projects"]:
            path = Path(entry.get("path", ""))
            row = RecentProject(
                path=str(path),
                name=entry.get("name", path.name),
                safety_level=entry.get("safety_level", "SIL2"),
                opened_at=entry.get("opened_at", ""),
            )
            if is_project_dir(path):
                counts = count_artifacts(path)
                row.pages = counts["pages"]
                row.stations = counts["stations"]
                row.blocks = counts["blocks"]
            else:
                row.exists = False
            rows.append(row)
        return rows

    # ---------- blocks ----------

    def touch_block(self, block, project: str = "") -> None:
        data = self._read()
        entries = [e for e in data["blocks"] if e.get("id") != block.id]
        entries.insert(
            0,
            {
                "id": block.id,
                "name": block.name,
                "version": block.version,
                "category": block.category.value if hasattr(block.category, "value") else str(block.category),
                "scope": block.scope,
                "project": project,
                "touched_at": datetime.now().isoformat(timespec="seconds"),
            },
        )
        data["blocks"] = entries[:MAX_ENTRIES]
        self._write(data)

    def forget_block(self, block_id: str) -> bool:
        data = self._read()
        entries = [e for e in data["blocks"] if e.get("id") != block_id]
        self._write({**data, "blocks": entries})
        return len(entries) != len(data["blocks"])

    def blocks(self, available_ids: Optional[set[str]] = None) -> list[RecentBlock]:
        """The MRU rows.

        A project-scoped block is only in the library while its own project is open,
        so availability cannot judge it -- it stays listed, and the row says which
        project it came from. A user-library block that was deleted is dropped.
        """
        rows = []
        for entry in self._read()["blocks"]:
            row = RecentBlock(
                id=entry.get("id", ""),
                name=entry.get("name", ""),
                version=entry.get("version", "1.0.0"),
                category=entry.get("category", "custom"),
                scope=entry.get("scope", "user"),
                project=entry.get("project", ""),
                touched_at=entry.get("touched_at", ""),
            )
            if (
                row.scope != "project"
                and available_ids is not None
                and row.id not in available_ids
            ):
                continue
            rows.append(row)
        return rows


_STORE: Optional[RecentStore] = None


def get_recent_store() -> RecentStore:
    global _STORE
    if _STORE is None:
        _STORE = RecentStore()
    return _STORE


def reset_recent_store() -> None:
    """Drop the cached store so a changed VERIDE_HOME takes effect (tests)."""
    global _STORE
    _STORE = None
