"""Algorithm blocks as text files.

A block is two files that belong to Git: `<Type>.block.yaml` (ports, parameters,
metadata) and `<Type>.st` (the implementation the compiler is finally handed).
Splitting them keeps the ST body readable in a diff instead of escaped inside a
JSON string, and it means a block can be edited, reviewed or copied without the
IDE running.

Libraries are directories containing a `library.yaml` manifest and a `blocks/`
subdirectory of block file pairs.  Multiple libraries live side by side under
`~/.veride/libraries/`.
"""

import hashlib
import re
import shutil
import zipfile
from datetime import datetime
from pathlib import Path
from typing import Optional

import yaml

from .models import (
    AlgorithmBlock, BlockCategory, BlockParameter, BlockPort,
    LibraryInfo, PortDirection, SignalType,
)

MANIFEST_SUFFIX = ".block.yaml"
SOURCE_SUFFIX = ".st"
LIBRARY_MANIFEST = "library.yaml"
BLOCKS_DIR = "blocks"


def st_type_name(block: AlgorithmBlock) -> str:
    """The POU name the block's ST declares -- its identity in generated code."""
    for keyword in ("FUNCTION_BLOCK", "FUNCTION"):
        match = re.search(r"\b%s\s+([A-Za-z_][A-Za-z0-9_]*)" % keyword, block.st_template or "")
        if match:
            return match.group(1)
    return safe_stem(block.id or block.name)


def safe_stem(value: str) -> str:
    """A filesystem-safe stem for an id or name that is not an identifier."""
    cleaned = re.sub(r"[^A-Za-z0-9_.-]", "_", value).strip("._-")
    return cleaned or "BLOCK"


def _manifest(block: AlgorithmBlock) -> dict:
    return {
        "id": block.id,
        "name": block.name,
        "category": block.category.value,
        "version": block.version,
        "description": block.description,
        "author": block.author,
        "block_kind": block.block_kind,
        "time_based": block.time_based,
        "signal_type": block.signal_type.value,
        "library_id": block.library_id,
        "inputs": [p.to_dict() for p in block.inputs],
        "outputs": [p.to_dict() for p in block.outputs],
        "parameters": [p.to_dict() for p in block.parameters],
        "icon_svg": block.icon_svg,
        "tags": list(block.tags),
        "sha256": block.sha256,
    }


def _from_manifest(data: dict, st_template: str) -> AlgorithmBlock:
    sig = data.get("signal_type", "mixed")
    try:
        signal_type = SignalType(sig)
    except ValueError:
        signal_type = SignalType.MIXED
    return AlgorithmBlock(
        id=data.get("id") or safe_stem(data.get("name", "")),
        name=data.get("name", ""),
        category=BlockCategory(data.get("category", "custom")),
        version=data.get("version", "1.0.0"),
        description=data.get("description", ""),
        author=data.get("author", ""),
        block_kind=data.get("block_kind", "FB"),
        time_based=bool(data.get("time_based", False)),
        signal_type=signal_type,
        library_id=data.get("library_id", ""),
        inputs=[
            BlockPort(
                name=p["name"],
                direction=PortDirection(p.get("direction", "input")),
                data_type=p.get("data_type", "REAL"),
                description=p.get("description", ""),
                default_value=p.get("default_value"),
            )
            for p in data.get("inputs", [])
        ],
        outputs=[
            BlockPort(
                name=p["name"],
                direction=PortDirection(p.get("direction", "output")),
                data_type=p.get("data_type", "REAL"),
                description=p.get("description", ""),
                default_value=p.get("default_value"),
            )
            for p in data.get("outputs", [])
        ],
        parameters=[
            BlockParameter(
                name=p["name"],
                data_type=p.get("data_type", "REAL"),
                default_value=p.get("default_value"),
                min_value=p.get("min_value"),
                max_value=p.get("max_value"),
                description=p.get("description", ""),
            )
            for p in data.get("parameters", [])
        ],
        st_template=st_template,
        icon_svg=data.get("icon_svg", ""),
        tags=list(data.get("tags", [])),
        sha256=data.get("sha256", ""),
    )


