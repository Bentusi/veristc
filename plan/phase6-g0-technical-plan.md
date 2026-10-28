---
name: phase6-g0-technical-plan
description: 'Phase 6 G0 前置能力补齐的详细技术方案（五个产出物）。当实现 veristc CLI 机器可读接口、.sasm 符号名段、仿真后端、watch 通道、下装帧协议时必读。含 5 项已定决策与协议定义。'
---

# Phase 6 G0 — 五个产出物详细技术方案

本文是 `phase6-veriide.prompt.md` 中「G0 前置能力补齐」的实施级设计。G0 的验收总目标：
**IDE 侧能从 watch 读到真实变量数值**，且 `make coq` 保持绿色、无新增 `Admitted`。

## 0. 已定决策（本文其余部分的前提，勿在实现时重开）

| # | 决策 | 后果 |
|---|------|------|
| **D1** | G0 验收信号用 **DINT**，不要求 REAL | REAL 全链路缺口（见 §1.2）列为并行子项，不进 G0 关键路径 |
| **D2** | IOMAP 的 `st_var_name_offset` **降级为 reserved(=0)**，符号名/类型/地址全放新 **section 7** | IOMAP 条目保持现有 42 字节不动，历史 `.sasm` 全兼容；规范 §4.4 随之修订；质量位 `qc_offset` 继续悬空 |
| **D3** | `LOC` 只做到 **POU + 变量名**，语句级行列推到 G2 | 不触碰 `st_stmt`/`st_expr`（证明锥内，无位置字段） |
| **D4** | watch 首期用 **stdout 帧**，不引入 socket/shm | 验收可在 shell 里断言，无需先做前端 |
| **D5** | 下装首期用 **HMAC-SHA256** 共享密钥，真签名（Ed25519/HSM）推到 G4 | 「未签名镜像可加载」降级为待签阶段的已知限制，进风险清单 |

## 1. 现状核查结论（纠正过的两处前提 + 两个硬缺口）

### 1.1 前提纠正

| 原假设 | 实际 | 证据 |
|---|---|---|
| encoder 发射了 section 7 但内容填 0 | encoder **根本不发射 section 7**；所见占位 0 在 IOMAP（section 3）内 | `encode_module` 只发 TYPE/FUNC/MEM/IOMAP/CODE/SAFE/WCET：`veri-stc/src/encoder.v:327-343`；`SEC_DEBUG 7` 是 C 侧未使用宏 `veri-runtime/core/vm.h:169` |
| 实现与规范只差「没填实」 | **IOMAP 条目字节布局本身与规范冲突**：规范定 46 字节（含 `qc_offset` + 3 reserved），编码器与加载器各自实现 42 字节 | 规范 `spec/safeasm-spec.md:388-405`；编码 `encoder.v:155-164`；解码 `loader.c:175-194` |
| DEBUG 段已有 name→addr 表待填 | 规范 §4.8 **只定义字符串池**，全仓无 name→地址符号记录布局 | `spec/safeasm-spec.md:460-468` |
| LOC 需要新设计 | 位置机制**已存在且已在用**，仅覆盖解析错误 | `lex_offsets` `lexer.v:383-403`；`offset_to_line_col` + `parse_or_fail` `veristc_main.ml:104-149` |

### 1.2 缺口 A — REAL 浮点全链路不可用（D1 的由来）

三层同时断：

1. 词法无小数字面量产生路径 ⇒ `veristc -c p07_real_arith.st` 实测报 `parser failed at line 4, col 1`；
   特性探针矩阵把 p07 标为 **XFAIL-词法**（`veri-stc/tests/st-examples/feature-probes/README.md:17`），
   其 `golden/p07_real_arith.out` 是**期望值而非实测值**，runner 里标 `xfail` 不参与比对
   （`integration/run_feature_probes.sh:33`）。
2. `F32_CONST` / `F64_CONST` 的立即数位被编码成**全零**，注释写「post-process with OCaml」，
   但 `veristc_main.ml` 里**不存在该后处理**（只有 `attach_crc32`）：`encoder.v:216-217`。
3. `global_codegen.v` 对二元运算统一发 I32 指令，未做类型导向降级。

⇒ 若 G0 验收坚持 REAL 信号，必须先补这整条链（估 3-4 周独立子项）。D1 已决定绕开。

### 1.3 缺口 B — 字节编码不该进 Coq

`ident`→字节 在 Coq 侧无现成路径，且 `io_scale/io_bias` 是 Coq `float`，Extraction 对浮点位编码本就不可靠
（与缺口 A 同源）。已有正确先例：`.svobj` 由 **Coq 只导出语义三元组**
（`compile_program_sym_info` `global_codegen.v:1056-1078`），**字节由 OCaml 拼**（`emit_svobj` `veristc_main.ml:318+`）。
符号段照抄这个分层。

### 1.4 证明锥（决定哪些改动是 provable-additive）

`compiler_correctness.v`（实际位置 **`veri-stc/src/`**，AGENTS.md 目录树误列为 `spec/`）的依赖闭包 =
`safest, safeasm, st_semantics, asm_semantics, function_semantics, desugar, codegen, global_codegen, analysis, typechecker`。

**锥外**：`lexer.v`、`parser.v`、`function_check.v`、`inline.v`、`encoder.v`。
⇒ 产出物 1 全部改动、产出物 2 的 Coq 侧新增函数，**定理影响为零**。

### 1.5 容量实测

- 最大真实制品 `nuclear_rps_esfas_full.sasm` = **196,738 字节**；`DL_MAX_RAW_SIZE = 262144` 仅余 33% 上限。
- 核电用例 MEM 段 total memory = 9,504 字节 ⇒ 约 **2,376 个全局槽**，符号表规模按数千计。
- 每个全局槽恒为 **4 字节单字**：`sasm_value = int32_t`（`vm.h:203`）、offset stride 4（`global_codegen.v:37-44`）、
  解释器无 i64/f64 内存 load/store。**勿照抄 Coq 语义的 `read_f64_lo/hi` 双字概念**（`safeasm.v:493-496`），运行期从不用。
- `GLOBAL_BASE = 4096`（`global_codegen.v:23`）；I/O 映射变量另起于 1024。

---

## 2. 产出物 1 — 编译器机器可读接口（仅改 `veristc_main.ml` + `function_check.v`）

### 2.1 现状

