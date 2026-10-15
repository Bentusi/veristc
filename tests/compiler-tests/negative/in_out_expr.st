(* ================================================================
   negative/in_out_expr.st  --  VAR_IN_OUT 实参必须是简单变量名

   别名需要一个稳定的存储位置，表达式/常量没有地址可取，
   故 a1.ACC := SHARED + 1 必须被拒绝。
   ================================================================ *)

VAR_GLOBAL
  SHARED : DINT;
  a1 : ACCUM;
END_VAR

FUNCTION_BLOCK ACCUM
VAR_IN_OUT
  ACC : DINT;
END_VAR
  ACC := ACC + 1;
END_FUNCTION_BLOCK

PROGRAM MAIN
  a1(ACC := SHARED + 1);
END_PROGRAM
