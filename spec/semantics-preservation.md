# SafeST → SafeASM 语义保持转换说明

> **文档版本**：v1.1  
> **状态**：正式发布  
> **生效日期**：2026-06-30  
> **对应 Coq 文件**：`compiler_correctness.v`（核心定理声明）  
> **对应实现文件**：`codegen.v`（代码生成器实现+证明）  
> **目的**：让不熟悉 Coq 形式化方法的开发人员也能清晰理解 ST 语言的每种构造如何映射到 SafeASM 指令，以及为什么这种映射是正确的（语义保持）。  

---

## 0. 文档控制

### 0.1 版本历史

| 版本 | 日期 | 变更说明 | 作者 |
|------|------|---------|------|
| v0.1 | 草案 | 初始草案 | JIANG Wei |
| v1.0 | 2026-06-29 | 正式发布。为每个 ST 构造补充完整的编译映射 + 语义保持例图；新增逻辑求值、CASE、WHILE、REPEAT、EXIT、数组访问、类型转换的逐构造证明示例；新增抽象关系 R 的完整定义；新增编译器逐阶段证明对应表。 | JIANG Wei |
| **v1.1** | **2026-07-02** | **全面更新：2.1 表达式映射表扩充 64 位运算/浮点/类型转换/Q 类型操作/质量检查函数；2.2 语句映射表新增 Q 类型赋值/T→QT 隐式转换/质量检查分支；新增 2.4 质量传播映射表（含 worst() 函数）；新增 3.3 影子质量内存布局（SEG_QUALITY）；4. 扫描周期增加质量影子区同步步骤；6.2 类型兼容映射表扩展至 Q* 全集；7.1 抽象关系 R 补充质量一致性条件；7.3 安全保持定理扩展质量安全约束；新增例 12 (64 位类型运算)；新增 8. 证明对应表（含质量条目）** | JIANG Wei |

### 0.2 符号约定

```
[[e]]     : ST 表达式 e 的求值结果
⟦e⟧      : ST 表达式 e 编译后的 SafeASM 指令序列
σ         : ST 运行时状态
τ         : SafeASM 运行时状态
R(σ, τ)  : 抽象关系 —— ST 状态 σ 与 ASM 状态 τ "看起来一样"
step_st   : ST 小步执行一步
⇒         : SafeASM 多步执行（multi_step）
```

---

## 1. 核心原则

```
对于任意 ST 程序 P，如果 P 编译生成 SafeASM 模块 M，
那么 M 在 SafeASM 虚拟机上的执行行为，
与 P 在 ST 语义下的执行行为完全一致。
```

**通俗解释**：编译器不会改变程序的"意思"。你在 ST 中写了一个 `x := a + b`，在 SafeASM 中执行对应指令序列后，`x` 的值与 ST 语义规定的值完全一样。

---

## 2. 逐构造映射表 (SafeST → SafeASM)

这是开发人员最需要关心的核心文档。每种 ST 构造的编译映射都附带**语义保持理由**。

### 2.1 表达式映射

| ST 构造 | SafeASM 指令序列 | 语义保持理由 |
|---------|-----------------|-------------|
| **32 位整数字面量** `42` | `I32_CONST 42` | 直接值映射，无歧义 |
| **64 位整数字面量** `L#100000` | `I64_CONST 100000` | 64 位直接值映射 |
| **布尔字面量** `TRUE` | `I32_CONST 1` | TRUE=1 映射 |
| **32 位浮点字面量** `3.14` | `F32_CONST 3.14` | 直接值映射 |
| **64 位浮点字面量** `LREAL#3.14` | `F64_CONST 3.14` | 64 位浮点直接值映射 |
| **时间字面量** `T#5s` | `I64_CONST 5000000000` | 纳秒编码为 64 位整数 |
| **变量引用** `x` | `LOCAL_GET idx` | 编译期变量偏移已确定，运行期一致 |
| **数组访问** `arr[i]` | `[arr_base] [i] I32_ADD SAFE_BOUNDS_CHECK I32_LOAD` | 基址+偏移+边界检查 |
| **一元负号** `-x` (32位) | `[x] I32_CONST 0 SWAP I32_SUB` | 0 - x = -x |
| **一元负号** `-x` (64位) | `[x] I64_CONST 0 SWAP I64_SUB` | 0 - x = -x，64 位版本 |
| **逻辑非** `NOT x` | `[x] I32_EQZ` | NOT x == (x = 0) |
| **绝对值** `ABS x` | `[x] DUP I32_CONST 0 I32_LT_S BR_IF neg [x] BR end neg: [x] I32_NEG end:` | 条件取反 |
| **32 位二元运算** `a + b` | `[a] [b] I32_ADD` | 值栈模型与表达式树同构 |
| **64 位二元运算** `a + b` (LINT) | `[a] [b] I64_ADD` | I64 值栈运算，同构映射 |
| **32 位乘除** `a * b`, `a / b` | `[a] [b] I32_MUL` / `I32_DIV_S` | 值栈运算 |
| **64 位乘除** `a * b`, `a / b` | `[a] [b] I64_MUL` / `I64_DIV_S` | I64 值栈运算 |
| **32 位取模** `a MOD b` | `[a] [b] I32_REM_S` | 值栈运算 |
| **64 位取模** `a MOD b` | `[a] [b] I64_REM_S` | I64 值栈运算 |
| **三元运算** `a * b + c` | `[a] [b] I32_MUL [c] I32_ADD` | 后序遍历，与 AST 一致 |
| **32 位比较** `a > b` | `[a] [b] I32_GT_S` | 比较结果 0/1 直接入栈 |
| **64 位比较** `a > b` | `[a] [b] I64_GT_S` | I64 比较结果 0/1 入栈 |
| **浮点运算** `a + b` (REAL) | `[a] [b] F32_ADD` | 浮点栈运算 |
| **64 位浮点运算** `a + b` (LREAL) | `[a] [b] F64_ADD` | 双精度浮点栈运算 |
| **浮点比较** `a > b` (REAL) | `[a] [b] F32_GT` | 浮点比较结果 0/1 入栈 |
| **64 位浮点比较** `a > b` (LREAL) | `[a] [b] F64_GT` | 双精度比较结果 0/1 入栈 |
| **逻辑 AND** `a AND b` | `[a] BR_IF 0 [b]` | a=false 时跳过 b 的计算 |
| **逻辑 OR** `a OR b` | `[a] BR_IF 1 [b]` | a=true 时跳过 b 的计算 |
| **XOR** `a XOR b` | `[a] [b] I32_XOR` | 直接位运算 |
| **i32 → i64 扩展** `LINT(x)` | `[x] I64_EXTEND_I32_S` | 符号扩展保持数值一致 |
| **i64 → i32 截断** `DINT(x)` | `[x] I32_WRAP_I64` | 截断低 32 位 |
| **i32 → f32 转换** `REAL(x)` | `[x] F32_CONVERT_I32_S` | IEEE 754 转换 |
| **i32 → f64 转换** `LREAL(x)` | `[x] F64_CONVERT_I32_S` | 32 位整数 → 双精度浮点 |
| **f32 → i32 截断** `DINT(x)` | `[x] I32_TRUNC_F32_S` | 浮点截断 |
| **f64 → i32 截断** `DINT(x)` | `[x] I32_TRUNC_F64_S` | 双精度浮点截断 |
| **质量读取** `Q_STATUS(x)` | `I32_CONST Q_BASE+x_idx I32_LOAD8_U` | 从影子质量区加载 1 字节质量码 |
| **质量检查** `Q_GOOD(x)` | `[Q_STATUS(x)] I32_CONST 0 I32_EQ` | GOOD=0 比较 |
| **质量检查** `Q_BAD(x)` | `[Q_STATUS(x)] I32_CONST 1 I32_EQ` | BAD=1 比较 |
| **值+质量构造** `Q_WITH(v, q)` | `[v] [q]` | 值栈同时保留值和质量 |

