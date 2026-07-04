# Phase 0: 现状分析 + 完整实现方案

> **文档版本**：v1.0  
> **建立日期**：2026-07-04  
> **作者**：Codex  
> **目的**：系统性识别当前项目中的简化/占位实现，给出从 Phase 0 到 Phase 4 的完整推进路线图

---

## 项目范围（Scope）

vstac = **V**erified **ST** to **A**ssembly **C**ompiler。将 IEC 61131-3 Structured Text (ST) 编译为 SafeASM 字节码（`.sasm`），配套 C 语言实现的 SafeASM 虚拟机，用于安全级仪控设备。

---

## 1. 第一阶段：现状盘点

### 1.1 已完成模块

| 模块 | 文件 | 行数 | 完成度 |
|------|------|------|--------|
| Coq Spec — SafeASM 形式化定义 | `vstac/spec/safeasm.v` | 1165 | ✅ 规范定义完整，小步语义骨架 |
| Coq Spec — SafeST 形式化定义 | `vstac/spec/safest.v` | ~500 | ✅ 完整类型/表达式/语句/POU 定义 |
| Coq Spec — 编译正确性定理 | `vstac/spec/compiler_correctness.v` | ~600 | ✅ 核心定理声明 + ST 操作语义 |
| Coq 词法分析器 | `vstac/src/lexer.v` | ~250 | ✅ 递归下降，40+ 关键字 |
| Coq 语法解析器 | `vstac/src/parser.v` | 1123 | ✅ 表达式优先级/POU/语句全集 |
| Coq 脱糖器 | `vstac/src/desugar.v` | ~250 | ✅ CASE/FOR/REPEAT → CoreST |
| Coq 类型检查器 | `vstac/src/typechecker.v` | ~400 | ✅ 可判定检查 + Soundness/Completeness 证明 |
| Coq 代码生成器 | `vstac/src/codegen.v` | 1367 | ✅ 指令发射 + exec_instr 大步模拟 |
| Coq 静态分析器 | `vstac/src/analysis.v` | ~200 | ✅ 调用图/循环/栈深度/WCET |
| Coq 二进制编码器 | `vstac/src/encoder.v` | ~100 | ⚠️ 骨架：只输出文件头 |
| C VM 核心 | `vm/safeasm_interp.c` | 525 | ⚠️ 实现 30 条指令，缺失 35+ 条 |
| C VM 加载器 | `vm/loader.c` | 266 | ✅ Magic/Version/CRC32 + 段解析 |
| C VM 头文件 | `vm/vm.h` | ~200 | ✅ 完整类型/常量/API 定义 |
| C I/O 映射 | `vm/io/io_mapping.c` | ~300 | ✅ 工程量转换/安全限值/扫描周期 |
| C 热备系统 | `vm/hotstandby/` | ~1500 | ✅ 脏页追踪/快照/状态机/增量下装 |
| RTOS 抽象 | `rtos/abstract.h` + `rtos/rtthread/` | ~100 | ✅ 接口定义 + RT-Thread 移植 |
| 测试 | `tests/vm-tests/test_minimal.c` | ~200 | ✅ 4 个端到端测试 |
| 构建系统 | `Makefile` + `vstac/dune*` | ~100 | ✅ Coq + C 完整构建 |
| Spec 文档 | `spec/*.md` | 3000+ | ✅ v1.1 完整规范文档 |
| Extraction 入口 | `vstac/extraction/` | ~80 | ⚠️ 骨架，引用未定义函数 |

### 1.2 当前简化/占位符清单

#### A. `spec/safeasm.v` — 小步语义仅 5 条规则

**现状**：定义了 `step` 归纳关系的 5 条规则（`Step_const`、`Step_i32_add`、`Step_safe_assert_cycle`、`Step_i32_load8_u`、`Step_i32_store8`），65+ 条指令无对应规则。

| 函数 | 实现 | 问题 |
|------|------|------|
| `state_after_store` | `:= s` | 直接返回原状态，未修改内存 |
| `branch_to` | `:= s` | 不做任何跳转 |
| `lookup_function` | `:= None` | 永远查不到函数 |
| `push_frame` | `:= s` | 不创建帧 |
| `pop_frame_with_return` | `:= s` | 不做返回操作 |
| `i32_bin_op` 中 `I32_SHR_S` | 用 `Z.shiftr` | 有符号右移语义不准确 |

