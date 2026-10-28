# G2 W1-W2 完成报告 — 功能图 Schema + 图→ST 生成器

**完成时间**: 2026-10-29  
**测试覆盖**: 27 项新增（16 项 Schema 校验 + 11 项生成器）  
**累计测试**: 72 项全绿  
**验收状态**: ✅ 全部通过

---

## 交付物清单

### W1: FC JSON Schema + 校验

#### 1. Schema 定义

**文件**: `src/veri_ide/schema/fc.schema.json`

- 功能图（FC）JSON Schema（Draft 7）
- 必填字段：`version`、`type`、`name`、`blocks`、`connections`
- 接口定义：`input`/`output`/`in_out` 端口数组
- 块定义：`id`（小写标识符）、`type`、`position`、`parameters`
- 连线定义：`from`/`to`（块 ID + 端口名）
- 特殊块 `__interface__` 表示接口端口

#### 2. 校验模块

**文件**: `src/veri_ide/backend/gen/validator.py`

- `validate_fc_json()` — JSON Schema 校验
- `validate_fc_file()` — 文件级校验
- `check_no_cycles()` — 环检测（DFS）
- `topological_sort()` — 拓扑排序（Kahn 算法）

#### 3. 测试套件

**文件**: `tests/test_fc_validator.py`（16 项测试）

| 测试 | 内容 |
|------|------|
| `test_validate_fc_valid` | 合法 FC 通过校验 |
| `test_validate_fc_missing_version` | 缺少 version 字段 |
| `test_validate_fc_wrong_version` | 错误版本号 |
| `test_validate_fc_wrong_type` | 错误类型（SFC） |
| `test_validate_fc_lowercase_name` | 小写程序名 |
| `test_validate_fc_invalid_block_id` | 非法块 ID |
| `test_validate_fc_missing_position` | 缺少位置 |
| `test_validate_fc_invalid_port_type` | 非法端口类型 |
| `test_validate_fc_file` | 文件校验 |
| `test_validate_fc_file_not_found` | 文件不存在 |
| `test_validate_fc_file_invalid_json` | JSON 格式错误 |
| `test_check_no_cycles_no_cycle` | 无环检测 |
| `test_check_no_cycles_with_cycle` | 环检测 |
| `test_topological_sort_simple` | 简单拓扑排序 |
| `test_topological_sort_chain` | 链式排序 |
| `test_topological_sort_cycle` | 环导致排序失败 |

### W2: 图→ST 生成器

#### 1. 生成器实现

**文件**: `src/veri_ide/backend/gen/graph_to_st.py`

- `generate_st_from_fc()` — FC JSON → ST 代码
- 接口映射：`input` → `VAR_INPUT`、`output` → `VAR_OUTPUT`、`in_out` → `VAR_IN_OUT`
- 块实例化：`blocks[]` → `VAR` 声明
- 连线映射：按拓扑序生成调用语句
- 参数处理：数值/字符串/布尔参数
- 特殊块 `__interface__`：输入端口作为实参，输出端口作为赋值目标

#### 2. 测试套件

**文件**: `tests/test_graph_to_st.py`（11 项测试）

| 测试 | 内容 |
|------|------|
| `test_generate_st_simple` | 简单单块生成 |
| `test_generate_st_no_interface` | 无接口 |
| `test_generate_st_no_blocks` | 无块 |
| `test_generate_st_chain` | 链式块排序 |
| `test_generate_st_parameters` | 数值参数 |
| `test_generate_st_string_parameter` | 字符串参数 |
| `test_generate_st_multiple_inputs` | 多输入 |
| `test_generate_st_multiple_outputs` | 多输出 |
| `test_generate_st_in_out` | VAR_IN_OUT |
| `test_generate_st_cycle_error` | 环错误 |
| `test_generate_st_direct_passthrough` | 直接透传 |

#### 3. 示例文件

**文件**: `examples/pid_control.fc.json`

PID 控制器功能图示例：
- 2 个输入端口（setpoint、measurement）
- 1 个输出端口（control_output）
- 2 个块（PID、LIMITER）
- 4 条连线

**生成结果**:
```structured-text
PROGRAM PID_CONTROL
VAR
    pid1 : PID;
    limiter1 : LIMITER;
END_VAR
VAR_INPUT
    setpoint : DINT;
    measurement : DINT;
END_VAR
VAR_OUTPUT
    control_output : DINT;
END_VAR

pid1(SP := setpoint, PV := measurement, kp := 10, ki := 1, kd := 0);
limiter1(IN := pid1.OUT, min := 0, max := 100);
control_output := limiter1.OUT;
END_PROGRAM
```

