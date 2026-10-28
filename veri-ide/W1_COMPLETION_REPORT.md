# G1 W1 完成报告

**日期**：2026-10-28  
**耗时**：约 2 小时  
**验收状态**：✅ 全绿（11 项协议测试 + 11 项回归测试）

## 交付物清单

### 1. JSON Schema 协议（3 个文件）

| Schema | 路径 | 用途 |
|--------|------|------|
| `project.schema.json` | `src/veri_ide/schema/` | 校验 `project.yaml`（工程元数据） |
| `iomap.schema.json` | `src/veri_ide/schema/` | 校验 `iomap/*.toml`（I/O 通道组态） |
| `lib.lock.schema.json` | `src/veri_ide/schema/` | 校验 `lib.lock.yaml`（库依赖锁定） |

**关键设计决策**：
- `project.yaml` 必须包含 `name` / `safety_level` / `svm_version` / `logic_files`
- `logic_files` 是有序列表，决定 PRE 合并顺序
- `safety_level` 只接受 `SIL1` / `SIL2` / `SIL3`（IEC 61508）
- `iomap` 使用 TOML 格式，支持 `channel` / `scale` / `bias` / `safety_limit`
- `lib.lock` 使用 SHA-256 内容寻址（64 位十六进制）

### 2. Schema 校验模块

**文件**：`src/veri_ide/backend/project/schema.py`

**API**：
```python
validate_project_yaml(project_path: Path) -> dict
validate_iomap_toml(iomap_path: Path) -> dict
validate_lib_lock_yaml(lock_path: Path) -> list
validate_project(project_path: Path) -> dict  # 一次性校验全部
```

**实现要点**：
- 使用 `jsonschema.Draft7Validator` 进行校验
- YAML 用 `pyyaml` 解析，TOML 用 Python 3.11+ 标准库 `tomllib` 解析
- 校验失败抛出 `jsonschema.ValidationError`，文件缺失抛出 `FileNotFoundError`

### 3. PRE 合并内核

**文件**：`src/veri_ide/backend/pre/merge.py`

**API**：
```python
pre_merge(project_path: Path, logic_files: list[str]) -> str
write_merged_file(project_path: Path, logic_files: list[str]) -> Path
```

**实现要点**：
- 首期只做文件拼接（PRE-1），不做命名空间 mangle（PRE-4 推 G5）
- 按 `logic_files` 列表顺序拼接，每个文件前加 `(* Source: filename *)` 注释
- 输出到 `build/merged.st`（不入库，`.gitignore` 已配置）

### 4. 协议测试门禁（11 项用例）

**文件**：
- `tests/test_schema.py`（6 项）
- `tests/test_pre_merge.py`（5 项）

**覆盖场景**：
| 类别 | 用例数 | 关键断言 |
|------|--------|---------|
| Schema 合法 | 3 | 正常工程通过校验 |
| Schema 非法 | 3 | `safety_level: SIL4` 拒绝 / `logic_files: []` 拒绝 / 文件缺失拒绝 |
| PRE 合并 | 5 | 拼接顺序正确 / 源注释存在 / 缺失文件报错 / `build/` 目录自动创建 |

**运行方式**：
```bash
cd veri-ide
source .venv/bin/activate
pytest tests/ -v
```

### 5. 测试样本工程

**路径**：`tests/fixtures/valid-project/`

**结构**：
```
valid-project/
├── project.yaml          # name: test_project, safety_level: SIL2
├── logic/
│   ├── MAIN.st           # PROGRAM main（计数器 + 状态机）
│   └── pid.st            # FUNCTION_BLOCK pid（比例控制）
└── iomap/
    └── ai.toml           # 2 个模拟输入通道（温度/压力）
```

**用途**：作为协议测试的输入样本，后续 W2（project-svc）会复用。

## 技术选型

| 组件 | 选型 | 版本 | 理由 |
|------|------|------|------|
| Python | 3.14 | 系统自带 | `tomllib` 标准库（3.11+） |
| YAML 解析 | pyyaml | 6.0.3 | 成熟稳定 |
| Schema 校验 | jsonschema | 4.26.0 | JSON Schema Draft 7 完整支持 |
| 测试框架 | pytest | 9.2.0 | Python 生态标准 |
| 包管理 | setuptools | 61.0+ | PEP 621 标准 |
| 虚拟环境 | venv | 标准库 | 隔离依赖，不污染系统 Python |

## 目录结构

```
veri-ide/
├── .venv/                          # Python 虚拟环境（不入库）
├── .gitignore                      # 排除 build/ .venv/ __pycache__/
├── pyproject.toml                  # 包配置 + pytest 配置
├── README.md                       # 组件说明（已更新 W1 进度）
├── src/
│   └── veri_ide/
│       ├── __init__.py             # 包入口（version 0.1.0）
│       ├── schema/
│       │   ├── project.schema.json
│       │   ├── iomap.schema.json
│       │   └── lib.lock.schema.json
│       └── backend/
│           ├── __init__.py
│           ├── project/
│           │   ├── __init__.py
│           │   └── schema.py       # Schema 校验 API
│           └── pre/
│               ├── __init__.py
│               └── merge.py        # PRE 合并 API
└── tests/
    ├── conftest.py                 # pytest fixtures
    ├── test_schema.py              # 6 项 schema 测试
    ├── test_pre_merge.py           # 5 项 PRE 测试
    └── fixtures/
        ├── valid-project/          # 合法样本工程
        └── invalid-project/        # 非法样本（safety_level: SIL4）
```

## 验收结果

### 协议测试门禁
```
$ pytest tests/ -v
============================== 11 passed in 0.10s ==============================
```

### 回归测试（G0 全量）
```
$ ./integration/run_tests.sh
PASS: VeriSTC Full Test Suite (11 check(s) passed)
```

**结论**：W1 交付物未破坏 G0 已有功能，证明锥零影响（`make coq` 未触碰）。

## 下一步（W2）

按 [plan/phase6-g1-technical-plan.md](../plan/phase6-g1-technical-plan.md) §3：

**W2 交付**：project-svc（工程 CRUD + Git 集成）+ build-svc（调 `veristc -c` 编译）

**验收标准**：
- `pytest test_project_svc.py` 全绿（创建/打开/提交/差异）
- `pytest test_build_svc.py` 全绿（合法工程编译成功 + 非法工程诊断输出）
- 端到端：`veride build tests/fixtures/valid-project` → 生成 `build/output.sasm`

**技术选型**（已定）：
- 框架：FastAPI（异步 + OpenAPI 文档）
- 存储：本地文件系统 + Git（无数据库）
- 通信：首期 CLI 直调，不暴露 HTTP

## 已知限制

1. **PRE 合并只做拼接**：不做命名空间 mangle（PRE-4），多文件同名 POU 冲突由编译器 `duplicate_declaration_msg` 拒绝
2. **Schema 校验不检查语义**：只校验结构合法性，不检查 `logic_files` 列表中的文件是否真实存在（PRE 合并阶段才检查）
3. **无多租户隔离**：首期单用户本地，工作目录不隔离（推 G3）
4. **无增量编译**：每次 `build` 全量重编（推 G3）

## 依赖安装

首次使用需安装 Python 依赖：
```bash
cd veri-ide
python3 -m venv .venv
source .venv/bin/activate
pip install -e .
```

后续运行测试：
```bash
source .venv/bin/activate
pytest tests/ -v
```
