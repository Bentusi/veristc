"""
算法块与算法库管理服务

多库架构：
- 每个算法库是 ``~/.veride/libraries/<id>/`` 目录，含 ``library.yaml`` + ``blocks/``
- 内置库 ``builtin/`` 只读，出厂块（PID/RS/FBY/LIMITER）
- 默认用户库 ``user-default/`` 从旧扁平布局自动迁移
- 工程 ``blocks/`` 仍按 ST 类型名遮蔽全局块
"""

import hashlib
import json
import re
import shutil
import uuid
from datetime import datetime
from pathlib import Path
from typing import Optional

from ..project.recent import get_recent_store
from .models import (
    AlgorithmBlock,
    BlockCategory,
    BlockParameter,
    BlockPort,
    ClassificationFilter,
    ImportResult,
    LibraryInfo,
    PortDirection,
    SignalType,
)
from .store import (
    BlockStore,
    LibraryStore,
    global_libraries_dir,
    global_library_dir,
    project_blocks_dir,
    st_type_name,
)

BUILTIN_LIB_ID = "builtin"
DEFAULT_USER_LIB_ID = "user-default"


class LibraryService:
    """算法库服务：多库磁盘布局 + 内存索引"""

    def __init__(self, libraries_root: Optional[Path] = None):
        self._root = Path(libraries_root or global_libraries_dir())
        self._library_stores: dict[str, LibraryStore] = {}
        self._project_store: Optional[BlockStore] = None
        self._blocks: dict[str, AlgorithmBlock] = {}
        self._libraries: dict[str, LibraryInfo] = {}

        self._migrate_if_needed()
        self._ensure_builtin()
        self._ensure_user_default()
        self._load_all_libraries()
        self.set_project_dir(None)

    # ------------------------------------------------------------------
    # Initialization helpers
    # ------------------------------------------------------------------

    def _migrate_if_needed(self):
        legacy = global_library_dir()
        if legacy.is_dir() and not self._root.is_dir():
            self._root.mkdir(parents=True, exist_ok=True)
            LibraryStore.migrate_legacy(legacy, self._root / DEFAULT_USER_LIB_ID)

    def _ensure_builtin(self):
        builtin_dir = self._root / BUILTIN_LIB_ID
        store = LibraryStore(builtin_dir)
        if not store.manifest_path.is_file():
            builtin_dir.mkdir(parents=True, exist_ok=True)
            info = LibraryInfo(
                id=BUILTIN_LIB_ID,
                name="Built-in Blocks",
                description="Factory-standard algorithm blocks (PID, RS, FBY, LIMITER)",
                owner="VeriSTC Team",
                version="1.0.0",
                is_shared=True,
            )
            store.save_manifest(info)
            for factory in (
                self._create_pid_block,
                self._create_rs_block,
                self._create_fby_block,
                self._create_limiter_block,
            ):
                block = factory()
                block.library_id = BUILTIN_LIB_ID
                block.scope = "builtin"
                block.sha256 = self._compute_sha256(block)
                store.save_block(block)
        self._library_stores[BUILTIN_LIB_ID] = store

    def _ensure_user_default(self):
        user_dir = self._root / DEFAULT_USER_LIB_ID
        store = LibraryStore(user_dir)
        if not store.manifest_path.is_file():
            user_dir.mkdir(parents=True, exist_ok=True)
            info = LibraryInfo(
                id=DEFAULT_USER_LIB_ID,
                name="User Library",
                description="Default user algorithm block library",
                version="1.0.0",
            )
            store.save_manifest(info)
        self._library_stores[DEFAULT_USER_LIB_ID] = store

    def _load_all_libraries(self):
        self._blocks.clear()
        self._libraries.clear()
        if not self._root.is_dir():
            return
        for lib_dir in sorted(self._root.iterdir()):
            if not lib_dir.is_dir():
                continue
            store = LibraryStore(lib_dir)
            info = store.load_manifest()
            if info is None:
                continue
            self._library_stores[info.id] = store
            self._libraries[info.id] = info
            for block in store.load_blocks():
                block.scope = "builtin" if info.id == BUILTIN_LIB_ID else "user"
                block.library_id = info.id
                self._blocks[block.id] = block
        self._recompute_library_counts()

    def _recompute_library_counts(self):
        counts: dict[str, int] = {}
        for b in self._blocks.values():
            counts[b.library_id] = counts.get(b.library_id, 0) + 1
        for lib_id, info in self._libraries.items():
            info.blocks_count = counts.get(lib_id, 0)
            info.validation = self._library_stores[lib_id]._compute_validation()

    # ------------------------------------------------------------------
    # Store resolution
    # ------------------------------------------------------------------

    def _stores(self) -> list[tuple[BlockStore, str]]:
        scopes: list[tuple[BlockStore, str]] = []
        for lib_id, store in self._library_stores.items():
            scope = "builtin" if lib_id == BUILTIN_LIB_ID else "user"
            scopes.append((store._block_store, scope))
        if self._project_store is not None:
            scopes.append((self._project_store, "project"))
        return scopes

    def _store_for(self, block: AlgorithmBlock) -> BlockStore:
        if block.scope == "project":
            if self._project_store is None:
                raise ValueError("没有打开的工程，无法写入工程作用域的算法块")
            return self._project_store
        lib_store = self._library_stores.get(block.library_id)
        if lib_store:
            return lib_store._block_store
        return self._library_stores[DEFAULT_USER_LIB_ID]._block_store

    def _library_store_for(self, block: AlgorithmBlock) -> LibraryStore:
        lib_store = self._library_stores.get(block.library_id)
        if lib_store:
            return lib_store
        return self._library_stores[DEFAULT_USER_LIB_ID]

    def _project_label(self, block: AlgorithmBlock) -> str:
        if block.scope != "project" or self._project_store is None:
            return ""
        return self._project_store.directory.parent.name

    # ------------------------------------------------------------------
    # Project scope
    # ------------------------------------------------------------------

    def set_project_dir(self, project_path: Optional[Path]) -> None:
        directory = project_blocks_dir(project_path)
        self._project_store = BlockStore(directory) if directory else None
        self._reload_project_blocks()

    def _reload_project_blocks(self):
        """Rebuild the block index: library blocks + project blocks shadowing by type name."""
        merged: dict[str, AlgorithmBlock] = {}
        by_type: dict[str, str] = {}
        for lib_id, store in self._library_stores.items():
            for block in store.load_blocks():
                block.scope = "builtin" if lib_id == BUILTIN_LIB_ID else "user"
                block.library_id = lib_id
                shadowed = by_type.get(st_type_name(block))
                if shadowed is not None:
                    merged.pop(shadowed, None)
                merged[block.id] = block
                by_type[st_type_name(block)] = block.id
        if self._project_store is not None:
            for block in self._project_store.load():
                block.scope = "project"
                block.library_id = ""
                shadowed = by_type.get(st_type_name(block))
                if shadowed is not None:
                    merged.pop(shadowed, None)
                merged[block.id] = block
                by_type[st_type_name(block)] = block.id
        self._blocks = merged
        self._recompute_library_counts()

    def save_project_blocks(self, project_path: Path) -> list[str]:
        store = self._project_store or BlockStore(project_blocks_dir(project_path))
        written = [
            str(store.save(block))
            for block in self._blocks.values()
            if block.scope == "project"
        ]
        self._project_store = store
        self._reload_project_blocks()
        return written

    # ------------------------------------------------------------------
    # SHA-256
    # ------------------------------------------------------------------

    def _compute_sha256(self, block: AlgorithmBlock) -> str:
        content = json.dumps({
            "name": block.name,
            "inputs": [p.to_dict() for p in block.inputs],
            "outputs": [p.to_dict() for p in block.outputs],
            "parameters": [p.to_dict() for p in block.parameters],
            "st_template": block.st_template,
        }, sort_keys=True)
        return hashlib.sha256(content.encode()).hexdigest()

    # ==================================================================
    # Block CRUD
    # ==================================================================

    def get_block(self, block_id: str) -> Optional[AlgorithmBlock]:
        return self._blocks.get(block_id)

    def list_blocks(
        self,
        category: Optional[BlockCategory] = None,
        search_text: Optional[str] = None,
        tag: Optional[str] = None,
        classification: Optional[ClassificationFilter] = None,
    ) -> list[AlgorithmBlock]:
        result = list(self._blocks.values())

        if classification:
            if classification.library_id is not None:
                result = [b for b in result if b.library_id == classification.library_id]
            if classification.time_based is not None:
                result = [b for b in result if b.time_based == classification.time_based]
            if classification.signal_type is not None:
                result = [b for b in result if b.signal_type == classification.signal_type]
            if classification.categories is not None:
                cats = set(classification.categories)
                result = [b for b in result if b.category in cats]

        if category:
            result = [b for b in result if b.category == category]
        if search_text:
            text_lower = search_text.lower()
            result = [
                b for b in result
                if text_lower in b.name.lower() or text_lower in b.description.lower()
            ]
        if tag:
            result = [b for b in result if tag in b.tags]

        return result

    def add_block(self, block: AlgorithmBlock, library_id: Optional[str] = None) -> AlgorithmBlock:
        block.sha256 = self._compute_sha256(block)

        for existing in self._blocks.values():
            if existing.sha256 == block.sha256:
                return existing

        if not block.id:
            block.id = f"{block.name}_{uuid.uuid4().hex[:8]}"

        if library_id is None and self._project_store is not None:
            block.scope = "project"
            block.library_id = ""
            self._project_store.save(block)
            self._reload_project_blocks()
        else:
            target_lib = library_id or DEFAULT_USER_LIB_ID
            block.library_id = target_lib
            block.scope = "user"
            lib_store = self._library_stores.get(target_lib)
            if lib_store is None:
                lib_store = self._library_stores[DEFAULT_USER_LIB_ID]
                block.library_id = DEFAULT_USER_LIB_ID
            lib_store.save_block(block)
            lib_info = self._libraries.get(block.library_id)
            if lib_info:
                lib_info.updated_at = datetime.now()
                lib_store.save_manifest(lib_info)
            self._load_all_libraries()

        get_recent_store().touch_block(block, self._project_label(block))
        return self._blocks.get(block.id, block)

    def update_block(self, block_id: str, **kwargs) -> Optional[AlgorithmBlock]:
        block = self._blocks.get(block_id)
        if not block:
            return None

        for key, value in kwargs.items():
            if hasattr(block, key):
                setattr(block, key, value)

        block.updated_at = datetime.now()
        block.sha256 = self._compute_sha256(block)

        store = self._store_for(block)
        store.delete(block)
        store.save(block)

        lib_store = self._library_store_for(block)
        info = lib_store.load_manifest()
        if info:
            info.updated_at = datetime.now()
            lib_store.save_manifest(info)
            self._libraries[info.id] = info

        if block.scope == "project":
            self._reload_project_blocks()
        else:
            self._load_all_libraries()

        get_recent_store().touch_block(block, self._project_label(block))
        return self._blocks.get(block_id, block)

    def delete_block(self, block_id: str) -> bool:
        block = self._blocks.get(block_id)
        if not block:
            return False
        if block.scope == "builtin":
            return False
        self._store_for(block).delete(block)
        if block.scope == "project":
            self._reload_project_blocks()
        else:
            self._load_all_libraries()
        get_recent_store().forget_block(block_id)
        return True

    # ==================================================================
    # Import / Export (JSON, backward compatible)
    # ==================================================================

    def import_block(self, block_data: dict, library_id: Optional[str] = None) -> ImportResult:
        try:
            sig = block_data.get("signal_type", "mixed")
            try:
                signal_type = SignalType(sig)
            except ValueError:
                signal_type = SignalType.MIXED

            block = AlgorithmBlock(
                id=block_data.get("id", ""),
                name=block_data["name"],
                category=BlockCategory(block_data.get("category", "custom")),
                version=block_data.get("version", "1.0.0"),
                description=block_data.get("description", ""),
                author=block_data.get("author", ""),
                block_kind=block_data.get("block_kind", "FB"),
                time_based=bool(block_data.get("time_based", False)),
                signal_type=signal_type,
                inputs=[BlockPort(**p) for p in block_data.get("inputs", [])],
                outputs=[BlockPort(**p) for p in block_data.get("outputs", [])],
                parameters=[BlockParameter(**p) for p in block_data.get("parameters", [])],
                st_template=block_data.get("st_template", ""),
                icon_svg=block_data.get("icon_svg", ""),
                tags=block_data.get("tags", []),
            )
            block.sha256 = self._compute_sha256(block)

            for existing in self._blocks.values():
                if existing.sha256 == block.sha256:
                    return ImportResult(
                        success=True, block_id=existing.id,
                        message=f"算法块已存在: {existing.name}", is_duplicate=True,
                    )

            imported = self.add_block(block, library_id=library_id)
            return ImportResult(success=True, block_id=imported.id, message=f"成功导入: {imported.name}")
        except Exception as e:
            return ImportResult(success=False, message=f"导入失败: {str(e)}")

    def export_block(self, block_id: str) -> Optional[dict]:
        block = self._blocks.get(block_id)
        return block.to_dict() if block else None

    def export_library(self, library_id: Optional[str] = None) -> dict:
        if library_id:
            blocks = [b for b in self._blocks.values() if b.library_id == library_id]
        else:
            blocks = list(self._blocks.values())
        return {
            "version": "2.0.0",
            "exported_at": datetime.now().isoformat(),
            "blocks": [block.to_dict() for block in blocks],
        }

    def import_library(self, library_data: dict, library_id: Optional[str] = None) -> list[ImportResult]:
        results = []
        for block_data in library_data.get("blocks", []):
            results.append(self.import_block(block_data, library_id=library_id))
        return results

    # ==================================================================
    # Library CRUD
    # ==================================================================

    def create_library(
        self, name: str, description: str = "", owner: str = "",
        version: str = "1.0.0", library_id: Optional[str] = None,
    ) -> LibraryInfo:
        lib_id = library_id or re.sub(r"[^A-Za-z0-9_.-]", "_", name).strip("._-") or str(uuid.uuid4())[:8]
        lib_dir = self._root / lib_id
        if lib_dir.exists():
            raise ValueError(f"Library directory already exists: {lib_dir}")
        lib_dir.mkdir(parents=True, exist_ok=True)
        (lib_dir / "blocks").mkdir(exist_ok=True)
        info = LibraryInfo(
            id=lib_id, name=name, description=description,
            owner=owner, version=version,
        )
        store = LibraryStore(lib_dir)
        store.save_manifest(info)
        self._library_stores[lib_id] = store
        self._libraries[lib_id] = info
        return info

    def get_library(self, library_id: str) -> Optional[LibraryInfo]:
        return self._libraries.get(library_id)

    def list_libraries(self, include_shared: bool = True) -> list[LibraryInfo]:
        libs = list(self._libraries.values())
        if not include_shared:
            libs = [lib for lib in libs if not lib.is_shared]
        return libs

    def update_library(self, library_id: str, **kwargs) -> Optional[LibraryInfo]:
        info = self._libraries.get(library_id)
        if not info:
            return None
        for key, value in kwargs.items():
            if hasattr(info, key):
                setattr(info, key, value)
        info.updated_at = datetime.now()
        store = self._library_stores.get(library_id)
        if store:
            store.save_manifest(info)
        return info

    def share_library(self, library_id: str, shared: bool = True) -> bool:
        return self.update_library(library_id, is_shared=shared) is not None

    def delete_library(self, library_id: str) -> bool:
        if library_id == BUILTIN_LIB_ID:
            return False
        lib_dir = self._root / library_id
        if not lib_dir.is_dir():
            return False
        shutil.rmtree(lib_dir)
        self._library_stores.pop(library_id, None)
        self._libraries.pop(library_id, None)
        self._blocks = {
            bid: b for bid, b in self._blocks.items() if b.library_id != library_id
        }
        return True

    def clear_library(self, library_id: str) -> int:
        store = self._library_stores.get(library_id)
        if not store:
            return 0
        removed = store.clear_blocks()
        info = self._libraries.get(library_id)
        if info:
            info.blocks_count = 0
            info.updated_at = datetime.now()
            store.save_manifest(info)
        self._blocks = {
            bid: b for bid, b in self._blocks.items() if b.library_id != library_id
        }
        return removed

    def validate_library(self, library_id: str) -> tuple[bool, list[str]]:
        store = self._library_stores.get(library_id)
        if not store:
            return False, [f"Library {library_id} not found"]
        return store.validate()

    # ==================================================================
    # ZIP import / export
    # ==================================================================

    def export_library_zip(self, library_id: str, output_path: Path) -> Path:
        store = self._library_stores.get(library_id)
        if not store:
            raise ValueError(f"Library {library_id} not found")
        return store.export_zip(output_path)

    def import_library_zip(self, zip_path: Path, library_id: Optional[str] = None) -> LibraryInfo:
        zip_path = Path(zip_path)
        temp_store = LibraryStore(zip_path.parent / f"_import_{uuid.uuid4().hex[:8]}")
        temp_store = LibraryStore.import_zip(
            zip_path,
            temp_store.directory,
        )
        info = temp_store.load_manifest()
        if info is None:
            shutil.rmtree(temp_store.directory, ignore_errors=True)
            raise ValueError("Invalid library ZIP: missing manifest")
        target_id = library_id or info.id
        target_dir = self._root / target_id
        if target_dir.exists():
            shutil.rmtree(target_dir)
        shutil.move(str(temp_store.directory), str(target_dir))
        store = LibraryStore(target_dir)
        info.id = target_id
        info.directory = str(target_dir)
        store.save_manifest(info)
        self._library_stores[target_id] = store
        self._libraries[target_id] = info
        for block in store.load_blocks():
            block.library_id = target_id
            block.scope = "user"
            self._blocks[block.id] = block
        self._recompute_library_counts()
        return info

    # ==================================================================
    # Builtin block factories
    # ==================================================================

    def _create_pid_block(self) -> AlgorithmBlock:
        return AlgorithmBlock(
            id="PID_v1",
            name="PID控制器",
            category=BlockCategory.CONTROL,
            version="1.0.0",
            description="比例-积分-微分控制器，用于闭环控制",
            author="VeriSTC Team",
            signal_type=SignalType.ANALOG,
            time_based=True,
            inputs=[
                BlockPort(name="SP", direction=PortDirection.INPUT, data_type="REAL", description="设定值"),
                BlockPort(name="PV", direction=PortDirection.INPUT, data_type="REAL", description="过程值"),
            ],
            outputs=[
                BlockPort(name="OUT", direction=PortDirection.OUTPUT, data_type="REAL", description="输出值"),
            ],
            parameters=[
                BlockParameter(name="Kp", data_type="REAL", default_value=1.0, description="比例增益"),
                BlockParameter(name="Ti", data_type="REAL", default_value=100.0, description="积分时间"),
                BlockParameter(name="Td", data_type="REAL", default_value=10.0, description="微分时间"),
            ],
            st_template="""FUNCTION_BLOCK PID
VAR_INPUT
    SP : REAL; (* 设定值 *)
    PV : REAL; (* 过程值 *)
END_VAR
VAR_OUTPUT
    OUT : REAL; (* 输出值 *)
END_VAR
VAR
    Kp : REAL := 1.0; (* 比例增益 *)
    Ti : REAL := 100.0; (* 积分时间 *)
    Td : REAL := 10.0; (* 微分时间 *)
    error : REAL;
    integral : REAL;
    derivative : REAL;
    last_error : REAL;
END_VAR

error := SP - PV;
integral := integral + error;
derivative := error - last_error;
OUT := Kp * (error + (1.0/Ti) * integral + Td * derivative);
last_error := error;
END_FUNCTION_BLOCK""",
            tags=["control", "pid", "closed-loop"],
        )

    def _create_rs_block(self) -> AlgorithmBlock:
        return AlgorithmBlock(
            id="RS_v1",
            name="RS触发器",
            category=BlockCategory.LOGIC,
            version="1.0.0",
            description="置位-复位触发器，优先复位",
            author="VeriSTC Team",
            signal_type=SignalType.DIGITAL,
            inputs=[
                BlockPort(name="S", direction=PortDirection.INPUT, data_type="BOOL", description="置位输入"),
                BlockPort(name="R", direction=PortDirection.INPUT, data_type="BOOL", description="复位输入"),
            ],
            outputs=[
                BlockPort(name="Q", direction=PortDirection.OUTPUT, data_type="BOOL", description="输出"),
            ],
            parameters=[],
            st_template="""FUNCTION_BLOCK RS
VAR_INPUT
    S : BOOL; (* 置位 *)
    R : BOOL; (* 复位 *)
END_VAR
VAR_OUTPUT
    Q : BOOL; (* 输出 *)
END_VAR

IF R THEN
    Q := FALSE;
ELSIF S THEN
    Q := TRUE;
END_IF;
END_FUNCTION_BLOCK""",
            tags=["logic", "flip-flop", "memory"],
        )

    def _create_fby_block(self) -> AlgorithmBlock:
        return AlgorithmBlock(
            id="FBY_v1",
            name="FBY延迟单元",
            category=BlockCategory.FILTER,
            version="1.0.0",
            description="一阶滞后滤波，用于信号平滑",
            author="VeriSTC Team",
            signal_type=SignalType.ANALOG,
            time_based=True,
            inputs=[
                BlockPort(name="IN", direction=PortDirection.INPUT, data_type="REAL", description="输入值"),
            ],
            outputs=[
                BlockPort(name="OUT", direction=PortDirection.OUTPUT, data_type="REAL", description="滤波后输出"),
            ],
            parameters=[
                BlockParameter(name="T", data_type="REAL", default_value=1.0, description="时间常数"),
                BlockParameter(name="Ts", data_type="REAL", default_value=0.1, description="采样周期"),
            ],
            st_template="""FUNCTION_BLOCK FBY
VAR_INPUT
    IN : REAL; (* 输入 *)
END_VAR
VAR_OUTPUT
    OUT : REAL; (* 输出 *)
END_VAR
VAR
    T : REAL := 1.0; (* 时间常数 *)
    Ts : REAL := 0.1; (* 采样周期 *)
    alpha : REAL;
END_VAR

alpha := Ts / (T + Ts);
OUT := alpha * IN + (1.0 - alpha) * OUT;
END_FUNCTION_BLOCK""",
            tags=["filter", "lag", "smoothing"],
        )

    def _create_limiter_block(self) -> AlgorithmBlock:
        return AlgorithmBlock(
            id="LIMITER_v1",
            name="限幅器",
            category=BlockCategory.MATH,
            version="1.0.0",
            description="限制信号在上下限范围内",
            author="VeriSTC Team",
            signal_type=SignalType.ANALOG,
            inputs=[
                BlockPort(name="IN", direction=PortDirection.INPUT, data_type="REAL", description="输入值"),
            ],
            outputs=[
                BlockPort(name="OUT", direction=PortDirection.OUTPUT, data_type="REAL", description="限幅后输出"),
            ],
            parameters=[
                BlockParameter(name="MIN", data_type="REAL", default_value=0.0, min_value=0.0, description="下限"),
                BlockParameter(name="MAX", data_type="REAL", default_value=100.0, min_value=0.0, description="上限"),
            ],
            st_template="""FUNCTION_BLOCK LIMITER
VAR_INPUT
    IN : REAL; (* 输入 *)
END_VAR
VAR_OUTPUT
    OUT : REAL; (* 输出 *)
END_VAR
VAR
    MIN : REAL := 0.0; (* 下限 *)
    MAX : REAL := 100.0; (* 上限 *)
END_VAR

IF IN < MIN THEN
    OUT := MIN;
ELSIF IN > MAX THEN
    OUT := MAX;
ELSE
    OUT := IN;
END_IF;
END_FUNCTION_BLOCK""",
            tags=["math", "limit", "clamp"],
        )


# ------------------------------------------------------------------
# Singleton
# ------------------------------------------------------------------

_service: Optional[LibraryService] = None


def get_library_service() -> LibraryService:
    global _service
    if _service is None:
        _service = LibraryService()
    return _service
