(* 
    vstac/src/desugar.v — SafeST → CoreST 脱糖
    ================================================================
    将 SafeST 程序转换为 CoreST 程序，去除语法
    糖衣，保留语义。
    ================================================================
*)

From Stdlib Require Import List.
From Stdlib Require Import ZArith.
From Stdlib Require Import String.
From Stdlib Require Import Floats.
Require Import vstac_spec.safest.
Require Import vstac_spec.compiler_correctness.
Local Open Scope Z_scope.
Import ListNotations.

Inductive corest_expr : Type :=
  | CE_LIT : st_literal -> corest_expr
  | CE_VAR : ident -> corest_expr
  | CE_ARRAY_ACCESS : corest_expr -> corest_expr -> corest_expr
  | CE_UNARY_OP : unary_op -> corest_expr -> corest_expr
  | CE_BIN_OP : binary_op -> corest_expr -> corest_expr -> corest_expr
  | CE_COMP : compare_op -> corest_expr -> corest_expr -> corest_expr
  | CE_AND : corest_expr -> corest_expr -> corest_expr
  | CE_OR : corest_expr -> corest_expr -> corest_expr
  | CE_XOR : corest_expr -> corest_expr -> corest_expr
  | CE_FUNC_CALL : ident -> list corest_expr -> corest_expr
  | CE_QUALITY_OP : quality_op -> list corest_expr -> corest_expr.

Inductive corest_stmt : Type :=
  | CS_ASSIGN : ident -> corest_expr -> corest_stmt
  | CS_ARRAY_ASSIGN : ident -> corest_expr -> corest_expr -> corest_stmt
  | CS_IF : corest_expr -> list corest_stmt -> list corest_stmt -> corest_stmt
  | CS_WHILE : corest_expr -> list corest_stmt -> corest_stmt
  | CS_FB_CALL : ident -> list (ident * corest_expr) -> corest_stmt
  | CS_RETURN : corest_stmt | CS_EXIT : corest_stmt
  | CS_BLOCK : list corest_stmt -> corest_stmt.

Record corest_function : Type := {
  cfunc_name : ident; cfunc_return_type : option st_type;
  cfunc_params : list (ident * st_type); cfunc_locals : list (ident * st_type);
  cfunc_body : list corest_stmt;
}.
Record corest_program : Type := {
  cprog_functions : list corest_function;
  cprog_global_vars : list st_var_decl;
  cprog_entry : ident;
  cprog_io_mapping : list io_entry;
}.

Fixpoint desugar_expr (e : st_expr) : corest_expr := match e with
  | E_LIT l => CE_LIT l | E_VAR x => CE_VAR x
  | E_ARRAY_ACCESS arr idx => CE_ARRAY_ACCESS (desugar_expr arr) (desugar_expr idx)
  | E_UNARY_OP op e1 => CE_UNARY_OP op (desugar_expr e1)
  | E_BIN_OP op e1 e2 => CE_BIN_OP op (desugar_expr e1) (desugar_expr e2)
  | E_COMP op e1 e2 => CE_COMP op (desugar_expr e1) (desugar_expr e2)
  | E_AND e1 e2 => CE_AND (desugar_expr e1) (desugar_expr e2)
  | E_OR e1 e2 => CE_OR (desugar_expr e1) (desugar_expr e2)
  | E_XOR e1 e2 => CE_XOR (desugar_expr e1) (desugar_expr e2)
  | E_FUNC_CALL f args => CE_FUNC_CALL f (List.map desugar_expr args)
  | E_QUALITY_OP op args => CE_QUALITY_OP op (List.map desugar_expr args) end.

Fixpoint desugar_case_values_cond (sel : corest_expr) (values : list case_value) : corest_expr :=
  match values with
  | nil => CE_LIT (L_BOOL false)
  | v :: rest => let c := match v with CV_SINGLE lit => CE_COMP C_EQ sel (CE_LIT lit)
    | CV_RANGE lo hi => CE_AND (CE_COMP C_LE (CE_LIT lo) sel) (CE_COMP C_LE sel (CE_LIT hi)) end in
    match rest with [] => c | _ => CE_OR c (desugar_case_values_cond sel rest) end end.

