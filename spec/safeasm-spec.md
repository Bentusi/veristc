# SafeASM — 安全汇编字节码规范

> **文档版本**：v1.1  
> **状态**：正式发布  
> **生效日期**：2026-06-30  
> **对应 Coq 文件**：`safeasm.v`（形式化镜像）  
> **对应实现文件**：`vm/safeasm_interp.c` `vm/loader.c`  
> **编码方式**：固定宽度编码

---

## 0. 文档控制

### 0.1 版本历史

| 版本 | 日期 | 变更说明 | 作者 |
|------|------|---------|------|
| v0.1 | 草案 | 初始草案 | JIANG Wei |
| v1.0 | 2026-06-29 | 正式发布。补全完整指令集（覆盖全部 66 条指令）；完善各段详细编码格式；新增验证规则章节；完善运行时小步语义；新增编码/解码示例 | JIANG Wei |
| **v1.1** | **2026-06-30** | **新增影子质量内存段 (SEG_QUALITY)；IOMap 扩展 quality_offset 字段；新增质量传播指令模板；新增 LOAD8_U / STORE8 指令** | JIANG Wei |

### 0.2 术语与约定

```
uint8    : 1 字节，无符号
uint16   : 2 字节，小端序
uint32   : 4 字节，小端序
sint32   : 4 字节，小端序，二进制补码
uint64   : 8 字节，小端序
float32  : 4 字节，IEEE 754 单精度
float64  : 8 字节，IEEE 754 双精度
```

---

## 1. 概述

SafeASM 是一种自定义安全汇编字节码格式，作为 **VeriSTC 编译器** 的输出目标和 **C 语言 SafeASM 虚拟机** 的输入。它参考 WASM 核心指令集做安全化剪裁和扩展，采用**固定宽度编码**以确保 WCET（最差执行时间）的确定性和形式化验证的可追溯性。

### 1.1 设计原则

1. **固定宽度编码** — 所有立即数/索引固定 4 字节（i32）或 8 字节（i64/f64），无变长编码（与 WASM LEB128 的关键区别）
2. **确定性执行** — 禁止 `memory.grow`、`call_indirect` 等非确定性指令；所有指令的执行时间在编译期可预测
3. **安全元数据内置** — 二进制中包含 Safety/IOMap/WCET 等安全扩展段，虚拟机可在加载时静态验证
4. **可验证格式** — 每个 `.sasm` 文件的 CRC32 校验和覆盖除 Magic 外的所有字节

---

## 2. 二进制格式总览

```
┌──────────────────────────────────────────────────────┐
│  SafeASM Binary Format (.sasm)                        │
├──────────────────────────────────────────────────────┤
│  [Magic]      "SASM"       固定 4 字节 (0x4D534153, 小端序存储 "SASM")  │
│  [Version]    uint8        当前版本 = 0x01           │
│  [Flags]      uint8        安全等级 + 特性位图        │
├──────────────────────────────────────────────────────┤
│  [Section Header] 每个段前有 8 字节头:                │
│    - type:   uint8  (段类型)                         │
│    - length: uint32 (段长度, 固定 4 字节)            │
│    - flags:  uint8  (段属性)                         │
├──────────────────────────────────────────────────────┤
│  Section 0: Type Section     (函数签名)               │
│  Section 1: Function Section (函数定义)               │
│  Section 2: Memory Section   (内存布局声明)           │
│  Section 3: IOMap Section    (I/O 映射表)             │
│  Section 4: Code Section     (字节码)                 │
│  Section 5: Safety Section   (安全注解)               │
│  Section 6: WCET Section     (WCET 分析信息)          │
│  Section 7: Debug Section    (可选调试符号)            │
├──────────────────────────────────────────────────────┤
│  [Checksum]   CRC32         4 字节，覆盖 Magic 后所有字节 │
└──────────────────────────────────────────────────────┘
```

### 2.1 固定宽度编码规则

| 数据类型 | 编码规则 |
|---------|---------|
| `uint8` | 1 字节，直接存储 |
| `uint32` | 4 字节，小端序 |
| `sint32` | 4 字节，小端序，二进制补码 |
| `uint64` | 8 字节，小端序 |
| `float32` | 4 字节，IEEE 754 单精度 |
| `float64` | 8 字节，IEEE 754 双精度 |

### 2.2 Section 头格式

每个段之前都有一个 8 字节的段头：

```
段头结构 (8 字节):
  [0]    type:   uint8   段类型
  [1-4]  length: uint32  段数据长度（不含段头）
  [5]    reserved: uint8 保留位
  [6-7]  flags:  uint16  段属性位图
```

段类型枚举：

| 值 | 段名 | 必选 | 说明 |
|----|------|------|------|
| 0 | TYPE | 是 | 函数类型签名 |
| 1 | FUNC | 是 | 函数声明 |
| 2 | MEM | 是 | 线性内存布局 |
| 3 | IOMAP | 是 | I/O 映射表 |
| 4 | CODE | 是 | 字节码 |
| 5 | SAFE | 是 | 安全注解 |
| 6 | WCET | 否 | WCET 分析信息 |
| 7 | DEBUG | 否 | 调试符号 |

---

## 3. 指令集 (Instruction Set)

### 3.1 指令编码格式

每条指令由 **1 字节操作码 (opcode)** 后跟 **固定宽度的立即数**（如果有）组成。

```
指令编码:
  [0]     opcode:    uint8    1 字节操作码
  [1..N]  immediates: 固定宽度  取决于指令类型
```

### 3.2 指令列表

#### 控制流指令

| 操作码 | 指令 | 立即数 | 栈效果 | 说明 |
|--------|------|--------|--------|------|
| 0x00 | `UNREACHABLE` | 无 | - | 不可达指令（触发安全保护动作） |
| 0x01 | `NOP` | 无 | - | 空操作 |
| 0x02 | `BLOCK` | `len:uint32` | - | 块开始，len 为块内指令字节数 |
| 0x03 | `LOOP` | `len:uint32` | - | 循环块开始 |
| 0x04 | `BR` | `depth:uint32` | - | 无条件跳转到 depth 层外的 block/loop |
| 0x05 | `BR_IF` | `depth:uint32` | `i32 cond → -` | 条件跳转（cond ≠ 0 时跳转） |
| 0x06 | `RETURN` | 无 | - | 从当前函数返回 |

