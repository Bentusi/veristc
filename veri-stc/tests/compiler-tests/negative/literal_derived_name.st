(* ================================================================
   negative/literal_derived_name.st -- 派生名不可书写

   expand_instances 产出的扁平全局名形如 a1#Q（'#' 为保留分隔符）。
   标识符文法是 字母 (字母|数字|_)*，不含 '#' ⇒ 源码里写 a1#Q 只能
   在词法阶段失败，用户无法伪造出一个"看起来像派生名"的名字去和
   真实派生名抢同一槽位，也不必再靠命名约定避免 a1_Q 这类碰撞。

   合法的字段访问写法是 IEC 点号 a1.Q，由 parser 融合为 a1#Q。
   ================================================================ *)

VAR_GLOBAL
  a1 : LATCH;
  x : DINT;
END_VAR

FUNCTION_BLOCK LATCH
VAR_OUTPUT
  Q : DINT;
END_VAR
  Q := 1;
END_FUNCTION_BLOCK

PROGRAM MAIN
  x := a1#Q;
END_PROGRAM