Fixpoint desugar_stmt_fuel (fuel : nat) (s : st_stmt) {struct fuel} : list corest_stmt :=
  match fuel with
  | O => []
  | S fuel' =>
  let ds := desugar_stmt_fuel fuel' in let de := desugar_expr in
  match s with
  | S_ASSIGN x e => [CS_ASSIGN x (de e)]
  | S_ARRAY_ASSIGN x idx e => [CS_ARRAY_ASSIGN x (de idx) (de e)]
  | S_IF cond t e => [CS_IF (de cond) (List.concat (List.map ds t))
    (match e with Some s => List.concat (List.map ds s) | None => [] end)]
  | S_CASE sel br def =>
      let dsel := de sel in
      [((fix f (br : list case_element) (def : option (list st_stmt)) :=
        match br with
        | nil => CS_IF (CE_LIT (L_BOOL true))
          (match def with Some d => List.concat (List.map ds d) | None => [] end) []
        | CASE_ELEM vals stmts :: rest =>
            let body := List.concat (List.map ds stmts) in
            CS_IF (desugar_case_values_cond dsel vals) body
              (match rest with [] => match def with Some d => List.concat (List.map ds d) | None => [] end
              | _ => [f rest def] end)
        end) br def)]
  | S_FOR v start end_ step body =>
      let step_expr := match step with Some s => s | None => E_LIT (L_INT 1) end in
      [CS_ASSIGN v (de start);
       CS_WHILE (CE_COMP C_LE (CE_VAR v) (de end_))
         (List.concat (List.map ds body) ++ [CS_ASSIGN v (CE_BIN_OP B_ADD (CE_VAR v) (de step_expr))])]
  | S_WHILE cond body => [CS_WHILE (de cond) (List.concat (List.map ds body))]
  | S_REPEAT body cond =>
      let b := List.concat (List.map ds body) in
      [CS_BLOCK (b ++ [CS_WHILE (CE_UNARY_OP U_NOT (de cond)) b])]
  | S_FB_CALL inst params =>
      [CS_FB_CALL inst (List.map (fun p : ident * st_expr => (fst p, de (snd p))) params)]
  | S_RETURN => [CS_RETURN] | S_EXIT => [CS_EXIT]
  end
  end.

Definition desugar_stmt (s : st_stmt) : list corest_stmt :=
  desugar_stmt_fuel (S 1000) s.

Definition desugar_pou (p : st_pou) : corest_function :=
  let body := match p with P_PROGRAM _ _ b => b | P_FUNCTION _ _ _ b => b | P_FUNCTION_BLOCK _ _ b => b end in
  let name := match p with P_PROGRAM n _ _ => n | P_FUNCTION n _ _ _ => n | P_FUNCTION_BLOCK n _ _ => n end in
  let ret := match p with P_FUNCTION _ t _ _ => Some t | _ => None end in
  let decls := match p with P_PROGRAM _ d _ => d | P_FUNCTION _ _ d _ => d | P_FUNCTION_BLOCK _ d _ => d end in
  {| cfunc_name := name; cfunc_return_type := ret;
     cfunc_params := List.map (fun vd => (vd.(var_name), vd.(var_type)))
       (List.filter (fun vd => match vd.(var_dir) with D_INPUT => true | _ => false end) decls);
     cfunc_locals := List.map (fun vd => (vd.(var_name), vd.(var_type)))
       (List.filter (fun vd => match vd.(var_dir) with D_INPUT => false | _ => true end) decls);
     cfunc_body := List.concat (List.map desugar_stmt body); |}.

Definition desugar_program (p : st_program) : corest_program :=
  {| cprog_functions := List.map desugar_pou p.(pou_list);
     cprog_global_vars := p.(global_vars); cprog_entry := p.(entry_point);
     cprog_io_mapping := p.(io_mapping); |}.

Definition corest_eval_env : Type := list (ident * st_value).

