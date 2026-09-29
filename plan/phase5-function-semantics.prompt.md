---
name: phase5-function-semantics
description: 'Phase 5: restore IEC-style stateless FUNCTION semantics with real CALL/RETURN, scoped typing, purity checks, and later formal proofs. Use when: extending FUNCTION support, adding call-aware codegen, or proving function-call semantics.'
---

# Phase 5: 恢复 IEC 风格无状态 FUNCTION（进行中）

## 目标

把 `FUNCTION` 从“单表达式内联宏”恢复为 IEC 61131-3 风格的无状态函数：

- 支持 `VAR_INPUT` 参数和局部 `VAR`。
- 支持 `IF`/`CASE` 控制流。
- 支持嵌套 `FUNCTION` 调用。
- 函数名作为隐式结果变量，可在多个分支中赋值。
- 禁止修改全局变量、输入参数、输出端口和任何跨周期状态。
- 禁止直接/间接递归。
- 单表达式 `FUNCTION` 继续合法，但只是未来内联优化的候选，不再是合法性条件。
- 函数内 `FOR`/`WHILE`/`REPEAT` 暂不开放，待循环有界性和调用帧证明完成后增量启用。

## 当前工程状态

已完成第一轮工程实现：

| 模块 | 状态 |
|------|------|
| `veristc/src/function_check.v` | 新增：函数结果变量准备、POU 局部作用域、调用感知类型检查、函数纯性检查 |
| `veristc/src/inline.v` | 新增 `normalize_program`：保留用户函数，展开 `CycleCounter`，不再强制单表达式内联 |
| `veristc/src/global_codegen.v` | 新增 `compile_program_gc`：函数索引表、`CE_FUNC_CALL -> CALL`、函数结果返回协议 |
| `veristc/src/global_codegen.v` | 修复 `ABS` 临时槽硬编码问题，新调用路径使用函数帧末尾保留的 scratch local |
| `veristc/src/function_check.v` | 函数内暂拒 `FOR`/`WHILE`/`REPEAT`、`EXIT` 和局部变量声明初始化 |
| `vm/safeasm_interp.c` | 修复 `OP_CALL`：按函数签名 `param_count` 传参，而不是错误地按 `local_count` 弹栈 |
| `tests/st-examples/function_control_flow.st` | 新增正向测试：局部变量、`IF/ELSIF/ELSE`、嵌套调用 |
| `tests/st-examples/function_impure.st` | 新增负向测试：拒绝写输入参数和全局变量 |
| `tests/st-examples/function_recursive.st` | 新增负向测试：拒绝递归函数 |
| `tests/st-examples/function_loop.st` | 新增负向测试：函数内循环暂不开放 |
| `tests/st-examples/function_local_initializer.st` | 新增负向测试：函数局部变量声明初始化尚未实现，拒绝而不是静默按 0 处理 |
| `tests/vm-tests/test_vm.c` | 新增 SafeASM `CALL` 单元测试 |
| `tests/vm-tests/test_nuclear_protection_full_e2e.c` | 更新：允许多函数 `.sasm` 模块，不再假设内联后只剩一个函数 |

## 剩余工作

### 5.1 内联优化

- 对单表达式、无递归、体积小的 `FUNCTION` 做选择性内联。
- 内联必须保持语义不变，仅影响代码体积和执行开销。
- 保留复杂函数为真实 `CALL`。
- 增加大小/调用次数/栈深/WCET 决策阈值。

### 5.2 函数内循环

- 在函数帧内支持有界 `FOR`。
- 后续评估 `WHILE`/`REPEAT` 的 Loop Variant 注解。
- 循环上界必须参与 WCET 和栈深分析。

### 5.3 形式化证明

- 在 ST 语义中定义函数调用配置、函数帧和结果变量。
- 在 SafeASM 语义中补齐 `CALL`/`RETURN` 小步规则。
- 证明函数调用表达式编译为 `args ++ [CALL idx]` 后语义保持。
- 证明函数局部环境与 SafeASM frame locals 对应。
- 证明无递归调用图下栈深度有界。
- 更新顶层编译正确性定理，覆盖多函数模块。

### 5.4 错误诊断

- 当前 `function_check.v` 返回布尔结果，错误信息仍较粗。
- 后续应返回结构化诊断：POU 名、变量名、错误类别和源码位置。
- 解析器也应保留 token 位置，替代统一 `parser failed`。

## 验收标准

1. `function_control_flow.st` 能编译并在 VM 中输出正确的 clamp 结果。
2. 写输入参数、写全局变量、递归调用均被编译拒绝。
3. 旧单表达式 `FUNCTION` 示例继续编译通过。
4. 核电全量 ST -> SASM -> VM 端到端测试通过。
5. `make coq` 与现有 Coq 定理构建通过。
6. 后续安全级发布前，5.3 的 CALL/RETURN 语义保持证明必须完成。
