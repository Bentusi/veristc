# G5 W1 完成报告：库注册服务核心

## 完成时间
2026-10-29

## 交付内容

### 1. 块 Manifest 协议 (`schema/block.schema.json`)

**字段定义：**
- `name`: 块名称（大写字母开头，32 字符内）
- `version`: 语义化版本号 (semver)
- `type`: FUNCTION 或 FUNCTION_BLOCK
- `interface`: 端口定义（input/output/in_out）
- `implementation`: 实现源哈希 + 路径
- `analysis`: 静态分析结果（WCET/栈深/纯性/循环上界）
- `sil_level`: 安全完整性等级 (SIL1-SIL4)
- `tags`: 标签（用于搜索/分类）

### 2. Manifest 模型 (`src/veri_ide/backend/registry/manifest.py`)

**数据类：**
- `BlockManifest`: 块 manifest 主类
- `PortDef`: 端口定义（name/type/default/description）
- `InterfaceDef`: 接口定义（input/output/in_out）
- `ImplementationDef`: 实现定义（source_hash/source_path/language）
- `AnalysisResult`: 分析结果（wcet_cycles/stack_depth/is_pure/loop_bound）

**功能：**
- `to_dict()` / `from_dict()`: 字典序列化
- `to_json()` / `from_json()`: JSON 序列化
- `validate()`: JSON Schema 校验
- `compute_source_hash()`: SHA-256 源文件哈希

### 3. 库注册服务 (`src/veri_ide/backend/registry/service.py`)

**核心类：**
- `RegistryService`: 注册服务主类
- `RegistryBlock`: 已注册块（manifest + storage_path）
- `RegistryError`: 注册异常

**功能：**
- `register_block()`: 注册块（内容寻址存储 + manifest 保存 + lock 更新）
- `get_block()`: 按名称版本获取块
- `list_blocks()`: 列出所有块（支持名称过滤）
- `unregister_block()`: 卸载块（清理 manifest + 内容 + lock）
- `search_blocks()`: 搜索块（名称/描述/标签匹配）

**存储结构：**
```
registry/
├── blocks/
│   └── <sha256[:2]>/
│       └── <sha256[2:]>  # 内容寻址存储
└── manifests/
    └── <name>@<version>.json  # manifest 文件
```

### 4. Lock 文件管理 (`src/veri_ide/backend/registry/lock.py`)

**数据类：**
- `LockFile`: lock 文件主类
- `LockEntry`: lock 条目（name/version/sha256/compiler_version）

**功能：**
- `add_or_update()`: 添加或更新条目
- `remove()`: 按名称删除条目
- `get()`: 按名称获取条目
- `save()` / `load()`: YAML 文件读写

**文件格式 (lib.lock.yaml)：**
```yaml
version: "1.0"
blocks:
  - name: PID
    version: 1.0.0
    sha256: abc123...
    compiler_version: 1.5.0
```

### 5. 准入门禁 (`src/veri_ide/backend/registry/admission.py`)

**核心类：**
- `AdmissionGate`: 准入门禁检查器
- `AdmissionResult`: 检查结果（passed/checks/errors/warnings）

**门禁规则：**
- WCET 上限（默认 1000 周期）
- 栈深上限（默认 256）
- 循环上界（默认 100）
- 纯性要求（可选）

**功能：**
- `check()`: 基于 manifest.analysis 检查
- `check_from_veristc()`: 调用 veristc -a 获取分析结果后检查

### 6. 测试 (`tests/test_registry.py`)

**测试覆盖（31 项）：**
- TestBlockManifest: 7 项（创建/序列化/校验/哈希）
- TestLockFile: 8 项（CRUD/保存加载）
- TestRegistryService: 10 项（注册/查询/列表/搜索/卸载/lock 集成）
- TestAdmissionGate: 6 项（通过/失败/纯性要求）

## 技术决策

### D1: 内容寻址存储
- **方案**：块实现按 SHA-256 哈希存储，路径为 `blocks/<sha256[:2]>/<sha256[2:]>`
- **理由**：去重、可验证、与 Git 对象模型对齐
- **后果**：相同内容的块只存储一份

### D2: Manifest 与内容分离
- **方案**：manifest 按 `name@version.json` 存储，内容按哈希存储
- **理由**：支持多版本共存，内容可被多个 manifest 引用
- **后果**：卸载时需检查内容是否被其他 manifest 引用

### D3: 准入门禁复用编译器分析
- **方案**：调用 `veristc -a` 获取 WCET/栈深/循环上界
- **理由**：不重复实现分析逻辑，与编译器证明边界一致
- **后果**：门禁结果依赖编译器版本

## 测试命令

```bash
cd veri-ide
source .venv/bin/activate
python3 -m pytest tests/test_registry.py -v
```

## 下一步

- G5 W2: 准入门禁集成 veristc 分析
- G5 W3: 前端库管理 UI
- G5 W4: API 集成 + 文档
