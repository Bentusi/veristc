# VeriSTC 项目指南

VeriSTC = **Veri**fied **ST** **C**ompiler

将 IEC 61131-3 Structured Text (ST) 编译为 SafeASM 字节码（`.sasm`），配套 C 语言实现的 SafeASM 虚拟机，用于安全级仪控设备。

## 项目结构

```
veristc/                            ← 仓库根：三组件 + 跨组件集成
├── AGENTS.md                       ← 本文件，项目级指引
├── Makefile                        ← 聚合入口：转发组件目标 + 构建跨组件制品
├── Makefile.common                 ← 三组件共享的工具链与 build/ 目录定义
├── _CoqProject                     ← 编辑器/Proof General 的 Coq 加载配置
├── misra-suppressions.txt          ← MISRA-C 抑制清单（路径敏感）
├── build/                          ← 统一构建输出：bin/ lib/ sasm/（不入库）
├── integration/                    ← 跨组件系统级端到端验证
│   ├── test_framework.sh             共享断言库（PASS/FAIL 计数与配色）
│   ├── run_tests.sh                  全量测试入口
│   ├── run_feature_probes.sh         SafeST 特性面探针矩阵（PASS/XFAIL 覆盖表）
│   ├── run_channel_e2e.sh            单组 RPS 4 通道保护黄金时间线 e2e
│   ├── run_algo_e2e.sh               RS/SR/PID/FBY 算法块多实例黄金时间线 e2e
│   ├── run_algo_fb_e2e.sh            原生 FUNCTION_BLOCK 算法块多实例 e2e
│   ├── run_sim_e2e.sh                闭环仿真 e2e（.plant 对象 + sim 主程序 + 黄金时间线 + watch 帧）
│   ├── dl_frames.py                    下装帧参考发送端（Python，与 C 接收端相互独立）
│   ├── run_download_e2e.sh             下装 e2e（管道送帧 → 周期边界切换 → 拒绝矩阵 → 健康回滚）
│   └── run_nuclear_e2e.sh            核电 ST→SASM→VM 端到端验证
├── plan/                           ← Phase 描述文件（见下方导航）
│   ├── phase0-spec-skeleton.prompt.md
│   ├── phase1-compiler-proofs.prompt.md
│   ├── phase2-io-rtos.prompt.md
│   ├── phase3-hotstandby.prompt.md
│   ├── phase4-engineering.prompt.md
│   ├── phase5-function-semantics.prompt.md
│   ├── phase6-veriide.prompt.md
│   └── phase6-g0-technical-plan.md   G0 五产出物实施级方案（CLI 协议/符号段/仿真/watch/下装）
├── spec/                           ← 顶层 Spec 文档（开发可读，跨组件协议唯一源）
│   ├── safest-spec.md                SafeST 语言规范（BNF + 类型系统）
│   ├── safeasm-spec.md               SafeASM 指令集 + 二进制格式
│   ├── simulation-spec.md            仿真协议：`.plant` 被控对象表 + `sim` 命令行 + watch 帧
│   ├── download-spec.md              下装帧协议：帧字节布局 + 两道校验 + 拒绝码 + agent 命令行
│   └── semantics-preservation.md     ST→ASM 映射 + 正确性定理说明
├── veri-stc/                       ← 编译器组件（形式化核，Coq 实现+证明 → OCaml）
│   ├── Makefile                      组件自持构建：make -C veri-stc [coq|extract|veristc]
│   ├── spec/                           Coq 规范定义
│   │   ├── safeasm.v                   SafeASM 字节码形式化（3086 行）
│   │   ├── safest.v                    SafeST AST/类型形式化（553 行）
│   │   ├── st_semantics.v              ST 操作语义（780 行）
│   │   ├── function_semantics.v        FUNCTION 调用/返回语义
│   │   └── asm_semantics.v             SafeASM 多步执行语义
│   ├── src/                            Coq 实现（每文件含实现+证明）
│   │   ├── compiler_correctness.v      编译正确性定理（2223 行，4 大定理）
│   │   ├── lexer.v                       词法分析
│   │   ├── parser.v                      递归下降解析
│   │   ├── inline.v                      内联展开
│   │   ├── desugar.v                     AST → CoreST 脱糖
│   │   ├── analysis.v                    静态分析（WCET/栈深度/循环上限）
│   │   ├── typechecker.v                 类型检查器
│   │   ├── function_check.v              FUNCTION 作用域/纯性检查 + FB 实例展开与字段封装检查 + 全量诊断收集（`--json` 数据源）
│   │   ├── codegen.v                     CoreST → SafeASM 代码生成（8201 行，核心）
│   │   ├── global_codegen.v              全局编排 + CALL/RETURN + 重定位/符号行导出
│   │   └── encoder.v                     SafeASM IR → .sasm 二进制编码
│   ├── extraction/                     Coq → OCaml Extraction
│   │   ├── extraction.v                    提取配置
│   │   └── veristc_main.ml                 OCaml 命令行入口（手写，IDE 唯一可改文件）
│   ├── tools/stpreproc.py              PRE 源到源展开参考实现
│   └── tests/
│       ├── st-examples/                  ST 语料（smoke / 核电 / 特性探针 / 算法块）
│       │   ├── core_assign.st              最小 smoke 测试
│       │   ├── nuclear_rps_channel.st      状态密集中型用例（4 通道+表决+顺序器）
│       │   ├── feature-probes/             13 个单特性探针 + golden/ + README 覆盖矩阵
│       │   └── nuclear_rps_esfas_full.st   核电 RPS/ESFAS 模型（>10000 行）
│       └── compiler-tests/               正/负编译用例 + run_compiler_tests.sh
├── veri-runtime/                   ← 运行站组件（C11 SafeASM VM + I/O + 热备 + 仿真）
│   ├── Makefile                      组件自持构建：make -C veri-runtime [all|svm|build-*-test]
│   ├── core/                           VM 核
│   │   ├── vm.h                            VM 公共头文件（核心数据结构）
│   │   ├── loader.c                          .sasm 加载 + CRC32 校验
│   │   ├── safeasm_interp.c                  SafeASM 指令解释器
│   │   ├── svm.c                             统一 VM 可执行程序（周期运行/dump/info/符号查询 -s -l/I/O 映射 -m）
│   │   ├── sasm_dump.c/.h                    .sasm 反汇编 dump 工具
│   │   └── sasm_info.c/.h                    .sasm 段信息查看工具
│   ├── io/                           I/O 映射层
│   │   ├── io_mapping.c                      内存地址 ↔ 物理 I/O 通道同步
│   │   └── io_mapping.h                      缩放/偏置/安全限值检查
│   ├── hotstandby/                   双机热备系统
│   │   ├── hotstandby.h                      热备公共头文件
│   │   ├── snapshot.c                        VM 状态快照（序列化 + CRC32）
│   │   ├── sync.c                            主备同步（脏页追踪）
│   │   ├── state_machine.c                   主备状态机（故障检测 + 角色切换）
│   │   ├── download.c                      下装：全量镜像版本槽 + 周期边界切换 + 一级回滚
│   │   ├── download_wire.c/.h              下装帧协议：组帧 + 接收状态机 + 拒绝码
│   │   └── hmac_sha256.c/.h                SHA-256 + HMAC-SHA256（自持，不依赖 OpenSSL）
│   ├── rtos/                         硬件抽象与 RTOS 适配
│   │   ├── abstract.h                        VM_Interface 硬件抽象接口定义
│   │   └── rtthread/                           RT-Thread 移植（需外部 SDK）
│   ├── agent/                        目标端 agent（G0/W5）
│   │   └── agent_main.c                  veristc-agent：装载 + 周期执行 + 下装服务 + 状态上报
│   ├── sim/                          仿真后端（G0/W3+W4：软件 I/O + 被控对象 + watch 帧）
│   │   ├── plant.c/.h                        `.plant` 解析 + 确定性步进（CONST/LAG/RAMP/ACTUATOR）
│   │   ├── sim_io.c/.h                       VM_Interface 软件实现 + 虚拟时钟
│   │   ├── watch.c/.h                        `--watch` JSONL 帧：段 7 名字 → 地址 → 数值（协议 §4）
│   │   ├── sim_main.c                        `sim` 主程序：走 io_mapping_cycle 全路径
│   │   └── plants/closed_loop.plant          演示对象表（一阶惯性 + 恒值设定 + 执行器）
│   ├── tests/
│   │   ├── vm-tests/                         C VM 单元测试与核电端到端测试
│   │   └── fuzz/                             .sasm 加载器模糊测试 + corpus
│   ├── run_vm_checks.sh                VM/SVM 单元+周期+CRC+符号表+量程+下装帧检查（97 项，最细回归指纹）
│   ├── run_misra_check.sh              MISRA-C 静态检查（逐文件用例式输出，可传文件参数）
│   ├── run_sanitizer.sh                ASan/UBSan 内存安全检测
│   └── run_fuzzer.sh                   .sasm 加载器模糊测试
└── veri-ide/                       ← 工程站组件（VeriIDE Web IDE，Phase 6 规划中，现仅 README）
```

