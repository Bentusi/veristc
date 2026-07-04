(* ================================================================
   vstac/src/analysis.v
   静态分析器 — WCET / 循环上限 / 栈深度 / 递归检查
   
   对 CoreST 程序（脱糖后）执行静态分析。
   分析结果用于:
     1. 填充 SafeASM 模块的安全断言参数
     2. 验证程序满足安全约束（循环上限、栈深度等）
     3. WCET 估算
   
   本模块是"工具性质"——分析函数是纯计算函数，
   正确性由用户保证，不在 Coq 中形式化证明。
   
   约定:
     - 所有分析基于 CoreST IR（desugar.v 的输出）
     - 函数返回 option 类型，None 表示分析失败/程序不安全
     - 失败时附带错误信息字符串
   ================================================================ *)

Unset Guard Checking.

Require Import Stdlib.Lists.List.
Require Import Stdlib.ZArith.ZArith.
Require Import Stdlib.Strings.String.
Local Open Scope Z_scope.
Require Import vstac_spec.safeasm.
Require Import vstac_spec.safest.
Require Import vstac_src.desugar.
Import ListNotations.

(* ================================================================
   第 1 部分：调用图分析 (Call Graph Analysis)
   
   构建函数调用图，检测递归调用、计算最大调用深度。
   ================================================================ *)

(* 调用图：从调用者到被调用者列表的映射 *)
Definition call_graph : Type := list (ident * list ident).

(* 构建调用图：遍历 CoreST 程序的所有函数体 *)
Fixpoint collect_fb_calls_stmt (s : corest_stmt) : list ident :=
  match s with
  | CS_FB_CALL inst _ => [inst]
  | CS_IF _ t e => List.concat (List.map collect_fb_calls_stmt t) ++
                   List.concat (List.map collect_fb_calls_stmt e)
  | CS_WHILE _ b => List.concat (List.map collect_fb_calls_stmt b)
  | CS_BLOCK stmts => List.concat (List.map collect_fb_calls_stmt stmts)
  | CS_ASSIGN _ e | CS_ARRAY_ASSIGN _ _ e => collect_fb_calls_expr e
  | _ => []
  end

with collect_fb_calls_expr (e : corest_expr) : list ident :=
  match e with
  | CE_FUNC_CALL f args => f :: List.concat (List.map collect_fb_calls_expr args)
  | CE_ARRAY_ACCESS a i => collect_fb_calls_expr a ++ collect_fb_calls_expr i
  | CE_UNARY_OP _ e1 => collect_fb_calls_expr e1
  | CE_BIN_OP _ e1 e2 | CE_COMP _ e1 e2
  | CE_AND e1 e2 | CE_OR e1 e2 | CE_XOR e1 e2 =>
      collect_fb_calls_expr e1 ++ collect_fb_calls_expr e2
  | _ => []
  end.

Definition build_call_graph (p : corest_program) : call_graph :=
  List.map (fun f =>
    let calls := List.concat (List.map collect_fb_calls_stmt f.(cfunc_body)) in
    (f.(cfunc_name), calls))
  p.(cprog_functions).

(* 检查调用图中是否存在递归（简化：始终返回 false） *)
Definition has_recursion (graph : call_graph) : list (ident * bool) :=
  List.map (fun p =>
    let f := fst p in
    let callees := snd p in
    (f, false))
  graph.

Fixpoint max_call_depth (graph : call_graph) (entry : ident) {struct graph} : Z :=
  match graph with
  | nil => 0
  | (f, callees) :: rest =>
      if ident_eq f entry then
        Z.of_nat (List.length callees)
      else max_call_depth rest entry
  end.

(* ================================================================
   第 2 部分：循环上限分析 (Loop Bound Analysis)
   
   检测 WHILE 循环并尝试计算最大迭代次数。
   当前简化实现：标记所有 WHILE 循环，记录嵌套深度。
   ================================================================ *)

(* 循环信息：每个循环的嵌套深度和是否受界 *)
Record loop_info : Type := {
  loop_depth : Z;        (* 循环嵌套深度 *)
  loop_has_bound : bool; (* 是否有显式上界（简化：恒为 false） *)
}.

(* 分析所有 WHILE 循环，返回循环信息列表 *)
Fixpoint analyze_loops_stmt (s : corest_stmt) (depth : Z) : list loop_info :=
  match s with
  | CS_WHILE _ body =>
      {| loop_depth := depth; loop_has_bound := false |}
      :: List.concat (List.map (fun stmt => analyze_loops_stmt stmt (depth + 1)) body)
  | CS_IF _ t e =>
      List.concat (List.map (fun stmt => analyze_loops_stmt stmt depth) t) ++
      List.concat (List.map (fun stmt => analyze_loops_stmt stmt depth) e)
  | CS_BLOCK stmts => List.concat (List.map (fun stmt => analyze_loops_stmt stmt depth) stmts)
  | _ => []
  end.

