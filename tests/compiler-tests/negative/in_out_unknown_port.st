(* ================================================================
   negative/in_out_unknown_port.st  --  调用只能绑定已声明端口

   FB_ACC 只声明了 ACC，调用点写 NOPE := SHARED 属于拼写/绕过声明，
   在逐引用端口上尤其危险（会把地址压进错误的槽位）。
   ================================================================ *)

VAR_GLOBAL
  SHARED : DINT;
  a1 : FB_ACC;
END_VAR

FUNCTION_BLOCK FB_ACC
VAR_IN_OUT
  ACC : DINT;
END_VAR
  ACC := ACC + 1;
END_FUNCTION_BLOCK

PROGRAM MAIN
  a1(ACC := SHARED, NOPE := SHARED);
END_PROGRAM
