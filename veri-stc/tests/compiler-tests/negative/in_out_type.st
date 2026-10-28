(* ================================================================
   negative/in_out_type.st  --  VAR_IN_OUT 两侧类型必须完全一致

   别名不经过隐式转换（同一块存储被两侧按同一宽度读写），
   且解引用指令按 4 字节定宽访问，故 INT(16 位) 目标必须拒绝。
   ================================================================ *)

VAR_GLOBAL
  SMALL : INT;
  a1 : ACCUM;
END_VAR

FUNCTION_BLOCK ACCUM
VAR_IN_OUT
  ACC : DINT;
END_VAR
  ACC := ACC + 1;
END_FUNCTION_BLOCK

PROGRAM MAIN
  a1(ACC := SMALL);
END_PROGRAM