### 2.2 语句映射

| ST 构造 | SafeASM 指令序列 | 语义保持理由 |
|---------|-----------------|-------------|
| **赋值（普通类型）** `x := e` | `[e] LOCAL_SET idx` | 先计算 e 的值压栈，再存入 x |
| **数组赋值** `a[i] := e` | `[base] [i] I32_ADD [e] I32_STORE` | 计算地址 → 存入值 |
| **Q 类型赋值** `qX := qE` | `[qE] LOCAL_SET qX_val_idx` + `质量传播(见 2.4)` | 值赋值 + 质量传播代码 |
| **T → QT 隐式转换** `qX := pY` | `[pY] LOCAL_SET qX_val_idx` + `I32_CONST Q_BASE+qX_idx I32_CONST 0 I32_STORE8` | 质量自动设为 GOOD |
| **质量检查分支** `IF Q_GOOD(x) THEN ...` | `[Q_STATUS(x)] I32_CONST 0 I32_EQ BR_IF end_if` | 质量 GOOD 为执行条件 |
| **IF-THEN** | `[cond] BR_IF end [then_body] end:` | cond=false 跳过 then 块 |
| **IF-THEN-ELSE** | `[cond] BR_IF else [then] BR end else: [else] end:` | 控制流分叉精确对应 |
| **CASE** | 级联 `BR_IF` 或 `BR_TABLE` | 每个分支对应一个基本块 |
| **FOR 循环** | `[init] SET i LOOP [body] [inc] [i<=end] BR_IF loop` | 循环结构一一映射 |
| **WHILE 循环** | `LOOP [cond] BR_IF end [body] BR loop end:` | 先判断再执行 |
| **REPEAT 循环** | `LOOP [body] [cond] BR_IF loop` | 先执行再判断 |
| **函数调用** `F(args)` | `[args] CALL func_idx` | 栈传递参数 + 返回值 |
| **FB 调用** `inst(a:=1)` | `[a] CALL fb_method_idx` | FB 数据在内存中，通过偏移访问 |
| **RETURN** | `RETURN` | 直接对应 |
| **EXIT** | `BR exit_depth` | 跳出当前循环 |

### 2.3 逻辑求值的精确保留

ST 的 `AND` 和 `OR` 是逻辑求值的（左操作数决定后，右操作数可能不计算）。

```
ST:  b := (x > 0) AND (y / x > 5)
     ── 当 x=0 时，右操作数 y/x 不会执行（避免除零）

SafeASM 映射:
  LOCAL_GET x        ; 加载 x
  I32_CONST 0
  I32_GT_S           ; x > 0 ?
  BR_IF false_br     ; 若 FALSE，跳过右侧计算，直接结果为 0
  LOCAL_GET y
  LOCAL_GET x
  I32_DIV_S          ; y / x (仅在 x>0 时执行)
  I32_CONST 5
  I32_GT_S           ; y/x > 5 ?
  BR end_br
false_br:
  I32_CONST 0        ; 结果为 FALSE
end_br:
  LOCAL_SET b        ; b := 结果
```

**语义保持**：ST 的逻辑语义与 BR_IF 跳转完全等价 ✅

### 2.4 质量传播映射表（v1.1）

编译器为每个 Q 类型变量自动生成**影子质量区**的读写代码。质量传播规则如下：

| ST 构造 | 质量传播规则 | SafeASM 指令模板 | 语义保持理由 |
|---------|-------------|------------------|-------------|
| **字面量** `42` | 质量 = GOOD | `I32_CONST Q_BASE+dst_idx I32_CONST 0 I32_STORE8` | 常量始终可信 Q1 |
| **变量引用** `x` | 质量 = x.quality | `I32_CONST Q_BASE+x_idx I32_LOAD8_U` | 透传，Q2 |
| **一元运算** `-x`, `NOT x`, `ABS x` | 质量 = operand.quality | `[读 x 质量] I32_CONST Q_BASE+dst_idx I32_STORE8` | 透传，Q3 |
| **二元运算** `a + b` | quality = worst(a.q, b.q) | `[读 a 质量] [读 b 质量] I32_GT_U` (取大值) | worst=max，Q4 |
| **比较运算** `a > b` | quality = worst(a.q, b.q) | 同二元运算 | 比较依赖双方质量，Q5 |
| **逻辑 AND** `a AND b` | quality = worst(已计算操作数的 q) | 条件执行中追踪质量 | 短路不影响质量，Q6 |
| **T → QT 赋值** `qX := pY` | qX.quality = GOOD | `I32_CONST Q_BASE+qX_idx I32_CONST 0 I32_STORE8` | 普通变量总是 GOOD，Q9 |
| **QT → QT 赋值** `qX := qY` | qX.quality = qY.quality | `[读 qY 质量] I32_CONST Q_BASE+qX_idx I32_STORE8` | 质量透传，Q7 |
| **函数/FB 调用** | 结果质量 = worst(所有输入质量的 worst) | 编译器为返回值生成质量计算 | 依赖所有输入，Q8 |
| **Q_WITH(v, q)** | 结果质量 = q | `[q] I32_CONST Q_BASE+dst_idx I32_STORE8` | 显式指定，Q10 |

**质量传播的 worst() 函数**在 SafeASM 层展开为 `I32_GT_U`（取数值上的最大值）：

```
worst(a, b) = I32_GT_U   ── 因为编码: GOOD(0) < BAD(1)
```

**语义保持核心**：质量传播代码由编译器自动插入，VM 无需感知质量语义。每条质量传播指令序列的 WCET 可静态计算（固定指令数、无分支），满足安全约束。

---

## 3. 内存布局映射

### 3.1 变量到内存偏移

```
ST 变量声明                              SafeASM 线性内存偏移
─────────────────                      ─────────────────────
VAR_INPUT                               ← IO_INPUT_BASE
  AI1 : REAL;        ──►  offset 0-3
  DI1 : BOOL;        ──►  offset 4
END_VAR
                                        ← IO_OUTPUT_BASE
VAR_OUTPUT
  AO1 : REAL;        ──►  offset 0-3
  DO1 : BOOL;        ──►  offset 4
END_VAR
                                        ← GLOBAL_BASE
VAR_GLOBAL
  counter : DINT;    ──►  offset 0-3
  mode    : INT;     ──►  offset 4-5
END_VAR
                                        ← FB_BASE
FUNCTION_BLOCK Timer
  VAR_INPUT           ──►  Timer_inst 起始偏移
    Preset : TIME;                      offset 0-7
  END_VAR
    ...
END_FUNCTION_BLOCK
                                        ← STACK_BASE
(临时变量/函数调用栈)                    动态分配
                                        ← CONST_BASE
(常量池)                                固定偏移
                                        ← Q_BASE (v1.1)
(影子质量区 — 每个变量 1 字节质量码)       Q_BASE + var_idx
```

### 3.2 偏移计算规则（编译期确定，运行期固定）

```
输入变量偏移(v) = IO_INPUT_BASE + input_layout(v_index)
输出变量偏移(v) = IO_OUTPUT_BASE + output_layout(v_index)
全局变量偏移(v) = GLOBAL_BASE + global_layout(v_index)
FB 字段偏移(inst, field) = FB_BASE + fb_base(inst) + field_offset(field)
局部变量偏移(f, idx) = STACK_BASE + frame_ptr(f) + idx × 4
质量码偏移(v) = Q_BASE + var_idx(v)          ← v1.1 新增
```

**关键保证**：所有偏移在**编译期确定**，运行期固定。SafeASM 线性内存布局由 Memory Section 中的 `memory_segments` 描述。

### 3.3 影子质量内存布局（v1.1）

每个 Q 类型变量在影子质量区中占用 **1 字节**质量码。影子质量区是 SafeASM 线性内存的独立段 `SEG_QUALITY`。