class BlockStore:
    """Read and write `<Type>.block.yaml` + `<Type>.st` in one directory."""

    def __init__(self, directory: Path) -> None:
        self.directory = Path(directory)

    def load(self) -> list[AlgorithmBlock]:
        blocks: list[AlgorithmBlock] = []
        if not self.directory.is_dir():
            return blocks
        for manifest_path in sorted(self.directory.glob(f"*{MANIFEST_SUFFIX}")):
            data = yaml.safe_load(manifest_path.read_text(encoding="utf-8")) or {}
            source = manifest_path.with_name(
                manifest_path.name[: -len(MANIFEST_SUFFIX)] + SOURCE_SUFFIX
            )
            # Trailing newlines are the file's, not the template's: dropping them
            # here is what makes save -> load -> save byte-identical.
            template = source.read_text(encoding="utf-8").rstrip("\n") if source.is_file() else ""
            block = _from_manifest(data, template)
            block.path = str(manifest_path)
            blocks.append(block)
        return blocks

    def save(self, block: AlgorithmBlock) -> Path:
        self.directory.mkdir(parents=True, exist_ok=True)
        stem = self.stem_for(block)
        manifest_path = self.directory / f"{stem}{MANIFEST_SUFFIX}"
        source_path = self.directory / f"{stem}{SOURCE_SUFFIX}"
        manifest_path.write_text(
            yaml.dump(_manifest(block), allow_unicode=True, sort_keys=True, default_flow_style=False),
            encoding="utf-8",
        )
        if block.st_template:
            source_path.write_text(block.st_template.rstrip("\n") + "\n", encoding="utf-8")
        block.path = str(manifest_path)
        return manifest_path

    def delete(self, block: AlgorithmBlock) -> bool:
        """Remove the pair a block was loaded or saved from."""
        if not block.path:
            return False
        manifest_path = Path(block.path)
        source_path = manifest_path.with_name(
            manifest_path.name[: -len(MANIFEST_SUFFIX)] + SOURCE_SUFFIX
        )
        removed = False
        for candidate in (manifest_path, source_path):
            if candidate.is_file():
                candidate.unlink()
                removed = True
        return removed

    def stem_for(self, block: AlgorithmBlock) -> str:
        """Prefer the declared POU name; fall back to the id when it is taken."""
        stem = st_type_name(block)
        existing = self.directory / f"{stem}{MANIFEST_SUFFIX}"
        if existing.is_file():
            data = yaml.safe_load(existing.read_text(encoding="utf-8")) or {}
            if data.get("id") != block.id:
                return safe_stem(block.id)
        return stem


def global_library_dir() -> Path:
    """Legacy flat layout -- used only for migration."""
    from ..project.recent import veride_home

    return veride_home() / "library"


def global_libraries_dir() -> Path:
    """The per-user multi-library root: ``~/.veride/libraries/``."""
    from ..project.recent import veride_home

    return veride_home() / "libraries"


def project_blocks_dir(project_path: Optional[Path]) -> Optional[Path]:
    return None if project_path is None else Path(project_path) / "blocks"


# ---------------------------------------------------------------------------
# LibraryStore -- manages one library directory on disk
# ---------------------------------------------------------------------------

def _library_manifest_dict(info: LibraryInfo) -> dict:
    return {
        "id": info.id,
        "name": info.name,
        "description": info.description,
        "owner": info.owner,
        "version": info.version,
        "is_shared": info.is_shared,
        "schema_version": info.schema_version,
        "classification_dims": info.classification_dims,
        "created_at": info.created_at.isoformat(),
        "updated_at": info.updated_at.isoformat(),
    }


def _library_info_from_dict(data: dict, directory: str = "") -> LibraryInfo:
    created = data.get("created_at", "")
    updated = data.get("updated_at", "")
    return LibraryInfo(
        id=data.get("id", ""),
        name=data.get("name", ""),
        description=data.get("description", ""),
        owner=data.get("owner", ""),
        version=data.get("version", "1.0.0"),
        is_shared=bool(data.get("is_shared", False)),
        schema_version=data.get("schema_version", "2.0"),
        classification_dims=dict(data.get("classification_dims", {})),
        created_at=datetime.fromisoformat(created) if created else datetime.now(),
        updated_at=datetime.fromisoformat(updated) if updated else datetime.now(),
        directory=directory,
    )


