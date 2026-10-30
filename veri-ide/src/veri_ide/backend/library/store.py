"""Algorithm blocks as text files.

A block is two files that belong to Git: `<Type>.block.yaml` (ports, parameters,
metadata) and `<Type>.st` (the implementation the compiler is finally handed).
Splitting them keeps the ST body readable in a diff instead of escaped inside a
JSON string, and it means a block can be edited, reviewed or copied without the
IDE running.

The same store backs two scopes: the per-user global library under
`~/.veride/library/`, which is what the palette always has, and the `blocks/`
directory of an open project, which shadows a global block of the same type name.
"""

import re
from pathlib import Path
from typing import Optional

import yaml

from .models import AlgorithmBlock, BlockCategory, BlockParameter, BlockPort, PortDirection

MANIFEST_SUFFIX = ".block.yaml"
SOURCE_SUFFIX = ".st"


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
        "inputs": [p.to_dict() for p in block.inputs],
        "outputs": [p.to_dict() for p in block.outputs],
        "parameters": [p.to_dict() for p in block.parameters],
        "icon_svg": block.icon_svg,
        "tags": list(block.tags),
        "sha256": block.sha256,
    }


def _from_manifest(data: dict, st_template: str) -> AlgorithmBlock:
    return AlgorithmBlock(
        id=data.get("id") or safe_stem(data.get("name", "")),
        name=data.get("name", ""),
        category=BlockCategory(data.get("category", "custom")),
        version=data.get("version", "1.0.0"),
        description=data.get("description", ""),
        author=data.get("author", ""),
        block_kind=data.get("block_kind", "FB"),
        time_based=bool(data.get("time_based", False)),
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
    """The per-user block library, beside the HMAC keys."""
    from ..project.recent import veride_home

    return veride_home() / "library"


def project_blocks_dir(project_path: Optional[Path]) -> Optional[Path]:
    return None if project_path is None else Path(project_path) / "blocks"