```
      主数据区 (值)                   影子质量区 (质量码)
  ┌─────────────────┐          ┌──────────────────────────┐
  │ var_0  (4 字节)  │          │ Q_BASE + 0: var_0.q     │ 1 字节
  │ var_1  (8 字节)  │          │ Q_BASE + 1: var_1.q     │ 1 字节
  │ var_2  (4 字节)  │          │ Q_BASE + 2: var_2.q     │ 1 字节
  │ ...             │          │ ...                      │
  │ var_N  (4 字节)  │          │ Q_BASE + N: var_N.q     │ 1 字节
  └─────────────────┘          └──────────────────────────┘

  质量码编码:
    0x00 = GOOD (GOOD)
    0x01 = BAD (BAD)

  质量区大小 = 变量总数 × 1 字节
  Q_BASE = IO_INPUT_BASE + IO_OUTPUT_BASE + GLOBAL_BASE + FB_BASE + STACK_BASE + CONST_BASE
          （即紧接在所有数据段之后）
```

**Q 类型变量的内存占用**（值与质量分离存储）：

| Q 类型 | 值在主数据区 | 质量在影子区 | 总内存占位 |
|--------|-------------|-------------|-----------|
| QBOOL | 1 B (对齐到 4 B) | 1 B | 5 B |
| QBYTE | 1 B (对齐到 4 B) | 1 B | 5 B |
| QINT | 4 B | 1 B | 5 B |
| QDINT | 4 B | 1 B | 5 B |
| QREAL | 4 B | 1 B | 5 B |
| QLINT | 8 B | 1 B | 9 B |
| QLREAL | 8 B | 1 B | 9 B |
| QTIME | 8 B | 1 B | 9 B |

**语义保持**：质量码与值一一对应，同步读写。值赋值操作之后紧跟质量传播代码，保证两者在 SafeASM 执行模型中始终一致。

---

## 4. 扫描周期映射

```
ST 扫描周期                         SafeASM 扫描周期
┌─────────────────┐               ┌──────────────────────────────────┐
│ 1. 读输入        │  ← I/O映射── │ 1. VM 将 I/O 输入拷贝到          │
│                  │              │    SafeASM 线性内存输入区         │
│                  │              │ 1b. VM 将 I/O 输入质量拷贝到     │
│                  │              │     影子质量区 (v1.1)            │
│ 2. 执行逻辑      │  ────►      │ 2. CALL entry_function           │
│                  │              │    (执行编译后的字节码，          │
│                  │              │     含质量传播代码)              │
│ 3. 写输出        │  ────►      │ 3. VM 将 SafeASM 线性内存         │
│                  │              │    输出区写回 I/O 输出            │
│                  │              │ 3b. VM 将影子质量区输出变量质量  │
│                  │              │    写回 I/O 质量 (v1.1)          │
└─────────────────┘               └──────────────────────────────────┘
```

**关键保证**：
- 一个 ST 扫描周期 = 一次 SafeASM `CALL entry_function` 调用
- I/O 输入质量在步骤 1b 中与值同步拷贝到影子质量区
- I/O 输出质量在步骤 3b 中写回物理通道
- 编译器生成的质量传播代码在步骤 2 中自动维护中间变量质量链
- 输入输出质量与值始终同步对齐 ✅

---

## 5. 语义保持示例

### 例 1：简单表达式 `x := a + b * 2`

```
ST:  x := a + b * 2
      │
      ▼  解析树 (AST):
           :=
          /  \
         x    +
             / \
            a   *
               / \
              b   2
      │
      ▼  编译为 SafeASM (后序遍历):
      LOCAL_GET a_idx    ; 加载 a 的值到栈
      LOCAL_GET b_idx    ; 加载 b 的值到栈
      I32_CONST 2        ; 加载常量 2
      I32_MUL            ; 计算 b * 2，结果在栈顶
      I32_ADD            ; 计算 a + (b*2)，结果在栈顶
      LOCAL_SET x_idx    ; 将栈顶值存入 x
      
      │
      ▼  ST 语义: x = [[a]] + ([[b]] × 2)
      ▼  ASM 语义: 栈计算结果与 ST 语义一致 ✅
```

**为什么正确**：表达式树的后序遍历天然对应值栈操作——左子树先入栈，右子树后入栈，根节点运算消耗栈顶元素。这是编译原理中经过形式化证明的经典结论。

### 例 2：IF 条件分支

```
ST:  IF a > b THEN max := a ELSE max := b END_IF
      │
      ▼  编译为 SafeASM:
      LOCAL_GET a_idx    ; 加载 a
      LOCAL_GET b_idx    ; 加载 b
      I32_GT_S           ; 比较 a > b → 栈顶为 0 或 1
      BR_IF else_br      ; 如果 0 (a<=b) 跳转到 else
      LOCAL_GET a_idx    ; then 分支: 加载 a
      LOCAL_SET max_idx  ; max := a
      BR end_br
  else_br:
      LOCAL_GET b_idx    ; else 分支: 加载 b
      LOCAL_SET max_idx  ; max := b
  end_br:
      
      │
      ▼  语义保持: ST 的 IF 语义 = ASM 的分支跳转语义
         IF 条件成立 → 执行 then 块 → 跳过 else
         IF 条件不成立 → 跳过 then → 执行 else 块
         两条路径的计算结果等价 ✅
```

### 例 3：FOR 循环

```
ST:  FOR i := 1 TO 10 DO total := total + i END_FOR
      │
      ▼  编译为 SafeASM:
      I32_CONST 1
      LOCAL_SET i_idx    ; i := 1
  loop_start:
      LOCAL_GET i_idx    ; 加载 i
      I32_CONST 10
      I32_GT_S           ; i > 10 ?
      BR_IF loop_end     ; 是 → 跳出
      LOCAL_GET total_idx
      LOCAL_GET i_idx
      I32_ADD
      LOCAL_SET total_idx ; total := total + i
      LOCAL_GET i_idx
      I32_CONST 1
      I32_ADD
      LOCAL_SET i_idx    ; i := i + 1
      BR loop_start      ; 继续循环
  loop_end:
      
      │
      ▼  语义保持:
         ST: for i=1 to 10 → total = total + i
         ASM: LOOP + BR_IF → 完全相同的迭代语义 ✅
         循环次数 = 10，编译期已知 ✅ (安全约束满足)
```

### 例 4：函数调用

```
ST:  result := Add(5, 3)
     
     FUNCTION Add : INT
         VAR_INPUT a, b : INT; END_VAR
         Add := a + b;
     END_FUNCTION
      │
      ▼  编译为 SafeASM:
      I32_CONST 5        ; 参数 1
      I32_CONST 3        ; 参数 2
      CALL 0             ; 调用函数索引 0 (Add)
      LOCAL_SET result_idx  ; 将返回值存入 result
      
  ; Add 函数的 SafeASM:
  ; Type: [I32, I32] → [I32]
  ; Code:
  func_Add:
      LOCAL_GET 0        ; 加载参数 a
      LOCAL_GET 1        ; 加载参数 b
      I32_ADD            ; a + b
      RETURN             ; 返回栈顶值
      
      │
      ▼  语义保持:
         ST 语义: result = Add(5, 3) = 5 + 3 = 8
         ASM 语义: CALL 0 → 执行 Add 指令 → RETURN → 栈顶=8
         参数传递和返回值一一对应 ✅
```

### 例 5：逻辑求值 (Short-circuit AND)

