# G2 W3 完成报告 — 往返恒等测试

**完成时间**: 2026-10-29  
**测试覆盖**: 9 项新增往返测试  
**累计测试**: 81 项全绿  
**验收状态**: ✅ 全部通过

---

## 交付物清单

### 1. ST→图反向解析器

**文件**: `src/veri_ide/backend/gen/st_to_graph.py`

- `parse_st_to_graph()` — ST 代码 → FC JSON 结构
- `normalize_graph_for_comparison()` — 归一化（忽略位置、排序连接）
- 解析 PROGRAM/VAR/VAR_INPUT/VAR_OUTPUT/VAR_IN_OUT 声明
- 解析块调用语句（参数 + 连线）
- 解析输出赋值语句

**关键实现**:
```python
def parse_st_to_graph(st_code: str) -> dict[str, Any]:
    # 1. 解析 PROGRAM 名
    # 2. 解析 VAR 声明 → blocks
    # 3. 解析 VAR_INPUT/OUTPUT/IN_OUT → interface
    # 4. 解析块调用语句 → connections + parameters
    # 5. 解析输出赋值 → connections to __interface__
```

### 2. 往返测试套件

**文件**: `tests/test_roundtrip.py`（9 项测试）

| 测试 | 内容 |
|------|------|
| `test_roundtrip_simple` | 简单单块往返 |
| `test_roundtrip_no_interface` | 无接口往返 |
| `test_roundtrip_chain` | 链式块往返 |
| `test_roundtrip_parameters` | 参数保留 |
| `test_roundtrip_multiple_inputs` | 多输入往返 |
| `test_roundtrip_multiple_outputs` | 多输出往返 |
| `test_roundtrip_in_out` | VAR_IN_OUT 往返 |
| `test_roundtrip_direct_passthrough` | 直接透传往返 |
| `test_roundtrip_position_lost` | 位置信息丢失（预期行为） |

---

## 技术决策

### D1: 反向解析仅用于测试

**理由**:
- ST 不保留位置信息（`position.x/y`）
- 反向解析结果的位置字段设为 `(0, 0)`
- 归一化比较时忽略位置，只验证拓扑结构

### D2: 归一化比较策略

**理由**:
- 块按 ID 排序
- 连接按 (from.block, from.port, to.block, to.port) 排序
- 接口端口按 name 排序
- 确保比较结果与顺序无关

### D3: 位置信息丢失是预期行为

**理由**:
- ST 是文本格式，不保存图形布局
- 图 JSON 是权威源，ST 是生成产物
- 往返恒等只验证语义等价，不验证布局等价

---

## 验收标准

### ✅ 功能验收

1. **正向生成**: FC JSON → ST 代码
2. **反向解析**: ST 代码 → FC JSON 结构
3. **归一化**: 忽略位置、排序连接/块/端口
4. **恒等断言**: 拓扑结构等价

### ✅ 测试验收

```bash
$ pytest tests/test_roundtrip.py -v
======================== 9 passed in 0.09s =========================
```

### ✅ 集成验收

```bash
$ pytest tests/ -v
======================== 81 passed in 1.08s ========================
```

---

## 使用示例

### 1. 正向生成

```python
from veri_ide.backend.gen.graph_to_st import generate_st_from_fc

graph = {
    "version": "1.0",
    "type": "FC",
    "name": "TEST",
    "blocks": [{"id": "pid1", "type": "PID", "position": {"x": 0, "y": 0}}],
    "connections": []
}

st_code = generate_st_from_fc(graph)
```

### 2. 反向解析

```python
from veri_ide.backend.gen.st_to_graph import parse_st_to_graph

graph2 = parse_st_to_graph(st_code)
# graph2["blocks"][0]["position"] == {"x": 0, "y": 0}  # 位置丢失
```

### 3. 归一化比较

```python
from veri_ide.backend.gen.st_to_graph import normalize_graph_for_comparison

g1_norm = normalize_graph_for_comparison(graph)
g2_norm = normalize_graph_for_comparison(graph2)

assert g1_norm["blocks"] == g2_norm["blocks"]
assert g1_norm["connections"] == g2_norm["connections"]
```

---

## 已知限制

1. **位置信息丢失**: ST 不保留 `position.x/y`，反向解析时设为 `(0, 0)`
2. **参数顺序**: ST 调用语句的参数顺序由图连线顺序决定，反向解析时按声明顺序
3. **注释丢失**: 图 JSON 不支持注释，生成的 ST 也不含注释
4. **布局信息丢失**: 图形编辑器的布局信息无法从 ST 恢复

---

## 后续工作（G2 W4）

### W4: 前端画布（可选）

- SVG/Canvas 渲染图 JSON
- 拖拽编辑块/连线
- 实时预览生成的 ST

---

## 里程碑总结

**G2 图形组态**（W1-W3）完成：

| 工作包 | 内容 | 测试数 | 状态 |
|--------|------|--------|------|
| W1 | FC Schema + 校验 | 16 | ✅ |
| W2 | 图→ST 生成器 | 11 | ✅ |
| W3 | 往返恒等测试 | 9 | ✅ |
| **总计** | — | **36** | ✅ |

**累计测试**: 81 项（G1: 45 + G2: 36）

**验收标准**:
- ✅ FC JSON Schema 校验
- ✅ 环检测 + 拓扑排序
- ✅ 图→ST 生成
- ✅ ST→图反向解析
- ✅ 往返恒等验证

**下一步**: G2 W4（前端画布，可选）或 G3 仿真验证