三组件的依赖规则（不可违反）：

- **R1** 跨组件耦合只能经由 `spec/` 协议（文本格式、二进制布局、JSON Schema），
  禁止跨组件 include 源文件。
- **R2** `veri-ide` 仅可消费 `veri-runtime` 的公共头文件与 `build/lib/libvm_*.a`。
- **R3** `veri-stc` 不依赖任何组件；`veri-runtime` 不依赖 `veri-stc` 源码，
  只消费其 `.sasm` 制品（由根 `Makefile` 收敛生成）。

## 架构概览

方案 A — 独立工具链（编译·运行解耦）：

- **上位机（IDE 侧）**：VeriSTC 编译器（Coq 实现，Extraction 为 OCaml）
  - 输入：`.st`（IEC 61131-3 Structured Text）
  - 输出：`.sasm`（SafeASM 二进制，I/O 配置作为内嵌 Section 3 一同编码，无独立 `.iomap` 文件）
  - 命令行：`veristc -c input.st -o output.sasm`（编译）/ `veristc -a input.st`（分析）/ `veristc -g input.st -o output.svobj`（可重定位对象）/ `veristc -x output.svobj`（校验 .svobj 结构+CRC）
  - 机器可读接口：`--json` 输出 NDJSON（一行一条诊断，字段 `pou/var/kind/loc/msg`）；
    退出码 `0/11/21/22/23/24/25`；`-c`/`-g` 缺 `-o` 即判 11，**绝不写当前工作目录**。
    协议唯一源见 `spec/safest-spec.md` 附录 D（文本诊断行格式冻结，`--json` 是附加副本）
