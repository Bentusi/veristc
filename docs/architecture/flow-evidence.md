# 流程图证据索引

对应 `flow-compile-pipeline.dot`、`flow-vm-runtime.dot`、`flow-vm-unwired.dot`。
基线 2026-10-14 工作树。C4 节点级证据见 `veristc.evidence.md`，本文件只记录**流程步骤**与**边语义**。

> **行号状态（2026-10-22）**：编译管线一节（下表 + `flow-compile-pipeline.dot`/`.svg`）的行号
> 已按当前工作树**全量重导**；v1.5.1 的三处变化已并入：解析期把 `inst.field` 融合为派生名
> `inst#field`、`prepare_program` 之后追加的展开后重名门禁（步骤 5b）、以及 `check_program_full_diag`
> 内新增的 `KIND=access` 字段封装门禁。VM 两张图（`flow-vm-runtime`、`flow-vm-unwired`）不受本次
> 改动影响，仍为 2026-10-14 基线行号。

## 编译管线（`flow-compile-pipeline.dot`）

触发：ST 工程师执行 `veristc -c|-a|-g|-x input.st`。全部步骤为**同进程内函数调用**（in-process），
无异步、无外部服务；唯一的进程边界是最后的文件写。

| # | 步骤 | 载荷形态变化 | 证据 | 失败时 |
| --- | --- | --- | --- | --- |
| 0 | 命令行模式分派 | `argv` → 四种模式之一（默认 `-a`） | `veristc_main.ml:511-524` | 未知选项 → `usage` + `exit 1` `:520-522` |
| 1 | `read_file` | 文件 → OCaml string → Coq String | `veristc_main.ml:184-185` | 文件不可读则异常 |
| 2 | `Lexer.lex` | string → `list token` | `veri-stc/src/lexer.v:377` @ `:132` | `None` → `failwith "lexer failed"` `:134`。v1.5.1：`#` 不在标识符文法内，源码出现 `#` 即在此失败（派生名不可书写） |
| 3 | `Parser.parse` | `list token` → `st_program` | `veri-stc/src/parser.v:1330` @ `:136` | `parse_fail_pos`(`:1354`)+`lex_offsets` 回推行列 `:140-145`。v1.5.1：`inst.field` 融合为 `inst#field`，AST 不新增构造 |
| 4 | 重名门禁 | `st_program` → `bool` | `veri-stc/src/typechecker.v:184` @ `:189` | `false` → 命名冲突 `:190` |
| 5 | `prepare_program` | `st_program` → `option st_program` | `veri-stc/src/function_check.v:1084` @ `:191` | `None` → FUNCTION 非法/缺 PROGRAM `:193`。内含 `expand_instances`（产出 `inst#field` 扁平全局） |
| 5b | 展开后重名门禁（v1.5.1） | `st_program` → `option 冲突名` | `veri-stc/src/typechecker.v:259` @ `:200-208` | `Some 名字` → 带名字拒绝（`duplicate_declaration_msg_catches_conflict` 不漏报 / `..agrees_with_check` 不误报） |
| 6 | `check_program_full_diag` | → `option 诊断串` | `veri-stc/src/function_check.v:1191` @ `:209` | `Some msg` → 作用域/纯性/调用类型/字段封装 `:209-212`。v1.5.1：内含 `check_program_access`(`:1034`，`KIND=access`) |
| 7 | `normalize_program` | AST 规范化（保留函数） | `veri-stc/src/inline.v:647` @ `:213` | `None` → 规范化失败 `:215` |
| 8 | `optimize_inline_program` | 叶子内联 + 死函数消除 | `veri-stc/src/inline.v:942` @ `:217` | `pou_list = 0` → `:218` |
| 9 | `desugar_program` | `st_program` → `corest_program` | `veri-stc/src/desugar.v:409,62` @ `:220` | 空函数列表 → `:221` |
| 10 | `analyze` | `corest` → 调用图/栈深/WCET | `veri-stc/src/analysis.v:242` @ `:223` | 递归 `:224-225`；栈深超限 `:226-230` |
| 11a | `-a` 出口 | 分析结果 → stdout | `veristc_main.ml:488-495` | 无文件产物 |
| — | ↑ 但 `-a` 不在上表 1-10 这条管线上 | `analyze_st` 重复实现同 10 步 | `veristc_main.ml:457-495` vs `:183-231` | 缺递归/栈深门禁，仅打印（见 G7） |
| 11c | `compile_program_gc` | `corest_program` → `sasm_module` | `veri-stc/src/global_codegen.v:783` @ `:235` | 纯函数，无失败分支 |
| 12c | `encode_module` | `sasm_module` → `list Z` | `veri-stc/src/encoder.v:327` @ `:235` | 同上 |
| 13c | `attach_crc32` | 字节串 → 带尾 CRC32 的字节串 | `veristc_main.ml:171-181` | 长度 < 10 → `failwith` `:173` |
| 11g | `*_reloc_info` / `*_inst_info` / `*_sym_info` | `corest` → 扁平元数据行 | `veri-stc/src/global_codegen.v:1005,1021,1056` @ `:322,327,333` | 符号缺行 → `failwith` `:339,345` |
| 12g | `emit_svobj` | 元数据行 + IMAGE → `.svobj` 字节 | `veristc_main.ml:318-384`（IMAGE 复用 `:361`） | 同上 |
| 11x | `verify_svobj` | `.svobj` 字节 → 结构走查 | `veristc_main.ml:385-456` | 任一字段不符 → 报错 |