#### 函数调用

| 操作码 | 指令 | 立即数 | 栈效果 | 说明 |
|--------|------|--------|--------|------|
| 0x10 | `CALL` | `idx:uint32` | `args... → results...` | 直接调用函数 idx |

#### 参数栈操作

| 操作码 | 指令 | 立即数 | 栈效果 | 说明 |
|--------|------|--------|--------|------|
| 0x1A | `DROP` | 无 | `v → -` | 丢弃栈顶值 |
| 0x1B | `SELECT` | 无 | `c v1 v2 → v` | 三目选择: v = c ? v1 : v2 |
| 0x20 | `LOCAL_GET` | `idx:uint32` | `→ v` | 读取局部变量 idx |
| 0x21 | `LOCAL_SET` | `idx:uint32` | `v → -` | 写入局部变量 idx |
| 0x22 | `LOCAL_TEE` | `idx:uint32` | `v → v` | 写入局部变量但保留值在栈上 |

#### i32 常量加载

| 操作码 | 指令 | 立即数 | 栈效果 |
|--------|------|--------|--------|
| 0x41 | `I32_CONST` | `val:sint32` | `→ i32` |

#### i32 比较运算

| 操作码 | 指令 | 栈效果 | 说明 |
|--------|------|--------|------|
| 0x45 | `I32_EQZ` | `i32 → i32` | 等零判断 |
| 0x46 | `I32_EQ` | `i32 i32 → i32` | 相等 |
| 0x47 | `I32_NE` | `i32 i32 → i32` | 不等 |
| 0x48 | `I32_LT_S` | `i32 i32 → i32` | 有符号小于 |
| 0x49 | `I32_LE_S` | `i32 i32 → i32` | 有符号小于等于 |
| 0x4A | `I32_GT_S` | `i32 i32 → i32` | 有符号大于 |
| 0x4B | `I32_GE_S` | `i32 i32 → i32` | 有符号大于等于 |

#### i32 算术运算

| 操作码 | 指令 | 栈效果 | 说明 |
|--------|------|--------|------|
| 0x6A | `I32_ADD` | `i32 i32 → i32` | 加法 |
| 0x6B | `I32_SUB` | `i32 i32 → i32` | 减法 |
| 0x6C | `I32_MUL` | `i32 i32 → i32` | 乘法 |
| 0x6D | `I32_DIV_S` | `i32 i32 → i32` | 有符号除法（零除触发保护动作） |
| 0x6F | `I32_REM_S` | `i32 i32 → i32` | 有符号取模 |

#### i32 位运算

| 操作码 | 指令 | 栈效果 |
|--------|------|--------|
| 0x71 | `I32_AND` | `i32 i32 → i32` |
| 0x72 | `I32_OR` | `i32 i32 → i32` |
| 0x73 | `I32_XOR` | `i32 i32 → i32` |
| 0x74 | `I32_SHL` | `i32 i32 → i32` |
| 0x75 | `I32_SHR_S` | `i32 i32 → i32` |
| 0x76 | `I32_ROTL` | `i32 i32 → i32` |
| 0x77 | `I32_ROTR` | `i32 i32 → i32` |

#### i64 指令（扩展）

| 操作码 | 指令 | 说明 |
|--------|------|------|
| 0x50 | `I64_CONST` | `val:sint64 → i64` |
| 0x53 | `I64_EQZ` | 等零判断 |
| 0x54-0x5B | `I64_EQ/NE/LT_S/LE_S/GT_S/GE_S` | 比较运算 |
| 0x7C-0x7E | `I64_ADD/SUB/MUL` | 算术运算 |
| 0x7F-0x80 | `I64_DIV_S/REM_S` | 除法/取模 |
| 0x83-0x85 | `I64_AND/OR/XOR` | 位运算 |
| 0x86-0x87 | `I64_SHL/SHR_S` | 移位运算 |

#### 浮点指令

| 操作码 | 指令 | 说明 |
|--------|------|------|
| 0x43 | `F32_CONST` | `val:float32 → f32` |
| 0x44 | `F64_CONST` | `val:float64 → f64` |
| 0x92-0x95 | `F32_ADD/SUB/MUL/DIV` | f32 算术 |
| 0x9A-0x9F | `F32_EQ/NE/LT/LE/GT/GE` | f32 比较 |
| 0xA0 | `F32_ABS` | f32 绝对值 |
| 0xA1 | `F32_NEG` | f32 取反 |
| 0xA2 | `F32_SQRT` | f32 平方根 |
| 0xA3-0xA6 | `F64_ADD/SUB/MUL/DIV` | f64 算术 |
| 0x8A-0x8F | `F64_EQ/NE/LT/LE/GT/GE` | f64 比较 |

#### 类型转换

| 操作码 | 指令 | 说明 |
|--------|------|------|
| 0xA7 | `I32_WRAP_I64` | i64 → i32 截断 |
| 0xAE | `I64_EXTEND_I32_S` | i32 → i64 符号扩展 |
| 0xAF | `I32_TRUNC_F32_S` | f32 → i32 截断 |
| 0xB0 | `I32_TRUNC_F64_S` | f64 → i32 截断 |
| 0xB7 | `F32_CONVERT_I32_S` | i32 → f32 转换 |
| 0xBB | `F64_CONVERT_I32_S` | i32 → f64 转换 |

#### 字节加载/存储指令（v1.1 新增，用于质量位操作）

