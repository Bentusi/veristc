(* ================================================================
   negative/in_out_unbound.st  --  VAR_IN_OUT 端口必须被绑定

   端口不绑定就没有别名目标（既无初值可拷贝，也无副本语义可言），
   与 IEC 要求一致：必须显式绑定到调用方存储。
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
  a1();
END_PROGRAM
