# VeriSTC 当前状态架构说明

范围：`/home/wei/veristc` 全仓库。视角：当前状态（AS-IS），不含目标态建议。
证据基线：2026-10-14 的工作树（含未提交改动）。配套图源见 `README.md` 清单。

## 系统边界

VeriSTC 是**一套独立工具链**，由两个互不通信的可执行程序组成，中间只靠一个文件契约连接：

```
ST 工程师 ──> veristc (上位机, OCaml 原生) ──写──> .sasm ──读──> svm (运行站, C11)
```

两者之间没有进程通信、没有共享库、没有网络协议。`.sasm` 是唯一接口，
其结构（Header / 段表 / IOMap / Code / Safety / CRC32）由 `spec/safeasm-spec.md` 与
`veristc/src/encoder.v` + `vm/loader.c` 两侧各自实现，靠测试保持一致而非类型系统。

第三个产物 `.svobj`（可重定位对象）目前**只有生产者，没有消费者** —— 链接器 `veristc-ld`
属 P3 计划，仓库内无实现。它是目标态，不是当前架构的一部分，模型里以 `TargetState` 标出。

## 真实的部署单元只有两个

`Makefile:72` 的 `all` 目标产出 `coq veristc vm-lib vm-hs vm-io svm`。其中：

- **`veristc`**（`veristc/extraction/veristc`，`Makefile:279-292`）—— 上位机编译器，唯一入口。
- **`svm`**（`vm/svm`，`Makefile:132-137`）—— 运行站程序，由 `svm.c + sasm_dump.c + loader.c +
  safeasm_interp.c` 直接 gcc 链接，**不链接任何 `libvm_*.a`**。

`libvm_core.a`、`libvm_io.a`、`libvm_hs.a` 三个静态库都被构建，但只有 `libvm_io.a` 和
`libvm_core.a` 被测试二进制链接（`Makefile:118-124`）；`libvm_hs.a` **没有被任何可执行目标链接**
（`test_hotstandby` 用 `#include "…/hotstandby/*.c"` 把源码内联进去，`Makefile:128-129`、
`tests/vm-tests/test_hotstandby.c:18-23`）。

`vm_rtthread.elf` 只出现在 `clean` 列表（`Makefile:66,388`），没有任何构建规则；
`rtthread` 目标即使设了 `RTTHREAD_SDK` 也只语法编译不链接（`Makefile:182-190`），
且 `rtos/rtthread/vm_rtthread.c:30` 引用了不存在的 `vm/loader.h`（`vm/` 下只有 `vm.h` 与
`sasm_dump.h`）。所以移植层是**当前不可编译的代码**，不是运行单元。

## 编译器内部：一条前端 + 三条后端分叉

`veristc/extraction/veristc_main.ml` 是手写的（不参与提取，`Makefile:281-282` 显式列为依赖）。
它把 Coq 提取出来的计算函数串成一条 `frontend()`（`veristc_main.ml:183-217`）：

```
read_file → Lexer.lex → Parser.parse → 重名门禁 → Function_check.prepare_program
→ check_program_full_diag → Inline.normalize_program → optimize_inline_program
→ Desugar.desugar_program → Analysis.analyze（递归拒绝 + 栈深门禁）
```

命令行分派发生在**最前面**（`veristc_main.ml:511-524`，无模式参数时默认 `-a`），四条路径互不共享入口函数：

- `-c` 与 `-g` 共用 `frontend()`，返回 `corest_program` 后分叉：
  `-c` 走 `compile_program_gc → encode_module → attach_crc32 → 写 .sasm`；
  `-g` 走 `compile_program_reloc_info / inst_info / sym_info → emit_svobj`，
  其中 IMAGE 段复用同一条 `gc + encode` 结果（`veristc_main.ml:361`）。
- `-a` 走 `analyze_st()`（`:457-495`），**不经过 `frontend`**，只 `printf` 四项指标不出文件。
- `-x` 输入是 `.svobj`，纯 OCaml 反向走查，不读 `.st` 也不经任何 Coq 代码。

一个值得注意的结构事实：`analyze_st` 与 `frontend` 是**十步逐行同构的两份实现**
（`:444-464` 对 `:184-209`），但 `analyze_st` 少了 `frontend:210-216` 的递归拒绝与栈深门禁，
只把这两项打印出来。也就是说"静态分析报告通过"与"编译通过"不是同一个判据，
且新增门禁时两处都要改 —— 这是模型里唯一被标为 `DuplicatedLogic` 的边界。

同理，`frontend` 在每个模式下各自完整执行一遍，所以 `-c` 与 `-g`
无法在一次调用内同时产出，只能跑两次编译。