| 操作码 | 指令 | 参数 | 栈效果 | 说明 |
|--------|------|------|--------|------|
| `0x2C` | `I32_LOAD8_U` | `memory_arg` | `addr:i32 → val:i32` | 加载 1 字节（无符号扩展） |
| `0x3A` | `I32_STORE8` | `memory_arg` | `addr:i32 val:i32 → -` | 存储 1 字节（取低 8 位） |

#### 内存操作

所有内存操作附带固定宽度的内存参数：

```
memory_arg (4 字节):
  [0-1]  align:    uint16   对齐要求 (log2)
  [2-3]  offset:   uint16   基址偏移
```

| 操作码 | 指令 | 参数 | 栈效果 | 说明 |
|--------|------|------|--------|------|
| 0x28 | `I32_LOAD` | `memory_arg` | `addr:i32 → val:i32` | 加载 i32 |
| 0x29 | `I64_LOAD` | `memory_arg` | `addr:i32 → val:i64` | 加载 i64 |
| 0x2A | `F32_LOAD` | `memory_arg` | `addr:i32 → val:f32` | 加载 f32 |
| 0x2B | `F64_LOAD` | `memory_arg` | `addr:i32 → val:f64` | 加载 f64 |
| 0x2C | `I32_LOAD8_U` | `memory_arg` | `addr:i32 → val:i32` | **加载 1 字节（无符号），v1.1** |
| 0x36 | `I32_STORE` | `memory_arg` | `addr:i32 val:i32 → -` | 存储 i32 |
| 0x37 | `I64_STORE` | `memory_arg` | `addr:i32 val:i64 → -` | 存储 i64 |
| 0x38 | `F32_STORE` | `memory_arg` | `addr:i32 val:f32 → -` | 存储 f32 |
| 0x39 | `F64_STORE` | `memory_arg` | `addr:i32 val:f64 → -` | 存储 f64 |
| 0x3A | `I32_STORE8` | `memory_arg` | `addr:i32 val:i32 → -` | **存储 1 字节（取低8位），v1.1** |

#### 安全扩展指令

| 操作码 | 指令 | 参数 | 说明 |
|--------|------|------|------|
| 0xFC | `SAFE_ASSERT` | `assert_type:uint8 data...` | 安全断言，VM 运行时检查 |
| 0xFD | `SAFE_BOUNDS_CHECK` | `low:uint32 high:uint32` | 显式边界检查 |

`SAFE_ASSERT` 类型：

| assert_type | 数据 | 说明 |
|------------|------|------|
| 0 | `limit:uint32` | 周期指令数上限 |
| 1 | `depth:uint32` | 栈深度上限 |
| 2 | `low:uint32 high:uint32` | 内存访问范围 |

---

## 4. 各段详细格式

### 4.0 文件头 (Header)

```
[0-3]    magic:   4 字节 = 0x4D534153 ("SASM" 小端序)
[4]      version: uint8 = 0x01
[5]      flags:   uint8
         bit 0: 安全等级 (0=SIL2, 1=SIL3)
         bit 1: 热备支持 (0=不支持, 1=支持)
         bits 2-7: 保留
```

### 4.1 Type Section (段类型 0)

每个函数类型签名定义：

```
每个函数类型:
  [0]      param_count: uint32
  [1..]    param_types: param_count × uint8
  [n+1]    return_count: uint32  (0 或 1)
  [n+2..]  return_types: return_count × uint8

值类型编码:
  0x7F = I32
  0x7E = I64
  0x7D = F32
  0x7C = F64
```

### 4.2 Function Section (段类型 1)

```
每个函数声明:
  [0-3]    type_idx:  uint32  对应 Type Section 中的索引
  [4-7]    local_count: uint32  局部变量数量
  [8..]    local_types: local_count × uint8  局部变量类型
```

### 4.3 Memory Section (段类型 2)

```
总内存声明:
  [0-3]    total_size: uint32  线性内存总大小 (固定，编译期确定)
  [4-7]    segment_count: uint32  内存段数量

每个内存段:
  [0]      segment_type: uint8
           0 = IO_INPUT    (I/O 输入区，只读)
           1 = IO_OUTPUT   (I/O 输出区，可写)
           2 = GLOBAL      (全局变量区)
           3 = FB_DATA     (FB 实例数据区)
           4 = STACK       (栈区)
           5 = CONST       (常量区)
           6 = QUALITY     (影子质量区，v1.1 新增)
  [1-4]    start_offset: uint32  基址
  [5-8]    size:         uint32  大小
```

**影子质量区 (SEG_QUALITY)**：v1.1 新增段类型。每个变量在质量区中对应 1 字节质量码。

```
质量区布局:
  质量码地址(Q_BASE + var_idx) = 该变量的质量字节

变量索引与主数据区变量顺序一致:
  var_idx 0 → Q_BASE + 0  (第 0 个变量的质量)
  var_idx 1 → Q_BASE + 1  (第 1 个变量的质量)
  ...

质量区总大小 = 变量总数 × 1 字节
```

### 4.4 IOMap Section (段类型 3)

```
每个 I/O 映射条目:
  [0-3]    st_var_name_offset: uint32  变量名字符串在 Debug Section 的偏移
  [4-7]    mem_offset:   uint32  在 SafeASM 线性内存中的偏移（值部分）
  [8]      qc_offset:    uint8   质量码在影子质量区中的偏移字节（v1.1）
                                = 0xFF 表示此变量无质量位
  [9-11]   reserved
  [12-15]  channel_id:   uint32  物理通道 ID
  [16]     direction:    uint8   0=INPUT, 1=OUTPUT
  [17]     io_type:      uint8   0=AI, 1=AO, 2=DI, 3=DO
  [18-21]  bit_width:    uint32  位宽
  [22-29]  scale_factor: float64  工程量转换系数
  [30-37]  bias:         float64  偏移量
  [38-41]  safety_limit_low:  sint32  安全下限
  [42-45]  safety_limit_high: sint32  安全上限
```

### 4.5 Code Section (段类型 4)

