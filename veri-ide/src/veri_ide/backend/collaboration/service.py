"""
多人协同服务

预留接口，后续实现时完善：
- 用户认证与授权
- 会话管理
- 文档锁机制
- 变更广播（WebSocket）
- 冲突检测与解决
- 操作历史与回滚
"""

import uuid
from datetime import datetime, timedelta
from typing import Optional

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


class CollaborationService:
    """协同服务主类"""
    
    def __init__(self):
        # TODO: 后续替换为持久化存储
        self._users: dict[str, User] = {}
        self._sessions: dict[str, Session] = {}
        self._documents: dict[str, CollaborativeDocument] = {}
        self._locks: dict[str, DocumentLock] = {}
        self._operations: list[Operation] = []
    
    # ========== 用户管理 ==========
    
    def create_user(self, username: str, email: Optional[str] = None, role: UserRole = UserRole.VIEWER) -> User:
        """创建用户（预留）"""
        # TODO: 集成真实认证系统（OAuth/LDAP/本地）
        user = User(
            id=str(uuid.uuid4()),
            username=username,
            email=email,
            role=role,
        )
        self._users[user.id] = user
        return user
    
    def get_user(self, user_id: str) -> Optional[User]:
        """获取用户信息"""
        return self._users.get(user_id)
    
    def list_online_users(self, session_id: str) -> list[User]:
        """列出会话中的在线用户"""
        # TODO: 实现真实的在线状态追踪
        session = self._sessions.get(session_id)
        if not session:
            return []
        return [self._users[uid] for uid in session.users if uid in self._users]
    
    # ========== 会话管理 ==========
    
    def create_session(self, document_id: str, user_id: str) -> Session:
        """创建协同会话"""
        # TODO: 实现会话过期清理
        session = Session(
            id=str(uuid.uuid4()),
            document_id=document_id,
            users=[user_id],
        )
        self._sessions[session.id] = session
        return session
    
    def join_session(self, session_id: str, user_id: str) -> bool:
        """加入协同会话"""
        session = self._sessions.get(session_id)
        if not session or not session.active:
            return False
        if user_id not in session.users:
            session.users.append(user_id)
        return True
    
    def leave_session(self, session_id: str, user_id: str) -> bool:
        """离开协同会话"""
        session = self._sessions.get(session_id)
        if not session:
            return False
        if user_id in session.users:
            session.users.remove(user_id)
        # TODO: 如果会话为空，标记为不活跃
        return True
    
    def get_session(self, session_id: str) -> Optional[Session]:
        """获取会话信息"""
        return self._sessions.get(session_id)
    
    # ========== 文档锁管理 ==========
    
    def acquire_lock(self, document_id: str, user_id: str, lock_type: LockType = LockType.EXCLUSIVE, duration_minutes: int = 30) -> Optional[DocumentLock]:
        """获取文档锁"""
        # TODO: 实现锁冲突检测与等待队列
        doc = self._documents.get(document_id)
        if not doc:
            return None
        
        # 检查是否已有锁
        existing_lock = self._locks.get(document_id)
        if existing_lock and not existing_lock.is_expired():
            if existing_lock.user_id != user_id:
                # 锁被其他用户持有
                return None
        
        # 创建新锁
        lock = DocumentLock(
            document_id=document_id,
            user_id=user_id,
            lock_type=lock_type,
            expires_at=datetime.now() + timedelta(minutes=duration_minutes),
        )
        self._locks[document_id] = lock
        doc.lock = lock
        return lock
    
    def release_lock(self, document_id: str, user_id: str) -> bool:
        """释放文档锁"""
        lock = self._locks.get(document_id)
        if not lock or lock.user_id != user_id:
            return False
        
        del self._locks[document_id]
        doc = self._documents.get(document_id)
        if doc:
            doc.lock = None
        return True
    
    def check_lock(self, document_id: str) -> Optional[DocumentLock]:
        """检查文档锁状态"""
        lock = self._locks.get(document_id)
        if lock and lock.is_expired():
            # 锁已过期，自动释放
            self.release_lock(document_id, lock.user_id)
            return None
        return lock
    
    # ========== 文档管理 ==========
    
    def create_document(self, name: str, owner_id: str, content: Optional[dict] = None) -> CollaborativeDocument:
        """创建协同文档"""
        doc = CollaborativeDocument(
            id=str(uuid.uuid4()),
            name=name,
            owner_id=owner_id,
            content=content or {},
        )
        self._documents[doc.id] = doc
        return doc
    
    def get_document(self, document_id: str) -> Optional[CollaborativeDocument]:
        """获取文档"""
        return self._documents.get(document_id)
    
    def update_document(self, document_id: str, user_id: str, content: dict) -> bool:
        """更新文档内容"""
        # TODO: 实现增量更新与冲突检测
        doc = self._documents.get(document_id)
        if not doc:
            return False
        
        # 检查锁
        lock = self.check_lock(document_id)
        if lock and lock.user_id != user_id:
            return False  # 文档被其他用户锁定
        
        doc.content = content
        doc.version += 1
        doc.updated_at = datetime.now()
        return True
    
    def list_documents(self, user_id: Optional[str] = None) -> list[CollaborativeDocument]:
        """列出文档"""
        # TODO: 实现权限过滤
        if user_id:
            return [doc for doc in self._documents.values() if doc.owner_id == user_id]
        return list(self._documents.values())
    
    # ========== 操作历史 ==========
    
    def record_operation(self, session_id: str, user_id: str, op_type: OperationType, target: str, data: dict) -> Operation:
        """记录协同操作"""
        # TODO: 实现操作广播（WebSocket）
        doc_id = self._sessions[session_id].document_id if session_id in self._sessions else ""
        version = self._documents[doc_id].version if doc_id in self._documents else 0
        
        op = Operation(
            id=str(uuid.uuid4()),
            session_id=session_id,
            user_id=user_id,
            op_type=op_type,
            target=target,
            data=data,
            version=version,
        )
        self._operations.append(op)
        return op
    
    def get_operation_history(self, document_id: str, limit: int = 100) -> list[Operation]:
        """获取操作历史"""
        # TODO: 实现按文档过滤和分页
        return self._operations[-limit:]
    
    def rollback_operation(self, operation_id: str, user_id: str) -> bool:
        """回滚操作（预留）"""
        # TODO: 实现操作回滚逻辑
        return False


# 全局服务实例（单例）
_service: Optional[CollaborationService] = None


def get_collaboration_service() -> CollaborationService:
    """获取协同服务实例"""
    global _service
    if _service is None:
        _service = CollaborationService()
    return _service
