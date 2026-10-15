# 流程缺口与待确认项

范围仅限三张流程图所表达的内容：未被证据支持的步骤、失败路径、缺失的运行期机制。
**这不是架构评审**（风险登记、质量属性、技术债评估请走 `risk-quality-reviewer`）。

## G1 场景关键机制缺失：运行期的 I/O 与故障收敛

`flow-vm-runtime.dot` 的主路径里没有 I/O 同步、没有看门狗、没有安全态。
这不是画图遗漏，而是代码事实（`vm/svm.c:204-225` 循环体内只有 `vm_run` + 休眠）。

需要确认的是**这是不是当前预期**：若 VeriSTC 现阶段定位是"编译正确性 + 指令语义 SIL 验证平台"，
那么 `svm` 是一个测试用执行器，I/O 接入本就不在射程内，模型应把它标注为"验证用运行器"；
若定位是"安全级仪控运行站"，则 G1 是主路径上的实质缺口。

验证动作：向负责人确认 `svm` 的定位；或直接看 `run_nuclear_e2e.sh` / `run_channel_e2e.sh`
是否以内存值而非物理通道值作为判据（若是，则支持前者）。

## G2 `.sasm` 完整性校验对"未签名文件"不设防

`vm/loader.c:283-289`：CRC 不匹配时，若 `stored_crc == 0` 则放行，注释写明为
"legacy handcrafted development fixtures"。而项目约定是"SVM 加载时拒绝损坏文件"（`AGENTS.md`）。

先厘清这条放行的**真实可达范围**，避免把结论说过头：

- 损坏检测本身是有效的，也有断言覆盖：`run_vm_checks.sh:197-209` 与 `run_sanitizer.sh:48-55`
  把 CRC 字段（末尾 4 字节）之前的最后一个字节改写为 `0xFF`（`seek=size-5`），
  使 `computed_crc` 变化而 `stored_crc` 保持非零，并断言输出含 `sasm_load failed: -2`。
- 真正进入 `sasm_load` 的只有四个调用点：`vm/svm.c:85`、`tests/fuzz/sasm_fuzzer.c:168`、
  `tests/vm-tests/test_nuclear_protection_full_e2e.c:218`、`rtos/rtthread/vm_rtthread.c:447`。
- `tests/vm-tests/test_vm.c` **不经过装载器**：它用 `install_code()`（`:23`）直接填充内存中的
  `SasmModule`，全文件没有任何 CRC 相关代码。因此它不能作为放行路径的证据。
- `stored_crc == 0` 的约定在工具侧也成型了：`vm/sasm_dump.c:544-551` 把它单独标注为 `(未计算)`，
  与 `OK` / `MISMATCH` 并列。

影响流程判断的地方：主路径图里"装载即可信"这一前提只对**已计算 CRC 的文件**成立。
一个 `stored_crc` 恰为 0 的文件（手工构造、下装链路未填 CRC、或**被改写后把 CRC 字段清零**）
都能通过校验。所以缺口的准确表述不是"损坏检测可绕过"，而是"完整性校验对未签名文件不强制"。

验证动作：确认是否应把放行限定在测试构建（编译期开关或独立的 `sasm_load_strict`），
或在生产入口把 `stored_crc == 0` 视为拒绝；同时明确下装/热备增量下装路径写入 CRC 的时机。

## G3 装载出的 IOMap 与 I/O 映射表之间没有桥

`vm/loader.c:175-193` 把 IOMap 段解析进 `SasmModule.iomap`，但：
`scale_factor` 与 `bias` 在解析时就被写死为 `1.0` / `0.0` 并跳过 16 字节（`:186-190`），
且全仓没有任何代码把 `SasmModule.iomap` 转换成 `IOMappingTable`。

后果：即使把 `libvm_io.a` 链进 `svm` 并删掉 `svm.c:31-37` 的桩，缩放/偏置与安全限值
也不会生效——数据在装载阶段已经丢了。这是一个**顺序依赖**：桥接与"保留 scale/bias"必须同时做。

验证动作：先补 `SasmModule.iomap → IOMappingTable` 的构造与 scale/bias 读取，
再改链接关系，否则会得到"接上了但全为 1.0/0.0"的假成功。

## G4 热备的脏页机制在语义上未闭合

`hs_snapshot_create` 按脏页构造快照（`snapshot.c:207`，并对 GLOBAL+FB_DATA 段整段纳入
`:239-257`），但 `hs_dirty_mark`（`:129`）在解释器的任何 STORE 路径上都没有被调用
（唯一调用者是 `tests/vm-tests/test_hotstandby.c`）。

因此"脏页追踪"目前只在测试里由人工标记闭合，运行期语义未闭合。
同类问题：`hs_chan_shmem_init` 把 `send`/`recv`/`last_activity` 全置 NULL（`sync.c:75-77`），
即通道抽象本身没有真实实现。

