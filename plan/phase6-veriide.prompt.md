---
name: phase6-veriide
description: 'Phase 6: build VeriIDE, a front-end/back-end separated Web IDE on top of VeriSTC, closing the loop of graphical configuration -> compile -> simulation -> download-and-run, with user-definable algorithm blocks and libraries. Use when: designing or implementing VeriIDE (工程站), the block-library mechanism, the simulation backend, or the download protocol.'
---

# Phase 6：VeriIDE（前后端分离 Web IDE，参考 CODESYS 4 架构）

## 命名

VeriIDE = **Veri**fied **I**ntegrated **De**velopment **E**nvironment，与 VeriSTC 同源命名：编译器 `veristc`（工具链侧）、工程站 `VeriIDE`（工程侧）、其无 UI 命令行入口 `veride`。

## 目标

在不破坏 Phase 1 语义证明边界的前提下，交付 VeriIDE —— 一个基于浏览器的工程站，完成四段闭环：

```
图形组态 ──> 代码编译 ──> 仿真验证 ──> 下装运行
   ↑                                    │
   └────────── 在线监视 / 偏差回溯 ──────┘
```

并支持用户自定义算法块与算法库扩展（对应 CODESYS 4 的「库概念 + 扩展模型」支柱）。

## 设计约束（不可妥协）

| 编号 | 约束 | 理由 |
|------|------|------|
| IDE-1 | 编译器唯一入口是**文本 ST**。图形层只能做「图 → 文本」源生成，禁止任何「图 → 字节码直达」路径 | `compiler_correctness.v` 四大定理只覆盖 ST→SafeASM；绕过文本边界的变换全部脱离证明，属安全评审否决项 |
| IDE-2 | **图 JSON 是权威源，ST 是生成产物**；ST 视图只读并提供锚点跳转 | 端口/连线不会与文本漂移；生成前即可做门禁校验 |
| IDE-3 | 图形层必须满足往返恒等 `graph -> merged.st -> graph`，且生成逐字节确定 | 现有 `compile_determinism` 只覆盖编译器半段，生成器半段需新测试补齐 |
| IDE-4 | 算法库走**源码合并**（PRE-1..PRE-8），不引入链接器 | `spec/safest-spec.md` §9.4 已明确「不设置 LIBRARY/IMPORT 运行时链接机制」，并把展开责任指派给前端编辑器/预处理器；零证明影响 |
| IDE-5 | 工程全量文本化，二进制制品不入库 | 对齐 CODESYS 4「工程文本化」，Git / diff / CI/CD 可用 |
| IDE-6 | IDE 侧改造只允许触碰 OCaml 入口（`veristc_main.ml`）与 encoder 的**纯新增**段，不得改动已证明结构 | 保住 `make coq` 绿色与既有定理 |

## 前置差距（G0 必须先补，否则闭环断在数据面上）