- 诊断字符串构造器把已有的 `dg_pou` / `dg_var` **扔掉**，硬写 `" LOC=- "`：`function_check.v:87-94`。
  `diagnostic` 记录本身含 `dg_pou : ident`、`dg_var : option ident`（:61-66）⇒ **D3 要求的层级零成本可得**。
- **短路只报第一条**：`first_alias_diag`（:680-686）+ `check_program_full_diag_struct`（:1158-1179）。
- `KIND=` 共 9 值：`type / purity / declaration / control-flow / for-bound / reserved-name / missing-entry / alias / access`
  （`diag_kind_to_string` :68-79）。其中 `KIND=access`、`KIND=type` 已被
  `veri-runtime/run_vm_checks.sh:168,189` 与 `veri-stc/tests/compiler-tests/negative/*.st` 断言 ⇒ **词汇冻结，不得改**。
- 30 处 `failwith`，**无顶层异常 handler**（程序是 `let () =`）⇒ 一切诊断以 OCaml 未捕获异常出栈，
  **退出码恒为 2**；usage 错误才显式 `exit 1`。
- `-o` 只认输入文件后的固定槽位，位置错了**静默忽略**并回退默认相对名，写进 **CWD**
  （`out_path` `veristc_main.ml:530-535`，默认 `output.sasm` :539 / `output.svobj` :544，`write_file` :237-240）。

### 2.2 设计

**退出码约定**（新增，写入 `spec/safest-spec.md` 工具链节）：

```
0  成功
11 CLI 用法错误（含未给 -o）
21 词法/语法失败
22 语义诊断（KIND=* 任一）
23 资源上限拒绝（栈深/WCET/循环上界）
24 制品写出失败
25 内部异常（不应出现；出现即 bug）
```

**`KIND=` 九词汇与既有 71 项断言逐字不变**（实现结论修正）：文本 API **原样保留**
`LOC=-`（渲染器不动，避免任何断言风险），层级信息改由 `--json` 的
`loc` 字段承载，格式 `POU=<pou> VAR=<var|->`。语句级/端口级字节偏移推到 G2；
届时需先解决 AST 无位置字段的问题（锥内改动，另立方案）。

**`--json` 输出**：一行一诊断（NDJSON），字段固定：

```json
{"pou":"MAIN","var":"pid1#OUT","kind":"access","loc":"POU=MAIN VAR=pid1#OUT","msg":"..."}
```
注意 `var` 是**派生名**（`实例#字段`，`derived_field_sep`）。IDE 侧需据此反查画布上的块/连线，
故派生名到「块实例 + 端口」的拆分协议必须在 `veri-ide/schema/` 里固化，不可让前端各自猜 `#`。

**多条诊断**：新增 `check_program_full_diags : st_program -> list diagnostic`（返回**全部**而非首条），
**保留**现有单条函数与渲染器不动，只为兼容既有断言。

**异常收口**：`let () = try main () with ...`，把 `Failure m` 映射到上表退出码；`--json` 时 stderr 只出 JSON，
不再出现 `Fatal error: exception Failure(...)`。

**输出隔离（多租户）**：`-o/--out-dir` 全位置识别；**未给 `-o` 即判 11**，不再往 CWD 写默认名。
编译器进程不常驻不共享（每请求独立工作目录）由 IDE 后端 build-svc 保证，CLI 侧只需保证不写 CWD。

**分析阈值接入**：`analysis.v` 的 `check_all_loops_bounded` / `estimate_wcet` 目前算了不接拒绝路径，
拒绝策略在 OCaml 侧（`frontend` ml:183-231 / `analyze_st` ml:457-495）。G0 把阈值判定显式化为
退出码 23 + 一条 `kind="resource"` 诊断，**不改 analysis.v**。

### 2.3 验收（已达成）

- `veristc --json -c x.st -o out.sasm` 的 stdout 逐行可解析（本机无 `jq`，
  用 `python3` 的 `json.loads` 断言）；退出码 0/11/21/22/24 逐类断言。
- 既有 71 项 `run_vm_checks.sh` 断言 + `run_compiler_tests.sh` 全绿
  （后者基线由 accepted=20 增至 38，新增的第 3 步全部通过），
  且**负例断言的 `KIND=` 字符串与文本诊断整行逐字不变**（已写成显式断言）。
- 全量回归 `integration/run_tests.sh` 9/9 通过，`make coq` 绿色、无新增 `Admitted`。

---

## 3. 产出物 2 — `.sasm` 符号名段（section 7）

### 3.1 协议（需先写入规范）

`spec/safeasm-spec.md` 两处修订：

1. **§4.4 IOMAP**：`st_var_name_offset` 从「变量名字符串在 Debug Section 的偏移」改为
   **`reserved`，必须为 0**；条目字节数按实现定为 **42**（现状），删除 `qc_offset` + 3 reserved 字段，
   并注明质量影子内存为 v1.1 悬空项（对应 `safeasm.v:203-210` 无 `SEG_QUALITY`）。
2. **§4.8 DEBUG**：在现有字符串池之后追加符号表子块：

```
SEC_DEBUG = 7   （位置：WCET 之后、尾部 CRC32 之前；可选，缺失即无符号信息）
  STRPOOL : u32 count | { u32 len | byte[len] UTF-8 }*        # 沿用现规范 §4.8 定义
  SYMTAB  : u32 count | { u32 name_off | u32 mem_addr | u8 type_tag | u8 size | u16 flags }*
```

- 全字段小端定宽，非 LEB128（§2.1 纪律）。
- SYMTAB **按 name 升序、去重**，与 `.svobj` SYMTAB 同确定性纪律（附录 D）⇒ 保证 `compile_determinism`
  在字节层可复现。
- `size` **恒为 4**（§1.5）。保留字段以便将来真做双字类型。
- `type_tag` 直接取 `st_type` 的枚举序号。**实现时补全**：原方案只列 `BOOL=0..QUALITY=7` 八个，
  而 Coq 侧的 `st_type_tag` 必须覆盖全部 25 个构造子 ⇒ 冻结为 0..7 原样保留、8..24 追加
  （完整表见 `spec/safeasm-spec.md` §4.8），并规定序号永不复用、新类型只追加。
  REAL 虽数值不可信（缺口 A），**类型标签照发**，由 IDE 侧标注。

### 3.2 Coq 侧（纯新增）