分层原则是"Coq 出语义、OCaml 出字节"：Coq 侧只导出扁平元数据行
（`global_codegen.v:1005,1021,1056`），排序、去重、小端定宽布局全在手写 OCaml 里
（`veristc_main.ml:289-293,318-384`）。这与 `.svobj` 被定位为"信任+测试层、不进安全核"一致。

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

`svm.c:204-225` 的周期循环体只有三件事：`vm_run` → 打印结果 → `clock_nanosleep` 绝对定时。

`vm_run`（`safeasm_interp.c:1138-1156`）→ `vm_execute_cycle`（`:259`）是
`while (frame->pc < frame->body_size)` 加一个大 opcode switch（`:274-1088`），
每指令递增 `cycle_count` 并对照 `safety.cycle_limit`（`:265-269`）。

**周期体内没有任何 I/O 步骤。** 装载阶段解析出的 IOMap 段（`loader.c:175-193`）此后从未被
任何代码消费，且其 `scale_factor`/`bias` 在加载时就被硬编码为 `1.0`/`0.0` 并跳过 16 字节
（`loader.c:186-190`）。`vm_scan_cycle`（`safeasm_interp.c:1162`）与真实的
`io_mapping_cycle`（`io/io_mapping.c:254-269`）都实现了完整周期，但前者全仓零调用点，
后者所在的库没被 `svm` 链接；`svm.c:31-37` 提供了一个同名本地桩，仅用于解析
`vm_scan_cycle` 里那个 extern 引用，而桩自身同样没被主循环调用。

双机热备同理：状态机、快照、脏页同步、增量下装的函数都在，`hs_master_cycle` 也确实调 `vm_run`
（`state_machine.c:333`），但 `hs_run_cycle` / `hs_master_cycle` / `hs_standby_cycle` /
`hs_sync_cycle` 四个周期入口全仓零调用点，`dl_commit_switch` 只有测试调用，
解释器的 STORE 路径从不 `hs_dirty_mark`（`snapshot.c:129` 唯一调用者在测试里）。

## 关键关系一览

| 关系 | 性质 | 证据 |
| --- | --- | --- |
| `veristc` → `.sasm` | 文件写（定宽小端 + OCaml 侧 CRC32） | `veristc_main.ml:219-226` |
| `.sasm` → `svm` | 文件读（fread 进 2MB 静态缓冲） | `vm/svm.c:70-99` |
| `svm` → 物理 I/O | **契约存在，运行期未接入** | `rtos/abstract.h:77-288` vs `vm/svm.c:204-225` |
| `libvm_hs` → `svm` | 库内函数调用，但库未被链接 | `state_machine.c:333` + `Makefile:104-107` |
| 证明层 → 生产层 | 共用类型定义，不共用被证明的函数 | `compiler_correctness.v:85-99` vs `veristc_main.ml:221` |
| Coq → OCaml | 构建期 Extraction，`veristc_main.ml` 为手写例外 | `Makefile:256-292` |

## 不确定项（建议优先确认）

1. **AGENTS.md 的 Phase 完成标记与代码接入状态不一致。** 顶层指引把 Phase 2（I/O 集成 + RTOS
   适配）与 Phase 3（双机热备 + 增量下装）标为"✅ 完成"，但上述 I/O 未接入 `svm`、热备无运行入口、
   移植层不可编译都是当前代码事实。需要确认"完成"的判定口径是**单元/库级验证通过**，
   还是**已接入运行站程序**。这决定后续该做接入还是做文档修正。
2. **`.iomap` 独立文件是否仍计划交付。** `AGENTS.md` 声明编译器输出 `.sasm` + `.iomap`，
   实际 I/O 映射是 `.sasm` 内 Section type=3（`encoder.v:166-174`），无独立 `.iomap` 文件产出。
3. **CRC `stored==0` 放行是否为受控偏差。** 损坏文件确实被拒（`run_vm_checks.sh:209` 断言 `-2`），
   但 `loader.c:286-288` 对 `stored_crc == 0` 的未签名文件放行，`sasm_dump.c:544-551` 也把这种情况
   标为 `(未计算)`。因此冲突点是"完整性校验对未签名文件不强制"，而非检测失效；
   需确认是否限定在测试路径（可达 `sasm_load` 的仅 `svm.c:85`、`sasm_fuzzer.c:168`、
   `test_nuclear_protection_full_e2e.c:218`、`vm_rtthread.c:447` 四处）。
4. **`compile_program_gc` 的端到端语义保持是否在有计划的 WS 里补齐**，还是长期接受
   "结构定理 + 测试"的覆盖口径。
