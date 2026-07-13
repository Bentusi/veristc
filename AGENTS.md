# VeriSTC 项目指南

VeriSTC = **Veri**fied **ST** **C**ompiler

将 IEC 61131-3 Structured Text (ST) 编译为 SafeASM 字节码（`.sasm`），配套 C 语言实现的 SafeASM 虚拟机，用于安全级仪控设备。

## 项目结构

```
veristc/
├── AGENTS.md                     ← 本文件，项目级指引
├── plan/                         ← Phase 描述文件（见下方导航）
│   ├── phase0-spec-skeleton.prompt.md
│   ├── phase1-compiler-proofs.prompt.md
│   ├── phase2-io-rtos.prompt.md
│   ├── phase3-hotstandby.prompt.md
│   └── phase4-engineering.prompt.md
├── spec/                         ← 顶层 Spec 文档（开发可读）
│   ├── safest-spec.md
│   ├── safeasm-spec.md
│   └── semantics-preservation.md
├── veristc/                       ← Coq 编译器（实现+证明）
│   ├── spec/                       Coq 规范定义
│   ├── src/                       Coq 实现（每文件含证明）
│   └── extraction/                Extraction → OCaml 配置
├── vm/                            C 语言 SafeASM 虚拟机
├── rtos/                          RTOS 适配层
├── tests/                         测试套件
└── docs/                          技术文档
```

## 架构概览

方案 A — 独立工具链（编译·运行解耦）：

- **上位机（IDE 侧）**：VeriSTC 编译器（Coq 实现，Extraction 为 OCaml）
  - 输入：`.st`（IEC 61131-3 Structured Text）
  - 输出：`.sasm`（SafeASM 二进制）+ `.iomap`（I/O 配置表）
- **下位机（运行站）**：C 语言 SafeASM 虚拟机
  - 加载 `.sasm` → 校验 → 周期解释执行
  - I/O 映射层驱动 AI/AO/DI/DO
  - 双机热备（主备同步 + 无扰切换）

## Phase 导航

| Phase | 周期 | 内容 | 前置依赖 |
|-------|------|------|---------|
| 0 | 第 1-4 周 | 顶层 Spec 定义 + 项目骨架 | 无 |
| 1 | 第 5-16 周 | VeriSTC 编译器全量实现 + 形式化证明 | Phase 0 |
| 2 | 第 17-20 周 | I/O 集成 + RTOS 适配 | Phase 1 |
| 3 | 第 21-25 周 | 双机热备 + 增量下装 | Phase 1 |
| 4 | 第 26-29 周 | 工程化完善（测试+文档） | Phase 1-3 |

每个 Phase 的详细实现指引见 `plan/` 下对应文件。

## 核心约定

### 语言

- **编译器**：Rocq (Coq) + Extraction → OCaml
  - 每个 `.v` 文件包含**实现 + 正确性证明**（CompCert 风格）
  - 证明策略优先使用 Coq 的 `omega`/`lia`/`auto` 等自动化策略
- **虚拟机**：C11 (MISRA-C 子集)
  - 禁止动态内存分配（`malloc`/`free`）
  - 禁止递归调用
  - 所有数组访问带边界检查
- **构建工具**：dune（Coq/OCaml）+ Makefile（C）

### `.sasm` 格式

- 自定义二进制格式，扩展名 `.sasm`
- 固定宽度编码（非 LEB128）
  - i32 立即数：固定 4 字节小端序
  - i64 立即数：固定 8 字节小端序
  - 指令操作码：1 字节

### 测试

- `tests/st-examples/`：ST 示例程序
- `tests/sasm-examples/`：预编译的 SafeASM 二进制
- `tests/vm-tests/`：C VM 单元测试（Unity/CMock 框架）
- `tests/veristc-tests/`：编译器集成测试
