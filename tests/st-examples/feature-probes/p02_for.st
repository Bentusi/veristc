(* p02: FOR 循环——常量上界/步长/嵌套（desugar → WHILE 计数模式） *)
PROGRAM MAIN
VAR
  i : INT;      (* 类型检查规则 TS_for_int: 循环变量必须为 INT *)
  j : INT;
  sum : DINT;
  step_sum : DINT;
  pairs : DINT;
END_VAR
  sum := 0;
  FOR i := 1 TO 5 DO
    sum := sum + i;
  END_FOR;

  step_sum := 0;
  FOR i := 2 TO 8 BY 2 DO
    step_sum := step_sum + i;
  END_FOR;

  pairs := 0;
  FOR i := 1 TO 3 DO
    FOR j := 1 TO 4 DO
      pairs := pairs + 1;
    END_FOR;
  END_FOR;

  PRINT('p02 s=', sum, ' ss=', step_sum, ' c=', pairs, '\n');
END_PROGRAM
