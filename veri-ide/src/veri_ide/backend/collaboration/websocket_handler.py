"""
WebSocket 实时协同处理器

预留接口，后续实现时完善：
- WebSocket 连接管理
- 操作广播
- 在线状态同步
- 心跳检测
- 断线重连
"""

import json
from typing import Optional
from fastapi import WebSocket, WebSocketDisconnect


class CollaborationWebSocketHandler:
    """协同 WebSocket 处理器"""
    
    def __init__(self):
        # TODO: 实现连接池管理
        self._connections: dict[str, WebSocket] = {}  # user_id -> websocket
        self._user_sessions: dict[str, str] = {}  # user_id -> session_id
    
    async def connect(self, websocket: WebSocket, user_id: str, session_id: str):
        """建立 WebSocket 连接"""
        await websocket.accept()
        self._connections[user_id] = websocket
        self._user_sessions[user_id] = session_id
        
        # TODO: 广播用户上线通知
        await self._broadcast_to_session(session_id, {
            "type": "user_joined",
            "user_id": user_id,
        })
    
    async def disconnect(self, user_id: str):
        """断开 WebSocket 连接"""
        if user_id in self._connections:
            del self._connections[user_id]
        
        session_id = self._user_sessions.pop(user_id, None)
        if session_id:
            # TODO: 广播用户下线通知
            await self._broadcast_to_session(session_id, {
                "type": "user_left",
                "user_id": user_id,
            })
    
    async def handle_message(self, user_id: str, message: dict):
        """处理收到的消息"""
        msg_type = message.get("type")
        
        if msg_type == "operation":
            # 广播操作到其他用户
            await self._broadcast_operation(user_id, message)
        elif msg_type == "cursor_move":
            # 广播光标位置
            await self._broadcast_cursor(user_id, message)
        elif msg_type == "ping":
            # 心跳响应
            await self._send_to_user(user_id, {"type": "pong"})
        else:
            # 未知消息类型
            pass
    
    async def _send_to_user(self, user_id: str, message: dict):
        """发送消息给指定用户"""
        websocket = self._connections.get(user_id)
        if websocket:
            try:
                await websocket.send_json(message)
            except Exception:
                # 发送失败，可能是连接已断开
                await self.disconnect(user_id)
    
    async def _broadcast_to_session(self, session_id: str, message: dict, exclude_user: Optional[str] = None):
        """广播消息给会话中的所有用户"""
        for user_id, sid in self._user_sessions.items():
            if sid == session_id and user_id != exclude_user:
                await self._send_to_user(user_id, message)
    
    async def _broadcast_operation(self, user_id: str, operation: dict):
        """广播操作到同一会话的其他用户"""
        session_id = self._user_sessions.get(user_id)
        if session_id:
            await self._broadcast_to_session(session_id, {
                "type": "operation",
                "user_id": user_id,
                "operation": operation,
            }, exclude_user=user_id)
    
    async def _broadcast_cursor(self, user_id: str, cursor_data: dict):
        """广播光标位置"""
        session_id = self._user_sessions.get(user_id)
        if session_id:
            await self._broadcast_to_session(session_id, {
                "type": "cursor_update",
                "user_id": user_id,
                "cursor": cursor_data.get("cursor"),
            }, exclude_user=user_id)
    
    def get_online_users(self, session_id: str) -> list[str]:
        """获取会话中的在线用户"""
        return [uid for uid, sid in self._user_sessions.items() if sid == session_id]


# 全局处理器实例
_handler: Optional[CollaborationWebSocketHandler] = None


def get_websocket_handler() -> CollaborationWebSocketHandler:
    """获取 WebSocket 处理器实例"""
    global _handler
    if _handler is None:
        _handler = CollaborationWebSocketHandler()
    return _handler


async def websocket_endpoint(websocket: WebSocket, user_id: str, session_id: str):
    """WebSocket 端点处理函数"""
    handler = get_websocket_handler()
    
    try:
        await handler.connect(websocket, user_id, session_id)
        
        while True:
            data = await websocket.receive_text()
            try:
                message = json.loads(data)
                await handler.handle_message(user_id, message)
            except json.JSONDecodeError:
                await websocket.send_json({"error": "Invalid JSON"})
            except Exception as e:
                await websocket.send_json({"error": str(e)})
    
    except WebSocketDisconnect:
        await handler.disconnect(user_id)
    except Exception as e:
        print(f"WebSocket error: {e}")
        await handler.disconnect(user_id)
