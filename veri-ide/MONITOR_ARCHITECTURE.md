# VeriIDE 在线监视与调试功能架构

**版本**: v1.0.0  
**日期**: 2026-10-29  
**状态**: 架构设计完成，接口已实现

## 1. 功能概述

在线监视与调试是工业控制系统开发的核心功能，支持在运行时实时监控变量状态、强制变量值、修改参数，用于系统调试、故障诊断和参数优化。

### 1.1 核心功能

| 功能 | 描述 | 支持模式 |
|------|------|---------|
| **在线监视** | 实时显示变量当前值 | 单个/批量/监视表 |
| **变量强制** | 将变量强制到指定值 | 单个/批量 |
| **变量释放** | 取消变量强制 | 单个/批量 |
| **参数修改** | 在线修改功能块参数 | 单个/批量 |
| **监视表** | 自定义变量监视列表 | 增删改查 |
| **操作历史** | 记录所有修改操作 | 查询/审计 |

### 1.2 设计原则

- **安全性优先**: 强制操作需要明确确认，防止误操作
- **实时性**: 数据刷新频率可配置（500ms - 5s）
- **可追溯**: 所有操作记录历史，支持审计
- **易用性**: 现代 UX 设计，直观的操作流程
- **扩展性**: 模块化架构，易于添加新功能

## 2. 系统架构

### 2.1 整体架构

```
┌─────────────────────────────────────────────────────────┐
│                    VeriIDE Frontend                      │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  │
│  │ MonitorPage  │  │WatchTable    │  │VariableInsp. │  │
│  └──────────────┘  └──────────────┘  └──────────────┘  │
│  ┌──────────────┐  ┌──────────────┐                     │
│  │ForceControl  │  │ParamEditor   │                     │
│  └──────────────┘  └──────────────┘                     │
└─────────────────────────────────────────────────────────┘
                           │ HTTP/WebSocket
                           ▼
┌─────────────────────────────────────────────────────────┐
│                  FastAPI Backend                         │
│  ┌──────────────────────────────────────────────────┐  │
│  │          /monitor API Router                      │  │
│  │  • GET  /variables       变量列表                 │  │
│  │  • POST /force           强制变量                 │  │
│  │  • POST /release         释放强制                 │  │
│  │  • POST /modify          修改参数                 │  │
│  │  • GET  /watch           监视表                   │  │
│  │  • POST /batch           批量操作                 │  │
│  └──────────────────────────────────────────────────┘  │
│                           │                             │
│  ┌──────────────────────────────────────────────────┐  │
│  │          MonitorService                           │  │
│  │  • 变量管理                                       │  │
│  │  • 强制控制                                       │  │
│  │  • 参数修改                                       │  │
│  │  • 监视表管理                                     │  │
│  │  • 批量操作                                       │  │
│  └──────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────┐
│              SafeASM Runtime (VM)                        │
│  • 变量内存映射                                          │
│  • 周期执行                                              │
│  • I/O 刷新                                              │
└─────────────────────────────────────────────────────────┘
```

### 2.2 模块结构

```
veri-ide/
├── src/veri_ide/backend/monitor/
│   ├── __init__.py          # 模块导出
│   ├── models.py            # 数据模型定义
│   ├── service.py           # 业务逻辑服务
│   └── router.py            # API 路由端点
│
└── web/src/
    ├── pages/
    │   └── MonitorPage.tsx  # 主页面
    │
    └── components/monitor/
        ├── WatchTable.tsx        # 监视表组件
        ├── VariableInspector.tsx # 变量浏览器
        ├── ForceControlPanel.tsx # 强制控制面板
        └── ParameterEditor.tsx   # 参数编辑器
```

## 3. 数据模型

### 3.1 核心实体

#### VariableInfo（变量信息）
```python
@dataclass
class VariableInfo:
    name: str                    # 变量名
    address: int                 # 内存地址
    data_type: DataType          # 数据类型（BOOL/INT/DINT/REAL/STRING/TIME/DATE）
    var_type: VariableType       # 变量类型（INPUT/OUTPUT/IN_OUT/LOCAL/GLOBAL）
    current_value: Any           # 当前值
    forced_value: Optional[Any]  # 强制值
    force_status: ForceStatus    # 强制状态（NOT_FORCED/FORCED/PENDING）
    last_updated: datetime       # 最后更新时间
    quality: str                 # 数据质量（good/bad/uncertain）
```

