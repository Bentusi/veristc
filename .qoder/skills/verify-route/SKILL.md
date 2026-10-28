---
name: verify-route
description: >-
  根据本次编辑涉及的文件路径，选择最小且充分的验证脚本组合。
  当 agent 完成代码修改后调用此 Skill 以确定应运行哪些验证。
---

# Verify Route — 变更后验证路由

## 使用场景

编辑项目文件后，根据变更范围选择正确的验证命令。避免"改一行代码跑全量测试"的低效，也避免"改了核心却忘记验证"的遗漏。

仓库分三组件：`veri-stc/`（形式化核：编译器）、`veri-runtime/`（执行核：VM）、`veri-ide/`（工程站，Phase 6 规划中）；跨组件系统级验证脚本在 `integration/`，组件自身验证脚本在组件目录内。

## 路由决策表

按以下优先级从上到下匹配，选中**第一条命中**的规则执行：

| # | 变更文件模式 | 验证动作 | 理由 |
|---|-------------|---------|------|
| 1 | `veri-stc/spec/*.v` | `make coq` | 定理/规范文件：编译通过 = 证明完整 |
| 2 | `veri-stc/src/*.v` | `make coq && make veristc && ./integration/run_tests.sh` | 编译器实现：全管线验证 |
| 3 | `veri-stc/extraction/extraction.v` | `make coq && make veristc && ./integration/run_tests.sh` | 提取配置变更：重提取+全测试 |
| 4 | `veri-stc/extraction/veristc_main.ml` | `make veristc && ./integration/run_tests.sh` | OCaml 入口：编译+全测试 |
| 5 | `veri-runtime/core/*.c` 或 `*.h` | `make svm && ./veri-runtime/run_vm_checks.sh` | VM 核：构建+单元/周期检查 |
| 6 | `veri-runtime/io/*.c` 或 `*.h` | `make vm-io && ./veri-runtime/run_vm_checks.sh` | I/O 映射层：构建+VM 检查 |
| 7 | `veri-runtime/hotstandby/*.c` 或 `*.h` | `make all && ./integration/run_tests.sh` | 热备模块：全量构建+全量测试 |
| 8 | `veri-runtime/rtos/**` | `make all` | RTOS 适配：编译通过即可 |
| 9 | `veri-runtime/tests/**/*.c` | `make build-tests && ./veri-runtime/run_vm_checks.sh` | VM 测试代码：重建测试+运行 |
| 10 | `veri-stc/tests/st-examples/feature-probes/*.st` | `./integration/run_feature_probes.sh` | 特性探针：仅跑探针矩阵 |
| 11 | `veri-stc/tests/st-examples/nuclear*.st` | `./integration/run_nuclear_e2e.sh` | 核电用例：端到端验证 |
| 12 | `veri-stc/tests/st-examples/*channel*.st` | `./integration/run_channel_e2e.sh` | 通道用例：黄金时间线比对 |
| 13 | `veri-stc/tests/st-examples/algo_blocks*.st` | `./integration/run_algo_e2e.sh` 或 `run_algo_fb_e2e.sh` | 算法块用例：黄金时间线比对 |
| 14 | `veri-stc/tests/compiler-tests/**/*.st` | `./veri-stc/tests/compiler-tests/run_compiler_tests.sh && ./veri-runtime/run_vm_checks.sh` | 正/负编译用例（负例须在 run_vm_checks 有诊断断言） |
| 15 | `Makefile`、`Makefile.common`、`veri-*/Makefile`、`run_*.sh`、`integration/*.sh` | `./integration/run_tests.sh` | 构建/测试基础设施变更：全量回归 |
| 16 | `veri-ide/**` | 无需验证 | 工程站尚无实现（Phase 6 G1 起引入契约测试门禁） |
| 17 | `spec/*.md`（顶层规范文档）、其他 `.md`、`.json`、`.yml` | 无需验证 | 纯文档/配置，不影响编译与运行 |

## 补充规则（可叠加）

当路由决策表命中 **第 5-8 条**（C 源文件变更）时，**额外建议**运行：

```bash
./veri-runtime/run_misra_check.sh    # MISRA-C 合规检查（cppcheck 缺失即 FAIL）
```

当变更涉及 `veri-runtime/core/loader.c` 或 `veri-runtime/core/safeasm_interp.c` 的错误处理路径时，**额外建议**：

```bash
./veri-runtime/run_fuzzer.sh         # .sasm 加载器模糊测试
```

## 快捷命令参考

```bash
# 全量验证（不确定时的安全默认）
export COQC=$HOME/.opam/default/bin/coqc && ./integration/run_tests.sh

# 仅 Coq 编译
make coq COQC=$HOME/.opam/default/bin/coqc

# 仅构建 veristc 可执行文件
make veristc COQC=$HOME/.opam/default/bin/coqc

# 仅 VM 检查（71 项，最细回归指纹）
./veri-runtime/run_vm_checks.sh

# 仅特性探针
./integration/run_feature_probes.sh

# 仅核电端到端
./integration/run_nuclear_e2e.sh

# 仅通道黄金比对
./integration/run_channel_e2e.sh

# 算法块黄金比对（函数版 / 原生 FB 版）
./integration/run_algo_e2e.sh
./integration/run_algo_fb_e2e.sh

# 编译器正/负用例
./veri-stc/tests/compiler-tests/run_compiler_tests.sh

# MISRA-C 检查
./veri-runtime/run_misra_check.sh

# Sanitizer 检测
make run-sanitize COQC=$HOME/.opam/default/bin/coqc
```

## 示例

**场景 A**：修改了 `veri-runtime/core/safeasm_interp.c` 中的一条指令语义

匹配规则 #5 → 执行：
```bash
make svm && ./veri-runtime/run_vm_checks.sh
./veri-runtime/run_misra_check.sh   # 补充：C 源文件
```

**场景 B**：修改了 `veri-stc/src/codegen.v` 增加新指令生成

匹配规则 #2 → 执行：
```bash
make coq && make veristc && ./integration/run_tests.sh
```

**场景 C**：修改了 `veri-stc/spec/safeasm.v` 中的归纳定义

匹配规则 #1 → 执行：
```bash
make coq
```

**场景 D**：修改了 `veri-stc/tests/st-examples/feature-probes/p07_real_arith.st`

匹配规则 #10 → 执行：
```bash
./integration/run_feature_probes.sh
```
