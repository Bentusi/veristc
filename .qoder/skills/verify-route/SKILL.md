---
name: verify-route
description: >-
  根据本次编辑涉及的文件路径，选择最小且充分的验证脚本组合。
  当 agent 完成代码修改后调用此 Skill 以确定应运行哪些验证。
---

# Verify Route — 变更后验证路由

## 使用场景

编辑项目文件后，根据变更范围选择正确的验证命令。避免"改一行代码跑全量测试"的低效，也避免"改了核心却忘记验证"的遗漏。

## 路由决策表

按以下优先级从上到下匹配，选中**第一条命中**的规则执行：

| # | 变更文件模式 | 验证动作 | 理由 |
|---|-------------|---------|------|
| 1 | `veristc/spec/*.v` | `make coq` | 定理/规范文件：编译通过 = 证明完整 |
| 2 | `veristc/src/*.v` | `make coq && make veristc && ./run_tests.sh` | 编译器实现：全管线验证 |
| 3 | `veristc/extraction/extraction.v` | `make coq && make veristc && ./run_tests.sh` | 提取配置变更：重提取+全测试 |
| 4 | `veristc/extraction/veristc_main.ml` | `make veristc && ./run_tests.sh` | OCaml 入口：编译+全测试 |
| 5 | `vm/*.c` 或 `vm/*.h`（hotstandby/io 除外） | `make svm && ./run_vm_checks.sh` | VM 核心：构建+单元/周期检查 |
| 6 | `vm/io/*.c` 或 `vm/io/*.h` | `make vm-io && ./run_vm_checks.sh` | I/O 映射层：构建+VM 检查 |
| 7 | `vm/hotstandby/*.c` 或 `vm/hotstandby/*.h` | `make all && ./run_tests.sh` | 热备模块：全量构建+全量测试 |
| 8 | `rtos/**/*.c` 或 `rtos/**/*.h` | `make all` | RTOS 适配：编译通过即可 |
| 9 | `tests/vm-tests/*.c` | `make build-tests && ./run_vm_checks.sh` | VM 测试代码：重建测试+运行 |
| 10 | `tests/st-examples/*.st`（feature-probes/） | `./run_feature_probes.sh` | 特性探针：仅跑探针矩阵 |
| 11 | `tests/st-examples/*.st`（nuclear*） | `./run_nuclear_e2e.sh` | 核电用例：端到端验证 |
| 12 | `tests/st-examples/*.st`（channel*） | `./run_channel_e2e.sh` | 通道用例：黄金时间线比对 |
| 13 | `run_*.sh` 或 `Makefile` | `./run_tests.sh` | 构建/测试基础设施变更：全量回归 |
| 14 | `spec/*.md`（顶层规范文档） | 无需验证 | 纯文档，不影响编译/运行 |
| 15 | 其他 `.md`、`.json`、`.yml` | 无需验证 | 文档/配置变更 |

## 补充规则（可叠加）

当路由决策表命中 **第 5-7 条**（C 源文件变更）时，**额外建议**运行：

```bash
./run_misra_check.sh    # MISRA-C 合规检查
```

当变更涉及 `vm/loader.c` 或 `vm/safeasm_interp.c` 的错误处理路径时，**额外建议**：

```bash
./run_fuzzer.sh         # .sasm 加载器模糊测试
```

## 快捷命令参考

```bash
# 全量验证（不确定时的安全默认）
export COQC=$HOME/.opam/default/bin/coqc && ./run_tests.sh

# 仅 Coq 编译
make coq COQC=$HOME/.opam/default/bin/coqc

# 仅构建 veristc 可执行文件
make veristc COQC=$HOME/.opam/default/bin/coqc

# 仅 VM 检查
./run_vm_checks.sh

# 仅特性探针
./run_feature_probes.sh

# 仅核电端到端
./run_nuclear_e2e.sh

# 仅通道黄金比对
./run_channel_e2e.sh

# MISRA-C 检查
./run_misra_check.sh

# Sanitizer 检测
make run-sanitize COQC=$HOME/.opam/default/bin/coqc
```

## 示例

**场景 A**：修改了 `vm/safeasm_interp.c` 中的一条指令语义

匹配规则 #5 → 执行：
```bash
make svm && ./run_vm_checks.sh
./run_misra_check.sh   # 补充：C 源文件
```

**场景 B**：修改了 `veristc/src/codegen.v` 增加新指令生成

匹配规则 #2 → 执行：
```bash
make coq && make veristc && ./run_tests.sh
```

**场景 C**：修改了 `veristc/spec/safeasm.v` 中的归纳定义

匹配规则 #1 → 执行：
```bash
make coq
```

**场景 D**：修改了 `tests/st-examples/feature-probes/probe_qreal.st`

匹配规则 #10 → 执行：
```bash
./run_feature_probes.sh
```
