# C4 模型证据索引

对应 `veristc.structurizr.dsl`。基线 2026-10-14 工作树。
置信度定义：**High** = 代码/构建文件直接可见；**Medium** = 间接信号或仅文档；**Target** = 计划态无实现。

## 节点

| 节点 id | 证据（文件:行） | 置信度 |
| --- | --- | --- |
| `stEngineer` | `veristc_main.ml:511+` 命令行分支；`AGENTS.md` 架构概览。无 GUI/IDE 代码 | Medium（仅 CLI 层可证） |
| `compiler` | `Makefile:279-292`；`veristc/extraction/dune:4-13`（`public_name veristc`） | High |
| `svm` | `Makefile:132-137`；`vm/svm.c:138` | High |
| `libIo` | `Makefile:92-98`（`libvm_io.a`） | High |
| `libHs` | `Makefile:104-110`（`libvm_hs.a`） | High |
| `rtthread` | `Makefile:62-66,182-190,388`；`rtos/rtthread/vm_rtthread.c:30`（引用不存在的 `vm/loader.h`） | High（"未构建且不可编译"这一状态） |
| `qaBin` | `Makefile:116-172,322-362` | High |
| `stSrc` / `sasmFile` / `svobjFile` | `tests/st-examples/`；`Makefile:141-167`；`veristc_main.ml:318-384` | High |
| `coqToolchain` | `Makefile:197,262-273,285-289`；`veristc/dune-project:1-19` | High |
| `rtosSdk` | `Makefile:184-190`（`RTTHREAD_SDK` 判定） | High |
| `ioHardware` | `rtos/abstract.h:41-52,77-288,294` | High（契约存在）/ 未接入 |
| `qaTools` | `Makefile:372-373`；`run_misra_check.sh` | High |
| `futureLinker` | `AGENTS.md` .svobj 约定（P3 计划）；仓库内 `grep veristc-ld` 无实现 | Target |

### 编译器组件（`veristc.compiler`）

全部为 High，证据即调用点与定义点：

`cli` `veristc_main.ml` 全文（手写，`Makefile:281-282` 显式依赖）·
`lexer` `src/lexer.v:377` @ `:132` ·
`parser` `src/parser.v:1330,1354` @ `:136,140`（v1.5.1：`inst.field` 在此融合为 `inst#field`）·
`dupchk` `src/typechecker.v:184` @ `:189` ·
`dupchk2` `src/typechecker.v:259` @ `:200`（v1.5.1：`expand_instances` 之后的重名门禁，报出冲突名）·
`funcCheck` `src/function_check.v:1084,1191` @ `:191,209`，v1.5.1 字段封装门禁 `check_program_access` `:1034` ·
`inline` `src/inline.v:647,942` @ `:213,217` ·
`desugar` `src/desugar.v:409,62` @ `:220` ·
`analysis` `src/analysis.v:242` @ `:223` ·
`gcCodegen` `src/global_codegen.v:783`，v1.5 指针指令 `:483,626` @ `:235,361` ·
`relocMeta` `src/global_codegen.v:1005,1021,1056`，别名表 `:918,1011`，行类型 `:836` @ `:322-333` ·
`encoder` `src/encoder.v:327` @ `:235,361` ·
`crcHost` `veristc_main.ml:163-181` ·
`svobjEmit` `veristc_main.ml:318-384` ·
`svobjVerify` `veristc_main.ml:385-456` ·
`dataTypes` `spec/safest.v:357`（`st_program`）、`spec/safest.v:94`（v1.5.1 `derived_field_sep = "#"`）、`spec/safeasm.v:282,293`、`extraction/dune:4-13`（spec 提取模块列入可执行 modules）·
`proofLayer` `spec/compiler_correctness.v:19-22,85-99,1688,1739,2007,2204,2216,2228-2493`、`Makefile:204-219,237-239` ·
`deadCode` `extraction/extraction.v:40-63`；`src/codegen.v:1077`、`src/global_codegen.v:269`、`src/inline.v:367`、`src/typechecker.v:623`

