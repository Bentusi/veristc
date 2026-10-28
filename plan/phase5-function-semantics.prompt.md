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
- 函数内 `FOR` 已支持（限常数 INT 上下界与正的常数步长）；`WHILE`/`REPEAT` 的 Loop Variant 注解仍待后续增量启用。

## 当前工程状态

已完成第一轮工程实现：

| 模块 | 状态 |
|------|------|
| `veri-stc/src/function_check.v` | 新增：函数结果变量准备、POU 局部作用域、调用感知类型检查、函数纯性检查 |
| `veri-stc/src/inline.v` | 新增 `normalize_program`：保留用户函数，展开 `CycleCounter`，不再强制单表达式内联 |
| `veri-stc/src/global_codegen.v` | 新增 `compile_program_gc`：函数索引表、`CE_FUNC_CALL -> CALL`、函数结果返回协议 |
| `veri-stc/src/global_codegen.v` | 修复 `ABS` 临时槽硬编码问题，新调用路径使用函数帧末尾保留的 scratch local |
| `veri-stc/src/function_check.v` | 放行常数界 `FOR` 与字面量局部初值（经 `prepare_function_pou` 下推为入口 `S_ASSIGN`）；仍拒 `WHILE`/`REPEAT`/`EXIT` |
| `veri-runtime/core/safeasm_interp.c` | 修复 `OP_CALL`：按函数签名 `param_count` 传参，而不是错误地按 `local_count` 弹栈 |
| `veri-stc/tests/st-examples/function_control_flow.st` | 新增正向测试：局部变量、`IF/ELSIF/ELSE`、嵌套调用 |
| `veri-stc/tests/st-examples/function_impure.st` | 新增负向测试：拒绝写输入参数和全局变量 |
| `veri-stc/tests/st-examples/function_recursive.st` | 新增负向测试：拒绝递归函数 |
| `veri-stc/tests/st-examples/function_loop.st` | 正向测试：函数内常数界 `FOR` 循环编译并在 VM 运行正确 |
| `veri-stc/tests/st-examples/function_local_initializer.st` | 正向测试：函数局部变量字面量初值下推为入口赋值，编译并运行正确 |
| `veri-runtime/tests/vm-tests/test_vm.c` | 新增 SafeASM `CALL` 单元测试 |
| `veri-runtime/tests/vm-tests/test_nuclear_protection_full_e2e.c` | 更新：允许多函数 `.sasm` 模块，不再假设内联后只剩一个函数 |

## 完成情况与后续前沿

本轮把 CALL/RETURN 形式化证明线（WS-A~WS-E）与错误诊断细化（WS-F）全部落地，
`make coq` 与全部测试保持绿色，未引入 `Admitted`/`Axiom`。以下按工作流标注状态。

### 5.1 内联优化（WS-E，已完成结构级可靠性）

- `optimize_inline_program` 选择性内联已接入（阈值 64 / 纯叶子 / 死函数消除），
  仅展开单表达式、无用户调用、参数为 `D_INPUT` 的函数，复杂函数保留为真实 `CALL`。
- `inline.v` 新增可靠性引理：`lookup_inlineable_function_Some`（判定可内联 ⟹ 纯叶子单表达式）、
  `function_inline_decls_ok_spec`（声明方向约束）、`remove_dead_functions_keeps` /
  `remove_dead_functions_drop_not_called`（死代码删除只影响无引用的 `P_FUNCTION`）。
- **后续前沿**：跨 `subst_expr` 与 `call_function_fn` 的完整大步值级等价（内联=call-site 替换）留作后续增量。

### 5.2 函数内循环（WS-D，已完成终止度量 + 栈深有界）

- 常数界 `FOR` 已在工程与语义两侧放行；`function_semantics.v` 以 fuel 大步建模 `exec_for`，
  新增 `exec_for_zero_fuel_none`、`exec_for_past_bound_terminates`（越界立即终止）。
