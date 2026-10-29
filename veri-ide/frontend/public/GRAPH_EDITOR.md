# 功能图编辑器 (SCADE 风格)

基于 SVG 的图形化功能图编辑器，采用 ANSYS SCADE 界面布局，支持拖拽编辑、参数编辑、接口管理和实时 ST 代码预览。

## 界面布局

```
┌─────────────────────────────────────────────────────────────────────┐
│  顶部工具栏：添加块 | 加载示例 | 清空 | 导出/导入 JSON              │
├──────────┬─────────────────────────────────────────────────────────┤
│ 项目树   │  画布 (SVG)                  │  属性面板                 │
│          │                              │                           │
│ 📦 功能块│  [pid1] ──→ [limiter1]      │  基本信息                 │
│ 🔗 连线  │                              │  - ID                    │
│ 🔌 接口  │                              │  - 类型                  │
│          │                              │  - X/Y 坐标              │
│          │                              │                           │
│          │                              │  参数                     │
│          │                              │  - kp := 10              │
│          │                              │  - ki := 1               │
│          │                              │  [+ 添加参数]            │
│          │                              │                           │
│          │                              │  接口端口                 │
│          │                              │  - setpoint : DINT       │
│          │                              │  - measurement : DINT    │
│          │                              │  [+ 添加端口]            │
├──────────┴──────────────────────────────┴───────────────────────────┤
│  生成的 ST 代码                                                      │
│  PROGRAM PID_CONTROL                                                 │
│  VAR                                                                 │
│      pid1 : PID;                                                     │
│      limiter1 : LIMITER;                                             │
│  END_VAR                                                             │
│  pid1(kp := 10, ki := 1);                                           │
│  limiter1(IN := pid1.OUT, min := 0, max := 100);                    │
│  END_PROGRAM                                                         │
├─────────────────────────────────────────────────────────────────────┤
│  状态栏：加载示例：PID_CONTROL                                       │
└─────────────────────────────────────────────────────────────────────┘
```

## 功能特性

### 1. 块管理
- **添加块**: PID / LIMITER / RS / FBY
- **拖拽移动**: 鼠标拖拽改变块位置
- **选中高亮**: 红色边框显示选中状态
- **删除块**: 通过属性面板编辑

### 2. 连线管理
- **创建连线**: 从输出端口（橙色）拖到输入端口（绿色）
- **自动布局**: 贝塞尔曲线连接
- **箭头指示**: 显示数据流方向

### 3. 参数编辑
- **实时编辑**: 右侧属性面板直接修改
- **参数类型**: 数值/字符串/布尔
- **动态添加/删除**: 支持运行时增删参数

### 4. 接口管理
- **输入端口**: VAR_INPUT 声明
- **输出端口**: VAR_OUTPUT 声明
- **端口类型**: BOOL / DINT / REAL / STRING
- **动态管理**: 添加/删除/重命名端口

### 5. 代码生成
- **实时预览**: 底部显示生成的 ST 代码
- **拓扑排序**: 按依赖关系排序块调用
- **参数内联**: 参数直接嵌入调用语句
- **一键复制**: 复制 ST 代码到剪贴板

### 6. 导入/导出
- **导出 JSON**: 保存为 `.fc.json` 文件
- **导入 JSON**: 加载已有功能图
- **格式兼容**: 与后端 FC JSON Schema 完全兼容

## 使用方法

```bash
cd veri-ide/frontend/public
python3 -m http.server 8080
```

浏览器打开 http://localhost:8080/graph-editor.html

## 数据格式

编辑器使用标准 FC JSON 格式：

```json
{
  "version": "1.0",
  "type": "FC",
  "name": "PID_CONTROL",
  "interface": {
    "input": [
      {"name": "setpoint", "type": "DINT"},
      {"name": "measurement", "type": "DINT"}
    ],
    "output": [
      {"name": "control_output", "type": "DINT"}
    ]
  },
  "blocks": [
    {
      "id": "pid1",
      "type": "PID",
      "position": {"x": 200, "y": 100},
      "parameters": {"kp": 10, "ki": 1}
    },
    {
      "id": "limiter1",
      "type": "LIMITER",
      "position": {"x": 400, "y": 100},
      "parameters": {"min": 0, "max": 100}
    }
  ],
  "connections": [
    {
      "from": {"block": "pid1", "port": "OUT"},
      "to": {"block": "limiter1", "port": "IN"}
    }
  ]
}
```

## 技术实现

- **SVG 渲染**: 矢量图形，缩放不失真
- **拖拽交互**: mousedown/mousemove/mouseup 事件处理
- **属性绑定**: 实时双向数据绑定
- **拓扑排序**: Kahn 算法检测环并排序
- **代码生成**: 图结构 → ST 代码转换

## 与后端集成

```
前端编辑器 (graph-editor.html)
  ↓ 导出 FC JSON
后端校验 (validator.py)
  ↓ validate_fc_json()
  ↓ check_no_cycles()
  ↓ topological_sort()
后端生成 (graph_to_st.py)
  ↓ generate_st_from_fc()
merged.st
  ↓ 编译 (veristc -c)
output.sasm
```

## 已知限制

1. **块类型有限**: 只支持 PID/LIMITER/RS/FBY
2. **单端口**: 每个块只有 1 个输入和 1 个输出端口
3. **无撤销/重做**: 刷新页面丢失编辑
4. **无自动布局**: 需手动调整位置
5. **无块库管理**: 自定义块需手动修改 JSON

## 后续扩展

### 短期
- 多端口支持（IN1/IN2/OUT1/OUT2）
- 块库扩展（自定义块类型）
- 撤销/重做功能
- 自动布局算法

### 中期
- 顺控图（SFC）支持
- 梯形图（LD）支持
- 协作编辑
- 版本管理集成

### 长期
- 与 VeriIDE 后端深度集成
- 在线编译 + 诊断显示
- 仿真波形查看
- 下装向导
