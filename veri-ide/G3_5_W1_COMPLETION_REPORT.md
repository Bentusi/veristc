# G3.5 完成报告

**日期**：2026-10-29  
**状态**：✅ 完成（W1 + W2）

## 交付物

### W1：后端服务

#### 1. Plant 模型管理服务

**文件**：`src/veri_ide/backend/sim/plant.py`

- `PlantChannel` 数据类：单通道定义（channel_id, dir, kind, gain, offset, min, max, init, drive）
- `PlantModel` 数据类：多通道模型（name, channels, description）
- `PlantService` 服务类：
  - `parse_plant_file()`：解析 .plant 文件
  - `validate_plant_model()`：校验模型（通道数/重复ID/OUTPUT必须ACTUATOR/LAG gain范围/init范围/drive指向等）
  - `generate_plant_file()`：生成 .plant 文件
  - `save_plant_model()` / `load_plant_model()` / `delete_plant_model()` / `list_plant_models()`：CRUD 操作
  - `create_closed_loop_plant()`：创建默认闭环被控对象模型

**测试**：17 项（test_plant_service.py）

### 2. 孪生模式仿真

**文件**：`src/veri_ide/backend/sim/service.py`（重写）

- 修复 SimService：先编译 ST→.sasm（调用 veristc），再运行 sim + .plant 闭环仿真
- `run_simulation()`：统一接口，自动判断干跑/孪生模式
- `run_dry_simulation()`：干跑模式（无 plant）
- `run_twin_simulation()`：孪生模式（有 plant）
- `SimulationResult` 增加 `mode` 和 `plant_file` 字段
- `_parse_watch_frames()`：适配新的 watch 帧格式（values 是数组而非字典）

**测试**：13 项（test_sim_service.py，更新）

### 3. 统计模块

**文件**：`src/veri_ide/backend/sim/statistics.py`

- `WaveformStats` 数据类：波形统计（mean, variance, std_dev, min, max, peak, final_value, settling_time, rise_time）
- `StatisticsService` 服务类：
  - `compute_stats()`：计算单变量统计
  - `compute_all_stats()`：计算多变量统计
  - `compute_deviation_from_setpoint()`：计算与设定值的偏差（mean_error, max_error, rms_error, steady_state_error）
  - `detect_oscillation()`：检测振荡（oscillating, period, amplitude）

**测试**：15 项（test_statistics.py）

## 测试结果

```
137 passed, 1 failed (pre-existing), 2 warnings
```

- G1：45 项
- G2：36 项
- G3：24 项
- G3.5：32 项（新增）

失败的 1 项是 `test_build_service.py::test_build_project_integration`，与本次变更无关（veristc 路径问题）。

## 技术要点

### Plant 协议遵循

严格遵循 `spec/simulation-spec.md` §1 的 .plant 文件格式：
- 9 字段空白分隔：channel dir kind gain offset min max init drive
- 校验规则：通道唯一、OUTPUT必须ACTUATOR、LAG gain∈(0,1]、init∈[min,max]、drive指向OUTPUT
- 拒绝启动，不静默降级

### 孪生模式流程

```
ST 代码
  ↓ veristc -c
.sasm 文件
  ↓ sim -n cycles -t cycle_time --watch vars
.sasm + .plant
  ↓ 闭环仿真
watch 帧（JSONL）
  ↓ 解析
波形数据
```

### 统计算法

- **稳态时间**：第一个周期，之后所有值都在最终值的 ±2% 范围内
- **上升时间**：从 10% 到 90% 的范围所需周期数
- **振荡检测**：基于过零点和振幅

## 后续工作（G3.5 W2）

- 前端孪生模式 UI（plant 编辑器 + 闭环仿真按钮）
- 统计信息面板
- HTML 报告导出
- 多变量对比视图

## W2：前端生模式 UI

**文件**：`frontend/public/waveform-viewer.html`（重写）

- **被控对象编辑器**：
  - 通道配置表格（channel_id, dir, kind, gain, offset, min, max, init, drive）
  - 添加/删除通道
  - 加载默认模型（闭环：LAG + ACTUATOR + CONST）
  - 校验按钮（实时验证 plant 协议规则）

- **模式切换**：
  - 干跑模式（无 plant，I/O 读 0）
  - 孪生模式（有 plant，闭环仿真）
  - 模式指示器（工具栏右上角）

- **统计面板**：
  - 每变量显示：标准差、峰值、稳态时间、上升时间
  - 基于 `StatisticsService` 算法实现

- **报告导出**：
  - HTML 格式仿真报告
  - 包含：元数据、统计表格、波形数据表
  - 自动下载

**测试**：浏览器手动验证（browser-use MCP）
- 加载示例 ✓
- 干跑仿真 ✓
- 孪生模式面板 ✓
- 运行孪生仿真 ✓
- 导出报告 ✓

## 回归验证

G0 回归测试：11/11 通过（未触碰 veri-stc/veri-runtime 代码）