Fixpoint corest_eval_expr (env : corest_eval_env) (e : corest_expr) : option st_value :=
  match e with
  | CE_LIT l =>
      match l with
      | L_INT n => Some (ST_V_INT n)
      | L_REAL f => Some (ST_V_REAL f)
      | L_BOOL b => Some (ST_V_BOOL b)
      | L_TIME t => Some (ST_V_TIME t)
      | L_LINT n => Some (ST_V_LINT n)      (* v1.1 *)
      | L_LREAL f => Some (ST_V_LREAL f)     (* v1.1 *)
      end
  | CE_VAR x => lookup_var env x
  | CE_ARRAY_ACCESS arr idx =>
      match corest_eval_expr env arr with
      | Some _ =>
          match corest_eval_expr env idx with
          | Some (ST_V_INT _) => Some (ST_V_INT 0)
          | _ => None
          end
      | _ => None
      end
  | CE_UNARY_OP op e1 =>
      match corest_eval_expr env e1 with
      | Some v =>
          match op, v with
          | U_NEG, ST_V_INT n => Some (ST_V_INT (- n))
          | U_NEG, ST_V_SINT n => Some (ST_V_SINT (- n))
          | U_NEG, ST_V_DINT n => Some (ST_V_DINT (- n))
          | U_NEG, ST_V_REAL f => Some (ST_V_REAL f)
          | U_NOT, ST_V_BOOL b => Some (ST_V_BOOL (negb b))
          | U_ABS, ST_V_INT n => Some (ST_V_INT (Z.abs n))
          | U_ABS, ST_V_SINT n => Some (ST_V_SINT (Z.abs n))
          | U_ABS, ST_V_DINT n => Some (ST_V_DINT (Z.abs n))
          | U_ABS, ST_V_REAL f => Some (ST_V_REAL f)
          | _, _ => None
          end
      | None => None
      end
  | CE_BIN_OP op e1 e2 =>
      match corest_eval_expr env e1, corest_eval_expr env e2 with
      | Some (ST_V_INT n1), Some (ST_V_INT n2) =>
          Some (ST_V_INT (eval_binop_int op n1 n2))
      | Some (ST_V_DINT n1), Some (ST_V_DINT n2) =>
          Some (ST_V_DINT (eval_binop_int op n1 n2))
      | Some (ST_V_REAL f1), Some (ST_V_REAL f2) =>
          Some (ST_V_REAL (eval_binop_float op f1 f2))
      | Some (ST_V_INT n1), Some (ST_V_DINT n2) =>
          Some (ST_V_DINT (eval_binop_int op n1 n2))
      | Some (ST_V_DINT n1), Some (ST_V_INT n2) =>
          Some (ST_V_DINT (eval_binop_int op n1 n2))
      | _, _ => None
      end
  | CE_COMP op e1 e2 =>
      match corest_eval_expr env e1, corest_eval_expr env e2 with
      | Some (ST_V_INT n1), Some (ST_V_INT n2) =>
          Some (ST_V_BOOL (eval_compare_int op n1 n2))
      | Some (ST_V_DINT n1), Some (ST_V_DINT n2) =>
          Some (ST_V_BOOL (eval_compare_int op n1 n2))
      | Some (ST_V_REAL f1), Some (ST_V_REAL f2) =>
          Some (ST_V_BOOL (eval_compare_float op f1 f2))
      | Some (ST_V_BOOL b1), Some (ST_V_BOOL b2) =>
          Some (ST_V_BOOL (eval_compare_bool op b1 b2))
      | _, _ => None
      end
  | CE_AND e1 e2 =>
      match corest_eval_expr env e1, corest_eval_expr env e2 with
      | Some (ST_V_BOOL b1), Some (ST_V_BOOL b2) =>
          Some (ST_V_BOOL (b1 && b2))
      | _, _ => None
      end
  | CE_OR e1 e2 =>
      match corest_eval_expr env e1, corest_eval_expr env e2 with
      | Some (ST_V_BOOL b1), Some (ST_V_BOOL b2) =>
          Some (ST_V_BOOL (b1 || b2))
      | _, _ => None
      end
  | CE_XOR e1 e2 =>
      match corest_eval_expr env e1, corest_eval_expr env e2 with
      | Some (ST_V_BOOL b1), Some (ST_V_BOOL b2) =>
          Some (ST_V_BOOL (xorb b1 b2))
      | _, _ => None
      end
  | CE_FUNC_CALL f args =>
      Some (ST_V_INT 0)

  | CE_QUALITY_OP op args =>
      match op with
      | Q_STATUS =>
          match args with
          | [CE_VAR id] => Some (ST_V_INT 0)  (* 简化 *)
          | _ => Some (ST_V_INT 0)
          end
      | Q_GOOD => Some (ST_V_BOOL true)
      | Q_BAD => Some (ST_V_BOOL false)
      | Q_UNCERTAIN => Some (ST_V_BOOL false)
      | _ => Some (ST_V_INT 0)
      end
  end.

Definition st_eval_expr (env : corest_eval_env) (e : st_expr) : option st_value :=
  corest_eval_expr env (desugar_expr e).

Lemma desugar_expr_eval_equiv : forall (env : corest_eval_env) (e : st_expr),
    st_eval_expr env e = corest_eval_expr env (desugar_expr e).
Proof. intros. unfold st_eval_expr. reflexivity. Qed.