- **下位机（运行站）**：C 语言 SafeASM 虚拟机
  - 加载 `.sasm` → CRC32 校验 → 周期解释执行
  - I/O 映射层驱动 AI/AO/DI/DO（缩放/偏置/安全限值）
  - 双机热备（状态快照 + 脏页同步 + 无扰切换 + 增量下装）
  - 两个主程序分工：`svm` 只跑 VM（不建映射表），`sim` 走 `io_mapping_cycle` 全路径并
    用 `.plant` 被控对象表充当软件 I/O 硬件；`sim --watch 名字表` 逐周期把「符号名 → 段 7
    地址 → 数值」以 stdout JSONL 帧发出，这就是工程站仿真按钮要消费的数据面 —— 协议见
    `spec/simulation-spec.md`（`.plant` 格式 + `sim` 命令行 + watch 帧）
  - 第三个主程序 `veristc-agent`（G0/W5）＝ 目标端常驻服务：装载 `.sasm` → 逐周期执行 →
    从文件/管道吸收**下装帧**（HMAC-SHA256 先验、CRC32 后验，两道独立闸）→ 在周期边界把整个 VM
    重绑到新镜像（冷启动语义：栈与线性内存清零）→ 健康检查不过即回切上一个版本槽；状态以
    `{"frame":"status",...}` JSONL 帧上报 —— 协议见 `spec/download-spec.md`
