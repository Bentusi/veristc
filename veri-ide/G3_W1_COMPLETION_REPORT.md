# G3 W1 完成报告 — sim-svc + 波形视图

**完成时间**: 2026-10-29  
**测试覆盖**: 10 项新增 sim-svc 测试  
**累计测试**: 91 项全绿  
**验收状态**: ✅ 全部通过

---

## 交付物清单

### 1. sim-svc 仿真服务

**文件**: `src/veri_ide/backend/sim/service.py`

- `SimService` 类：仿真服务
- `SimulationResult` 数据类：仿真结果
- `run_simulation()`：执行仿真
- `_parse_watch_frames()`：解析 watch 帧（JSONL）
- `_find_sim_binary()`：查找 sim 二进制

**关键实现**:
```python
class SimService:
    def run_simulation(
        self,
        st_code: str,
        cycles: int,
        watch_vars: list[str],
        plant_file: str | None = None,
    ) -> SimulationResult:
        # 1. 创建临时目录
        # 2. 写入 ST 代码
        # 3. 调用 sim 主程序
        # 4. 解析 watch 帧
        # 5. 返回波形数据
```

### 2. 波形视图

**文件**: `frontend/public/waveform-viewer.html`

- SVG 波形渲染
- 鼠标悬停显示周期 + 数值
- 基线对比（虚线显示）
- 统计信息（min/max/avg）
- 基线保存/加载（localStorage）

**关键功能**:
- 加载示例波形
- 运行仿真（调用后端 API）
- 保存基线
- 加载基线
- 清空波形

### 3. 测试套件

**文件**: `tests/test_sim_service.py`（10 项测试）

| 测试 | 内容 |
|------|------|
| `test_sim_service_init` | SimService 初始化 |
| `test_parse_watch_frames_empty` | 空 watch 帧 |
| `test_parse_watch_frames_single` | 单个 watch 帧 |
| `test_parse_watch_frames_multiple` | 多个 watch 帧 |
| `test_parse_watch_frames_skip_non_cycle` | 跳过非周期帧 |
| `test_parse_watch_frames_malformed` | 处理 malformed JSON |
| `test_parse_watch_frames_missing_var` | 处理缺失变量 |
| `test_simulation_result_dataclass` | SimulationResult 数据类 |
| `test_simulation_result_failure` | 仿真失败情况 |
| `test_find_sim_binary_not_found` | sim 二进制未找到 |

---

## 技术决策

### D1: 复用 G0 仿真后端

**理由**:
- `veri-runtime/sim/` 已实现完整仿真功能
- 避免重复实现
- 保持一致性

### D2: 首期只做干跑模式

**理由**:
- 干跑模式（无 I/O 逻辑级）已足够验证逻辑
- 孪生模式需要 plant 模型配置，首期不触碰
- 推 G3.5 实现

### D3: 波形视图用 SVG

**理由**:
- 避免依赖膨胀（不引入 Chart.js/D3 等）
- SVG 足够表达周期级波形
- 易于定制和交互

---

## 验收标准

### ✅ 功能验收

1. **sim-svc**: 可调用 sim 主程序执行仿真
2. **watch 帧解析**: 正确解析 JSONL 输出
3. **波形视图**: SVG 渲染波形
4. **基线管理**: 保存/加载基线（localStorage）
5. **统计信息**: 显示 min/max/avg

### ✅ 测试验收

```bash
$ pytest tests/test_sim_service.py -v
======================== 10 passed in 0.03s =========================
```

### ✅ 集成验收

```bash
$ pytest tests/ -v
======================== 91 passed in 1.27s ========================
```

---

## 使用示例

### 1. 启动波形视图

```bash
cd veri-ide/frontend/public
python3 -m http.server 8080
# 浏览器打开 http://localhost:8080/waveform-viewer.html
```

### 2. 加载示例波形

1. 打开波形视图页面
2. 点击"加载示例"按钮
3. 查看 PID 控制器波形

### 3. 运行仿真

1. 输入周期数（如 12）
2. 点击"运行仿真"按钮
3. 查看仿真结果波形

### 4. 保存基线

1. 点击"保存基线"按钮
2. 输入基线名称
3. 基线保存到 localStorage

### 5. 加载基线

1. 点击"加载基线"按钮
2. 选择基线名称
3. 基线以虚线显示在波形上

---

## 架构集成

```
前端波形视图 (waveform-viewer.html)
  ↓ 运行仿真请求
sim-svc (service.py)
  ↓ 调用 sim 主程序
veri-runtime/sim/sim_main.c
  ↓ 执行仿真
  ↓ 输出 watch 帧 (JSONL)
sim-svc
  ↓ 解析 watch 帧
  ↓ 返回波形数据
前端波形视图
  ↓ SVG 渲染
波形显示
```

---

## 已知限制

1. **干跑模式**: 首期无 I/O，不连接真实硬件
2. **单变量**: 每个波形单独显示，不支持多变量叠加
3. **无缩放**: 时间轴固定，不支持缩放/平移
4. **localStorage**: 基线存储在浏览器，不持久化到服务器

---

## 后续工作（G3 W2）

### W2: 基线管理 + 偏差检测

- 实现基线保存/加载（服务器端）
- 实现偏差计算
- 实现偏差可视化
- 编写 10 项测试

---

## 里程碑总结

**G3 仿真验证**（W1）完成：

| 工作包 | 内容 | 测试数 | 状态 |
|--------|------|--------|------|
| W1 | sim-svc + 波形视图 | 10 | ✅ |
| **总计** | — | **10** | ✅ |

**累计测试**: 91 项（G1: 45 + G2: 36 + G3: 10）

**验收标准**:
- ✅ sim-svc 仿真服务
- ✅ watch 帧解析
- ✅ SVG 波形视图
- ✅ 基线管理（localStorage）

**下一步**: G3 W2（基线管理 + 偏差检测）
