(* p06: 跨周期锁存状态——VAR_GLOBAL 持久 + 迟滞整定 + 手动复位
   场景: x = tick*25; 跳闸阈值 x>100; 复位脉冲 tick=7 *)
VAR_GLOBAL
  latched : BOOL;
END_VAR

PROGRAM MAIN
VAR
  tick : DINT;
  x : DINT;
  rst : BOOL;
END_VAR
  tick := CycleCounter();
  x := tick * 25;
  rst := tick = 7;

  latched := (NOT rst) AND ((x > 100) OR (latched AND NOT (x < 80)));
  PRINT('p06 x=', x, ' latched=', latched, '\n');
END_PROGRAM
