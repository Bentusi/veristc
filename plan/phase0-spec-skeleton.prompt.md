---
name: phase0-spec-skeleton
description: 'Phase 0: define SafeST/SafeASM specifications and build project skeleton. Use when: starting the VeriSTC project, defining language specs, setting up build infrastructure.'
---

# Phase 0: 顶层 Spec 定义 + 项目骨架（第 1-4 周）

## 目标

定义整个项目的最高权威输入——SafeST 和 SafeASM 的语言规范，并搭建项目骨架使端到端通路可验证。

## 核心产出物

| 产出物 | 路径 | 内容 |
|--------|------|------|
| SafeST 规范（文档） | `spec/safest-spec.md` | BNF 文法 + 类型系统 + 安全约束（开发可读） |
| SafeST 规范（Coq） | `veristc/spec/safest.v` | token/AST/语义的 Coq Inductive 定义 |
| SafeASM 规范（文档） | `spec/safeasm-spec.md` | 指令集 + 固定宽度二进制格式（开发可读） |
| SafeASM 规范（Coq） | `veristc/spec/safeasm.v` | 指令/模块/语义的 Coq Inductive 定义 |
| 语义保持说明 | `spec/semantics-preservation.md` | ST→ASM 映射 + 正确性定理（开发可读） |
| 编译正确性定理 | `veristc/spec/compiler_correctness.v` | 语义保持关系（Semantics Preservation Relation）的 Coq 定理声明 |
| 词法分析器 | `veristc/src/lexer.v` | Gallina 手写，含完备性/健全性证明 |
| 递归下降解析器 | `veristc/src/parser.v` | Gallina 手写，含良构性证明 |
| 二进制编码器 | `veristc/src/encoder.v` | SafeASM IR → `.sasm` 字节序列 |
| C 端加载器 | `vm/loader.c` | `.sasm` 解析 + CRC 校验 |
| C 端最小解释器 | `vm/safeasm_interp.c` | 核心指令子集解释执行 |

## 实现流程

1. **先写文档，再写 Coq**：先在 `spec/*.md` 中确定 BNF 文法和语义，再翻译为 `veristc/spec/*.v` 中的 Coq Inductive 类型
2. **文档和 Coq 定义保持同步**：任何 Coq 类型的修改必须同步更新对应 `.md` 文档
3. **词法/解析器先行**：`lexer.v` 和 `parser.v` 依赖 `safest.v` 中的 token/AST 定义
4. **VM 端并行开发**：`vm/loader.c` 和 `vm/safeasm_interp.c` 依赖 `safeasm.v` 中的格式定义，可与 compiler 端并行
5. **里程碑验证**：手写一个最小的 `.sasm` 二进制，C VM 能加载并执行

## 上下游关系

- **上游依赖**：无（本 Phase 是项目起点）
- **下游产出**：Phase 1 依赖本阶段的 `safest.v`、`safeasm.v`、`lexer.v`、`parser.v`、`encoder.v`

## 关键决策

- 编译器语言：Rocq (Coq) + Extraction → OCaml
- 解析器：Coq 内 Gallina 手写递归下降（非 ANTLR4）
- `.sasm` 编码：固定宽度编码（非 LEB128）
