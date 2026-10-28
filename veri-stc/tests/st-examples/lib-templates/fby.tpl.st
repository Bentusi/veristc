(* ================================================================
   fby.tpl.st  --  库侧模板（前端预处理器解析，不经 veristc 编译）

   语义：OUT := PRE; PRE := IN

   受限 FB 语法要点（供预处理器机械展开）:
   - 端口三分类显式声明：VAR_INPUT / VAR_STATE / VAR_OUTPUT
   - 模板体每个 STATE/OUTPUT 字段恰好一条赋值，右端为单表达式；
     表达式内自引用状态字段 = 上一周期值（更新序 = 声明序）
   - 预处理器为每个可写字段生成一个共享单表达式 FUNCTION 实体
     （全程序一份实现，inline.v 展开域内），调用点只展开为
     "输入绑定 + 赋值调用"，不复制算法体
   ================================================================ *)
(* @tpl VAR_GLOBAL *)
VAR_GLOBAL
  PRE : BOOL;
END_VAR
(* @tpl END_VAR *)

(* @tpl RESET *)
FUNCTION FBY_RESET
VAR_IN
  RESET_IN : BOOL;
END_VAR
  PRE := RESET_IN;
END_FUNCTION
(* @tpl RESET_END *)

(* @tpl FUNCTION *)
FUNCTION FBY
VAR_IN
  PRE : BOOL;
  IN  : BOOL;
END_VAR
  FBY := PRE;
  PRE := IN;
END_FUNCTION
(* @tpl END_FUNCTION *)

(* 展开约束:
   T-1 体内只引用声明端口；每字段一条单表达式更新规则
   T-2 每实例每周期至多调用一次（禁重入）
   T-3 实例输出之间不得别名绑定
   T-4 字段顺序 = 声明顺序（更新序，确定性展开）
   展开映射:
     模板 <TPL>.<field> 赋值 -> 共享实体 FUNCTION <TPL>_<field>（一份）
     调用点 inst(A := e, ...) -> <inst>__in_A := e; <inst>_f := <TPL>_f(args); *)