### SVM 组件（`veristc.svm`）

`svmMain` `vm/svm.c:138,204-225` ·
`fileRead` `vm/svm.c:24,70-99` ·
`loader` `vm/loader.c:91,99-106,111-281,283-289,302-342` + `vm/svm.c:90-93` ·
`interp` `vm/safeasm_interp.c:259-274,1088,265-269,577,594,1138-1156` + `vm/vm.h:147-148` ·
`dumpTool` `vm/svm.c:8` + `vm/sasm_dump.c:129-130,177-178` ·
`ioShim` `vm/svm.c:31-37`（对照 `vm/svm.c:205`、`vm/safeasm_interp.c:1162-1174`）·
`scanCycle` `vm/safeasm_interp.c:1162` + `vm/vm.h:349`（全仓零调用点）

### I/O 与热备组件

`ioRead` `vm/io/io_mapping.c:141-189` · `ioWrite` `:199-244` · `ioCycle` `:254-269` ·
缩放/限值 `:48-68,74-80` ·
`hsSnap` `vm/hotstandby/snapshot.c:207,324,239-257,304-310`，脏页 `:129` ·
`hsSync` `vm/hotstandby/sync.c:92,119,158,178,205,230,253`，回调置空 `:75-77` ·
`hsSm` `vm/hotstandby/state_machine.c:98-255,326,333,357,371` ·
`hsDl` `vm/hotstandby/download.c:100,210,266,276,297,332-346` ·
`rtWdt` `rtos/rtthread/vm_rtthread.c:398-427,483-505` · `rtIo` `:335,347`

## 关系

| 关系 | 类型 | 证据 | 置信度 |
| --- | --- | --- | --- |
| `stEngineer → compiler` | 进程调用 | `veristc_main.ml:511+`；`Makefile:143,158-159` | High |
| `compiler → sasmFile` | 文件写 | `veristc_main.ml:219-226` | High |
| `compiler → svobjFile` | 文件写 | `veristc_main.ml:318-384,543-545` | High |
| `sasmFile → svm` | 文件读 | `vm/svm.c:70-99` | High |
| `svm → ioHardware` | 应为读写，实际无 | `vm/svm.c:204-225` 循环体内无 I/O 调用；`vm/loader.c:186-190` scale/bias 被丢弃 | High（"未接入"这一点） |
| `libIo → svm` | 链接符号被本地桩替代 | `vm/svm.c:31-37` vs `vm/io/io_mapping.c:254` | High |
| `libHs → svm` | 库内函数调用，库未被链接 | `vm/hotstandby/state_machine.c:333`；`Makefile:104-107` 无 `-lvm_hs` | High |
| `rtthread → libIo` | 函数调用（唯一真实消费者） | `rtos/rtthread/vm_rtthread.c:335,347` | High |
| `rtthread → svm` | 依赖但不成立 | `vm_rtthread.c:30` 引用不存在的 `vm/loader.h` | High（"不可编译"） |
| `qaBin → libIo` | 链接 + mock | `Makefile:121-124`；`tests/vm-tests/test_io_mapping.c:16,44-45,204,239` | High |
| `qaBin → libHs` | 源码内联而非链接 | `tests/vm-tests/test_hotstandby.c:18-23`；`Makefile:128-129` | High |
| `svobjFile → futureLinker` | 预期消费 | `AGENTS.md` .svobj 约定 | Target |
| `compiler → coqToolchain` | 构建期依赖 | `Makefile:197,221-292` | High |

## 刻意未建模的内容

- 测试用例与 golden 文件的内部结构（属测试套件，非架构单元）。
- `spec/safeasm-spec.md` 的字节布局细节（已由 `flow-compile-pipeline.dot` 的产物节点概括）。
- 团队/所有权边界：仓库内无 `CODEOWNERS`、无 owner 元数据，故模型不含 owner 字段。
- 运行时拓扑（进程/网络/环境）：属 `deployment-topology-analyzer` 范围，本模型不覆盖。