新增 `compile_program_debug_info : corest_program -> list debug_row`，`debug_row = (name, addr, type_tag)`。
**定义域必须是 `corest_program`（脱糖后）而非 `st_program`** —— 因为地址唯一权威来源是
`build_global_env`，它的签名就是 `corest_program -> list (ident * Z)`（`global_codegen.v:45`）。
在 `st_program` 上另算一遍偏移会产生第二套地址真相，是本项目最典型的漂移源。
数据源 `cprog_global_vars : list st_var_decl` 同时带 `var_name` 与 `var_type`；
FB 实例字段此时已被 `expand_instances` 扁平成派生名全局（`实例#字段`），故符号表天然覆盖实例字段。

**关键**：现有 `build_global_env` 把 `st_type` **丢弃**了（只保 `ident * Z`，`global_codegen.v:37-47`）。
⇒ 新建一个带类型的平行取行函数，**不要**改 `build_global_env` 的签名（它是 codegen 链上的既有定义）。

不动 `sasm_module` 记录（`safeasm.v:282-301`）—— 它**在证明锥内**，加字段会波及所有构造点与模式匹配。
符号行以独立函数返回值传递，与 `compile_program_sym_info` 完全同构。

### 3.3 OCaml 侧（字节编码）

新增 `emit_debug_section`，与 `emit_svobj` 同层同风格（`put_u32` / `put_name` 复用）。
字符串内容由 OCaml 写（避开缺口 B），Coq 只给名字字符串与地址。
段插在 WCET 之后，`attach_crc32`（`veristc_main.ml:171-181`）自然把它纳入 CRC。

### 3.4 C 侧（实现落地：运行核零消费）

- **加载器不改**：未知 section id 走 `default:` 静默跳过（`loader.c:275-279`）⇒ 段 7 存在与否、
  内容是否完好，都不影响加载与执行；老制品无需重编译。段 7 的完整性由覆盖它的尾部 CRC32 保证，
  因此 **V12b 的执行者是主机侧解析器，不是安全加载器**。
  原方案写的「`SasmModule` 新增 `debug_blob/debug_len` 两字段 + 二分查找」**已放弃**：
  让下位机的静态结构为一个只被上位工具消费的东西变大，是把工具需求漏进了安全核。
- 符号解析全部在主机侧工具里（`sasm_info.c`）：
  `sym_find_body`（走段头定位段 7）+ `sym_parse`（校验池/表边界）+
  `sym_dump_rows`（打印），入口 `sasm_sym_file(path, name)`，`name==NULL` 即全列。
  CLI：`svm -s NAME <file>`（查一个，未命中/无段返回 1）、`svm -l`（全列）、
  `svm -i` 的 Sections 行与 Summary `Symbols:` 报告条数。
  这些工具本就 `malloc` 整个文件（靠抑制清单放行），新增代码未新增动态分配。
- `IOMapEntry.st_var_name_offset` 保持不解析（reserved，见 §4.4 与 D2 决策）；
  `io_mapping.c` 的 `parse_var_name` 路径不在本工作包动。

### 3.5 验收（已达成）

- `run_vm_checks.sh` 第 7 步 6 项（总数 71→77）：`svm -s 'pid1#U'` 解析出地址与 `DINT size=4`；
  未知名被拒（返回非 0）；地址落在 `[GLOBAL_BASE, total_memory)`；`-l` 行数 == `-i` 的
  `Symbols:` 条数且含派生名字（`#`）；同一 `.st` 两次编译字节完全相同（符号段确定性）。
- **推迟到 W4**：「按符号地址读出的值与黄金时间线第 k 周期一致」需要按地址读内存的通路，
  那正是 watch 帧（产出物 4）要建的东西，本包无法验证。
- 树内既有 `.sasm`（fuzz corpus + 黄金 + 探针）加载不受影响 —— `loader.c` 未改，
  且 `run_fuzzer.sh` 复跑通过。
- `make coq` 全绿、无新增 `Admitted`。

---

## 4. 产出物 3 — 仿真后端 `veri-runtime/sim/`

### 4.1 范围先砍（避免为未调用的接口写代码）

`VM_Interface` 有 25 个函数指针（`rtos/abstract.h:77-288`），但**生产代码真正调用的只有 2 个**：
`io_read`（`io_mapping.c:156`）与 `io_write`（:239）。
`io_group_read/write` 在 `io_mapping.c` 里是逐通道循环、**零调用点**；其余 21 个仅 RT-Thread 移植实现，
而该移植**根本编不过**（`vm_rtthread.c:30` include 了不存在的 `core/loader.h`）。

⇒ 后端只实现：`io_read / io_write / get_ticks / sleep / ms_to_ticks / ticks_to_ms / init / deinit`。
`IOChannelDesc`（abstract.h:41-52）全仓未使用，**不要**为它接线。

### 4.2 真正的阻塞是接线，不是后端

| # | 缺口 | 证据 | 动作 |
|---|---|---|---|
| 1 | ✅ 已清（W3）：发布的 `svm` **零 I/O**：主循环直接 `vm_run(&vm)`，从不建 `IOMappingTable` | `svm.c:215` | 新增 `sim` 主程序，走 `io_mapping_cycle` 全路径 |
| 2 | ✅ 已清（W2'）：`svm.c:33-39` 的 `io_mapping_cycle` **stub** 只为满足 `vm_scan_cycle` 的 extern；而 `vm_scan_cycle` 全仓**零调用者** | `svm.c:33-39`、`safeasm_interp.c:1162-1174`、`vm.h:349` | 删 stub；`svm` 改为链归档 |
| 3 | ✅ 部分（W2'）：直接链 `libvm_io.a` 进 `svm` 会**重复符号** `io_mapping_cycle` | `veri-runtime/Makefile:113-118`（重编源文件而非链 `build/lib`） | `svm` 已链 `libvm_core.a`；`libvm_io.a` 留待 `sim`（`svm` 不引用 I/O 符号，链了是空转） |
| 4 | ✅ 已清（W2'）：**量程/偏置被加载器丢弃**：硬写 `scale_factor=1.0; bias=0.0;` 后 `p += 16` 跳过文件里真实 double | `loader.c:186-190` | 加载器真读两个 float64 + 拒非有限值；OCaml 侧补齐「文件 ≡ IR」；`run_vm_checks.sh` 第 8 步断言生效 |
| 5 | 越限**不报错不跳闸**，只钳位 + `safety_violations++`；`io_mapping_cycle` 返回值只反映 I/O 传输错误 | `io_mapping.c:170-178, 223-230` | 保持钳位语义（改它属安全行为变更）；**把 `safety_violations` 透进 watch 帧**（§5） |
| 6 | ✅ 已清（W3）：真 `io_mapping_cycle` **从未被端到端测过**：只用 `(NULL,NULL)` 调 | `test_io_mapping.c:422` | `sim` 成为其第一个真实调用者；`integration/run_sim_e2e.sh` 钉住 12 周期黄金时间线 |
| 7 | ✅ 已清（W3 期间发现）：**IOMAP `mem_offset` 与全局槽位不同源**——`assign_io_offsets … 1024` 自行编号，变量在 `GLOBAL_BASE=4096`；映射写进去的地址与程序读写的变量不是同一块内存 | `codegen.v` `assign_io_offsets` vs `global_codegen.build_global_env` | `global_codegen.resolve_io_map` 按名向 `build_global_env` 取地址；未绑定名编译拒绝（GATE-7）；`run_vm_checks.sh` 第 8 步核对 `svm -m` 地址 ⊆ `svm -l` 地址 |

