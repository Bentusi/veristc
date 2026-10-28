(* ================================================================
   negative/qualified_input_read.st -- 封装：输入/别名端口不可用点号引用

   spec/safest-spec.md 6.5.1 方向表里 `VAR_INPUT` 与 `VAR_IN_OUT` 两行的
   体外访问都落到 `KIND=type`：expand_instances 只为可写字段
   （VAR_OUTPUT + 实例内 VAR）生成扁平派生全局，输入端口经调用点绑定为
   形参、别名端口降级为指针形参，二者都不存在名为 a1#K / a1#ACC 的全局。
   于是引用它们 = 引用未声明名，由类型检查阶段以 KIND=type 拒绝（而非
   access）。已知精度取舍：这条路径复用通用类型错误，诊断形如
     POU=MAIN VAR=- KIND=type LOC=- MSG=type error
   不指认具体名字，且报出第一条即中止（Fatal error）。因此本文件只保留
   一处违规（VAR_INPUT）；VAR_IN_OUT 的同一路径见 qualified_in_out_read.st，
   两行方向规则各自独立可验证。

   对比 qualified_internal_read.st（VAR=a1#C KIND=access）：那条是名字
   确实存在（内部 VAR 生成了派生全局）但封装禁止体外访问；本条是名字
   不存在。两者共同构成 6.5.1 方向表的机器可验证部分。
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
  x := a1.K;
END_PROGRAM
