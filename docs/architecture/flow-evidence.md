# 流程图证据索引

对应 `flow-compile-pipeline.dot`、`flow-vm-runtime.dot`、`flow-vm-unwired.dot`。
基线 2026-10-14 工作树，VM 侧已于 2026-10-28 重导。C4 节点级证据见 `veristc.evidence.md`，本文件只记录**流程步骤**与**边语义**。

> **行号状态（2026-10-22）**：编译管线一节（下表 + `flow-compile-pipeline.dot`/`.svg`）的行号
> 已按当前工作树**全量重导**；v1.5.1 的三处变化已并入：解析期把 `inst.field` 融合为派生名
> `inst#field`、`prepare_program` 之后追加的展开后重名门禁（步骤 5b）、以及 `check_program_full_diag`
> 内新增的 `KIND=access` 字段封装门禁。
>
> **行号状态（2026-10-28，Phase 6 G0 / W2'-W5）**：VM 两张图（`flow-vm-runtime`、`flow-vm-unwired`）
> 与「VM 运行期主路径 / 未接入能力图」两节**已重导**，并并入四处结论变化：CRC 强制、scale/bias 真值、
> IOMAP 地址同源、`sim`/`veristc-agent` 成为运行站第二、第三个主程序。
> 编译管线一节同样在 2026-10-28 再重导一次（W1 改了 `veristc_main.ml` 的 CLI 与诊断通道、
> W2 加了段 7 与 IOMAP 量程覆盖，`typechecker.v`/`function_check.v`/`global_codegen.v` 行号随之漂移）。

## 编译管线（`flow-compile-pipeline.dot`）

触发：ST 工程师执行 `veristc -c|-a|-g|-x [-o out] [--json] input.st`。全部步骤为**同进程内函数调用**（in-process），
无异步、无外部服务；唯一的进程边界是最后的文件写。

> **行号状态（2026-10-28，G0/W1+W2）**：本表已再重导一次。W1 把 CLI 解析换成
> `parse_args`/`require_output`/`run`（选项可任意位置、`-c`/`-g` 缺 `-o` 判 11、不再写 CWD，
> 退出码 0/11/21/22/23/24/25），并新增 `--json` 全量诊断通道 `check_program_full_diag_rows`；
> W2 在 `-c` 出口串入 `emit_debug_section`（段 7）与 `patch_iomap_cal`（IOMAP 量程覆盖）。
> 步骤 12c 之后因此多了两个环节，表中以 12c.5 / 12c.6 标注。