第 4 项是**独立于本方案的功能缺陷**，且是仿真有意义的前置条件（否则 plant 缩放全为 1:1、限值在 raw 上比）。
它与 D2 无冲突：float64 读出是**加载器侧**，不涉及 IOMAP 条目宽度变更（那 16 字节现在就在流里，只是被跳过）。

### 4.3 plant 配置格式（避开 YAML 陷阱）

工程源用 `sim/plant.yaml`，但 **C 侧不解析 YAML**（无解析器、禁 malloc、MISRA 21.x 顾虑）。
两层：

- **运行协议**：`.plant` 定宽行式表，`fgets` + 定长缓冲读入静态数组，字段
  `channel, dir, kind, gain, offset, min, max, init`。
- **工程源**：`sim/plant.yaml` 由上位工具（G1 的 project-svc）编译成 `.plant`。G0 阶段用一个几百行的
  参考转换器脚本顶上，位置 `veri-runtime/sim/plant_gen.py` 或 `veri-stc/tools/`，二选一后写进 AGENTS.md。

plant 动态模型首期只需三类原语（够 PID 闭环）：**常量 / 一阶惯性 / 斜坡**；通道数上限与
`IO_MAX_CHANNELS 64`（`io_mapping.h:31`）对齐。仿真必须**逐周期确定**，否则黄金时间线无法比对。

> **W3 落地时的偏差（已确认）**：`.plant` 运行协议已冻结进 `spec/simulation-spec.md` §1
> （9 列、四种 kind、raw 单位、九类拒绝、确定性论证）。`plant.yaml` 与 YAML→`.plant`
> 参考转换器**不在 G0 交付**，改由 G1 的 project-svc 承担 —— C 侧不该解析 YAML，
> 而转换器的天然归属就是上位工具；G0 阶段 IDE 侧还没有工程文件概念，先造转换器只会
> 造出一个没有用户的中间层。

### 4.4 多实例可行性：无需重构

解释器 / io / 热备全按 `VM *` 传参（`vm.h:332-334`）。真正的进程级单例只有
`g_vm_interface`（`abstract.h:294`）与热备 `static DownloadManager s_dl_mgr`（`download.c:266`）
—— 与「每工程一进程」模型天然一致。`VM` ~1 MB、`SasmModule` ~5 MB（code_pool 2 MB `vm.h:287`），
按进程隔离本就是内存上唯一合理选择。

---

## 5. 产出物 4 — watch 通道 `veri-runtime/sim/watch.c`

### 5.1 现状：从零建

全仓**无 socket / shm / mmap 代码**。`io_mapping_get_by_name`（`io_mapping.c:292-303`）存在但**是空的**：
只覆盖 ≤64 个 I/O 通道，且唯一调用方传 `dbg_buf=NULL, dbg_len=0`。

### 5.2 设计（D4：stdout 帧）

`sim` 增加 `--watch <name>[,<name>...]`，每扫描周期把一帧写 stdout，IDE 后端作为子进程管道消费。

> **实现与原 sketch 有四处偏差**（键名、拒绝策略、64 位与 `t_ms`/帧格式），冻结后的协议以
> `spec/simulation-spec.md` §4 为准，偏差理由见本文 §7 的「W4 落地补充」。下面的 sketch 保留作设计现场。

```
帧（JSONL，一周期一行）：
{"cycle":12,"status":0,"violations":0,"values":[{"name":"pid1#OUT","addr":4200,"type":2,"raw":1234,"eng":1234.0}]}
```

- `addr` 与 `type` 来自 section 7 符号表（§3）；**类型驱动解码**：一律 `memcpy` 4 字节小端自
  `vm->memory[addr]`（`memory[MEMORY_SIZE]` 1 MiB，`vm.h:307/317`），BOOL/INT/REAL 各按语义解释。
- `eng` 用真实 `scale/bias`（依赖 §4.2 第 4 项修复）；未修复前 `eng == raw`，帧里据此标注。
- `status` 透 `vm_run` 返回值；`violations` 透 `safety_violations`（§4.2 第 5 项）。
- 未知名不报错，产一条 `{"unknown":"..."}` 前置帧 —— IDE 需要知道是「符号不存在」还是「值为 0」。
- **只读**：watch 不写 `vm->memory`。变量写入/强制明确留在范围外（核级仪控需单独安全评审）。

带宽与实时性：1000 ms 周期 + 数十个符号 ⇒ stdout 行数可忽略。将来需要连续高频波形时再上 UDS，
G0 不做（D4）。

---

## 6. 产出物 5 — 下装帧协议 + agent

### 6.1 现状比文档描述的空

| 能力 | 实际 | 证据 |
|---|---|---|
| 结构性变更拒绝（−2） | `apply_patch` 是 static 且**全仓零调用者** ⇒ −2 从公开 API **不可观测** | `download.c:210-260`（−2 在 :232-235） |
| 周期边界原子切换 | `dl_commit_switch` **只被测试调用**；`hs_master_cycle` 不查下载管理器；`VM.module` 是 `const SasmModule *`，**无任何代码把运行中的 VM 重指到新镜像** ⇒ 链路最后一环缺失 | `download.c:332-363`、`state_machine.c:326-355`、`vm.h:310` |
| 回滚 | 实为「验证失败就不切」（活动槽从未被碰）；无运行后 N 周期健康检查回滚 | `download.c:345` |
| patch CRC | `hdr.crc32 = 0`，**从未计算** | `download.c:198` |
| 传输/分帧 | **不存在**；`sync.c` 只有共享内存，无 ACK/超时/重传（尽管头注释写「超时重传」）；`HS_CHAN_TCP` 是死宏 | `sync.c:12,158-199`、`hotstandby.h:114` |