**验证规则中标记为 `True` 的占位**：`rule_V1`（Magic "SASM" — 加载器层级检查）、`rule_V3`（CRC32 — 运行时检查）、`rule_V12`（Safety Section 存在）、`rule_V26`（无递归调用 — 需调用图分析）。

#### B. `spec/safest.v` — 良构性全为 `True`

```coq
Definition no_duplicate_declarations (p : st_program) : Prop := True.
Definition all_refs_declared (p : st_program) : Prop := True.
Definition no_recursive_calls (p : st_program) : Prop := True.
Definition all_functions_pure (p : st_program) : Prop := True.
Definition all_loops_bounded (p : st_program) : Prop := True.
```

`lookup_function` 实现为 `None`，函数调用类型检查无法真正工作。

#### C. `spec/compiler_correctness.v` — 核心证明 admit

| 项目 | 问题 |
|------|------|
| `var_to_sasm_offset` | `Parameter`（未赋予具体实现） |
| `compile_st_to_sasm` | `Parameter`（未赋予具体实现） |
| `semantics_preservation` 证明 | `admit` 在 `St_assign` 分支 |
| `execute_case`/`execute_fb` | 简化实现 |
| `enter_block`/`exit_block` | 简化占位 |
| 质量相关 helper | 大部分简化占位 |

#### D. `src/codegen.v` — 最多简化处

| 问题 | 具体描述 |
|------|----------|
| `build_compile_env` | 所有 param 索引均为 `0` |
| `U_NEG` 编译 | 用 `I32_CONST (-1); I32_MUL` 替代正确 `0 - x`，不支持 64 位/浮点 |
| `ARRAY_ACCESS` | 假设基址是地址而非 local var 索引 |
| `CE_FUNC_CALL` | 始终编译为 `[I32_CONST 0]` |
| IF 语句编译 | BR depth 硬编码，BLOCK 嵌套长度计算有误（缺少跳越 ELSE 的 BR） |
| `compile_function` | 所有 `sasm_locals` 类型硬编码为 `I32` |
| `compile_program` | `sasm_total_memory_size := 0`，段列表空，IOMap 空 |
| `exec_instr` 控制流 | `BR/BR_IF/BLOCK/LOOP/CALL/RETURN` 全部返回 `None` |
| `compile_expr_correct` | 8/9 分支 `admit` |
| `compile_stmt_correct` | `:= I`（trivial 占位） |

#### E. `src/lexer.v` — 缺少质量关键字

`keyword_table` 没有包含 `QUALITY`、`GOOD`、`BAD`、`UNCERTAIN`、`NOT_CONNECTED`、`QBOOL`~`QTIME`、`Q_STATUS`、`Q_VALUE` 等 v1.1 关键字。`string_of_Z` 实现为 `"0"`，`string_of_float` 实现为 `"0.0"`。

#### F. `src/parser.v` — 类型解析不完整

`parse_type` 只处理基础类型：`BOOL/BYTE/WORD/DWORD/SINT/INT/DINT/REAL/TIME/ARRAY`。**缺失类型**：`LINT/LREAL/QUALITY/QBOOL/QBYTE/QWORD/QDWORD/QSINT/QINT/QDINT/QLINT/QREAL/QLREAL/QTIME`。IO 映射从未被解析（`io_mapping` 字段永远为空）。

#### G. `src/desugar.v` — CoreST eval 占位

`CE_FUNC_CALL` 永远返回 `ST_V_INT 0`。质量操作 `CE_QUALITY_OP` 大部分返回默认值。

#### H. `src/typechecker.v` — 部分占位

- `type_check_expr` 中 `E_FUNC_CALL` 分支返回 `None`（简化实现）
- `type_check_program` 不报告具体错误
- Progress 定理用 `St_skip` hack 绕过；Preservation 定理 trivial；TypeSafety 定理永远说 "can step"

#### I. `src/analysis.v` — 循环分析未实现