| # | 步骤 | 载荷形态变化 | 证据 | 失败时 |
| --- | --- | --- | --- | --- |
| 0 | 命令行解析与模式分派 | `argv` → `action`（Analyze/Compile/Object/Verify/Help；无模式默认 `-a`） | `veristc_main.ml:808-841`（`parse_args`，默认值 `:840`）、类型 `:791`、分派 `:848-881` | 未知选项/多余位置参数 → `die exit_usage` `:833,:836`；`-c`/`-g` 缺 `-o` → `require_output` `:843-846` |
| 1 | `read_file` | 文件 → OCaml string → Coq String | `veristc_main.ml:57`，调用 `:424-426` | `Sys_error` → `die exit_usage` `:426` |
| 2 | `Lexer.lex` | string → `list token` | `veri-stc/src/lexer.v:377` @ `veristc_main.ml:215` | `None` → `die exit_syntax "lexer failed"` `:217`。v1.5.1：`#` 不在标识符文法内，源码出现 `#` 即在此失败（派生名不可书写） |
| 3 | `Parser.parse` | `list token` → `st_program` | `veri-stc/src/parser.v:1330` @ `veristc_main.ml:220` | `parse_fail_pos`(`parser.v:1354`)+`lex_offsets` 回推行列 `:222-233`。v1.5.1：`inst.field` 融合为 `inst#field`，AST 不新增构造 |
| 4 | 重名门禁 | `st_program` → `bool` | `veri-stc/src/typechecker.v:184` @ `veristc_main.ml:432` | `false` → `die exit_semantic` `:433-434` |
| 5 | `prepare_program` | `st_program` → `option st_program` | `veri-stc/src/function_check.v:1084` @ `:435` | `None` → FUNCTION 非法/缺 PROGRAM `:437`。内含 `expand_instances`（产出 `inst#field` 扁平全局） |
| 5b | 展开后重名门禁（v1.5.1） | `st_program` → `option 冲突名` | `veri-stc/src/typechecker.v:262` @ `:444-452` | `Some 名字` → 带名字拒绝（`duplicate_declaration_msg_catches_conflict` 不漏报 / `..agrees_with_check` 不误报） |
| 6 | `check_program_full_diag` | → `option 诊断串` | `veri-stc/src/function_check.v:1227` @ `:460-463`。内含 `check_program_access`(`:1034`，`KIND=access`) | `Some msg` → `die exit_semantic`；作用域/纯性/调用类型/字段封装/IOMAP 未绑定名 |
| 6j | （`--json` 分支）全量诊断 | → `list diagnostic` → NDJSON | `check_program_full_diag_rows` @ `:454-459` | 任一条即 `die exit_semantic ""`（文本行与 JSON 行同源，`:458`） |
| 7 | `normalize_program` | AST 规范化（保留函数） | `veri-stc/src/inline.v:647` @ `:464` | `None` → `die exit_internal` `:466` |
| 8 | `optimize_inline_program` | 叶子内联 + 死函数消除 | `veri-stc/src/inline.v:942` @ `:468` | `pou_list = 0` → `:470` |
| 9 | `desugar_program` | `st_program` → `corest_program` | `veri-stc/src/desugar.v:409` @ `:471` | 空函数列表 → `:473` |
| 10 | `analyze` | `corest` → 调用图/栈深/WCET | `veri-stc/src/analysis.v:242` @ `:474` | 递归 `:475-476`；栈深超限 `:477-481`（`exit_resource`） |
| 11a | `-a` 出口 | 分析结果 → stdout（含 `--json` 单行） | `veristc_main.ml:721-780` | **只报告不拒绝**（见 G7） |
| — | ↑ 但 `-a` 不在上表 1-10 这条管线上 | `analyze_st` 重复实现同 10 步 | `veristc_main.ml:721-780` vs `:423-482` | 缺递归/栈深拒绝门禁，仅打印（见 G7） |
| 12c | `compile_program_gc` | `corest_program` → `sasm_module` | `veri-stc/src/global_codegen.v:801` @ `veristc_main.ml:486` | 纯函数，无失败分支 |
| 13c | `encode_module` | `sasm_module` → `list Z` | `veri-stc/src/encoder.v:327` @ `:489` | 同上（Coq `PrimFloat.float` 无 IEEE-754 位 ⇒ IOMAP 量程此处为占位零） |
| 12c.5 | `patch_iomap_cal` | 占位量程 → 文件真值 float64 | `veristc_main.ml:375` @ `:488`，条目源 `compile_module_io_cal_info` `:491` | 段缺失/条目数或段长不符/通道号不符 → `die exit_internal`（`:397,:406,:413`），**不产出半成品镜像** |
| 12c.6 | `emit_debug_section` | 符号行 → 段 7（STRPOOL+SYMTAB） | `veristc_main.ml:293` @ `:494`，行源 `compile_program_debug_info`（`global_codegen.v`） | 排序/去重后拼接，插在尾部 CRC 之前 `:498-499` |
| 14c | `attach_crc32` | 字节串 → 带尾 CRC32 的字节串 | `veristc_main.ml:255` @ `:499` | 长度 < 10 → `die exit_internal` `:257` |
| 11g | `*_reloc_info` / `*_inst_info` / `*_sym_info` | `corest` → 扁平元数据行 | `veri-stc/src/global_codegen.v:1021,1037,1072` @ `veristc_main.ml:578,583,589` | 符号缺信息行 → `die exit_internal` `:594-595,:600-602` |
| 12g | `emit_svobj` | 元数据行 + IMAGE → `.svobj` 字节 | `veristc_main.ml:574-647`（IMAGE 复用 `:617`） | 同上 |
| 11x | `verify_svobj` | `.svobj` 字节 → 结构走查 | `veristc_main.ml:649-719` | 任一字段不符 → 报错 |

生命周期状态：源码 → 已解析 → 已通过门禁 → 已脱糖 → 已分析 → 已生成 IR → 已编码 → 已校验（仅 `-x`）。
**没有中间产物落盘**，除最终 `.sasm` / `.svobj` 外全部在内存中传递。

## VM 运行期主路径（`flow-vm-runtime.dot`）

触发：`svm [-d|-i|-s NAME|-l|-m] [-n CYCLES] [-p MS] file.sasm [expected] [local_index]`。
全部为单进程、同步、无并发；周期边界由 `clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME)` 提供
（`veri-runtime/core/svm.c:136-152`）。

