---
name: phase6-g1-technical-plan
description: 'Phase 6 G1 工程站骨架详细技术方案（文本化工程 schema + project-svc + ST 编辑器 + LSP + build-svc + CLI）。当实现 VeriIDE 工程站骨架、协议测试门禁、图→ST 生成器前置时必读。'
---

# Phase 6 G1 — 工程站骨架详细技术方案

本文是 `phase6-veriide.prompt.md` 中「G1 骨架（4 周）」的实施级设计。G1 的验收总目标：
**无 GUI 全链路（CLI 提交工程 → 得制品 + JSON 诊断）**，且协议测试门禁覆盖 IDE 对编译器/仿真/下装的调用路径。

## 0. 已定决策（本文其余部分的前提，勿在实现时重开）

| # | 决策 | 后果 |
|---|------|------|
| **D1** | G1 只做**文本工程**，不引入图形组态 | 图→ST 生成器推到 G2；G1 验收不要求 `*.FC.json` / `*.SFC.json` |
| **D2** | 工程全量文本化，二进制制品**不入库** | `build/` 目录 `.gitignore`；Git 只跟踪 `project.yaml` / `logic/*.st` / `iomap/*.toml` / `lib.lock.yaml` |
| **D3** | LSP 首期只做**诊断 + 悬停**，不做补全 | 补全需类型推断与符号表索引，复杂度高；首期用编译器 `--json` 诊断 + 段 7 符号表提供基础 LSP |
| **D4** | build-svc 首期**不常驻**，CLI 每次调用独立进程 | 多租户/进程池推到 G3；首期每请求 `fork` 一个 `veristc` 进程，工作目录隔离 |
| **D5** | 协议测试门禁**黑盒**调 CLI，不直接 import 编译器内部 | 守住 R1（跨组件耦合只经 `spec/` 协议）；测试断言退出码 + JSON 诊断 + 制品结构 |

## 1. 现状核查结论

### 1.1 G0 已交付的 IDE 消费面

| 能力 | G0 交付物 | IDE 消费方式 |
|------|----------|-------------|
| 机器可读诊断 | `veristc --json` NDJSON（`pou/var/kind/loc/msg`）+ 退出码 0/11/21-25 | build-svc 解析 JSON → 编辑器诊断装饰 |
| 符号名段 | `.sasm` 段 7（STRPOOL + SYMTAB）+ `svm -s/-l/-i` | LSP 悬停显示变量类型/地址；仿真 watch 帧消费 |
| 仿真监视 | `sim --watch 名字表` stdout JSONL（名字→地址→数值） | 仿真视图订阅 stdout 流 → 时间线渲染 |
| 下装协议 | DLF1 帧（HMAC+CRC 两道闸）+ `veristc-agent` 周期边界切换 | deploy-svc 分帧 → 管道送 agent → 状态帧回显 |

### 1.2 G1 必须补的缺口

| # | 缺口 | 现状 | G1 交付 |
|---|------|------|---------|
| 1 | 文本化工程 schema | 无；编译器只接受单 `.st` 文件 | `project.yaml` + `logic/*.st` + `iomap/*.toml` + `lib.lock.yaml`；PRE 展开内核读 schema 合并 |
| 2 | project-svc | 无 | 工程 CRUD + Git 提交/diff；首期不做多租户隔离 |
| 3 | ST 编辑器 | 无 | Monaco Editor + 基础语法高亮（关键字/注释/字符串）；LSP 诊断 + 悬停 |
| 4 | LSP | 无 | 首期：诊断（调 `veristc --json`）+ 悬停（查段 7 符号表）；补全推 G2 |
| 5 | build-svc | 无 | 读 `project.yaml` → PRE 合并 → `veristc -c` → `.sasm` + JSON 诊断；首期单进程 |
| 6 | CLI（veride） | 无 | `veride build <project-dir>` → 调 build-svc → 输出制品路径 + 诊断；CI 复用 |
| 7 | 协议测试门禁 | 无 | 黑盒调 CLI，断言退出码 + JSON 结构 + 制品字节；首期 10+ 用例 |

### 1.3 证明锥影响

G1 **不触碰** `veri-stc/src/*.v`（证明锥内），只消费 `veristc` 可执行文件的 CLI 协议。
⇒ `make coq` 零影响，定理证明零回归。