```
每个函数的代码体:
  [0-3]    func_idx: uint32  对应的 Function 索引
  [4-7]    body_size: uint32  代码体字节数
  [8..]    body: byte[body_size]  指令序列

代码段 = 函数代码体的列表
```

### 4.6 Safety Section (段类型 5)

```
安全注解:
  [0]      safety_level: uint8  安全等级
  [1-4]    cycle_limit:  uint32  每周期最大指令数
  [5-8]    global_stack_depth: uint32  全局栈深度上限

循环上限表:
  [9-12]   loop_count: uint32  循环上限条目数
  每个条目:
    [0-3]  func_idx:   uint32  所属函数索引
    [4-7]  instr_offset: uint32  循环开始指令偏移
    [8-11] max_iterations: uint32  最大迭代次数

内存访问范围表:
  每个条目:
    [0-3]  low:  uint32  范围下限
    [4-7]  high: uint32  范围上限
```

### 4.7 WCET Section (段类型 6, 可选)

```
WCET 信息:
  [0-3]    func_count: uint32
  每个函数:
    [0-3]  func_idx:   uint32
    [4-7]  wcet_cycles: uint32  最差执行周期数
    [8-11] wcet_ns:     uint32  最差执行时间 (ns)
```

### 4.8 Debug Section (段类型 7, 可选)

```
调试符号表:
  [0-3]    string_count: uint32
  每个字符串:
    [0-3]  len:  uint32  字符串长度
    [4..]  data: byte[len]  UTF-8 字符串
```

---

## 5. SafeASM 执行语义

### 5.1 运行时状态

```
运行时状态:
  ┌─────────────────────┐
  │ 值栈 (value stack)   │  ← 操作数栈，LIFO
  ├─────────────────────┤
  │ 调用帧栈 (frame stack)│  ← 函数调用栈
  │ ┌─────────────────┐ │
  │ │ Frame           │ │
  │ │  - locals[]     │ │   ← 局部变量数组
  │ │  - func_idx     │ │   ← 当前函数索引
  │ │  - pc           │ │   ← 程序计数器
  │ └─────────────────┘ │
  ├─────────────────────┤
  │ 线性内存              │   ← byte[]，固定大小
  ├─────────────────────┤
  │ 全局变量              │   ← value[]，固定数量
  ├─────────────────────┤
  │ 周期计数器            │    ← 当前周期已执行指令数
  └─────────────────────┘
```

### 5.2 核心执行规则

```
每条指令执行:
  1. 从当前帧的 pc 位置读取 opcode
  2. 解码指令和立即数
  3. 检查预条件（栈深度、类型匹配）
  4. 执行指令（修改栈/内存/帧）
  5. pc += 指令长度
  6. cycle_cnt += 1
  7. 若 cycle_cnt > cycle_limit → 触发安全保护动作
```

### 5.3 函数调用规则

```
CALL idx:
  1. 从函数表中查找 func_idx = idx 的函数
  2. 从当前值栈弹出参数
  3. 创建新帧:
     - locals = 参数 + 局部变量默认值
     - func_idx = idx
     - pc = 该函数的 code 起始位置
  4. 新帧压入帧栈
  5. 开始执行新帧

RETURN:
  1. 当前帧的返回值（若有）留在值栈
  2. 弹出当前帧
  3. 恢复上一帧的 pc（调用后的下一条指令）
```

### 5.4 安全约束

```
每个 step 前检查:
  1. cycle_cnt < cycle_limit  (周期指令数上限)
  2. stack_depth(帧栈) ≤ global_stack_depth (调用栈深度)
  3. 值栈深度 ≤ MAX_VALUE_STACK_DEPTH
  4. 所有 LOAD/STORE 地址在 mem_access_map 范围内
  5. 除法指令除数 ≠ 0
```

### 5.5 错误处理与保护动作 (Traps)

SafeASM 虚拟机在以下情况触发**安全保护动作 (safety trap)**，立即停止当前扫描周期并进入安全状态：

| 保护动作类型 | 触发条件 | 处理方式 |
|---------|---------|---------|
| `TRAP_UNREACHABLE` | 执行到 `UNREACHABLE` 指令 | 立即停止，报告无效指令 |
| `TRAP_DIV_ZERO` | `I32_DIV_S`/`I64_DIV_S`/`I32_REM_S`/`I64_REM_S` 除数为 0 | 停止执行，输出保持上一周期值 |
| `TRAP_BOUNDS` | `I32_LOAD`/`I32_STORE` 等内存访问地址越界 | 停止执行 |
| `TRAP_STACK_OVERFLOW` | 值栈深度超过 `MAX_VALUE_STACK_DEPTH`（= 1024） | 停止执行 |
| `TRAP_STACK_UNDERFLOW` | 值栈为空时尝试弹出 | 停止执行 |
| `TRAP_CYCLE_LIMIT` | 当前周期指令数超过 `cycle_limit` | 停止执行，输出保持 |
| `TRAP_TYPE_MISMATCH` | 指令操作数类型与预期不符 | 停止执行（运行时不应发生，因编译期已验证） |
| `TRAP_INVALID_OPCODE` | 读到未定义的操作码 | 停止执行 |
| `TRAP_CALL_DEPTH` | 调用栈深度超过 `global_stack_depth` | 停止执行，防止栈溢出 |
| `TRAP_ASSERT_FAIL` | `SAFE_ASSERT` 运行时断言失败 | 停止执行 |

**安全状态行为**：
1. 数字输出保持执行前的值（fail-safe）
2. 数字输出切换到预定义安全值（由 Safety Section 配置）
3. 看门狗触发系统复位

### 5.6 小步语义的形式化定义（Coq 对应）

SafeASM 的小步操作语义在 `veristc/spec/safeasm.v` 中用归纳关系定义：