| # | 需要的能力 | 现状 | 证据 |
|---|-----------|------|------|
| 1 | 工程/多文件输入 | 🟡 部分已清（G0/W1）：写当前工作目录的隐患已消除——`-c`/`-g` 缺 `-o` 即判退出码 11，**绝不落到 CWD**；多文件/工程目录输入仍待 G1（编译器唯一入口仍是单个文本 `.st`，这是语义证明边界） | `spec/safest-spec.md` 附录 D、`veri-stc/tests/compiler-tests/run_compiler_tests.sh` 第 3 步 |
| 2 | 结构化诊断 | ✅ 已清（G0/W1，决策 D3）：全量诊断收集 + `--json` NDJSON（`pou/var/kind/loc/msg`）+ 约定退出码 0/11/21–25；`loc` 按 D3 只到 **POU + 变量名**，语句级定位推到 G2 | `spec/safest-spec.md` 附录 D、`veri-stc/src/function_check.v` 的 `diagnostic` 记录、`veri-stc/extraction/veristc_main.ml` 的 `--json` 路径 |
| 3 | 图形语言 | 无。AST 仅 ST 语句集 | [safest.v:290-344](file:///home/wei/veristc/veri-stc/spec/safest.v#L290) |
| 4 | ✅ 已清（G0/W2+W2'）| ~~仿真监视 name→addr：`.sasm` DEBUG 段从未发射，IOMAP 条目 `st_var_name_offset` 与 `scale/bias` 写死占位 `0`~~ ⇒ 段 7 符号表已发射并由 `svm -s/-l/-i` 解析；scale/bias 走「文件 ≡ IR」真值链；`mem_offset` 改为按名解析到真实全局槽位（GATE-7） | `spec/safeasm-spec.md` §4.8 / §4.4「地址单一真值」 |
| 5 | ✅ 已清（G0/W3+W4）| ~~数字孪生闭环：`svm.c` 用 stub 覆盖 `io_mapping_cycle` ⇒ 发布二进制零 I/O；`VM_Interface` 仿真后端无任一实现~~ ⇒ `sim` 主程序实现 8 个被真实调用的接口 + `.plant` 被控对象，`io_mapping_cycle` 端到端跑通并有 12 周期黄金时间线（`integration/run_sim_e2e.sh`）。W4 补上监视数据面：`sim --watch 名字表` 逐周期发 stdout JSONL 帧（名字→段 7 地址→数值，含派生名 `cnt#N`、`status`、累计 `violations`、流末 done 帧），即工程站仿真按钮要消费的那一份。`svm` 仍定位为纯执行、不做 I/O | `veri-runtime/sim/`、`spec/simulation-spec.md` §4 |
| 6 | 下装传输 | ✅ 已清（G0/W5，决策 D5）：下装帧协议（24B 头 + 载荷 + HMAC-SHA256，CRC32/HMAC 两道独立闸、MAC 先验）、接收状态机与十类拒绝码、全量镜像版本槽 + `vm_rebind` 周期边界原子切换 + 一级回滚、目标端 `veristc-agent`（装载/周期执行/下装服务/状态上报，管道后端）。`crc32==0` 后门已关闭（未计算校验和一律拒）。真签名、UDS/网络、重传与断点续传推到 G4；增量补丁代码保留但不进链路 | `spec/download-spec.md`、`veri-runtime/hotstandby/download_wire.c`、`integration/run_download_e2e.sh`（34 项） |
| 7 | 版本化库 | 仅 `veri-stc/tools/stpreproc.py` 演示实现，PRE-2/3/5 契约未成体系；无 lock、无内容寻址 | [safest-spec.md:1604-1611](file:///home/wei/veristc/spec/safest-spec.md#L1604) |
| 8 | 资源上限强制 | 栈深 > 256 已拒绝，但 `check_all_loops_bounded` / `estimate_wcet` 算了**不接拒绝路径** | [analysis.v:153](file:///home/wei/veristc/veri-stc/src/analysis.v#L153) |

## 架构分层

```
前端（浏览器）   项目树 · ST 编辑器(Monaco+LSP) · 组态画布 · 监视表/时间线 · 下装向导 · 库管理
    ↑↓  REST: 工程与文件 CRUD      WS-RPC: 构建/仿真/在线      WS-binary: trace 采样
VeriIDE 后端（权威进程，按用户进程隔离）
  ├ project-svc   文本化工程 + Git + diff/merge
  ├ lang-svc      LSP（补全/悬停/诊断），独立于编译器证明
  ├ build-svc     块合并(PRE) -> veristc -c/-g -> 制品 + manifest + JSON 诊断（无状态 sidecar 池）
  ├ sim-svc       libvm_core.a + SIM 后端(io_read/io_write/io_group_*/get_ticks/sleep) + watch + 黄金时间线 diff
  ├ deploy-svc    分帧 / 校验 / 签名 -> 目标端周期边界原子切换 + 回滚
  └ registry-svc  算法块与库制品仓（sha256 内容寻址 + semver + lock）
目标端（安全侧，与 IDE 解耦）  veristc-agent：装载 + 周期执行 + 主备同步 + 下装 commit
CI/CD           veride CLI（对齐 CODESYS c4），复用 build-svc 同一内核
```

多租户要求：编译器进程不常驻不共享（每请求独立工作目录）；VM 实例每工程一进程（现 `svm.c` 用全局单例，不可重入）。

## 工程文本化布局

```
plant-unit/                        <- 全文本，入 Git
├── project.yaml                   工程元数据、认证 VM 版本锁、safety_level
├── iomap/ai.toml                  I/O 组态（通道/量程/安全限值），从内嵌 .sasm 提为文件
├── logic/
│   ├── MAIN.st                    PROGRAM 体（可手写）
│   ├── pump_interlock.FC.json     功能图：块 + 连线 + 端口绑定 + 文本锚点
│   └── esfas_seq.SFC.json         顺控图
├── blocks/pid.st + pid.block.yaml 项目内自定义块（实现 + manifest）
├── lib.lock.yaml                  库名 / 版本 / sha256 三元组
├── sim/plant.yaml                 被控对象与扰动模型
├── sim/golden/*.expect            黄金时间线基线
└── build/                         派生制品 .merged.st / .sasm / .svobj，不入库
```

## 核心产出物

| 产出物 | 路径 | 内容 |
|--------|------|------|
| 编译器 API 包装 | `veri-stc/extraction/veristc_main.ml`（扩展） | `--json` 诊断、约定退出码、隔离输出目录、`LOC` 至少填到 POU/端口粒度 |
| 符号名段发射 | Coq `global_codegen.v`（新增取行函数）+ `veristc_main.ml`（字节编码）+ `veri-runtime/core/loader.c` | 新增 `SEC_DEBUG 7`：字符串池 + name→(addr,type) 符号表。**字节编码不进 Coq**（Coq `ident`/`float` → 字节无可靠路径，与 `emit_svobj` 同层） |
| 仿真后端 | `veri-runtime/sim/`（新增） | 只实现**被真实调用**的 `io_read/io_write` + `get_ticks/sleep/ms_to_ticks/init/deinit`；前置需修 `loader.c` 丢弃 scale/bias 与 `svm` 的 `io_mapping_cycle` stub |
| watch 通道 | `veri-runtime/sim/watch.c`（新增） | 读 `vm->memory` + 符号表解析 name→addr，输出结构化采样帧 |
| 下装协议 + agent | `veri-runtime/hotstandby/download_wire.c`、`veri-runtime/agent/` | 分帧/重组/签名校验/周期边界提交/回滚；关闭 `CRC==0` 后门并真校验 patch CRC |
| 图→ST 生成器 | `veri-ide/backend/gen/` | `*.FC.json` / `*.SFC.json` → `merged.st`；确定性 + 往返恒等 |
| 块 manifest 契约 | `veri-ide/schema/block.schema.json` | 端口方向/类型/默认参数/图标/SIL 属性/semver/实现源哈希 |
| 库注册服务 | `veri-ide/backend/registry/` | 内容寻址制品 + `lib.lock.yaml` + 准入门禁（WCET/栈深/纯性/循环上界） |
| PRE 展开内核 | `veri-ide/backend/pre/`（替换 `veri-stc/tools/stpreproc.py`） | PRE-1..PRE-8 全量落地，尤其 PRE-2 确定性、PRE-3 递归上限、PRE-4 命名空间 mangle、PRE-5 manifest |
| 前端 | `veri-ide/frontend/` | 编辑器 / 画布 / 监视表 / 时间线 / 下装向导 |
| CLI | `veri-ide/cli/veride` | 无 UI，工作区·会话·PLC 命令，CI 复用 build-svc |

## 实现流程

1. **G0 前置能力补齐（4-6 周）**：产出物 1~5，实施级方案见 `phase6-g0-technical-plan.md`。
   验收 = 新增 e2e 断言「IDE 侧能从 watch 读到 `pid1#OUT` 的真实数值」，且 `veri-runtime/run_vm_checks.sh` 扩展到含 watch 与下装帧校验；`make coq` 保持绿色、无新增 `Admitted`。
   **决策 D1**：验收信号取 **DINT** 而非 REAL —— REAL 全链路当前不可用（词法无小数字面量、`F32_CONST` 立即数被编码为全零且无 OCaml 后处理），补 REAL 属并行子项、不在 G0 关键路径。
2. **G1 骨架（4 周）**：文本化工程 schema + project-svc + ST 编辑器 + LSP + build-svc + CLI。验收 = 无 GUI 全链路（CLI 提交工程 → 得制品 + JSON 诊断）。
3. **G2 图形组态（6-8 周）**：画布 + 块/端口模型 + 图→ST 生成器 + 往返恒等 CI 门禁。连线语义直接映射已实现且 Coq 检查过的三机制：端口绑定→具名实参 `S_FB_CALL`、跨周期状态→FB 内 `VAR`、透传/跟踪→`VAR_IN_OUT` 别名。
4. **G3 仿真验证（4 周）**：双模式仿真（干跑=无 I/O 逻辑级，对照黄金时间线；孪生=plant 模型 + watch），波形视图、基线管理与偏差回指到块。
5. **G4 下装运行（4 周）**：下装向导 + 制品校验/签名 + 周期边界原子切换 + 回滚 + 主备双通道 + 审计链。
6. **G5 库与扩展（6 周）**：registry + manifest SDK + 版本/lock + 块准入门禁 + CI/CD 模板 + MCP Server（面向全工程的 AI 助手）。

## 上下游关系

- **上游依赖**：Phase 1（编译器 + `.sasm`/`.svobj` 编码）、Phase 2（`VM_Interface` 抽象）、Phase 3（快照/主备/进程内下装原语）
- **下游产出**：为后续 V&V 数字化（批量回归、可复现构建审计）提供工程站底座

## 关键决策

- 图形权威 = 图 JSON，ST 为生成产物（IDE-2）；手写 ST 与图混排以「段落边界」隔离
- 库机制 = PRE 源码合并，不实现 `veristc-ld`；整工程全量重编，以生成器 + 编译器确定性换取证明边界完整
- 传输 = REST + WebSocket RPC；构建流为拉取式（前端订阅 job 事件）
- 下装首期只做**全量 + 签名 + 周期边界切换**，增量补丁待结构变更能力补齐后再开放
- 目标形态先虚拟控制器（容器/Linux x64），真机作为 G4 之后的移植项
- **G0 五项已定决策（D1–D5）**：验收信号用 DINT ／ IOMAP `st_var_name_offset` 降级 reserved、符号名全放 section 7 ／ LOC 只到 POU+变量名 ／ watch 首期 stdout 帧不上 socket ／ 下装首期 HMAC-SHA256、真签名推 G4。逐条后果与字节契约见 `phase6-g0-technical-plan.md` §0

## 范围外（首期不做）

断点 / 单步 / 变量写入与强制（VM 无 debug hook，且「强制」在核级仪控需单独安全评审）；可视化 Visu；运动控制；OPC UA；第三方插件市场。

## 待议

- **规范漂移**：PRE-8 声明「未展开的 FB 调用禁止提交编译器」，但 v1.5.1 已支持原生 `FUNCTION_BLOCK` 直接编译（`veri-stc/tests/st-examples/algo_blocks_fb.st`）。IDE 与 PRE 内核必须认单一权威，建议改写 §9.4 第二层为「按块来源分层」而非「按是否展开分层」。
- `.iomap` 是否独立成文件：现状是内嵌 `.sasm` Section 3，AGENTS.md 却宣称独立 `.iomap` 产物。建议以 `iomap/*.toml` 为工程源、`.sasm` 内嵌段为编译产物，消除文档与实现的口径差。
