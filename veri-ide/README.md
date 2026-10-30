# veri-ide — 工程站组件（VeriIDE）

VeriIDE = **Veri**fied **I**ntegrated **D**evelopment **E**nvironment。
前后端分离的 Web 工程站：图形组态 → 代码编译 → 仿真验证 → 下装运行，
并提供自定义算法块与算法库扩展。

**当前状态：阶段 3-E 完成（2026-10-30）。** 设备组态 → 图形组态 → 仿真（含引脚数值、
强制与按周期注入）已闭环，386 项 pytest 协议测试全绿。G4 下装与 G5 库管理已有骨架。
G0 前置能力已补齐（提交 `0155343`），G1 工程站骨架已完成，G2 图形组态已完成，G3 仿真验证已完成，G3.5 孪生模式已完成，G4 下装运行已完成，G5 库与扩展 W1 完成。

## 运行

三个进程：FastAPI 侧车（`127.0.0.1:8000`）、Vite 前端（`:1420`）、Tauri 桌面壳。
桌面壳负责拉起侧车，前端只与 8000 通信。

```bash
# 一次性准备
cd veri-ide
python3 -m venv .venv && .venv/bin/pip install -e .
cd web && pnpm install
cd .. && make -C .. all          # 产出 build/bin/{veristc,sim}，编译与仿真要用
```

入口是 `./run.sh`（不带参数即体检：venv、`build/bin/{veristc,sim}` 的实际解析结果、
打包产物、端口占用）：

```bash
cd veri-ide && ./run.sh dev        # 桌面壳（开发模式）：钩子拉起 Vite，main.rs 拉起侧车
cd veri-ide && ./run.sh backend    # 只要 UI：侧车 + Vite，浏览器打开 http://localhost:1420
cd veri-ide && ./run.sh appimage   # 跑打包版，且从 /tmp 启动 —— 证明它不依赖本仓库
cd veri-ide && ./run.sh stop       # 收掉本脚本起的后台进程（按进程组，不留孤儿）
```

`dev` 等价于在 `src-tauri` 里执行 `../web/node_modules/.bin/tauri dev`，必须在
`src-tauri` 跑：Tauri CLI 只向下查找 `tauri.conf.json`，从 `web/` 启动会报
「Couldn't recognize the current folder as a Tauri project」。而这两个钩子实际在**组件根目录**
（`src-tauri` 的上一级）执行，所以配置里写成 `pnpm --dir web ...`；裸 `pnpm dev` 在那里没有
`package.json`，会报 `ERR_PNPM_RECURSIVE_EXEC_FIRST_FAIL`。

开发模式下侧车用 `veri-ide/.venv/bin/python3`（`$PYTHON` 可覆盖），`veristc`/`sim`
由仓库 `build/bin/` 解析；打包模式两者都来自随包内容，见下节。

桌面壳加载窗口的时机早于侧车监听端口，所以 `web/src/main.tsx` 先轮询 `/health`，
通了才挂载应用；侧车约 18 秒内没有应答时页面给出明确提示，而不是空白。
Ctrl-C 结束 `dev` 时，Vite 与侧车同属一个进程组，一起退出；用 `kill <pid>` 单杀桌面壳
则会把侧车留在 8000 端口上 —— 下一次启动的「白屏」多半就是它，`./run.sh check` 会指出来。

## 打包

```bash
cd veri-ide && ./package.sh
# → src-tauri/target/release/bundle/appimage/VeriIDE_0.1.0_amd64.AppImage
```

打包版自带可运行的三样东西，不依赖本仓库 checkout：

| 随包内容 | 落点 | 解析方式 |
|---------|------|---------|
| Python 侧车（`.venv` 副本 + `veri_ide` 实体） | `<resource_dir>/python/` | `main.rs` 直接执行 `python/bin/python3` |
| `veristc`、`sim` | `<resource_dir>/bin/` | 启动时导出 `VERIDE_BIN_DIR`，四个工具查找器优先采信它 |
| 前端 `dist` | 内嵌二进制 | Tauri 资源协议 |