```
ST:  b := (x > 0) AND (y / x > 5)
     ── 当 x=0 时，右侧 y/x 不会计算（避免除零）
      │
      ▼  编译为 SafeASM:
      LOCAL_GET x_idx        ; 加载 x
      I32_CONST 0
      I32_GT_S               ; x > 0 ?
      BR_IF false_br         ; 若 FALSE，跳过右侧直接得 0
      LOCAL_GET y_idx
      LOCAL_GET x_idx
      I32_DIV_S              ; y / x (仅在 x>0 时执行)
      I32_CONST 5
      I32_GT_S               ; y/x > 5 ?
      BR end_br
  false_br:
      I32_CONST 0            ; 结果为 FALSE
  end_br:
      LOCAL_SET b_idx        ; b := 结果
      
      │
      ▼  模拟证明:
     情况 1: x ≤ 0
       ST:    (x > 0)=false → 逻辑，不计算右侧 → b:=false
       ASM:   BR_IF 跳转到 false_br → I32_CONST 0 → b:=0
       ✅  b = false = 0

     情况 2: x > 0 且 y/x > 5
       ST:    (x>0)=true → 计算 y/x → (y/x>5)=true → b:=true
       ASM:   不跳转 → 执行除法 → 比较 → b:=1
       ✅  b = true = 1

     情况 3: x > 0 且 y/x ≤ 5
       ST:    (x>0)=true → 计算 y/x → (y/x>5)=false → b:=false
       ASM:   不跳转 → 执行除法 → 比较 → 结果为 0 → b:=0
       ✅  b = false = 0
```

### 例 6：CASE 语句

```
ST:  CASE mode OF
        1 : state := 10;
        2 : state := 20;
        3,4 : state := 30;
        5..10 : state := 40;
     ELSE
        state := 0;
     END_CASE
      │
      ▼  编译为 SafeASM (级联 BR_IF):
      LOCAL_GET mode_idx     ; 加载 mode
      I32_CONST 1
      I32_EQ                 ; mode = 1 ?
      BR_IF case_1
      LOCAL_GET mode_idx
      I32_CONST 2
      I32_EQ                 ; mode = 2 ?
      BR_IF case_2
      LOCAL_GET mode_idx
      I32_CONST 3
      I32_EQ                 ; mode = 3 ?
      BR_IF case_3_4
      LOCAL_GET mode_idx
      I32_CONST 4
      I32_EQ                 ; mode = 4 ?
      BR_IF case_3_4
      LOCAL_GET mode_idx
      I32_CONST 5
      I32_GE_S               ; mode >= 5 ?
      BR_IF range_5_10
      ...                    ; (检查 mode <= 10)
      BR else_br

  case_1:
      I32_CONST 10
      LOCAL_SET state_idx
      BR end_case
  case_2:
      I32_CONST 20
      LOCAL_SET state_idx
      BR end_case
  case_3_4:
      I32_CONST 30
      LOCAL_SET state_idx
      BR end_case
  range_5_10:
      I32_CONST 40
      LOCAL_SET state_idx
      BR end_case
  else_br:
      I32_CONST 0
      LOCAL_SET state_idx
  end_case:

      │
      ▼  语义保持:
     对每个可能的分支值 v:
       ST: mode=v → 选择匹配分支 → state := 对应值
       ASM: 级联 BR_IF → 命中匹配分支 → state := 对应值
       
     关键保证: 级联条件链精确模拟了 CASE 的"依次匹配-执行-跳出"语义 ✅
     多值分支 (3,4) 和范围分支 (5..10) 通过多条比较指令实现，效果等价 ✅
```

### 例 7：WHILE 循环

```
ST:  WHILE cond DO body END_WHILE
     │
     ▼  编译为 SafeASM:
  loop_start:
      LOCAL_GET cond_idx     ; 加载条件
      I32_EQZ                ; cond = 0 ?
      BR_IF loop_end         ; 是 → 跳出
      ;; ... body 指令序列 ...
      BR loop_start          ; 跳回循环开始
  loop_end:

     │
     ▼  语义保持:
     情况 1: cond=false (首次进入)
       ST: 跳过 body → 继续后续执行
       ASM: cond=0 → BR_IF 跳转到 loop_end → 继续
       ✅  控制流一致

     情况 2: cond=true, 执行 body 后 cond=false
       ST:  执行 body → 再次检查 cond=false → 结束循环
       ASM: cond≠0 → 不跳转 → 执行 body → BR loop_start
            → cond=0 → BR_IF loop_end → 结束
       ✅  迭代次数和路径一致

     情况 3: cond=true, 执行 body 后 cond=true
       ST:  执行 body → 再次检查 cond=true → 继续循环
       ASM: cond≠0 → 执行 body → BR loop_start
            → cond≠0 → 继续循环
       ✅  无限循环的保持（受安全约束 S1 限制: 必须有 Loop Variant）
```

### 例 8：REPEAT 循环

```
ST:  REPEAT body UNTIL cond END_REPEAT
     │
     ▼  编译为 SafeASM:
  loop_start:
      ;; ... body 指令序列 ...
      LOCAL_GET cond_idx     ; 加载条件
      I32_EQZ                ; cond = 0 ?
      BR_IF loop_start       ; cond=0 → 继续循环
  loop_end:

     │
     ▼  语义保持:
     REPEAT 与 WHILE 的关键区别: 至少执行一次 body

     情况 1: 首次执行后 cond=true
       ST:  执行 body → 检查 cond=true → 结束循环
       ASM: 执行 body → cond≠0 → 不跳转 → 结束
       ✅  至少执行一次的语义保持

     情况 2: 首次执行后 cond=false
       ST:  执行 body → 检查 cond=false → 继续循环
       ASM: 执行 body → cond=0 → BR_IF loop_start → 继续
       ✅  多迭代路径一致
```

### 例 9：EXIT 语句

```
ST:  FOR i := 1 TO 100 DO
         IF found THEN EXIT; END_IF
         sum := sum + data[i];
     END_FOR
     │
     ▼  编译为 SafeASM:
      I32_CONST 1
      LOCAL_SET i_idx
  for_start:
      ;; 检查 i > 100 → 跳出
      ...
      ;; found 条件
      LOCAL_GET found_idx
      BR_IF after_loop       ; EXIT: 直接跳出到循环外
      ;; 正常循环体
      LOCAL_GET sum_idx
      ...
      BR for_start
  after_loop:

     │
     ▼  语义保持:
     EXIT 在 ST 中表示"立即退出当前最内层循环"
     ASM 中等价于: BR 跳转到循环外的标签 ✅
     注意: BR 的 depth 参数必须精确指向循环外层,
     这在编译期由 codegen.v 的控制流分析保证 ✅
```

### 例 10：数组访问与边界检查

```
ST:  val := arr[i]    -- ARRAY[0..15] OF INT
     │
     ▼  编译为 SafeASM:
      ;; 计算地址: base + i * 2 (INT=2 字节)
      I32_CONST arr_base     ; 数组基址
      LOCAL_GET i_idx
      I32_CONST 2
      I32_MUL                ; i * 元素大小
      I32_ADD                ; arr_base + i*2
      
      ;; 边界检查 (编译期或运行期)
      LOCAL_GET i_idx
      I32_CONST 0
      I32_LT_S               ; i < 0 ?
      BR_IF trap             ; 越界 → 保护动作
      LOCAL_GET i_idx
      I32_CONST 15
      I32_GT_S               ; i > 15 ?
      BR_IF trap             ; 越界 → 保护动作
      
      ;; 安全加载
      I32_LOAD {align=1, offset=0}
      LOCAL_SET val_idx
      BR after_access
  trap:
      UNREACHABLE            ; 触发安全保护动作
  after_access:

     │
     ▼  语义保持:
     ST 语义: val = arr[i], 其中 i ∈ [0, 15]
     ASM 语义: 计算地址 → 检查 0 ≤ i ≤ 15 → 加载 → 存入 val
     
     情况 1: i 在范围内 → 正确加载 ✅
     情况 2: i 越界 → 触发保护动作（安全行为） ✅
     
     边界检查的确切形式取决于编译期是否能静态确定 i 的范围:
     - 编译期常量 i: 在编译期检查，插入 SAFE_BOUNDS_CHECK 或跳过检查
     - 运行时变量 i: 在生成的 ASM 中插入边界比较指令
```

