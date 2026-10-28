(* ================================================================
   rs_multi_entity_fb.st  --  授权源文件（FB 形式多实体 RS）

   实现只在模板一份：lib-templates/rs_v1.tpl.st
   MAIN 只调用、不重新实现。编译器实际接收的是预处理展开产物：
     python3 tools/stpreproc.py \
       tests/st-examples/rs_multi_entity_fb.st \
       -o tests/st-examples/rs_multi_entity_fb.expanded.st
   （展开产物含生成头，标注模板版本与 sha256，见 PRE-5）

   与 FUNCTION 版 (rs_multi_entity.st) 的分工差异：
     FUNCTION 版: 状态由调用方搬进搬出   q1 := RS(q1, s1, r1);
     FB 版:      状态封装在实例上下文，MAIN 只见调用   rs1(S := ..., R := ...);
   ================================================================ *)

(* @use lib-templates/rs_v1.tpl.st *)

(* 实例声明：每个实体 = 同一模板的一份上下文 *)
(* @fb rs1 : RS_V1 *)
(* @fb rs2 : RS_V1 *)

PROGRAM MAIN
VAR
  tick  : DINT;
END_VAR
  tick := CycleCounter();

  (* 多实体调用：同一份模板实现，各绑各的输入 *)
  rs1(S := tick = 2, R := tick = 6);
  rs2(S := tick = 4, R := tick = 8);

  (* 输出消费：读实例上下文全局（本 demo 只消费状态 Q） *)
  PRINT('tick', tick, rs1.Q, rs2.Q);
END_PROGRAM
