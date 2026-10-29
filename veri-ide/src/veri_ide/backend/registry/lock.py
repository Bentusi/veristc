"""Lock file management (lib.lock.yaml)."""

from dataclasses import dataclass
from pathlib import Path
from typing import Optional

import yaml


@dataclass
class LockEntry:
    """Lock file entry."""
    name: str
    version: str
    sha256: str
    compiler_version: Optional[str] = None


@dataclass
class LockFile:
    """Lock file (lib.lock.yaml)."""
    entries: list[LockEntry] = None

    def __post_init__(self):
        if self.entries is None:
            self.entries = []

    def add_or_update(self, entry: LockEntry):
        """Add or update entry."""
        for i, e in enumerate(self.entries):
            if e.name == entry.name:
                self.entries[i] = entry
                return
        self.entries.append(entry)

    def remove(self, name: str) -> bool:
        """Remove entry by name. Returns True if found."""
        for i, e in enumerate(self.entries):
            if e.name == name:
                self.entries.pop(i)
                return True
        return False

    def get(self, name: str) -> Optional[LockEntry]:
        """Get entry by name."""
        for e in self.entries:
            if e.name == name:
                return e
        return None

    def to_dict(self) -> dict:
        """Convert to dictionary."""
        return {
            "version": "1.0",
            "blocks": [
                {
                    "name": e.name,
                    "version": e.version,
                    "sha256": e.sha256,
                    **({"compiler_version": e.compiler_version} if e.compiler_version else {}),
                }
                for e in self.entries
            ],
        }

    @classmethod
    def from_dict(cls, data: dict) -> "LockFile":
        """Create from dictionary."""
        entries = []
        for block in data.get("blocks", []):
            entries.append(LockEntry(
                name=block["name"],
                version=block["version"],
                sha256=block["sha256"],
                compiler_version=block.get("compiler_version"),
            ))
        return cls(entries=entries)

    def save(self, path: Path):
        """Save to YAML file."""
        path.parent.mkdir(parents=True, exist_ok=True)
        with open(path, "w") as f:
            yaml.dump(self.to_dict(), f, default_flow_style=False, allow_unicode=True)

    @classmethod
    def load(cls, path: Path) -> "LockFile":
        """Load from YAML file."""
        if not path.exists():
            return cls()
        with open(path) as f:
            data = yaml.safe_load(f)
        return cls.from_dict(data or {})
