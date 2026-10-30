"""
在线监视与调试数据模型

支持功能：
- 变量在线监视（单个/批量）
- 变量强制（Force）与释放（Release）
- 参数在线修改
- 实时数据刷新
"""

from dataclasses import dataclass, field
from datetime import datetime
from enum import Enum
from typing import Optional, Any


class VariableType(str, Enum):
    """变量类型"""
    INPUT = "INPUT"
    OUTPUT = "OUTPUT"
    IN_OUT = "IN_OUT"
    LOCAL = "LOCAL"
    GLOBAL = "GLOBAL"


class DataType(str, Enum):
    """数据类型（IEC 61131-3）"""
    BOOL = "BOOL"
    INT = "INT"
    DINT = "DINT"
    REAL = "REAL"
    STRING = "STRING"
    TIME = "TIME"
    DATE = "DATE"


class ForceStatus(str, Enum):
    """强制状态"""
    NOT_FORCED = "not_forced"
    FORCED = "forced"
    PENDING = "pending"  # 等待周期边界生效


class MonitorMode(str, Enum):
    """监视模式"""
    SINGLE = "single"      # 单变量监视
    BATCH = "batch"        # 批量变量监视
    WATCH_TABLE = "watch_table"  # 监视表


@dataclass
class VariableInfo:
    """变量信息"""
    name: str
    address: int  # 内存地址
    data_type: DataType
    var_type: VariableType
    current_value: Any = None
    forced_value: Optional[Any] = None
    force_status: ForceStatus = ForceStatus.NOT_FORCED
    last_updated: datetime = field(default_factory=datetime.now)
    quality: str = "good"  # good / bad / uncertain
    
    def to_dict(self) -> dict:
        return {
            "name": self.name,
            "address": self.address,
            "data_type": self.data_type.value,
            "var_type": self.var_type.value,
            "current_value": self.current_value,
            "forced_value": self.forced_value,
            "force_status": self.force_status.value,
            "last_updated": self.last_updated.isoformat(),
            "quality": self.quality,
        }


@dataclass
class WatchEntry:
    """监视表条目"""
    id: str
    variable_name: str
    alias: Optional[str] = None  # 显示别名
    display_format: str = "decimal"  # decimal / hex / binary
    enabled: bool = True
    last_value: Any = None
    last_update: Optional[datetime] = None
    
    def to_dict(self) -> dict:
        return {
            "id": self.id,
            "variable_name": self.variable_name,
            "alias": self.alias,
            "display_format": self.display_format,
            "enabled": self.enabled,
            "last_value": self.last_value,
            "last_update": self.last_update.isoformat() if self.last_update else None,
        }


@dataclass
class ForceRequest:
    """变量强制值请求"""
    variable_name: str
    force_value: Any
    data_type: DataType
    persistent: bool = False  # 是否持久化（跨周期保持）
    
    def to_dict(self) -> dict:
        return {
            "variable_name": self.variable_name,
            "force_value": self.force_value,
            "data_type": self.data_type.value,
            "persistent": self.persistent,
        }


@dataclass
class ForceResult:
    """变量强制结果"""
    success: bool
    variable_name: str
    message: str
    effective_at: Optional[datetime] = None  # 生效时间（周期边界）
    
    def to_dict(self) -> dict:
        return {
            "success": self.success,
            "variable_name": self.variable_name,
            "message": self.message,
            "effective_at": self.effective_at.isoformat() if self.effective_at else None,
        }


@dataclass
class ParameterModification:
    """参数修改请求"""
    block_id: str  # 功能块实例 ID
    parameter_name: str
    old_value: Any
    new_value: Any
    data_type: DataType
    timestamp: datetime = field(default_factory=datetime.now)
    applied: bool = False
    error: Optional[str] = None
    
    def to_dict(self) -> dict:
        return {
            "block_id": self.block_id,
            "parameter_name": self.parameter_name,
            "old_value": self.old_value,
            "new_value": self.new_value,
            "data_type": self.data_type.value,
            "timestamp": self.timestamp.isoformat(),
            "applied": self.applied,
            "error": self.error,
        }


@dataclass
class MonitorSnapshot:
    """监视数据快照"""
    timestamp: datetime
    cycle_count: int
    variables: list[VariableInfo]
    
    def to_dict(self) -> dict:
        return {
            "timestamp": self.timestamp.isoformat(),
            "cycle_count": self.cycle_count,
            "variables": [v.to_dict() for v in self.variables],
        }


@dataclass
class BatchOperation:
    """批量操作"""
    id: str
    operation_type: str  # "force" / "release" / "modify"
    items: list[dict]
    created_at: datetime = field(default_factory=datetime.now)
    completed_at: Optional[datetime] = None
    success_count: int = 0
    failure_count: int = 0
    results: list[dict] = field(default_factory=list)
    
    def to_dict(self) -> dict:
        return {
            "id": self.id,
            "operation_type": self.operation_type,
            "items": self.items,
            "created_at": self.created_at.isoformat(),
            "completed_at": self.completed_at.isoformat() if self.completed_at else None,
            "success_count": self.success_count,
            "failure_count": self.failure_count,
            "results": self.results,
        }
