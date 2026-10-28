(* p07 [XFAIL-后端缺口]: REAL 浮点算术。
   spec 要求 F32_ADD/F32_CMP 类型导向降级；当前 global_codegen.v 对一切
   二元运算统一发 I32 指令 → 结果必然错误。期望 ok=1。 *)
PROGRAM MAIN
VAR
  a : REAL;
  b : REAL;
  ok : DINT;
END_VAR
  a := 1.5;
  b := a + 2.25;
  ok := 0;
  IF (b > 3.5) AND (b < 4.0) THEN
    ok := 1;
  END_IF;
  PRINT('p07 ok=', ok, '\n');
END_PROGRAM