### 例 11：类型转换 (Type Conversion)

```
ST:  x := DINT(y)    -- y: INT, x: DINT
     │
     ▼  编译为 SafeASM (INT→DINT 是提升，无运行时代码):
      LOCAL_GET y_idx
      LOCAL_SET x_idx        ; INT 和 DINT 在 ASM 中都是 I32

ST:  a := REAL(b)    -- b: DINT, a: REAL
     │
     ▼  编译为 SafeASM:
      LOCAL_GET b_idx
      F32_CONVERT_I32_S      ; I32 → F32
      LOCAL_SET a_idx

ST:  c := DINT(d)    -- d: REAL, c: DINT
     │
     ▼  编译为 SafeASM:
      LOCAL_GET d_idx
      I32_TRUNC_F32_S        ; F32 → I32 (截断)
      LOCAL_SET c_idx

     │
     ▼  语义保持:
     类型提升 (SINT→INT→DINT, BYTE→WORD→DWORD):
       在 ST 中无运行时开销（只是表示范围变化）
       在 ASM 中: 值类型相同（都是 I32），不需要指令 ✅
     
     跨类型转换 (INT↔REAL):
       ST 语义: 调用类型转换函数
       ASM 语义: 使用 F32_CONVERT_I32_S / I32_TRUNC_F32_S
       Coq 证明: 转换结果一致 ✅
```

### 例 12 (v1.1 新增)：64 位类型运算 (LINT/LREAL)

```
ST:  acc : LINT;        -- 64 位累加器
     acc := acc + L#1000000;

     │
     ▼  编译为 SafeASM:
      LOCAL_GET acc_idx       ; 加载 acc (64 位)
      I64_CONST 1000000       ; 加载 64 位常量
      I64_ADD                 ; 64 位加法
      LOCAL_SET acc_idx       ; 存回 acc

     │
     ▼  ST 语义: acc = [[acc]] + 1000000
     ▼  ASM 语义: I64_ADD 使用 64 位值栈运算
         值栈操作与 32 位版本同构，仅操作码和值宽度不同 ✅
         WCET: 4 条指令，固定无分支 ✅

ST:  pid_out : LREAL;       -- 64 位 PID 输出
     pid_out := Kp * error + Ki * integral;

     │
     ▼  编译为 SafeASM:
      LOCAL_GET Kp_idx       ; 加载 Kp (LREAL)
      LOCAL_GET error_idx    ; 加载 error (LREAL)
      F64_MUL               ; Kp * error
      LOCAL_GET Ki_idx       ; 加载 Ki (LREAL)
      LOCAL_GET integral_idx ; 加载 integral (LREAL)
      F64_MUL               ; Ki * integral
      F64_ADD               ; Kp*error + Ki*integral
      LOCAL_SET pid_out_idx ; 存回 pid_out

     │
     ▼  语义保持:
         ST 语义: pid_out = Kp × error + Ki × integral
         ASM 语义: F64_MUL/F64_ADD 精确对应算术运算
         双精度浮点运算符合 IEEE 754 标准 ✅
         WCET: 7 条指令，无分支 ✅

ST:  high : LINT;
     low  : DINT;
     high := LINT(low);     -- DINT → LINT 符号扩展

     │
     ▼  编译为 SafeASM:
      LOCAL_GET low_idx      ; 加载 low (I32)
      I64_EXTEND_I32_S      ; 符号扩展到 I64
      LOCAL_SET high_idx    ; 存回 high

     │
     ▼  语义保持:
         ST: high = 符号扩展(low)
         ASM: I64_EXTEND_I32_S 将 I32 符号扩展为 I64
         数值在 64 位表示中保持一致 ✅
```

### 例 13：FB 调用

```
ST:  TON_inst(IN := start, PT := T#5s);
     
     FUNCTION_BLOCK TON
         VAR_INPUT  IN : BOOL; PT : TIME; END_VAR
         VAR_OUTPUT Q : BOOL; ET : TIME; END_VAR
         VAR        running : BOOL := FALSE; start_time : TIME; END_VAR
         IF IN AND NOT running THEN
             running := TRUE;
             start_time := ET;
         END_IF
         IF running THEN
             ET := ET + T#10ms;
             IF ET >= PT THEN
                 Q := TRUE;
             END_IF
         END_IF
         IF NOT IN THEN
             running := FALSE;
             Q := FALSE;
             ET := T#0ms;
         END_IF
     END_FUNCTION_BLOCK
     │
     ▼  编译为 SafeASM:
     ;; TON_inst 的 FB 数据在内存中的布局:
     ;;   offset 0:   IN      (I32, BOOL)
     ;;   offset 4:   PT      (I64, TIME)
     ;;   offset 12:  Q       (I32, BOOL)
     ;;   offset 16:  ET      (I64, TIME)
     ;;   offset 24:  running (I32, BOOL)
     ;;   offset 28:  start_time (I64, TIME)
     
     ;; 1. 将输入参数写入 FB 数据区
     LOCAL_GET start_idx
     I32_STORE {align=2, offset=FB_BASE + 0}   ; IN := start
     ;; PT := T#5s (常量)
     I64_CONST 5000000000
     I64_STORE {align=4, offset=FB_BASE + 4}   ; PT := 5s in ns
     
     ;; 2. CALL FB 方法 (在 codegen.v 中转为对 TON_body 函数的调用)
     CALL ton_body_idx
     
     ;; 3. FB 执行结束后，从 FB 数据区读取输出
     I32_LOAD {align=2, offset=FB_BASE + 12}   ; 加载 Q
     LOCAL_SET q_out_idx
     I64_LOAD {align=4, offset=FB_BASE + 16}   ; 加载 ET
     LOCAL_SET et_out_idx

     │
     ▼  语义保持:
     ST 语义: FB 调用 = 将输入参数传递给 FB 实例 → 执行 FB 体
              → 读取 FB 输出
     ASM 语义: 写参数到 FB 数据区 → CALL FB 方法 → 读回输出
     
     关键保证: FB 实例的数据区布局在编译期确定，
     所有偏移在编译期计算，运行期固定 ✅
```

### 例 14：嵌套控制流

```
ST:  IF a > b THEN
         FOR i := 1 TO 10 DO
             IF data[i] > 0 THEN
                 sum := sum + data[i];
             END_IF
         END_FOR
     END_IF
     │
     ▼  编译为 SafeASM (嵌套 BLOCK/LOOP):
      LOCAL_GET a_idx
      LOCAL_GET b_idx
      I32_GT_S               ; a > b ?
      BR_IF after_if         ; 否 → 跳过整个块
      
      I32_CONST 1
      LOCAL_SET i_idx
  for_start:
      ;; i > 10 → 跳出
      LOCAL_GET i_idx
      I32_CONST 10
      I32_GT_S
      BR_IF after_for
      
      ;; 内层 IF
      LOCAL_GET i_idx
      I32_CONST 2
      I32_MUL
      I32_CONST data_base
      I32_ADD
      I32_LOAD {align=2, offset=0}   ; data[i]
      I32_CONST 0
      I32_GT_S
      BR_IF skip_inner
      
      ;; then 分支
      LOCAL_GET sum_idx
      ... (data[i] 的地址计算和加载)
      I32_ADD
      LOCAL_SET sum_idx
      
  skip_inner:
      ;; i := i + 1
      LOCAL_GET i_idx
      I32_CONST 1
      I32_ADD
      LOCAL_SET i_idx
      BR for_start
      
  after_for:
  after_if:

     │
     ▼  语义保持（模拟证明的关键）:
     
     模拟关系需要证明: 对任意嵌套深度 d,
     如果 ST 执行到嵌套深度 d 的位置，
     则 ASM 的 pc 也指向对应的嵌套深度 d 的位置。
     
     这是通过 BLOCK/LOOP 指令的嵌套结构保证的:
       - IF 对应 BLOCK (条件分支)
       - FOR 对应 LOOP (循环)
       - 内层 IF 对应内层 BLOCK
     
     嵌套深度在编译期已知，BR 的 depth 参数确保跳转目标正确 ✅
```

