(* ================================================================
   negative/qualified_internal_read.st -- 封装：内部状态对外不可见

   FB 的 VAR（实例持久状态，此处 C）是 FUNCTION_BLOCK 的私有内容：
   外部只能经 VAR_OUTPUT / VAR_IN_OUT 观察和交互。写 a1.C 会让调用方
   绕过 FB 的算法直接读内部计数器，多实例/维护场景下等价于破坏封装。

   expand_instances 本就不为 D_INPUT/D_IN_OUT 生成全局，但会为内部 VAR
   生成可写的扁平全局（FB 体内要读写它）；因此"外部不得引用"必须由
   访问规则单独把关 —— 诊断 KIND=access，VAR=a1#C 指认被泄漏的字段。
   ================================================================ *)

VAR_GLOBAL
  a1 : LATCH;
  x : DINT;
END_VAR

FUNCTION_BLOCK LATCH
VAR_INPUT
  K : DINT;
END_VAR
VAR_OUTPUT
  Q : DINT;
END_VAR
VAR
  C : DINT;
END_VAR
  C := C + 1;
  Q := K;
END_FUNCTION_BLOCK

PROGRAM MAIN
  a1(K := 3);
  x := a1.C;
END_PROGRAM