生命周期状态：源码 → 已解析 → 已通过门禁 → 已脱糖 → 已分析 → 已生成 IR → 已编码 → 已校验（仅 `-x`）。
**没有中间产物落盘**，除最终 `.sasm` / `.svobj` 外全部在内存中传递。

## VM 运行期主路径（`flow-vm-runtime.dot`）

触发：`svm [-d] [-n CYCLES] [-p MS] file.sasm [expected] [local_index]`。
全部为单进程、同步、无并发；周期边界由 `clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME)` 提供
（`veri-runtime/core/svm.c:119-136`）。

| # | 步骤 | 语义 | 证据 |
| --- | --- | --- | --- |
| 1 | `fopen`+`fread` 进 2MB 静态缓冲 | 文件读，无动态内存 | `veri-runtime/core/svm.c:70-83`、`:24` |
| 2 | `sasm_load`：长度/magic/version | 结构校验，失败 `-1` | `veri-runtime/core/loader.c:91,99-106` |
| 3 | 段循环解析（Types/Funcs/Segments/IOMap/Code/Safety） | 结构校验，每处越界 `-1` | `veri-runtime/core/loader.c:111-281` |
| 4 | 尾部 CRC32 | 完整性校验，不匹配且 `stored!=0` → `-2`；`stored==0` 放行（未签名文件不强制） | `veri-runtime/core/loader.c:283-289` |
| 5 | `sasm_validate` | 安全参数校验（cycle_limit/栈深/内存/入口/代码区间） | `veri-runtime/core/loader.c:302-342` @ `veri-runtime/core/svm.c:90-93` |
| 6 | `vm_init` | 建立 `VM{val_stack[1024], frame_stack[256], memory[1MiB]}` | `veri-runtime/core/vm.h:309-321` @ `veri-runtime/core/svm.c:94` |
| 7 | 周期循环判定 | `-n 0` 为连续；否则计数退出 | `veri-runtime/core/svm.c:204` |
| 8 | `vm_run` → `vm_execute_cycle` | 每指令 `cycle_count++`，超 `safety.cycle_limit` → `VM_ERR_CYCLE_LIMIT`；`cycle_limit==0` 时不检查 | `veri-runtime/core/safeasm_interp.c:1138-1156,259-269` |
| 9 | 结果读取与打印 | `frame_stack[0].locals[0]` 或 `local[i]` | `veri-runtime/core/svm.c:211-213,101-117` |
| 10 | 期望值比对（可选） | 不符 → `return 1` | `veri-runtime/core/svm.c:215-218` |
| 11 | 休眠至下一周期 | 绝对定时，`-p MS` 默认 1000 | `veri-runtime/core/svm.c:119-136,223-224` |

装载路径的可达性：`veri-runtime/tests/vm-tests/test_vm.c:23` 的 `install_code()` 直接填充内存中的 `SasmModule`，
该文件无任何 CRC 代码，因此指令级单元测试**不经过**步骤 1-5。真正调用 `sasm_load` 的只有四处：
`veri-runtime/core/svm.c:85`、`veri-runtime/tests/fuzz/sasm_fuzzer.c:168`、
`veri-runtime/tests/vm-tests/test_nuclear_protection_full_e2e.c:218`、`veri-runtime/rtos/rtthread/vm_rtthread.c:447`。

失败传播：`vm_run != VM_OK` → 打印 → `return 3`（`veri-runtime/core/svm.c:206-208`）。
**没有安全态迁移、没有重启策略、没有看门狗**；进程终止即系统终止。

## 未接入能力图（`flow-vm-unwired.dot`）

本图的边全部是"设计上应当存在"或"代码里确实写了但没人调"，因此统一用虚线，
并在标签里写明调用者是谁。

| 能力 | 实现位置 | 真实调用者 | 断点性质 |
| --- | --- | --- | --- |
| `vm_scan_cycle` | `veri-runtime/core/safeasm_interp.c:1162`（声明 `veri-runtime/core/vm.h:349`） | 无 | 零调用点 |
| `io_mapping_cycle`（真） | `veri-runtime/io/io_mapping.c:254-269` | 仅 `vm_scan_cycle`（死）与 `test_io_mapping.c:422` | 库未被 `svm` 链接 |
| `io_mapping_read_all` / `write_all` | `veri-runtime/io/io_mapping.c:141,199` | `test_io_mapping.c:204,239,270,281,304`（mock）、`vm_rtthread.c:335,347`（未构建） | 消费者均不在可部署路径 |
| `io_mapping_cycle`（桩） | `veri-runtime/core/svm.c:31-37` | 无（仅为解析 extern 符号而存在） | 链接垫片 |
| `hs_run_cycle`/`hs_master_cycle`/`hs_standby_cycle`/`hs_sync_cycle` | `state_machine.c:371,326,357`、`sync.c:253` | 仅 `hs_run_cycle → master/standby` 内部互调 | 零外部调用点 |
| `hs_dirty_mark` | `snapshot.c:129` | `test_hotstandby.c:326,340,355-357,376-378,391-392,423,458,475,501` | 解释器 STORE 路径不标记 |
| `hs_chan_shmem_init` | `sync.c:75-77` | — | 把 send/recv/last_activity 全置 NULL |
| `dl_commit_switch` | `download.c:332-346` | `test_hotstandby.c:561,581` | 仅测试驱动 |
| RT-Thread 三线程 + `vm_wdt` | `vm_rtthread.c:483-505,398-427` | 无构建目标 | 不可编译（缺 `veri-runtime/core/loader.h`） |