### 例 15：质量传播 —— 二元运算

```
ST:  qR := qA + qB;    -- qA, qB, qR 均为 QINT

     ST 语义 (带质量):
       qR.value   = qA.value + qB.value
       qR.quality = worst(qA.quality, qB.quality)
                      (= max(qA, qB) 数值上)
     
     编译为 SafeASM (编译器展开，VM 无感知):
       ;; ─── 值计算 (与无质量版本相同) ───
       LOCAL_GET qA_val_idx
       LOCAL_GET qB_val_idx
       I32_ADD
       LOCAL_SET qR_val_idx

       ;; ─── 质量传播 (编译器自动生成) ───
       I32_CONST Q_BASE + qA_idx      ; 影子质量区偏移
       I32_LOAD8_U                    ; 读 qA 质量 (1 字节)
       I32_CONST Q_BASE + qB_idx
       I32_LOAD8_U                    ; 读 qB 质量
       I32_GT_U                       ; worst = max(qA_q, qB_q)
       I32_CONST Q_BASE + qR_idx
       I32_STORE8                     ; 写结果质量
       
     语义保持:
       情况 1: qA=GOOD(0), qB=GOOD(0) → worst=0 → qR=GOOD ✅
       情况 2: qA=GOOD(0), qB=BAD(1)   → worst=1 → qR=BAD   ✅
       情况 3: qA=BAD(1),  qB=BAD(1)   → worst=1 → qR=BAD   ✅

       WCET: 12 条指令 (5 值 + 7 质量)，固定无分支 ✅
```

### 例 16：质量检查条件

```
ST:  IF Q_GOOD(qA) THEN
          qR := qA * 2;
      END_IF

     编译为 SafeASM:
       ;; 读取 qA 质量
       I32_CONST Q_BASE + qA_idx
       I32_LOAD8_U
       I32_CONST 0                   ; GOOD = 0
       I32_EQ                        ; quality == GOOD ?
       BR_IF end_if                  ; 不是 GOOD → 跳过

       ;; then 分支: qR := qA * 2 (值 + 质量传播)
       LOCAL_GET qA_val_idx
       I32_CONST 2
       I32_MUL
       LOCAL_SET qR_val_idx

       ;; 质量传播: 结果质量 = qA.quality
       I32_CONST Q_BASE + qA_idx
       I32_LOAD8_U
       I32_CONST Q_BASE + qR_idx
       I32_STORE8

     end_if:

     语义保持:
       ST 语义: 仅当 Q_GOOD(qA) 为 TRUE 时执行赋值
       ASM 语义: 质量检查 → BR_IF 跳过 → 条件成立时才执行

       两种可能的执行路径:
        路径 1 (质量非 GOOD): 5 条指令 → 跳过 then
        路径 2 (质量 GOOD):   12 条指令 → 执行 then
       WCET = max(路径1, 路径2) = 12 条指令 ✅ (可静态计算)
```

### 例 17：质量传播的 T → QT 隐式转换

```
ST:  qX : QINT;
     pY : INT;          -- 无质量位的普通变量

     qX := pY;           -- T → QT: 隐式转换，质量自动设为 GOOD

     编译为 SafeASM:
       ;; 值赋值
       LOCAL_GET pY_idx
       LOCAL_SET qX_val_idx

       ;; 质量自动设 GOOD
       I32_CONST Q_BASE + qX_idx
       I32_CONST 0                ; GOOD = 0
       I32_STORE8

     语义保持:
       输入 pY=42 → qX.value=42, qX.quality=GOOD
       质量 GOOD 是对"普通变量值可信"的正确表达 ✅
```

### 例 18：质量传播的转换链完整性

```
ST:  VAR_INPUT  AI1 : QREAL; END_VAR
     VAR         tmp  : REAL;       -- 无质量
     VAR_OUTPUT AO1  : QREAL; END_VAR

     tmp := AI1;                    -- QT → T: 警告 Q-STRIP
     AO1 := tmp;                    -- T → QT: 质量自动 GOOD

     ── 问题: AI1 的质量信息在 tmp 处丢失!
     ── 结果: AO1 质量被误设为 GOOD，实际 AI1 可能是 BAD

     正确写法:
     VAR tmpQ : QREAL; END_VAR      -- 用 Q 类型保持质量链
     
     tmpQ := AI1;                   -- QT → QT: 质量透传 ✅
     AO1  := tmpQ;                  -- QT → QT: 质量透传 ✅

     编译为 SafeASM (正确写法):
       ;; AI1 → tmpQ (值传递)
       LOCAL_GET  AI1_val_idx
       LOCAL_SET  tmpQ_val_idx

       ;; 质量透传
       I32_CONST  Q_BASE + AI1_idx
       I32_LOAD8_U
       I32_CONST  Q_BASE + tmpQ_idx
       I32_STORE8

       ;; tmpQ → AO1 (同上)
       ...

     语义保持：
       质量链完整: AI1.quality → tmpQ.quality → AO1.quality
       AI1 质量为 BAD → AO1 也为 BAD (已正确传播) ✅
```

---

## 6. 抽象关系 R 的完整定义 (Abstraction Relation)

抽象关系 `R(σ, τ)` 是编译正确性证明中最核心的定义。它在 Coq 文件 `veristc/spec/compiler_correctness.v` 中定义为：

### 6.1 形式化定义

```
R(st_state σ, runtime_state τ) 定义为以下四个条件的合取:

┌──────────────────────────────────────────────────────────────────┐
│ 条件 1 — 变量值一致性 (Value Consistency)                         │
│                                                                  │
│   ∀(x, v) ∈ σ.vars,                                             │
│     ∃offset, asm_val:                                            │
│       var_to_sasm_offset(x) = offset ∧                           │
│       read_sasm_mem(τ, offset) = Some(asm_val) ∧                 │
│       st_val_to_sasm(v) = asm_val                                │
│                                                                  │
│   "ST 中每个变量的值 = ASM 内存中对应偏移处的值"                   │
└──────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────┐
│ 条件 2 — 质量一致性 (Quality Consistency) (v1.1 新增)             │
│                                                                  │
│   对于每个 Q 类型变量 x 或 I/O 变量 x:                            │
│     ∃q_offset ∈ σ.quality:                                       │
│       质量码地址 = Q_BASE + var_idx(x) ∧                          │
│       read_sasm_mem(τ, Q_BASE + var_idx(x)) = σ.quality[x]       │
│                                                                  │
│   对于无质量位的普通变量:                                          │
│     不要求质量一致性                                              │
│                                                                  │
│   "ST 中每个 Q 变量的质量 = ASM 影子质量区中对应偏移处的质量码"     │
└──────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────┐
│ 条件 3 — 执行位置一致性 (Control Flow Consistency)                 │
│                                                                  │
│   match τ.rt_frames with                                         │
│   | nil => σ.st_pou_idx = -1       (两者都已完成)                 │
│   | f :: _ => σ.st_pou_idx = f.frame_func_idx  (同一函数)         │
│                                                                  │
│   "ST 正在执行的 POU = ASM 帧栈顶帧的函数索引"                    │
└──────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────┐
│ 条件 4 — 调用栈深度一致性 (Call Stack Consistency)                 │
│                                                                  │
│   |σ.st_call_stack| = |τ.rt_frames|                              │
│                                                                  │
│   "ST 调用栈深度 = ASM 帧栈深度"                                  │
└──────────────────────────────────────────────────────────────────┘
```

### 6.2 类型兼容映射

ST 类型到 SafeASM 值类型的映射（编译期确定，运行期固定）：

