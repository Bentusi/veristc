(* ================================================================
   negative/qualified_in_out_read.st -- 封装：别名端口不可用点号引用

   6.5.1 方向表的 VAR_IN_OUT 行。v1.5 起 VAR_IN_OUT 降级为"持有调用方
   存储地址的形参槽"（I32_LOAD_PTR / I32_STORE_PTR），expand_instances
   不为它生成派生全局，所以 `x := a1.ACC;` 引用的名字根本不存在，由类型
   检查阶段以 KIND=type 拒绝。

   这不是多余的严格性：调用方本来就持有别名目标（此处 shared），要读就
   直接读它 —— 读得到同一份存储，且不需要绕过 FB 的端口约定。

   与 qualified_input_read.st 的区别只在端口方向（IN_OUT vs INPUT）；
   与 qualified_internal_read.st（KIND=access）的区别在于名字是否存在。
   ================================================================ *)

(* 实例声明必须先于 POU 列表（顶层文法：VAR_GLOBAL → POU*）*)
VAR_GLOBAL
  a1 : ACCUM;
  shared : DINT;
  x : DINT;
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
  a1(ACC := shared, K := 10);
  x := a1.ACC;
END_PROGRAM
