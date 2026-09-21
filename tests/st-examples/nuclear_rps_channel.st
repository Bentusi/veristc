(* ================================================================
   nuclear_rps_channel.st — 单组 RPS 4 通道保护 + 跳闸母线 + ESFAS 顺序器

   定位（与 feature-probes/ 分工）：探针覆盖单构造，本文件覆盖
   "状态密集 + 核电保护语义"，全部构造限于当前实编译管线
   （global_codegen I32 后端）可正确执行的子集：
     CASE 多分支(值/范围/ELSE) · IF/ELSIF · FOR(INT 环变量) ·
     WHILE 定点缩放 · MOD/除法 · 布尔代数(AND/OR/XOR/NOT) ·
     FUNCTION 多实参内联复用 · VAR_GLOBAL 跨周期锁存 ·
     CycleCounter 驱动场景激励 · PRINT 可观测量

   被保护对象：核岛 RPS 保护机柜（4 通道 A/B/C/D，中子功率量程，
   整定 1100/堆量程单位，迟滞复位 1000）。跳闸母线 2oo4 表决，
   故障/旁路通道从表决中剔除。ESFAS 顺序器按周期间隔分级：
   SI 信号 → 高压注泵 → 停堆卸压。

   场景时间线（tick = CycleCounter，运行 38 周期）：
     t=11..21  A 通道超量程(1160)
     t=13..23  B 通道超量程(1160)
     t=13..    D 通道持续超量程(1160)
     t=5..8    C 传感器故障(sf_c)  t>=9 C 维护旁路(byp_c)
     t=14/16   A/B/D 滤波均值越限 → 触发延时 3 周期(TON 仿真)
     t=17      A 跳闸  t=19 B/D 跳闸 → 2oo4 满足 → 母线 A 跳
               (上升沿 trip_count_a=1, 顺序器启动)
     t=24 SI, t=28 HPI …  t=30 全局 RESET：闭锁清除、顺序器复位
     t=33      D 重新跳闸，但仅剩 1/4 → 母线保持释放（验证复位后
               表决抑制路径）
   ================================================================ *)

(* ---------------- 跨周期状态（VM 持久 MEM 段） ---------------- *)

VAR_GLOBAL
  (* 通道状态机: 0=NORMAL 2=TRIP_PENDING 3=TRIPPED 4=BYPASSED 5=FAULT *)
  st_a : DINT;
  st_b : DINT;
  st_c : DINT;
  st_d : DINT;
  (* 跳闸延时计时器 (TON 仿真, 单位=扫描周期) *)
  dt_a : DINT;
  dt_b : DINT;
  dt_c : DINT;
  dt_d : DINT;
  (* 4 抽头滑动平均环 × 4 通道 = 16 个状态字 *)
  f0_a : DINT;
  f1_a : DINT;
  f2_a : DINT;
  f3_a : DINT;
  f0_b : DINT;
  f1_b : DINT;
  f2_b : DINT;
  f3_b : DINT;
  f0_c : DINT;
  f1_c : DINT;
  f2_c : DINT;
  f3_c : DINT;
  f0_d : DINT;
  f1_d : DINT;
  f2_d : DINT;
  f3_d : DINT;
  (* 滤波输出 *)
  avg_a : DINT;
  avg_b : DINT;
  avg_c : DINT;
  avg_d : DINT;
  (* 跳闸闭锁 *)
  trip_a : BOOL;
  trip_b : BOOL;
  trip_c : BOOL;
  trip_d : BOOL;
  (* 跳闸母线 + 边沿检测 + 计数器 *)
  trainA_trip : BOOL;
  prevA : BOOL;
  trip_count_a : DINT;
  (* ESFAS 顺序器: 0=IDLE 1=SI延时 2=HPI延时 3=卸压延时 4=完成 *)
  seq_state : DINT;
  seq_timer : DINT;
  si_a : BOOL;
  hpi_a : BOOL;
  ld_a : BOOL;
  (* 报警字 *)
  alarm_word : DINT;
END_VAR

(* ---------------- 库函数（内联展开，多实体复用） ---------------- *)

(* 4 点滑动平均（定点） *)
FUNCTION MA4 : DINT
VAR_INPUT
  x0 : DINT;
  x1 : DINT;
  x2 : DINT;
  x3 : DINT;
END_VAR
  MA4 := (x0 + x1 + x2 + x3) / 4;
END_FUNCTION

(* 2oo3 表决：三输入中至少两个为真 *)
FUNCTION Vote23 : BOOL
VAR_INPUT
  a : BOOL;
  b : BOOL;
  c : BOOL;
