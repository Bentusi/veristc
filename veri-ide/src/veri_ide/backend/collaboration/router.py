"""
多人协同 API 路由

预留接口，后续实现时完善：
- 用户认证中间件
- 权限检查
- WebSocket 端点
- 错误处理
"""

from fastapi import APIRouter, HTTPException, WebSocket, Query
from pydantic import BaseModel
from typing import Optional

from .service import get_collaboration_service
from .models import UserRole, LockType
from .websocket_handler import websocket_endpoint


router = APIRouter(prefix="/collaboration", tags=["collaboration"])


# ========== Request/Response Models ==========

class CreateUserRequest(BaseModel):
    username: str
    email: Optional[str] = None
    role: UserRole = UserRole.VIEWER


class CreateSessionRequest(BaseModel):
    document_id: str
    user_id: str


class JoinSessionRequest(BaseModel):
    session_id: str
    user_id: str


class AcquireLockRequest(BaseModel):
    document_id: str
    user_id: str
    lock_type: LockType = LockType.EXCLUSIVE
    duration_minutes: int = 30


class CreateDocumentRequest(BaseModel):
    name: str
    owner_id: str
    content: Optional[dict] = None


class UpdateDocumentRequest(BaseModel):
    document_id: str
    user_id: str
    content: dict


class RecordOperationRequest(BaseModel):
    session_id: str
    user_id: str
    op_type: str
    target: str
    data: dict


# ========== User Endpoints ==========

@router.post("/users")
async def create_user(request: CreateUserRequest):
    """创建用户"""
    # TODO: 添加认证中间件
    service = get_collaboration_service()
    user = service.create_user(request.username, request.email, request.role)
    return {"user": user.to_dict()}


@router.get("/users/{user_id}")
async def get_user(user_id: str):
    """获取用户信息"""
    service = get_collaboration_service()
    user = service.get_user(user_id)
    if not user:
        raise HTTPException(status_code=404, detail="User not found")
    return {"user": user.to_dict()}


@router.get("/sessions/{session_id}/users")
async def list_online_users(session_id: str):
    """列出会话中的在线用户"""
    service = get_collaboration_service()
    users = service.list_online_users(session_id)
    return {"users": [u.to_dict() for u in users]}


# ========== Session Endpoints ==========

@router.post("/sessions")
async def create_session(request: CreateSessionRequest):
    """创建协同会话"""
    service = get_collaboration_service()
    session = service.create_session(request.document_id, request.user_id)
    return {"session": session.to_dict()}


@router.post("/sessions/join")
async def join_session(request: JoinSessionRequest):
    """加入协同会话"""
    service = get_collaboration_service()
    success = service.join_session(request.session_id, request.user_id)
    if not success:
        raise HTTPException(status_code=400, detail="Cannot join session")
    return {"success": True}


@router.post("/sessions/leave")
async def leave_session(request: JoinSessionRequest):
    """离开协同会话"""
    service = get_collaboration_service()
    success = service.leave_session(request.session_id, request.user_id)
    return {"success": success}


@router.get("/sessions/{session_id}")
async def get_session(session_id: str):
    """获取会话信息"""
    service = get_collaboration_service()
    session = service.get_session(session_id)
    if not session:
        raise HTTPException(status_code=404, detail="Session not found")
    return {"session": session.to_dict()}


# ========== Lock Endpoints ==========

@router.post("/locks")
async def acquire_lock(request: AcquireLockRequest):
    """获取文档锁"""
    service = get_collaboration_service()
    lock = service.acquire_lock(
        request.document_id,
        request.user_id,
        request.lock_type,
        request.duration_minutes,
    )
    if not lock:
        raise HTTPException(status_code=409, detail="Document is locked by another user")
    return {"lock": lock.to_dict()}


@router.delete("/locks/{document_id}")
async def release_lock(document_id: str, user_id: str = Query(...)):
    """释放文档锁"""
    service = get_collaboration_service()
    success = service.release_lock(document_id, user_id)
    if not success:
        raise HTTPException(status_code=400, detail="Cannot release lock")
    return {"success": True}


@router.get("/locks/{document_id}")
async def check_lock(document_id: str):
    """检查文档锁状态"""
    service = get_collaboration_service()
    lock = service.check_lock(document_id)
    if lock:
        return {"locked": True, "lock": lock.to_dict()}
    return {"locked": False}


# ========== Document Endpoints ==========

@router.post("/documents")
async def create_document(request: CreateDocumentRequest):
    """创建协同文档"""
    service = get_collaboration_service()
    doc = service.create_document(request.name, request.owner_id, request.content)
    return {"document": doc.to_dict()}


@router.get("/documents/{document_id}")
async def get_document(document_id: str):
    """获取文档"""
    service = get_collaboration_service()
    doc = service.get_document(document_id)
    if not doc:
        raise HTTPException(status_code=404, detail="Document not found")
    return {"document": doc.to_dict()}


@router.put("/documents")
async def update_document(request: UpdateDocumentRequest):
    """更新文档内容"""
    service = get_collaboration_service()
    success = service.update_document(request.document_id, request.user_id, request.content)
    if not success:
        raise HTTPException(status_code=400, detail="Cannot update document (locked or not found)")
    return {"success": True}


@router.get("/documents")
async def list_documents(user_id: Optional[str] = Query(None)):
    """列出文档"""
    service = get_collaboration_service()
    docs = service.list_documents(user_id)
    return {"documents": [d.to_dict() for d in docs]}


# ========== Operation History Endpoints ==========

@router.post("/operations")
async def record_operation(request: RecordOperationRequest):
    """记录协同操作"""
    service = get_collaboration_service()
    from .models import OperationType
    op = service.record_operation(
        request.session_id,
        request.user_id,
        OperationType(request.op_type),
        request.target,
        request.data,
    )
    return {"operation": op.to_dict()}


@router.get("/documents/{document_id}/operations")
async def get_operation_history(document_id: str, limit: int = Query(100)):
    """获取操作历史"""
    service = get_collaboration_service()
    ops = service.get_operation_history(document_id, limit)
    return {"operations": [op.to_dict() for op in ops]}


# ========== WebSocket Endpoint ==========

@router.websocket("/ws/{user_id}/{session_id}")
async def websocket_collaboration(websocket: WebSocket, user_id: str, session_id: str):
    """协同 WebSocket 端点"""
    await websocket_endpoint(websocket, user_id, session_id)
