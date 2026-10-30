"""
算法块与算法库管理服务

提供功能：
- 算法块 CRUD
- 算法库管理（分类/版本）
- 内容寻址存储（SHA-256）
- 导入/导出（JSON）
- 共享库支持
"""

import hashlib
import json
import uuid
from datetime import datetime
from typing import Optional

from .models import (
    AlgorithmBlock,
    BlockCategory,
    BlockParameter,
    BlockPort,
    ImportResult,
    LibraryInfo,
    PortDirection,
)


class LibraryService:
    """算法库服务"""
    
    def __init__(self):
        # TODO: 后续替换为持久化存储
        self._blocks: dict[str, AlgorithmBlock] = {}
        self._libraries: dict[str, LibraryInfo] = {}
        
        # 初始化内置算法块
        self._init_builtin_blocks()
    
    def _init_builtin_blocks(self):
        """初始化内置算法块"""
        builtin_blocks = [
            self._create_pid_block(),
            self._create_rs_block(),
            self._create_fby_block(),
            self._create_limiter_block(),
        ]
        
        for block in builtin_blocks:
            self._blocks[block.id] = block
    
    def _create_pid_block(self) -> AlgorithmBlock:
        """创建 PID 控制器算法块"""
        return AlgorithmBlock(
            id="PID_v1",
            name="PID控制器",
            category=BlockCategory.CONTROL,
            version="1.0.0",
            description="比例-积分-微分控制器，用于闭环控制",
            author="VeriSTC Team",
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
        """创建 RS 触发器算法块"""
        return AlgorithmBlock(
            id="RS_v1",
            name="RS触发器",
            category=BlockCategory.LOGIC,
            version="1.0.0",
            description="置位-复位触发器，优先复位",
            author="VeriSTC Team",
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
        """创建 FBY 延迟单元算法块"""
        return AlgorithmBlock(
            id="FBY_v1",
            name="FBY延迟单元",
            category=BlockCategory.FILTER,
            version="1.0.0",
            description="一阶滞后滤波，用于信号平滑",
            author="VeriSTC Team",
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
        """创建限幅器算法块"""
        return AlgorithmBlock(
            id="LIMITER_v1",
            name="限幅器",
            category=BlockCategory.MATH,
            version="1.0.0",
            description="限制信号在上下限范围内",
            author="VeriSTC Team",
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
    
    def _compute_sha256(self, block: AlgorithmBlock) -> str:
        """计算算法块的 SHA-256 哈希"""
        content = json.dumps({
            "name": block.name,
            "inputs": [p.to_dict() for p in block.inputs],
            "outputs": [p.to_dict() for p in block.outputs],
            "parameters": [p.to_dict() for p in block.parameters],
            "st_template": block.st_template,
        }, sort_keys=True)
        
        return hashlib.sha256(content.encode()).hexdigest()
    
    # ========== 算法块管理 ==========
    
    def get_block(self, block_id: str) -> Optional[AlgorithmBlock]:
        """获取算法块"""
        return self._blocks.get(block_id)
    
    def list_blocks(
        self,
        category: Optional[BlockCategory] = None,
        search_text: Optional[str] = None,
        tag: Optional[str] = None,
    ) -> list[AlgorithmBlock]:
        """列出算法块（支持过滤）"""
        result = list(self._blocks.values())
        
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
    
    def add_block(self, block: AlgorithmBlock) -> AlgorithmBlock:
        """添加算法块"""
        # 计算 SHA-256
        block.sha256 = self._compute_sha256(block)
        
        # 检查是否已存在（SHA-256 相同）
        for existing in self._blocks.values():
            if existing.sha256 == block.sha256:
                return existing
        
        # 生成唯一 ID（如果未提供）
        if not block.id:
            block.id = f"{block.name}_{uuid.uuid4().hex[:8]}"
        
        self._blocks[block.id] = block
        return block
    
    def update_block(self, block_id: str, **kwargs) -> Optional[AlgorithmBlock]:
        """更新算法块"""
        block = self._blocks.get(block_id)
        if not block:
            return None
        
        for key, value in kwargs.items():
            if hasattr(block, key):
                setattr(block, key, value)
        
        block.updated_at = datetime.now()
        block.sha256 = self._compute_sha256(block)
        
        return block
    
    def delete_block(self, block_id: str) -> bool:
        """删除算法块"""
        if block_id in self._blocks:
            del self._blocks[block_id]
            return True
        return False
    
    def import_block(self, block_data: dict) -> ImportResult:
        """导入算法块（从 JSON）"""
        try:
            # 解析数据
            block = AlgorithmBlock(
                id=block_data.get("id", ""),
                name=block_data["name"],
                category=BlockCategory(block_data.get("category", "custom")),
                version=block_data.get("version", "1.0.0"),
                description=block_data.get("description", ""),
                author=block_data.get("author", ""),
                block_kind=block_data.get("block_kind", "FB"),
                time_based=bool(block_data.get("time_based", False)),
                inputs=[
                    BlockPort(**p) for p in block_data.get("inputs", [])
                ],
                outputs=[
                    BlockPort(**p) for p in block_data.get("outputs", [])
                ],
                parameters=[
                    BlockParameter(**p) for p in block_data.get("parameters", [])
                ],
                st_template=block_data.get("st_template", ""),
                icon_svg=block_data.get("icon_svg", ""),
                tags=block_data.get("tags", []),
            )
            
            # 计算 SHA-256
            block.sha256 = self._compute_sha256(block)
            
            # 检查是否已存在
            for existing in self._blocks.values():
                if existing.sha256 == block.sha256:
                    return ImportResult(
                        success=True,
                        block_id=existing.id,
                        message=f"算法块已存在: {existing.name}",
                        is_duplicate=True,
                    )
            
            # 生成唯一 ID
            if not block.id:
                block.id = f"{block.name}_{uuid.uuid4().hex[:8]}"
            
            self._blocks[block.id] = block
            
            return ImportResult(
                success=True,
                block_id=block.id,
                message=f"成功导入: {block.name}",
            )
        
        except Exception as e:
            return ImportResult(
                success=False,
                message=f"导入失败: {str(e)}",
            )
    
    def export_block(self, block_id: str) -> Optional[dict]:
        """导出算法块（为 JSON）"""
        block = self._blocks.get(block_id)
        if not block:
            return None
        return block.to_dict()
    
    def export_library(self) -> dict:
        """导出整个算法库"""
        return {
            "version": "1.0.0",
            "exported_at": datetime.now().isoformat(),
            "blocks": [block.to_dict() for block in self._blocks.values()],
        }
    
    def import_library(self, library_data: dict) -> list[ImportResult]:
        """导入算法库（从 JSON）"""
        results = []
        blocks = library_data.get("blocks", [])
        
        for block_data in blocks:
            result = self.import_block(block_data)
            results.append(result)
        
        return results
    
    # ========== 算法库管理 ==========
    
    def create_library(self, name: str, description: str = "", owner: str = "") -> LibraryInfo:
        """创建算法库"""
        library = LibraryInfo(
            id=str(uuid.uuid4()),
            name=name,
            description=description,
            owner=owner,
        )
        self._libraries[library.id] = library
        return library
    
    def get_library(self, library_id: str) -> Optional[LibraryInfo]:
        """获取算法库信息"""
        return self._libraries.get(library_id)
    
    def list_libraries(self, include_shared: bool = True) -> list[LibraryInfo]:
        """列出算法库"""
        libraries = list(self._libraries.values())
        
        if not include_shared:
            libraries = [lib for lib in libraries if not lib.is_shared]
        
        return libraries
    
    def share_library(self, library_id: str, shared: bool = True) -> bool:
        """设置算法库共享状态"""
        library = self._libraries.get(library_id)
        if not library:
            return False
        
        library.is_shared = shared
        library.updated_at = datetime.now()
        return True
    
    def delete_library(self, library_id: str) -> bool:
        """删除算法库"""
        if library_id in self._libraries:
            del self._libraries[library_id]
            return True
        return False


# 全局服务实例
_service: Optional[LibraryService] = None


def get_library_service() -> LibraryService:
    """获取算法库服务实例"""
    global _service
    if _service is None:
        _service = LibraryService()
    return _service
