# VeriSTC 当前状态架构说明

范围：`/home/wei/veristc` 全仓库。视角：当前状态（AS-IS），不含目标态建议。
证据基线：2026-10-14 的工作树（含未提交改动）；**运行站与编译器侧已于 2026-10-28（Phase 6 G0 / W1-W5）重导**，
本轮变化集中在：三个运行站主程序、IOMAP 量程与地址真值链、段 7 符号表、CRC 强制、下装帧与 `veristc-agent`。
配套图源见 `README.md` 清单。

## 系统边界

VeriSTC 是**一套独立工具链**，由一个编译器与**三个互不通信的运行站程序**组成，
中间只靠文件/字节契约连接：

```
ST 工程师 ──> veristc (上位机, OCaml 原生) ──写──> .sasm ──┬──读──> svm   (纯执行器：测试/黄金时间线)
                                                          ├──读──> sim    (闭环仿真：I/O 映射 + .plant + watch 帧)
                                                          └──读──> veristc-agent (装载 + 周期扫描 + 下装换版)
```

`veri-ide/`（工程站）目前只有 README，属 Phase 6 目标态；它对上述程序的消费方式已由
`spec/safest-spec.md` 附录 D（编译 CLI）、`spec/simulation-spec.md`（仿真数据面）、
`spec/download-spec.md`（下装帧与 agent CLI/状态帧）三份契约冻结。

程序之间没有进程通信、没有共享库依赖（agent 链接 `libvm_hs`+`libvm_core`，`sim` 链接
`libvm_io`+`libvm_core`，`svm` 只链 `libvm_core`），`.sasm` 是唯一接口，
其结构（Header / 段表 / IOMap / Code / Safety / WCET / Debug / CRC32）由 `spec/safeasm-spec.md` 与
`veri-stc/src/encoder.v` + `veri-runtime/core/loader.c` 两侧各自实现，靠测试保持一致而非类型系统。

第三个产物 `.svobj`（可重定位对象）目前**只有生产者，没有消费者** —— 链接器 `veristc-ld`
属 P3 计划，仓库内无实现。它是目标态，不是当前架构的一部分，模型里以 `TargetState` 标出。

## 真实的部署单元有三个

`veri-runtime/Makefile:61` 的 `all` 目标产出 `vm-lib vm-io vm-hs svm build-sim agent`。其中：

- **`veristc`**（`build/bin/veristc`）—— 上位机编译器，唯一入口。
- **`svm`**（`veri-runtime/core/svm.c`）—— 纯执行器，链 `-lvm_core`（`veri-runtime/Makefile:155`）。
- **`sim`**（`veri-runtime/sim/sim_main.c`）—— 闭环仿真，链 `-lvm_io -lvm_core`（`veri-runtime/Makefile:169`），
  用 `.plant` 表 + `sim/sim_io.c` 充当软件 I/O 硬件，`--watch` 发 stdout JSONL 帧。
- **`veristc-agent`**（`veri-runtime/agent/agent_main.c`）—— 目标端常驻程序，链
  `-lvm_hs -lvm_core`（`veri-runtime/Makefile:182`），装载 + 周期扫描 + 下装帧接收 + 周期边界换版 + 健康窗回滚。

三个库现在都有可执行消费者：`libvm_core.a`（三者）、`libvm_io.a`（`sim`）、`libvm_hs.a`（`agent`）。
`test_hotstandby` 仍用 `#include "…/hotstandby/*.c"` 内联源码而非链接库
（`veri-runtime/tests/vm-tests/test_hotstandby.c:17-23`）；新的
`test_download_wire` / `test_download_switch` 把 `hotstandby/*.c` 直接列进编译命令
（`veri-runtime/Makefile:138-143`），两种驱动方式都绕过了归档，因此库级 ABI 只有
`sim`/`agent` 两个主程序真正在检验。

`vm_rtthread.elf` 没有任何构建规则；`rtthread` 目标即使设了 `RTTHREAD_SDK` 也只语法编译不链接，
且 `veri-runtime/rtos/rtthread/vm_rtthread.c:30` 引用了不存在的 `veri-runtime/core/loader.h`（`veri-runtime/core/` 下只有 `vm.h` 与
`sasm_dump.h`）。所以移植层是**当前不可编译的代码**，不是运行单元。

## 编译器内部：一条前端 + 三条后端分叉

`veri-stc/extraction/veristc_main.ml` 是手写的（不参与提取，`veri-stc/Makefile` 的 extract 目标
显式把它列为依赖）。它把 Coq 提取出来的计算函数串成一条 `frontend()`（`veristc_main.ml:423-482`）：

```
read_file → Lexer.lex → Parser.parse → 重名门禁 → Function_check.prepare_program
→ 展开后重名门禁 → check_program_full_diag → Inline.normalize_program → optimize_inline_program
→ Desugar.desugar_program → Analysis.analyze（递归拒绝 + 栈深门禁）
```

