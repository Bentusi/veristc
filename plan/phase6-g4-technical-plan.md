---
name: phase6-g4-technical-plan
description: 'Phase 6 G4 下装运行的详细技术方案。当实现 deploy-svc、下装向导、密钥管理时必读。'
---

# Phase 6 G4 — 下装运行详细技术方案

本文是 `phase6-veriide.prompt.md` 中「G4 下装运行」的实施级设计。G4 的验收总目标：
**工程站能把 .sasm 制品安全下装到目标端并监控运行状态**。

## 0. 已定决策（本文其余部分的前提，勿在实现时重开）

| # | 决策 | 后果 |
|---|------|------|
| **D1** | 复用 G0 下装后端（`veri-runtime/hotstandby/` + `integration/dl_frames.py`），不重新实现 | 帧协议/版本槽/周期边界切换/回滚已实现并验证（34 项 e2e 测试） |
| **D2** | 首期只做**文件/管道后端**，UDS/TCP 推到后续 | `DlStream` 抽象已解耦协议与链路，后续扩展不破坏接口 |
| **D3** | 密钥管理用**本地文件存储**（加密），真签名/密钥轮换推到后续 | 首期共享密钥静态注入，密钥文件权限 0600 |

## 1. 现状核查结论

### 1.1 G0 已交付能力

| 能力 | 路径 | 状态 |
|------|------|------|
| 帧协议 | `integration/dl_frames.py` | ✅ 已实现（Python 参考发送端） |
| 接收状态机 | `veri-runtime/hotstandby/download_wire.c` | ✅ 已实现（10 类拒绝码） |
| 版本槽/切换/回滚 | `veri-runtime/hotstandby/download.c` | ✅ 已实现 |
| 目标端 agent | `veri-runtime/agent/agent_main.c` | ✅ 已实现 |
| 端到端测试 | `integration/run_download_e2e.sh` | ✅ 已验证（34 项） |

### 1.2 G4 需要新增能力

| 能力 | 说明 |
|------|------|
| deploy-svc | 工程站下装服务（调用 dl_frames.py + 管道/文件发送） |
| 密钥管理 | 生成/存储/注入 HMAC-SHA256 密钥 |
| 下装向导 | 前端 UI：目标配置 + 密钥选择 + 进度显示 + 状态监控 |
| 状态监控 | 解析 agent 状态帧（JSONL）并展示 |

## 2. deploy-svc 设计

### 2.1 职责

- 接收下装请求（.sasm 文件 + 目标配置 + 密钥）
- 调用 `dl_frames.py` 生成帧流
- 通过管道/文件发送到目标端
- 解析 agent 状态帧并返回进度

### 2.2 接口

```python
class DeployService:
    def deploy(
        sasm_file: str,
        target: TargetConfig,
        key: bytes,
        download_at: int = 1,
        health_cycles: int = 3,
    ) -> DeployResult:
        """
        执行下装
        
        Args:
            sasm_file: .sasm 文件路径
            target: 目标配置（管道/文件路径）
            key: 32 字节 HMAC 密钥
            download_at: 第 N 个周期边界落地
            health_cycles: 健康检查周期数
        
        Returns:
            DeployResult: 包含进度/状态/错误
        """
```

### 2.3 实现

```python
@dataclass
class DeployResult:
    success: bool
    stages: list[str]  # 进度阶段
    status_frames: list[dict]  # agent 状态帧
    errors: list[str]
```

## 3. 密钥管理设计

### 3.1 密钥格式

- 32 字节随机密钥（HMAC-SHA256）
- 存储为 64 字符 hex 字符串
- 文件权限 0600

### 3.2 密钥存储

```
~/.veride/keys/
├── default.key
├── production.key
└── ...
```

### 3.3 密钥操作

- 生成新密钥
- 列出所有密钥
- 加载指定密钥
- 删除密钥

## 4. 下装向导设计

### 4.1 步骤

1. **目标配置**：选择管道/文件路径
2. **密钥选择**：选择或生成 HMAC 密钥
3. **下装参数**：download_at / health_cycles
4. **执行下装**：显示进度条 + 状态帧
5. **完成/回滚**：显示结果

### 4.2 状态监控

解析 agent 状态帧（JSONL）：
- `start`：首装完成
- `download_begin`：开始吸收帧流
- `download_staged`：镜像收满
- `download_rejected`：拒绝
- `switch`：切换成功
- `switch_failed`：切换失败
- `health_ok`：健康检查通过
- `rollback`：回滚
- `end`：周期循环结束

## 5. 实现计划

### W1（2 周）：deploy-svc + 密钥管理

- 实现 `DeployService` 类
- 实现 `KeyManager` 类
- 编写 10 项测试

### W2（2 周）：前端下装向导

- 实现下装向导 UI（5 步骤）
- 实现状态监控面板
- 编写集成测试

**验收标准**：
- 下装执行成功（文件/管道后端）
- 密钥生成/存储正常
- 状态帧解析正确
- 进度显示准确

## 6. 与 G0 的关系

G4 复用 G0 的基础设施：
- `integration/dl_frames.py`：帧流生成
- `veri-runtime/hotstandby/download_wire.c`：接收状态机
- `veri-runtime/hotstandby/download.c`：版本槽/切换/回滚
- `veri-runtime/agent/agent_main.c`：目标端服务

G4 新增：
- `src/veri_ide/backend/deploy/service.py`：deploy-svc
- `src/veri_ide/backend/deploy/key_manager.py`：密钥管理
- `frontend/public/download-wizard.html`：下装向导

## 7. 后续扩展

- **UDS/TCP 传输**：替换管道/文件后端
- **真签名/密钥轮换**：非对称加密 + 证书链
- **增量补丁下装**：diff/patch 机制
- **重传/断点续传**：序号缺口恢复
- **备站下装**：主备同步传输
