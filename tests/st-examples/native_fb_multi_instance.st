(* ================================================================
   native_fb_multi_instance.st  --  原生 FUNCTION_BLOCK 多实体 e2e

   验证 P1 目标：库逻辑一份（FB 定义），实例数据分离（每实例
   独立 self 相对上下文），无需前端文本预处理器展开。

   语义（RS，S 置位优先于 R 复位）： Q := S OR (Q AND NOT R)
     - 逻辑体只在 FUNCTION_BLOCK RS_V1 出现一份
     - rs1 / rs2 为两个实例，各自持有独立的 Q 上下文
     - MAIN 只见调用与实例输出读取，不复制算法体

   tick = CycleCounter(): 1,2,3,...
   rs1: S=(tick=2) R=(tick=6)  -> Q: 0,0,1,1,1,1,0,0
   rs2: S=(tick=4) R=(tick=8)  -> Q: 0,0,0,1,1,1,1,0
   ================================================================ *)

(* 实例声明必须先于 POU 列表（顶层文法：VAR_GLOBAL → POU*）*)
VAR_GLOBAL
  rs1 : RS_V1;
  rs2 : RS_V1;
END_VAR

FUNCTION_BLOCK RS_V1
VAR_INPUT
  S : BOOL;
  R : BOOL;
END_VAR
VAR_OUTPUT
  Q : BOOL;
END_VAR
  Q := S OR (Q AND NOT R);
END_FUNCTION_BLOCK

PROGRAM MAIN
VAR
  tick : DINT;
END_VAR
  tick := CycleCounter();
  rs1(S := (tick = 2), R := (tick = 6));
  rs2(S := (tick = 4), R := (tick = 8));
  PRINT('tick', tick, rs1_Q, rs2_Q);
END_PROGRAM
