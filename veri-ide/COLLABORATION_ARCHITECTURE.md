# VeriIDE 多人协同组态架构设计

**版本**: v0.1.0 (架构预留)  
**日期**: 2026-10-29  
**状态**: 接口已定义，实现待完善

## 1. 概述

本文档描述 VeriIDE 多人协同组态功能的架构设计。当前版本已预留模块结构和 API 接口，后续实现时将在此基础上完善具体功能。

### 1.1 设计目标

- **实时协同**: 多人同时编辑同一图形组态文档
- **冲突避免**: 文档锁机制防止并发修改冲突
- **操作同步**: 基于 WebSocket 的实时操作广播
- **权限控制**: 基于角色的访问控制（RBAC）
- **历史追溯**: 操作历史记录与回滚能力

### 1.2 核心概念

| 概念 | 说明 |
|------|------|
| **User** | 协同用户，具有角色（Owner/Editor/Viewer/Guest） |
| **Session** | 协同会话，关联一组用户和一个文档 |
| **Document** | 协同文档，包含图形组态内容（blocks, connections） |
| **Lock** | 文档锁，排他锁或共享锁，带过期时间 |
| **Operation** | 协同操作，记录用户的每次修改 |

## 2. 模块结构

```
veri-ide/src/veri_ide/backend/collaboration/
├── __init__.py              # 模块导出
├── models.py                # 数据模型定义
├── service.py               # 协同服务主类
├── websocket_handler.py     # WebSocket 实时通信
└── router.py                # FastAPI 路由端点
```

### 2.1 数据模型 (models.py)

#### User 用户模型
```python
@dataclass
class User:
    id: str
    username: str
    email: Optional[str]
    role: UserRole  # OWNER / EDITOR / VIEWER / GUEST
    created_at: datetime
    last_seen: datetime
```

#### Session 会话模型
```python
@dataclass
class Session:
    id: str
    document_id: str
    users: list[str]  # User IDs
    created_at: datetime
    active: bool
```

#### DocumentLock 文档锁模型
```python
@dataclass
class DocumentLock:
    document_id: str
    user_id: str
    lock_type: LockType  # EXCLUSIVE / SHARED / NONE
    acquired_at: datetime
    expires_at: Optional[datetime]
```

#### Operation 操作模型
```python
@dataclass
class Operation:
    id: str
    session_id: str
    user_id: str
    op_type: OperationType  # CREATE / UPDATE / DELETE / LOCK / UNLOCK
    target: str  # 操作目标（block_id, connection_id, etc.）
    data: dict
    timestamp: datetime
    version: int  # 文档版本号
```

#### CollaborativeDocument 协同文档模型
```python
@dataclass
class CollaborativeDocument:
    id: str
    name: str
    owner_id: str
    version: int
    lock: Optional[DocumentLock]
    created_at: datetime
    updated_at: datetime
    content: dict  # 文档内容（blocks, connections, variables）
```

### 2.2 协同服务 (service.py)

`CollaborationService` 提供以下核心方法：

#### 用户管理
- `create_user(username, email, role)` → User
- `get_user(user_id)` → Optional[User]
- `list_online_users(session_id)` → list[User]

#### 会话管理
- `create_session(document_id, user_id)` → Session
- `join_session(session_id, user_id)` → bool
- `leave_session(session_id, user_id)` → bool
- `get_session(session_id)` → Optional[Session]

#### 文档锁管理
- `acquire_lock(document_id, user_id, lock_type, duration_minutes)` → Optional[DocumentLock]
- `release_lock(document_id, user_id)` → bool
- `check_lock(document_id)` → Optional[DocumentLock]

#### 文档管理
- `create_document(name, owner_id, content)` → CollaborativeDocument
- `get_document(document_id)` → Optional[CollaborativeDocument]
- `update_document(document_id, user_id, content)` → bool
- `list_documents(user_id)` → list[CollaborativeDocument]