```
Inductive step : sasm_module -> runtime_state -> runtime_state -> Prop :=
  | Step_const : I32_CONST v 将 v 压入值栈
  | Step_i32_add : I32_ADD 弹出两个 i32，求和后压回
  | Step_i32_div : I32_DIV_S 检查除数非零后执行除法
  | Step_local_get : LOCAL_GET idx 将局部变量压栈
  | Step_local_set : LOCAL_SET idx 将栈顶值写入局部变量
  | Step_branch : BR depth 跳转到指定外层的 block/loop
  | Step_branch_if : BR_IF depth 仅在栈顶 ≠ 0 时跳转
  | Step_block : BLOCK len 标记结构化控制流的开始
  | Step_loop : LOOP len 标记循环块的开始（分支可跳回此处）
  | Step_call : CALL idx 创建新帧，传递参数
  | Step_return : RETURN 销毁当前帧，返回值留在栈顶
  | Step_safe_assert : SAFE_ASSERT 运行时检查安全条件
  ...
```

多步执行定义为其自反传递闭包：

```
Inductive multi_step : sasm_module -> runtime_state -> runtime_state -> Prop :=
  | Multi_refl : forall m s, multi_step m s s
  | Multi_step : forall m s1 s2 s3,
      step m s1 s2 -> multi_step m s2 s3 -> multi_step m s1 s3
```

---

## 6. 安全指令示例

### 6.1 简单加法

```
原始 ST:  x := a + b

编译为 SafeASM (所有立即数为小端序):
  41 0A 00 00 00     I32_CONST 10         ; 加载 a=10
  41 14 00 00 00     I32_CONST 20         ; 加载 b=20
  6A                 I32_ADD              ; 加法
  21 00 00 00 00     LOCAL_SET 0          ; 存入 x(局部变量0)
```

### 6.2 IF-ELSE

```
原始 ST:  IF a > b THEN max := a ELSE max := b END_IF

编译为 SafeASM (所有立即数为小端序):
  20 00 00 00 00     LOCAL_GET 0          ; 加载 a
  20 01 00 00 00     LOCAL_GET 1          ; 加载 b
  4A                 I32_GT_S             ; a > b ?
  05 02 00 00 00     BR_IF 2              ; 不成立则跳过 then
  20 00 00 00 00     LOCAL_GET 0          ; then: 加载 a
  21 02 00 00 00     LOCAL_SET 2          ; max := a
  04 01 00 00 00     BR 1                 ; 跳过 else
  20 01 00 00 00     LOCAL_GET 1          ; else: 加载 b
  21 02 00 00 00     LOCAL_SET 2          ; max := b
```

### 6.3 FOR 循环

```
原始 ST:  FOR i := 1 TO 10 DO sum := sum + i END_FOR

编译为 SafeASM (所有立即数为小端序):
  41 01 00 00 00     I32_CONST 1          ; i = 1
  21 02 00 00 00     LOCAL_SET 2          ; 存入 i
  03 1E 00 00 00     LOOP 30              ; 循环开始 (30 字节)
  20 02 00 00 00     LOCAL_GET 2          ; 加载 i
  41 0A 00 00 00     I32_CONST 10         ; 加载 10
  4B                 I32_GT_S             ; i > 10 ?
  05 02 00 00 00     BR_IF 2              ; 是→跳出
  20 01 00 00 00     LOCAL_GET 1          ; 加载 sum
  20 02 00 00 00     LOCAL_GET 2          ; 加载 i
  6A                 I32_ADD              ; sum + i
  21 01 00 00 00     LOCAL_SET 1          ; 存入 sum
  20 02 00 00 00     LOCAL_GET 2          ; 加载 i
  41 01 00 00 00     I32_CONST 1          ; 加载 1
  6A                 I32_ADD              ; i + 1
  21 02 00 00 00     LOCAL_SET 2          ; 存入 i
  04 03 00 00 00     BR 3                 ; 继续循环
```

---

## 7. 验证规则 (Validation Rules)

SafeASM 模块在加载时必须通过以下验证。验证失败则拒绝加载。

### 7.1 文件完整性

| 规则 | 描述 | 检查时机 |
|------|------|---------|
| V1 | Magic 必须为 `0x4D534153` ("SASM") | 加载时 |
| V2 | Version 必须为 `0x01` | 加载时 |
| V3 | CRC32 校验和覆盖 Magic 后所有字节，必须匹配 | 加载时 |
| V4 | 文件总大小 = 文件头 + 各段头+段数据 + 4 字节校验和 | 加载时 |

### 7.2 段验证

| 规则 | 描述 |
|------|------|
| V5 | Type Section 中每个函数签名的参数和返回值类型均在有效值集合内（0x7C-0x7F） |
| V6 | Function Section 中 `type_idx` 必须在 Type Section 的有效范围内 |
| V7 | Memory Section 中 `total_size` 必须 > 0 且 ≤ `MAX_MEMORY_SIZE`（= 64 KB） |
| V8 | Memory Section 中各段的 `start_offset + size` 不得超出 `total_size` |
| V9 | Memory Section 中各段区间不得重叠 |
| V10 | IOMap Section 中每个条目的 `mem_offset + bit_width/8` 不得超出 `total_size` |
| V11 | Code Section 中每个函数的 `body_size` 必须 > 0 |
| V12 | Safety Section 必须存在（所有 8 个基础段为必选） |

### 7.3 指令验证

| 规则 | 描述 |
|------|------|
| V13 | 所有 `CALL idx` 的 `idx` 必须在 Function Section 范围内 |
| V14 | 所有 `LOCAL_GET/SET/TEE idx` 的 `idx` 必须小于函数声明的局部变量数 |
| V15 | 所有 `BR depth` 和 `BR_IF depth` 的 `depth` 必须 ≤ 当前 BLOCK/LOOP 嵌套深度 |
| V16 | 所有 `BLOCK len` 的 `len` 必须等于块内实际指令字节数（确保结构化控制流完整性） |
| V17 | 所有 `LOOP len` 的 `len` 必须等于循环体内实际指令字节数 |
| V18 | 每个函数的指令序列必须满足值栈类型一致性（每个指令的栈效果与上下文匹配） |
| V19 | 所有 `SAFE_BOUNDS_CHECK low high` 的 `low ≤ high` |
| V20 | 所有 `SAFE_ASSERT` 的参数值必须在合理范围内 |

