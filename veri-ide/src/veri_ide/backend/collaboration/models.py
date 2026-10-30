"""
多人协同组态数据模型

预留接口，后续实现时完善：
- 用户认证与授权
- 会话管理
- 文档锁机制
- 变更广播
- 冲突解决
"""

from dataclasses import dataclass, field
from datetime import datetime
from enum import Enum
from typing import Optional


class UserRole(str, Enum):
    """用户角色"""
    OWNER = "owner"          # 所有者：完全控制
    EDITOR = "editor"        # 编辑者：可修改
    VIEWER = "viewer"        # 查看者：只读
    GUEST = "guest"          # 访客：临时访问


class LockType(str, Enum):
    """锁类型"""
    EXCLUSIVE = "exclusive"  # 排他锁：独占编辑
    SHARED = "shared"        # 共享锁：多人查看
    NONE = "none"            # 无锁


class OperationType(str, Enum):
    """操作类型"""
    CREATE = "create"        # 创建
    UPDATE = "update"        # 更新
    DELETE = "delete"        # 删除
    LOCK = "lock"            # 加锁
    UNLOCK = "unlock"        # 解锁


@dataclass
class User:
    """用户信息"""
    id: str
    username: str
    email: Optional[str] = None
    role: UserRole = UserRole.VIEWER
    created_at: datetime = field(default_factory=datetime.now)
    last_seen: datetime = field(default_factory=datetime.now)
    
    def to_dict(self) -> dict:
        return {
            "id": self.id,
            "username": self.username,
            "email": self.email,
            "role": self.role.value,
            "created_at": self.created_at.isoformat(),
            "last_seen": self.last_seen.isoformat(),
        }


@dataclass
class Session:
    """协同会话"""
    id: str
    document_id: str
    users: list[str] = field(default_factory=list)  # User IDs
    created_at: datetime = field(default_factory=datetime.now)
    active: bool = True
    
    def to_dict(self) -> dict:
        return {
            "id": self.id,
            "document_id": self.document_id,
            "users": self.users,
            "created_at": self.created_at.isoformat(),
            "active": self.active,
        }


@dataclass
class DocumentLock:
    """文档锁"""
    document_id: str
    user_id: str
    lock_type: LockType
    acquired_at: datetime = field(default_factory=datetime.now)
    expires_at: Optional[datetime] = None
    
    def is_expired(self) -> bool:
        if self.expires_at is None:
            return False
        return datetime.now() > self.expires_at
    
    def to_dict(self) -> dict:
        return {
            "document_id": self.document_id,
            "user_id": self.user_id,
            "lock_type": self.lock_type.value,
            "acquired_at": self.acquired_at.isoformat(),
            "expires_at": self.expires_at.isoformat() if self.expires_at else None,
        }


@dataclass
class Operation:
    """协同操作记录"""
    id: str
    session_id: str
    user_id: str
    op_type: OperationType
    target: str  # 操作目标（block_id, connection_id, etc.）
    data: dict = field(default_factory=dict)
    timestamp: datetime = field(default_factory=datetime.now)
    version: int = 0  # 文档版本号
    
    def to_dict(self) -> dict:
        return {
            "id": self.id,
            "session_id": self.session_id,
            "user_id": self.user_id,
            "op_type": self.op_type.value,
            "target": self.target,
            "data": self.data,
            "timestamp": self.timestamp.isoformat(),
            "version": self.version,
        }


@dataclass
class CollaborativeDocument:
    """协同文档"""
    id: str
    name: str
    owner_id: str
    version: int = 1
    lock: Optional[DocumentLock] = None
    created_at: datetime = field(default_factory=datetime.now)
    updated_at: datetime = field(default_factory=datetime.now)
    content: dict = field(default_factory=dict)  # 文档内容（blocks, connections, etc.）
    
    def to_dict(self) -> dict:
        return {
            "id": self.id,
            "name": self.name,
            "owner_id": self.owner_id,
            "version": self.version,
            "lock": self.lock.to_dict() if self.lock else None,
            "created_at": self.created_at.isoformat(),
            "updated_at": self.updated_at.isoformat(),
            "content": self.content,
        }
