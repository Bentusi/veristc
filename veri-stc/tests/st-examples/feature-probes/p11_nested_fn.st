(* p11: FUNCTION 嵌套内联——Quad 调用 Twice，两层展开后与 4*tick 恒等 *)
FUNCTION Twice : DINT
VAR_INPUT
  x : DINT;
END_VAR
  Twice := x + x;
END_FUNCTION

FUNCTION Quad : DINT
VAR_INPUT
  x : DINT;
END_VAR
  Quad := Twice(Twice(x));
END_FUNCTION

PROGRAM MAIN
VAR
  tick : DINT;
  q : DINT;
  diff : DINT;
END_VAR
  tick := CycleCounter();
  q := Quad(tick);
  diff := q - 4 * tick;
  PRINT('p11 q=', q, ' diff=', diff, '\n');
END_PROGRAM