### 7.4 安全约束验证

| 规则 | 描述 |
|------|------|
| V21 | `safe_cycle_limit` 必须 > 0 且 ≤ `MAX_CYCLE_LIMIT`（= 10^6） |
| V22 | `safe_stack_depth` 必须 > 0 且 ≤ `MAX_CALL_DEPTH`（= 32） |
| V23 | 每个 `loop_bound` 的 `max_iter` 必须 > 0 |
| V24 | 循环上限表中所有循环的 `max_iter` 之和 ≤ `safe_cycle_limit` |
| V25 | 所有内存访问范围条目不得超出 `total_memory_size` |
| V26 | 无递归调用（调用图无环）— 与 SafeST 的 S3 约束对应 |

---

## 8. SafeASM vs 标准 WASM 差异

| 特性 | 标准 WASM | SafeASM |
|------|-----------|---------|
| 扩展名 | `.wasm` | `.sasm` |
| 编码 | LEB128 变长 | **固定宽度** (4/8 字节) |
| opcode 宽度 | 1 字节 | 1 字节 |
| `memory.grow` | 允许 | ❌ 禁止 |
| `call_indirect` | 允许 | ❌ 禁止（仅直接 CALL） |
| 可变全局 | 允许 | ❌ 仅不可变 |
| 异常处理 | 提案中 | ❌ 禁止 |
| SIMD | 提案中 | ❌ 禁止 |
| 安全段 | 无 | ✅ TYPE/FUNC/MEM/IOMAP/CODE/SAFE/WCET |
| 形式化验证 | 部分（WASM spec 有 Coq 模型） | ✅ 全量（编译器 + 指令语义） |

---

## 附录 A：完整操作码编码表

以下为所有 SafeASM 指令的 16 进制编码。

### A.1 控制流指令

| 操作码 | 指令 | 立即数字段 | 总字节数 |
|--------|------|-----------|---------|
| `0x00` | `UNREACHABLE` | — | 1 |
| `0x01` | `NOP` | — | 1 |
| `0x02` | `BLOCK` | `len:uint32` | 5 |
| `0x03` | `LOOP` | `len:uint32` | 5 |
| `0x04` | `BR` | `depth:uint32` | 5 |
| `0x05` | `BR_IF` | `depth:uint32` | 5 |
| `0x06` | `RETURN` | — | 1 |

### A.2 函数调用指令

| 操作码 | 指令 | 立即数字段 | 总字节数 |
|--------|------|-----------|---------|
| `0x10` | `CALL` | `idx:uint32` | 5 |

### A.3 栈操作指令

| 操作码 | 指令 | 立即数字段 | 总字节数 |
|--------|------|-----------|---------|
| `0x1A` | `DROP` | — | 1 |
| `0x1B` | `SELECT` | — | 1 |
| `0x20` | `LOCAL_GET` | `idx:uint32` | 5 |
| `0x21` | `LOCAL_SET` | `idx:uint32` | 5 |
| `0x22` | `LOCAL_TEE` | `idx:uint32` | 5 |

### A.4 内存操作指令

| 操作码 | 指令 | 立即数字段 | 总字节数 |
|--------|------|-----------|---------|
| `0x28` | `I32_LOAD` | `align:uint16 offset:uint16` | 5 |
| `0x29` | `I64_LOAD` | `align:uint16 offset:uint16` | 5 |
| `0x2A` | `F32_LOAD` | `align:uint16 offset:uint16` | 5 |
| `0x2B` | `F64_LOAD` | `align:uint16 offset:uint16` | 5 |
| `0x36` | `I32_STORE` | `align:uint16 offset:uint16` | 5 |
| `0x37` | `I64_STORE` | `align:uint16 offset:uint16` | 5 |
| `0x38` | `F32_STORE` | `align:uint16 offset:uint16` | 5 |
| `0x39` | `F64_STORE` | `align:uint16 offset:uint16` | 5 |

### A.5 i32 常量指令

| 操作码 | 指令 | 立即数字段 | 总字节数 |
|--------|------|-----------|---------|
| `0x41` | `I32_CONST` | `val:sint32` | 5 |

### A.6 i32 比较指令

| 操作码 | 指令 | 立即数字段 | 总字节数 |
|--------|------|-----------|---------|
| `0x45` | `I32_EQZ` | — | 1 |
| `0x46` | `I32_EQ` | — | 1 |
| `0x47` | `I32_NE` | — | 1 |
| `0x48` | `I32_LT_S` | — | 1 |
| `0x49` | `I32_LE_S` | — | 1 |
| `0x4A` | `I32_GT_S` | — | 1 |
| `0x4B` | `I32_GE_S` | — | 1 |

### A.7 i64 常量/比较指令

| 操作码 | 指令 | 立即数字段 | 总字节数 |
|--------|------|-----------|---------|
| `0x50` | `I64_CONST` | `val:sint64` | 9 |
| `0x53` | `I64_EQZ` | — | 1 |
| `0x54` | `I64_EQ` | — | 1 |
| `0x55` | `I64_NE` | — | 1 |
| `0x56` | `I64_LT_S` | — | 1 |
| `0x57` | `I64_LE_S` | — | 1 |
| `0x58` | `I64_GT_S` | — | 1 |
| `0x59` | `I64_GE_S` | — | 1 |

### A.8 i32 算术指令

| 操作码 | 指令 | 立即数字段 | 总字节数 |
|--------|------|-----------|---------|
| `0x6A` | `I32_ADD` | — | 1 |
| `0x6B` | `I32_SUB` | — | 1 |
| `0x6C` | `I32_MUL` | — | 1 |
| `0x6D` | `I32_DIV_S` | — | 1 |
| `0x6F` | `I32_REM_S` | — | 1 |

### A.9 i32 位运算指令

