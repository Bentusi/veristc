# C4 模型证据索引

对应 `veristc.structurizr.dsl`。基线 2026-10-14 工作树，**2026-10-28 随 Phase 6 G0（W1-W6）全量重推**：
行号按当前文件重新定位，运行站从「一个 svm」改为「三个主程序 `svm` / `sim` / `veristc-agent`」。
置信度定义：**High** = 代码/构建文件直接可见；**Medium** = 间接信号或仅文档；**Target** = 计划态无实现。

## 节点

| 节点 id | 证据（文件:行） | 置信度 |
| --- | --- | --- |
| `stEngineer` | `veri-stc/extraction/veristc_main.ml:808-841` 命令行分支；`AGENTS.md` 架构概览。无 GUI/IDE 代码 | Medium（仅 CLI 层可证） |
| `compiler` | `veri-stc/Makefile:85-99`（`$(VERISTC_BIN)`）；`veri-stc/extraction/dune:4-13`（`public_name veristc`）；根 `Makefile:55` 转发 | High |
| `svm` | `veri-runtime/Makefile:149-155`（只链 `-lvm_core`）；`veri-runtime/core/svm.c:155` | High |
| `sim` | `veri-runtime/Makefile:162-169`（链 `-lvm_io -lvm_core`）；`veri-runtime/sim/sim_main.c:273`；根 `Makefile:81` 转发 | High |
| `agent` | `veri-runtime/Makefile:176-182`（链 `-lvm_hs -lvm_core`）；`veri-runtime/agent/agent_main.c:406`；根 `Makefile:74` 转发 | High |
| `libIo` | `veri-runtime/Makefile:80-91`（`libvm_io.a`） | High |
| `libHs` | `veri-runtime/Makefile:93-104`（`libvm_hs.a`） | High |
| `rtthread` | `veri-runtime/Makefile:261-270`（需 `RTTHREAD_SDK`，不在 `all`）；`veri-runtime/rtos/rtthread/vm_rtthread.c:30` 引用不存在的 `veri-runtime/core/loader.h` | High（"未构建且不可编译"这一状态） |
| `qaBin` | `veri-runtime/Makefile:106-143,188-249` | High |
| `stSrc` / `sasmFile` / `svobjFile` | `veri-stc/tests/st-examples/`；`veristc_main.ml:484-499` / `:574-647`；根 `Makefile:118-136` 产出黄金制品 | High |
| `plantFile` | `veri-runtime/sim/plant.c:220-345`；`veri-runtime/sim/plants/closed_loop.plant`；协议 `spec/simulation-spec.md` | High |
| `watchFrames` | `veri-runtime/sim/watch.c:264-290`；协议 `spec/simulation-spec.md` §4 | High |
| `dlStream` | `veri-runtime/hotstandby/download_wire.c:226,267`；协议 `spec/download-spec.md` | High（文件传输）/ socket 属 Target |
| `coqToolchain` | `veri-stc/Makefile:35-82`（coqc → extraction）；`veri-stc/dune-project:1-19` | High |
| `rtosSdk` | `veri-runtime/Makefile:261-270`（`RTTHREAD_SDK` 判定） | High |
| `ioHardware` | `veri-runtime/rtos/abstract.h:41-52,77-288,294`；软件后端 `veri-runtime/sim/sim_io.c:17-60` | High（协议存在）/ 生产后端未接入 |
| `qaTools` | `veri-runtime/Makefile:252`；`veri-runtime/run_misra_check.sh` | High |
| `futureLinker` | `AGENTS.md` .svobj 约定（P3 计划）；仓库内 `grep veristc-ld` 无实现 | Target |

### 编译器组件（`veristc.compiler`）

全部为 High，证据即调用点与定义点：

