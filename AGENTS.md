# VeriSTC 项目指南

VeriSTC = **Veri**fied **ST** **C**ompiler

将 IEC 61131-3 Structured Text (ST) 编译为 SafeASM 字节码（`.sasm`），配套 C 语言实现的 SafeASM 虚拟机，用于安全级仪控设备。

## 项目结构

```
veristc/
├── AGENTS.md                     ← 本文件，项目级指引
├── Makefile                      ← 统一构建入口（Coq + C）
├── run_tests.sh                  ← 全量测试入口
├── run_vm_checks.sh              ← VM/SVM 单元+周期+CRC 检查
├── run_nuclear_e2e.sh            ← 核电 ST→SASM→VM 端到端验证
├── run_feature_probes.sh         ← SafeST 特性面探针矩阵（PASS/XFAIL 覆盖表）
├── run_channel_e2e.sh            ← 单组 RPS 4 通道保护黄金时间线 e2e
├── run_misra_check.sh            ← MISRA-C 静态检查（逐文件用例式输出，可传文件参数）
├── plan/                         ← Phase 描述文件（见下方导航）
│   ├── phase0-spec-skeleton.prompt.md
│   ├── phase1-compiler-proofs.prompt.md
│   ├── phase2-io-rtos.prompt.md
│   ├── phase3-hotstandby.prompt.md
│   ├── phase4-engineering.prompt.md
│   └── phase5-function-semantics.prompt.md
├── spec/                         ← 顶层 Spec 文档（开发可读）
│   ├── safest-spec.md              SafeST 语言规范（BNF + 类型系统）
│   ├── safeasm-spec.md             SafeASM 指令集 + 二进制格式
│   └── semantics-preservation.md   ST→ASM 映射 + 正确性定理说明
├── veristc/                      ← Coq 编译器（实现+证明）
│   ├── spec/                       Coq 规范定义
│   │   ├── safeasm.v                 SafeASM 字节码形式化（3086 行）
│   │   ├── safest.v                  SafeST AST/类型形式化（553 行）
│   │   ├── st_semantics.v            ST 操作语义（780 行）
│   │   ├── asm_semantics.v           SafeASM 多步执行语义
│   │   └── compiler_correctness.v    编译正确性定理（2223 行，4 大定理）
│   ├── src/                        Coq 实现（每文件含实现+证明）
│   │   ├── lexer.v                   词法分析
│   │   ├── parser.v                  递归下降解析
│   │   ├── inline.v                  内联展开
│   │   ├── desugar.v                 AST → CoreST 脱糖
│   │   ├── analysis.v                静态分析（WCET/栈深度/循环上限）
│   │   ├── typechecker.v             类型检查器
│   │   ├── function_check.v          完整 FUNCTION 作用域/纯性/调用类型检查
│   │   ├── codegen.v                 CoreST → SafeASM 代码生成（8201 行，核心）
│   │   ├── global_codegen.v          全局编译编排
│   │   └── encoder.v                 SafeASM IR → .sasm 二进制编码
│   └── extraction/                 Coq → OCaml Extraction
│       ├── extraction.v              提取配置
│       └── veristc_main.ml           OCaml 命令行入口
├── vm/                           ← C 语言 SafeASM 虚拟机
│   ├── vm.h                        VM 公共头文件（核心数据结构）
│   ├── loader.c                    .sasm 加载 + CRC32 校验
│   ├── safeasm_interp.c            SafeASM 指令解释器
│   ├── svm.c                       统一 VM 可执行程序（周期运行/dump）
│   ├── sasm_dump.c/.h              .sasm 反汇编 dump 工具
│   ├── io/                         I/O 映射层
│   │   ├── io_mapping.c              内存地址 ↔ 物理 I/O 通道同步
│   │   └── io_mapping.h              缩放/偏置/安全限值检查
│   └── hotstandby/                 双机热备系统
│       ├── hotstandby.h              热备公共头文件
│       ├── snapshot.c                VM 状态快照（序列化 + CRC32）
│       ├── sync.c                    主备同步（脏页追踪）
│       ├── state_machine.c           主备状态机（故障检测 + 角色切换）
│       └── download.c                增量下装（周期边界原子切换）
├── rtos/                         ← RTOS 适配层
│   ├── abstract.h                    硬件抽象接口定义
│   └── rtthread/                   RT-Thread 适配
│       ├── vm_rtthread.c             RT-Thread 移植实现
│       └── vm_rtthread.h             RT-Thread 移植头文件
└── tests/                        ← 测试套件
    ├── st-examples/                ST 示例程序
    │   ├── core_assign.st            最小 smoke 测试
    │   ├── nuclear_rps_channel.st    状态密集中型用例（4 通道+表决+顺序器）
    │   ├── feature-probes/           12 个单特性探针 + golden/ + README 覆盖矩阵
    │   └── nuclear_rps_esfas_full.st 核电 RPS/ESFAS 模型（>10000 行）
    └── vm-tests/                   C VM 测试
        ├── test_vm.c                 VM 单元测试（Unity/CMock）
        └── test_nuclear_protection_full_e2e.c  核电端到端测试
```

