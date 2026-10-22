(* ================================================================
   negative/qualified_output_write.st -- 封装：输出只能由 FB 体写

   VAR_OUTPUT 是 FB 对外的只读结果。外部写 a1.Q 会在 FB 下一次执行之前
   篡改其结论，使"输出由算法决定"这条安全论证失效（同理 VAR_INPUT 由
   调用点绑定，也不能在体外的表达式里直接读写）。

   检查在 prepare_program 之后进行（派生名此时才存在），诊断 KIND=access
   并以 VAR=a1#Q 指认被篡改的字段。
   ================================================================ *)

VAR_GLOBAL
  a1 : LATCH;
END_VAR

FUNCTION_BLOCK LATCH
VAR_INPUT
  K : DINT;
END_VAR
VAR_OUTPUT
  Q : DINT;
END_VAR
  Q := K;
END_FUNCTION_BLOCK

PROGRAM MAIN
  a1(K := 3);
  a1.Q := 99;
END_PROGRAM