```coq
loop_has_bound := false   (* 所有循环都标记为无界 *)
has_recursion f := false   (* 所有函数都标记为无递归 *)
WCET 估算: 循环固定 *1000（不是基于真实边界）
```

#### J. `src/encoder.v` — 编码器骨架

- `F32_CONST`/`F64_CONST` 编码为 `0`（浮点值未编码）
- 内存操作指令的 `memory_arg` 全部编码为 `0`
- `SAFE_ASSERT`/`SAFE_BOUNDS_CHECK` 的参数全部编码为 `0`
- `encode_sasm` 只输出 `[0x53, 0x41, 0x53, 0x4D, 0x01, 0x00]`（Magic + Version + Flags）
- 未定义 `encode_module` 函数（但 `vstac_main.ml` 调用了它）

#### K. C VM `safeasm_interp.c` — 缺失 35+ 条指令

**已实现**（30 条）：`UNREACHABLE`、`NOP`、`RETURN`、`BLOCK`、`LOOP`、`BR`、`BR_IF`、`CALL`、`DROP`、`SELECT`、`LOCAL_GET/SET/TEE`、`I32_CONST`、`I32_EQZ/EQ/NE/LT_S/GT_S`、`I32_ADD/SUB/MUL/DIV_S/REM_S`、`I32_AND/OR/XOR`、`I32_LOAD/STORE`、`SAFE_ASSERT`、`SAFE_BOUNDS_CHECK`

**缺失**（35+ 条）：
- 比较：`I32_LE_S`、`I32_GE_S`
- 位移：`I32_SHL`、`I32_SHR_S`、`I32_ROTL`、`I32_ROTR`
- 64 位整数（15 条）：`I64_CONST`、`I64_EQZ/EQ/NE/LT_S/LE_S/GT_S/GE_S`、`I64_ADD/SUB/MUL/DIV_S/REM_S`、`I64_AND/OR/XOR`、`I64_SHL/SHR_S`
- 32 位浮点（15 条）：`F32_CONST`、`F32_ADD/SUB/MUL/DIV`、`F32_EQ/NE/LT/LE/GT/GE`、`F32_ABS/NEG/SQRT`
- 64 位浮点（15 条）：`F64_CONST`、`F64_ADD/SUB/MUL/DIV`、`F64_EQ/NE/LT/LE/GT/GE`、`F64_ABS/NEG/SQRT`
- 字节操作：`I32_LOAD8_U`、`I32_STORE8`
- 类型转换（6 条）：`I32_WRAP_I64`、`I64_EXTEND_I32_S`、`I32_TRUNC_F32_S`、`I32_TRUNC_F64_S`、`F32_CONVERT_I32_S`、`F64_CONVERT_I32_S`

#### L. `sasm_dump.c` — 指令打印缺失

`opcode_name` 函数缺少 `I32_LE_S`、`I32_GE_S` 等不少指令的助记符。

---

## 2. 第二阶段：完整实现方案

### Phase 0 收尾（3-4 周）

| ID | 优先级 | 模块 | 任务 |
|----|--------|------|------|
| P0-1 | 🔴 P0 | C VM `safeasm_interp.c` | 补全缺失的 35+ 条指令实现（按 I32→I64→F32→F64→Conv 顺序） |
| P0-2 | 🔴 P0 | `encoder.v` | 实现完整二进制编码：7 种 section 编码、指令参数正确填充（F32/F64 literal, memory_arg, 安全断言参数）；定义 `encode_module` |
| P0-3 | 🔴 P0 | `codegen.v` | 修复 `build_compile_env` param 索引分配；修复 IF 编译的 BLOCK 嵌套/BR depth |
| P0-4 | 🟡 P1 | `lexer.v` | 补全 v1.1 质量关键字到 `keyword_table` |
| P0-5 | 🟡 P1 | `parser.v` | 补全 `parse_type` 支持所有 LINT/LREAL/QUALITY/Q* 类型；补全 IO 映射解析 |
| P0-6 | 🟡 P1 | `codegen.v` | 修复 WHILE/REPEAT 编译模式；修复 U_NEG/ABS 多类型支持 |
| P0-7 | 🟡 P1 | `codegen.v` | `compile_function` 使用真实 local types；`compile_program` 填充 total_memory_size/segments/IOMap |
| P0-8 | 🟢 P2 | C VM `sasm_dump.c` | 补全所有指令的 `opcode_name` 打印 |
| P0-9 | 🟢 P2 | `tests/` | 编写覆盖所有新增指令的单元测试 |