`payload/` 由脚本装配、不入库（见 `.gitignore`）；`bundle.resources` 用**目录键**
`"payload/python"`，写成 `"payload/python/**"` 会把匹配到的文件平铺进目标目录，
虚拟环境随之散架。三个坑见 `package.sh` 头部注释。

注意：随包的是本机 `.venv` 的副本，其 `pyvenv.cfg` 仍指向系统 Python 3.14 的标准库，
因此打包版只能在同版本 Python 的 Linux 主机上运行 —— 真正的独立运行时属于后续工程化项。

## 验证

| 范围 | 命令 |
|------|------|
| 后端（侧车全部域） | `cd veri-ide && .venv/bin/python -m pytest tests/ -q` |
| 前端类型与构建 | `cd veri-ide/web && pnpm exec tsc --noEmit && pnpm build` |
| 仿真数据链 | `./integration/run_sim_e2e.sh`（仓库根） |

## 工程生命周期与启动页交付物

- **工程脚手架**（`src/veri_ide/backend/project/service.py`）：`create_project` 在磁盘上建出
  `project.yaml` + `logic/ iomap/ device/ blocks/ sim/ build/`，`build/` 由 `.gitignore` 排除，
  并 `git init` + 首次提交；`is_project_dir` / `project_tree` / `count_artifacts` 供启动页读数
- **工作区单一真值**（`src/veri_ide/backend/project/workspace.py`）：`open_workspace` 一次读入
  设备/图页/工程块三域并给空工程落地下种子制品（站 `ST1` + 页 `PAGE1`），`save_workspace` 一次写回，
  `resolve_project_path` 让各阶段页面不再手输工程目录
- **最近列表**（`src/veri_ide/backend/project/recent.py`）：`~/.veride/recent.json`（`VERIDE_HOME` 可改），
  工程行读盘重算 `站/图页/块` 计数并把丢失目录标为 `exists: false`；工程作用域的块行不受
  「当前库有没有它」影响，始终带所属工程名
- **算法块即文本**（`src/veri_ide/backend/library/store.py`）：`<Type>.block.yaml` + `<Type>.st` 成对读写，
  `<Type>` 取 ST 里声明的 POU 名（`st_type_name`）；全局用户库 `~/.veride/library/` 与工程 `blocks/`
  两 scope，同名遮蔽；4 个内置块首次运行落盘
- **HTTP 端点**（`src/veri_ide/backend/project/router.py`）：`GET /project/state` /
  `POST /project/create|open|save|close|forget` / `GET /project/current`
- **启动页**（`web/src/pages/HomePage.tsx`）：新建工程 / 打开工程 / 新建算法块三张引导卡 + 两条最近列表 +
  面板内校验（工程名与 ST 类型名为标识符，ST 声明名与类型名一致）
- **工程上下文**（`web/src/project/ProjectProvider.tsx`）：标题栏常驻当前工程，
  设备组态页与图形组态页的读写都指向它（`data-testid="device-project"` / `"graph-project"`）
- **协议测试门禁**（`tests/test_project_api.py` + `tests/test_library_store.py`）：19 项 pytest 用例

## G5 W1 交付物

- **块 manifest 协议**（`schema/block.schema.json`）：端口/类型/默认参数/图标/SIL 属性/semver/实现源哈希
- **Manifest 模型**（`src/veri_ide/backend/registry/manifest.py`）：`BlockManifest` / `PortDef` / `InterfaceDef` / `ImplementationDef` / `AnalysisResult`
- **库注册服务**（`src/veri_ide/backend/registry/service.py`）：`RegistryService` / 注册/查询/列出/搜索/卸载 + 内容寻址存储（SHA-256）
- **Lock 文件管理**（`src/veri_ide/backend/registry/lock.py`）：`LockFile` / `LockEntry` / lib.lock.yaml 读写
- **准入门禁**（`src/veri_ide/backend/registry/admission.py`）：`AdmissionGate` / WCET/栈深/纯性/循环上界检查
- **协议测试门禁**（`tests/test_registry.py`）：31 项 pytest 用例

