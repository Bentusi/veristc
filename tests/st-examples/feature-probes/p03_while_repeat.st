(* p03: WHILE 递减收敛 + REPEAT-UNTIL 至少执行一次语义 *)
PROGRAM MAIN
VAR
  n : DINT;
  k : DINT;
  m : DINT;
END_VAR
  n := 100;
  k := 0;
  WHILE n > 50 DO
    n := n - 7;
    k := k + 1;
  END_WHILE;

  m := 0;
  REPEAT
    m := m + 3;
  UNTIL m >= 20
  END_REPEAT;

  PRINT('p03 n=', n, ' k=', k, ' m=', m, '\n');
END_PROGRAM