- **工程站（Phase 6 规划）**：VeriIDE —— 前后端分离的浏览器 IDE，覆盖「图形组态 → 编译 → 仿真验证 → 下装运行」闭环与自定义算法块库
  - 它**调用** `veristc` 而非替代：图形层只做「图 JSON → 文本 ST」源生成，编译器唯一入口仍是文本 ST（语义证明边界，不得绕过）
  - 命名体系：编译器 `veristc` / 工程站 `VeriIDE`（组件目录 `veri-ide/`）/ 无 UI 命令行 `veride` / 目标端 `veristc-agent`
  - 详细设计、前置差距与阶段验收见 `plan/phase6-veriide.prompt.md`；
    G0 五产出物的实施级方案（含 5 项已定决策与字节协议）见 `plan/phase6-g0-technical-plan.md`

**数据流**：
```
.st (IEC 61131-3 ST)
  → lexer.v (词法分析)
  → parser.v (递归下降解析；inst.field 融合为派生名 inst#field)
  → function_check.v (FUNCTION 结果变量准备 + 作用域/纯性/调用类型检查 + expand_instances 实例展开 + 字段封装检查)
  → inline.v (normalize_program：保留函数，展开 CycleCounter，后续可选择性内联)
  → desugar.v (AST → CoreST 脱糖)
  → analysis.v (静态分析: WCET/栈深度)
  → codegen.v (CoreST → SafeASM 指令序列)
  → global_codegen.v (全局编排 + CALL/RETURN 代码生成)
  → encoder.v (SafeASM → .sasm 二进制)
  → [OCaml extraction: veristc 可执行文件]
  → .sasm 文件
  → [C VM: svm 纯执行 / sim 闭环仿真（.plant 被控对象）/ veristc-agent 目标端服务]
  → 周期执行 + I/O 映射 + 热备同步
  → [工程站送下装帧（HMAC+CRC 全量镜像）] → agent 周期边界重绑 + 健康检查回滚
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
| 6 | 待定（估 28-32 周） | VeriIDE Web 工程站：图形组态→编译→仿真→下装闭环 + 算法块库 | Phase 1-3 | 🚧 G0 完成 / G1 规划中 |

Phase 6 子阶段：G0（前置能力补齐，✅ 完成）→ G1（工程站骨架，📝 方案已写）→ G2（图形组态）→ G3（仿真验证）→ G4（下装运行）→ G5（库与扩展）。
详细实现指引：`plan/phase6-veriide.prompt.md`（总览）、`plan/phase6-g0-technical-plan.md`（G0）、`plan/phase6-g1-technical-plan.md`（G1）。

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
- **构建工具**：dune（Coq/OCaml）+ Makefile（C）；根 `Makefile` 只做转发与跨组件制品，组件构建在各自 `Makefile` 内自持
  - dune 配置文件：`veri-stc/dune-project`、`veri-stc/spec/dune`、`veri-stc/src/dune`、`veri-stc/extraction/dune`
  - MISRA-C 检查：`./veri-runtime/run_misra_check.sh`（cppcheck MISRA addon，逐文件用例式输出；`make misra-check` 为其薄封装；cppcheck 缺失即判 FAIL，不静默跳过）

### `.sasm` 格式

- 自定义二进制格式，扩展名 `.sasm`
- Magic: `0x4D534153`（"SASM" 小端序），Version: `0x01`
- 固定宽度编码（非 LEB128）
  - i32 立即数：固定 4 字节小端序
  - i64 立即数：固定 8 字节小端序
  - 指令操作码：1 字节
- 尾部 CRC32 校验，SVM 加载时拒绝损坏文件
- Debug Section（段 7，可选但恒发射）：`STRPOOL + SYMTAB` 的
  `名字 → 地址 → 类型` 符号表，字节布局与 `type_tag` 枚举见 `spec/safeasm-spec.md` §4.8
- **段 7 分层**：Coq `global_codegen.v` 的 `compile_program_debug_info` 出行
  （地址唯一来源 `build_global_env`，含 `expand_instances` 派生的 `实例#字段` 与实例基址）；
  OCaml `veristc_main.ml` 的 `emit_debug_section` 做排序/去重/编码