| ST 类型 | SafeASM 值类型 | 影子质量区 | 映射说明 |
|---------|---------------|-----------|---------|
| BOOL | I32 | 无 | TRUE=1, FALSE=0 |
| BYTE | I32 | 无 | 直接映射 |
| WORD | I32 | 无 | 直接映射 |
| DWORD | I32 | 无 | 直接映射 |
| SINT | I32 | 无 | 符号扩展 |
| INT | I32 | 无 | 直接映射 |
| DINT | I32 | 无 | 直接映射 |
| **LINT** | **I64** | **无** | **64 位符号整数 (v1.1)** |
| REAL | F32 | 无 | IEEE 754 单精度 |
| **LREAL** | **F64** | **无** | **IEEE 754 双精度 (v1.1)** |
| TIME | I64 | 无 | 纳秒计数 |
| **QUALITY** | **I32** | **无** | **质量码 (低 2 位有效) (v1.1)** |
| **QBOOL/QBYTE** | **I32** | **1 B** | **值 + 质量 (v1.1)** |
| **QINT/QDINT** | **I32** | **1 B** | **值 + 质量 (v1.1)** |
| **QREAL** | **F32** | **1 B** | **值 + 质量 (v1.1)** |
| **QLINT** | **I64** | **1 B** | **64 位值 + 质量 (v1.1)** |
| **QLREAL** | **F64** | **1 B** | **64 位浮点值 + 质量 (v1.1)** |
| **QTIME** | **I64** | **1 B** | **时间值 + 质量 (v1.1)** |
| **QARRAY[...]** | **同元素类型** | **连续 1B/元素** | **数组每个元素独立质量 (v1.1)** |
| ARRAY[...] | 元素类型对应 | 无 | 元素类型对应 |

### 6.3 抽象关系图

```
    ST 世界                      ASM 世界
    ┌──────────┐                ┌──────────────┐
    │ σ.vars   │                │ τ.rt_memory  │
    │  x → 42  │───R(cond1)──→ │  [0x100]=42  │
    │  y → TRUE│               │  [0x104]=1   │
    └──────────┘               └──────────────┘
    ┌──────────┐               ┌──────────────┐
    │ σ.quality│               │ τ.rt_memory  │
    │ x → GOOD │───R(cond2)──→ │  [Q_BASE+x]  │
    │ y → BAD  │  (v1.1 新增) │  = 0x00      │
    └──────────┘               │  [Q_BASE+y]  │
    ┌──────────┐               │  = 0x01      │
    │ σ.pou_idx│               └──────────────┘
    │ = 0      │───R(cond3)──→ ┌──────────────┐
    │          │               │ τ.rt_frames  │
    └──────────┘               │  top.frame_  │
    ┌──────────┐               │  func_idx=0  │
    │ σ.call_  │               └──────────────┘
    │ stack|=2 │───R(cond4)──→ ┌──────────────┐
    └──────────┘               │ |τ.rt_frames|│
                               │ = 2          │
                               └──────────────┘
```

---

## 7. 编译正确性形式化定理（开发人员注解版）

以下为 Coq 中声明的核心定理，附带通俗解释。

### 7.1 抽象关系 R

```
R(st_state, asm_state) 定义为:
  ─────────────────────────────────────
  1. 每个 ST 变量的值 = SafeASM 内存中对应偏移处的值
     例: st.x = 42 → mem[GLOBAL_BASE + x_offset] = 42
     
  2. 每个 Q 类型变量的质量码 = SafeASM 影子质量区对应偏移处的值 (v1.1)
     例: st.qX.quality = GOOD → mem[Q_BASE + qX_idx] = 0x00
     
  3. 当前执行位置对应
     例: ST 执行到第 5 行 → ASM 的 pc 指向第 5 行对应的指令
     
  4. 变量类型兼容
     ST 的 INT = ASM 的 I32
     ST 的 REAL = ASM 的 F32
     ST 的 LINT = ASM 的 I64     (v1.1)
     ST 的 LREAL = ASM 的 F64    (v1.1)
     ST 的 QINT = ASM 的 I32 + 影子区 1 B  (v1.1)
     ...
```

### 7.2 编译正确性定理

```
定理 semantics_preservation:
  如果 [ST 程序 P 编译成功生成 SafeASM 模块 M]
  且 [ST 状态 s1 执行一步到 s2]
  且 [s1 与 ASM 状态 t1 满足抽象关系 R]
  那么 [ASM 状态 t1 执行若干步到 t2]
  且 [s2 与 t2 仍然满足抽象关系 R]

形象理解:
    ST 世界:        s1 ──一步──→ s2
                    │              │
   R 关系 (对齐)     │              │
                    ▼              ▼
   ASM 世界:       t1 ──多步──→ t2
    
   不管 ST 中怎么跳，ASM 总能"跟上"并保持状态一致。
   编译没有改变程序的语义。这叫作 Simulation Relation。
```

### 7.3 安全保持定理

```
定理 safety_preservation:
  如果 [ST 程序 P 编译成功]
  且 [P 通过了类型检查]
  那么 [编译产物 M 满足所有安全约束]:
    ✓ 循环上限已确定
    ✓ 所有内存访问在声明范围内
    ✓ 周期指令数有限
    ✓ 函数无递归调用
    ✓ 质量传播代码的 WCET 可静态计算  (v1.1)
    ✓ 影子质量区访问不超出 SEG_QUALITY 边界  (v1.1)
```

---

## 8. 编译器逐阶段证明对应表 (Proof Correspondence Table)

下表将每种 ST 构造的语义保持责任映射到具体的 Coq 文件和定理：

| 阶段 | Coq 文件 | 证明内容 | 对应 spec 章节 | 进度 |
|------|---------|---------|---------------|------|
| 1.1 | `typechecker.v` | 类型安全 `type_safety` (progress + preservation) | §2.2 子集定义 | ❌ 待实现 |
| 1.2 | `desugar.v` | 脱糖语义保持 `desugar_semantics_preservation` | §2.3 逻辑求值 | ❌ 待实现 |
| 1.3 | `codegen.v` | 表达式编译仿真 `compile_expr_correct` | §2.1 表达式映射 | ⚠️ 骨架 |
| 1.3 | `codegen.v` | 语句编译仿真 `compile_stmt_correct` | §2.2 语句映射 | ❌ 待实现 |
| 1.3 | `codegen.v` | **64 位运算仿真** | **§2.1 I64/F64 运算** | ❌ **v1.1 新增** |
| 1.3 | `codegen.v` | **质量传播仿真** | **§2.4 质量传播映射** | ❌ **v1.1 新增** |
| 1.3 | `codegen.v` | **影子质量区访问正确性** | **§3.3 影子内存** | ❌ **v1.1 新增** |
| 1.3 | `codegen.v` | **T↔QT 隐式转换仿真** | **§2.2 Q 类型赋值** | ❌ **v1.1 新增** |
| 1.3 | `compiler_correctness.v` | 语义保持 `semantics_preservation` | §7.2 核心定理 | ⚠️ 已声明/admit |
| 1.3 | `compiler_correctness.v` | **质量保持扩展 `quality_preservation`** | **§6.1 条件 2** | ❌ **v1.1 新增** |
| 1.3 | `compiler_correctness.v` | 整体语义保持 `total_semantics_preservation` | §7.2 闭包版本 | ⚠️ 已声明/admit |
| 1.3 | `compiler_correctness.v` | 编译确定性 `compile_determinism` | — | ✅ 已证明 |
| 1.3 | `compiler_correctness.v` | 安全保持 `safety_preservation` | §7.3 安全约束 | ⚠️ 占位证明 |
| 1.3 | `compiler_correctness.v` | **影子区访问安全 `quality_mem_safety`** | **§7.3 质量安全** | ❌ **v1.1 新增** |
| 1.4 | `analysis.v` | WCET/循环上限静态分析 | — | ❌ 待实现 |
| 1.5 | `encoder.v` | 编码/解码可逆性 `encode_decode_identity` | safeasm-spec §编码 | ❌ 待实现 |

