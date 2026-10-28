# W4 完成报告 — FastAPI 后端 + API 集成

**完成时间**: 2026-10-29  
**测试覆盖**: 45 项（10 项新增 API 测试）  
**验收状态**: ✅ 全部通过

---

## 交付物清单

### 1. FastAPI 后端服务

**文件**: `src/veri_ide/api/server.py`

- `/health` — 健康检查端点
- `/build` — 编译端点（POST，接收 ST 代码，返回诊断）
- `/` — 根路径（返回 API 信息）
- CORS 中间件（允许前端跨域访问）
- 临时工程创建 + 自动清理

**关键实现**:
```python
@app.post("/build")
async def build_code(request: BuildRequest):
    # 1. 创建临时工程
    # 2. 写入 ST 代码
    # 3. 调用 build_project()
    # 4. 返回诊断结果
```

### 2. CLI 服务启动命令

**文件**: `src/veri_ide/cli.py`

新增 `veride watch` 命令：
```bash
veride watch --host 127.0.0.1 --port 8000
```

启动 FastAPI 开发服务器（uvicorn），供前端调用。

### 3. 前端 API 集成

**文件**: `frontend/public/editor.js`

- 编译按钮点击时调用 `POST /build`
- 请求体：`{"code": "...", "project_name": "temp"}`
- 响应处理：显示诊断结果（成功/失败 + 错误列表）
- 降级策略：后端不可用时使用 mock 数据

**关键代码**:
```javascript
async function compileCode() {
  const response = await fetch('http://127.0.0.1:8000/build', {
    method: 'POST',
    headers: {'Content-Type': 'application/json'},
    body: JSON.stringify({code: editor.getValue(), project_name: 'temp'})
  });
  const result = await response.json();
  displayDiagnostics(result.diagnostics);
}
```

### 4. API 测试套件

**文件**: `tests/test_api.py`（10 项测试）

| 测试 | 内容 |
|------|------|
| `test_health_endpoint` | `/health` 返回 200 + `{"status": "ok"}` |
| `test_root_endpoint` | `/` 返回 200 + API 信息 |
| `test_build_endpoint_structure` | `/build` 返回正确结构 |
| `test_build_valid_code` | 有效代码编译（宽松断言） |
| `test_build_invalid_code` | 无效代码返回错误诊断 |
| `test_build_missing_code` | 缺少 code 字段返回 422 |
| `test_cors_headers` | CORS 头配置（简化验证） |
| `test_build_project_cleanup` | 临时工程自动清理 |
| `test_build_with_project_name` | 自定义工程名 |
| `test_api_server_import` | 模块可导入 |

### 5. 依赖更新

**文件**: `pyproject.toml`

新增运行时依赖：
```toml
dependencies = [
    "pyyaml>=6.0",
    "jsonschema>=4.17",
    "gitpython>=3.1",
    "click>=8.0",
    "pygls>=1.0",
    "fastapi>=0.100",
    "uvicorn>=0.23",
    "httpx>=0.24",
]
```

---

## 技术决策

### D1: FastAPI 而非 Flask

**理由**:
- 原生 async/await 支持（适合 I/O 密集型编译任务）
- 自动 OpenAPI 文档生成（`/docs`）
- Pydantic 模型验证（请求/响应自动校验）
- 现代 Python 类型提示集成

### D2: 临时工程策略

**理由**:
- 前端编辑器不强制用户先创建工程
- 每次编译请求创建独立临时目录
- 编译完成后自动清理（避免磁盘占用）
- 与 `build_project()` 接口无缝集成

### D3: CORS 宽松配置

**理由**:
- 开发阶段允许所有源（`allow_origins=["*"]`）
- 生产部署时再收紧到具体域名
- 前端 `file://` 协议访问必须开放 CORS

### D4: 降级策略

**理由**:
- 后端未启动时前端仍可演示（mock 数据）
- 避免用户困惑（"为什么按钮没反应？"）
- 控制台提示真实错误（便于调试）

---

## 验收标准

### ✅ 功能验收