| 操作码 | 指令 | 立即数字段 | 总字节数 |
|--------|------|-----------|---------|
| `0x71` | `I32_AND` | — | 1 |
| `0x72` | `I32_OR` | — | 1 |
| `0x73` | `I32_XOR` | — | 1 |
| `0x74` | `I32_SHL` | — | 1 |
| `0x75` | `I32_SHR_S` | — | 1 |
| `0x76` | `I32_ROTL` | — | 1 |
| `0x77` | `I32_ROTR` | — | 1 |

### A.10 i64 算术/位运算指令

| 操作码 | 指令 | 立即数字段 | 总字节数 |
|--------|------|-----------|---------|
| `0x7C` | `I64_ADD` | — | 1 |
| `0x7D` | `I64_SUB` | — | 1 |
| `0x7E` | `I64_MUL` | — | 1 |
| `0x7F` | `I64_DIV_S` | — | 1 |
| `0x80` | `I64_REM_S` | — | 1 |
| `0x83` | `I64_AND` | — | 1 |
| `0x84` | `I64_OR` | — | 1 |
| `0x85` | `I64_XOR` | — | 1 |
| `0x86` | `I64_SHL` | — | 1 |
| `0x87` | `I64_SHR_S` | — | 1 |

### A.11 浮点常量指令

| 操作码 | 指令 | 立即数字段 | 总字节数 |
|--------|------|-----------|---------|
| `0x43` | `F32_CONST` | `val:float32` | 5 |
| `0x44` | `F64_CONST` | `val:float64` | 9 |

### A.12 f32 算术/比较指令

| 操作码 | 指令 | 立即数字段 | 总字节数 |
|--------|------|-----------|---------|
| `0x92` | `F32_ADD` | — | 1 |
| `0x93` | `F32_SUB` | — | 1 |
| `0x94` | `F32_MUL` | — | 1 |
| `0x95` | `F32_DIV` | — | 1 |
| `0x9A` | `F32_EQ` | — | 1 |
| `0x9B` | `F32_NE` | — | 1 |
| `0x9C` | `F32_LT` | — | 1 |
| `0x9D` | `F32_LE` | — | 1 |
| `0x9E` | `F32_GT` | — | 1 |
| `0x9F` | `F32_GE` | — | 1 |
| `0xA0` | `F32_ABS` | — | 1 |
| `0xA1` | `F32_NEG` | — | 1 |
| `0xA2` | `F32_SQRT` | — | 1 |

### A.13 f64 算术/比较指令

| 操作码 | 指令 | 立即数字段 | 总字节数 |
|--------|------|-----------|---------|
| `0xA3` | `F64_ADD` | — | 1 |
| `0xA4` | `F64_SUB` | — | 1 |
| `0xA5` | `F64_MUL` | — | 1 |
| `0xA6` | `F64_DIV` | — | 1 |
| `0x8A` | `F64_EQ` | — | 1 |
| `0x8B` | `F64_NE` | — | 1 |
| `0x8C` | `F64_LT` | — | 1 |
| `0x8D` | `F64_LE` | — | 1 |
| `0x8E` | `F64_GT` | — | 1 |
| `0x8F` | `F64_GE` | — | 1 |

### A.14 类型转换指令

| 操作码 | 指令 | 立即数字段 | 总字节数 |
|--------|------|-----------|---------|
| `0xA7` | `I32_WRAP_I64` | — | 1 |
| `0xAE` | `I64_EXTEND_I32_S` | — | 1 |
| `0xAF` | `I32_TRUNC_F32_S` | — | 1 |
| `0xB0` | `I32_TRUNC_F64_S` | — | 1 |
| `0xB7` | `F32_CONVERT_I32_S` | — | 1 |
| `0xBB` | `F64_CONVERT_I32_S` | — | 1 |

### A.15 安全扩展指令

| 操作码 | 指令 | 立即数字段 | 总字节数 |
|--------|------|-----------|---------|
| `0xFC` | `SAFE_ASSERT` | `assert_type:uint8 data...` | 2+ |
| `0xFD` | `SAFE_BOUNDS_CHECK` | `low:uint32 high:uint32` | 9 |

---

## 附录 B：二进制布局示例

以下展示一个最小 `.sasm` 文件的完整十六进制布局。

```
偏移    字节                                 说明
─────   ───────────────────────────────────   ────────────────────────────
0x00    53 41 53 4D                          Magic: "SASM"
0x04    01                                    Version: 1
0x05    01                                    Flags: SIL3 (bit0=1)

0x06    00                                   段类型: TYPE (0)
0x07    07 00 00 00                          段长度: 7 字节
0x0B    00                                   保留
0x0C    00 00                                 Flags

0x0E    01 00 00 00                          param_count: 1
0x12    7F                                    param_types[0]: I32
0x13    01 00 00 00                          return_count: 1
0x17    7F                                    return_types[0]: I32

0x18    01                                   段类型: FUNC (1)
0x19    0B 00 00 00                          段长度: 11 字节
...

```
| 确定性 | 部分 | ✅ 完全确定 |
| 校验和 | 无 | ✅ CRC32 校验 |
| 边界检查 | 运行时隐式 | ✅ 编译期 + 运行时显式 (SAFE_BOUNDS_CHECK) |

---

## 附录 A：`.sasm` 最小示例（十六进制）