命令行分派发生在**最前面**（`veristc_main.ml:808-841` 的 `parse_args`，无模式参数时默认 `-a` `:840`），
四条路径互不共享入口函数：

- `-c` 与 `-g` 共用 `frontend()`，返回 `corest_program` 后分叉：
  `-c` 走 `compile_program_gc → encode_module → patch_iomap_cal → emit_debug_section → attach_crc32 → 写 .sasm`
  （`:484-499`）；
  `-g` 走 `compile_program_reloc_info / inst_info / sym_info → emit_svobj`，
  其中 IMAGE 段复用同一条 `gc + encode` 结果（`veristc_main.ml:617`）。
- `-a` 走 `analyze_st()`（`:721-780`），**不经过 `frontend`**，只 `printf` 四项指标不出文件。
- `-x` 输入是 `.svobj`，纯 OCaml 反向走查，不读 `.st` 也不经任何 Coq 代码。
- 任意模式加 `--json` 改走机器可读通道：诊断走全量行（`check_program_full_diag_rows` `:454-459`），
  产物走一条 `{"kind":"output",...}` 行（`:865-867`）。

一个值得注意的结构事实：`analyze_st` 与 `frontend` 是**同构的两份实现**
（`:730-757` 对 `:429-456`），但 `analyze_st` 少了 `frontend:475-481` 的递归拒绝与栈深门禁，
只把这两项打印出来。也就是说"静态分析报告通过"与"编译通过"不是同一个判据，
且新增门禁时两处都要改 —— 这是模型里唯一被标为 `DuplicatedLogic` 的边界。

同理，`frontend` 在每个模式下各自完整执行一遍，所以 `-c` 与 `-g`
无法在一次调用内同时产出，只能跑两次编译。

分层原则是"Coq 出语义、OCaml 出字节"：Coq 侧只导出扁平元数据行
（`global_codegen.v:1021,1037,1072` 加 `compile_program_debug_info`），排序、去重、小端定宽布局全在手写 OCaml 里
（`veristc_main.ml:293` 段 7、`:574-647` `.svobj`）。这与 `.svobj` 被定位为"信任+测试层、不进安全核"一致。

## 证明层与生产层的解耦边界

这是本模型里最需要理解清楚的一条边界，也是 VeriSTC 区别于普通编译器的地方。

`compiler_correctness.v` 的端到端组合是
`compile_st_to_sasm = compile_core_program`（`:85-99`），它由
`type_check_program` + `codegen.compile_program` 构成，语义保持定理
（`:1688`、`:1739`、`compile_st_to_sasm_core` `:2007`、`compile_determinism` `:2216`）
都建立在这个组合上。

而生产入口调用的是 `global_codegen.compile_program_gc`（`veristc_main.ml:221,347`），
它额外串入 `csites`（调用点表）与 `fbctx`（self 相对字段上下文）。针对 `compile_program_gc`
的定理确实存在，但集中在 WS-C 段（`:2228-2493`），内容是 CALL 的**结构性质**
（类型段/函数段长度、被调目标存在、形参数 ≤ 局部槽位数），**不含端到端语义保持**。

按项目既有决策，这是有意的：结构证明留在 `codegen.v`，工程扩展在 `global_codegen.v` 推进，
不触碰已证明结构。模型把它画成一条边界而不是缺陷，但它的直接后果应当被明确记录：
**"通过 `veristc -c` 产出的镜像"与"被端到端定理覆盖的镜像"不是同一个集合。**

## 运行站内部：一个周期里到底发生了什么

**`svm`**（`core/svm.c:257-277`）周期循环体只有三件事：`vm_run` → 打印结果 → `clock_nanosleep` 绝对定时。
`vm_run`（`safeasm_interp.c:1164-1178`）→ `vm_execute_cycle`（`:259-1096`）是
`while (frame->pc < body_size)` 加一个大 opcode switch，每指令递增 `cycle_count`
并对照 `safety.cycle_limit`（`:265-268`）。它的周期体内没有任何 I/O 步骤 ——
这是**有意的分工**，不是缺口：`svm` 是纯执行器，用于单元测试与黄金时间线复算。

**`sim`**（`sim/sim_main.c:273`）才走完整 I/O 周期：`io_mapping_cycle`（`io/io_mapping.c:254-269`）
= `read_all`（硬件→工程量→写 `vm->memory`）→ `vm_run` → `write_all`。
两条前置修复是它能跑通的原因（G0/W2'-W3）：
① `loader.c:207,210` 逐条真读 IOMAP 的 float64 scale/bias 并拒绝非有限值（此前硬写 `1.0`/`0.0` 后跳过 16 字节）；
② `io_mapping_init`（`io/io_mapping.c:86` @ `sim_main.c:240`）把 `SasmModule.iomap` 桥接成
`IOMappingTable`，且 IOMAP 的 `mem_offset` 由编译器按名向 `build_global_env` 解析，
与段 7 报出的全局槽位**同源**（否则运行站写入的位置与程序读写的变量不是同一块内存）。
数据面出口是 `sim --watch` 的 stdout JSONL 帧（`sim/watch.c`）：符号名 → 段 7 地址 → 数值。
原先零调用点的 `vm_scan_cycle` 与 `svm.c` 里的 `io_mapping_cycle` 同名桩已一并删除。