- **运行核不消费段 7**：`loader.c` 按未知段整段跳过，`SasmModule` 无符号数组；
  解析归主机侧 `svm -s NAME`（查一个）/ `svm -l`（全列）/ `svm -i`（条数）
- **IOMAP（段 3）量程真值链**：条目 42 字节，`[18-25]` scale、`[26-33]` bias 为 float64。
  Coq 侧 `PrimFloat.float` 无 IEEE-754 位 ⇒ `encoder.v` 只写占位零，
  由 OCaml `patch_iomap_cal` 按 `compile_module_io_cal_info` 的 IR 值覆盖（条目数/段长/通道号三重核对，不符即拒绝产出）；
  `loader.c` 的 `read_f64` **逐条采信文件值**并拒绝非有限值（NaN/±Inf → 加载失败）。
  当前 SafeST 无量程语法，发射值恒为 `1.0 / 0.0`；工程量程属 G0/W3 仿真侧 `.plant` 表
  （协议见 `spec/safeasm-spec.md` §4.4 与验证规则 V10b）
- **IOMAP（段 3）地址单一真值**：`[4-7]` `mem_offset` 由 Coq `global_codegen.v` 的
  `resolve_io_map` **按名**向 `build_global_env`（段 7 用的同一张表）取该全局变量的槽位地址。
  此前它按 1024 起步自行编号，而变量在 4096 起步 ⇒ 运行站写入映射的位置与程序读写的变量
  不是同一块内存，I/O 数据永远进不了程序。名字未声明即编译拒绝（GATE-7，`KIND=declaration`）；
  可机检不变量：`svm -m` 的每个 `mem=` 必出现在 `svm -l` 的地址列（`run_vm_checks.sh` 第 8 步）

### `.svobj` 格式（P2 可重定位对象）

库编译链接重构计划（见 plan 文件）引入的**可重定位目标文件**，供后续链接器 `veristc-ld`（P3）跨模块链接；详细字节布局见 `spec/safeasm-spec.md` 附录 D。

- 扩展名 `.svobj`，Magic: `"SOBJ"`（`0x53 0x4F 0x42 0x4A`），Version `1`，尾部 CRC32
- 布局：`Header(36B) | SYMTAB | RELOC | BLOCKS | IMAGE | CRC32(4B)`（小端/定宽/非 LEB128）
- **实现分层**：编译器侧（Coq `global_codegen.v` 的 `compile_program_reloc_info`/`compile_program_inst_info`/`compile_program_sym_info`）仅导出扁平重定位元数据（纯新增，不触碰已证明结构）；主机侧 OCaml（`veristc_main.ml` 的 `emit_svobj`/`verify_svobj`）负责确定性字节编码。链接器为“信任+测试”层，不进安全核。
- 重定位种类：`0=CALL_IDX`（FB `__exec` 调用）/ `1=INST_BASE_IMM`（实例 self 基址）/ `2=GLOBAL_OFF`（VAR_IN_OUT 别名实参的全局地址立即数，`addend = 地址 − GLOBAL_BASE`，符号 kind=`2 GLOBAL_EXT`）
- **v1.5 VAR_IN_OUT 逐引用别名**：端口降级为“持有调用方存储地址的形参槽”，读写走 `I32_LOAD_PTR`/`I32_STORE_PTR`（0x30/0x31，地址来自值栈而非静态 `mem_offset`）。`GLOBAL_OFF` 由 `build_alias_table` 从调用点结构派生；扫描器里**别名判定优先于基址判定**（实例字段派生全局 `a1#LAST` 的地址恰等于该实例 self 基址，否则两类行会互相错记）。已知精度取舍与派生规则见 `spec/safeasm-spec.md` 附录 D.3/D.4。
- **v1.5.1 实例字段命名与封装**：`expand_instances` 派生的扁平全局名为 `实例名 # 字段名`（`safest.v` 的 `derived_field_sep`，三处拼接必须逐字一致：`function_check.inst_field_global` / `global_codegen.cat_ident` / `parser` 的 `TK_DOT`）。`#` 不在标识符文法内 ⇒ 派生名**不可书写**，用户无法与派生槽位互相冒充名字；源码唯一合法写法是 IEC 点号 `a1.Q`，由解析器融合成 `a1#Q`（不新增 AST 构造，证明核心不变）。封装规则（GATE-6，`function_check.check_program_access`，在展开后运行）：体外只可读 `VAR_OUTPUT`，读写 FB 内部 `VAR` 或体外写 `VAR_OUTPUT` → `KIND=access` 拒绝。GATE-1 重复名检查同样在展开后再跑一次并报出冲突名字（`duplicate_declaration_msg`）。