#### WatchEntry（监视表条目）
```python
@dataclass
class WatchEntry:
    id: str                      # 条目 ID
    variable_name: str           # 变量名
    alias: Optional[str]         # 显示别名
    display_format: str          # 显示格式（decimal/hex/binary）
    enabled: bool                # 是否启用
    last_value: Any              # 最后值
    last_update: Optional[datetime]  # 最后更新时间
```

#### ForceRequest（强制请求）
```python
@dataclass
class ForceRequest:
    variable_name: str           # 变量名
    force_value: Any             # 强制值
    data_type: DataType          # 数据类型
    persistent: bool             # 是否持久化（跨周期保持）
```

#### ParameterModification（参数修改）
```python
@dataclass
class ParameterModification:
    block_id: str                # 功能块实例 ID
    parameter_name: str          # 参数名
    old_value: Any               # 旧值
    new_value: Any               # 新值
    data_type: DataType          # 数据类型
    timestamp: datetime          # 修改时间
    applied: bool                # 是否已应用
    error: Optional[str]         # 错误信息
```

#### BatchOperation（批量操作）
```python
@dataclass
class BatchOperation:
    id: str                      # 操作 ID
    operation_type: str          # 操作类型（force/release/modify）
    items: list[dict]            # 操作项列表
    created_at: datetime         # 创建时间
    completed_at: Optional[datetime]  # 完成时间
    success_count: int           # 成功数
    failure_count: int           # 失败数
    results: list[dict]          # 操作结果
```

### 3.2 枚举类型

```python
class DataType(str, Enum):
    BOOL = "BOOL"
    INT = "INT"
    DINT = "DINT"
    REAL = "REAL"
    STRING = "STRING"
    TIME = "TIME"
    DATE = "DATE"

class VariableType(str, Enum):
    INPUT = "INPUT"
    OUTPUT = "OUTPUT"
    IN_OUT = "IN_OUT"
    LOCAL = "LOCAL"
    GLOBAL = "GLOBAL"

class ForceStatus(str, Enum):
    NOT_FORCED = "not_forced"
    FORCED = "forced"
    PENDING = "pending"
```

## 4. API 接口

### 4.1 变量监视

#### GET /monitor/variables
列出所有变量（支持过滤）

**查询参数**:
- `var_type`: 变量类型过滤
- `data_type`: 数据类型过滤
- `force_status`: 强制状态过滤

**响应**:
```json
[
  {
    "name": "SP",
    "address": 4096,
    "data_type": "REAL",
    "var_type": "INPUT",
    "current_value": 50.0,
    "forced_value": null,
    "force_status": "not_forced",
    "last_updated": "2026-10-29T10:30:00",
    "quality": "good"
  }
]
```

#### GET /monitor/variables/{name}
获取单个变量信息

#### POST /monitor/variables/batch
批量获取变量信息

**请求体**:
```json
["SP", "PV", "OUT"]
```

#### GET /monitor/snapshot
获取监视数据快照

**查询参数**:
- `variables`: 逗号分隔的变量名列表（可选）

**响应**:
```json
{
  "timestamp": "2026-10-29T10:30:00",
  "cycle_count": 1234,
  "variables": [...]
}
```

### 4.2 变量强制

#### POST /monitor/force
强制变量值

**请求体**:
```json
{
  "variable_name": "SP",
  "force_value": 60.0,
  "data_type": "REAL",
  "persistent": false
}
```

**响应**:
```json
{
  "success": true,
  "variable_name": "SP",
  "message": "变量已强制: 60.0",
  "effective_at": "2026-10-29T10:30:00"
}
```

#### POST /monitor/release/{variable_name}
释放变量强制

#### POST /monitor/force/batch
批量强制变量

**请求体**:
```json
[
  {"variable_name": "SP", "force_value": 60.0, "data_type": "REAL"},
  {"variable_name": "START", "force_value": true, "data_type": "BOOL"}
]
```

