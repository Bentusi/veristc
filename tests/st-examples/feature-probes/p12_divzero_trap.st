(* p12: 除零运行时陷阱——tick=3 时触发 10/0，期望 VM 报错退出，
   前两个周期正常输出 e=10 *)
PROGRAM MAIN
VAR
  tick : DINT;
  e : DINT;
END_VAR
  tick := CycleCounter();
  e := 10;
  IF tick = 3 THEN
    e := e / 0;
  END_IF;
  PRINT('p12 e=', e, '\n');
END_PROGRAM