> **2026-10-28 行号重导（G0/W2'-W5 之后）**：本节与 `flow-vm-runtime.dot`、`flow-vm-unwired.dot`
> 的 `文件:行号` 已按当前工作树重新 grep。三处**结论级**变化已并入：
> ① 加载期 CRC 改为无条件强制；② IOMap 的 scale/bias 改为真读、`mem_offset` 与全局槽位同源；
> ③ `svm` 内的 `io_mapping_cycle` 同名桩与零调用点的 `vm_scan_cycle` 已删除，
> I/O 闭环改由 `sim` 承担、镜像换版由 `veristc-agent` 承担。

| # | 步骤 | 语义 | 证据 |
| --- | --- | --- | --- |
| 1 | `fopen`+`fread` 进 2MB 静态缓冲 | 文件读，无动态内存 | `veri-runtime/core/svm.c:73-81`、`:29` |
| 2 | `sasm_load`：长度/magic/version | 结构校验，失败 `-1` | `veri-runtime/core/loader.c:110,118-127` |
| 3 | 段循环解析（Types/Funcs/Segments/IOMap/Code/Safety/WCET/Debug） | 结构校验，每处越界 `-1`；段 7 整段跳过，运行核不消费 | `veri-runtime/core/loader.c:135-303` |
| 4 | 尾部 CRC32 | 完整性校验，**值不符或全零 → `-2`**（G0/W5 起，"未计算即放行"后门已关闭） | `veri-runtime/core/loader.c:305-314` |
| 5 | `sasm_validate` | 安全参数校验（cycle_limit∈(0,1e6]/栈深/内存/入口/代码区间） | `veri-runtime/core/loader.c:327-367` @ `veri-runtime/core/svm.c:91` |
| 6 | `vm_init` | 建立 `VM{val_stack[1024], frame_stack[256], memory[1MiB]}` | `veri-runtime/core/vm.h:311-318` @ `veri-runtime/core/svm.c:95` |
| 7 | 周期循环判定 | `-n 0` 为连续；否则计数退出 | `veri-runtime/core/svm.c:257` |
| 8 | `vm_run` → `vm_execute_cycle` | 每指令 `cycle_count++`，超 `safety.cycle_limit` → `VM_ERR_CYCLE_LIMIT (-5)`；`cycle_limit==0` 在加载期即被拒 | `veri-runtime/core/safeasm_interp.c:1164-1178,259-1096,265-268` |
| 9 | 结果读取与打印 | `frame_stack[0].locals[0]` 或 `local[i]` | `veri-runtime/core/svm.c:264-266,118-131` |
| 10 | 期望值比对（可选） | 不符 → `return 1` | `veri-runtime/core/svm.c:268-271` |
| 11 | 休眠至下一周期 | 绝对定时，`-p MS` 默认 1000 | `veri-runtime/core/svm.c:136-152,276-277` |

装载路径的可达性：`veri-runtime/tests/vm-tests/test_vm.c:23` 的 `install_code()` 直接填充内存中的 `SasmModule`，
该文件无任何 CRC 代码，因此指令级单元测试**不经过**步骤 1-5。真正调用 `sasm_load` 的是六处：
`veri-runtime/core/svm.c:86`、`veri-runtime/sim/sim_main.c:90`、
`veri-runtime/hotstandby/download.c:456`（下装槽位装载，经 `libvm_hs` 被 `veristc-agent` 使用）、
`veri-runtime/tests/fuzz/sasm_fuzzer.c:168`、
`veri-runtime/tests/vm-tests/test_nuclear_protection_full_e2e.c:218`、`veri-runtime/rtos/rtthread/vm_rtthread.c:447`（未构建）。

失败传播：`vm_run != VM_OK` → 打印 → `return 3`（`veri-runtime/core/svm.c:258-261`）。
**`svm` 自身没有安全态迁移、没有重启策略、没有看门狗**；进程终止即系统终止。
`veristc-agent` 在其之上加了一层：健康窗内 `vm_run` 返回错误即 `dl_rollback` 回上一版本
（`veri-runtime/agent/agent_main.c:490`）——这是目前唯一的运行期故障收敛机制。

## 仿真与下装主路径（G0/W3-W5 新增；尚无独立 DOT，证据在此）

