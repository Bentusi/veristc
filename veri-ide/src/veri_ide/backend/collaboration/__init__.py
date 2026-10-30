"""
多人协同组态模块

提供以下能力（预留接口，后续实现）：
- 用户认证与授权
- 会话管理
- 文档锁机制
- 实时协同（WebSocket）
- 操作历史与回滚
- 冲突检测与解决
"""

from .models import (
    CollaborativeDocument,
    DocumentLock,
    LockType,
    Operation,
    OperationType,
    Session,
    User,
    UserRole,
)
from .service import CollaborationService, get_collaboration_service
from .websocket_handler import (
    CollaborationWebSocketHandler,
    get_websocket_handler,
    websocket_endpoint,
)

__all__ = [
    # Models
    "User",
    "UserRole",
    "Session",
    "DocumentLock",
    "LockType",
    "Operation",
    "OperationType",
    "CollaborativeDocument",
    # Service
    "CollaborationService",
    "get_collaboration_service",
    # WebSocket
    "CollaborationWebSocketHandler",
    "get_websocket_handler",
    "websocket_endpoint",
]