## 架构概览

方案 A — 独立工具链（编译·运行解耦）：

- **上位机（IDE 侧）**：VeriSTC 编译器（Coq 实现，Extraction 为 OCaml）
  - 输入：`.st`（IEC 61131-3 Structured Text）
  - 输出：`.sasm`（SafeASM 二进制）+ `.iomap`（I/O 配置表）
  - 命令行：`veristc -c input.st -o output.sasm`（编译）/ `veristc -a input.st`（分析）/ `veristc -g input.st -o output.svobj`（可重定位对象）/ `veristc -x output.svobj`（校验 .svobj 结构+CRC）
- **下位机（运行站）**：C 语言 SafeASM 虚拟机
  - 加载 `.sasm` → CRC32 校验 → 周期解释执行
  - I/O 映射层驱动 AI/AO/DI/DO（缩放/偏置/安全限值）
  - 双机热备（状态快照 + 脏页同步 + 无扰切换 + 增量下装）

**数据流**：
```
.st (IEC 61131-3 ST)
  → lexer.v (词法分析)
  → parser.v (递归下降解析)
  → function_check.v (FUNCTION 结果变量准备 + 作用域/纯性/调用类型检查)
  → inline.v (normalize_program：保留函数，展开 CycleCounter，后续可选择性内联)
  → desugar.v (AST → CoreST 脱糖)
  → analysis.v (静态分析: WCET/栈深度)
  → codegen.v (CoreST → SafeASM 指令序列)
  → global_codegen.v (全局编排 + CALL/RETURN 代码生成)
  → encoder.v (SafeASM → .sasm 二进制)
  → [OCaml extraction: veristc 可执行文件]
  → .sasm 文件
  → [C VM: svm]
  → 周期执行 + I/O 映射 + 热备同步
```

## Phase 导航与完成状态

| Phase | 周期 | 内容 | 前置依赖 | 状态 |
|-------|------|------|---------|------|
| 0 | 第 1-4 周 | 顶层 Spec 定义 + 项目骨架 | 无 | ✅ 完成 |
| 1 | 第 5-16 周 | VeriSTC 编译器全量实现 + 形式化证明 | Phase 0 | ✅ 完成 |
| 2 | 第 17-20 周 | I/O 集成 + RTOS 适配 | Phase 1 | ✅ 完成 |
| 3 | 第 21-25 周 | 双机热备 + 增量下装 | Phase 1 | ✅ 完成 |
| 4 | 第 26-29 周 | 工程化完善（测试+文档） | Phase 1-3 | ✅ 完成 |
| 5 | 第 30 周起 | 恢复 IEC 风格无状态 FUNCTION + CALL/RETURN + 后续证明 | Phase 1 | 🚧 进行中 |

每个 Phase 的详细实现指引见 `plan/` 下对应文件。

## Coq 编译器核心定理

`compiler_correctness.v`（2223 行）中已证明的 4 大定理：

| 定理 | 内容 | 意义 |
|------|------|------|
| `compile_st_to_sasm_core` | 核心编译正确性 | ST 程序编译后，SafeASM 多步执行语义与源程序一致 |
| `compile_st_to_sasm` | 完整编译正确性 | 端到端编译管线（含脱糖+代码生成）的语义保持 |
| `noncore_program_rejected` | 非核心子集拒绝 | 超出 SafeST 子集的程序（如 FUNCTION）被编译拒绝 |
| `compile_determinism` | 编译确定性 | 同一源程序编译结果唯一 |

## 核心约定

### 语言

