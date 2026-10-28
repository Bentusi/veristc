(* ================================================================
   cli/two_access_violations.st -- 一次编译报出多条诊断

   G0 产出物 1 的验收夹具：MAIN 里同时有两处封装违规（读内部 VAR a1.C、
   写 VAR_OUTPUT a1.Q）。文本 API 仍只渲染第一条（既有 71 项断言依赖其
   逐字输出），--json 必须把两条都吐出来，且首条与文本那条完全同构。
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
  a1.Q := 9;
END_PROGRAM
