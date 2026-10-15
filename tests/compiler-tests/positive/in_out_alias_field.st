(* ================================================================
   positive/in_out_alias_field.st  --  别名目标可以是实例数据字段

   a2.ACC 绑定到 a1_LAST（expand_instances 展开出的扁平全局字段），
   即"跨实例逐引用"：a2 的写直接落在 a1 的输出字段存储上，
   与 a1 自己的读写共享同一地址。合法 ⇒ 编译器必须接受。
   ================================================================ *)

VAR_GLOBAL
  t : DINT;
  tick : DINT;
  a1 : FB_INC;
  a2 : FB_INC;
END_VAR

FUNCTION_BLOCK FB_INC
VAR_INPUT
  K : DINT;
END_VAR
VAR_OUTPUT
  LAST : DINT;
END_VAR
VAR_IN_OUT
  ACC : DINT;
END_VAR
  LAST := ACC;
  ACC := ACC + K;
END_FUNCTION_BLOCK

PROGRAM MAIN
  tick := CycleCounter();
  t := tick;
  a1(ACC := t, K := 1);
  a2(ACC := a1_LAST, K := 5);
  PRINT('t', t, a1_LAST, a2_LAST);
END_PROGRAM