首期按 Phase 6 决策只做**全量镜像**下装：分帧走 full-image 路径，
`compute_diff` / `apply_patch` 原地保留但**不进链路**（不删，留给结构变更能力补齐后）。

> 上表是 **W5 开工前**的核查记录。这些缺口已在 W5 全部闭合（`dl_stage_image` /
> `dl_apply_switch` / `dl_rollback` / `vm_rebind` / agent 主循环 / 帧 CRC+HMAC），
> 差异与落地位置见 §6.6；协议本体见 `spec/download-spec.md`。

### 6.2 传输抽象

```c
typedef struct { int (*feed)(void *ctx, uint8_t *buf, uint32_t cap, uint32_t *got);
                 int (*drain)(void *ctx, const uint8_t *buf, uint32_t len); } DlStream;
```
G0 只对接进程内 `pair`（socketpair/pipe）后端，在测试里验证状态机；真 UDS 推到 G4。
收益：**协议状态机与 MISRA 敏感的 socket API 解耦**，抑制清单只多一处。

帧：`MAGIC(4) | ver(1) | total_len(u32) | seq(u32) | flags(u16) | crc32(u32) | payload[n]`，定宽小端。
**全帧 HMAC-SHA256**（D5）覆盖 `ver..payload`，密钥由 agent 侧静态配置注入；校验不过即整镜像丢弃、
活动槽不动。上限 `DL_MAX_RAW_SIZE 262144` 提到与 1 MiB 内存模型一致（实测最大制品 196,738 B，仅余 33%），
并在 `run_vm_checks.sh` 加「超限镜像被拒」用例。

### 6.3 切换接线（本产出物真正的难点）

1. 去掉 `VM.module` 的 `const`（`vm.h:310`），提供 `vm_rebind(VM*, const SasmModule*)`
   —— C 侧改动，无证明影响，但**必须**全绿 `run_vm_checks.sh` 71 项。
2. `dl_commit_switch` 在**真实周期边界**被调用：`vm_run` 返回之后、下一次扫描之前（`svm.c:215-219` 同款位置）。
3. 提交后健康检查：跑 N 个周期，`vm_run` 连续失败即回切旧槽（当前完全没有这一步）。
4. 多工程多 agent 实例：`dl_*` 现绑 `s_dl_mgr` 文件静态。首期一进程一 agent ⇒ **保留静态但显式注明**，
   不做半成品句柄化。

### 6.4 关闭 `CRC==0` 后门（可独立早做）

现路径：`loader.c:283-289` —— `stored_crc != computed_crc` 时，若 `stored_crc == 0` 仍放行，
注释「legacy handcrafted development fixtures」。

**已实测零风险**：树内**所有** `.sasm`（2 个 fuzz corpus + 6 个黄金 + 14 个探针）的 stored CRC 全部非零
且与计算值完全相符；`sasm_fuzzer.c:165-170` 本就 `(void)` 丢弃 `sasm_load` 返回值；
`run_vm_checks.sh:277-289` 的损坏 CRC 用例翻的是 `size-5` 的**载荷**字节、stored 保持非零 ⇒
改严格校验**不破任何测试**。

改法：`stored_crc != computed_crc || stored_crc == 0` 一律 `return -2`（退化全零也拒）。

### 6.5 目标端 agent

新增 `veri-runtime/agent/`（Phase 6 文档写的 `vm/agent/` 需按新布局改名）：装载 + 周期执行 +
下装服务 + 角色上报。**不实现主备同步的传输层**（`sync.c` 仍是共享内存），那是 Phase 3 遗留、独立评审。

### 6.6 W5 落地补充（与 §6.1–§6.5 原方案的差异，均已按实现回填 `spec/download-spec.md`）

| 原方案 | 落地 | 理由 |
|---|---|---|
| §6.3-1 去掉 `VM.module` 的 `const` | **未做，也不需要**：`const SasmModule *` 是"指向 const 数据的非 const 指针"，`vm_rebind(VM*, const SasmModule*)` 直接改指针即可 | 少动一处核心结构，`run_vm_checks.sh` 无需为签名变更让路 |
| §6.2 帧 HMAC 用「静态配置注入」 | 密钥经 `--key <64 hex>` 传入；C 侧自持 SHA-256/HMAC（`hmac_sha256.c`），**不引 OpenSSL** | 目标端是 RTOS 且属安全核；OpenSSL 的初始化路径与依赖无法进 MISRA 子集 |
| §6.2 `DL_MAX_RAW_SIZE 262144` 提到 1 MiB | `DL_MAX_IMAGE = 1048576`（`download_wire.h`），`DL_MAX_RAW_SIZE` 直接取它 ⇒ 传输上限与版本槽容量同源，不再两处数字 | 实测最大制品 196,738 B；代价是版本槽 + 接收缓冲各 1 MiB 静态内存 |
| §6.2「G0 只对接进程内 pair 后端，在测试里验证状态机」 | 状态机单测用内存数组后端；**agent 侧后端是文件/管道/FIFO**（`--download-from`，含 `-` = stdin），比 pair 更接近真链路且无需 socket 代码 | 协议与链路 API 的解耦由 `DlStream` 承担，socket 仍推到 G4 |
| §6.3-3 提交后健康检查 | 健康检查归 **agent 主循环**（`--health-cycles`，任一 `vm_run` 失败即 `dl_rollback`），下装层不驱动周期 | 下装层不该知道"周期"这个调度概念；且这是 §6.1「链路最后一环缺失」真正补上的地方 |
| §6.3-4 多工程多 agent 实例 | `s_dl_mgr` 仍是文件静态，**一进程一 agent**，已在代码注释显式声明 | 不做半成品句柄化 |
| （未规划） | 发送端参考实现改用 **Python**（`integration/dl_frames.py`）而非复用 C | 两侧独立实现才能验证 MAC 约定；C 自证自永远测不出字节序/覆盖区写错 |
| （未规划） | 拒绝码分两层：传输层 `DlResult(-1..-10)`，下装层 `DL_RC_*(-101..-106)`，底层加载器码由 `dl_last_error()` 取 | 混用一套码会让"帧坏了"和"镜像坏了"在同一数字上不可区分 |
| （未规划） | 回滚只有一级深度（两槽 ⇒ `previous_slot` 是唯一落点，第二次返回 `NULL`）；版本号单调不回退 | 与 §6.1 的两槽现实一致，不假装有历史栈 |

