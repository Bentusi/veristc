# 流程缺口与待确认项

范围仅限三张流程图所表达的内容：未被证据支持的步骤、失败路径、缺失的运行期机制。
**这不是架构评审**（风险登记、质量属性、技术债评估请走 `risk-quality-reviewer`）。

## G1 场景关键机制缺失：运行期的 I/O 与故障收敛 —— ✅ 已闭合（Phase 6 G0 / W3-W5）

原判断成立的前提是"运行站只有 `svm` 一个程序"。现在有三个主程序，分工写进了
`spec/safeasm-spec.md` §5.0：

- `svm`：纯执行器，周期体内不含 I/O（`veri-runtime/core/svm.c:257-277`）。**这是有意的**，
  用于测试与黄金时间线复算，不再算缺口。
- `sim`：`io_mapping_cycle` 全路径（`veri-runtime/sim/sim_main.c:273` → `io/io_mapping.c:254-269`），
  软件 I/O 后端 `sim/sim_io.c` + `.plant` 被控对象；watch 帧给出工程站仿真按钮要的数据面。
- `veristc-agent`：装载 + 周期扫描 + 下装帧接收 + 周期边界换版 + 健康窗回滚
  （`agent/agent_main.c:473,490`）。**故障收敛**目前只有这一层：换版后窗口内 `vm_run` 出错即
  `dl_rollback` 回上一版本（仅一级）。

仍未闭合的部分改记为 G9（生产 `VM_Interface` 后端缺失）与 G4（热备周期封装无调用者）。

## G2 `.sasm` 完整性校验对"未签名文件"不设防 —— ✅ 已闭合（Phase 6 G0 / W5）

`veri-runtime/core/loader.c:305-314` 现为无条件强制：

```c
if ((stored_crc == 0U) || (stored_crc != computed_crc)) { return -2; }
```

即"值不符"与"从未计算（全零）"两种情形一律拒绝，改写后把 CRC 字段清零不再能绕过。

改动前先确认了非破坏性：`run_vm_checks.sh` 的损坏 CRC 用例翻的是 `size-5` 的**载荷**字节、
stored 恒为非零，因此严格化不破任何既有制品；所有黄金 `.sasm` 由编译器 `attach_crc32`
（`veristc_main.ml:255-265`）产出真值。新增门禁：`veri-runtime/run_vm_checks.sh` 第 6/10 步
分别断言"损坏载荷 → -2"与"全零尾部 → -2"；`sasm_dump` 仍把 0 标注为 `(未计算)`，
但那是**展示**层的读法，装载层不再据此放行。

## G3 装载出的 IOMap 与 I/O 映射表之间没有桥 —— ✅ 已闭合（Phase 6 G0 / W2'-W3）

原判断的顺序依赖完全正确（先补桥接与 scale/bias 保留，再谈链接），两点都已落地：

1. **真值保留**：`loader.c:207,210` 经 `read_f64`（`:65`）逐条采信文件里的 float64，
   非有限值（NaN/±Inf）直接判加载失败；编译器侧由 OCaml `patch_iomap_cal` 用 IR 值覆盖
   Coq 编码器无法表示的 IEEE-754 位（三重核对不符即拒绝产出）。
2. **桥接**：`io_mapping_init`（`io/io_mapping.c:86`）直接吃 `SasmModule`，
   `sim_main.c:240` 调用；`svm -m` 打印的是加载后的运行期量程，不是文件字节复读。
3. **地址同源**（原缺口的新发现）：IOMAP 的 `mem_offset` 曾按 1024 起步自行编号，
   而全局变量从 4096 起步 —— 运行站写入的位置与程序读写的变量不是同一块内存。
   现由 Coq `global_codegen.v` 的 `resolve_io_map` 按名向 `build_global_env`（段 7 同一张表）取槽位；
   可机检不变量：`svm -m` 的每个 `mem=` 必出现在 `svm -l` 的地址列
   （`run_vm_checks.sh` 第 8 步）。

## G9 新的运行期留白（G0 之后）

| 留白 | 现状 | 推到 |
| --- | --- | --- |
| 生产 `VM_Interface` 后端 | 只有 `sim/sim_io.c`（软件 + 虚拟时钟）与未构建的 RT-Thread 层 | 目标硬件适配（Phase 2 的未完成半边） |
| 真实签名与密钥管理 | 下装密钥由 `--key` 进程内静态注入（决策 D5） | G4 |
| 增量补丁链路 | `compute_diff`/`apply_patch` 齐全但不在 agent 链路上 | 后续（`spec/download-spec.md` §8） |
| socket 传输 | 下装后端只有文件/管道流（`DlStream` 抽象已隔离） | G1+（工程站联调时） |
| watch 数据面走 socket | 首期 stdout JSONL 帧（决策 D4） | G1 |

## G4 热备的脏页机制在语义上未闭合

`hs_snapshot_create` 按脏页构造快照（`snapshot.c:207`，并对 GLOBAL+FB_DATA 段整段纳入
`:239-257`），但 `hs_dirty_mark`（`:129`）在解释器的任何 STORE 路径上都没有被调用
（唯一调用者是 `veri-runtime/tests/vm-tests/test_hotstandby.c`）。

因此"脏页追踪"目前只在测试里由人工标记闭合，运行期语义未闭合。
同类问题：`hs_chan_shmem_init` 把 `send`/`recv`/`last_activity` 全置 NULL（`sync.c:75-77`），
即通道抽象本身没有真实实现。

