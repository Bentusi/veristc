(* ================================================================
   algo_blocks_fb.st
   原生 FUNCTION_BLOCK 版算法块库 + "不同变量调用相同算法功能" e2e

   与 FUNCTION 版（algo_blocks_lib.st / algo_blocks_multi_instance.st）
   同激励、同黄金时间线，可交叉验证两种实现一致。

   演示 FB 全部可用特性（P1 + v1.5）：
     - VAR_INPUT / VAR_OUTPUT（多输出：Q 与 QN、U 与 UI 与 ALM）
     - VAR 实例内持久状态（UI / E_OLD，FB_DATA 跨周期不清零）
     - VAR_IN_OUT 逐引用别名（TRACE：诊断量直写调用方全局）
     - 实例声明分离：rs1/rs2 同一份代码、独立数据段
     - IF/ELSIF/ELSE 控制流、表达式实参、命名实参（:=）
   限制：FB 体内不得声明成员实例（嵌套 FB 不支持，P1 范围外）。
   调用点在外部以 IEC 点号访问 inst.FIELD 读取字段（v1.5.1；编译器内部
   融合为不可书写的派生名 inst#FIELD，外部只能读 VAR_OUTPUT）。

   黄金时间线（数值列与 FUNCTION 版一致，t: rs1 rs2 sr1 sr2 | u1 ui1 |
   u2 ui2 | f1 f2，u 与 tr 恒等因 TRACE 别名）。列标签自 v1.5.1 起写作
   点号形式（rs1.Q / pid1.U / pid1.UI / fby1.Y …）指认"这一列来自哪个
   实例的哪个字段"；golden 文件随之只改标签文本，12 行数值逐列不变：
     t1 : 1 0 0 0 | 170 118 | 140 65  |  20   0
     t2 : 1 0 0 0 | 170 200 | 140 90  |  40   0
     t3 : 1 1 0 0 | 170 200 | 140 90  |  60   0
     t4 : 1 0 0 0 | 170 200 | 140 90  |  80   0
     t5 : 0 0 0 0 | 170 200 | 140 90  | 100  50
     t6 : 0 0 0 1 | 170 200 | 140 90  | 120 100
     t7 : 0 0 0 1 | 170 200 | 140 90  | 140 120
     t8 : 0 0 0 1 | 170 200 | 140 90  | 160 120
     t9 : 0 0 0 0 | 170 200 | 135 90  | 180 120
     t10: 0 0 0 0 | 170 200 | 125 90  | 200 120
     t11: 0 0 0 0 | 170 198 | 115 90  | 220 120
     t12: 0 0 0 0 | 158 184 | 105 90  | 240 120
   ================================================================ *)

(* ---- 实例声明：必须先于 POU 列表；每实例独立 FB_DATA ---- *)
VAR_GLOBAL
  rs1  : RS_FB;
  rs2  : RS_FB;
  sr1  : SR_FB;
  sr2  : SR_FB;
  pid1 : PID_FB;
  pid2 : PID_FB;
  fby1 : FBY_FB;
  fby2 : FBY_FB;
  trace1 : DINT;   (* pid1 的 VAR_IN_OUT 别名目标 *)
  trace2 : DINT;   (* pid2 的 VAR_IN_OUT 别名目标 *)
END_VAR

(* ---- RS：置位优先双稳态；Q 为实例持久状态 ---- *)
FUNCTION_BLOCK RS_FB
VAR_INPUT
  S : BOOL;
  R : BOOL;
END_VAR
VAR_OUTPUT
  Q  : BOOL;
  QN : BOOL;
END_VAR
  Q := S OR (Q AND NOT R);
  QN := NOT Q;
END_FUNCTION_BLOCK

(* ---- SR：复位优先双稳态 ---- *)
FUNCTION_BLOCK SR_FB
VAR_INPUT
  S : BOOL;
  R : BOOL;
END_VAR
VAR_OUTPUT
  Q  : BOOL;
  QN : BOOL;
END_VAR
  Q := (S OR Q) AND NOT R;
  QN := NOT Q;
END_FUNCTION_BLOCK

(* ---- PID：定点 PID，实例内持久 UI/E_OLD，KI 固定为 1；
       TRACE 为 VAR_IN_OUT 诊断别名，输出 U 同步写入调用方全局 ---- *)
FUNCTION_BLOCK PID_FB
VAR_INPUT
  E     : DINT;
  KP    : DINT;
  KD    : DINT;
  UI_LO : DINT;
  UI_HI : DINT;
  LO    : DINT;
  HI    : DINT;
END_VAR
VAR_OUTPUT
  U   : DINT;
  UI  : DINT;
  ALM : BOOL;
END_VAR
VAR_IN_OUT
  TRACE : DINT;
END_VAR
VAR
  DE    : DINT;
  V     : DINT;
  E_OLD : DINT;
END_VAR
  DE := E - E_OLD;
  V := UI + E;
  IF V > UI_HI THEN
    V := UI_HI;
  ELSIF V < UI_LO THEN
    V := UI_LO;
  END_IF;
  UI := V;
  U := KP * E + UI + KD * DE;
  IF U > HI THEN
    U := HI;
  ELSIF U < LO THEN
    U := LO;
  END_IF;
  IF U >= HI THEN
    ALM := TRUE;
  ELSE
    ALM := FALSE;
  END_IF;
  TRACE := U;
  E_OLD := E;
END_FUNCTION_BLOCK

(* ---- FBY：速率限制跟随；Y 为实例持久输出 ---- *)
FUNCTION_BLOCK FBY_FB
VAR_INPUT
  IN : DINT;
  DR : DINT;
END_VAR
VAR_OUTPUT
  Y : DINT;
END_VAR
VAR
  V : DINT;
END_VAR
  V := IN;
  IF V > Y + DR THEN
    V := Y + DR;
  ELSIF V < Y - DR THEN
    V := Y - DR;
  END_IF;
  Y := V;
END_FUNCTION_BLOCK

PROGRAM MAIN
VAR
  tick : DINT;
  in2  : DINT;
END_VAR
  tick := CycleCounter();

  (* 与 FUNCTION 版完全相同的激励时序 *)
  rs1(S := (tick = 1), R := (tick = 5));
  rs2(S := (tick = 3), R := (tick = 4));

  sr1(S := (tick = 2), R := (tick = 2));
  sr2(S := (tick = 6), R := (tick = 9));

  (* 同一份 PID 代码，两套增益/限值、两套独立状态与别名目标 *)
  pid1(E := 130 - tick * 12, KP := 1, KD := 1,
       UI_LO := 0, UI_HI := 200, LO := 0, HI := 170,
       TRACE := trace1);
  pid2(E := 70 - tick * 5, KP := 2, KD := 1,
       UI_LO := 0, UI_HI := 90, LO := 0, HI := 140,
       TRACE := trace2);

  fby1(IN := tick * 30, DR := 20);
  IF tick > 4 THEN
    in2 := 120;
  ELSE
    in2 := 0;
  END_IF;
  fby2(IN := in2, DR := 50);

  PRINT('FB t=', tick, ' rs1.Q,=', rs1.Q, ' rs2.Q,=', rs2.Q,
        ' sr1.Q,=', sr1.Q, ' sr2.Q,=', sr2.Q,
        ' pid1.U,=', pid1.U, ' pid1.UI,=', pid1.UI,
        ' pid2.U,=', pid2.U, ' pid2.UI,=', pid2.UI,
        ' fby1.Y,=', fby1.Y, ' fby2.Y,=', fby2.Y,
        ' trace1,=', trace1, ' trace2,=', trace2, '\n');
END_PROGRAM