- **编译器**：Rocq (Coq) + Extraction → OCaml
  - 每个 `.v` 文件包含**实现 + 正确性证明**（CompCert 风格）
  - 证明策略优先使用 Coq 的 `omega`/`lia`/`auto` 等自动化策略
  - Coq 命名空间：`veristc_spec`（spec/）、`veristc_src`（src/）
  - 支持质量类型（v1.1）：`T_QUALITY`、`T_QBOOL`、`T_QREAL` 等及 `Q_STATUS`/`Q_SET`/`Q_WITH` 等内置函数
  - `FUNCTION`（v1.4 工程阶段）：无状态纯函数，支持局部 `VAR`、`IF`/`CASE`、嵌套调用和函数名结果变量；禁止修改全局变量、输入参数和跨周期状态；函数内循环暂不开放。单表达式 `FUNCTION` 仍合法，内联只是后续优化，不是合法性条件
- **虚拟机**：C11 (MISRA-C 子集)
  - 禁止动态内存分配（`malloc`/`free`）
  - 禁止递归调用
  - 所有数组访问带边界检查
- **构建工具**：dune（Coq/OCaml）+ Makefile（C）
  - dune 配置文件：`veristc/dune-project`、`veristc/spec/dune`、`veristc/src/dune`、`veristc/extraction/dune`
  - MISRA-C 检查：`./run_misra_check.sh`（cppcheck MISRA addon，逐文件用例式输出；`make misra-check` 为其薄封装）

### `.sasm` 格式

- 自定义二进制格式，扩展名 `.sasm`
- Magic: `0x4D534153`（"SASM" 小端序），Version: `0x01`
- 固定宽度编码（非 LEB128）
  - i32 立即数：固定 4 字节小端序
  - i64 立即数：固定 8 字节小端序
  - 指令操作码：1 字节
- 尾部 CRC32 校验，SVM 加载时拒绝损坏文件

### `.svobj` 格式（P2 可重定位对象）

库编译链接重构计划（见 plan 文件）引入的**可重定位目标文件**，供后续链接器 `veristc-ld`（P3）跨模块链接；详细字节布局见 `spec/safeasm-spec.md` 附录 D。

- 扩展名 `.svobj`，Magic: `"SOBJ"`（`0x53 0x4F 0x42 0x4A`），Version `1`，尾部 CRC32
- 布局：`Header(36B) | SYMTAB | RELOC | BLOCKS | IMAGE | CRC32(4B)`（小端/定宽/非 LEB128）
- **实现分层**：编译器侧（Coq `global_codegen.v` 的 `compile_program_reloc_info`/`compile_program_inst_info`/`compile_program_sym_info`）仅导出扁平重定位元数据（纯新增，不触碰已证明结构）；主机侧 OCaml（`veristc_main.ml` 的 `emit_svobj`/`verify_svobj`）负责确定性字节编码。链接器为“信任+测试”层，不进安全核。
- 重定位种类：`0=CALL_IDX`（FB `__exec` 调用）/ `1=INST_BASE_IMM`（实例 self 基址）/ `2=GLOBAL_OFF`（VAR_IN_OUT 别名实参的全局地址立即数，`addend = 地址 − GLOBAL_BASE`，符号 kind=`2 GLOBAL_EXT`）
- **v1.5 VAR_IN_OUT 逐引用别名**：端口降级为“持有调用方存储地址的形参槽”，读写走 `I32_LOAD_PTR`/`I32_STORE_PTR`（0x30/0x31，地址来自值栈而非静态 `mem_offset`）。`GLOBAL_OFF` 由 `build_alias_table` 从调用点结构派生；扫描器里**别名判定优先于基址判定**（实例字段全局 `a1_LAST` 的地址恰等于该实例 self 基址，否则两类行会互相错记）。已知精度取舍与派生规则见 `spec/safeasm-spec.md` 附录 D.3/D.4。

### 测试