---

## 2. 产出物 1 — 文本化工程 schema

### 2.1 目标布局

```
my-project/                        <- 全文本，入 Git
├── project.yaml                   工程元数据（name/safety_level/svm_version）
├── iomap/
│   ├── ai.toml                    AI 通道组态（channel/scale/bias/safety_limit）
│   └── do.toml                    DO 通道组态
├── logic/
│   ├── MAIN.st                    PROGRAM 体（手写或图生成）
│   └── pid.st                     FUNCTION_BLOCK（手写或库导入）
├── lib.lock.yaml                  库名/版本/sha256 三元组（内容寻址）
├── sim/
│   ├── plant.yaml                 被控对象模型（CONST/LAG/RAMP/ACTUATOR）
│   └── golden/*.expect            黄金时间线基线
└── build/                         派生制品（.merged.st / .sasm / .svobj），.gitignore
```

### 2.2 JSON Schema 协议

| Schema | 路径 | 内容 |
|--------|------|------|
| `project.schema.json` | `veri-ide/schema/` | `project.yaml` 结构：`name: string`, `safety_level: enum[SIL1-3]`, `svm_version: string` |
| `iomap.schema.json` | `veri-ide/schema/` | `iomap/*.toml` 结构：`channel: int`, `scale: float`, `bias: float`, `safety_limit: {min, max}` |
| `lib.lock.schema.json` | `veri-ide/schema/` | `lib.lock.yaml` 结构：`name: string`, `version: semver`, `sha256: hex` |

**协议测试门禁**：
- 用 `ajv` 或 Python `jsonschema` 校验 schema 合法性
- 非法 schema → 拒绝编译（exit 21）

### 2.3 PRE 展开内核（首期最小集）

首期只做 **PRE-1（文件包含）** 与 **PRE-4（命名空间 mangle）**，不做 PRE-2/3/5/6/7/8（推 G5 库机制）。

**PRE-1 文件包含**：
- `logic/MAIN.st` 里写 `(* #include "pid.st" *)` → PRE 内核读 `project.yaml` 解析路径 → 拼接为 `merged.st`
- 拼接顺序按 `project.yaml` 的 `logic_files: [MAIN.st, pid.st]` 显式声明（不依赖 `#include` 指令）

**PRE-4 命名空间 mangle**：
- 首期不实现；多文件同名 POU 冲突由编译器 `duplicate_declaration_msg` 拒绝（G0 已实现）

**产物**：`build/merged.st`（不入库）→ 喂给 `veristc -c build/merged.st -o build/output.sasm`

---

## 3. 产出物 2 — project-svc（首期最小集）

### 3.1 职责

- 工程 CRUD：`create` / `open` / `list` / `delete`
- Git 集成：`commit` / `diff` / `log`（首期不做 merge/resolve）
- 文件锁：首期不做（单用户本地）

### 3.2 技术选型

| 组件 | 选型 | 理由 |
|------|------|------|
| 语言 | Python 3.10+ | 快速原型；CI 环境已有；不引入 Node.js 依赖 |
| 框架 | FastAPI | 异步；自动 OpenAPI 文档；首期 CLI 直调，后续前端消费 |
| 存储 | 本地文件系统 + Git | 工程 = 目录；版本 = Git 提交；无数据库 |

### 3.3 API 协议（首期 CLI 直调，不暴露 HTTP）

```python
# veri-ide/backend/project/main.py
def create_project(name: str, path: Path) -> ProjectMeta: ...
def open_project(path: Path) -> ProjectMeta: ...
def commit_project(path: Path, message: str) -> GitCommit: ...
def diff_project(path: Path, rev1: str, rev2: str) -> GitDiff: ...
```

**协议测试门禁**：
- `create_project` → 检查 `project.yaml` 生成 + Git 初始化
- `commit_project` → 检查 Git 提交哈希返回

---

## 4. 产出物 3 — ST 编辑器 + LSP（首期最小集）

### 4.1 编辑器

| 组件 | 选型 | 理由 |
|------|------|------|
| 编辑器 | Monaco Editor | VS Code 同源；ST 语法高亮可复用 TextMate grammar |
| 语法高亮 | `st-language.tmLanguage.json` | 首期手写；关键字/注释/字符串/数字 |