| # | 步骤（`sim`） | 语义 | 证据 |
| --- | --- | --- | --- |
| 1 | `sasm_load` | 与 `svm` 走同一条装载路径（上表步骤 2-5） | `veri-runtime/sim/sim_main.c:90` |
| 2 | `plant_load` | `.plant` 被控对象表，确定性步进 | `veri-runtime/sim/plant.c` @ `sim_main.c:231` |
| 3 | `io_mapping_init` | **桥接**：`SasmModule.iomap` → `IOMappingTable`（scale/bias 已在加载期真读） | `veri-runtime/io/io_mapping.c:86` @ `sim_main.c:240` |
| 4 | 对象表/映射一致性核对 | 通道缺失、方向不符、无映射段 → 启动即拒 | `sim_main.c:108-146,248` |
| 5 | `io_mapping_cycle` | `read_all` → `vm_run` → `write_all` | `veri-runtime/io/io_mapping.c:254-269` @ `sim_main.c:273` |
| 6 | `watch_cycle_frame` | 段 7 名字 → 地址 → 数值，stdout JSONL | `veri-runtime/sim/watch.c` @ `sim_main.c:276` |

| # | 步骤（下装） | 语义 | 证据 |
| --- | --- | --- | --- |
| 1 | `dl_rx_pump` | 逐帧 HMAC-SHA256 先验、CRC32 后验；任一不符即整镜像作废 | `veri-runtime/hotstandby/download_wire.c:226` |
| 2 | `dl_rx_finish` | 长度收满 + 末帧标记，回填镜像 | `download_wire.c:267` |
| 3 | `dl_stage_image` | 装入**非活动**槽：先 `sasm_load`+`sasm_validate`，失败即槽位作废 | `download.c:510` |
| 4 | `dl_apply_switch` | 周期边界提交：`dl_commit_switch` 换槽 → `vm_rebind`（冷启动语义） | `download.c:543` @ `agent_main.c:473` |
| 5 | 健康窗 → `dl_rollback` | 换版后窗口内出错则回退上一版本（仅一级） | `download.c:568` @ `agent_main.c:490` |

## 未接入能力图（`flow-vm-unwired.dot`）

本图的边全部是"设计上应当存在"或"代码里确实写了但没人调"，因此统一用虚线，
并在标签里写明调用者是谁。

| 能力 | 实现位置 | 真实调用者 | 断点性质 |
| --- | --- | --- | --- |
| `vm_scan_cycle` | 已删除（G0/W2'） | — | 全仓零调用点，连同 `svm` 的同名桩一并移除 |
| `io_mapping_cycle`（真） | `veri-runtime/io/io_mapping.c:254-269` | `sim/sim_main.c:273`、`test_io_mapping.c` | **已接入 `sim`**；`svm` 按设计仍不接 I/O |
| `io_mapping_read_all` / `write_all` | `veri-runtime/io/io_mapping.c:141,199` | `io_mapping_cycle` 内部；`vm_rtthread.c:335,347`（未构建） | 生产 `VM_Interface` 后端仍缺（现只有 `sim/sim_io.c` 软件实现） |
| `SasmModule.iomap → IOMappingTable` | `io_mapping.c:86`（`io_mapping_init`） | `sim_main.c:240` | **已桥接**（G0/W3：此前 scale/bias 在装载期即丢失） |
| `io_mapping_cycle`（桩） | 已删除（G0/W2'） | — | 链接垫片不复存在 |
| `hs_run_cycle`/`hs_master_cycle`/`hs_standby_cycle`/`hs_sync_cycle` | `state_machine.c:371,326,357`、`sync.c:253` | 仅 `hs_run_cycle → master/standby` 内部互调 | 零外部调用点（`veristc-agent` 只上报角色，不跑主备周期） |
| `hs_dirty_mark` | `snapshot.c:129` | `test_hotstandby.c:326,340,355-357,376-378,391-392,423,458,475,501` | 解释器 STORE 路径不标记 |
| `hs_chan_shmem_init` | `sync.c:75-77` | — | 把 send/recv/last_activity 全置 NULL |
| `dl_commit_switch` | `download.c:343` | `dl_apply_switch`(`:543`) ← `agent_main.c:473` | **已接入 `veristc-agent`**（周期边界原子切换 + 一级回滚） |
| `compute_diff` / `apply_patch` / `dl_prepare_download` | `download.c:100,210,308` | 仅 `test_hotstandby.c` | 增量补丁路径保留**未接线**（G0 只做全量镜像，`spec/download-spec.md` §8） |
| 下装密钥 | `agent_main.c` 的 `--key` | 进程内静态注入 | 无真实签名与密钥管理（决策 D5，真签名推到 G4） |
| RT-Thread 三线程 + `vm_wdt` | `vm_rtthread.c:483-505,398-427` | 无构建目标 | 不可编译（缺 `veri-runtime/core/loader.h`） |