- `safeasm.v` 以步数索引关系 `pc_step_n` 证明“步数预算 ⟹ 帧数/栈深有界”
  （`pc_step_n_frame_bound`、`multi_pc_step_frame_depth_bounded`）。
- `WHILE`/`REPEAT` 的 Loop Variant 注解仍**不**开放（后续增量）；把“循环有界 ⟹ 步数有限”
  与 `analysis.v` 的 `ar_all_loops_bounded`/`ar_max_stack_depth` 正式对接留作后续说明性增量。

### 5.3 形式化证明（WS-A~WS-C，已完成多帧结构级门槛）

细化为本轮实际交付：

- **WS-A**：`function_semantics.v` 纳入 `Makefile`/`_CoqProject` 构建；补全 `exec_stmt_fn`
  的 `S_CASE` 与循环建模；增加帧不变式引理（`bind_args_length`/arity、结果变量唯一性）。
- **WS-B**：`safeasm.v` 补齐 `Pc_call`/`Pc_return` 调用约定（消费 `param_count`、callee 帧
  `frame_locals = args ++ zeros`、`RETURN` 只留 1 个返回值）、帧计数进度、内存保持与确定性；
  `asm_semantics.v` 把 `is_final_sasm` 收拢到基于 `pc_final_entry` 的多帧定义，统一以 `multi_pc_step` 为执行语义。
- **WS-C**：`compiler_correctness.v` 引入 `global_codegen` 与 `function_semantics`，证明结构级门槛定理
  `compile_st_to_sasm_calls`（`compile_program_gc` 生成的模块中所有 `CALL` 目标索引在界内、
  参数数 ≤ 局部数、ST-ASM arity 调和），及 `compile_call_index_present` 等投影引理。
- **后续前沿**：顶层**完整多帧值级大步模拟**（放宽 `semantics_preservation` 前置到含 `P_FUNCTION` 的多 POU 模块）
  留作安全级发布前的最终证明目标；现有单帧定理保持不变不回退。

### 5.4 错误诊断（WS-F，已完成）

- `function_check.v` 由 `option string` 升级为结构化诊断记录 `diagnostic {dg_pou; dg_var; dg_kind; dg_msg}`；
  `check_program_full_diag` 改为由 `diagnostic_render` 渲染，输出 `POU=/VAR=/KIND=/LOC=/MSG=` 四元组，
  并保留原有关键子串（如 `purity violation`）以免既有断言回退。
- `lexer.v` 新增 `lex_offsets`（每个 token 的起始字节偏移，与 `lex` 一一对齐）；`parser.v` 新增
  `parse_fail_pos`（返回首个无法并入的 token 索引）；`veristc_main.ml` 据此把解析失败定位到
  `line/col`，取代统一 `parser failed`。
- 检查阶段（类型/纯性）尚无 AST 内源位置，`LOC` 渲染为 `-`；逐表达式的类型错误定位（需改造
  `type_check_expr_f` 返回契约）留作后续增量。

## 验收标准

1. `function_control_flow.st` 能编译并在 VM 中输出正确的 clamp 结果。
2. 写输入参数、写全局变量、递归调用均被编译拒绝。
3. 旧单表达式 `FUNCTION` 示例继续编译通过。
4. 核电全量 ST -> SASM -> VM 端到端测试通过。
5. `function_loop.st`（常数界 `FOR`）与 `function_local_initializer.st`（字面量局部初值）为正向测试，编译并在 VM 运行正确。
6. `make coq` 与现有 Coq 定理构建通过；新增 WS-A~WS-E 引理均已完整证明（无 `Admitted`/`Axiom`）。
7. WS-F：解析失败输出 `line/col` 定位，检查错误输出 `POU/VAR/KIND/MSG` 结构化四元组。
8. 安全级发布前仍需补完 5.3 的**顶层完整多帧值级大步模拟**（结构级门槛已达成）。
