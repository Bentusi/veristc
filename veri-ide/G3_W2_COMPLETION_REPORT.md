# G3 W2 完成报告 — 基线管理 + 偏差检测

**完成时间**: 2026-10-29  
**测试覆盖**: 14 项新增基线管理测试  
**累计测试**: 105 项全绿  
**验收状态**: ✅ 全部通过

---

## 交付物清单

### 1. 基线管理服务

**文件**: `src/veri_ide/backend/sim/baseline.py`

- `Baseline` 数据类：基线数据
- `BaselineManager` 类：基线管理服务
- `save_baseline()`：保存基线到文件
- `load_baseline()`：从文件加载基线
- `delete_baseline()`：删除基线
- `list_baselines()`：列出所有基线
- `compute_deviation()`：计算偏差
- `find_max_deviation()`：找到最大偏差
- `check_threshold()`：检查阈值

**关键实现**:
```python
class BaselineManager:
    def compute_deviation(
        self,
        current: dict[str, list[float]],
        baseline: dict[str, list[float]],
    ) -> dict[str, list[float]]:
        """计算逐周期偏差"""
        return {
            var: [abs(c - b) for c, b in zip(current[var], baseline[var])]
            for var in current if var in baseline
        }

    def check_threshold(
        self,
        deviations: dict[str, list[float]],
        threshold: float,
    ) -> dict[str, list[bool]]:
        """检查是否超阈值"""
        return {
            var: [d > threshold for d in deviation]
            for var, deviation in deviations.items()
        }
```

### 2. 测试套件

**文件**: `tests/test_baseline.py`（14 项测试）

| 测试 | 内容 |
|------|------|
| `test_save_baseline` | 保存基线到文件 |
| `test_load_baseline` | 从文件加载基线 |
| `test_load_baseline_not_found` | 加载不存在的基线 |
| `test_delete_baseline` | 删除基线 |
| `test_delete_baseline_not_found` | 删除不存在的基线 |
| `test_list_baselines` | 列出所有基线 |
| `test_list_baselines_empty` | 列出空基线列表 |
| `test_compute_deviation` | 计算偏差 |
| `test_compute_deviation_missing_var` | 计算偏差（缺失变量） |
| `test_find_max_deviation` | 找到最大偏差 |
| `test_find_max_deviation_empty` | 找到最大偏差（空数据） |
| `test_check_threshold` | 检查阈值 |
| `test_check_threshold_zero` | 检查零阈值（严格匹配） |
| `test_baseline_dataclass` | Baseline 数据类 |

---

## 技术决策

### D1: 服务器端基线存储

**理由**:
- W1 使用 localStorage（浏览器端），不持久化
- W2 改为服务器端文件存储（JSON 文件）
- 支持跨浏览器访问
- 支持团队协作

### D2: 偏差计算策略

**理由**:
- 逐周期计算绝对偏差
- 支持变量级偏差分析
- 支持阈值检查
- 支持最大偏差定位

### D3: 阈值可配置

**理由**:
- 默认阈值 0.0（严格匹配）
- 可配置阈值（允许浮点误差）
- 超阈值标记为红色（前端实现）

---

## 验收标准

### ✅ 功能验收

1. **基线保存**: 保存到服务器端 JSON 文件
2. **基线加载**: 从文件加载基线
3. **基线删除**: 删除基线文件
4. **基线列表**: 列出所有基线名称
5. **偏差计算**: 逐周期计算绝对偏差
6. **最大偏差**: 找到最大偏差周期
7. **阈值检查**: 检查是否超阈值

### ✅ 测试验收

```bash
$ pytest tests/test_baseline.py -v
======================== 14 passed in 0.05s =========================
```

### ✅ 集成验收

```bash
$ pytest tests/ -v
======================== 105 passed in 1.09s ========================
```

---

## 使用示例

### 1. 保存基线

```python
from veri_ide.backend.sim.baseline import BaselineManager

manager = BaselineManager("/path/to/baselines")

baseline = manager.save_baseline(
    name="pid_control_baseline",
    cycles=12,
    variables={
        "pid1.OUT": [0, 10, 20, 30, 40, 50, 60, 70, 80, 90, 100, 100],
    },
    description="PID 控制器黄金时间线",
)
```

### 2. 加载基线

```python
baseline = manager.load_baseline("pid_control_baseline")
if baseline:
    print(f"Loaded: {baseline.name}")
    print(f"Cycles: {baseline.cycles}")
```

### 3. 计算偏差

```python
current = {
    "pid1.OUT": [0, 10, 22, 28, 42, 48, 62, 68, 82, 88, 102, 98],
}
baseline_vars = {
    "pid1.OUT": [0, 10, 20, 30, 40, 50, 60, 70, 80, 90, 100, 100],
}

deviations = manager.compute_deviation(current, baseline_vars)
# deviations["pid1.OUT"] = [0, 0, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2]
```

### 4. 找到最大偏差

```python
max_deviations = manager.find_max_deviation(deviations)
# max_deviations["pid1.OUT"] = (2, 2.0)  # 周期 2，偏差 2.0
```

### 5. 检查阈值

```python
exceeds = manager.check_threshold(deviations, threshold=1.5)
# exceeds["pid1.OUT"] = [False, False, True, True, True, True, True, True, True, True, True, True]
```

---

## 架构集成

```
前端波形视图 (waveform-viewer.html)
  ↓ 保存基线请求
sim-svc (service.py)
  ↓ 调用 BaselineManager
baseline.py
  ↓ 保存到 JSON 文件
sim/baselines/
  ↓ 加载基线
  ↓ 计算偏差
  ↓ 返回偏差数据
前端波形视图
  ↓ 偏差可视化（红色标记超阈值点）
```

---

## 已知限制

1. **文件存储**: 基线存储为 JSON 文件，不支持数据库
2. **无版本控制**: 基线覆盖时不保留历史版本
3. **无权限控制**: 任何用户都可删除基线
4. **单变量偏差**: 不支持多变量联合偏差分析

---

## 后续工作（G3.5）

### 孪生模式

- plant 模型配置
- 真实 I/O 仿真
- 硬件在环测试

### 高级分析

- 多变量对比
- 统计信息（均值/方差/峰值/稳态时间）
- 频域分析
- 导出报告（PDF/HTML）

---

## 里程碑总结

**G3 仿真验证**（W1-W2）完成：

| 工作包 | 内容 | 测试数 | 状态 |
|--------|------|--------|------|
| W1 | sim-svc + 波形视图 | 10 | ✅ |
| W2 | 基线管理 + 偏差检测 | 14 | ✅ |
| **总计** | — | **24** | ✅ |

**累计测试**: 105 项（G1: 45 + G2: 36 + G3: 24）

**验收标准**:
- ✅ sim-svc 仿真服务
- ✅ SVG 波形视图
- ✅ 基线保存/加载/删除
- ✅ 偏差计算
- ✅ 阈值检查

**下一步**: G4 下装运行