验收锚点：`run_vm_checks.sh` 第 9/10 步（协议 + 切换单测，共 11 项）、
`integration/run_download_e2e.sh`（34 项：正向切换 / 六类拒绝 / 健康回滚 / CLI 协议）、
`run_sanitizer.sh` 第 5 步（两组单测的 ASan/UBSan 变体）。
§6.4 的 CRC 严格化已落地并新增「全零校验和被拒」用例，规范 V3 同步改写。

---

## 7. 工作包与顺序

```
W1  ✅ 产出物1 API 包装（function_check 全量诊断 + veristc_main CLI）
W1' ✅ 协议冻结：已落 spec/safeasm-spec.md §4.4/§4.8/V12b + spec/safest-spec.md 附录 D
        （退出码 + --json + 不写 CWD）+ spec/simulation-spec.md（**.plant 随 W3、watch 帧随 W4**）。
        下装帧 + HMAC 协议已随 W5 冻结进 spec/download-spec.md ⇒ **W1' 完结**。
W2  ✅ 产出物2 符号段（Coq 取行 + OCaml 编码 + 主机侧解析；**不改 loader**，见下）
W2' ✅ 产出物3 前置修复：loader scale/bias 真读 + svm 链归档 + 删 stub        独立可并行
W3  ✅ 产出物3 仿真后端 + plant 表（sim/plant.c + sim_io.c + sim_main.c + 闭环黄金；
        期间发现并修掉缺口 C —— IOMAP 的 mem_offset 与全局槽位不同源）
W4  ✅ 产出物4 watch stdout 帧（sim/watch.c + 段 7 地址解析复用 + 派生名语料；
        G0 总验收在此：帧的 addr/type/size 对 `svm -l`、value 对黄金时间线，26 项门禁）
W5  ✅ 产出物5：CRC 严格化 → 分帧/HMAC（自持实现 + 公开向量）→ 切换接线（vm_rebind +
        dl_stage_image/dl_apply_switch/dl_rollback）→ veristc-agent → 协议冻结进
        spec/download-spec.md（差异见 §6.6）
W6  门禁扩展：run_vm_checks.sh 加符号/watch/下装帧 3 组用例
```

W1 落地补充（与本方案原写的两处差异，已按实现回填文档）：

- 全量诊断走**新增并行函数** `check_program_full_diags` / `check_program_full_diag_rows`
  （`function_check.v` 尾部），不改动单条版；三趟检查（逐 POU / 别名 / 封装）各自由
  `first_*` 改为等价的 `_all` 收集版，收集顺序与旧版逐字一致 ⇒ JSON 首行恒等于文本行。
- 新增夹具 `veri-stc/tests/compiler-tests/cli/two_access_violations.st`：一处读内部 VAR、
  一处写 VAR_OUTPUT，用来钉住「一次编译报多条」与「文本只报首条」这两条相反方向的协议。
  它**不放进 `negative/`**，以免改变既有 `accepted=` 计数（现为 38）。
- 退出码断言全部落在 `run_compiler_tests.sh` 第 3 步，计入该脚本自身的 accepted/failed 汇总。
- 实测本机无 `jq`，NDJSON 校验用 `python3 -c 'json.loads'` 并带缺工具时的 SKIP 分支。

W2 落地补充（两处与本方案原写法不同，已按实现回填 spec）：

- **loader 不做零拷贝**：原方案想让 `loader.c` 把段 7 的字节指针挂进 `SasmModule`。
  实际不改 —— 安全核不消费符号，挂指针等于让运行期内存布局依赖上位工具需要的东西，
  还要为它扩 `SasmModule` 静态结构（下位机 BSS 变大）。改为段 7 走 `default:` 整段跳过，
  符号解析只发生在主机侧 `svm -s/-l/-i`（`sasm_info.c`），运行时零新增内存。
  段 7 内容的完整性由覆盖它的尾部 CRC32 保证，V12b 的校验者因此是主机工具而非加载器。
- **`type_tag` 取值表补全**：W1' 只冻结了 `BOOL..QUALITY` 八个序号，而 `st_type` 有 25 个
  构造子，Coq 侧必须全覆盖。现表为 0..7 原样保留 + 8..24 追加（`spec` §4.8 表），
  并规定序号永不复用、新类型只追加，`23=ARRAY`/`24=FB` 行给出块基址。
- 地址唯一来源落实为 `debug_rows_of` 与 `build_global_env` **逐槽对齐**：两边名字一旦
  对不上即停止发射（宁缺勿错），杜绝第二份地址真相。
- 门禁：`run_vm_checks.sh` 新增第 7 步（6 项，总数 71→77）钉住派生名可解析、
  地址落在 `[GLOBAL_BASE, total_memory)`、`-l` 与 `-i` 条数一致、同源码两次编译字节相同。

W2' 落地补充（§4.2 表第 2/3/4 项已清；第 1/5/6 项属 W3/W4，仍在原处）：

- **根因不止第 4 项，而是四层串供**：SafeST 无量程语法（`safest.io_entry` 只有
  名字/通道/方向/类型）⇒ `codegen.io_entry_to_sasm` 硬写 `PrimFloat.one / PrimFloat.zero`
  ⇒ `encoder.encode_io_entry` 把这两个值编成 `encode_u64 0`（浮点位拿不到，与 §4.5
  F32/F64 立即数同一缺口）⇒ `loader.c` 连这 16 字节都不读，再硬写一次 `1.0/0.0`。
  只修加载器会得到「文件写 0、运行用 1」的**新不一致**，所以两侧一起改：
  OCaml `patch_iomap_cal` 用 `compile_module_io_cal_info` 的 IR float64 覆盖那 16 字节
  （条目数 / 段长 / 逐条通道号三重核对，任一不符即拒绝产出制品），加载器 `read_f64` 逐条采信。
  **不变量：文件 ≡ IR**。发射值目前恒为 1.0/0.0，真量程由 W3 的 `.plant` 提供。
- **非有限值即拒**：`read_f64` 用 `!(v >= -DBL_MAX && v <= DBL_MAX)` 拒 NaN/±Inf
  （两个比较都为假才叫 NaN，写成 `v < -DBL_MAX || v > DBL_MAX` 会漏），返回 `-1`。
  量化为 spec 新增规则 **V10b**（§7.2）。
