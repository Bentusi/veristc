---
name: phase6-g2-technical-plan
description: 'Phase 6 G2 图形组态的详细技术方案。当实现图 JSON Schema、图→ST 生成器、往返恒等测试时必读。含 3 项已定决策与协议定义。'
---

# Phase 6 G2 — 图形组态详细技术方案

本文是 `phase6-veriide.prompt.md` 中「G2 图形组态」的实施级设计。G2 的验收总目标：
**图 JSON → merged.st → 编译通过**，且满足往返恒等 `graph -> merged.st -> graph`。

## 0. 已定决策（本文其余部分的前提，勿在实现时重开）

| # | 决策 | 后果 |
|---|------|------|
| **D1** | 首期只做**功能图（FC）**，顺控图（SFC）推 G2.5 | SFC 涉及步/转换/动作的复杂语义，首期不触碰；FC 已足够表达算法块互联 |
| **D2** | 图 JSON 是**权威源**，ST 是生成产物；ST 视图只读 | 端口/连线不会与文本漂移；生成前即可做门禁校验 |
| **D3** | 连线语义直接映射已实现的三机制（端口绑定→`S_FB_CALL`、跨周期状态→`VAR`、透传→`VAR_IN_OUT`） | 不引入新语义，复用 `function_check.v` 已检查的结构 |

## 1. 图 JSON 格式定义

### 1.1 功能图（FC）Schema

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "title": "Function Chart (FC)",
  "type": "object",
  "required": ["version", "type", "name", "blocks", "connections"],
  "properties": {
    "version": {"const": "1.0"},
    "type": {"const": "FC"},
    "name": {"type": "string", "pattern": "^[A-Z_][A-Z0-9_]*$"},
    "interface": {
      "type": "object",
      "properties": {
        "input": {"type": "array", "items": {"$ref": "#/definitions/port"}},
        "output": {"type": "array", "items": {"$ref": "#/definitions/port"}},
        "in_out": {"type": "array", "items": {"$ref": "#/definitions/port"}}
      }
    },
    "blocks": {
      "type": "array",
      "items": {"$ref": "#/definitions/block"}
    },
    "connections": {
      "type": "array",
      "items": {"$ref": "#/definitions/connection"}
    }
  }
}
```

### 1.2 块（Block）定义

```json
{
  "block": {
    "type": "object",
    "required": ["id", "type", "position"],
    "properties": {
      "id": {"type": "string", "pattern": "^[a-z_][a-z0-9_]*$"},
      "type": {"type": "string"},
      "position": {
        "type": "object",
        "required": ["x", "y"],
        "properties": {
          "x": {"type": "number"},
          "y": {"type": "number"}
        }
      },
      "parameters": {
        "type": "object",
        "additionalProperties": {"type": ["string", "number", "boolean"]}
      }
    }
  }
}
```

### 1.3 连线（Connection）定义

```json
{
  "connection": {
    "type": "object",
    "required": ["from", "to"],
    "properties": {
      "from": {
        "type": "object",
        "required": ["block", "port"],
        "properties": {
          "block": {"type": "string"},
          "port": {"type": "string"}
        }
      },
      "to": {
        "type": "object",
        "required": ["block", "port"],
        "properties": {
          "block": {"type": "string"},
          "port": {"type": "string"}
        }
      }
    }
  }
}
```

### 1.4 示例：PID 控制器互联

```json
{
  "version": "1.0",
  "type": "FC",
  "name": "PID_CONTROL",
  "interface": {
    "input": [
      {"name": "setpoint", "type": "DINT"},
      {"name": "measurement", "type": "DINT"}
    ],
    "output": [
      {"name": "control_output", "type": "DINT"}
    ]
  },
  "blocks": [
    {
      "id": "pid1",
      "type": "PID",
      "position": {"x": 200, "y": 100},
      "parameters": {"kp": 10, "ki": 1, "kd": 0}
    },
    {
      "id": "limiter1",
      "type": "LIMITER",
      "position": {"x": 400, "y": 100},
      "parameters": {"min": 0, "max": 100}
    }
  ],
  "connections": [
    {
      "from": {"block": "__interface__", "port": "setpoint"},
      "to": {"block": "pid1", "port": "SP"}
    },
    {
      "from": {"block": "__interface__", "port": "measurement"},
      "to": {"block": "pid1", "port": "PV"}
    },
    {
      "from": {"block": "pid1", "port": "OUT"},
      "to": {"block": "limiter1", "port": "IN"}
    },
    {
      "from": {"block": "limiter1", "port": "OUT"},
      "to": {"block": "__interface__", "port": "control_output"}
    }
  ]
}
```

## 2. 图→ST 生成规则

### 2.1 接口映射

```
图 interface.input[]  →  VAR_INPUT
图 interface.output[] →  VAR_OUTPUT
图 interface.in_out[] →  VAR_IN_OUT
```

### 2.2 块实例化

```
图 blocks[]  →  VAR
                  实例名 : 块类型;
                END_VAR