### 4.2 LSP 首期能力

| 能力 | 实现方式 | 协议测试 |
|------|---------|---------|
| 诊断 | 调 `veristc --json` → 解析 NDJSON → 转为 LSP `Diagnostic` | 非法 ST → 编辑器红线 + 退出码 21 |
| 悬停 | 查段 7 符号表（`svm -l`）→ 显示类型/地址 | 鼠标悬停变量 → 显示 `DINT @ 4096` |
| 补全 | **首期不做** | 推 G2（需类型推断） |

### 4.3 LSP 技术选型

| 组件 | 选型 | 理由 |
|------|------|------|
| LSP 框架 | `pygls` (Python) | 轻量；与 project-svc 同语言 |
| 通信 | stdio | 首期本地；后续推 WebSocket |

---

## 5. 产出物 4 — build-svc（首期最小集）

### 5.1 职责

读 `project.yaml` → PRE 合并 → `veristc -c` → `.sasm` + JSON 诊断

### 5.2 实现

```python
# veri-ide/backend/build/main.py
def build_project(project_path: Path) -> BuildResult:
    # 1. 读 project.yaml，校验 schema
    meta = load_project(project_path)
    
    # 2. PRE 合并（首期只拼接）
    merged = pre_merge(project_path / "logic", meta.logic_files)
    (project_path / "build" / "merged.st").write_text(merged)
    
    # 3. 调 veristc -c
    result = subprocess.run(
        ["veristc", "-c", "build/merged.st", "-o", "build/output.sasm", "--json"],
        cwd=project_path,
        capture_output=True,
        text=True
    )
    
    # 4. 解析 JSON 诊断
    diagnostics = parse_ndjson(result.stdout)
    
    # 5. 返回结果
    return BuildResult(
        success=(result.returncode == 0),
        sasm_path=project_path / "build" / "output.sasm",
        diagnostics=diagnostics,
        exit_code=result.returncode
    )
```

### 5.3 协议测试门禁

| 用例 | 输入 | 断言 |
|------|------|------|
| 合法工程 | `project.yaml` + `MAIN.st`（合法） | exit 0 + `.sasm` 生成 + 诊断空 |
| 语法错误 | `MAIN.st` 含 `VAR x : INT;`（缺 `END_VAR`） | exit 22 + 诊断含 `KIND=type` + `loc=MAIN.x` |
| 重名拒绝 | `MAIN.st` + `pid.st` 都声明 `PROGRAM main` | exit 23 + 诊断含 `KIND=declaration` |
| IOMAP 未绑定 | `iomap/ai.toml` 引用未声明变量 | exit 24 + 诊断含 `KIND=declaration` |

---

## 6. 产出物 5 — CLI（veride）

### 6.1 命令集（首期）

```bash
veride create <name> [--path <dir>]      # 创建工程
veride build <project-dir>               # 编译工程 → build/output.sasm
veride sim <project-dir> [--cycles N]    # 仿真 → stdout JSONL
veride info <project-dir>                # 显示工程元数据
```

### 6.2 实现

```python
# veri-ide/cli/veride.py
import click
from veri_ide.backend.project import create_project, open_project
from veri_ide.backend.build import build_project

@click.group()
def cli(): ...

@cli.command()
@click.argument("name")
@click.option("--path", default=".")
def create(name, path):
    meta = create_project(name, Path(path))
    click.echo(f"Created project {meta.name} at {meta.path}")

@cli.command()
@click.argument("project_dir")
def build(project_dir):
    result = build_project(Path(project_dir))
    if result.success:
        click.echo(f"Build success: {result.sasm_path}")
    else:
        for diag in result.diagnostics:
            click.echo(f"{diag.severity}: {diag.message} at {diag.loc}")
        sys.exit(result.exit_code)
```

### 6.3 协议测试门禁

| 用例 | 命令 | 断言 |
|------|------|------|
| 创建工程 | `veride create myproj --path /tmp` | `/tmp/myproj/project.yaml` 存在 + Git 初始化 |
| 编译合法 | `veride build /tmp/myproj` | exit 0 + `build/output.sasm` 生成 |
| 编译非法 | `veride build /tmp/bad-proj` | exit 22 + stderr 含诊断 |

