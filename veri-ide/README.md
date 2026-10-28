# veri-ide — 工程站组件（VeriIDE）

VeriIDE = **Veri**fied **I**ntegrated **D**evelopment **E**nvironment。
前后端分离的 Web 工程站：图形组态 → 代码编译 → 仿真验证 → 下装运行，
并提供自定义算法块与算法库扩展。

**当前状态：规划中（Phase 6）。** 本目录暂不含代码；目录骨架先行，
是为了固定三组件边界与依赖规则。实现排期见
[plan/phase6-veriide.prompt.md](../plan/phase6-veriide.prompt.md)。

## 信任级别

| 组件 | 信任级别 | 门禁 |
|------|---------|------|
| `veri-stc/` | 形式化核 | `make coq` 全绿、无新增 `Admitted` |
| `veri-runtime/` | 执行核 | MISRA-C + ASan/UBSan + fuzzer |
| `veri-ide/`（本组件） | 非安全侧工程工具 | 协议测试 + 图↔文本往返恒等测试 |

工程站自身不进入安全核交付物：它只生成文本 ST 与消费制品，
所有安全性质由 `veri-stc` 的证明与 `veri-runtime` 的校验承担。

## 依赖规则

- **R1** 跨组件耦合只能经由 `spec/` 协议（文本格式、二进制布局、JSON Schema）。
  禁止 `veri-ide` 直接 include `veri-stc/` 或 `veri-runtime/` 的源文件。
- **R2** `veri-ide` 仅可消费 `veri-runtime` 的公共头文件与 `build/lib/libvm_*.a`
  （仿真服务 sim-svc 需要），不得修改运行站源码。
- **R3** `veri-stc` 不依赖任何组件；`veri-runtime` 不依赖 `veri-stc` 源码，
  只消费其 `.sasm` 制品（由根 `Makefile` 收敛生成）。

## 规划的子结构

以下为 Phase 6 G1 起的目标布局，现尚未创建：

```
veri-ide/
├── schema/          块 manifest、图 JSON、工程/lock 的 JSON Schema（协议唯一源）
├── backend/
│   ├── project/     project-svc：文本化工程 + Git + diff/merge
│   ├── lang/        lang-svc：LSP（补全 / 悬停 / 诊断）
│   ├── build/       build-svc：PRE 块合并 → veristc -c/-g → 制品 + JSON 诊断
│   ├── sim/         sim-svc：libvm_core.a + VM_Interface 仿真后端 + watch
│   ├── deploy/      deploy-svc：分帧 / 校验 / 签名 → 周期边界原子切换
│   └── registry/    registry-svc：算法块与库制品仓（sha256 + semver + lock）
├── frontend/        项目树 · ST 编辑器 · 组态画布 · 监视表 / 时间线 · 下装向导
├── cli/             veride：无 UI 命令行入口，与 build-svc 共用内核（CI 用）
└── tests/           协议测试 + 往返恒等测试
```

## 不可妥协的设计约束

摘自 [plan/phase6-veriide.prompt.md](../plan/phase6-veriide.prompt.md)：

- **IDE-1**：编译器唯一入口是文本 ST。图形层只做「图 → 文本」源生成，
  禁止任何「图 → 字节码直达」路径（绕过证明边界，安全评审否决项）。
- **IDE-2**：图 JSON 为权威源，ST 为生成产物；ST 视图只读并提供锚点跳转。
- **IDE-3**：必须满足往返恒等 `graph → merged.st → graph`，且生成逐字节确定。
- **IDE-4**：算法库走 PRE 源码合并（`spec/safest-spec.md` §9.4），不引入链接器。
- **IDE-5**：工程全量文本化，二进制制品不入库。
- **IDE-6**：对编译器侧的改造只允许触碰 OCaml 入口
  `veri-stc/extraction/veristc_main.ml` 与 encoder 的纯新增段。
