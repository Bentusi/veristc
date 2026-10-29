# Phase 6 G5 技术方案：库与扩展

## 目标

交付算法块库管理系统，支持：
- 块 manifest 协议（端口/类型/默认参数/图标/SIL 属性/semver）
- 库注册服务（内容寻址 + 版本管理 + lock 文件）
- 块准入门禁（WCET/栈深/纯性/循环上界）
- 前端库管理 UI（浏览/搜索/安装/卸载）

## 决策

### D1: 库存储采用内容寻址
- **方案**：块实现按 SHA-256 哈希存储，manifest 按 `name@version` 索引
- **理由**：去重、可验证、与 Git 对象模型对齐
- **后果**：存储路径为 `registry/blocks/<sha256[:2]>/<sha256[2:]>`

### D2: 准入门禁复用编译器分析
- **方案**：调用 `veristc -a` 获取 WCET/栈深/循环上界，与 manifest 声明对比
- **理由**：不重复实现分析逻辑，与编译器证明边界一致
- **后果**：门禁结果依赖编译器版本，需在 lock 文件记录编译器版本

### D3: 首期只做本地库
- **方案**：库存储在工程目录 `.veride/registry/`，不实现远程仓库
- **理由**：降低首期复杂度，远程同步推到 G6
- **后果**：库共享需手动复制 `.veride/registry/` 目录

## 架构

```
veri-ide/backend/registry/
── __init__.py
├── service.py          # RegistryService: 注册/查询/安装/卸载
├── manifest.py         # BlockManifest: 解析/校验/序列化
── admission.py        # AdmissionGate: 准入门禁检查
└── lock.py             # LockFile: lib.lock.yaml 读写

veri-ide/schema/
└── block.schema.json   # 块 manifest JSON Schema

veri-ide/frontend/public/
└── library-manager.html # 库管理 UI
```

## 实现计划

### W1: 后端核心（3 天）
- [ ] BlockManifest 数据模型 + JSON Schema 校验
- [ ] RegistryService: 注册/查询/列出块
- [ ] 内容寻址存储（SHA-256）
- [ ] LockFile: lib.lock.yaml 读写
- [ ] 单元测试（15 项）

### W2: 准入门禁（2 天）
- [ ] AdmissionGate: 调用 veristc -a 获取分析结果
- [ ] 门禁规则：WCET/栈深/纯性/循环上界
- [ ] 门禁报告生成
- [ ] 单元测试（10 项）

### W3: 前端 UI（3 天）
- [ ] library-manager.html: 三栏布局（库列表/块详情/操作）
- [ ] 块浏览/搜索/过滤
- [ ] 安装/卸载操作
- [ ] 门禁结果展示
- [ ] 浏览器集成测试

### W4: API 集成 + 文档（2 天）
- [ ] FastAPI 端点：GET/POST/DELETE /registry/blocks
- [ ] 前端 API 集成
- [ ] 用户文档
- [ ] 完成报告

## 验收标准

1. 能注册块到本地库（manifest + 实现）
2. 能查询/列出已注册块
3. 能生成/更新 lib.lock.yaml
4. 准入门禁拒绝超标块（WCET > 阈值/栈深 > 256/非纯函数）
5. 前端能浏览/搜索/安装/卸载块
6. 25 项测试全部通过

## 依赖

- G1: project-svc（工程目录结构）
- G2: gen/（块 manifest 协议）
- G4: deploy-svc（无直接依赖，但共享密钥管理）

## 范围外

- 远程仓库同步（推 G6）
- 库版本升级/降级（推 G6）
- 库依赖解析（推 G6）
- MCP Server（推 G6）