## G4 W2 交付物

- **后端 API 端点**（`src/veri_ide/api/server.py`）：`POST /deploy` / `POST /keys/generate` / `GET /keys` / `GET /keys/{name}` / `DELETE /keys/{name}`
- **前端 API 集成**（`frontend/public/download-wizard.html`）：`apiCall()` / `loadKeys()` / `generateKey()` / `startDeploy()` 异步调用
- **密钥管理 UI**：步骤 2 密钥下拉框 + 生成新密钥按钮 + 自动加载密钥列表
- **协议测试门禁**（`tests/test_deploy_service.py` + `tests/test_key_manager.py`）：26 项 pytest 用例

## G4 W1 交付物

- **DeployService 下装服务**（`src/veri_ide/backend/deploy/service.py`）：`DeployService` / `DeployResult` / `TargetConfig` / 帧流生成 + 管道/文件发送
- **密钥管理服务**（`src/veri_ide/backend/deploy/key_manager.py`）：`KeyManager` / 生成/存储/加载/删除 HMAC-SHA256 密钥
- **下装向导 UI**（`frontend/public/download-wizard.html`）：5 步骤向导（目标配置/密钥选择/下装参数/执行/完成）
- **协议测试门禁**（`tests/test_deploy_service.py` + `tests/test_key_manager.py`）：26 项 pytest 用例

## G3.5 W2 交付物

- **前端生模式 UI**（`frontend/public/waveform-viewer.html`）：被控对象编辑器 + 孪生仿真按钮 + 统计面板 + HTML 报告导出
- **模式切换**：干跑模式（无 plant）/ 孪生模式（闭环仿真）指示器

## G3.5 W1 交付物

- **Plant 模型管理**（`src/veri_ide/backend/sim/plant.py`）：`PlantService` / `PlantModel` / `PlantChannel` / 解析/校验/生成 .plant 文件
- **孪生模式仿真**（`src/veri_ide/backend/sim/service.py`）：`SimService.run_twin_simulation` / 先编译 ST→.sasm 再闭环仿真
- **统计模块**（`src/veri_ide/backend/sim/statistics.py`）：`StatisticsService` / 均值/方差/峰值/稳态时间/上升时间/振荡检测
- **协议测试门禁**（`tests/test_plant_service.py` + `tests/test_statistics.py`）：32 项 pytest 用例

## G3 W2 交付物

- **基线管理**（`src/veri_ide/backend/sim/baseline.py`）：`Baseline` / `BaselineManager` / `save_baseline` / `load_baseline` / `delete_baseline` / `list_baselines`
- **偏差检测**（`src/veri_ide/backend/sim/baseline.py`）：`compute_deviation` / `find_max_deviation` / `check_threshold`
- **协议测试门禁**（`tests/test_baseline.py`）：14 项 pytest 用例，覆盖基线 CRUD + 偏差计算 + 阈值检测

## G3 W1 交付物

- **sim-svc 仿真服务**（`src/veri_ide/backend/sim/service.py`）：`SimService` / `SimulationResult` / `run_simulation`
- **波形视图**（`frontend/public/waveform-viewer.html`）：SVG 波形渲染 + 统计信息 + 工具栏
- **协议测试门禁**（`tests/test_sim_service.py`）：10 项 pytest 用例

## G2 W4 交付物

- **功能图编辑器**（`frontend/public/graph-editor.html`）：SVG 画布 + 拖拽编辑 + 实时 ST 预览
- **使用说明**（`frontend/public/GRAPH_EDITOR.md`）：功能/数据格式/已知限制/后续扩展

## G2 W3 交付物

- **ST→图反向解析器**（`src/veri_ide/backend/gen/st_to_graph.py`）：`parse_st_to_graph` / `normalize_graph_for_comparison`
- **往返恒等测试**（`tests/test_roundtrip.py`）：9 项 pytest 用例，验证图→ST→图拓扑等价

## G2 W1-W2 交付物