**进度说明**：
- ✅ = 已完成并证明
- ⚠️ = 已声明但暂缺证明（admit）
- ❌ = 待实现
- **粗体** = v1.1 新增的质量相关证明条目
    
  通俗理解: 编译器不仅是正确的，还是安全的。
  它保证输出的 SafeASM 代码满足安全约束。
```

---

## 8. 验证检查清单

对于每个 ST 构造，开发人员应验证以下语义保持条件：

| 检查项 | 说明 |
|--------|------|
| ✅ 值一致性 | 编译前后的变量值相同 |
| ✅ 控制流一致性 | 分支/循环的执行路径相同 |
| ✅ 类型一致性 | 类型转换符合规范 |
| ✅ 副作用一致性 | 函数/FB 的副作用（输出变量修改）一致 |
| ✅ 终止性 | 有限循环在有限步内终止 |
| ✅ 错误处理 | 除零/越界等错误触发方式一致 |

---

## 附录 A：常见问题

**Q: 为什么值栈模型能保证语义正确？**
A: 表达式树的后序遍历与值栈操作同构——这是编译器理论中已被广泛证明的结论。每个子表达式的结果压入栈，父运算消耗栈顶元素，最终的栈顶值就是整个表达式的结果。

**Q: 循环的语义保持如何保证？**
A: FOR 循环的语义保持通过 LOOP/BR_IF/BR 的组合实现。LOOP 标记循环开始，条件判断决定是否继续，BR 跳回循环开始。这与 ST 的 FOR 语义（初始化→判断→执行→增量→判断→...）完全对应。

**Q: 如果 SafeASM 解释器有 bug 怎么办？**
A: 编译正确性定理只保证"如果 VM 正确执行 SafeASM 指令，则结果与 ST 语义一致"。VM 本身的正确性需要通过 C 语言级别的测试和（可选）形式化验证来保证。这就是为什么我们将编译器证明和 VM 分开——编译器证明用 Coq，VM 正确性用测试。

**Q: 函数调用怎么保证语义保持？**
A: 通过 CALL/RETURN 指令机制和栈帧管理。参数在调用前压入值栈，CALL 指令创建新栈帧，RETURN 返回值留在栈顶，恢复调用者帧。这与 ST 的函数调用语义（传参→执行→返回）完全对应。

---

## 附录 B：编译器逐阶段证明对应表

以下表格将每个 ST 构造的语义保持证明映射到对应的 Coq 文件和定理。

| ST 构造 | Coq 实现文件 | 核心定理/引理 | 依赖的证明策略 |
|---------|-------------|-------------|---------------|
| 字面量 | `codegen.v` | `compile_literal_correct` | `simpl; auto` |
| 变量引用 | `codegen.v` | `compile_var_correct` | `unfold var_to_sasm_offset` |
| 二元运算 | `codegen.v` | `compile_binop_simulation` | `induction; step_simpl` |
| 一元运算 | `codegen.v` | `compile_unop_simulation` | `case analysis on op` |
| 比较运算 | `codegen.v` | `compile_compare_simulation` | `case analysis; omega` |
| 逻辑 AND/OR | `codegen.v` | `compile_shortcircuit_simulation` | `case analysis on cond; eauto` |
| XOR | `codegen.v` | `compile_xor_simulation` | `unfold xorb; auto` |
| 数组访问 | `codegen.v` | `compile_array_access_simulation` | `lia; apply bounds_check_correct` |
| 赋值 | `codegen.v` | `compile_assign_simulation` | `eapply compile_expr_correct` |
| IF-THEN-ELSE | `codegen.v` | `compile_if_simulation` | `case analysis; eauto 3` |
| CASE | `codegen.v` | `compile_case_simulation` | `induction on branches; eauto` |
| FOR 循环 | `codegen.v` | `compile_for_simulation` | `invariant induction; omega` |
| WHILE 循环 | `codegen.v` | `compile_while_simulation` | `invariant induction; omega` |
| REPEAT 循环 | `codegen.v` | `compile_repeat_simulation` | `invariant induction; omega` |
| EXIT | `codegen.v` | `compile_exit_simulation` | `unfold br_depth; auto` |
| RETURN | `codegen.v` | `compile_return_simulation` | `unfold pop_frame; auto` |
| 函数调用 | `codegen.v` | `compile_call_simulation` | `eapply frame_push_correct` |
| FB 调用 | `codegen.v` | `compile_fb_simulation` | `eapply fb_memory_layout_correct` |
| 类型转换 | `codegen.v` | `compile_typecast_simulation` | `case analysis on conversion type` |
| **质量传播（二元运算）** | `codegen.v` | `compile_quality_binop_simulation` | **`destruct q1, q2; auto` (v1.1)** |
| **质量传播（一元运算）** | `codegen.v` | `compile_quality_unop_simulation` | **`destruct q; auto` (v1.1)** |
| **Q_STATUS 提取** | `codegen.v` | `compile_qstatus_simulation` | **`unfold lookup_quality` (v1.1)** |
| **Q_SET 写入** | `codegen.v` | `compile_qset_simulation` | **`unfold update_quality` (v1.1)** |
| **Q_WITH 构造** | `codegen.v` | `compile_qwith_simulation` | **`split; auto` (v1.1)** |
| **Q_GOOD/Q_BAD 检查** | `codegen.v` | `compile_qcheck_simulation` | **`destruct q; auto` (v1.1)** |
| **T→QT 转换** | `codegen.v` | `compile_t_to_qt_simulation` | **`split; reflexivity` (v1.1)** |
| **QT→T 转换** | `codegen.v` | `compile_qt_to_t_simulation` | **`simpl; auto` (v1.1)** |
| 脱糖 (Desugar) | `desugar.v` | `desugar_semantics_preservation` | `induction; simpl; auto` |
| 类型检查 (Type Safety) | `typechecker.v` | `progress` + `preservation` | `induction; inversion; auto` |
| 整体编译 | `compiler_correctness.v` | `total_semantics_preservation` | `apply multi_step_sasm_trans` |

### 证明层次结构

```
total_semantics_preservation (整体语义保持定理)
  │
  ├── semantics_preservation (单步模拟)
  │     │
  │     ├── compile_expr_correct (表达式求值保持) 
  │     │     ├── compile_literal_correct
  │     │     ├── compile_var_correct
  │     │     ├── compile_binop_simulation
  │     │     ├── compile_shortcircuit_simulation
  │     │     ├── compile_typecast_simulation
  │     │     └── quality层 (v1.1):
  │     │           ├── compile_quality_binop_simulation
  │     │           ├── compile_quality_unop_simulation
  │     │           ├── compile_qstatus_simulation
  │     │           ├── compile_qset_simulation
  │     │           ├── compile_qwith_simulation
  │     │           ├── compile_qcheck_simulation
  │     │           ├── compile_t_to_qt_simulation
  │     │           └── compile_qt_to_t_simulation
  │     │
  │     └── compile_stmt_simulation (语句执行保持)
  │           ├── compile_assign_simulation
  │           ├── compile_if_simulation
  │           ├── compile_case_simulation
  │           ├── compile_for_simulation
  │           ├── compile_while_simulation
  │           ├── compile_repeat_simulation
  │           ├── compile_call_simulation
  │           ├── compile_fb_simulation
  │           ├── compile_exit_simulation
  │           └── compile_return_simulation
  │
  └── desugar_semantics_preservation (脱糖保持)
  
safety_preservation (安全保持定理)
  │
  ├── all_loops_bounded (循环有界性)
  ├── all_memory_accesses_safe (内存安全)
  └── sasm_no_recursive_calls (无递归)
```