#### 操作历史
- `record_operation(session_id, user_id, op_type, target, data)` → Operation
- `get_operation_history(document_id, limit)` → list[Operation]
- `rollback_operation(operation_id, user_id)` → bool

### 2.3 WebSocket 处理器 (websocket_handler.py)

`CollaborationWebSocketHandler` 负责实时通信：

#### 连接管理
- `connect(websocket, user_id, session_id)`: 建立连接
- `disconnect(user_id)`: 断开连接
- `handle_message(user_id, message)`: 处理消息

#### 消息类型
```json
// 用户加入
{"type": "user_joined", "user_id": "xxx"}

// 用户离开
{"type": "user_left", "user_id": "xxx"}

// 操作广播
{
  "type": "operation",
  "user_id": "xxx",
  "operation": {"op_type": "create", "target": "block_1", "data": {...}}
}

// 光标更新
{
  "type": "cursor_update",
  "user_id": "xxx",
  "cursor": {"x": 100, "y": 200}
}

// 心跳
{"type": "ping"}
{"type": "pong"}
```

### 2.4 API 路由 (router.py)

所有端点前缀：`/collaboration`

#### 用户端点
- `POST /users`: 创建用户
- `GET /users/{user_id}`: 获取用户信息
- `GET /sessions/{session_id}/users`: 列出在线用户

#### 会话端点
- `POST /sessions`: 创建会话
- `POST /sessions/join`: 加入会话
- `POST /sessions/leave`: 离开会话
- `GET /sessions/{session_id}`: 获取会话信息

#### 锁端点
- `POST /locks`: 获取文档锁
- `DELETE /locks/{document_id}`: 释放文档锁
- `GET /locks/{document_id}`: 检查锁状态

#### 文档端点
- `POST /documents`: 创建文档
- `GET /documents/{document_id}`: 获取文档
- `PUT /documents`: 更新文档
- `GET /documents`: 列出文档

#### 操作历史端点
- `POST /operations`: 记录操作
- `GET /documents/{document_id}/operations`: 获取操作历史

#### WebSocket 端点
- `WS /ws/{user_id}/{session_id}`: 实时协同连接

## 3. 协同流程

### 3.1 用户加入协同会话

```
1. 用户 A 打开文档
2. 前端调用 POST /collaboration/sessions 创建会话
3. 前端建立 WebSocket 连接 WS /collaboration/ws/{user_id}/{session_id}
4. 服务端广播 {"type": "user_joined", "user_id": "A"}
```

### 3.2 文档锁获取

```
1. 用户 A 点击"编辑"按钮
2. 前端调用 POST /collaboration/locks 请求排他锁
3. 服务端检查锁状态：
   - 无锁 → 授予锁，返回 DocumentLock
   - 有锁但未过期 → 返回 409 Conflict
   - 有锁但已过期 → 自动释放，授予新锁
4. 前端获得锁后启用编辑功能
```

### 3.3 实时操作同步

```
1. 用户 A 创建功能块
2. 前端调用 POST /collaboration/operations 记录操作
3. 前端通过 WebSocket 发送操作消息
4. 服务端广播操作到同一会话的其他用户（B, C）
5. 用户 B、C 的前端接收并应用操作
6. 所有用户的文档视图保持同步
```

### 3.4 冲突解决策略

当前预留的冲突解决策略：

1. **悲观锁**: 编辑前必须获取排他锁，防止并发修改
2. **版本号**: 每次更新递增版本号，检测过期更新
3. **操作合并**: 后续可实现 OT（Operational Transformation）或 CRDT 算法

## 4. 待实现功能

### 4.1 短期（G2 阶段）

- [ ] 持久化存储（替换内存字典）
- [ ] 用户认证中间件（JWT/OAuth）
- [ ] WebSocket 连接池管理
- [ ] 心跳检测与断线重连
- [ ] 操作广播优化（增量同步）

### 4.2 中期（G3-G4 阶段）

