"""
多人协同模块测试

测试协同服务的基本功能和 API 端点
"""

import pytest
from datetime import datetime

from veri_ide.backend.collaboration import (
    CollaborationService,
    get_collaboration_service,
    User,
    UserRole,
    Session,
    DocumentLock,
    LockType,
    CollaborativeDocument,
    Operation,
    OperationType,
)


class TestCollaborationService:
    """协同服务测试"""
    
    def setup_method(self):
        """每个测试前重置服务"""
        self.service = get_collaboration_service()
        # 清空数据
        self.service._users.clear()
        self.service._sessions.clear()
        self.service._documents.clear()
        self.service._locks.clear()
        self.service._operations.clear()
    
    def test_create_user(self):
        """测试创建用户"""
        user = self.service.create_user("test_user", "test@example.com", UserRole.EDITOR)
        assert user.username == "test_user"
        assert user.email == "test@example.com"
        assert user.role == UserRole.EDITOR
        assert user.id is not None
    
    def test_get_user(self):
        """测试获取用户"""
        user = self.service.create_user("test_user")
        retrieved = self.service.get_user(user.id)
        assert retrieved is not None
        assert retrieved.id == user.id
        assert retrieved.username == "test_user"
    
    def test_create_session(self):
        """测试创建会话"""
        user = self.service.create_user("test_user")
        doc = self.service.create_document("Test Doc", user.id)
        
        session = self.service.create_session(doc.id, user.id)
        assert session.document_id == doc.id
        assert user.id in session.users
        assert session.active is True
    
    def test_join_session(self):
        """测试加入会话"""
        user1 = self.service.create_user("user1")
        user2 = self.service.create_user("user2")
        doc = self.service.create_document("Test Doc", user1.id)
        
        session = self.service.create_session(doc.id, user1.id)
        success = self.service.join_session(session.id, user2.id)
        
        assert success is True
        assert user2.id in session.users
    
    def test_leave_session(self):
        """测试离开会话"""
        user = self.service.create_user("test_user")
        doc = self.service.create_document("Test Doc", user.id)
        
        session = self.service.create_session(doc.id, user.id)
        success = self.service.leave_session(session.id, user.id)
        
        assert success is True
        assert user.id not in session.users
    
    def test_acquire_lock(self):
        """测试获取文档锁"""
        user = self.service.create_user("test_user")
        doc = self.service.create_document("Test Doc", user.id)
        
        lock = self.service.acquire_lock(doc.id, user.id, LockType.EXCLUSIVE, 30)
        assert lock is not None
        assert lock.document_id == doc.id
        assert lock.user_id == user.id
        assert lock.lock_type == LockType.EXCLUSIVE
    
    def test_acquire_lock_conflict(self):
        """测试锁冲突"""
        user1 = self.service.create_user("user1")
        user2 = self.service.create_user("user2")
        doc = self.service.create_document("Test Doc", user1.id)
        
        # user1 获取锁
        lock1 = self.service.acquire_lock(doc.id, user1.id, LockType.EXCLUSIVE, 30)
        assert lock1 is not None
        
        # user2 尝试获取锁，应该失败
        lock2 = self.service.acquire_lock(doc.id, user2.id, LockType.EXCLUSIVE, 30)
        assert lock2 is None
    
    def test_release_lock(self):
        """测试释放文档锁"""
        user = self.service.create_user("test_user")
        doc = self.service.create_document("Test Doc", user.id)
        
        self.service.acquire_lock(doc.id, user.id, LockType.EXCLUSIVE, 30)
        success = self.service.release_lock(doc.id, user.id)
        
        assert success is True
        assert self.service.check_lock(doc.id) is None
    
    def test_create_document(self):
        """测试创建文档"""
        user = self.service.create_user("test_user")
        doc = self.service.create_document("Test Doc", user.id, {"blocks": []})
        
        assert doc.name == "Test Doc"
        assert doc.owner_id == user.id
        assert doc.version == 1
        assert doc.content == {"blocks": []}
    
    def test_update_document(self):
        """测试更新文档"""
        user = self.service.create_user("test_user")
        doc = self.service.create_document("Test Doc", user.id)
        
        new_content = {"blocks": [{"id": "block1", "type": "PID"}]}
        success = self.service.update_document(doc.id, user.id, new_content)
        
        assert success is True
        updated_doc = self.service.get_document(doc.id)
        assert updated_doc.content == new_content
        assert updated_doc.version == 2
    
    def test_update_document_locked(self):
        """测试更新被锁定的文档"""
        user1 = self.service.create_user("user1")
        user2 = self.service.create_user("user2")
        doc = self.service.create_document("Test Doc", user1.id)
        
        # user1 锁定文档
        self.service.acquire_lock(doc.id, user1.id, LockType.EXCLUSIVE, 30)
        
        # user2 尝试更新，应该失败
        success = self.service.update_document(doc.id, user2.id, {"blocks": []})
        assert success is False
    
    def test_record_operation(self):
        """测试记录操作"""
        user = self.service.create_user("test_user")
        doc = self.service.create_document("Test Doc", user.id)
        session = self.service.create_session(doc.id, user.id)
        
        op = self.service.record_operation(
            session.id,
            user.id,
            OperationType.CREATE,
            "block_1",
            {"type": "PID", "x": 100, "y": 200},
        )
        
        assert op.session_id == session.id
        assert op.user_id == user.id
        assert op.op_type == OperationType.CREATE
        assert op.target == "block_1"
    
    def test_get_operation_history(self):
        """测试获取操作历史"""
        user = self.service.create_user("test_user")
        doc = self.service.create_document("Test Doc", user.id)
        session = self.service.create_session(doc.id, user.id)
        
        # 记录多个操作
        for i in range(5):
            self.service.record_operation(
                session.id,
                user.id,
                OperationType.UPDATE,
                f"block_{i}",
                {"data": i},
            )
        
        history = self.service.get_operation_history(doc.id, limit=10)
        assert len(history) == 5
    
    def test_list_online_users(self):
        """测试列出在线用户"""
        user1 = self.service.create_user("user1")
        user2 = self.service.create_user("user2")
        doc = self.service.create_document("Test Doc", user1.id)
        
        session = self.service.create_session(doc.id, user1.id)
        self.service.join_session(session.id, user2.id)
        
        online_users = self.service.list_online_users(session.id)
        assert len(online_users) == 2
        assert any(u.id == user1.id for u in online_users)
        assert any(u.id == user2.id for u in online_users)