```

### 2.3 连线映射

```
图 connections[]  →  调用语句（按拓扑排序）
```

**拓扑排序规则**：
1. 构建有向图（节点=块，边=连线）
2. 检测环（环 ⇒ 拒绝，SafeST 禁止组合循环）
3. 拓扑排序（Kahn 算法）
4. 按排序顺序生成调用语句

**调用语句生成**：
```
对于每个块 B（按拓扑序）：
  收集所有输入连线：from.port → B.port
  生成：B(端口1:=实参1, 端口2:=实参, ...);
```

### 2.4 特殊块 `__interface__`

```
from.block = "__interface__"  ⇒  实参 = 接口变量名
to.block = "__interface__"    ⇒  输出赋值：接口变量 := 块输出;
```

### 2.5 生成示例

输入图（PID_CONTROL）：
```json
{
  "blocks": [
    {"id": "pid1", "type": "PID", "parameters": {"kp": 10}},
    {"id": "limiter1", "type": "LIMITER", "parameters": {"min": 0, "max": 100}}
  ],
  "connections": [
    {"from": {"block": "__interface__", "port": "setpoint"}, "to": {"block": "pid1", "port": "SP"}},
    {"from": {"block": "pid1", "port": "OUT"}, "to": {"block": "limiter1", "port": "IN"}},
    {"from": {"block": "limiter1", "port": "OUT"}, "to": {"block": "__interface__", "port": "control_output"}}
  ]
}
```

生成 ST：
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

pid1(SP := setpoint, PV := measurement, KP := 10);
limiter1(IN := pid1.OUT, MIN := 0, MAX := 100);
control_output := limiter1.OUT;
END_PROGRAM
```

## 3. 往返恒等验证

### 3.1 恒等定义

```
graph -> merged.st -> graph'
断言：graph == graph'
```

**注意**：这里的 `graph'` 是从生成的 ST 反向解析回的图结构。由于 ST 不保留位置信息（`position.x/y`），反向解析只验证**拓扑结构**等价，不验证布局。

### 3.2 验证策略

**正向生成**：
```python
def graph_to_st(graph: dict) -> str:
    # 1. 校验图 JSON
    # 2. 拓扑排序
    # 3. 生成 ST 代码
```

**反向解析**（仅用于测试）：
```python
def st_to_graph(st_code: str) -> dict:
    # 1. 解析 VAR 声明 → blocks
    # 2. 解析调用语句 → connections
    # 3. 忽略 position（设为默认值）
```

**恒等断言**：
```python
def test_roundtrip(graph):
    st = graph_to_st(graph)
    graph2 = st_to_graph(st)
    assert graph["blocks"] == graph2["blocks"]  # 忽略 position
    assert graph["connections"] == graph2["connections"]
```

### 3.3 已知精度取舍

1. **位置信息丢失**：ST 不保留 `position.x/y`，反向解析时设为 `(0, 0)`
2. **参数顺序**：ST 调用语句的参数顺序由图连线顺序决定，反向解析时按声明顺序
3. **注释丢失**：图 JSON 不支持注释，生成的 ST 也不含注释

## 4. 实现计划

### W1（2 周）：图 JSON Schema + 校验

- 定义 `fc.schema.json`（功能图）
- 实现 `validate_fc_json()`
- 编写 10 项测试（合法/非法图）

### W2（2 周）：图→ST 生成器

- 实现 `graph_to_st()`（拓扑排序 + 代码生成）
- 实现 `__interface__` 特殊块处理
- 编写 15 项测试（简单/复杂/环检测）

### W3（2 周）：往返恒等测试

- 实现 `st_to_graph()`（反向解析，仅测试用）
- 编写 10 项往返测试
- CI 门禁：每次提交自动验证

### W4（2 周）：前端画布（可选）

- SVG/Canvas 渲染图 JSON
- 拖拽编辑块/连线
- 实时预览生成的 ST

**验收标准**：
- 图 JSON → merged.st → 编译通过（`veristc -c`）
- 往返恒等测试 10/10 通过
- 无环检测（组合循环 ⇒ 拒绝）

## 5. 风险与缓解

| 风险 | 影响 | 缓解 |
|------|------|------|
| 拓扑排序失败（环） | 无法生成 ST | 早期检测 + 明确错误信息 |
| 块类型不存在 | 编译失败 | 生成前校验块类型（查库注册表） |
| 端口类型不匹配 | 编译失败 | 生成前校验类型一致性 |
| 往返恒等破坏 | 图/文本漂移 | CI 门禁自动检测 |

## 6. 与 G1 的关系

G2 复用 G1 的基础设施：
- `pre/merge.py`：多文件合并（图生成的 ST + 手写的 ST）
- `build/service.py`：调用 `veristc -c --json`
- `project/service.py`：工程 CRUD + Git 集成

G2 新增：
- `schema/fc.schema.json`：功能图协议
- `backend/gen/graph_to_st.py`：图→ST 生成器
- `tests/test_graph_gen.py`：生成 + 往返测试

## 7. 后续扩展（G2.5）

- **顺控图（SFC）**：步/转换/动作/有向连线
- **梯形图（LD）**：触点/线圈/函数块
- **指令表（IL）**：文本指令序列（已有 ST，不优先）
- **连续功能图（CFC）**：无拓扑排序约束（按绘制顺序）