END_VAR
  Vote23 := (a AND b) OR (a AND c) OR (b AND c);
END_FUNCTION

(* 通道有效跳闸输出：故障或旁路时强制剔除 *)
FUNCTION ChValid : BOOL
VAR_INPUT
  q : BOOL;
  fault : BOOL;
  bypass : BOOL;
END_VAR
  ChValid := q AND (NOT fault) AND (NOT bypass);
END_FUNCTION

(* ---------------- 主程序 ---------------- *)

PROGRAM MAIN
VAR
  tick : DINT;
  (* 输入层临时量 *)
  raw_a : DINT;
  raw_b : DINT;
  raw_c : DINT;
  raw_d : DINT;
  byp_c : BOOL;
  sf_c : BOOL;
  rst : BOOL;
  (* 表决有效输出 *)
  va : BOOL;
  vb : BOOL;
  vc : BOOL;
  vd : BOOL;
  vote : BOOL;
  (* 报警字打包 / 位重编码 (FOR) *)
  fa : DINT;
  bitv : DINT;
  pow : DINT;
  j : INT;
  (* 定点百分比缩放 (WHILE) *)
  n : DINT;
  pct_a : DINT;
END_VAR
  tick := CycleCounter();

  (* ---- 1. 场景激励（确定性，tick 驱动） ---- *)
  raw_c := 880;
  raw_a := 880;
  IF (tick >= 11) AND (tick <= 21) THEN
    raw_a := 1160;
  END_IF;
  raw_b := 880;
  IF (tick >= 13) AND (tick <= 23) THEN
    raw_b := 1160;
  END_IF;
  raw_d := 880;
  IF tick >= 13 THEN
    raw_d := 1160;
  END_IF;
  sf_c := (tick >= 5) AND (tick <= 8);
  byp_c := tick >= 9;
  rst := tick = 30;

  (* ---- 2. 滑动平均环更新（右旋 + 新样本入 f0） ---- *)
  f3_a := f2_a;
  f2_a := f1_a;
  f1_a := f0_a;
  f0_a := raw_a;
  avg_a := MA4(f0_a, f1_a, f2_a, f3_a);

  f3_b := f2_b;
  f2_b := f1_b;
  f1_b := f0_b;
  f0_b := raw_b;
  avg_b := MA4(f0_b, f1_b, f2_b, f3_b);

  f3_c := f2_c;
  f2_c := f1_c;
  f1_c := f0_c;
  f0_c := raw_c;
  avg_c := MA4(f0_c, f1_c, f2_c, f3_c);

  f3_d := f2_d;
  f2_d := f1_d;
  f1_d := f0_d;
  f0_d := raw_d;
  avg_d := MA4(f0_d, f1_d, f2_d, f3_d);

  (* ---- 3. RESET：清除所有闭锁与顺序器 ---- *)
  IF rst THEN
    st_a := 0;  st_b := 0;  st_d := 0;
    dt_a := 0;  dt_b := 0;  dt_d := 0;
    trip_a := FALSE;  trip_b := FALSE;  trip_d := FALSE;
    trainA_trip := FALSE;
    seq_state := 0;  seq_timer := 0;
    si_a := FALSE;  hpi_a := FALSE;  ld_a := FALSE;
  END_IF;

  (* ---- 4. C 通道维护状态直通（旁路优先于故障） ---- *)
  IF byp_c THEN
    st_c := 4;
  ELSIF sf_c THEN
    st_c := 5;
  ELSE
    st_c := 0;
  END_IF;

  (* ---- 5. 每通道跳闸状态机（多分支 CASE） ----
     NORMAL → 均值越限 → TRIP_PENDING(延时 3 周期) → TRIPPED；
     PENDING 中均值回落则撤回 NORMAL（延时取消）。 *)
  CASE st_a OF
    0:
      IF avg_a > 1100 THEN
        st_a := 2;
        dt_a := 3;
      END_IF;
    2:
      dt_a := dt_a - 1;
      IF dt_a <= 0 THEN
        st_a := 3;
        trip_a := TRUE;
      ELSE
        IF avg_a <= 1000 THEN
          st_a := 0;
        END_IF;
      END_IF;
    3:
      trip_a := TRUE;
    4:
      trip_a := FALSE;
    5:
      trip_a := FALSE;
  END_CASE;

  CASE st_b OF
    0:
      IF avg_b > 1100 THEN
        st_b := 2;
        dt_b := 3;
      END_IF;
    2:
      dt_b := dt_b - 1;
      IF dt_b <= 0 THEN
        st_b := 3;
        trip_b := TRUE;
      ELSE
        IF avg_b <= 1000 THEN
          st_b := 0;
        END_IF;
      END_IF;
    3:
      trip_b := TRUE;
    4:
      trip_b := FALSE;
    5:
      trip_b := FALSE;
  END_CASE;

  CASE st_c OF
    0:
      IF avg_c > 1100 THEN
        st_c := 2;
        dt_c := 3;
      END_IF;
    2:
      dt_c := dt_c - 1;
      IF dt_c <= 0 THEN
        st_c := 3;
        trip_c := TRUE;
      ELSE
        IF avg_c <= 1000 THEN
          st_c := 0;
        END_IF;
      END_IF;
    3:
      trip_c := TRUE;
    4:
      trip_c := FALSE;
    5:
      trip_c := FALSE;
  END_CASE;

  CASE st_d OF
    0:
      IF avg_d > 1100 THEN
        st_d := 2;
        dt_d := 3;
      END_IF;
    2:
      dt_d := dt_d - 1;
      IF dt_d <= 0 THEN
        st_d := 3;
        trip_d := TRUE;
      ELSE
        IF avg_d <= 1000 THEN
          st_d := 0;
        END_IF;
      END_IF;
    3:
      trip_d := TRUE;
    4:
      trip_d := FALSE;
    5:
      trip_d := FALSE;
  END_CASE;

  (* ---- 6. 2oo4 表决（剔除故障/旁路通道） + 母线自保持 + 上升沿 ---- *)
  va := ChValid(trip_a, FALSE, FALSE);
  vb := ChValid(trip_b, FALSE, FALSE);
  vc := ChValid(trip_c, sf_c, byp_c);
  vd := ChValid(trip_d, FALSE, FALSE);
  vote := Vote23(va, vb, vd);
  trainA_trip := trainA_trip OR vote;
  IF trainA_trip AND (NOT prevA) THEN
    trip_count_a := trip_count_a + 1;
    IF seq_state = 0 THEN
      seq_state := 1;
      seq_timer := 5;
    END_IF;
  END_IF;
  prevA := trainA_trip;

  (* ---- 7. ESFAS 顺序器（周期分级延时） ---- *)
  IF seq_state = 1 THEN
    seq_timer := seq_timer - 1;
    IF seq_timer <= 0 THEN
      si_a := TRUE;
      seq_state := 2;
      seq_timer := 4;
    END_IF;
  ELSIF seq_state = 2 THEN
    seq_timer := seq_timer - 1;
    IF seq_timer <= 0 THEN
      hpi_a := TRUE;
      seq_state := 3;
      seq_timer := 4;
    END_IF;
  ELSIF seq_state = 3 THEN
    seq_timer := seq_timer - 1;
    IF seq_timer <= 0 THEN
      ld_a := TRUE;
      seq_state := 4;
    END_IF;
  END_IF;

  (* ---- 8. 报警字: bit3=A跳 bit2=B跳 bit1=C故障/旁路 bit0=D跳；
         FOR 环做位域重编码（/·MOD 取位后原样重组，恒等即通过） ---- *)
  fa := 0;
  IF va THEN
    fa := fa + 8;
  END_IF;
  IF vb THEN
    fa := fa + 4;
  END_IF;
  IF sf_c OR byp_c THEN
    fa := fa + 2;
  END_IF;
  IF vd THEN
    fa := fa + 1;
  END_IF;
  alarm_word := 0;
  pow := 1;
  FOR j := 0 TO 3 DO
    bitv := (fa / pow) MOD 2;
    alarm_word := alarm_word + bitv * pow;
    pow := pow * 2;
  END_FOR;

  (* ---- 9. A 通道量程百分比：无浮点定点缩放（WHILE 收敛环） ---- *)
  n := raw_a;
  pct_a := 0;
  WHILE n >= 12 DO
    n := n - 12;
    pct_a := pct_a + 1;
  END_WHILE;

  (* ---- 10. 可观测量 ---- *)
  PRINT('CHAN t=', tick, ' av=', avg_a, ',', avg_b, ',', avg_c, ',', avg_d,
        ' st=', st_a, ',', st_b, ',', st_c, ',', st_d,
        ' v=', va, ',', vb, ',', vc, ',', vd,
        ' bus=', trainA_trip, ' cnt=', trip_count_a,
        ' seq=', seq_state, ',', si_a, ',', hpi_a, ',', ld_a,
        ' aw=', alarm_word, ' pct=', pct_a, '\n');
END_PROGRAM
