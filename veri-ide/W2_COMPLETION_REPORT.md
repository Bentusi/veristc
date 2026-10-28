# G1 W2 完成报告

**日期**：2026-10-28  
**耗时**：约 1.5 小时  
**验收状态**：✅ 全绿（35 项协议测试 + 11 项 G0 回归测试）

## 交付物清单

### 1. project-svc（工程服务）

**文件**：`src/veri_ide/backend/project/service.py`

**API**：
```python
create_project(name, target_path, safety_level, svm_version) -> ProjectMeta
open_project(project_path) -> ProjectMeta
list_projects(base_path) -> list[ProjectMeta]
commit_project(project_path, message) -> str  # commit hash
diff_project(project_path, rev1, rev2) -> str  # unified diff
delete_project(project_path) -> None
```

**功能**：
- 创建工程：生成目录结构（logic/ iomap/ build/）+ project.yaml + Git 初始化
- 打开工程：读取并校验 project.yaml，返回 ProjectMeta
- 列出工程：扫描目录下所有有效工程
- Git 集成：提交变更、获取 diff
- 删除工程：递归删除目录

**测试用例**：15 项（test_project_service.py）

### 2. build-svc（构建服务）

**文件**：`src/veri_ide/backend/build/service.py`

**API**：
```python
build_project(project_path, veristc_path) -> BuildResult
parse_ndjson_diagnostics(ndjson_output) -> list[Diagnostic]
find_veristc_binary() -> Path
```

**功能**：
- 校验工程 schema
- PRE 合并逻辑文件
- 调用 veristc 编译器（-c --json）
- 解析 NDJSON 诊断输出
- 返回 BuildResult（成功/失败 + 产物路径 + 诊断列表）

**退出码映射**：
- 0: 编译成功
- 21: Schema 校验失败
- 22: 逻辑文件缺失
- 126: 编译器执行异常
- 127: 编译器二进制未找到

**测试用例**：10 项（test_build_service.py）

### 3. CLI（veride 命令行）

**文件**：`src/veri_ide/cli.py`

**命令**：
```bash
veride create <name> [--path <dir>] [--safety-level SIL1|SIL2|SIL3]
veride info <project_path>
veride ls [base_path]
veride build <project_path> [--veristc <path>]
veride commit <project_path> <message>
```

**功能**：
- create: 创建新工程
- info: 显示工程元数据
- ls: 列出目录下的工程
- build: 编译工程到 .sasm
- commit: 提交 Git 变更

**依赖**：click >= 8.0

### 4. 端到端集成测试

**验收场景**：
```bash
veride create myproj
cd myproj
# 编辑 logic/main.st 和 project.yaml
veride info .
veride build .
# 输出：build/output.sasm (298 bytes, magic: SASM)
```

**验证点**：
- ✓ 工程创建成功
- ✓ Schema 校验通过
- ✓ PRE 合并生成 build/merged.st
- ✓ veristc 编译生成 build/output.sasm
- ✓ .sasm 文件 magic number 正确 (0x53 0x41 0x53 0x4d = "SASM")

## 测试覆盖

| 模块 | 测试文件 | 用例数 | 状态 |
|------|---------|--------|------|
| Schema 校验 | test_schema.py | 5 | ✅ 全绿 |
| PRE 合并 | test_pre_merge.py | 5 | ✅ 全绿 |
| 工程服务 | test_project_service.py | 15 | ✅ 全绿 |
| 构建服务 | test_build_service.py | 10 | ✅ 全绿 |
| **总计** | | **35** | **✅ 全绿** |

## 依赖清单

新增依赖（已加入 pyproject.toml）：
- `gitpython>=3.1` — Git 仓库操作
- `click>=8.0` — CLI 框架

完整依赖列表：
```
pyyaml>=6.0
jsonschema>=4.17
gitpython>=3.1
click>=8.0
```

## 目录结构

```
veri-ide/
├── src/veri_ide/
│   ├── __init__.py
│   ├── cli.py                          # W2 新增：CLI 入口
│   ├── schema/
│   │   ├── project.schema.json
│   │   ├── iomap.schema.json
│   │   └── lib.lock.schema.json
│   └── backend/
│       ├── project/
│       │   ├── __init__.py
│       │   ├── schema.py               # W1: Schema 校验
│       │   └── service.py              # W2 新增：工程服务
│       ├── pre/
│       │   ├── __init__.py
│       │   └── merge.py                # W1: PRE 合并
│       └── build/
│           ├── __init__.py
│           └── service.py              # W2 新增：构建服务
└── tests/
    ├── conftest.py
    ├── test_schema.py                  # W1
    ├── test_pre_merge.py               # W1
    ├── test_project_service.py         # W2 新增
    └── test_build_service.py           # W2 新增
```

## 验收结果

### 协议测试门禁
```
$ pytest tests/ -v
============================== 35 passed in 0.61s ==============================
```

### G0 回归测试
```
$ ./integration/run_tests.sh
PASS: VeriSTC Full Test Suite (11 check(s) passed)
```

### 端到端演示
```bash
$ veride create myproj
Created project 'myproj' at myproj
  Safety level: SIL2
  SVM version: 1.0.0

$ cd myproj && veride build .
Building project at ....
✓ Build successful
  Output: build/output.sasm
  Merged ST: build/merged.st

$ file build/output.sasm
build/output.sasm: SAS
```

## 下一步（W3）

按 [plan/phase6-g1-technical-plan.md](../plan/phase6-g1-technical-plan.md) §4：

**W3 交付**：ST 编辑器（Monaco + 语法高亮）+ LSP（诊断 + 悬停）

**验收标准**：
- 浏览器打开编辑器 → 输入 ST 代码 → 语法高亮正确
- 输入非法 ST → 编辑器红线标记
- 鼠标悬停变量 → 显示类型和地址（从段 7 符号表读取）

**技术选型**（已定）：
- 编辑器：Monaco Editor（VS Code 同源）
- 语法高亮：TextMate grammar（手写 ST 关键字/注释/字符串）
- LSP 框架：pygls（Python LSP 库）
- 通信：stdio（首期本地，后续推 WebSocket）

**前置依赖**：
- 需要 build-svc 提供诊断信息（W2 已完成）
- 需要 veristc --json 输出（G0 W1 已完成）
- 需要段 7 符号表解析（G0 W2 已完成）

## 已知限制

1. **LSP 首期不做补全**：补全需要类型推断和符号表索引，复杂度高，推 G2
2. **编辑器首期只读**：不支持从编辑器直接保存文件（需 project-svc 配合）
3. **无增量编译**：每次诊断都全量重编（推 G3）
4. **单文件诊断**：不支持多文件联合诊断（PRE 合并后的整体诊断）

## 安装与使用

首次使用需安装依赖：
```bash
cd veri-ide
python3 -m venv .venv
source .venv/bin/activate
pip install -e .
```

运行测试：
```bash
pytest tests/ -v
```

使用 CLI：
```bash
veride --help
veride create myproj
cd myproj
veride build .
```