- [ ] 冲突检测与自动合并（OT/CRDT）
- [ ] 操作历史持久化
- [ ] 文档版本管理（快照与回滚）
- [ ] 权限细粒度控制（字段级锁）
- [ ] 协同编辑可视化（光标、选区显示）

### 4.3 长期（G5+ 阶段）

- [ ] 分布式部署（Redis Pub/Sub）
- [ ] 操作审计日志
- [ ] 协同会话录制与回放
- [ ] AI 辅助冲突解决
- [ ] 离线编辑与同步

## 5. 技术选型建议

### 5.1 存储层

| 方案 | 优点 | 缺点 | 适用场景 |
|------|------|------|---------|
| **SQLite** | 轻量、单文件、无需服务 | 并发性能有限 | 单机部署、小规模协同 |
| **PostgreSQL** | 强一致性、丰富查询 | 需要独立服务 | 生产环境、大规模协同 |
| **Redis** | 高性能、Pub/Sub 支持 | 内存存储、需持久化方案 | 实时通信、会话缓存 |

**推荐**: SQLite（开发）→ PostgreSQL（生产）+ Redis（实时通信）

### 5.2 实时通信

| 方案 | 优点 | 缺点 |
|------|------|------|
| **WebSocket** | 双向通信、低延迟 | 需要处理连接管理 |
| **Server-Sent Events** | 简单、单向推送 | 不支持客户端发送 |
| **Long Polling** | 兼容性好 | 延迟高、资源浪费 |

**推荐**: WebSocket（已预留）

### 5.3 冲突解决算法

| 算法 | 优点 | 缺点 | 适用场景 |
|------|------|------|---------|
| **OT (Operational Transformation)** | 成熟、Google Docs 使用 | 实现复杂 | 文本编辑 |
| **CRDT (Conflict-free Replicated Data Type)** | 去中心化、无需服务器协调 | 数据结构限制 | 图形编辑 |
| **锁机制** | 简单、易实现 | 并发度低 | 当前预留方案 |

**推荐**: 锁机制（短期）→ CRDT（长期）

## 6. 安全考虑

### 6.1 认证与授权

- 所有 API 端点需添加认证中间件
- 基于角色的权限控制（RBAC）
- WebSocket 连接需验证用户身份

### 6.2 数据安全

- 文档内容加密存储
- 操作历史脱敏处理
- 防止未授权的文档访问

### 6.3 拒绝服务防护

- WebSocket 连接数限制
- API 请求频率限制
- 文档锁超时自动释放

## 7. 性能优化

### 7.1 短期优化

- 操作批量广播（减少 WebSocket 消息数）
- 文档增量更新（只传输变更部分）
- 连接池复用

### 7.2 长期优化

- 分布式部署（多节点协同）
- 操作压缩与缓存
- CDN 加速静态资源

## 8. 测试策略

### 8.1 单元测试

- 数据模型序列化/反序列化
- 服务层方法逻辑
- WebSocket 消息处理

### 8.2 集成测试

- API 端点完整流程
- 多用户并发操作
- 锁冲突场景

### 8.3 性能测试

- 100 用户同时在线
- 1000 操作/秒广播延迟
- 文档大小对性能影响

## 9. 总结

当前架构已预留完整的多人协同模块结构和 API 接口，后续实现时可在此基础上逐步完善。关键设计决策：

1. **模块化**: 数据模型、服务逻辑、通信处理分离
2. **可扩展**: 接口预留充分，支持多种实现方案
3. **安全性**: 认证授权、数据加密、防拒绝服务
4. **性能**: 增量同步、批量广播、连接池优化

下一步工作优先级：
1. 实现持久化存储（替换内存字典）
2. 添加用户认证中间件
3. 完善 WebSocket 连接管理
4. 实现操作广播与同步
5. 添加冲突检测与解决

---

**文档维护**: 随着实现进展，本文档将持续更新。
