(* p13: VAR_IN_OUT 逐引用别名——端口是调用方存储的别名，不是副本
   场景: shared 为全局累加器；i1/i2 两个实例的 ACC 端口都绑定 shared，
         体内 LAST := ACC（读别名）+ ACC := ACC + K（写别名）。
         每周期 i1 加 tick、i2 加 100 ⇒ shared 单点跨实例累加；
         两实例 LAST 互不相同 ⇒ 实例数据仍分离。 *)
VAR_GLOBAL
  shared : DINT;
  i1 : ACCUM;
  i2 : ACCUM;
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
  i1(ACC := shared, K := tick);
  i2(ACC := shared, K := 100);
  PRINT('p13 shared=', shared, ' i1=', i1.LAST, ' i2=', i2.LAST, '\n');
END_PROGRAM
