# G4 W2 完成报告：前端 API 集成

## 完成时间
2026-10-29

## 交付内容

### 1. 下装向导 API 集成 (`frontend/public/download-wizard.html`)

**新增功能：**
- API 基础配置：`API_BASE = 'http://localhost:8000'`
- `apiCall()` 函数：统一 API 调用封装，自动处理错误
- `loadKeys()` 函数：进入步骤 2 时自动加载密钥列表
- `updateKeySelect()` 函数：动态更新密钥下拉框
- `generateKey()` 函数：生成新密钥（调用 POST /keys/generate）
- `startDeploy()` 函数：异步执行下装（调用 POST /deploy）
  - 自动从 API 获取密钥 hex 值（当选择密钥名时）
  - 显示进度条和状态日志
  - 处理成功/失败结果

**修复问题：**
- 密钥选择逻辑：选择密钥名时，先调用 GET /keys/{name} 获取实际 hex 密钥
- 添加"生成新密钥"按钮到步骤 2

### 2. 后端 API 端点 (`src/veri_ide/api/server.py`)

**新增端点：**
- `POST /deploy` — 执行下装
- `POST /keys/generate` — 生成新密钥
- `GET /keys` — 列出所有密钥
- `GET /keys/{name}` — 获取密钥详情
- `DELETE /keys/{name}` — 删除密钥
- `GET /keys/{name}/info` — 获取密钥元信息

**数据模型：**
- `DeployRequest` — 下装请求（sasm_file, target, key_hex, download_at, health_cycles）
- `DeployResponse` — 下装响应（success, stages, status_frames, errors, target）
- `KeyGenerateRequest` — 密钥生成请求（name）
- `KeyResponse` — 密钥响应（name, key_hex, exists）
- `KeyListResponse` — 密钥列表响应（keys）
- `KeyInfoResponse` — 密钥信息响应（name, created_at, size）

### 3. 测试验证

**浏览器集成测试（browser-use MCP）：**
- ✅ 步骤 1：填写目标路径（.sasm 文件）
- ✅ 步骤 2：加载密钥列表（从 API）
- ✅ 步骤 2：选择密钥（test_key）
- ✅ 步骤 3：配置下装参数（默认值）
- ✅ 步骤 4：执行下装（调用 POST /deploy）
- ✅ 步骤 5：显示完成结果

**后端单元测试：**
- ✅ 26 项测试全部通过（test_key_manager.py: 13 项 + test_deploy_service.py: 13 项）

## 技术决策

### D1: 密钥名 vs 密钥 hex
- **问题**：前端下拉框显示密钥名，但 API 需要 hex 密钥
- **方案**：选择密钥名后，调用 GET /keys/{name} 获取 hex 值
- **理由**：用户体验更好（显示可读名称），同时满足 API 要求

### D2: 异步部署流程
- **问题**：部署是长时间操作，需要进度反馈
- **方案**：使用 async/await + 进度条 + 状态日志
- **理由**：用户可实时看到部署进度和状态

## 已知限制

1. **后端依赖**：需要安装 Python 依赖（fastapi, uvicorn）才能运行 API 服务器
   - 解决方案：`cd veri-ide && source .venv/bin/activate && python3 -m pip install -e .`
   
2. **真实部署**：当前部署到文件后端（生成帧流文件），未连接真实 agent
   - 后续 G4 阶段将集成真实目标端

3. **密钥管理 UI**：密钥管理功能通过向导集成，无独立管理页面
   - 可在后续版本添加独立密钥管理界面

## 测试命令

```bash
# 启动后端 API 服务器
cd veri-ide
source .venv/bin/activate
python3 -m uvicorn src.veri_ide.api.server:app --host 127.0.0.1 --port 8000

# 启动前端服务器
cd frontend/public
python3 -m http.server 8080

# 运行单元测试
python3 -m pytest tests/test_key_manager.py tests/test_deploy_service.py -v

# 访问下装向导
# http://localhost:8080/download-wizard.html
```

## 下一步

- G4 W3: 集成真实目标端（veristc-agent）
- G4 W4: 下装结果可视化 + 回滚演示
- G5: 算法块库管理
