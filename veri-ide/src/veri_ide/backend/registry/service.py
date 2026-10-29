"""Registry service for algorithm block management."""

import shutil
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

from .manifest import BlockManifest, ImplementationDef, compute_source_hash
from .lock import LockFile, LockEntry


@dataclass
class RegistryBlock:
    """Registered block."""
    manifest: BlockManifest
    storage_path: Path  # Content-addressed storage path


@dataclass
class RegistryError(Exception):
    """Registry error."""
    message: str


class RegistryService:
    """Registry service for algorithm blocks."""

    def __init__(self, registry_dir: Path, project_dir: Optional[Path] = None):
        """Initialize registry service.

        Args:
            registry_dir: Registry storage directory
            project_dir: Project directory (for lock file)
        """
        self.registry_dir = registry_dir
        self.blocks_dir = registry_dir / "blocks"
        self.manifests_dir = registry_dir / "manifests"
        self.project_dir = project_dir

        # Create directories
        self.blocks_dir.mkdir(parents=True, exist_ok=True)
        self.manifests_dir.mkdir(parents=True, exist_ok=True)

    def _get_content_path(self, sha256: str) -> Path:
        """Get content-addressed storage path."""
        return self.blocks_dir / sha256[:2] / sha256[2:]

    def _get_manifest_path(self, name: str, version: str) -> Path:
        """Get manifest file path."""
        return self.manifests_dir / f"{name}@{version}.json"

    def register_block(
        self,
        manifest: BlockManifest,
        source_path: Path,
    ) -> RegistryBlock:
        """Register a block.

        Args:
            manifest: Block manifest
            source_path: Path to implementation source file

        Returns:
            Registered block

        Raises:
            RegistryError: If block already exists or source not found
        """
        if not source_path.exists():
            raise RegistryError(f"Source file not found: {source_path}")

        # Compute source hash
        source_hash = compute_source_hash(source_path)
        manifest.implementation = ImplementationDef(
            source_hash=source_hash,
            source_path=str(source_path.name),
        )

        # Check if already registered
        manifest_path = self._get_manifest_path(manifest.name, manifest.version)
        if manifest_path.exists():
            raise RegistryError(
                f"Block {manifest.name}@{manifest.version} already registered"
            )

        # Store source file (content-addressed)
        content_path = self._get_content_path(source_hash)
        content_path.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source_path, content_path)

        # Save manifest
        manifest_path.parent.mkdir(parents=True, exist_ok=True)
        manifest_path.write_text(manifest.to_json(), encoding="utf-8")

        # Update lock file if project_dir is set
        if self.project_dir:
            lock_path = self.project_dir / "lib.lock.yaml"
            lock = LockFile.load(lock_path)
            lock.add_or_update(LockEntry(
                name=manifest.name,
                version=manifest.version,
                sha256=source_hash,
            ))
            lock.save(lock_path)

        return RegistryBlock(manifest=manifest, storage_path=content_path)

    def get_block(self, name: str, version: str) -> Optional[RegistryBlock]:
        """Get block by name and version."""
        manifest_path = self._get_manifest_path(name, version)
        if not manifest_path.exists():
            return None

        manifest = BlockManifest.from_json(manifest_path.read_text(encoding="utf-8"))
        if not manifest.implementation:
            return None

        content_path = self._get_content_path(manifest.implementation.source_hash)
        if not content_path.exists():
            return None

        return RegistryBlock(manifest=manifest, storage_path=content_path)

    def list_blocks(self, name_filter: Optional[str] = None) -> list[RegistryBlock]:
        """List registered blocks.

        Args:
            name_filter: Optional name filter (supports * wildcard)

        Returns:
            List of registered blocks
        """
        blocks = []
        for manifest_path in self.manifests_dir.glob("*.json"):
            try:
                manifest = BlockManifest.from_json(manifest_path.read_text(encoding="utf-8"))
                if name_filter and name_filter not in manifest.name:
                    continue
                if manifest.implementation:
                    content_path = self._get_content_path(manifest.implementation.source_hash)
                    if content_path.exists():
                        blocks.append(RegistryBlock(manifest=manifest, storage_path=content_path))
            except Exception:
                continue
        return blocks

    def unregister_block(self, name: str, version: str) -> bool:
        """Unregister a block.

        Returns:
            True if block was found and removed
        """
        manifest_path = self._get_manifest_path(name, version)
        if not manifest_path.exists():
            return False

        # Read manifest to get source hash
        manifest = BlockManifest.from_json(manifest_path.read_text(encoding="utf-8"))

        # Remove manifest
        manifest_path.unlink()

        # Remove content if no other block references it
        if manifest.implementation:
            content_path = self._get_content_path(manifest.implementation.source_hash)
            # Check if any other manifest references this content
            referenced = False
            for other_path in self.manifests_dir.glob("*.json"):
                if other_path == manifest_path:
                    continue
                try:
                    other = BlockManifest.from_json(other_path.read_text(encoding="utf-8"))
                    if other.implementation and other.implementation.source_hash == manifest.implementation.source_hash:
                        referenced = True
                        break
                except Exception:
                    continue
            if not referenced and content_path.exists():
                content_path.unlink()
                # Remove parent directory if empty
                if content_path.parent.exists() and not any(content_path.parent.iterdir()):
                    content_path.parent.rmdir()

        # Update lock file
        if self.project_dir:
            lock_path = self.project_dir / "lib.lock.yaml"
            lock = LockFile.load(lock_path)
            lock.remove(name)
            lock.save(lock_path)

        return True

    def search_blocks(self, query: str, tags: Optional[list[str]] = None) -> list[RegistryBlock]:
        """Search blocks by name/description/tags.

        Args:
            query: Search query (matches name, description, tags)
            tags: Optional tag filter

        Returns:
            Matching blocks
        """
        results = []
        query_lower = query.lower()
        for block in self.list_blocks():
            m = block.manifest
            # Match query
            if query_lower in m.name.lower() or query_lower in m.description.lower():
                pass
            elif any(query_lower in tag.lower() for tag in m.tags):
                pass
            else:
                continue

            # Match tags
            if tags:
                if not any(tag in m.tags for tag in tags):
                    continue

            results.append(block)
        return results