**`veristc-agent`**（`agent/agent_main.c`）是第三个主程序：装载首镜像 → `vm_init` →
逐周期 `vm_run`，在**周期边界**（`vm_run` 已返回、下一扫描未开始）提交换版：
`dl_rx_pump`（`hotstandby/download_wire.c:226`，HMAC 先验 + CRC 后验）→ `dl_stage_image`（`download.c:510`）
→ `dl_apply_switch`（`download.c:543`）= `dl_commit_switch` 换槽 + `vm_rebind` 冷启动重绑
（`agent_main.c:473`）；健康窗内出错则 `dl_rollback` 回上一版本，仅一级（`agent_main.c:490`）。

**双机热备仍未接入**：状态机、快照、脏页同步、增量补丁的函数都在，`hs_master_cycle` 也确实调 `vm_run`
（`state_machine.c:333`），但 `hs_run_cycle` / `hs_master_cycle` / `hs_standby_cycle` /
`hs_sync_cycle` 四个周期入口全仓零调用点，`agent` 只上报角色不跑主备周期；
解释器的 STORE 路径从不 `hs_dirty_mark`（`snapshot.c:129` 唯一调用者在测试里）；
`hs_chan_shmem_init` 把通道指针全置 NULL（`sync.c:75-77`）。
`compute_diff`/`apply_patch` 也在 —— 但不在 `agent` 的链路上（G0 只做全量镜像）。

## 关键关系一览

| 关系 | 性质 | 证据 |
| --- | --- | --- |
| `veristc` → `.sasm` | 文件写（定宽小端 + 段 7 + OCaml 侧 CRC32） | `veristc_main.ml:499`（组装）`:501-510`（写文件） |
| `.sasm` → `svm` / `sim` | 文件读（fread 进 2MB 静态缓冲，同一条装载路径） | `veri-runtime/core/svm.c:73-96`、`sim/sim_main.c:90` |
| `.sasm` → `veristc-agent` | 经下装帧（HMAC+CRC32）而非直接读盘 | `hotstandby/download_wire.c:226` → `download.c:482` |
| `svm` → 物理 I/O | **按设计不接**；带 I/O 的周期在 `sim` | `veri-runtime/core/svm.c:257-277` vs `sim/sim_main.c:273` |
| `sim` → I/O 硬件 | 软件后端（`.plant` + 虚拟时钟），非真实通道 | `sim/sim_io.c`、契约 `spec/simulation-spec.md` §1 |
| 生产 `VM_Interface` 后端 | **缺失**：只有 `sim_io.c`（软件）与不可构建的 RT-Thread 层 | `veri-runtime/rtos/abstract.h:77-288` |
| `libvm_hs` → `veristc-agent` | 库内函数调用，**已链接** | `download.c:543` + `veri-runtime/Makefile:182` |
| 热备周期封装 → 任何主程序 | **无调用者**（Phase 3 遗留，传输层为共享内存） | `state_machine.c:371`、`sync.c:253` |
| 证明层 → 生产层 | 共用类型定义，不共用被证明的函数 | `compiler_correctness.v:85-99` vs `veristc_main.ml:486` |
| Coq → OCaml | 构建期 Extraction，`veristc_main.ml` 为手写例外 | `make -C veri-stc extract veristc` |

## 不确定项（建议优先确认）

1. **双机热备仍未接入任何主程序。** `hs_*_cycle` 四个周期入口零调用点、脏页只在测试里标记、
   `hs_chan_shmem_init` 把通道指针置 NULL。`AGENTS.md` 把 Phase 3 标为"✅ 完成"，其口径是
   **单元/库级验证通过**而非**已接入运行站程序**；`veristc-agent` 的 `--role` 只做上报，
   不做主备同步（`spec/download-spec.md` §8 已把传输层列为范围外）。
   需要确认这是长期口径还是待补工作包。
2. **`compile_program_gc` 的端到端语义保持是否在有计划的 WS 里补齐**，还是长期接受
   "结构定理 + 测试"的覆盖口径。
3. **下装密钥与签名。** G0 用 `--key` 进程内静态注入（决策 D5），真签名与密钥管理推到 G4；
   在此之前，"谁能连上 agent 就能换程序"这条信任边界靠网络隔离而非密码学。
4. **数据面与传输面的首期取舍。** watch 为 stdout JSONL（决策 D4）、下装后端为文件/管道，
   socket 版待工程站联调时再定；`DlStream` 抽象已把协议与链路解耦，替换成本局限在实现两个回调。
