# veri-ide — 工程站组件（VeriIDE）

VeriIDE = **Veri**fied **I**ntegrated **D**evelopment **E**nvironment。
前后端分离的 Web 工程站：图形组态 → 代码编译 → 仿真验证 → 下装运行，
并提供自定义算法块与算法库扩展。

**当前状态：G2 W1-W2 完成（2026-10-29）。** 功能图 Schema + 图→ST 生成器已交付，72 项协议测试全绿（G1: 45 + G2: 27）。
G0 前置能力已补齐（提交 `0155343`），G1 工程站骨架已完成，G2 图形组态方案见 [plan/phase6-g2-technical-plan.md](../plan/phase6-g2-technical-plan.md)。

## 快速开始

### 使用 CLI

```bash
# 安装
cd veri-ide
python3 -m venv .venv
source .venv/bin/activate
pip install -e .

# 创建工程
veride create myproj
cd myproj

# 编辑 logic/main.st 和 project.yaml
cat > logic/main.st << 'EOF'
PROGRAM main
VAR
    counter : DINT;
END_VAR
counter := counter + 1;
END_PROGRAM
EOF

# 编译
veride build .
# 输出：build/output.sasm
```

### 使用 Web 编辑器

```bash
# 启动后端 API 服务
veride watch --host 127.0.0.1 --port 8000

# 另开终端，启动前端静态服务
cd frontend/public
python3 -m http.server 8080

# 浏览器打开 http://localhost:8080
```

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
