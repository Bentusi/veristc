# VeriSTC 平台

将 IEC 61131-3 Structured Text (ST) 编译为 SafeASM 字节码（`.sasm`）的**形式化验证**工具链，
配套 C 语言实现的 SafeASM 运行站，用于安全级仪控设备。编译器（SafeST → SafeASM）的语义保持
由 Rocq/Coq 机器检查证明覆盖。

## 三大组件

| 组件 | 角色 | 信任级别 | 门禁 |
|------|------|---------|------|
| [`veri-stc/`](veri-stc/) | 编译器（Coq 实现+证明 → Extraction → OCaml `veristc`） | 形式化核 | `make coq` 全绿、无新增 `Admitted` |
| [`veri-runtime/`](veri-runtime/) | 运行站（C11 SafeASM VM + I/O 映射 + 双机热备 + 仿真） | 执行核 | MISRA-C + ASan/UBSan + fuzzer |
| [`veri-ide/`](veri-ide/) | 工程站（VeriIDE：图形组态→编译→仿真→下装闭环 Web IDE） | 非安全侧工程工具 | 协议测试 + 图↔文本往返恒等（Phase 6 起） |

跨组件耦合只允许经由 [`spec/`](spec/) 的文本协议与二进制布局定义；
系统级端到端验证脚本集中在 [`integration/`](integration/)。
项目级指引（目录结构、依赖规则 R1–R3、验证路由表）见 [AGENTS.md](AGENTS.md)。

## 依赖项

- **Coq/Rocq** (>= 8.18)：形式化验证
- **OCaml** (>= 5.0) + **dune** (>= 3.16)：Extraction 后的代码编译
- **GCC** (C11)：运行站编译
- **cppcheck**：MISRA-C 静态分析（`make misra-check` 需要；缺失即判 FAIL）

## 构建

在仓库根执行；根 `Makefile` 只做目标转发与跨组件制品构建。

```bash
make all                      # 编译器 + 运行站库 + svm
make build-tests              # 追加测试二进制与 .sasm 黄金用例
make coq                      # 仅 Coq：编译 .vo（= 证明检查门禁）
make veristc                  # Extraction + 链接 build/bin/veristc
make vm-lib vm-io vm-hs svm   # 运行站
make clean                    # 清除 build/ 与两组件中间产物
```

组件内自持构建（不经过根 `Makefile`）：

```bash
make -C veri-stc coq veristc
make -C veri-runtime all
```

Coq 侧也可用 dune 增量构建：

```bash
cd veri-stc
dune build                       # Coq 库
dune build @extraction           # 提取 OCaml
dune build extraction/veristc.exe
dune clean
```

产物一律收敛到 `build/`：`build/bin/{veristc,svm,test_*}`、`build/lib/libvm_*.a`、`build/sasm/*.sasm`。

## 验证

```bash
./integration/run_tests.sh                       # 全量（9 组：构建 + VM + 探针 + 通道 + 算法块 + 核电 + 编译用例 + sanitizer）
./veri-runtime/run_vm_checks.sh                  # VM/SVM 单元+周期+CRC（71 项，最细回归指纹）
./veri-stc/tests/compiler-tests/run_compiler_tests.sh  # 编译器正/负用例
./integration/run_nuclear_e2e.sh                 # 核电 ST（>10000 行）端到端
./integration/run_feature_probes.sh              # SafeST 特性面探针矩阵（PASS/XFAIL 覆盖表）
./veri-runtime/run_misra_check.sh                # MISRA-C 静态合规
./veri-runtime/run_sanitizer.sh                  # ASan/UBSan
./veri-runtime/run_fuzzer.sh 100000              # .sasm 加载器模糊测试
```

改动后应跑哪个脚本，按 [AGENTS.md](AGENTS.md) 的「变更后验证路由」决策表
（或 Skill `verify-route`）选择。

## 使用编译器与运行站

```bash
build/bin/veristc -c input.st -o output.sasm   # 编译
build/bin/veristc -a input.st                  # 静态分析（栈深/WCET/循环上界）
build/bin/veristc -g input.st -o out.svobj     # 可重定位对象
build/bin/veristc -x out.svobj                 # 校验 .svobj 结构与 CRC
build/bin/svm -n 10 -p 0 output.sasm           # 周期执行（10 个扫描周期）
build/bin/svm -d output.sasm                   # 反汇编 dump
build/bin/svm -i output.sasm                   # 段信息
```

## CI/CD

GitHub Actions（[.github/workflows/ci.yml](.github/workflows/ci.yml)）在每次 push/PR 执行：
Coq 库构建 → OCaml 提取 → `veristc` 可执行文件 → 运行站库与 `svm` → 测试构建 → MISRA-C 检查。

## 文档

- [AGENTS.md](AGENTS.md) —— 项目级指引：目录结构、三组件依赖规则、验证路由
- [spec/](spec/) —— SafeST / SafeASM 语言与二进制规范、语义保持说明（跨组件协议唯一源）
- [plan/](plan/) —— Phase 0–6 实现指引，含 [Phase 6 VeriIDE 设计](plan/phase6-veriide.prompt.md)
- [docs/architecture/](docs/architecture/) —— AS-IS 架构模型与数据流图（含 `文件:行号` 证据）
- [veri-stc/tests/st-examples/feature-probes/README.md](veri-stc/tests/st-examples/feature-probes/README.md) —— 特性覆盖矩阵

## 许可证

MIT License