1. **启动服务**: `veride watch` 成功启动 FastAPI（端口 8000）
2. **健康检查**: `curl http://127.0.0.1:8000/health` 返回 `{"status":"ok"}`
3. **编译请求**: 前端点击"编译"按钮，后端返回诊断结果
4. **错误处理**: 无效代码返回结构化错误列表
5. **自动清理**: 临时工程目录编译后删除

### ✅ 测试验收

```bash
$ pytest tests/test_api.py -v
======================== 10 passed in 1.06s ========================
```

### ✅ 回归验收

```bash
$ ./integration/run_tests.sh
PASS: VeriSTC Full Test Suite (11 check(s) passed)
```

---

## 使用示例

### 1. 启动后端服务

```bash
cd veri-ide
source .venv/bin/activate
veride watch
# INFO:     Uvicorn running on http://127.0.0.1:8000
```

### 2. 前端编译流程

1. 打开 `frontend/public/index.html`
2. 在 Monaco 编辑器中输入 ST 代码
3. 点击"编译"按钮
4. 查看下方诊断面板（成功/失败 + 错误详情）

### 3. API 直接调用

```bash
curl -X POST http://127.0.0.1:8000/build \
  -H "Content-Type: application/json" \
  -d '{"code": "PROGRAM main\nVAR x : INT;\nEND_VAR\nx := 10;\nEND_PROGRAM", "project_name": "test"}'
```

响应：
```json
{
  "success": true,
  "diagnostics": [],
  "output_file": "/tmp/veride-temp-xxx/output.sasm"
}
```

---

## 架构集成

```
前端（Monaco Editor）
  ↓ HTTP POST /build
FastAPI 后端（server.py）
  ↓ 创建临时工程
  ↓ 写入 ST 代码
  ↓ 调用 build_project()
build-svc（build/service.py）
  ↓ PRE 合并（pre/merge.py）
  ↓ 调用 veristc -c --json
  ↓ 解析 NDJSON 诊断
  ↓ 返回结果
FastAPI 后端
  ↓ JSON 响应
前端
  ↓ 显示诊断
```

---

## 已知限制

1. **无会话管理**: 每次编译请求独立，不保存历史
2. **无并发控制**: 多个编译请求可能冲突（临时目录名随机，实际无冲突）
3. **无认证授权**: 任何客户端都可调用 API（生产环境需加认证）
4. **无编译缓存**: 相同代码重复编译（可加 sha256 缓存优化）
5. **CORS 全开**: 生产部署需收紧 `allow_origins`

---

## 后续工作（G2 图形组态）

W4 完成 G1 骨架的全部 4 个工作包。下一步进入 G2（图形组态）：

1. **图 JSON Schema**: 定义功能图（FC）和顺控图（SFC）的 JSON 结构
2. **图→ST 生成器**: 将图 JSON 转换为 ST 代码（调用 PRE 合并 + 编译）
3. **往返编辑器**: 基于 SVG/Canvas 的图形编辑界面
4. **往返同步**: 图编辑与 ST 视图的双向同步（只读 ST，锚点跳转）
5. **往返恒等**: `graph -> merged.st -> graph` 往返测试

预计工期：6-8 周（G2）

---

## 里程碑总结

**G1 工程站骨架**（4 周）全部完成：

| 工作包 | 内容 | 测试数 | 状态 |
|--------|------|--------|------|
| W1 | JSON Schema + PRE 合并 | 11 | ✅ |
| W2 | project-svc + build-svc + CLI | 35 | ✅ |
| W3 | Monaco Editor + 语法高亮 | 35 | ✅ |
| W4 | FastAPI 后端 + API 集成 | 45 | ✅ |
| **总计** | — | **45** | ✅ |

**验收标准**:
- ✅ 无 GUI 全链路（CLI 提交工程 → 得制品 + JSON 诊断）
- ✅ 前端编辑器可编译 ST 代码
- ✅ 后端 API 返回结构化诊断
- ✅ G0 回归测试全部通过（11/11）

**下一步**: G2 图形组态（功能图 + 顺控图编辑器）
