(* p09 [XFAIL-后端缺口]: 静态数组读写。
   spec: 地址 = base + (idx-low)*width；当前 CS_ARRAY_ASSIGN/CE_ARRAY_ACCESS
   把数组变量当"值"再 +idx（无宽度缩放，全局数组读到的是内容不是地址）。
   期望 s=20。 *)
PROGRAM MAIN
VAR
  buf : ARRAY[0..3] OF DINT;
  i : DINT;
  s : DINT;
END_VAR
  FOR i := 0 TO 3 DO
    buf[i] := i * 10;
  END_FOR;
  s := buf[0] + buf[2];
  PRINT('p09 s=', s, '\n');
END_PROGRAM