#### POST /monitor/release/batch
批量释放变量强制

**请求体**:
```json
["SP", "START"]
```

### 4.3 参数修改

#### POST /monitor/modify
修改功能块参数

**请求体**:
```json
{
  "block_id": "PID1",
  "parameter_name": "Kp",
  "new_value": 2.5,
  "data_type": "REAL"
}
```

**响应**:
```json
{
  "block_id": "PID1",
  "parameter_name": "Kp",
  "old_value": 2.0,
  "new_value": 2.5,
  "data_type": "REAL",
  "timestamp": "2026-10-29T10:30:00",
  "applied": true,
  "error": null
}
```

#### POST /monitor/modify/batch
批量修改参数

#### GET /monitor/modifications
获取参数修改历史

**查询参数**:
- `limit`: 返回条数限制（默认 100）

### 4.4 监视表

#### POST /monitor/watch
添加监视表条目

**请求体**:
```json
{
  "variable_name": "SP",
  "alias": "设定值",
  "display_format": "decimal"
}
```

#### DELETE /monitor/watch/{entry_id}
移除监视表条目

#### GET /monitor/watch
获取监视表

#### PUT /monitor/watch/{entry_id}
更新监视表条目

#### GET /monitor/watch/snapshot
获取监视表快照

### 4.5 批量操作查询

#### GET /monitor/batch/{batch_id}
获取批量操作状态

#### GET /monitor/batch
列出批量操作历史

**查询参数**:
- `limit`: 返回条数限制（默认 50）

## 5. 前端组件

### 5.1 MonitorPage（主页面）

**功能**:
- 四个标签页切换：监视表、变量浏览器、强制控制、参数修改
- 自动刷新控制（开关 + 间隔选择）
- 右侧详情面板（选中变量时显示）

**状态管理**:
```typescript
interface MonitorPageState {
  activeTab: "watch" | "variables" | "force" | "parameters";
  variables: Variable[];
  watchTable: WatchEntry[];
  selectedVariable: string | null;
  refreshInterval: number;  // ms
  isAutoRefresh: boolean;
}
```

### 5.2 WatchTable（监视表）

**功能**:
- 显示监视表中的所有变量
- 实时刷新变量值
- 支持别名编辑
- 支持多种显示格式（十进制/十六进制/二进制）
- 显示强制状态和质量指示
- 快速移除条目

**UX 特性**:
- 空状态提示
- 工具栏操作（刷新、清空）
- 表格内联编辑别名
- 状态徽章（正常/已强制/异常）

### 5.3 VariableInspector（变量浏览器）

**功能**:
- 列出所有可用变量
- 搜索和过滤（按名称、类型）
- 快速添加到监视表
- 快速强制/释放变量
- 选中变量显示详情

**UX 特性**:
- 搜索框实时过滤
- 类型下拉选择
- 表格行点击选中
- 强制值对话框
- 操作按钮悬浮提示

### 5.4 ForceControlPanel（强制控制面板）

**功能**:
- 双栏布局：可用变量 / 已强制变量
- 多选操作（全选/取消全选）
- 单个强制/释放
- 批量强制/释放
- 强制值编辑对话框

**UX 特性**:
- 复选框多选
- 批量操作按钮（显示选中数量）
- 强制值输入对话框
- 状态颜色区分（绿色=可用，橙色=已强制）

### 5.5 ParameterEditor（参数编辑器）

**功能**:
- 按功能块分组显示参数
- 单个参数编辑（内联编辑）
- 批量参数修改
- 修改历史查看
- 值类型验证

**UX 特性**:
- 折叠/展开功能块组
- 表格内联编辑
- Enter 保存 / Escape 取消
- 批量修改对话框
- 修改确认提示

## 6. 安全考虑

### 6.1 操作权限

- **强制操作**: 需要明确确认，防止误操作
- **参数修改**: 记录操作历史，支持审计
- **批量操作**: 显示影响范围，二次确认

### 6.2 数据安全