验证动作：确认热备是否计划在解释器写指令里插桩（涉及 `safeasm_interp.c` 与已证明的
`pc_step` 语义，代价不低），或改为周期性全量快照。

## G5 证明覆盖与生产入口不同路径（有意设计，但需明确口径）

端到端语义保持定理的组合是 `compile_st_to_sasm = compile_core_program`
（`compiler_correctness.v:85-99`），内部用 `type_check_program` + `codegen.compile_program`；
生产入口用 `global_codegen.compile_program_gc`（`veristc_main.ml:221,347`）。
针对 `compile_program_gc` 的定理集中在 `:2228-2493`（WS-C 段），内容为 CALL 结构性质
（段长度、被调目标存在、形参数 ≤ 局部槽位数），不含端到端语义保持。

按项目既有决策这是有意的解耦（结构证明留在 `codegen.v`，工程扩展在 `global_codegen.v`），
所以这里记为**口径待明确**而非缺陷：`compile_st_to_sasm_core` 等定理的适用范围，
在文档与安全论证里应如何表述。

验证动作：确认 `spec/semantics-preservation.md` 与 `AGENTS.md` 定理表是否已声明
"定理覆盖 `compile_program`，生产入口为 `compile_program_gc` + WS-C 结构定理 + 测试"。

## G6 分析模式无产物、`.iomap` 文件未实现

`-a` 只 `printf` 四项指标到 stdout（`veristc_main.ml:465-472`），不产出文件；
`AGENTS.md` 声明的 `.iomap` 输出实际是 `.sasm` 内的 Section type=3（`encoder.v:166-174,335-340`）。

影响：任何依赖"读 `.iomap` 文件"的外部工具链（组态、下装工具）在流程上无处可接。
验证动作：确认 `.iomap` 是废弃需求还是待实现；若废弃，同步 `AGENTS.md`。

## G7 `-a` 与 `-c` 是两份同构管线，门禁判据不同

`analyze_st`（`veristc_main.ml:443-472`）与 `frontend`（`:183-217`）九步逐行同构
（`:444-464` 对 `:184-209`），但 `analyze_st` **不做** `frontend:210-216` 的递归拒绝与栈深超限拒绝，
只把 `recursive calls` 与 `stack depth` 打印出来（`:465-469`）。

后果有两层：
1. 判据不一致 —— 同一程序可以"`-a` 报告正常"而"`-c` 编译失败"。若把 `-a` 输出当作
   可编译性预检（`Makefile:158` 在核电用例里就是先 `-a` 再 `-c`），这个预检是弱于编译门禁的。
2. 演进风险 —— 任何新增到 `frontend` 的门禁都必须同步补到 `analyze_st`，否则静默漂移。

验证动作：确认 `-a` 的定位是"信息报告"还是"可编译性预检"。若是后者，
应让 `analyze_st` 复用 `frontend` 并在其后打印，而不是维护第二份管线。

## G8 本模型自身的验证边界

- 三张 DOT 已用本机 `dot 16.1.0` 成功解析并导出 SVG（`README.md` 的重生成命令即验证命令）。
- `veristc.structurizr.dsl` **未做机器校验**：本机无 Structurizr CLI，语法按标准 DSL 手写。
  若预览器报错，优先修 DSL 源而不是改导出件。
- 图中所有"零调用点"结论来自全仓 `Grep`，覆盖 `.c/.h`；复现命令见 `README.md` 末尾的自检命令块。
  若后续新增其它语言的运行站入口（例如 C++/Rust 宿主），这些结论需要重跑。
- 本轮自检修正过一处错误归因：早期版本称 `tests/vm-tests/test_vm.c` 的手工字节序列"走 CRC 放行路径
  进入解释器"，实际该文件用 `install_code()` 直接构造内存模块、从不调用 `sasm_load`。
  G2 已按可达性重写。**同类"某测试覆盖了 X"的表述应优先按调用点验证，而非按文件用途推断。**
- 基线是 2026-10-14 的**工作树**（含未提交改动，如 `vm/safeasm_interp.c`、
  `veristc/src/global_codegen.v` 与 v1.5 VAR_IN_OUT 相关文件）。提交后行号可能漂移，
  建议以函数名而非行号做长期锚点。

## 建议的下一步（按依赖排序）

1. 先回答 G1（`svm` 定位）——它决定 G3/G4 是"缺口"还是"超范围"。
2. G5 的口径澄清可以并行做，纯文档工作，且影响安全论证表述。
3. G2、G6 与 G7 是独立小改动，不依赖前两者；其中 G7 只需把 `analyze_st` 改为复用 `frontend`。
4. G3 必须在改链接关系之前完成，否则得到假成功。
5. G4 代价最高（触碰解释器与已证明语义），建议最后评估。
