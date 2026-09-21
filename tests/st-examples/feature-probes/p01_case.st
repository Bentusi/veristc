(* p01: CASE 语句——单值/多值/范围/ELSE 四类分支（desugar → IF 链） *)
PROGRAM MAIN
VAR
  tick : DINT;
  code : DINT;
END_VAR
  tick := CycleCounter();
  code := 0;
  CASE tick OF
    1:
      code := 10;
    2,3:
      code := 20;
    4..6:
      code := 30;
  ELSE:
    code := 99;
  END_CASE;
  PRINT('p01 code=', code, '\n');
END_PROGRAM