`cli` `veristc_main.ml` 全文（手写，`veri-stc/Makefile:85` 显式依赖）·
`lexer` `veri-stc/src/lexer.v:377` @ `veristc_main.ml:215` ·
`parser` `veri-stc/src/parser.v:1330,1354` @ `:220-233`（v1.5.1：`inst.field` 在此融合为 `inst#field`）·
`dupchk` `veri-stc/src/typechecker.v:184` @ `:432-434`；展开后再跑一次 `duplicate_declaration_msg` `:262` @ `:444-452` ·
`funcCheck` `veri-stc/src/function_check.v:1084,1227,1034,1608` @ `veristc_main.ml:435-461`（`--json` 走全量行 API）·
`inline` `veri-stc/src/inline.v:647,942` @ `:464-468` ·
`desugar` `veri-stc/src/desugar.v:409` @ `:471` ·
`analysis` `veri-stc/src/analysis.v:242` @ `:474-481` ·
`gcCodegen` `veri-stc/src/global_codegen.v:801`（`resolve_io_map:61`、`build_global_env:46`）@ `:486,617` ·
`relocMeta` `veri-stc/src/global_codegen.v:1021,1037,1072,1154,1172`，别名表 `:934` @ `:491,496,578-589` ·
`encoder` `veri-stc/src/encoder.v:327` @ `:489,622`（IOMAP scale/bias 此处只写占位零）·
`iomapPatch` `veristc_main.ml:375-421` @ `:488-492,620-625` ·
`debugEmit` `veristc_main.ml:293-335,337-368` @ `:493-499` ·
`crcHost` `veristc_main.ml:255-267` @ `:499` ·
`svobjEmit` `veristc_main.ml:574-647` ·
`svobjVerify` `veristc_main.ml:649-719` ·
`analyzeSt` `veristc_main.ml:721-780`（与 frontend 重复，无递归/栈深门禁）·
`dataTypes` `veri-stc/spec/safest.v:357`（`st_program`）、`:94`（`derived_field_sep = "#"`）、`veri-stc/spec/safeasm.v:282,293`、`veri-stc/extraction/dune:4-13` ·
`proofLayer` `veri-stc/spec/compiler_correctness.v:19-22,85-99,1688,1739,2007,2204,2216,2228-2493`、`veri-stc/Makefile:35-82` ·
`deadCode` `veri-stc/extraction/extraction.v:40-63`；`veri-stc/src/codegen.v:1077`、`veri-stc/src/global_codegen.v:289`、`veri-stc/src/inline.v:367`、`veri-stc/src/typechecker.v:626`

### svm 组件（`veristc.svm`）

`svmMain` `veri-runtime/core/svm.c:155-248,257-278` ·
`fileRead` `veri-runtime/core/svm.c:33,71-98` ·
`loader` `veri-runtime/core/loader.c:110,118-127,135-303,305-314,327-367` + `veri-runtime/core/svm.c:86-93` ·
`iomapLoad` `veri-runtime/core/loader.c:199-215`，`read_f64` `:65`；`svm -m` 打印 `veri-runtime/core/svm.c:103-116` ·
`symQuery` `veri-runtime/core/svm.c:217-236` + `veri-runtime/core/sasm_dump.c:288`、`veri-runtime/core/sasm_info.c:261,346` ·
`interp` `veri-runtime/core/safeasm_interp.c:259-1096,265-268,577,594,1164-1178` + `veri-runtime/core/vm.h:147-148,311-321`

已删除的旧节点：`ioShim`（`svm.c` 内的 `io_mapping_cycle` 同名桩）与 `scanCycle`
（`vm_scan_cycle`）—— 全仓 `grep vm_scan_cycle` 现无匹配，桩与死入口一并移除，
故 svm 不再引用 libvm_io 的任何符号。

### sim 组件（`veristc.sim`）

`simMain` `veri-runtime/sim/sim_main.c:90-92,240-290,273` ·
`plant` `veri-runtime/sim/plant.c:150-219,220-345,347-365` ·
`simIo` `veri-runtime/sim/sim_io.c:17-60`（`VM_Interface` 软件实现，虚拟时钟）·
`watch` `veri-runtime/sim/watch.c:82-135,177-207,264-290` + `sim_main.c:251-254,275-276,287-289`

### agent 组件（`veristc.agent`）

`agentMain` `veri-runtime/agent/agent_main.c:406-520,473,486-496,512-514` ·
`agentDl` `veri-runtime/agent/agent_main.c:269-320,286,299,305` + `veri-runtime/hotstandby/download_wire.c:226,267` ·
`agentKey` `veri-runtime/agent/agent_main.c:137-156,351,397` + `veri-runtime/hotstandby/download_wire.c:130` ·
`agentStatus` `veri-runtime/agent/agent_main.c:104-116,458`

### I/O 与热备组件

