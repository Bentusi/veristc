(* ================================================================
   algo_blocks_multi_instance.st
   测试用例：不同的变量调用相同的算法功能（多实例复用）

   内联库：tests/st-examples/algo_blocks_lib.st
   （VeriSTC 无库链接机制，库文本由上游预处理器内联，此处手工内联）

   每个算法块均有 2 个实例，实例之间变量完全独立：
     RS(q1)/RS(q2)   SR(q1)/SR(q2)
     PID(e1,ui1,de1,u1) / PID(e2,ui2,de2,u2)
     FBY(in->f1) / FBY(in->f2)
   跨周期状态全部放 VAR_GLOBAL 并由调用方写回。

   12 周期金标准（t: rs1 rs2 sr1 sr2 | u1 ui1 | u2 ui2 | f1 f2）
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

VAR_GLOBAL
  rs1_q  : BOOL;
  rs2_q  : BOOL;
  sr1_q  : BOOL;
  sr2_q  : BOOL;
  pid1_ui   : DINT;
  pid1_eold : DINT;
  pid2_ui   : DINT;
  pid2_eold : DINT;
  fby1_out : DINT;
  fby2_out : DINT;
END_VAR

(* ---------------- 库：algo_blocks_lib.st 内联开始 ---------------- *)

FUNCTION RS : BOOL
VAR_INPUT
  Q_old : BOOL;
  S : BOOL;
  R : BOOL;
END_VAR
  RS := S OR (Q_old AND NOT R);
END_FUNCTION

FUNCTION SR : BOOL
VAR_INPUT
  Q_old : BOOL;
  S : BOOL;
  R : BOOL;
END_VAR
  SR := (S OR Q_old) AND NOT R;
END_FUNCTION

FUNCTION PID_UI : DINT
VAR_INPUT
  E  : DINT;
  UI : DINT;
  KI : DINT;
  LO : DINT;
  HI : DINT;
END_VAR
VAR
  V : DINT;
END_VAR
  V := UI + KI * E;
  IF V > HI THEN
    V := HI;
  ELSIF V < LO THEN
    V := LO;
  END_IF;
  PID_UI := V;
END_FUNCTION

FUNCTION PID_OUT : DINT
VAR_INPUT
  E   : DINT;
  UI  : DINT;
  DE  : DINT;
  KP  : DINT;
  KD  : DINT;
  LO  : DINT;
  HI  : DINT;
END_VAR
VAR
  U : DINT;
END_VAR
  U := KP * E + UI + KD * DE;
  IF U > HI THEN
    U := HI;
  ELSIF U < LO THEN
    U := LO;
  END_IF;
  PID_OUT := U;
END_FUNCTION

FUNCTION FBY : DINT
VAR_INPUT
  IN  : DINT;
  PRE : DINT;
  DR  : DINT;
END_VAR
VAR
  Q : DINT;
END_VAR
  Q := IN;
  IF Q > PRE + DR THEN
    Q := PRE + DR;
  ELSIF Q < PRE - DR THEN
    Q := PRE - DR;
  END_IF;
  FBY := Q;
END_FUNCTION

(* ---------------- 库内联结束 ---------------- *)

PROGRAM MAIN
VAR
  tick  : DINT;
  rs1_s : BOOL;
  rs1_r : BOOL;
  rs2_s : BOOL;
  rs2_r : BOOL;
  sr1_s : BOOL;
  sr1_r : BOOL;
  sr2_s : BOOL;
  sr2_r : BOOL;
  e1  : DINT;
  de1 : DINT;
  u1  : DINT;
  e2  : DINT;
  de2 : DINT;
  u2  : DINT;
  in1 : DINT;
  in2 : DINT;
  fby1_q : DINT;
  fby2_q : DINT;
END_VAR
  tick := CycleCounter();

  (* ---- 激励 ---- *)
  rs1_s := tick = 1;
  rs1_r := tick = 5;
  rs2_s := tick = 3;
  rs2_r := tick = 4;
  sr1_s := tick = 2;
  sr1_r := tick = 2;
  sr2_s := tick = 6;
  sr2_r := tick = 9;

  (* ---- RS：同一功能，两套变量 ---- *)
  rs1_q := RS(rs1_q, rs1_s, rs1_r);
  rs2_q := RS(rs2_q, rs2_s, rs2_r);

  (* ---- SR：同一功能，另两套变量 ---- *)
  sr1_q := SR(sr1_q, sr1_s, sr1_r);
  sr2_q := SR(sr2_q, sr2_s, sr2_r);

  (* ---- PID 实例 1：e1 = 130 - 12t, Kp=Ki=Kd=1, UI限[0,200], U限[0,170] ---- *)
  e1  := 130 - tick * 12;
  de1 := e1 - pid1_eold;
  pid1_ui := PID_UI(e1, pid1_ui, 1, 0, 200);
  u1  := PID_OUT(e1, pid1_ui, de1, 1, 1, 0, 170);
  pid1_eold := e1;

  (* ---- PID 实例 2：e2 = 70 - 5t, Kp=2,Kd=1, UI限[0,90], U限[0,140] ---- *)
  e2  := 70 - tick * 5;
  de2 := e2 - pid2_eold;
  pid2_ui := PID_UI(e2, pid2_ui, 1, 0, 90);
  u2  := PID_OUT(e2, pid2_ui, de2, 2, 1, 0, 140);
  pid2_eold := e2;

  (* ---- FBY 实例 1：in1 = 30t 斜坡, 速率限 20 ---- *)
  in1 := tick * 30;
  fby1_q := FBY(in1, fby1_out, 20);
  fby1_out := fby1_q;

  (* ---- FBY 实例 2：t<=4 时 in2=0，之后跳变 120, 速率限 50 ---- *)
  IF tick > 4 THEN
    in2 := 120;
  ELSE
    in2 := 0;
  END_IF;
  fby2_q := FBY(in2, fby2_out, 50);
  fby2_out := fby2_q;

  PRINT('ALG t=', tick, ' rs1=', rs1_q, ' rs2=', rs2_q,
        ' sr1=', sr1_q, ' sr2=', sr2_q,
        ' u1=', u1, ' ui1=', pid1_ui,
        ' u2=', u2, ' ui2=', pid2_ui,
        ' f1=', fby1_out, ' f2=', fby2_out, '\n');
END_PROGRAM