- **FC JSON Schema**（`src/veri_ide/schema/fc.schema.json`）：功能图协议定义（块/连线/接口）
- **图校验模块**（`src/veri_ide/backend/gen/validator.py`）：`validate_fc_json` / `check_no_cycles` / `topological_sort`
- **图→ST 生成器**（`src/veri_ide/backend/gen/graph_to_st.py`）：`generate_st_from_fc`（拓扑排序 + 代码生成）
- **示例功能图**（`examples/pid_control.fc.json`）：PID 控制器互联示例
- **协议测试门禁**（`tests/test_fc_validator.py` + `tests/test_graph_to_st.py`）：27 项 pytest 用例

## W4 交付物

- **FastAPI 后端**（`src/veri_ide/api/server.py`）：`/health` / `/build` / `/` 端点 + CORS 中间件
- **CLI 服务命令**（`src/veri_ide/cli.py`）：`veride watch` 启动 API 服务器
- **前端 API 集成**（`frontend/public/editor.js`）：编译按钮调用后端 + 诊断展示 + 降级策略
- **协议测试门禁**（`tests/test_api.py`）：10 项 pytest 用例，覆盖端点/请求/响应/CORS/清理

## W3 交付物

- **Monaco Editor 集成**（`frontend/public/`）：ST 语法高亮 + 深色主题 + 行号 + 小地图
- **TextMate 语法**（`frontend/src/st-language.tmLanguage.json`）：ST 关键字/类型/运算符/注释/字符串
- **诊断面板**：实时错误标记 + 颜色编码 + 清除按钮
- **LSP 服务端骨架**（`src/veri_ide/lsp/`）：pygls 框架（完整集成推后续迭代）

## W2 交付物

- **工程服务**（`src/veri_ide/backend/project/service.py`）：`create_project` / `open_project` / `list_projects` / `commit_project` / `diff_project` / `delete_project`
- **构建服务**（`src/veri_ide/backend/build/service.py`）：`build_project` / `parse_ndjson_diagnostics` / `find_veristc_binary`
- **CLI 命令行**（`src/veri_ide/cli.py`）：`veride create` / `info` / `ls` / `build` / `commit`
- **协议测试门禁**（`tests/`）：45 项 pytest 用例，覆盖工程 CRUD + Git 集成 + 编译诊断解析 + API 端点 + 端到端流程

## W1 交付物

- **JSON Schema 协议**（`src/veri_ide/schema/`）：`project.schema.json` / `iomap.schema.json` / `lib.lock.schema.json`
- **Schema 校验模块**（`src/veri_ide/backend/project/schema.py`）：`validate_project_yaml` / `validate_iomap_toml` / `validate_lib_lock_yaml` / `validate_project`
- **PRE 合并内核**（`src/veri_ide/backend/pre/merge.py`）：首期只拼接（PRE-1），不做命名空间 mangle（PRE-4 推 G5）
- **协议测试门禁**（`tests/`）：11 项 pytest 用例，覆盖 schema 合法/非法 + PRE 合并顺序/缺失文件
- **测试样本工程**（`tests/fixtures/valid-project/`）：`project.yaml` + `logic/MAIN.st` + `logic/pid.st` + `iomap/ai.toml`

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

## 工程文件夹布局

一个工程 = 磁盘上的一个文件夹，除 `build/` 外全部文本化，可直接用 Git 审改：

```
<project>/
├── project.yaml           工程名 / SIL / 目标 VM 版本 / 创建时间
├── .gitignore             只排除 build/
├── device/stations.toml   站清单（设备类型、周期、通信）
├── iomap/<station>.toml   该站的通道映射与点属性（量程/偏置/单位/质量/故障保持）
├── logic/<PAGE>.FC.json   图页，自描述（含 page.index 排序），无索引文件
├── blocks/<Type>.block.yaml + <Type>.st   工程内算法块，同名遮蔽全局用户库
├── sim/                   预留：仿真工作目录（当前仿真仍写临时目录）
└── build/                 .sasm 等派生制品，不入库
```

全局状态在 `~/.veride/`（`VERIDE_HOME` 覆盖）：`library/` 为用户算法块库，`recent.json` 为最近工程与最近算法块。

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