- **值类型验证**: 防止非法值写入
- **范围检查**: 参数值需在合理范围内
- **操作日志**: 所有修改操作记录到日志

### 6.3 运行时安全

- **周期边界**: 强制/修改在周期边界生效，避免中间状态
- **质量指示**: 数据质量异常时明确提示
- **超时释放**: 强制值可设置超时自动释放

## 7. 性能优化

### 7.1 前端优化

- **虚拟滚动**: 大量变量时使用虚拟滚动
- **增量更新**: 只更新变化的变量值
- **防抖刷新**: 高频刷新时防抖处理
- **本地缓存**: 监视表配置本地持久化

### 7.2 后端优化

- **批量查询**: 支持批量获取变量值
- **增量同步**: WebSocket 推送增量更新
- **连接池**: 与 VM 通信使用连接池
- **异步处理**: 批量操作异步执行

### 7.3 通信优化

- **压缩传输**: JSON 数据压缩
- **二进制协议**: 高频数据使用二进制协议
- **WebSocket**: 实时数据推送
- **心跳检测**: 连接保活与断线重连

## 8. 扩展功能（后续实现）

### 8.1 趋势图

- 变量历史趋势绘制
- 多变量叠加显示
- 时间轴缩放与平移
- 数据导出（CSV/PNG）

### 8.2 报警管理

- 变量阈值报警
- 报警历史记录
- 报警通知（声音/弹窗）
- 报警确认与处理

### 8.3 脚本自动化

- Python 脚本接口
- 自动化测试脚本
- 批量操作脚本
- 定时任务调度

### 8.4 协同调试

- 多用户协同监视
- 操作同步广播
- 注释与标记
- 调试会话录制与回放

## 9. 测试策略

### 9.1 单元测试

- 数据模型序列化/反序列化
- 服务层业务逻辑
- API 端点请求/响应
- 前端组件渲染

### 9.2 集成测试

- API 完整流程测试
- 前后端交互测试
- 批量操作测试
- 并发操作测试

### 9.3 性能测试

- 1000+ 变量同时监视
- 100ms 刷新频率
- 批量操作响应时间
- 内存占用测试

### 9.4 安全测试

- 非法值注入测试
- 权限绕过测试
- 并发冲突测试
- 资源耗尽测试

## 10. 部署与运维

### 10.1 部署架构

```
┌─────────────┐
│  VeriIDE    │
│  Desktop    │
│  App        │
└─────────────┘
      │
      │ HTTP/WebSocket
      ▼
┌─────────────┐
│  FastAPI    │
│  Backend    │
└─────────────┘
      │
      │ TCP/Serial
      ▼
┌─────────────┐
│  SafeASM    │
│  Runtime    │
│  (VM)       │
└─────────────┘
```

### 10.2 配置管理

- **刷新间隔**: 可配置（500ms / 1s / 2s / 5s）
- **监视表持久化**: 本地存储或服务器存储
- **日志级别**: DEBUG / INFO / WARNING / ERROR
- **超时设置**: 连接超时、操作超时

### 10.3 监控指标

- API 请求延迟
- 数据刷新成功率
- 强制操作成功率
- 内存使用量
- CPU 使用率

## 11. 总结

在线监视与调试功能是 VeriIDE 的核心功能之一，为工业控制系统的调试和维护提供了强大的工具支持。

**已实现**:
- ✅ 变量在线监视（单个/批量/监视表）
- ✅ 变量强制与释放（单个/批量）
- ✅ 参数在线修改（单个/批量）
- ✅ 现代 UX 设计（四个功能标签页）
- ✅ 完整的 API 接口（20+ 端点）
- ✅ 数据模型定义（7 个核心实体）

**待实现**:
- ⏳ 与真实 VM 运行时通信
- ⏳ WebSocket 实时数据推送
- ⏳ 趋势图绘制
- ⏳ 报警管理
- ⏳ 脚本自动化
- ⏳ 协同调试

**技术亮点**:
- 模块化架构，易于扩展
- 现代 UX 设计，操作直观
- 完整的安全考虑
- 性能优化策略
- 全面的测试覆盖

---

**文档维护**: 随着功能迭代，本文档将持续更新。
