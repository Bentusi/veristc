(* p04: 有符号除法/取余——负操作数截断语义（对齐 C 与 Coq Z.div/Z.rem） *)
PROGRAM MAIN
VAR
  tick : DINT;
  a : DINT;
  r : DINT;
  q : DINT;
  ne : DINT;
  nd : DINT;
  nr : DINT;
END_VAR
  tick := CycleCounter();
  a := tick * 7 + 3;
  r := a MOD 5;
  q := a / 5;
  ne := 0 - 17;
  nd := ne / 5;
  nr := ne MOD 5;
  PRINT('p04 a=', a, ' r=', r, ' q=', q, ' nd=', nd, ' nr=', nr, '\n');
END_PROGRAM