- `tests/st-examples/`：ST 示例程序
- `tests/vm-tests/`：C VM 单元测试与端到端测试（Unity/CMock 框架）
- `run_tests.sh`：构建并执行全部测试（调用 run_vm_checks.sh + run_nuclear_e2e.sh）
- `run_vm_checks.sh`：VM 单元测试、SVM 单周期运行、完整 `FUNCTION` 控制流/嵌套 `CALL`/纯性与递归拒绝、dump/SIL3/CRC、1000ms 周期+损坏 CRC 拒绝
- `run_nuclear_e2e.sh`：核电 ST（>10000 行）→ VeriSTC → SASM → VM 端到端验证
- `run_feature_probes.sh`：SafeST 特性面探针矩阵（12 探针，PASS/XFAIL 覆盖表）
- `run_channel_e2e.sh`：单组 RPS 4 通道保护 + ESFAS 顺序器黄金时间线验证
- `run_misra_check.sh`：MISRA-C 静态合规检查（cppcheck，逐文件用例输出）
- `run_sanitizer.sh`：ASan/UBSan 内存安全检测
- `run_fuzzer.sh`：.sasm 加载器模糊测试

### 变更后验证路由（Skill: verify-route）

编辑文件后，按以下决策表选择**最小且充分**的验证动作（匹配第一条命中规则）：

| 变更文件模式 | 验证命令 | 理由 |
|-------------|---------|------|
| `veristc/spec/*.v` | `make coq` | 定理编译通过 = 证明完整 |
| `veristc/src/*.v` | `make coq && make veristc && ./run_tests.sh` | 编译器实现变更 → 全管线 |
| `veristc/extraction/extraction.v` | `make coq && make veristc && ./run_tests.sh` | 提取配置 → 重提取+全测试 |
| `veristc/extraction/veristc_main.ml` | `make veristc && ./run_tests.sh` | OCaml 入口变更 |
| `vm/*.c` 或 `vm/*.h`（非 io/hotstandby） | `make svm && ./run_vm_checks.sh` | VM 核心 → 构建+单元/周期检查 |
| `vm/io/*.c` 或 `vm/io/*.h` | `make vm-io && ./run_vm_checks.sh` | I/O 映射层 → 构建+VM 检查 |
| `vm/hotstandby/*.c` 或 `vm/hotstandby/*.h` | `make all && ./run_tests.sh` | 热备模块 → 全量测试 |
| `rtos/**/*.c` 或 `rtos/**/*.h` | `make all` | RTOS 适配 → 编译通过即可 |
| `tests/vm-tests/*.c` | `make build-tests && ./run_vm_checks.sh` | VM 测试代码 → 重建+运行 |
| `tests/st-examples/feature-probes/*.st` | `./run_feature_probes.sh` | 特性探针变更 |
| `tests/st-examples/nuclear*.st` | `./run_nuclear_e2e.sh` | 核电用例变更 |
| `tests/st-examples/*channel*.st` | `./run_channel_e2e.sh` | 通道黄金时间线变更 |
| `run_*.sh` 或 `Makefile` | `./run_tests.sh` | 基础设施变更 → 全量回归 |
| `*.md`、`*.json`、`*.yml` | 无需验证 | 文档/配置 |

**补充规则**（C 源文件变更时可叠加）：
- 任何 `vm/**/*.c` 变更 → 建议追加 `./run_misra_check.sh`
- `vm/loader.c` 或 `vm/safeasm_interp.c` 错误处理路径变更 → 建议追加 `./run_fuzzer.sh`

## 常用构建命令

### 使用 dune 构建（推荐）

```bash
# 进入 veristc 目录
cd veristc

# 构建所有 Coq 库
dune build

# 提取 OCaml 代码
dune build @extraction

# 构建 veristc 可执行程序
dune build extraction/veristc.exe

# 清理构建
dune clean
```

### 使用 Make 构建

```bash
# 构建全部（Coq .vo + C 库 + svm）
make all

# 构建 veristc 可执行文件（Coq → OCaml extraction → 编译）
make veristc

# 构建测试二进制
make build-tests

# 运行全量测试
./run_tests.sh

# 仅运行 VM/SVM 检查
./run_vm_checks.sh

# 仅运行核电端到端
./run_nuclear_e2e.sh

# MISRA-C 检查
./run_misra_check.sh          # 全部 VM C 源文件；make misra-check 等价转发
./run_misra_check.sh vm/loader.c vm/svm.c   # 仅检查指定文件（修改时快速回归）

# ASan/UBSan 内存安全检测 (P2)
./run_sanitizer.sh

# .sasm 加载器模糊测试 (P2)
./run_fuzzer.sh [迭代次数]  # 默认 100000 次

# 清理所有构建产物
make clean
```
