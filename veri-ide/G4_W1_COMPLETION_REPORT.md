# G4 W1 完成报告

**日期**：2026-10-29  
**状态**：✅ 完成

## 交付物

### 1. DeployService 下装服务

**文件**：`src/veri_ide/backend/deploy/service.py`

- `TargetConfig` 数据类：目标配置（backend, path, agent_binary, cycles, period_ms, role, node_id）
- `DeployResult` 数据类：下装结果（success, stages, status_frames, errors）
- `DeployService` 服务类：
  - `deploy()`：执行下装（.sasm + 目标 + 密钥 → DeployResult）
  - `_generate_frames()`：调用 dl_frames.py 生成帧流
  - `_send_via_file()`：文件后端发送
  - `_send_via_pipe()`：管道后端发送
  - `_parse_status_frames()`：解析 agent 状态帧（JSONL）

**测试**：13 项（test_deploy_service.py）

### 2. 密钥管理服务

**文件**：`src/veri_ide/backend/deploy/key_manager.py`

- `KeyManager` 服务类：
  - `generate_key()`：生成 32 字节随机密钥（64 字符 hex）
  - `load_key()` / `load_key_hex()`：加载密钥
  - `delete_key()`：删除密钥
  - `list_keys()`：列出所有密钥
  - `key_exists()`：检查密钥是否存在
  - `get_key_info()`：获取密钥元数据

**存储**：`~/.veride/keys/` 目录，文件权限 0600，目录权限 0700

**测试**：13 项（test_key_manager.py）

### 3. 下装向导 UI

**文件**：`frontend/public/download-wizard.html`

- **5 步骤向导**：
  1. 目标配置（后端类型/路径/agent/角色/节点 ID）
  2. 密钥选择（下拉选择或手动输入）
  3. 下装参数（周期数/周期时长/切换周期/健康检查）
  4. 执行下装（进度条 + 状态日志）
  5. 完成（结果面板）

- **功能**：
  - 步骤导航（上一步/下一步/点击跳转）
  - 进度显示（7 阶段进度条）
  - 状态日志（实时滚动）
  - 重置向导

**测试**：浏览器手动验证

## 测试结果

```
163 passed, 1 failed (pre-existing), 2 warnings
```

- G1：45 项
- G2：36 项
- G3：24 项
- G3.5：32 项
- G4：26 项（新增）

失败的 1 项是 `test_build_service.py::test_build_project_integration`，与本次变更无关（veristc 路径问题）。

## 技术要点

### 复用 G0 基础设施

- `integration/dl_frames.py`：帧流生成（Python 参考发送端）
- `veri-runtime/hotstandby/download_wire.c`：接收状态机（10 类拒绝码）
- `veri-runtime/hotstandby/download.c`：版本槽/切换/回滚
- `veri-runtime/agent/agent_main.c`：目标端服务

### 下装流程

```
.sasm 文件
  ↓ dl_frames.py --key HEX
帧流 (frames.bin)
  ↓ cat frames.bin | veristc-agent --download-from -
目标端接收
  ↓ 状态帧 (JSONL)
进度监控
```

### 密钥管理

- 32 字节随机密钥（`secrets.token_bytes(32)`）
- 存储为 64 字符 hex 字符串
- 文件权限 0600（仅所有者读写）
- 目录权限 0700（仅所有者访问）

## 后续工作（G4 W2）

- 前端下装向导与后端 API 集成
- 实时状态帧监控（WebSocket）
- 密钥管理 UI
- 下装历史记录

## 回归验证

G0 回归测试：11/11 通过（未触碰 veri-stc/veri-runtime 代码）