---

## 7. 协议测试门禁（黑盒）

### 7.1 测试框架

| 组件 | 选型 | 理由 |
|------|------|------|
| 框架 | `pytest` | Python 生态；与 project-svc/build-svc 同语言 |
| 断言 | `subprocess.run` + JSON 解析 | 黑盒调 CLI，不 import 内部 |

### 7.2 测试目录

```
veri-ide/tests/
├── conftest.py                    pytest fixtures（临时工程目录）
├── test_project_svc.py            project-svc 协议测试
├── test_build_svc.py              build-svc 协议测试
├── test_cli.py                    veride CLI 协议测试
└── fixtures/                      测试工程样本
    ├── valid-project/
    ├── syntax-error-project/
    └── duplicate-name-project/
```

### 7.3 首期用例清单（10+）

| # | 用例 | 断言 |
|---|------|------|
| 1 | 创建工程 → `project.yaml` 生成 | 文件存在 + schema 合法 |
| 2 | 编译合法工程 → `.sasm` 生成 | exit 0 + 文件存在 + CRC 合法 |
| 3 | 编译语法错误 → 诊断输出 | exit 22 + JSON 含 `KIND=type` |
| 4 | 编译重名 → 诊断输出 | exit 23 + JSON 含 `KIND=declaration` |
| 5 | 编译 IOMAP 未绑定 → 诊断输出 | exit 24 + JSON 含 `KIND=declaration` |
| 6 | 仿真合法工程 → JSONL 帧 | stdout 含 `cycle` 帧 + `done` 帧 |
| 7 | 仿真非法 watch 名 → 拒绝 | exit 22 + stderr 含 "symbol not found" |
| 8 | Git 提交 → 哈希返回 | `commit_project` 返回 40 字符 hex |
| 9 | Git diff → 差异返回 | `diff_project` 返回 unified diff |
| 10 | 工程 schema 非法 → 拒绝 | exit 21 + stderr 含 schema 校验错误 |

---

## 8. 实现顺序（4 周）

| 周 | 交付 | 验收 |
|----|------|------|
| W1 | 文本化工程 schema + JSON Schema + PRE 合并（首期只拼接） | `pytest test_schema.py` 全绿 |
| W2 | project-svc（CRUD + Git）+ build-svc（调 `veristc`） | `pytest test_project_svc.py test_build_svc.py` 全绿 |
| W3 | ST 编辑器（Monaco + 语法高亮）+ LSP（诊断 + 悬停） | 浏览器打开编辑器 → 输入非法 ST → 红线 + 悬停显示类型 |
| W4 | CLI（veride）+ 协议测试门禁（10+ 用例） | `pytest` 全绿 + `veride build` 端到端跑通 |

---

## 9. 验收总目标

**无 GUI 全链路**：
```bash
veride create myproj --path /tmp
cd /tmp/myproj
# 编辑 logic/MAIN.st（手写）
veride build .
# 输出：Build success: /tmp/myproj/build/output.sasm
veride sim . --cycles 12
# 输出：12 行 JSONL 帧
```

**协议测试门禁**：`pytest veri-ide/tests/` 全绿（10+ 用例）。

**证明锥零影响**：`make coq` 保持绿色，无新增 `Admitted`。

---

## 10. 依赖与风险

| 风险 | 影响 | 缓解 |
|------|------|------|
| Monaco Editor 集成复杂 | W3 延期 | 首期只做只读 ST 视图（不嵌入编辑器），LSP 用独立进程 |
| LSP 诊断延迟高 | 用户体验差 | 首期用 debounce 500ms；后续推增量编译 |
| PRE 合并语义不清 | 多文件冲突 | 首期只拼接，不做命名空间 mangle；冲突由编译器拒绝 |
| Git 集成 bug | 工程损坏 | 首期只做 `commit` / `diff`，不做 `merge` / `rebase` |

---

## 11. 范围外（G1 不做）

- 图形组态（`*.FC.json` / `*.SFC.json`）→ G2
- 图→ST 生成器 → G2
- 库注册服务（registry-svc）→ G5
- 多租户/进程池 → G3
- LSP 补全 → G2
- 下装向导（deploy-svc）→ G4
- 仿真波形视图 → G3