class TestModels:
    """数据模型测试"""
    
    def test_user_to_dict(self):
        """测试用户序列化"""
        user = User(
            id="user_1",
            username="test_user",
            email="test@example.com",
            role=UserRole.EDITOR,
        )
        data = user.to_dict()
        
        assert data["id"] == "user_1"
        assert data["username"] == "test_user"
        assert data["email"] == "test@example.com"
        assert data["role"] == "editor"
    
    def test_document_lock_expired(self):
        """测试文档锁过期"""
        from datetime import timedelta
        
        lock = DocumentLock(
            document_id="doc_1",
            user_id="user_1",
            lock_type=LockType.EXCLUSIVE,
            expires_at=datetime.now() - timedelta(minutes=1),
        )
        
        assert lock.is_expired() is True
    
    def test_document_lock_not_expired(self):
        """测试文档锁未过期"""
        from datetime import timedelta
        
        lock = DocumentLock(
            document_id="doc_1",
            user_id="user_1",
            lock_type=LockType.EXCLUSIVE,
            expires_at=datetime.now() + timedelta(minutes=30),
        )
        
        assert lock.is_expired() is False
    
    def test_operation_to_dict(self):
        """测试操作序列化"""
        op = Operation(
            id="op_1",
            session_id="session_1",
            user_id="user_1",
            op_type=OperationType.CREATE,
            target="block_1",
            data={"type": "PID"},
            version=1,
        )
        data = op.to_dict()
        
        assert data["id"] == "op_1"
        assert data["op_type"] == "create"
        assert data["target"] == "block_1"
        assert data["data"] == {"type": "PID"}


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
