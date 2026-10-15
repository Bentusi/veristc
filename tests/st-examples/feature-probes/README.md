# feature-probes — SafeST 特性面端到端探针矩阵

每个探针只压一条语言/后端特性通道，`ST → veristc → .sasm → svm` 全管线
运行，stdout 与 `golden/` 逐行比对。目的：把"规范声称支持"与"实编译
管线（global_codegen I32 后端）真正可用"之间的差值显式化。

## 矩阵

| 探针 | 特性 | 状态 | 说明 |
|------|------|------|------|
| p01_case | CASE 多分支/值表/范围/ELSE | PASS | 依赖 parser 修复（分支头收束，2026-09-21） |
| p02_for | FOR 常量界/BY 步长/嵌套 | PASS | 类型规则 TS_for_int：环变量必须 INT |
| p03_while_repeat | WHILE 收敛 + REPEAT-UNTIL | PASS | n=44 k=8 m=21 |
| p04_div_mod | 有符号 /、MOD | PASS | -17/5=-3、-17%5=-2（C 截断语义，与 Z.div/Z.rem 一致） |
| p05_xor_bits | 布尔 XOR / 算术位抽取 | PASS | AND/OR/XOR 类型规则仅 BOOL 域 |
| p06_latch_state | VAR_GLOBAL 跨周期锁存 + 迟滞 | PASS | 复位脉冲回环 t7→0, t8→1 |
| p07_real_arith | REAL 浮点 | **XFAIL-词法** | lexer 无小数字面量产生路径，`1.5` 不可解析 |
| p08_lint_arith | LINT 64 位算术 | **XFAIL-后端** | global_codegen 全 I32；判据用除法破坏环同态 |
| p09_array_ops | 静态数组 | **XFAIL-类型/后端** | 数组访问无元素宽度缩放；全局数组基址取内容非地址 |
| p10_quality_ops | Q 类型/质量算子 | **XFAIL-语法+后端** | parser 无 Q_* 算子产生式；CE_QUALITY_OP 仅透传数值 |
| p11_nested_fn | FUNCTION 多层内联 | PASS | Quad(Twice(x)) ≡ 4x |
| p12_divzero_trap | 除零 VM 陷阱 | PASS | t3 触发，VM_ERR_DIV_BY_ZERO(rc=3) |
| p13_in_out_alias | VAR_IN_OUT 逐引用别名 | PASS | v1.5：端口=调用方存储的别名，两实例共享 `shared`，`LAST` 仍各自独立 |

## 已知后端差值（探针暴露，待工程决策修复）

1. **词法**：`TK_REAL_LIT` 有 token 无产生路径 → REAL/LREAL 字面量不可达。
2. **语法**：`Q_STATUS/Q_SET/Q_WITH/...` 仅存在于关键字表，无表达式产生式。
3. **后端**：`global_codegen.v` 二元运算统一 I32，无类型导向 F32/F64/I64 降级；
   而已证明的 `codegen.v` 是类型导向的——两条管线能力不一致。
4. **后端**：数组地址 = `值 + idx`，无 `(idx-low)*width` 缩放，全局数组基址
   取的是内容；shadow quality memory 未实现。
5. **类型**：`T_And/T_Or/T_Xor` 只放行 BOOL，与 safest-spec 数据类型表中
   "WORD 位操作" 的宣称矛盾。

运行：`./run_feature_probes.sh`（PASS 组任何回退 = 回归；XFAIL 组若转 PASS
会提示"缺口已修复，请升级为 PASS 并补 golden"）。