`ioInit` `veri-runtime/io/io_mapping.c:86-133`，名字解析 `:24-42` ·
`ioConv` `:51-62,64-76,78-84` ·
`ioRead` `:141-189` · `ioWrite` `:199-244` · `ioCycle` `:254-269` @ `sim/sim_main.c:273` ·
`hsSnap` `veri-runtime/hotstandby/snapshot.c:207,324,239-257,304-310`，脏页 `:129` ·
`hsSync` `veri-runtime/hotstandby/sync.c:92,119,158,178,205,230,253`，回调置空 `:75-77` ·
`hsSm` `veri-runtime/hotstandby/state_machine.c:98-255,326,333,357,371`（三个 `hs_*_cycle` 仍零调用点）·
`hsDl` `veri-runtime/hotstandby/download.c:482,510,543-559,568-588,381`（`sasm_load` 在 `:456`）·
`hsWire` `veri-runtime/hotstandby/download_wire.c:130,226,267`；`veri-runtime/hotstandby/hmac_sha256.c` ·
`rtWdt` `veri-runtime/rtos/rtthread/vm_rtthread.c:398-427,483-505` · `rtIo` `:335,347`

## 关系

| 关系 | 类型 | 证据 | 置信度 |
| --- | --- | --- | --- |
| `stEngineer → compiler` | 进程调用 | `veristc_main.ml:808-841`；根 `Makefile:55` | High |
| `compiler → sasmFile` | 文件写 | `veristc_main.ml:484-499` → `write_file:501` @ `:864` | High |
| `compiler → svobjFile` | 文件写 | `veristc_main.ml:574-647` → `write_file` @ `:873` | High |
| `sasmFile → svm` | 文件读 | `veri-runtime/core/svm.c:71-98,86` | High |
| `sasmFile → sim` | 文件读 | `veri-runtime/sim/sim_main.c:90-92` | High |
| `sasmFile → agent` | 首装进版本槽 | `veri-runtime/agent/agent_main.c:434` → `download.c:482,456` | High |
| `plantFile → sim` | 文件读 | `veri-runtime/sim/plant.c:220` @ `sim_main.c:231` | High |
| `sim → watchFrames` | stdout JSONL 写 | `veri-runtime/sim/watch.c:264-290` @ `sim_main.c:275-276,287-289` | High |
| `dlStream → agent` | 文件读 + 帧解析 | `veri-runtime/agent/agent_main.c:269-320,286`；`download_wire.c:226` | High |
| `svm → ioHardware` | 有意不含 I/O 同步 | `veri-runtime/core/svm.c:257-278` 循环体内只有 `vm_run`；I/O 归 `sim`，换版归 `agent` | High（分工，非缺口） |
| `libIo → sim` | 链接 + 逐周期调用 | `veri-runtime/Makefile:162-169`；`io_mapping.c:254` @ `sim_main.c:273` | High |
| `libHs → agent` | 链接 + 周期边界换版 | `veri-runtime/Makefile:176-182`；`download.c:543` @ `agent_main.c:473` | High |
| `libHs → svm` | 不存在 | `svm` 只链 `-lvm_core`（`veri-runtime/Makefile:151-155`） | High |
| `rtthread → libIo` | 函数调用 | `veri-runtime/rtos/rtthread/vm_rtthread.c:335,347` | High（但未构建） |
| `rtthread → svm` | 依赖但不成立 | `vm_rtthread.c:30` 引用不存在的 `veri-runtime/core/loader.h` | High（"不可编译"） |
| `qaBin → libIo` | 链接 + mock | `veri-runtime/Makefile:112-116`；`veri-runtime/tests/vm-tests/test_io_mapping.c:16,44-45` | High |
| `qaBin → libHs` | 源码内联或直接编源，不链归档 | `test_hotstandby.c:18-23`；`veri-runtime/Makefile:127-133,138-143` | High |
| `svobjFile → futureLinker` | 预期消费 | `AGENTS.md` .svobj 约定 | Target |
| `compiler → coqToolchain` | 构建期依赖 | `veri-stc/Makefile:35-99` | High |

## 刻意未建模的内容

- 测试用例与 golden 文件的内部结构（属测试套件，非架构单元）。
- `spec/safeasm-spec.md` 的字节布局细节（已由 `flow-compile-pipeline.dot` 的产物节点概括）。
- 团队/所有权边界：仓库内无 `CODEOWNERS`、无 owner 元数据，故模型不含 owner 字段。
- 运行时拓扑（进程/网络/环境）：属 `deployment-topology-analyzer` 范围，本模型不覆盖。
  三个主程序的部署形态目前只是"同一个二进制目录下的三个可执行文件"，没有跨机拓扑证据。