### 测试

**组件内测试**（改动只落在一个组件时，跑这些最快）：

- `veri-runtime/run_vm_checks.sh`：VM 单元测试、SVM 单周期运行、完整 `FUNCTION` 控制流/嵌套 `CALL`/纯性与递归拒绝、原生 FB 多实例/VAR_IN_OUT 别名/svobj 元数据、实例字段封装与派生名拒绝（KIND=access / 展开后重名 / 字面 `#` 不可书写）、dump/SIL3/CRC、1000ms 周期+损坏 CRC 与全零 CRC 拒绝（G0/W5 起 stored_crc==0 也判 -2）、Debug 段符号表（派生名字→地址解析、地址落在全局槽区间、`-l`/`-i` 条数一致、字节级确定性）、IOMAP 量程（编译器发射的 scale/bias 经加载器逐条采信、非有限值拒绝、`svm -m` 的地址必出现在 `svm -l`）、
  下装帧协议（SHA-256/HMAC 对公开测试向量、多帧重组、逐类畸形帧拒绝）、全量镜像下装链路
  （收帧→装槽→周期边界重绑→回滚，用真实 `.sasm` 制品）—— **97 项，最细的回归指纹**
- `veri-stc/tests/compiler-tests/run_compiler_tests.sh`：编译器正/负用例 + 机器可读 CLI 断言（基线 accepted=42, failed=0；第 3 步覆盖退出码、`--json` 与 IOMAP 未绑定名拒绝）
- `veri-runtime/run_misra_check.sh`：MISRA-C 静态合规检查（cppcheck；缺失即判 FAIL，不静默跳过）
- `veri-runtime/run_sanitizer.sh`：ASan/UBSan 内存安全检测（含下装帧与镜像切换的 ASan 变体）
- `veri-runtime/run_fuzzer.sh`：`.sasm` 加载器模糊测试

**跨组件系统级 e2e**（`integration/`；语料在 `veri-stc/tests/st-examples`，被测制品在 `build/`）：

- `integration/run_tests.sh`：全量入口（先 `make all build-tests`，再依次调用下列脚本与组件内测试）
- `integration/run_nuclear_e2e.sh`：核电 ST（>10000 行）→ VeriSTC → SASM → VM 端到端验证
- `integration/run_feature_probes.sh`：SafeST 特性面探针矩阵（13 探针，PASS/XFAIL 覆盖表；探针 `.sasm` 输出到 `build/sasm/probes/`）
- `integration/run_channel_e2e.sh`：单组 RPS 4 通道保护 + ESFAS 顺序器黄金时间线验证
- `integration/run_algo_e2e.sh`：RS/SR/PID/FBY 算法块多实例 12 周期黄金时间线验证
- `integration/run_algo_fb_e2e.sh`：原生 FUNCTION_BLOCK 版算法块（VAR_OUTPUT 多输出、VAR 实例持久状态、VAR_IN_OUT 别名、IF 控制流）12 周期黄金时间线验证
- `integration/run_download_e2e.sh`：下装端到端——Python 发送端经管道送帧 → agent 收帧 → 周期边界切换（判据是**程序输出形状真的换了**，不是状态帧自证）、六类拒绝用例（篡改/CRC/截断/超限/序号缺口/错钥，每条都核对"活动镜像不动"）、健康检查回滚（新镜像超自身周期预算 ⇒ 回切旧槽后继续扫描）、agent 命令行与退出码协议 + 状态帧 JSON 可解析（34 项）
- `integration/run_sim_e2e.sh`：闭环仿真——积分控制器 + 一阶惯性被控对象 12 周期黄金时间线、两次运行逐字节确定、`.plant` 协议拒绝（重名/方向/越界/非有限/字段数/驱动断链）、程序与对象表一致性拒绝（通道缺失/方向不符/无映射段）、watch 帧与 `svm -l`/黄金时间线逐条交叉核对 + 名字表启动即拒（26 项）