class LibraryStore:
    """Manage a single library directory: ``library.yaml`` + ``blocks/``."""

    def __init__(self, directory: Path) -> None:
        self.directory = Path(directory)
        self.blocks_dir = self.directory / BLOCKS_DIR
        self.manifest_path = self.directory / LIBRARY_MANIFEST
        self._block_store = BlockStore(self.blocks_dir)

    # -- manifest -----------------------------------------------------------

    def load_manifest(self) -> Optional[LibraryInfo]:
        if not self.manifest_path.is_file():
            return None
        data = yaml.safe_load(self.manifest_path.read_text(encoding="utf-8")) or {}
        info = _library_info_from_dict(data, str(self.directory))
        info.blocks_count = len(self._block_store.load())
        info.validation = self._compute_validation()
        return info

    def save_manifest(self, info: LibraryInfo) -> None:
        self.directory.mkdir(parents=True, exist_ok=True)
        info.directory = str(self.directory)
        info.updated_at = datetime.now()
        self.manifest_path.write_text(
            yaml.dump(
                _library_manifest_dict(info),
                allow_unicode=True, sort_keys=True, default_flow_style=False,
            ),
            encoding="utf-8",
        )

    # -- block operations (delegate to BlockStore) --------------------------

    def load_blocks(self) -> list[AlgorithmBlock]:
        blocks = self._block_store.load()
        info = self.load_manifest()
        lib_id = info.id if info else self.directory.name
        for b in blocks:
            b.library_id = lib_id
        return blocks

    def save_block(self, block: AlgorithmBlock) -> Path:
        return self._block_store.save(block)

    def delete_block(self, block: AlgorithmBlock) -> bool:
        return self._block_store.delete(block)

    def clear_blocks(self) -> int:
        removed = 0
        for block in self._block_store.load():
            if self._block_store.delete(block):
                removed += 1
        return removed

    # -- validation ---------------------------------------------------------

    def _compute_validation(self) -> dict:
        blocks = self._block_store.load()
        h = hashlib.sha256()
        for b in sorted(blocks, key=lambda x: x.id):
            h.update(b.id.encode())
            h.update(b.sha256.encode())
        return {
            "block_count": len(blocks),
            "integrity_hash": f"sha256:{h.hexdigest()}",
        }

    def validate(self) -> tuple[bool, list[str]]:
        errors: list[str] = []
        if not self.manifest_path.is_file():
            errors.append("library.yaml missing")
        if not self.blocks_dir.is_dir():
            errors.append("blocks/ directory missing")
        info = self.load_manifest()
        if info is None:
            errors.append("library.yaml is not valid YAML")
            return False, errors
        blocks = self._block_store.load()
        if info.blocks_count and info.blocks_count != len(blocks):
            errors.append(
                f"manifest says {info.blocks_count} blocks but found {len(blocks)}"
            )
        for b in blocks:
            if not b.st_template and not b.inputs and not b.outputs:
                errors.append(f"block {b.id} appears empty")
        return len(errors) == 0, errors

    # -- zip import / export ------------------------------------------------

    def export_zip(self, zip_path: Path) -> Path:
        zip_path = Path(zip_path)
        with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zf:
            if self.manifest_path.is_file():
                zf.write(self.manifest_path, LIBRARY_MANIFEST)
            for f in sorted(self.blocks_dir.glob(f"*{MANIFEST_SUFFIX}")):
                zf.write(f, f"{BLOCKS_DIR}/{f.name}")
            for f in sorted(self.blocks_dir.glob(f"*{SOURCE_SUFFIX}")):
                zf.write(f, f"{BLOCKS_DIR}/{f.name}")
        return zip_path

    @classmethod
    def import_zip(cls, zip_path: Path, target_dir: Path) -> "LibraryStore":
        zip_path = Path(zip_path)
        target_dir = Path(target_dir)
        if target_dir.exists():
            shutil.rmtree(target_dir)
        target_dir.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(zip_path, "r") as zf:
            zf.extractall(target_dir)
        store = cls(target_dir)
        if not store.manifest_path.is_file():
            raise ValueError("ZIP does not contain library.yaml")
        return store

    # -- migration ----------------------------------------------------------

    @classmethod
    def migrate_legacy(cls, legacy_dir: Path, new_dir: Path) -> Optional["LibraryStore"]:
        """Move a flat ``~/.veride/library/`` into ``~/.veride/libraries/user-default/``."""
        legacy_dir = Path(legacy_dir)
        if not legacy_dir.is_dir():
            return None
        new_dir = Path(new_dir)
        if new_dir.exists() and any(new_dir.iterdir()):
            return None  # target already has content, don't overwrite
        new_dir.mkdir(parents=True, exist_ok=True)
        blocks_target = new_dir / BLOCKS_DIR
        blocks_target.mkdir(exist_ok=True)
        for f in legacy_dir.iterdir():
            if f.suffix in (".yaml", ".st", ".yml"):
                shutil.copy2(f, blocks_target / f.name)
        info = LibraryInfo(
            id="user-default",
            name="User Library",
            description="Migrated from legacy flat layout",
            version="1.0.0",
        )
        store = cls(new_dir)
        store.save_manifest(info)
        for b in store.load_blocks():
            b.library_id = "user-default"
            store.save_block(b)
        return store
