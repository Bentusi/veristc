---
name: phase6-g3-technical-plan
description: 'Phase 6 G3 仿真验证的详细技术方案。当实现 sim-svc、波形视图、基线管理、偏差检测时必读。含 3 项已定决策与协议定义。'
---

# Phase 6 G3 — 仿真验证详细技术方案

本文是 `phase6-veriide.prompt.md` 中「G3 仿真验证」的实施级设计。G3 的验收总目标：
**工程站能执行仿真并显示波形，支持基线对比与偏差检测**。

## 0. 已定决策（本文其余部分的前提，勿在实现时重开）

| # | 决策 | 后果 |
|---|------|------|
| **D1** | 复用 G0 仿真后端（`veri-runtime/sim/`），不重新实现 | `sim` 主程序已实现 8 个接口 + `.plant` 被控对象 + watch 帧，工程站只消费 |
| **D2** | 首期只做**干跑模式**（无 I/O 逻辑级），孪生模式推 G3.5 | 孪生模式需要 plant 模型配置，首期不触碰；干跑已足够验证逻辑 |
| **D3** | 波形视图用 **SVG/Canvas**，不引入第三方图表库 | 避免依赖膨胀，SVG 足够表达周期级波形 |

## 1. 现状核查结论

### 1.1 G0 已交付能力

| 能力 | 路径 | 状态 |
|------|------|------|
| 仿真后端 | `veri-runtime/sim/` | ✅ 已实现 |
| sim 主程序 | `veri-runtime/sim/sim_main.c` | ✅ 已实现 |
| .plant 解析 | `veri-runtime/sim/plant.c` | ✅ 已实现 |
| watch 帧 | `veri-runtime/sim/watch.c` | ✅ 已实现 |
| 黄金时间线 | `integration/run_sim_e2e.sh` | ✅ 已验证 |

### 1.2 G3 需要新增能力

| 能力 | 说明 |
|------|------|
| sim-svc | 工程站仿真服务（调用 sim 主程序） |
| 波形视图 | 前端显示变量随周期变化 |
| 基线管理 | 保存/加载黄金时间线 |
| 偏差检测 | 对比当前仿真与基线 |
| 偏差回指 | 定位到具体块/周期 |

## 2. sim-svc 设计

### 2.1 职责

- 接收仿真请求（ST 代码 + 周期数 + 变量列表）
- 调用 `sim` 主程序执行仿真
- 解析 watch 帧（JSONL）
- 返回波形数据

### 2.2 接口

```python
class SimService:
    def run_simulation(
        st_code: str,
        cycles: int,
        watch_vars: list[str],
        plant_file: str | None = None
    ) -> SimulationResult:
        """
        执行仿真
        
        Args:
            st_code: ST 代码
            cycles: 仿真周期数
            watch_vars: 监视变量列表
            plant_file: .plant 文件路径（孪生模式）
        
        Returns:
            SimulationResult: 包含波形数据
        """
```

### 2.3 实现

```python
@dataclass
class SimulationResult:
    success: bool
    waveforms: dict[str, list[float]]  # 变量名 → 数值序列
    cycles: int
    errors: list[str]
```

## 3. 波形视图设计

### 3.1 数据格式

```json
{
  "cycles": 12,
  "variables": {
    "pid1.OUT": [0, 10, 20, 30, 40, 50, 60, 70, 80, 90, 100, 100],
    "limiter1.OUT": [0, 10, 20, 30, 40, 50, 60, 70, 80, 90, 100, 100]
  }
}
```

### 3.2 SVG 渲染

```
周期  0  1  2  3  4  5  6  7  8  9  10 11
     ┌────────────────────────────────────┐
pid1 │  ┌──────────────────────────────┐  │
     │  │                              │  │
     └──┘                              └──┘
```

### 3.3 交互

- 鼠标悬停显示周期 + 数值
- 点击波形定位到周期
- 缩放/平移时间轴

## 4. 基线管理设计

### 4.1 基线格式

```json
{
  "name": "pid_control_baseline",
  "cycles": 12,
  "variables": {
    "pid1.OUT": [0, 10, 20, 30, 40, 50, 60, 70, 80, 90, 100, 100]
  },
  "created": "2026-10-29T10:00:00Z",
  "description": "PID 控制器黄金时间线"
}
```

### 4.2 基线存储

```
sim/baselines/
├── pid_control_baseline.json
├── rs_latch_baseline.json
└── ...
```

### 4.3 基线操作

- 保存当前仿真为基线
- 加载基线进行对比
- 删除基线
- 列出所有基线

## 5. 偏差检测设计

### 5.1 偏差计算

```python
def compute_deviation(current: list[float], baseline: list[float]) -> list[float]:
    """计算逐周期偏差"""
    return [abs(c - b) for c, b in zip(current, baseline)]

def find_max_deviation(deviations: list[float]) -> tuple[int, float]:
    """找到最大偏差周期"""
    max_idx = max(range(len(deviations)), key=lambda i: deviations[i])
    return max_idx, deviations[max_idx]
```

### 5.2 偏差阈值

- 默认阈值：0.0（严格匹配）
- 可配置阈值：允许浮点误差
- 超阈值标记为红色

### 5.3 偏差回指

- 点击偏差点定位到周期
- 显示该周期的块状态
- 高亮产生偏差的块

## 6. 实现计划

### W1（2 周）：sim-svc + 波形视图

- 实现 `SimService` 类
- 实现波形 SVG 渲染
- 编写 10 项测试

### W2（2 周）：基线管理 + 偏差检测

- 实现基线保存/加载
- 实现偏差计算
- 实现偏差可视化
- 编写 10 项测试

**验收标准**：
- 仿真执行成功（干跑模式）
- 波形视图正确显示
- 基线保存/加载正常
- 偏差检测准确

## 7. 与 G0 的关系

G3 复用 G0 的基础设施：
- `veri-runtime/sim/sim_main.c`：仿真执行
- `veri-runtime/sim/watch.c`：watch 帧输出
- `veri-runtime/sim/plant.c`：被控对象（孪生模式）

G3 新增：
- `src/veri_ide/backend/sim/service.py`：sim-svc
- `frontend/public/waveform-viewer.html`：波形视图
- `src/veri_ide/backend/sim/baseline.py`：基线管理

## 8. 后续扩展（G3.5）

- **孪生模式**：plant 模型配置 + 真实 I/O 仿真
- **多变量对比**：同时显示多个变量波形
- **统计信息**：均值/方差/峰值/稳态时间
- **导出报告**：PDF/HTML 仿真报告