- **第 2/3 项按原计划清**：删 `svm.c` 的 `io_mapping_cycle` stub 与
  `safeasm_interp.c` 的 `vm_scan_cycle`（全仓零调用者）+ `vm.h` 声明；
  `$(SVM_BIN)` 改链 `build/lib/libvm_core.a`，不再重编 `loader.c`/`safeasm_interp.c`。
  `svm` 未链 `libvm_io.a` —— 它不引用任何 I/O 符号，链了也只是空转；
  W3 的 `sim` 才需要它（届时由 `sim` 定义 `g_vm_interface`）。
- **可见产出**：`svm -m <file.sasm>` 打印**加载后**的 I/O 映射（通道/方向/mem/位宽/
  scale/bias/安全限值），走 CRC → `sasm_load` → `sasm_validate` 同一条路径，
  所以它证明的是运行期真值，不是文件字节的复读。spec §5.0 已收录。
- 新黄金制品 `veri-stc/tests/st-examples/io_cal.st` → `build/sasm/io_cal.sasm`
  （根 `make build-io-cal`，已进 `build-tests`）。全仓此前**没有任何**带 IOMAP 段的
  ST 语料，段 3 从未被编译器→加载器链路测过，这个夹具是第 6 项「端到端未测」的最小补齐。
- `-g` 的 svobj 内嵌 IMAGE **同样过 `patch_iomap_cal`**：否则 P3 链接出来的 `.sasm`
  会带着 `scale=0` 的 IOMAP 条目（0 缩放把所有输入压成偏置），把缺陷埋进对象文件里。
- 门禁：`run_vm_checks.sh` 新增第 8 步（6 项，总数 **77→83**）：恒等量程透传、
  手工改写 scale/bias 后由加载器采信（0.5/100 与 -2/3.25 两通道独立）、
  NaN 量程被拒且报出 `sasm_load failed: -1`。无 `python3` 时整步 SKIP（沿用编译器测试的先例）。

W3 落地补充（§4.2 表第 1/6 项已清；第 5 项的 `safety_violations` 透进 watch 帧仍在 W4）：

- **缺口 C —— 仿真真正的阻塞点**（W2' 未预见，动手写后端时才暴露）：`codegen.v` 的
  `assign_io_offsets p.(cprog_io_mapping) 1024` 给 IOMAP 条目发了一套**私有编号**（1024 起步、
  4 递增），而全局变量由 `build_global_env` 从 `GLOBAL_BASE = 4096` 起分配。于是
  `io_mapping_read_all` 往 `vm->memory[1024]` 写传感器值，ST 程序读的是 `memory[4096+]` 的
  `ai0` —— **两侧永远不是同一块内存**，任何仿真都只会看到常量。这不是接线的边角，而是
  「闭环」这个词此前在仓库里从未真正成立。
- **修法守住单一真值**：新增 `global_codegen.resolve_io_map`，按 `IOMAP` 里书写的变量名向
  `build_global_env` 取地址（段 7 用的同一张表），`compile_program_g` / `compile_program_gc`
  两处组装点替换旧的 `assign_io_offsets`；`codegen.compile_program`（仅证明使用）保持原样不动，
  不触碰已证明路径。名字解析不到 ⇒ 编译拒绝（GATE-7，复用既有 `KIND=declaration`，
  不扩九词汇表）。可机检：`svm -m` 的每个 `mem=` 必须出现在 `svm -l` 的地址列
  （`run_vm_checks.sh` 第 8 步新增该项，总数 **83→84**）。
- **`.plant` 协议落在 `spec/simulation-spec.md`**（新建）：9 列定宽行式表、四种模型
  （CONST/LAG/RAMP/ACTUATOR）、raw 单位约定（缩放仍归 IOMAP，两侧不重复换算）、
  确定性论证（输入步进只读执行器与自身，行序无关）、九类解析即拒绝。
  **与原方案的偏差**：`sim/plant.yaml` + YAML→`.plant` 参考转换器**不在 G0 交付**，
  推到 G1 的 project-svc —— C 侧不解析 YAML（无解析器、禁 malloc），而转换器的真正归属
  本就是上位工具；G0 只冻结运行协议那一份。
- **后端只实现 8 个接口**（§4.1 的砍范围决定照原样执行）：`sim_io.c` 定义 `g_vm_interface`
  并填 `io_read/io_write/get_ticks/sleep/ms_to_ticks/ticks_to_ms/init/deinit`，其余留 NULL；
  `sleep` 空操作 + tick 由主程序按周期推进 ⇒ 时间线不依赖墙钟。虚拟时钟取 1 tick = 1 ms。
- **`sim` 是 `io_mapping_cycle` 的第一个真实调用者**（§4.2 第 6 项）：此前只有
  `test_io_mapping.c:422` 用 `(NULL, NULL)` 调过，端到端从未跑通。
- **程序与对象表一致性检查放在启动前**（退出码 2）：映射段每个通道须在表内且方向一致，
  否则映射层只是把故障通道标记 `fault` 后跳过 —— 时间线看起来"正常"却全是常量，
  这类静默失败正是仿真后端最不能有的性质。
- **演示与门禁**：`sim_closed_loop.st`（纯 DINT 积分控制器 + 抗积分饱和，按 D1）与
  `plants/closed_loop.plant`（一阶惯性 gain=1/8，二进制精确可复现）+ 12 周期黄金时间线
  `sim_closed_loop.golden.timeline`；`integration/run_sim_e2e.sh` 20 项（黄金比对、
  两次运行逐字节确定、两次编译逐字节确定、6 类畸形 `.plant` 拒绝、3 类一致性拒绝），
  已接入 `run_tests.sh`（第 8 步，全量 9→10 组）。`make sim-demo` 是给"看一眼"用的入口。
  （W4 加了第 6 步后此脚本共 26 项。）
- **构建纪律照 §8 执行**：`$(SIM_BIN)` 规则单独加 `-Werror`（老文件不回改），
  `sim/*.c` 三个文件已进 `run_misra_check.sh` 的 `DEFAULT_FILES`。
- 踩到并已写进 spec 的两个既有约定：`IOMAP` 块只能位于 `VAR_GLOBAL…END_VAR` 与
  `PROGRAM` 之间；`IF` 的产生式是 `END_IF ';'`（第 10 章若干 IEC 风格示例漏了分号，
  照抄即解析失败 —— 属示例笔误，G1 的图→ST 生成器必须以 §5.3 产生式为准）。