### Phase 1（5-16 周）— 编译器全量 + 形式化证明

| ID | 模块 | 任务 |
|----|------|------|
| P1-1 | `safeasm.v` | 补全小步语义：为全部 66 条指令添加 `Step_` 规则 |
| P1-2 | `safeasm.v` | 补全运行时 helper：`branch_to`（BLOCK/LOOP 标签跳转）、`push_frame`、`pop_frame_with_return`、`read_memory`（小端多字节）、`write_memory` |
| P1-3 | `safeasm.v` | 补全 V1-V26 中标记为 `True` 的规则（V1/V3/V12/V26） |
| P1-4 | `safeasm.v` | 证明 `type_safety` 定理 |
| P1-5 | `safest.v` | 实现 `lookup_function` 具体搜索逻辑 |
| P1-6 | `safest.v` | 替换所有 `:= True` 的良构性谓词为真实实现 |
| P1-7 | `compiler_correctness.v` | 实现 `var_to_sasm_offset` + `compile_st_to_sasm` |
| P1-8 | `compiler_correctness.v` | 完成 `semantics_preservation` 证明的 `St_assign` 分支 |
| P1-9 | `compiler_correctness.v` | 扩展 `semantics_preservation` 到所有 10+ 语句类型 |
| P1-10 | `codegen.v` | 实现 `exec_instr` 中 BR/BR_IF/BLOCK/LOOP/CALL/RETURN 的控制流语义 |
| P1-11 | `codegen.v` | 完成 `compile_expr_correct` 所有分支的证明（去除 admit） |
| P1-12 | `codegen.v` | 完成 `compile_stmt_correct` 的模拟引理（IF/WHILE/ASSIGN） |
| P1-13 | `typechecker.v` | 实现 `type_check_expr` 中 `E_FUNC_CALL` 的真实检查 |
| P1-14 | `typechecker.v` | 实现 `type_check_program` 的详细错误报告 |
| P1-15 | `typechecker.v` | 完善 Progress/Preservation/TypeSafety 证明（去掉 `St_skip` hack） |
| P1-16 | `analysis.v` | 实现真正的循环上限分析（AST pattern matching + 常量传播） |
| P1-17 | `analysis.v` | 实现真正的递归检测（DFS 调用图遍历） |
| P1-18 | `analysis.v` | 实现精确 WCET 计算（指令计数 × 循环上限 × 路径分析） |
| P1-19 | `analysis.v` | 安全断言生成与 `compile_program` 集成 |
| P1-20 | `extraction/` | 修复 OCaml 提取（确保 `E.encode_module` 可用）+ 命令行工具完善 |

### Phase 2（17-20 周）— I/O + RTOS

| ID | 模块 | 任务 |
|----|------|------|
| P2-1 | `codegen.v` | I/O 映射编译：将 ST 变量映射到 SEG_IO_INPUT/SEG_IO_OUTPUT |
| P2-2 | `codegen.v` | 质量影子内存（SEG_QUALITY）的编译支持（Q_BASE + idx） |
| P2-3 | `compiler_correctness.v` | 扩展抽象关系 R 包含 I/O 一致性条件 |
| P2-4 | C VM | 实现 `vm_scan_cycle` 集成 I/O 读→VM 执行→I/O 写完整周期 |
| P2-5 | C VM | 实现质量影子区同步逻辑 |
| P2-6 | `rtos/` | 完善 RT-Thread 适配层（信号量、邮箱、定时器） |
| P2-7 | `tests/` | I/O 集成测试（模拟量输入→PID→模拟量输出） |

### Phase 3（21-25 周）— 双机热备

