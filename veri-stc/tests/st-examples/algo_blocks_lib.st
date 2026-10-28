(* ================================================================
   algo_blocks_lib.st — SafeST 算法块库（源码级库文件）

   提供 4 种经典控制算法块，全部实现为无状态 FUNCTION：
     RS      : 置位优先双稳态   Q' = S OR (Q_old AND NOT R)
     SR      : 复位优先双稳态   Q' = (S OR Q_old) AND NOT R
     PID_UI  : 积分项 + 限幅    V = UI + KI*E, clamp [LO,HI]
     PID_OUT : 全量输出 + 限幅  U = KP*E + UI + KD*DE, clamp [LO,HI]
     FBY     : 速率限制(跟随)   Q = IN, clamp [PRE-DR, PRE+DR]

   多实例约定（与 rs_multi_entity.st 相同）：
   - 状态（Q_old / UI / DE / PRE）由调用方持有并作为输入传入，
     返回值由调用方写回自身状态变量 => 同一份代码服务任意多个实例。
   - 跨周期状态必须放 VAR_GLOBAL（VM 每周期清零 PROGRAM 局部变量）。
   - 本文件为库源码：VeriSTC 无 LIBRARY/IMPORT 链接机制，
     使用时由上游预处理器将 FUNCTION 块文本内联进目标 .st，
     参见 algo_blocks_multi_instance.st（已内联的可编译测试用例）。
   ================================================================ *)

(* ---- RS：置位优先（S 与 R 同时为真时输出 1） ---- *)
FUNCTION RS : BOOL
VAR_INPUT
  Q_old : BOOL;
  S : BOOL;
  R : BOOL;
END_VAR
  RS := S OR (Q_old AND NOT R);
END_FUNCTION

(* ---- SR：复位优先（S 与 R 同时为真时输出 0） ---- *)
FUNCTION SR : BOOL
VAR_INPUT
  Q_old : BOOL;
  S : BOOL;
  R : BOOL;
END_VAR
  SR := (S OR Q_old) AND NOT R;
END_FUNCTION

(* ---- PID_UI：积分项累加 + 抗积分饱和限幅 ---- *)
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

(* ---- PID_OUT：比例+积分+微分合成输出 + 限幅 ---- *)
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

(* ---- FBY：一阶速率限制跟随（首出/后备跟随类） ---- *)
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