### 变更后验证路由（Skill: verify-route）

编辑文件后，按以下决策表选择**最小且充分**的验证动作（匹配第一条命中规则）：

| 变更文件模式 | 验证命令 | 理由 |
|-------------|---------|------|
| `veri-stc/spec/*.v` | `make coq` | 定理编译通过 = 证明完整 |
| `veri-stc/src/*.v` | `make coq && make veristc && ./integration/run_tests.sh` | 编译器实现变更 → 全管线 |
| `veri-stc/extraction/extraction.v` | `make coq && make veristc && ./integration/run_tests.sh` | 提取配置 → 重提取+全测试 |
| `veri-stc/extraction/veristc_main.ml` | `make veristc && ./integration/run_tests.sh` | OCaml 入口变更 |
| `veri-runtime/core/*.c` 或 `*.h` | `make svm && ./veri-runtime/run_vm_checks.sh` | VM 核 → 构建+单元/周期检查 |
| `veri-runtime/io/*.c` 或 `*.h` | `make vm-io && ./veri-runtime/run_vm_checks.sh` | I/O 映射层 → 构建+VM 检查 |
| `veri-runtime/hotstandby/*.c` 或 `*.h` | `make all && ./integration/run_tests.sh` | 热备模块 → 全量测试 |
| `veri-runtime/rtos/**` | `make all` | RTOS 适配 → 编译通过即可 |
| `veri-runtime/sim/**` | `make build-sim && ./integration/run_sim_e2e.sh` | 仿真后端 → 构建+闭环/协议回归 |
| `veri-runtime/agent/**` | `make agent && ./integration/run_download_e2e.sh` | 目标端 agent → 构建+下装 e2e |
| `veri-runtime/hotstandby/download*.c` 或 `hmac_sha256.c` | `make build-dlwire-test build-dlswitch-test && ./veri-runtime/run_vm_checks.sh && ./integration/run_download_e2e.sh` | 下装帧/版本槽 → 协议单测+切换单测+e2e |
| `veri-runtime/tests/**/*.c` | `make build-tests && ./veri-runtime/run_vm_checks.sh` | VM 测试代码 → 重建+运行 |
| `veri-stc/tests/st-examples/feature-probes/*.st` | `./integration/run_feature_probes.sh` | 特性探针变更 |
| `veri-stc/tests/st-examples/nuclear*.st` | `./integration/run_nuclear_e2e.sh` | 核电用例变更 |
| `veri-stc/tests/st-examples/*channel*.st` | `./integration/run_channel_e2e.sh` | 通道黄金时间线变更 |
| `veri-stc/tests/st-examples/algo_blocks*.st` | `./integration/run_algo_e2e.sh` | 算法块库/多实例用例变更 |
| `veri-stc/tests/st-examples/algo_blocks_fb.st` | `./integration/run_algo_fb_e2e.sh` | FB 版算法块用例变更 |
| `veri-stc/tests/st-examples/qualified_access_field.st` | `./veri-runtime/run_vm_checks.sh` | 点号访问/名字分离用例变更 |
| `veri-stc/tests/st-examples/io_cal.st` | `./veri-runtime/run_vm_checks.sh` | IOMAP 量程黄金制品（`svm -m` 断言）变更 |
| `veri-stc/tests/st-examples/sim_closed_loop.st` 或 `*.golden.timeline` | `./integration/run_sim_e2e.sh` | 闭环黄金时间线变更 |
| `veri-runtime/sim/plants/*.plant` | `./integration/run_sim_e2e.sh` | 被控对象表变更（黄金时间线随之变） |
| `veri-stc/tests/compiler-tests/**/*.st` | `./veri-stc/tests/compiler-tests/run_compiler_tests.sh && ./veri-runtime/run_vm_checks.sh` | 正/负编译用例变更（负例还需 run_vm_checks 校验诊断内容） |
| `spec/download-spec.md`、`integration/dl_frames.py` | `./integration/run_download_e2e.sh` | 下装协议或其参考实现变更 |
| `Makefile`、`Makefile.common`、`veri-*/Makefile`、`run_*.sh`、`integration/*.sh` | `./integration/run_tests.sh` | 构建/验证基础设施变更 → 全量回归 |
| `veri-ide/**`、`*.md`、`*.json`、`*.yml` | 无需验证 | 工程站尚无实现（Phase 6 G1 起引入协议测试门禁）；文档/配置 |