验证动作：确认热备是否计划在解释器写指令里插桩（涉及 `safeasm_interp.c` 与已证明的
`pc_step` 语义，代价不低），或改为周期性全量快照。

## G5 证明覆盖与生产入口不同路径（有意设计，但需明确口径）

端到端语义保持定理的组合是 `compile_st_to_sasm = compile_core_program`
（`compiler_correctness.v:85-99`），内部用 `type_check_program` + `codegen.compile_program`；
生产入口用 `global_codegen.compile_program_gc`（`veristc_main.ml:486,617`）。
针对 `compile_program_gc` 的定理集中在 `:2228-2493`（WS-C 段），内容为 CALL 结构性质
（段长度、被调目标存在、形参数 ≤ 局部槽位数），不含端到端语义保持。

按项目既有决策这是有意的解耦（结构证明留在 `codegen.v`，工程扩展在 `global_codegen.v`），
所以这里记为**口径待明确**而非缺陷：`compile_st_to_sasm_core` 等定理的适用范围，
在文档与安全论证里应如何表述。

验证动作：确认 `spec/semantics-preservation.md` 与 `AGENTS.md` 定理表是否已声明
"定理覆盖 `compile_program`，生产入口为 `compile_program_gc` + WS-C 结构定理 + 测试"。

## G6 分析模式无产物（`.iomap` 一条已在文档层面澄清）

`-a` 只把四项指标发出（`--json` 单行 `veristc_main.ml:763-771`；文本四行 `:772-779`），不产出文件。
`.iomap` 独立文件**不是待实现项**：I/O 配置一直作为 `.sasm` 的段 3 编码
（`encoder.v:155-174`），`AGENTS.md` 与 `spec/safeasm-spec.md` §4.4 均已如此声明，
运行站对它的消费路径自 G0/W3 起由 `sim` 打通（`io_mapping_init` ← `sim_main.c:240`）。

余留影响：任何仍按"读 `.iomap` 文件"设想的外部工具链需要改读 `.sasm` 段 3 或 `svm -m`。

## G7 `-a` 与 `-c` 是两份同构管线，门禁判据不同

`analyze_st`（`veristc_main.ml:721-780`）与 `frontend`（`:423-482`）十步逐行同构
（`:722-760` 对 `:425-474`），但 `analyze_st` **不做** `frontend:475-481` 的递归拒绝与栈深超限拒绝，
只把 `recursive calls` 与 `stack depth` 报告出来（`:762-779`）。

后果有两层：
1. 判据不一致 —— 同一程序可以"`-a` 报告正常"而"`-c` 编译失败"。若把 `-a` 输出当作
   可编译性预检（根 `Makefile:135` 在核电用例里就是先 `-a` 再 `-c`，
   `integration/run_{algo,algo_fb,channel}_e2e.sh:23` 同样先跑 `-a`），这个预检是弱于编译门禁的。
2. 演进风险 —— 任何新增到 `frontend` 的门禁都必须同步补到 `analyze_st`，否则静默漂移。
   G0/W1 的 `--json` 与 G0/W2 的段 7 都是"两处都要改"的实例（诊断行 API 在两条管线里各接一次：
   `:455-459` 与 `:744-748`）。

验证动作：确认 `-a` 的定位是"信息报告"还是"可编译性预检"。若是后者，
应让 `analyze_st` 复用 `frontend` 并在其后打印，而不是维护第二份管线。

## G8 本模型自身的验证边界

- 三张 DOT 已用本机 `dot 16.1.0` 成功解析并导出 SVG（`README.md` 的重生成命令即验证命令）。
- `veristc.structurizr.dsl` **未做机器校验**：本机无 Structurizr CLI，语法按标准 DSL 手写。
  若预览器报错，优先修 DSL 源而不是改导出件。
- 图中所有"零调用点"结论来自全仓 `Grep`，覆盖 `.c/.h`；复现命令见 `README.md` 末尾的自检命令块。
  若后续新增其它语言的运行站入口（例如 C++/Rust 宿主），这些结论需要重跑。
- 本轮自检修正过一处错误归因：早期版本称 `veri-runtime/tests/vm-tests/test_vm.c` 的手工字节序列"走 CRC 放行路径
  进入解释器"，实际该文件用 `install_code()` 直接构造内存模块、从不调用 `sasm_load`。
  G2 已按可达性重写。**同类"某测试覆盖了 X"的表述应优先按调用点验证，而非按文件用途推断。**
- 基线是 2026-10-14 的**工作树**（含未提交改动，如 `veri-runtime/core/safeasm_interp.c`、
  `veri-stc/src/global_codegen.v` 与 v1.5 VAR_IN_OUT 相关文件）。提交后行号可能漂移，
  建议以函数名而非行号做长期锚点。

## 建议的下一步（按依赖排序）

1. 先回答 G1（`svm` 定位）——它决定 G3/G4 是"缺口"还是"超范围"。
2. G5 的口径澄清可以并行做，纯文档工作，且影响安全论证表述。
3. G2、G6 与 G7 是独立小改动，不依赖前两者；其中 G7 只需把 `analyze_st` 改为复用 `frontend`。
4. G3 必须在改链接关系之前完成，否则得到假成功。
5. G4 代价最高（触碰解释器与已证明语义），建议最后评估。