| ID | 模块 | 任务 |
|----|------|------|
| P3-1 | C VM `hotstandby/` | 实现 `hs_master_cycle` 和 `hs_standby_cycle` 主循环 |
| P3-2 | C VM `hotstandby/` | 实现脏页追踪与增量同步 |
| P3-3 | C VM `hotstandby/` | 实现状态机转换逻辑 |
| P3-4 | C VM `hotstandby/` | 实现增量下装与原子切换 |
| P3-5 | `compiler_correctness.v` | 扩展安全保持定理包含热备语义 |
| P3-6 | `tests/` | 双机热备集成测试 |

### Phase 4（26-29 周）— 工程化

| ID | 模块 | 任务 |
|----|------|------|
| P4-1 | `tests/` | 完整编译器集成测试套件 |
| P4-2 | `tests/` | VM 运行测试（100+ 用例） |
| P4-3 | `extraction/` | OCaml 命令行工具完善 |
| P4-4 | `docs/` | 技术文档/用户手册/示例教程 |
| P4-5 | `Makefile`/CI | CI/CD 流水线 |

---

## 3. 优先级建议

### 立即处理（Phase 0 收尾核心）

```
优先级顺序（推荐执行顺序）：
┌────────────────────────────────────────────────────────────────┐
│ P0-1  C VM 补全 35+ 条指令                                      │
│ P0-2  编码器完整实现                                              │
│ P0-3  代码生成器修复（build_compile_env / IF 编译 / WHILE）       │
│ P0-5  解析器类型补全（LINT/LREAL/QUALITY/Q*）                    │
│ P0-4  词法分析器补全（质量关键字）                                │
│ P0-6  代码生成类型修复（64 位/浮点支持）                           │
│ P0-7  编译产物元数据填充（total_memory_size/segments/IOMap）      │
│ P0-8  反汇编工具补全                                              │
│ P0-9  测试补充                                                    │
└────────────────────────────────────────────────────────────────┘
```

### 整体推进原则

1. **先端到端跑通，后形式化证明** — C VM 和编码器优先，让编译器能产出（哪怕不完美）可运行的 `.sasm`
2. **先 i32 子集，后完整类型** — 补全 C VM 时从缺失的 i32 指令开始，再推进到 i64/f32/f64
3. **先实现，后证明** — Phase 0 聚焦补全实现，Phase 1 再补证明

---

## 附录：文件操作清单

| 文件 | 推荐操作 | 关联 Phase |
|------|----------|-----------|
| `vm/safeasm_interp.c` | **编辑** — 补全缺失指令 | Phase 0 |
| `vstac/src/encoder.v` | **编辑** — 完整编码实现 | Phase 0 |
| `vstac/src/codegen.v` | **编辑** — 修复编译逻辑 | Phase 0 |
| `vstac/src/lexer.v` | **编辑** — 加关键字 | Phase 0 |
| `vstac/src/parser.v` | **编辑** — 加类型解析 | Phase 0 |
| `vstac/spec/safeasm.v` | **编辑** — 补小步语义 | Phase 1 |
| `vstac/spec/safest.v` | **编辑** — 补良构性 | Phase 1 |
| `vstac/spec/compiler_correctness.v` | **编辑** — 补证明 | Phase 1 |
| `vstac/src/typechecker.v` | **编辑** — 补函数调用检查 | Phase 1 |
| `vstac/src/analysis.v` | **编辑** — 补循环分析 | Phase 1 |
| `vstac/src/desugar.v` | **编辑** — 补 eval | Phase 1 |
| `vstac/extraction/vstac_main.ml` | **编辑** — 完善 | Phase 4 |
| `vm/sasm_dump.c` | **编辑** — 补指令打印 | Phase 0 |
| `vm/loader.c` | 基本完整，可微调 | Phase 0 |
| `vm/vm.h` | 基本完整，可微调 | Phase 0 |
| `vm/io/io_mapping.c` | 基本完整，Phase 2 微调 | Phase 2 |
| `vm/hotstandby/*` | 基本完整，Phase 3 补主循环 | Phase 3 |
| `rtos/rtthread/vm_rtthread.c` | Phase 2 完善 | Phase 2 |
| `tests/vm-tests/test_minimal.c` | 持续扩展 | 全域 |
| `Makefile` | 持续维护 | 全域 |
| `spec/*.md` | 持续同步 | 全域 |
