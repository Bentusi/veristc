"""
在线监视与调试模块

提供功能：
- 变量在线监视（单个/批量）
- 变量强制（Force）与释放（Release）
- 参数在线修改
- 监视表管理
- 批量操作支持
"""

from .models import (
    VariableInfo,
    VariableType,
    DataType,
    ForceStatus,
    ForceRequest,
    ForceResult,
    WatchEntry,
    ParameterModification,
    MonitorSnapshot,
    BatchOperation,
    MonitorMode,
)
from .service import MonitorService, get_monitor_service
from .router import router

__all__ = [
    # Models
    "VariableInfo",
    "VariableType",
    "DataType",
    "ForceStatus",
    "ForceRequest",
    "ForceResult",
    "WatchEntry",
    "ParameterModification",
    "MonitorSnapshot",
    "BatchOperation",
    "MonitorMode",
    # Service
    "MonitorService",
    "get_monitor_service",
    # Router
    "router",
]