**补充规则**（C 源文件变更时可叠加）：
- 任何 `veri-runtime/**/*.c` 变更 → 建议追加 `./veri-runtime/run_misra_check.sh`
- `veri-runtime/core/loader.c` 或 `veri-runtime/core/safeasm_interp.c` 错误处理路径变更 → 建议追加 `./veri-runtime/run_fuzzer.sh`

## 常用构建命令

根 `Makefile` 只做两件事：向组件转发目标、构建必须由两组件共同产出的制品
（`.sasm` 黄金用例 + 核电端到端测试二进制）。日常一律在仓库根调用 `make <目标>`；
需要单独构建某一个组件时用 `make -C <组件> <目标>`。

```bash
# 全量构建（编译器 veristc + 运行站 libvm_*/svm/sim + 测试二进制 + .sasm 制品）
make all
make build-tests            # 追加测试二进制与 .sasm 黄金用例

# 编译器组件（Coq 证明 → Extraction → OCaml 可执行文件 build/bin/veristc）
make coq                    # 仅编译 .vo（= 证明检查门禁）
make veristc                # 提取 + 链接可执行文件
make extract                # 仅重跑 Extraction

# 运行站组件（C11 → build/lib/libvm_{core,io,hs}.a + build/bin/{svm,sim}）
make vm-lib vm-io vm-hs
make svm
make build-vm-test build-io-test build-hs-test
make build-smoke build-function-tests build-channel-e2e build-nuclear-e2e
make build-io-cal                # → build/sasm/io_cal.sasm（带 IOMAP 段的黄金制品）
make build-sim                   # → build/bin/sim（软件 I/O + 被控对象仿真后端）
make sim-demo                    # 一眼可看：积分控制器 + 一阶惯性对象闭环 12 周期
make sim-watch                   # 仿真数据面：12 行 cycle 帧 + 1 行 done 帧（JSONL）

# 组件内自持构建（不经过根 Makefile）
make -C veri-stc coq veristc
make -C veri-runtime all

# dune 路线（推荐用于 Coq 侧增量构建）
cd veri-stc && dune build && dune build @extraction && dune build extraction/veristc.exe
make dune-veristc           # 等价封装，产物收敛到 build/bin/veristc

# 内存安全与静态检查门禁
make misra-check            # → ./veri-runtime/run_misra_check.sh
make run-sanitize           # ASan/UBSan 构建 + 回归
make build-fuzzer           # .sasm 加载器模糊测试二进制

# 测试
./integration/run_tests.sh              # 全量（10 组）
./veri-runtime/run_vm_checks.sh         # 仅 VM/SVM（97 项）
./integration/run_sim_e2e.sh            # 仅闭环仿真（26 项）/ 也可 make sim-demo 肉眼看
./integration/run_download_e2e.sh       # 仅下装 e2e（34 项）
./integration/run_nuclear_e2e.sh        # 仅核电端到端
./veri-runtime/run_fuzzer.sh 100000      # 模糊测试（默认 100000 次）

# 清理（build/ + 两组件的中间产物）
make clean
```