---

## 技术决策

### D1: 首期只做功能图（FC）

**理由**:
- FC 已足够表达算法块互联
- SFC（顺控图）涉及步/转换/动作的复杂语义，首期不触碰
- SFC 推 G2.5（后续扩展）

### D2: 图 JSON 是权威源

**理由**:
- 端口/连线不会与文本漂移
- 生成前即可做门禁校验
- ST 视图只读（不反向编辑）

### D3: 连线语义复用已实现机制

**理由**:
- 端口绑定 → `S_FB_CALL`（具名实参）
- 跨周期状态 → FB 内 `VAR`
- 透传 → `VAR_IN_OUT` 别名
- 不引入新语义，复用 `function_check.v` 已检查的结构

### D4: 拓扑排序检测环

**理由**:
- SafeST 禁止组合循环
- Kahn 算法检测环并返回拓扑序
- 环 ⇒ 拒绝生成，明确错误信息

---

## 验收标准

### ✅ 功能验收

1. **Schema 校验**: 合法 FC JSON 通过，非法 FC 拒绝
2. **环检测**: 组合循环被检测并拒绝
3. **拓扑排序**: 块按依赖关系排序
4. **ST 生成**: FC JSON → 合法 ST 代码
5. **参数处理**: 数值/字符串/布尔参数正确生成

### ✅ 测试验收

```bash
$ pytest tests/test_fc_validator.py tests/test_graph_to_st.py -v
======================== 27 passed in 0.17s ========================
```

### ✅ 集成验收

```bash
$ pytest tests/ -v
======================== 72 passed in 1.09s ========================
```

---

## 使用示例

### 1. 校验 FC JSON

```python
from veri_ide.backend.gen.validator import validate_fc_file

data, errors = validate_fc_file("examples/pid_control.fc.json")
if errors:
    print("Validation failed:", errors)
else:
    print("Valid FC")
```

### 2. 生成 ST 代码

```python
import json
from veri_ide.backend.gen.graph_to_st import generate_st_from_fc

with open("examples/pid_control.fc.json") as f:
    data = json.load(f)

st_code = generate_st_from_fc(data)
print(st_code)
```

### 3. 检查环

```python
from veri_ide.backend.gen.validator import check_no_cycles

errors = check_no_cycles(data)
if errors:
    print("Cycle detected!")
```

---

## 架构集成

```
FC JSON (图编辑器)
  ↓ validate_fc_json()
  ↓ check_no_cycles()
  ↓ topological_sort()
graph_to_st.py
  ↓ generate_st_from_fc()
merged.st
  ↓ pre/merge.py (多文件合并)
  ↓ build/service.py (调用 veristc -c --json)
  ↓ 解析 NDJSON 诊断
output.sasm + diagnostics
```

---

## 已知限制

1. **位置信息不验证**: Schema 要求 `position.x/y`，但不校验布局合理性
2. **块类型不验证**: 不检查块类型是否存在于库注册表
3. **端口类型不验证**: 不检查连线两端端口类型是否匹配
4. **无图形渲染**: 首期无前端画布（推 W4）

---

## 后续工作（G2 W3-W4）

### W3: 往返恒等测试

- 实现 `st_to_graph()`（反向解析，仅测试用）
- 编写 10 项往返测试
- CI 门禁：每次提交自动验证

### W4: 前端画布（可选）

- SVG/Canvas 渲染图 JSON
- 拖拽编辑块/连线
- 实时预览生成的 ST

---

## 里程碑总结

**G2 图形组态**（W1-W2）完成：

| 工作包 | 内容 | 测试数 | 状态 |
|--------|------|--------|------|
| W1 | FC Schema + 校验 | 16 | ✅ |
| W2 | 图→ST 生成器 | 11 | ✅ |
| **总计** | — | **27** | ✅ |

**累计测试**: 72 项（G1: 45 + G2: 27）

**验收标准**:
- ✅ FC JSON Schema 校验
- ✅ 环检测 + 拓扑排序
- ✅ 图→ST 生成
- ✅ 示例文件可编译

**下一步**: G2 W3（往返恒等测试）
