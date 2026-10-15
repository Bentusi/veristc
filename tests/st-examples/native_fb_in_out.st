(* ================================================================
   native_fb_in_out.st  --  VAR_IN_OUT 逐引用别名 e2e

   验证 v1.5 IN_OUT 语义：端口不是副本，而是调用方存储的别名。
     - 逻辑一份（ACCUM 定义），实例数据分离（a1/a2 各自持有 LAST）
     - VAR_IN_OUT ACC 编译为"指向调用方全局的地址"形参，体内读写走
       I32_LOAD_PTR / I32_STORE_PTR，故两个实例共享同一个 shared
     - 同一周期内双向可见：调用方写 shared → 被调读得到；被调写
       ACC → 调用方立即读到

   每周期 t（tick = CycleCounter()）：
     shared := t                 调用方写入别名目标
     a1(K := 10)  : LAST := t,       shared := t + 10
     a2(K := 100) : LAST := t + 10,  shared := t + 110
   ⇒ PRINT 输出 (tick, shared, a1_LAST, a2_LAST)
        t=1 → 1, 111, 1, 11     t=3 → 3, 113, 3, 13
   LAST 互不相同 ⇒ 实例数据仍分离；shared 单点累加 ⇒ 端口是别名。
   ================================================================ *)

(* 实例声明必须先于 POU 列表（顶层文法：VAR_GLOBAL → POU*）*)
VAR_GLOBAL
  shared : DINT;
  a1 : ACCUM;
  a2 : ACCUM;
END_VAR

FUNCTION_BLOCK ACCUM
VAR_INPUT
  K : DINT;
END_VAR
VAR_OUTPUT
  LAST : DINT;
END_VAR
VAR_IN_OUT
  ACC : DINT;
END_VAR
  LAST := ACC;
  ACC := ACC + K;
END_FUNCTION_BLOCK

PROGRAM MAIN
VAR
  tick : DINT;
END_VAR
  tick := CycleCounter();
  shared := tick;
  a1(ACC := shared, K := 10);
  a2(ACC := shared, K := 100);
  PRINT('tick', tick, shared, a1_LAST, a2_LAST);
END_PROGRAM
