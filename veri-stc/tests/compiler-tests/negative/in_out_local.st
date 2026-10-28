(* ================================================================
   negative/in_out_local.st  --  VAR_IN_OUT 别名目标不能是调用方局部

   MAIN 的 tick 是帧局部槽位（不在可寻址线性内存中），取不到地址，
   因此不能作为 a1.ACC 的别名目标。检查层必须以 alias 诊断拒绝。
   ================================================================ *)

VAR_GLOBAL
  a1 : ACCUM;
END_VAR

FUNCTION_BLOCK ACCUM
VAR_IN_OUT
  ACC : DINT;
END_VAR
  ACC := ACC + 1;
END_FUNCTION_BLOCK

PROGRAM MAIN
VAR
  tick : DINT;
END_VAR
  a1(ACC := tick);
END_PROGRAM