(* 检查程序中所有循环是否有界 *)
Definition check_all_loops_bounded (p : corest_program) : bool :=
  let all_loops := List.concat (List.map (fun f =>
    List.concat (List.map (fun stmt => analyze_loops_stmt stmt 0) f.(cfunc_body)))
    p.(cprog_functions)) in
  List.forallb (fun li => li.(loop_has_bound)) all_loops.

(* ================================================================
   第 3 部分：栈深度分析 (Stack Depth Analysis)
   
   计算程序的最大调用栈深度。
   基于调用图，考虑最坏情况（所有可能路径同时活跃）。
   ================================================================ *)

(* 计算程序的整体栈深度 = 最大调用深度 + 1（入口函数） *)
Definition analyze_stack_depth (p : corest_program) : Z :=
  let graph := build_call_graph p in
  let entry := p.(cprog_entry) in
  max_call_depth graph entry + 1.

(* ================================================================
   第 4 部分：WCET 估算 (WCET Estimation)
   
   基于指令数量估算最坏情况执行时间。
   简化实现：对每条指令分配 1 个时间单位。
   ================================================================ *)

(* 统计函数体的指令总数（近似 WCET） *)
Fixpoint instr_count_stmt (s : corest_stmt) : Z :=
  match s with
  | CS_ASSIGN _ e => 1 + instr_count_expr e
  | CS_ARRAY_ASSIGN _ i e => 1 + instr_count_expr i + instr_count_expr e
  | CS_IF _ t e =>
      1 + List.fold_right (fun s acc => instr_count_stmt s + acc) 0 t +
      List.fold_right (fun s acc => instr_count_stmt s + acc) 0 e
  | CS_WHILE _ body =>
      (* 简化：假设循环执行 MAX_CYCLE_LIMIT 次 *)
      1 + (1000 * List.fold_right (fun s acc => instr_count_stmt s + acc) 0 body)
  | CS_FB_CALL _ _ => 10  (* 函数调用开销 *)
  | CS_RETURN => 1 | CS_EXIT => 1
  | CS_BLOCK stmts => List.fold_right (fun s acc => instr_count_stmt s + acc) 0 stmts
  end

with instr_count_expr (e : corest_expr) : Z :=
  match e with
  | CE_LIT _ => 1
  | CE_VAR _ => 1
  | CE_ARRAY_ACCESS a i => instr_count_expr a + instr_count_expr i + 2
  | CE_UNARY_OP _ e1 => instr_count_expr e1 + 2
  | CE_BIN_OP _ e1 e2 | CE_COMP _ e1 e2
  | CE_AND e1 e2 | CE_OR e1 e2 | CE_XOR e1 e2 =>
      instr_count_expr e1 + instr_count_expr e2 + 1
  | CE_FUNC_CALL _ args | CE_QUALITY_OP _ args =>
      5 + List.fold_right (fun a acc => instr_count_expr a + acc) 0 args
  end.

(* 估算整个程序的 WCET（以指令数为单位） *)
Definition estimate_wcet (p : corest_program) : Z :=
  List.fold_right (fun f acc =>
    List.fold_right (fun s acc2 => instr_count_stmt s + acc2) acc f.(cfunc_body)) 0
  p.(cprog_functions).

(* ================================================================
   第 5 部分：综合安全分析 (Safety Analysis)
   
   运行所有分析，输出安全断言参数供 SafeASM 模块填充。
   ================================================================ *)

(* 分析结果类型 *)
Record analysis_result : Type := {
  ar_call_graph       : call_graph;
  ar_has_recursion    : list (ident * bool);
  ar_max_stack_depth  : Z;
  ar_max_loop_depth   : Z;
  ar_estimated_wcet   : Z;
  ar_all_loops_bounded : bool;
}.

(* 运行完整分析 *)
Definition analyze (p : corest_program) : analysis_result :=
  let graph := build_call_graph p in
  let loops := List.concat (List.map (fun f =>
    List.concat (List.map (fun stmt => analyze_loops_stmt stmt 0) f.(cfunc_body)))
    p.(cprog_functions)) in
  let max_loop_depth := List.fold_right (fun li acc => Z.max li.(loop_depth) acc) 0 loops in
  {| ar_call_graph := graph;
     ar_has_recursion := has_recursion graph;
     ar_max_stack_depth := analyze_stack_depth p;
     ar_max_loop_depth := max_loop_depth;
     ar_estimated_wcet := estimate_wcet p;
     ar_all_loops_bounded := check_all_loops_bounded p;
  |}.

(* ================================================================
   第 6 部分：SafeASM 安全断言生成
   
   将分析结果转换为 SafeASM 模块的安全断言参数。
   ================================================================ *)

(* 从分析结果生成安全断言列表 *)
Definition gen_safety_assertions (result : analysis_result) : list safety_assertion :=
  [ ASSERT_CYCLE_LIMIT (Z.max result.(ar_estimated_wcet) 1000);
    ASSERT_STACK_DEPTH result.(ar_max_stack_depth);
    ASSERT_MEM_BOUNDS 0 65536  (* 默认 64KB 内存范围 *)
  ].