W4 落地补充（§5.2 的原设计有四处按实现回填，其余照原样执行）：

- **未知名改为「启动即拒」，不再产 `{"unknown":…}` 前置帧**：原方案担心 IDE 分不清
  「符号不存在」与「值为 0」。实现后取向更强的一条：把歧义消灭在周期循环之外
  （名字表整体验证，任一条不符即退出码 2、一个周期都不跑），比在流里多一个
  「消费者必须记得检查」的标记可靠。§4.6 列了全部拒绝情形。
- **键名 `raw`/`eng` → `value`/`raw`/`channel`**：核对 `io_mapping.c` 后确认
  `vm->memory` 里存的是**工程值**（读入时已 `raw*scale+bias` 并钳位），不是原始 ADC 码。
  原方案的两键命名会让人把 `raw` 读成内存内容。现语义冻结为：`value` = 按地址从内存读出、
  即程序看到的量；`raw` = 该通道上一周期与物理侧交换的原始值；非 I/O 绑定后两者为 `null`。
- **非标量与 64 位在启动时拒绝**：原方案假设「8 字节量占两槽、按 8 字节读」。
  实测不成立——`global_codegen.v:37-44` 给每个全局只分配一个 int32 字，
  `veristc_main.ml:321` 段 7 的 `size` 恒写 4。按 8 字节解释只会读出高半段的垃圾。
  故 `LINT/LREAL/Q*64` 与 `ARRAY/FB` 一律启动即拒（FB 基名本就没有「一个值」，
  字段派生名 `cnt#N` 才有）；D1 只收 DINT 与此一致。
- **stdout 是复用的，帧按 `{"frame":` 前缀过滤**：被编译程序的 `PRINT` 端口直接
  `printf` 到 stdout（`safeasm_interp.c:541-617`）。没有用 `dup2`/`freopen` 在安全相关工具里
  动 fd，而是让 `sim --watch` 把自己的配置回显改道 stderr，并在协议里写明前缀过滤规则
  （非帧行属于被编译程序的跟踪输出）。
- **新增 done 帧**（§4.4）：`{"frame":"done",…}` 流末恰好一行，消费者据此区分
  「正常结束」与「子进程断了」——这是 stdout 管道方案必须补上的一环。
- **段 7 解析器复用**：地址来源 `core/sasm_info.c` 的 `sasm_sym_resolve()` 与 `svm -s/-l`
  走同一个行读取器（`sym_read_row`），不存在第二份名字→地址实现；
  门禁第 6 步因此能钉「帧的 `addr/type/size` 逐条 == `svm -l`」。
- **语料扩到派生名**：`sim_closed_loop.st` 加了一个只供 watch 使用的 `COUNTER_FB` 实例
  （`cnt#N`、`cnt#ACC`），验证派生名与扁平全局名的解析通路；12 周期黄金时间线逐字节未变。
- **门禁 20→26 项**（`integration/run_sim_e2e.sh` 第 6 步）：帧可 JSON 解析、12+1 帧数、
  列序 == 命令行书写序、`t_ms` 取本周期起始、`addr/type/size` 与 `svm -l` 交叉核对、
  `value` 与黄金时间线逐周期核对、`channel/raw` 绑定关系、done 计数器、两次 watch 逐字节一致、
  三类名字表拒绝。交叉核对脚本本身做过负向验证（改黄金值即报 MISMATCH），不会空转。
- **W2 遗留的那条断言在此关闭**：「按符号地址读出的值与黄金时间线第 k 周期一致」
  （§3.5 推迟项）现已落地。

## 8. 全程约束
- **字节编码不进 Coq**：Coq 只导出语义行，OCaml 拼字节（与 `emit_svobj` 同层）。
- 不新增 `Admitted`；`make coq` 全绿。
- **`KIND=` 九词汇与既有 71 项断言逐字不变**（W2' 后总数 83，W3 后 84，新增项只增不改）；新增走新增函数，不改老函数签名。
- 新目录 `sim/*.c`、`agent/*.c` 必须进 `run_misra_check.sh` 的 `DEFAULT_FILES`（:30-41）。
  本机 cppcheck 缺失 ⇒ 该门禁本地始终 FAIL（环境缺口，非代码问题），须在 CI 上取绿。
- 新目录单独开 `-Werror`（现全仓无 `-Werror`），**不回改老文件**以免噪声淹没。
- 禁 malloc / 禁递归 / 数组访问带边界检查（AGENTS.md 约定，非工具强制）：`sim`、`watch`、`download_wire`
  一律静态缓冲。注意现树里 `sasm_dump.c:308`、`sasm_info.c:85` 已在用 malloc（靠抑制清单放行）——
  新增代码**不得**援引它们为先例。
- 顺带修一处文档错误：`compiler_correctness.v` 实际在 `veri-stc/src/`，AGENTS.md 目录树误列为 `spec/`。

## 9. 明确不做（G0）

语句级/端口级 LOC（D3，→G2）；REAL 全链路（D1，→并行子项）；变量写入与强制；
真签名 Ed25519/HSM（D5，→G4）；增量补丁下装（`apply_patch` 保留但不进链路）；
`veristc-ld` 链接器；主备同步传输层；socket/shm watch（D4，→G3）。

## 10. 遗留风险登记

| 风险 | 影响 | 处置 |
|---|---|---|
| REAL 不可用但 `type_tag=REAL` 照发 | IDE 显示 0 值且看不出是缺口 | **W4 未实现 `suspect: true` 标记**：`REAL`/`QREAL` 走单字 float32 解码，帧里就是一个数值，缺口 A 未闭合时它可能是 0 或残值。缓解靠 D1：G0 验收语料（`sim_closed_loop.st`）纯 DINT，门禁不读 REAL 符号。缺口 A 闭合前，IDE 侧不得把 REAL 帧当真值 |
| `qc_offset` / 质量影子内存悬空 | 质量类型无法被监视 | §4.4 已注明为 v1.1 悬空项；G0 不解决 |
| `s_dl_mgr` 文件静态 | 一 agent 进程仅一工程 | 首期接受；句柄化推到 G4 多工程需求出现时 |
| HMAC 非真签名 | 密钥泄露即伪造镜像可加载 | D5 已接受，进安全评审清单，G4 前不得接真机 |
| `run_misra_check.sh` 本地始终 FAIL | 本地无法自证 MISRA 合规 | 环境缺口；以 CI 为准 |
