(* ================================================================
   negative/name_collision_expanded.st -- 展开后派生名重复

   expand_instances（function_check.v）为实例 a1 的每个可写字段生成
   扁平全局名 a1#<字段>。若同一个 FUNCTION_BLOCK 里两个可写字段同名
   （此处 VAR_OUTPUT Q 与实例状态 VAR Q 重名），展开后就会产出两条
   a1#Q 声明 ⇒ 两个逻辑变量落到同一全局槽位、互相覆盖。

   这类冲突只在 prepare_program 之后才存在，因此 GATE-1 的重复名检查
   必须在展开后再跑一次，由 duplicate_declaration_msg 报出冲突的名字。

   （分隔符已改为标识符文法外的 '#'，用户无法手写派生名，所以静态
     命名冲突只剩"展开自身产出重名"这一条路径 —— 正是本用例。）
   ================================================================ *)

VAR_GLOBAL
  a1 : LATCH;
END_VAR

FUNCTION_BLOCK LATCH
VAR_INPUT
  K : DINT;
END_VAR
VAR_OUTPUT
  Q : DINT;
END_VAR
VAR
  Q : DINT;
END_VAR
  Q := K;
END_FUNCTION_BLOCK

PROGRAM MAIN
VAR
  tick : DINT;
END_VAR
  tick := CycleCounter();
  a1(K := tick);
END_PROGRAM
