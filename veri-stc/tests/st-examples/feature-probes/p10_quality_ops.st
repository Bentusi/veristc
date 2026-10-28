(* p10 [XFAIL-后端缺口]: 质量算子与质量传播。
   spec: Q_WITH(TRUE,BAD) 构造坏质量值，Q_GOOD 应为 FALSE。
   当前 CE_QUALITY_OP 仅透传数值参数，质量语义在实编译后端不存在 → 输出 1。
   期望 g=0。 *)
PROGRAM MAIN
VAR
  q : QBOOL;
  g : DINT;
END_VAR
  q := Q_WITH(TRUE, BAD);
  g := 0;
  IF Q_GOOD(q) THEN
    g := 1;
  END_IF;
  PRINT('p10 g=', g, '\n');
END_PROGRAM