```
; ==============================================================
; 最简单 SafeASM 程序: 返回常量 42
; 等效函数: int main() { return 42; }
; ==============================================================

; --- 文件头 ---
53 41 53 4D        ; Magic "SASM"
01                 ; Version = 1
00                 ; Flags = 0

; --- Type Section ---
00                 ; Section type = TYPE
0C 00 00 00        ; Length = 12
00 00              ; Flags = 0
00 00 00 00        ; param_count = 0
01 00 00 00        ; return_count = 1
7F 00 00 00        ; return_type = I32

; --- Function Section ---
01                 ; Section type = FUNC
0C 00 00 00        ; Length = 12
00 00              ; Flags = 0
00 00 00 00        ; type_idx = 0
00 00 00 00        ; local_count = 0

; --- Memory Section ---
02                 ; Section type = MEM
10 00 00 00        ; Length = 16
00 00              ; Flags = 0
00 01 00 00        ; total_size = 256 bytes
00 00 00 00        ; segment_count = 0

; --- IOMap Section ---
03                 ; Section type = IOMAP
04 00 00 00        ; Length = 4
00 00              ; Flags = 0
00 00 00 00        ; entry_count = 0

; --- Code Section ---
04                 ; Section type = CODE
14 00 00 00        ; Length = 20
00 00              ; Flags = 0
00 00 00 00        ; func_idx = 0
0A 00 00 00        ; body_size = 10
41 2A 00 00 00     ; I32_CONST 42
0B                 ; RETURN (indicates end)

; --- Safety Section ---
05                 ; Section type = SAFE
10 00 00 00        ; Length = 16
00 00              ; Flags = 0
01                 ; safety_level = SIL3
00 00 00 00        ; cycle_limit = 0 (unlimited)
00 00 00 00        ; stack_depth = 0
00 00 00 00        ; loop_count = 0

; --- Checksum ---
XX XX XX XX        ; CRC32 (覆盖 Magic 后所有字节)
```

---

## 附录 C：质量传播编译模式（v1.1）

本章展示编译器如何将 ST 的质量操作展开为内联 SafeASM 指令序列，VM 无需感知质量概念。

### C.1 变量访问

```
ST:  qX : QINT;         -- 带质量的整型变量

Q_STATUS(qX) 展开:
  I32_CONST  Q_BASE + X_idx      ; 影子质量区基址 + 变量索引
  I32_LOAD8_U                    ; 加载 1 字节质量码
  ── 2 条指令

Q_VALUE(qX) 展开:
  LOCAL_GET  X_idx               ; 直接读值（值与质量分离）
  ── 1 条指令
```

### C.2 质量传播：二元运算

```
ST:  qResult := qA + qB;     -- QINT + QINT → QINT

展开为 SafeASM:
  ;; ─── 值计算 ───
  LOCAL_GET  A_val_idx        ; 加载 A 的值
  LOCAL_GET  B_val_idx        ; 加载 B 的值
  I32_ADD                     ; 加法
  LOCAL_SET  R_val_idx        ; 存结果值

  ;; ─── 质量传播 ───
  I32_CONST  Q_BASE + A_idx   ; A 质量地址
  I32_LOAD8_U                 ; 读 A 质量
  I32_CONST  Q_BASE + B_idx   ; B 质量地址
  I32_LOAD8_U                 ; 读 B 质量
  I32_GT_U                    ; worst = max(qA, qB) [数值上 0<1<2<3]
  I32_CONST  Q_BASE + R_idx   ; 结果质量地址
  I32_STORE8                  ; 写结果质量

  ;; ── 5 条值指令 + 7 条质量指令 = 12 条指令
  ;; 质量传播开销固定 7 条指令 ✅
```

### C.3 质量常量赋值

```
ST:  qX := Q_WITH(42, GOOD);

展开为 SafeASM:
  ;; 值部分
  I32_CONST  42
  LOCAL_SET  X_val_idx

  ;; 质量部分：写入 GOOD (0)
  I32_CONST  Q_BASE + X_idx
  I32_CONST  0                ; GOOD = 0
  I32_STORE8

  ;; ── 4 条指令，固定开销 ✅
```

### C.4 质量检查条件

```
ST:  IF Q_GOOD(qA) THEN ... END_IF

展开为 SafeASM:
  I32_CONST  Q_BASE + A_idx
  I32_LOAD8_U                 ; 读 A 质量
  I32_CONST  0                ; GOOD = 0
  I32_EQ                      ; quality == GOOD ?
  BR_IF  end_if               ; 不是 → 跳过 then 块

  ;; ... then 块指令 ...

end_if:

  ;; ── 5 条指令 + 质量检查后的分支（分支 WCET 取最长路径）
```

### C.5 Q_FORCE 强制赋值

```
ST:  Q_FORCE(qX, 100, BAD);

展开为 SafeASM:
  ;; 值部分
  I32_CONST  100
  LOCAL_SET  X_val_idx

  ;; 质量部分
  I32_CONST  Q_BASE + X_idx
  I32_CONST  2                ; BAD = 2
  I32_STORE8

  ;; ── 5 条指令，固定开销 ✅
```

### C.6 类型转换：带正确质量透传

```
ST:  qDINT := QINT_var;     -- QINT → QDINT (提升)

展开为 SafeASM:
  LOCAL_GET  QINT_val_idx
  LOCAL_SET  QDINT_val_idx   ; 值直接拷贝（同为 I32）

  ;; 质量透传
  I32_CONST  Q_BASE + QINT_idx
  I32_LOAD8_U
  I32_CONST  Q_BASE + QDINT_idx
  I32_STORE8                 ; 质量直接拷贝

  ;; ── 4 条指令，质量透传 ✅
```

### C.7 质量传播 WCET 汇总

| 操作 | 指令数 | 分支 | WCET 可预测性 |
|------|--------|------|-------------|
| Q_STATUS 读取 | 2 | 无 | ✅ 固定 |
| Q_VALUE 提取 | 1 | 无 | ✅ 固定 |
| Q_WITH 构造 | 4 | 无 | ✅ 固定 |
| Q_SET 写入 | 3 | 无 | ✅ 固定 |
| Q_FORCE 强赋 | 5 | 无 | ✅ 固定 |
| Q_GOOD/Q_BAD 检查 | 4-5 | 有（1 个 BR_IF） | ✅ 取最长路径 |
| 二元运算质量传播 | 7 | 无 | ✅ 固定 |
| 一元运算质量传播 | 3 | 无 | ✅ 固定 |
| 赋值质量传播 | 3 | 无 | ✅ 固定 |

**结论**：所有质量操作的 WCET 均可静态计算，无隐藏分支或循环 ✅
```
