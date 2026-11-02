"""
算法块与算法库数据模型

支持功能：
- 算法块定义（PID/RS/FBY/LIMITER等）
- 算法库管理（分类/版本/元数据）
- 内容寻址存储（SHA-256）
- 导入/导出
- 共享库支持
"""

from dataclasses import dataclass, field
from datetime import datetime
from enum import Enum
from typing import Optional, Any


class BlockCategory(str, Enum):
    """算法块分类"""
    MATH = "math"              # 数学运算
    CONTROL = "control"        # 控制算法
    LOGIC = "logic"            # 逻辑运算
    FILTER = "filter"          # 滤波算法
    CONVERTER = "converter"    # 转换算法
    CUSTOM = "custom"          # 自定义


class PortDirection(str, Enum):
    """端口方向"""
    INPUT = "input"
    OUTPUT = "output"
    IN_OUT = "in_out"


class SignalType(str, Enum):
    """信号类型"""
    ANALOG = "analog"        # 模拟量
    DIGITAL = "digital"      # 开关量
    MIXED = "mixed"          # 混合


@dataclass
class BlockPort:
    """算法块端口定义"""
    name: str
    direction: PortDirection
    data_type: str  # BOOL/INT/DINT/REAL/STRING
    description: str = ""
    default_value: Any = None
    
    def to_dict(self) -> dict:
        return {
            "name": self.name,
            "direction": self.direction.value,
            "data_type": self.data_type,
            "description": self.description,
            "default_value": self.default_value,
        }


@dataclass
class BlockParameter:
    """算法块参数定义"""
    name: str
    data_type: str
    default_value: Any = None
    min_value: Optional[Any] = None
    max_value: Optional[Any] = None
    description: str = ""
    
    def to_dict(self) -> dict:
        return {
            "name": self.name,
            "data_type": self.data_type,
            "default_value": self.default_value,
            "min_value": self.min_value,
            "max_value": self.max_value,
            "description": self.description,
        }


@dataclass
class AlgorithmBlock:
    """算法块定义"""
    id: str                      # 唯一标识（如 "PID_v1"）
    name: str                    # 显示名称（如 "PID控制器"）
    category: BlockCategory      # 分类
    version: str                 # 版本号（如 "1.0.0"）
    description: str             # 描述
    author: str = ""             # 作者
    created_at: datetime = field(default_factory=datetime.now)
    updated_at: datetime = field(default_factory=datetime.now)

    # 执行语义
    block_kind: str = "FB"       # FB = FUNCTION_BLOCK（有实例状态）/ FUN = FUNCTION（纯函数）
    time_based: bool = False     # 输出是否取决于上周期的值（如图形回环里的延迟块）
    signal_type: SignalType = SignalType.MIXED  # 信号类型：模拟/数字/混合

    # 所属库
    library_id: str = ""         # 所属算法库 ID

    # 块定义
    inputs: list[BlockPort] = field(default_factory=list)
    outputs: list[BlockPort] = field(default_factory=list)
    parameters: list[BlockParameter] = field(default_factory=list)
    
    # ST 代码模板
    st_template: str = ""        # ST 代码模板
    
    # 图标
    icon_svg: str = ""           # SVG 图标
    
    # 元数据
    tags: list[str] = field(default_factory=list)
    sha256: str = ""             # 内容哈希（用于去重和验证）

    # 磁盘落点：全局用户库 / 当前工程 blocks/ / 内置块
    scope: str = "user"          # builtin / user / project
    path: str = ""               # <Type>.block.yaml 的绝对路径

    def to_dict(self) -> dict:
        return {
            "id": self.id,
            "name": self.name,
            "category": self.category.value,
            "version": self.version,
            "description": self.description,
            "author": self.author,
            "created_at": self.created_at.isoformat(),
            "updated_at": self.updated_at.isoformat(),
            "block_kind": self.block_kind,
            "time_based": self.time_based,
            "signal_type": self.signal_type.value,
            "library_id": self.library_id,
            "inputs": [p.to_dict() for p in self.inputs],
            "outputs": [p.to_dict() for p in self.outputs],
            "parameters": [p.to_dict() for p in self.parameters],
            "st_template": self.st_template,
            "icon_svg": self.icon_svg,
            "tags": self.tags,
            "sha256": self.sha256,
            "scope": self.scope,
            "path": self.path,
        }


@dataclass
class LibraryInfo:
    """算法库信息"""
    id: str                      # 库 ID
    name: str                    # 库名称
    description: str             # 描述
    owner: str = ""              # 所有者
    version: str = "1.0.0"       # 库版本
    is_shared: bool = False      # 是否共享
    blocks_count: int = 0        # 算法块数量
    created_at: datetime = field(default_factory=datetime.now)
    updated_at: datetime = field(default_factory=datetime.now)

    # 分类维度
    schema_version: str = "2.0"  # 清单格式版本
    classification_dims: dict = field(default_factory=dict)  # {time_based: bool, signal_type: str}

    # 校验信息
    validation: dict = field(default_factory=dict)  # {block_count, integrity_hash, ...}

    # 磁盘路径
    directory: str = ""          # 库目录的绝对路径

    def to_dict(self) -> dict:
        return {
            "id": self.id,
            "name": self.name,
            "description": self.description,
            "owner": self.owner,
            "version": self.version,
            "is_shared": self.is_shared,
            "blocks_count": self.blocks_count,
            "created_at": self.created_at.isoformat(),
            "updated_at": self.updated_at.isoformat(),
            "schema_version": self.schema_version,
            "classification_dims": self.classification_dims,
            "validation": self.validation,
            "directory": self.directory,
        }


@dataclass
class ClassificationFilter:
    """多维度分类筛选条件"""
    time_based: Optional[bool] = None      # True=时序相关, False=时序无关, None=不限
    signal_type: Optional[SignalType] = None  # analog/digital/mixed, None=不限
    categories: Optional[list[BlockCategory]] = None  # 限定分类列表, None=不限
    library_id: Optional[str] = None       # 限定库, None=全部


@dataclass
class ImportResult:
    """导入结果"""
    success: bool
    block_id: str = ""
    message: str = ""
    is_duplicate: bool = False   # 是否已存在（SHA-256 相同）
    
    def to_dict(self) -> dict:
        return {
            "success": self.success,
            "block_id": self.block_id,
            "message": self.message,
            "is_duplicate": self.is_duplicate,
        }
