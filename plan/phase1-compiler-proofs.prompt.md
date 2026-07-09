---
name: phase1-compiler-proofs
description: 'Phase 1: implement VeriSTC compiler passes with Coq correctness proofs. Use when: building compiler passes, writing Coq proofs, verifying type safety and semantics preservation.'
---

# Phase 1: VeriSTC 编译器全量实现 + 形式化证明（第 5-16 周）

## 目标

实现 ST→SafeASM 编译器的所有编译阶段，每个阶段在同一个 `.v` 文件中附带 Coq 正确性证明。这是项目的**核心阶段**。

## 核心产出物

| 阶段 | 文件 | 实现内容 | 正确性定理 |
|------|------|---------|-----------|
| 1.1 | `veristc/src/typechecker.v` | 类型检查器 + 类型推理规则 | `type_safety` (progress + preservation) |
| 1.2 | `veristc/src/desugar.v` | 脱糖（AST → CoreST IR） | `desugar_semantics_preservation` |
| 1.3 | `veristc/src/codegen.v` | CoreST → SafeASM 代码生成 | `codegen_simulation` **（核心定理）** |
| 1.4 | `veristc/src/analysis.v` | 静态分析（WCET/循环上限/栈深度） | 无证明（工具性质） |
| 1.5 | `veristc/extraction/` | Coq Extraction → OCaml 配置 | 无（工具链配置） |

**并行任务**（VM 端，与 1.1-1.5 同步）：
- `vm/memory/`：静态安全内存容器实现
- `vm/safeasm_interp.c`：SafeASM 解释器从子集扩展到完整指令集

## 实现流程

### 类型检查器（周 5-6）
1. 在 Coq 中定义 `has_type : context -> st_expr -> st_type -> Prop` 推理规则
2. 实现类型检查函数 `type_check : st_program -> option (list type_error)`
3. 证明 `type_safety` 定理——良类型程序不会在运行时出现类型错误
4. 需要辅助定理：`progress`（良类型程序要么是终态要么可执行）、`preservation`（执行保持类型）

### 脱糖（周 7-8）
1. 定义 CoreST IR——精简 AST（去掉语法糖，统一控制流结构）
2. 实现 `desugar : ST_AST → CoreST`
3. 证明：脱糖后的 CoreST 程序语义等价于原 ST 程序

### 代码生成（周 9-12）— 核心工作
1. 实现 `codegen : CoreST → SafeASM Module`
2. 逐构造证明 Simulation Relation：
   - 表达式编译 → 值栈模拟
   - 语句编译 → 控制流模拟
   - 函数编译 → CALL/RETURN 模拟
3. 这是整个项目**最关键的定理**，需要最多的证明工作量

### 编码器完善（周 13-14）
1. 完善 `encoder.v`，支持所有 SafeASM 指令类型的编码
2. 证明 `encode_decode_identity`（编码后解码回到原值）

### Extraction 配置（周 15-16）
1. 配置 Coq Extraction 到 OCaml
2. 编写 Makefile/dune 构建脚本
3. 验证 OCaml 可执行能正常编译 `.st` → `.sasm`

## 上下游关系

- **上游依赖**：Phase 0（spec 定义、lexer/parser/基础 encoder）
- **下游产出**：Phase 2 依赖 `codegen.v`（代码生成器），Phase 3 依赖 `analysis.v`（静态分析）
- **并行**：VM 端实现（内存容器 + 解释器）可与本 Phase 同步推进

## 关键决策

- **实现+证明同文件**：每个阶段与其证明在同一 `.v` 文件中（CompCert 风格）
- **证明策略**：优先使用 `omega`/`lia`/`auto` 自动化策略，核心 Simulation Relation 需手动引导
