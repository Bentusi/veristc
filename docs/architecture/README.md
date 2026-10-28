# VeriSTC 架构模型与数据流图

生成日期 2026-10-14。由 `architecture-visualization` 插件的 `system-modeler` + `c4model`（结构建模）与
`flow-visualizer` + `graphviz`（数据流建模）产出，全部为**当前状态（AS-IS）**模型。

**2026-10-22 行号重导**（已被下一轮覆盖）：编译器侧的 `文件:行号` 按当时工作树重导，并补入
v1.5.1 的两处新门禁（`duplicate_declaration_msg` 展开后重名、`check_program_access` 字段封装
`KIND=access`）与解析期 `inst.field → inst#field` 名字融合。

每张图只回答一个问题；节点/边文本内嵌 `文件:行号` 证据，可直接跳读源码核对。

**2026-10-28 三组件化路径更新**：仓库已重组为 `veri-stc/`（编译器）、`veri-runtime/`（运行站）、
`veri-ide/`（工程站，规划中），本目录全部 `文件:行号` 的**源码路径前缀**已随之更新
（`veristc/…`→`veri-stc/…`，`vm/…`→`veri-runtime/core/…`，`vm/io/`→`veri-runtime/io/`，
`vm/hotstandby/`→`veri-runtime/hotstandby/`，`rtos/`→`veri-runtime/rtos/`，
`tests/vm-tests/`→`veri-runtime/tests/vm-tests/`，`tests/st-examples/`→`veri-stc/tests/st-examples/`）。

**同一轮（G0/W6）已把全部 `文件:行号` 重新 grep 核对并重导**，覆盖三张 DOT、`.svg`、
DSL、`veristc.evidence.md`、`veristc.summary.md`、`flow-evidence.md`、`flow-risks-and-gaps.md`。
此前形如 `Makefile:NNN` 的悬空行号（指向拆分前的单一根 Makefile，git `8311fb5`）已在本轮**全部清除**：
现在每个 Makefile 引用都带真实前缀 —— 根 `Makefile`（聚合转发 + 跨组件制品）、
`veri-stc/Makefile`、`veri-runtime/Makefile`（共享工具链在 `Makefile.common`），可直接跳转。

## 清单

| 文件 | 层次 | 回答的问题 |
| --- | --- | --- |
| `veristc.structurizr.dsl` | L1→L3 | 系统边界、可部署单元、单元内部组件分别是什么 |
| `flow-compile-pipeline.dot` | 数据流 | 一个 `.st` 到可执行镜像，数据形态如何逐步变化、门禁在哪拒绝、四种模式如何分叉 |
| `flow-vm-runtime.dot` | 数据流 | `.sasm` 进入 `svm` 后，一个扫描周期里**真正执行**了什么 |
| `flow-vm-unwired.dot` | 数据流 | 哪些运行期能力已实现但**没有进入**三个主程序（`svm` / `sim` / `veristc-agent`）的可执行路径，断点在哪一行 |
| `veristc.summary.md` | 说明 | 模型可读解释、边界、关键关系、不确定项 |
| `veristc.evidence.md` | 证据 | C4 节点/边的证据与置信度索引 |
| `flow-evidence.md` | 证据 | 三张流程图的步骤证据索引 |
| `flow-risks-and-gaps.md` | 缺口 | 未支持步骤、失败路径、待确认项与验证动作 |

## 阅读顺序

1. `veristc.summary.md` —— 先建立整体感。
2. `veristc.structurizr.dsl` 的 `v1-system-context` → `v2-containers` → `v3-compiler-components` →
   `v4-svm-components` → `v4b-sim-components` → `v4c-agent-components` → `v4d-io-components` →
   `v5-hotstandby-components`（`v4/v4b/v4c` 是三个主程序各一张，`v4d` 是被 `sim` 唯一消费的 I/O 库）。
3. 若要改编译器：`flow-compile-pipeline.dot`。若要改运行站：`flow-vm-runtime.dot`，
   并务必连读 `flow-vm-unwired.dot`（两张图是一对：会执行的 / 存在但不执行的）。
4. 结论有疑时查 `*.evidence.md` 与 `flow-risks-and-gaps.md`。

## 视觉约定（三张 DOT 与 DSL 一致）

- 实线绿框：可执行文件里真正会执行的路径。
- 橙色虚线簇 + 橙色边框：代码已实现，但零调用点 / 未链接 / 未构建。
- 红色八边形或红底节点：终止、拒绝、或"断点"。
- 灰色虚线：协议、测试替身、构建期依赖。
- 置信度：`Conf-High` = 直接来自代码/构建文件；`Conf-Medium` = 多个间接信号或仅文档；
  `TargetState` = 计划态，仓库内无实现。

## 重新生成

```bash
cd docs/architecture
for f in flow-compile-pipeline flow-vm-runtime flow-vm-unwired; do
    dot -Tsvg "$f.dot" -o "$f.svg"        # 需要 graphviz (本机 dot 16.1.0 已验证可解析)
done
```

`.svg` 是派生产物，`.dot` / `.dsl` 才是事实来源；修图请改源文件，不要改导出件。

Structurizr DSL 可用 Qoder 的 DSL 格式预览器打开，或
`npx -y @structurizr/cli@latest validate -w veristc.structurizr.dsl`（本机未装 CLI，
DSL 语法按标准 Structurizr 书写但未做机器校验 —— 见 `flow-risks-and-gaps.md` G8）。

## 维护建议

这三张图对"哪个函数被谁调用"高度敏感，而这类事实最容易在重构中悄悄变化。
建议在下述变更时同步更新：新增/删除构建目标、改变 `veristc_main.ml` 的 `frontend` 阶段顺序、
改变 `svm`/`sim`/`veristc-agent` 的链接集合、`sasm_load` 的调用点集合发生变化、
`loader.c` 的 CRC 策略被改动、或把热备周期封装真正接入某个主程序。

自检命令（图中"零调用点 / 已接入"结论的复现方式）：

```bash
grep -rn 'io_mapping_cycle' --include='*.c' veri-runtime | grep -v tests   # 期望：定义 + sim 主循环调用
grep -rn 'dl_apply_switch\|dl_commit_switch' --include='*.c' veri-runtime   # 期望：定义 + download.c 内部 + agent
grep -rn 'hs_run_cycle\|hs_sync_cycle' --include='*.c' veri-runtime         # 期望：仅定义与内部互调（无主程序调用）
grep -rn 'sasm_load(' --include='*.c' veri-runtime                          # 期望：1 定义 + 6 调用（其中 RT-Thread 那处未构建）
grep -c 'compile_program_gc' veri-stc/spec/compiler_correctness.v
```

> 2026-10-28（Phase 6 G0 / W1-W6）本轮按上述命令重导了 `flow-vm-runtime.*`、`flow-vm-unwired.*`、
> `flow-compile-pipeline.*`、`veristc.structurizr.dsl`（新增 `sim`/`agent` 容器与 4 张组件视图）、
> `veristc.evidence.md`（全量重写）、`flow-evidence.md`、`flow-risks-and-gaps.md`
> （G1/G2/G3 已闭合，新增 G9）与 `veristc.summary.md` 的运行站/部署单元/CLI 章节。
> `.svg` 已用本机 `dot 16.1.0` 重新渲染。
> 同期核对的门禁计数（以脚本实际输出为准）：`run_vm_checks.sh` = **97 项**、
> `run_sim_e2e.sh` = **26 项**、下装帧 = **34 项**、`run_compiler_tests.sh` = **accepted=42, failed=0**。
