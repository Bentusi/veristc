(* ================================================================
   rs_v1.tpl.st  --  库侧模板（前端预处理器解析，不经 veristc 编译）

   语义：Q := S OR (Q_old AND NOT R)，S 优先 —— 与
   tests/st-examples/rs_multi_entity.st 的 FUNCTION RS 完全一致。

   受限 FB 语法要点（供预处理器机械展开）:
   - 端口三分类显式声明：VAR_INPUT / VAR_STATE / VAR_OUTPUT
   - 模板体每个 STATE/OUTPUT 字段恰好一条赋值，右端为单表达式；
     表达式内自引用状态字段 = 上一周期值（更新序 = 声明序）
   - 预处理器为每个可写字段生成一个共享单表达式 FUNCTION 实体
     （全程序一份实现，inline.v 展开域内），调用点只展开为
     "输入绑定 + 赋值调用"，不复制算法体
   ================================================================ *)

(* @tpl RS_V1 lib=demo version=1.2 wcet=20 max_instances=64 *)
FUNCTION_BLOCK RS_V1
VAR_INPUT            (* 输入端口：调用点绑定表达式 → 周期内临时量 *)
  S : BOOL;
  R : BOOL;
END_VAR
VAR_STATE            (* 状态字段：每实例一份 → <inst>_Q 全局（ME-2/PRE-7）*)
  Q : BOOL;
END_VAR
  Q := S OR (Q AND NOT R);
END_FUNCTION_BLOCK

(* 展开约束:
   T-1 体内只引用声明端口；每字段一条单表达式更新规则
   T-2 每实例每周期至多调用一次（禁重入）
   T-3 实例输出之间不得别名绑定
   T-4 字段顺序 = 声明顺序（更新序，确定性展开）
   展开映射:
     模板 <TPL>.<field> 赋值 -> 共享实体 FUNCTION <TPL>_<field>（一份）
     调用点 inst(A := e, ...) -> <inst>__in_A := e; <inst>_f := <TPL>_f(args); *)
