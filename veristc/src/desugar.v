(* 
    veristc/src/desugar.v — SafeST → CoreST 脱糖
    ================================================================
    将 SafeST 程序转换为 CoreST 程序，去除语法
    糖衣，保留语义。
    ================================================================
*)

From Stdlib Require Import List.
From Stdlib Require Import ZArith.
From Stdlib Require Import String.
From Stdlib Require Import Bool.
From Stdlib Require Import Floats.
Require Import veristc_spec.safest.
Require Import veristc_spec.st_semantics.
Local Open Scope Z_scope.
Import ListNotations.

Lemma ds_app_cons_assoc :
  forall (A : Type) (xs zs : list A) (y : A) (ys : list A),
    (xs ++ (y :: ys)) ++ zs = xs ++ (y :: (ys ++ zs)).
Proof.
  intros A xs zs y ys.
  induction xs as [|a xs IH]; simpl.
  - reflexivity.
  - rewrite IH. reflexivity.
Qed.

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
  | v :: rest =>
      let c := match v with
               | CV_SINGLE lit => CE_COMP C_EQ sel (CE_LIT lit)
               | CV_RANGE lo hi =>
                   CE_AND (CE_COMP C_LE (CE_LIT lo) sel)
                          (CE_COMP C_LE sel (CE_LIT hi))
               end in
      CE_OR c (desugar_case_values_cond sel rest)
  end.

Definition case_values_core := core_case_values.
Definition case_branches_core := core_case_branches.

Lemma desugar_case_values_cond_single_cons :
  forall (sel : corest_expr) (n : Z) (rest : list case_value),
    desugar_case_values_cond sel (CV_SINGLE (L_INT n) :: rest) =
    CE_OR (CE_COMP C_EQ sel (CE_LIT (L_INT n)))
          (desugar_case_values_cond sel rest).
Proof. reflexivity. Qed.

Lemma desugar_case_values_cond_range_cons :
  forall (sel : corest_expr) (lo hi : Z) (rest : list case_value),
    desugar_case_values_cond sel (CV_RANGE (L_INT lo) (L_INT hi) :: rest) =
    CE_OR
      (CE_AND (CE_COMP C_LE (CE_LIT (L_INT lo)) sel)
              (CE_COMP C_LE sel (CE_LIT (L_INT hi))))
      (desugar_case_values_cond sel rest).
Proof. reflexivity. Qed.

Fixpoint desugar_case_chain_with
         (D : list st_stmt -> list corest_stmt)
         (sel : corest_expr) (branches : list case_element)
         (default : option (list st_stmt)) {struct branches} : corest_stmt :=
  match branches with
  | nil =>
      CS_IF (CE_LIT (L_BOOL true))
        (match default with
         | Some body => D body
         | None => nil
         end)
        nil
  | CASE_ELEM values body :: rest =>
      CS_IF (desugar_case_values_cond sel values)
        (D body)
        (match rest with
         | nil =>
             match default with
             | Some default_body => D default_body
             | None => nil
             end
         | _ => [desugar_case_chain_with D sel rest default]
         end)
  end.

(* 结构递归脱糖：不对程序深度设置静默上限。
   列表辅助函数是 desugar_stmt 内部的局部结构递归，避免引入 fuel。 *)
Fixpoint desugar_stmt (s : st_stmt) {struct s} : list corest_stmt :=
  let fix desugar_stmts_inner (stmts : list st_stmt) {struct stmts}
      : list corest_stmt :=
    match stmts with
    | nil => nil
    | head :: tail => desugar_stmt head ++ desugar_stmts_inner tail
    end in
  match s with
  | S_ASSIGN x e => [CS_ASSIGN x (desugar_expr e)]
  | S_ARRAY_ASSIGN x idx e =>
      [CS_ARRAY_ASSIGN x (desugar_expr idx) (desugar_expr e)]
  | S_IF cond then_body else_body =>
      [CS_IF (desugar_expr cond)
         (desugar_stmts_inner then_body)
         (match else_body with
          | Some body => desugar_stmts_inner body
          | None => nil
          end)]
  | S_CASE sel branches default =>
      [desugar_case_chain_with desugar_stmts_inner
         (desugar_expr sel) branches default]
  | S_FOR v start end_ step body =>
      let step_expr :=
        match step with Some e => e | None => E_LIT (L_INT 1) end in
      [CS_ASSIGN v (desugar_expr start);
       CS_WHILE (CE_COMP C_LE (CE_VAR v) (desugar_expr end_))
         (desugar_stmts_inner body ++
          [CS_ASSIGN v
             (CE_BIN_OP B_ADD (CE_VAR v) (desugar_expr step_expr))])]
  | S_WHILE cond body =>
      [CS_WHILE (desugar_expr cond) (desugar_stmts_inner body)]
  | S_REPEAT body cond =>
      let dbody := desugar_stmts_inner body in
      [CS_BLOCK
         (dbody ++ [CS_WHILE (CE_UNARY_OP U_NOT (desugar_expr cond)) dbody])]
  | S_FB_CALL inst params =>
      [CS_FB_CALL inst
         (List.map (fun p : ident * st_expr =>
            (fst p, desugar_expr (snd p))) params)]
  | S_RETURN => [CS_RETURN]
  | S_EXIT => [CS_EXIT]
  end.

Definition desugar_stmts (stmts : list st_stmt) : list corest_stmt :=
  List.concat (List.map desugar_stmt stmts).

Definition desugar_case_chain
           (sel : corest_expr) (branches : list case_element)
           (default : option (list st_stmt)) : corest_stmt :=
  desugar_case_chain_with desugar_stmts sel branches default.

Lemma desugar_stmt_local_stmts_eq :
  forall (stmts : list st_stmt),
    (fix desugar_stmts_inner (xs : list st_stmt) {struct xs} : list corest_stmt :=
       match xs with
       | nil => nil
       | head :: tail => desugar_stmt head ++ desugar_stmts_inner tail
       end) stmts = desugar_stmts stmts.
Proof.
  induction stmts as [|head tail IH]; simpl.
  - reflexivity.
  - rewrite IH. unfold desugar_stmts. simpl.
    reflexivity.
Qed.

Lemma desugar_case_chain_local_eq :
  forall (sel : corest_expr) (branches : list case_element)
         (default : option (list st_stmt)),
    (let fix desugar_stmts_inner (xs : list st_stmt) {struct xs}
         : list corest_stmt :=
       match xs with
       | nil => nil
       | head :: tail => desugar_stmt head ++ desugar_stmts_inner tail
       end in
     desugar_case_chain_with desugar_stmts_inner sel branches default) =
    desugar_case_chain sel branches default.
Proof.
  intros sel branches.
  induction branches as [|branch rest IH]; intros default;
    unfold desugar_case_chain; simpl.
  - destruct default as [body|]; simpl.
    + rewrite (desugar_stmt_local_stmts_eq body). reflexivity.
    + reflexivity.
  - destruct branch as [values body].
    destruct rest as [|next rest'].
    + destruct default as [default_body|]; simpl.
      * rewrite (desugar_stmt_local_stmts_eq body).
        rewrite (desugar_stmt_local_stmts_eq default_body). reflexivity.
      * rewrite (desugar_stmt_local_stmts_eq body). reflexivity.
    + rewrite (desugar_stmt_local_stmts_eq body).
      rewrite IH. reflexivity.
Qed.

Lemma desugar_stmts_cons :
  forall (head : st_stmt) (tail : list st_stmt),
    desugar_stmts (head :: tail) =
    desugar_stmt head ++ desugar_stmts tail.
Proof.
  intros head tail.
  unfold desugar_stmts.
  simpl.
  reflexivity.
Qed.

Lemma desugar_stmts_append :
  forall (xs ys : list st_stmt),
    desugar_stmts (xs ++ ys) = desugar_stmts xs ++ desugar_stmts ys.
Proof.
  induction xs as [|head tail IH]; intros ys; simpl.
  - reflexivity.
  - rewrite desugar_stmts_cons.
    rewrite IH.
    rewrite desugar_stmts_cons.
    repeat rewrite app_assoc.
    reflexivity.
Qed.

Lemma desugar_stmt_assign :
  forall (x : ident) (e : st_expr),
    desugar_stmt (S_ASSIGN x e) = [CS_ASSIGN x (desugar_expr e)].
Proof. intros. reflexivity. Qed.

Lemma desugar_stmt_if :
  forall (cond : st_expr) (then_body : list st_stmt)
         (else_body : option (list st_stmt)),
    desugar_stmt (S_IF cond then_body else_body) =
    [CS_IF (desugar_expr cond) (desugar_stmts then_body)
       (match else_body with
        | Some body => desugar_stmts body
        | None => nil
        end)].
Proof.
  intros cond then_body else_body.
  simpl.
  rewrite desugar_stmt_local_stmts_eq.
  destruct else_body; simpl.
  - rewrite desugar_stmt_local_stmts_eq. reflexivity.
  - reflexivity.
Qed.

Lemma desugar_stmt_while :
  forall (cond : st_expr) (body : list st_stmt),
    desugar_stmt (S_WHILE cond body) =
    [CS_WHILE (desugar_expr cond) (desugar_stmts body)].
Proof.
  intros cond body.
  simpl.
  rewrite desugar_stmt_local_stmts_eq.
  reflexivity.
Qed.

Lemma desugar_stmt_for :
  forall (v : ident) (start end_ : st_expr)
         (step : option st_expr) (body : list st_stmt),
    desugar_stmt (S_FOR v start end_ step body) =
    [CS_ASSIGN v (desugar_expr start);
     CS_WHILE
       (CE_COMP C_LE (CE_VAR v) (desugar_expr end_))
       (desugar_stmts body ++
        [CS_ASSIGN v
           (CE_BIN_OP B_ADD (CE_VAR v)
             (desugar_expr
               (match step with Some e => e | None => E_LIT (L_INT 1) end)))])].
Proof.
  intros v start end_ step body.
  simpl.
  rewrite desugar_stmt_local_stmts_eq.
  reflexivity.
Qed.

Lemma desugar_stmt_repeat :
  forall (body : list st_stmt) (cond : st_expr),
    desugar_stmt (S_REPEAT body cond) =
    [CS_BLOCK
       (desugar_stmts body ++
        [CS_WHILE (CE_UNARY_OP U_NOT (desugar_expr cond))
           (desugar_stmts body)])].
Proof.
  intros body cond.
  simpl.
  rewrite desugar_stmt_local_stmts_eq.
  reflexivity.
Qed.

Lemma desugar_stmt_case :
  forall (sel : st_expr) (branches : list case_element)
         (default : option (list st_stmt)),
    desugar_stmt (S_CASE sel branches default) =
    [desugar_case_chain (desugar_expr sel) branches default].
Proof.
  intros sel branches default.
  simpl.
  rewrite desugar_case_chain_local_eq.
  reflexivity.
Qed.


Definition desugar_pou (p : st_pou) : corest_function :=
  let body := match p with P_PROGRAM _ _ b => b | P_FUNCTION _ _ _ b => b | P_FUNCTION_BLOCK _ _ b => b end in
  let name := match p with P_PROGRAM n _ _ => n | P_FUNCTION n _ _ _ => n | P_FUNCTION_BLOCK n _ _ => n end in
  let ret := match p with P_FUNCTION _ t _ _ => Some t | _ => None end in
  let decls := match p with P_PROGRAM _ d _ => d | P_FUNCTION _ _ d _ => d | P_FUNCTION_BLOCK _ d _ => d end in
  {| cfunc_name := name; cfunc_return_type := ret;
     cfunc_params :=
       match p with
       | P_PROGRAM _ _ _ => nil
       | _ =>
           List.map (fun vd => (vd.(var_name), vd.(var_type)))
             (List.filter (fun vd =>
                match vd.(var_dir) with D_INPUT => true | _ => false end) decls)
       end;
     cfunc_locals :=
       match p with
       | P_PROGRAM _ _ _ =>
           List.map (fun vd => (vd.(var_name), vd.(var_type))) decls
       | _ =>
           List.map (fun vd => (vd.(var_name), vd.(var_type)))
             (List.filter (fun vd =>
                match vd.(var_dir) with D_INPUT => false | _ => true end) decls)
       end;
     cfunc_body := desugar_stmts body; |}.

Definition desugar_program (p : st_program) : corest_program :=
  {| cprog_functions := List.map desugar_pou p.(pou_list);
     cprog_global_vars := p.(global_vars); cprog_entry := p.(entry_point);
     cprog_io_mapping := p.(io_mapping); |}.

Definition corest_eval_env : Type := list (ident * st_value).

Definition corest_eval_binop_value (op : binary_op) (v1 v2 : st_value)
  : option st_value :=
  match v1, v2 with
  | ST_V_INT n1, ST_V_INT n2 =>
      Some (ST_V_INT (eval_binop_int op n1 n2))
  | ST_V_DINT n1, ST_V_DINT n2 =>
      Some (ST_V_DINT (eval_binop_int op n1 n2))
  | ST_V_REAL f1, ST_V_REAL f2 =>
      Some (ST_V_REAL (eval_binop_float op f1 f2))
  | ST_V_INT n1, ST_V_DINT n2 =>
      Some (ST_V_DINT (eval_binop_int op n1 n2))
  | ST_V_DINT n1, ST_V_INT n2 =>
      Some (ST_V_DINT (eval_binop_int op n1 n2))
  | ST_V_LINT n1, ST_V_LINT n2 =>
      Some (ST_V_LINT (eval_binop_int op n1 n2))
  | ST_V_INT n1, ST_V_LINT n2 =>
      Some (ST_V_LINT (eval_binop_int op n1 n2))
  | ST_V_LINT n1, ST_V_INT n2 =>
      Some (ST_V_LINT (eval_binop_int op n1 n2))
  | ST_V_DINT n1, ST_V_LINT n2 =>
      Some (ST_V_LINT (eval_binop_int op n1 n2))
  | ST_V_LINT n1, ST_V_DINT n2 =>
      Some (ST_V_LINT (eval_binop_int op n1 n2))
  | ST_V_REAL f1, ST_V_LREAL f2 =>
      Some (ST_V_LREAL (eval_binop_float op f1 f2))
  | ST_V_LREAL f1, ST_V_REAL f2 =>
      Some (ST_V_LREAL (eval_binop_float op f1 f2))
  | ST_V_LREAL f1, ST_V_LREAL f2 =>
      Some (ST_V_LREAL (eval_binop_float op f1 f2))
  | _, _ => None
  end.

Definition corest_eval_binop (op : binary_op) (o1 o2 : option st_value)
  : option st_value :=
  match o1, o2 with
  | Some v1, Some v2 => corest_eval_binop_value op v1 v2
  | _, _ => None
  end.

Definition corest_eval_compare_value (op : compare_op)
  (v1 v2 : st_value) : option st_value :=
  match v1, v2 with
  | ST_V_INT n1, ST_V_INT n2 =>
      Some (ST_V_BOOL (eval_compare_int op n1 n2))
  | ST_V_DINT n1, ST_V_DINT n2 =>
      Some (ST_V_BOOL (eval_compare_int op n1 n2))
  | ST_V_INT n1, ST_V_DINT n2 =>
      Some (ST_V_BOOL (eval_compare_int op n1 n2))
  | ST_V_DINT n1, ST_V_INT n2 =>
      Some (ST_V_BOOL (eval_compare_int op n1 n2))
  | ST_V_REAL f1, ST_V_REAL f2 =>
      Some (ST_V_BOOL (eval_compare_float op f1 f2))
  | ST_V_BOOL b1, ST_V_BOOL b2 =>
      Some (ST_V_BOOL (eval_compare_bool op b1 b2))
  | ST_V_LINT n1, ST_V_LINT n2 =>
      Some (ST_V_BOOL (eval_compare_int op n1 n2))
  | ST_V_DINT n1, ST_V_LINT n2 =>
      Some (ST_V_BOOL (eval_compare_int op n1 n2))
  | ST_V_LINT n1, ST_V_DINT n2 =>
      Some (ST_V_BOOL (eval_compare_int op n1 n2))
  | ST_V_REAL f1, ST_V_LREAL f2 =>
      Some (ST_V_BOOL (eval_compare_float op f1 f2))
  | ST_V_LREAL f1, ST_V_REAL f2 =>
      Some (ST_V_BOOL (eval_compare_float op f1 f2))
  | ST_V_LREAL f1, ST_V_LREAL f2 =>
      Some (ST_V_BOOL (eval_compare_float op f1 f2))
  | _, _ => None
  end.

Definition corest_eval_compare (op : compare_op) (o1 o2 : option st_value)
  : option st_value :=
  match o1, o2 with
  | Some v1, Some v2 => corest_eval_compare_value op v1 v2
  | _, _ => None
  end.

Definition corest_eval_logic_and (o1 o2 : option st_value) : option st_value :=
  match o1, o2 with
  | Some (ST_V_BOOL b1), Some (ST_V_BOOL b2) =>
      Some (ST_V_BOOL (b1 && b2))
  | _, _ => None
  end.

Definition corest_eval_logic_or (o1 o2 : option st_value) : option st_value :=
  match o1, o2 with
  | Some (ST_V_BOOL b1), Some (ST_V_BOOL b2) =>
      Some (ST_V_BOOL (b1 || b2))
  | _, _ => None
  end.

Definition corest_eval_logic_xor (o1 o2 : option st_value) : option st_value :=
  match o1, o2 with
  | Some (ST_V_BOOL b1), Some (ST_V_BOOL b2) =>
      Some (ST_V_BOOL (xorb b1 b2))
  | _, _ => None
  end.

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
          | U_NEG, ST_V_LINT n => Some (ST_V_LINT (- n))
          | U_NEG, ST_V_LREAL f => Some (ST_V_LREAL f)
          | U_NOT, ST_V_BOOL b => Some (ST_V_BOOL (negb b))
          | U_ABS, ST_V_INT n => Some (ST_V_INT (Z.abs n))
          | U_ABS, ST_V_SINT n => Some (ST_V_SINT (Z.abs n))
          | U_ABS, ST_V_DINT n => Some (ST_V_DINT (Z.abs n))
          | U_ABS, ST_V_REAL f => Some (ST_V_REAL f)
          | U_ABS, ST_V_LINT n => Some (ST_V_LINT (Z.abs n))
          | U_ABS, ST_V_LREAL f => Some (ST_V_LREAL f)
          | _, _ => None
          end
      | None => None
      end
  | CE_BIN_OP op e1 e2 =>
      corest_eval_binop op
        (corest_eval_expr env e1) (corest_eval_expr env e2)
  | CE_COMP op e1 e2 =>
      corest_eval_compare op
        (corest_eval_expr env e1) (corest_eval_expr env e2)
  | CE_AND e1 e2 =>
      corest_eval_logic_and
        (corest_eval_expr env e1) (corest_eval_expr env e2)
  | CE_OR e1 e2 =>
      corest_eval_logic_or
        (corest_eval_expr env e1) (corest_eval_expr env e2)
  | CE_XOR e1 e2 =>
      corest_eval_logic_xor
        (corest_eval_expr env e1) (corest_eval_expr env e2)
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
      | _ => Some (ST_V_INT 0)
      end
  end.

Lemma corest_eval_expr_comp :
  forall (env : corest_eval_env) (op : compare_op)
         (e1 e2 : corest_expr),
    corest_eval_expr env (CE_COMP op e1 e2) =
    corest_eval_compare op (corest_eval_expr env e1) (corest_eval_expr env e2).
Proof. reflexivity. Qed.

Lemma corest_eval_expr_and :
  forall (env : corest_eval_env) (e1 e2 : corest_expr),
    corest_eval_expr env (CE_AND e1 e2) =
    corest_eval_logic_and (corest_eval_expr env e1) (corest_eval_expr env e2).
Proof. reflexivity. Qed.

Lemma corest_eval_expr_or :
  forall (env : corest_eval_env) (e1 e2 : corest_expr),
    corest_eval_expr env (CE_OR e1 e2) =
    corest_eval_logic_or (corest_eval_expr env e1) (corest_eval_expr env e2).
Proof. reflexivity. Qed.

Definition st_eval_expr (env : corest_eval_env) (e : st_expr) : option st_value :=
  corest_eval_expr env (desugar_expr e).

Definition corest_assign_value (s : st_state) (x : ident) (v : st_value)
  : st_value :=
  match lookup_var s.(st_vars) x with
  | Some old => coerce_value_to_type (st_value_type old) v
  | None => v
  end.

Lemma desugar_expr_eval_equiv : forall (env : corest_eval_env) (e : st_expr),
    st_eval_expr env e = corest_eval_expr env (desugar_expr e).
Proof. intros. unfold st_eval_expr. reflexivity. Qed.

(* ================================================================
   CoreST 配置式小步语义

   配置 = 当前剩余 CoreST 语句列表 + st_state。
   与源语言 stmts_step 的形态保持一致，使后续语义保持证明可拼接。
   ================================================================ *)

Inductive corest_step :
  list corest_stmt -> st_state ->
  list corest_stmt -> st_state -> Prop :=
  | Cs_assign : forall (x : ident) (e : corest_expr) (rest : list corest_stmt)
                       (s : st_state) (v : st_value),
      corest_eval_expr s.(st_vars) e = Some v ->
      corest_step (CS_ASSIGN x e :: rest) s rest
                  (update_var s x (corest_assign_value s x v))

  | Cs_if_true : forall (cond : corest_expr) (then_body : list corest_stmt)
                        (else_body : list corest_stmt)
                        (rest : list corest_stmt) (s : st_state),
      corest_eval_expr s.(st_vars) cond = Some (ST_V_BOOL true) ->
      corest_step (CS_IF cond then_body else_body :: rest) s
                  (then_body ++ rest) s

  | Cs_if_false : forall (cond : corest_expr) (then_body : list corest_stmt)
                         (else_body : list corest_stmt)
                         (rest : list corest_stmt) (s : st_state),
      corest_eval_expr s.(st_vars) cond = Some (ST_V_BOOL false) ->
      corest_step (CS_IF cond then_body else_body :: rest) s
                  (else_body ++ rest) s

  | Cs_while_true : forall (cond : corest_expr) (body : list corest_stmt)
                           (rest : list corest_stmt) (s : st_state),
      corest_eval_expr s.(st_vars) cond = Some (ST_V_BOOL true) ->
      corest_step (CS_WHILE cond body :: rest) s
                  (body ++ CS_WHILE cond body :: rest) s

  | Cs_while_false : forall (cond : corest_expr) (body : list corest_stmt)
                            (rest : list corest_stmt) (s : st_state),
      corest_eval_expr s.(st_vars) cond = Some (ST_V_BOOL false) ->
      corest_step (CS_WHILE cond body :: rest) s rest s

  | Cs_block : forall (body rest : list corest_stmt) (s : st_state),
      corest_step (CS_BLOCK body :: rest) s (body ++ rest) s
.

Inductive star_corest_step :
  list corest_stmt -> st_state ->
  list corest_stmt -> st_state -> Prop :=
  | CsStar_refl : forall (stmts : list corest_stmt) (s : st_state),
      star_corest_step stmts s stmts s
  | CsStar_step : forall (stmts1 stmts2 stmts3 : list corest_stmt)
                         (s1 s2 s3 : st_state),
      corest_step stmts1 s1 stmts2 s2 ->
      star_corest_step stmts2 s2 stmts3 s3 ->
      star_corest_step stmts1 s1 stmts3 s3
.

Lemma ds_corest_step_tail :
  forall (stmts1 stmts2 : list corest_stmt)
         (s1 s2 : st_state) (tail : list corest_stmt),
    corest_step stmts1 s1 stmts2 s2 ->
    corest_step (stmts1 ++ tail) s1 (stmts2 ++ tail) s2.
Proof.
  intros stmts1 stmts2 s1 s2 tail Hstep.
  inversion Hstep; subst; simpl.
  - eapply Cs_assign; eauto.
  - replace ((then_body ++ rest) ++ tail)
      with (then_body ++ (rest ++ tail))
      by (rewrite app_assoc; reflexivity).
    eapply Cs_if_true; eauto.
  - replace ((else_body ++ rest) ++ tail)
      with (else_body ++ (rest ++ tail))
      by (rewrite app_assoc; reflexivity).
    eapply Cs_if_false; eauto.
  - replace ((body ++ (CS_WHILE cond body :: rest)) ++ tail)
      with (body ++ (CS_WHILE cond body :: (rest ++ tail)))
      by (rewrite ds_app_cons_assoc; reflexivity).
    eapply Cs_while_true; eauto.
  - eapply Cs_while_false; eauto.
  - replace ((body ++ rest) ++ tail)
      with (body ++ (rest ++ tail))
      by (rewrite app_assoc; reflexivity).
    eapply Cs_block; eauto.
Qed.

Lemma ds_star_corest_step_tail :
  forall (stmts1 stmts2 : list corest_stmt)
         (s1 s2 : st_state) (tail : list corest_stmt),
    star_corest_step stmts1 s1 stmts2 s2 ->
    star_corest_step (stmts1 ++ tail) s1 (stmts2 ++ tail) s2.
Proof.
  intros stmts1 stmts2 s1 s2 tail Hstar.
  induction Hstar as
    [stmts s | stmts1' stmts2' stmts3' s1' s2' s3' Hstep Hrest IH].
  - apply CsStar_refl.
  - eapply CsStar_step.
    + apply ds_corest_step_tail. exact Hstep.
    + exact IH.
Qed.

Lemma ds_star_corest_step_app :
  forall (xs : list corest_stmt) (s1 : st_state)
         (ys : list corest_stmt) (s2 : st_state)
         (zs : list corest_stmt) (s3 : st_state),
    star_corest_step xs s1 ys s2 ->
    star_corest_step ys s2 zs s3 ->
    star_corest_step xs s1 zs s3.
Proof.
  intros xs s1 ys s2 zs s3 Hxy.
  revert zs s3.
  induction Hxy as
    [stmts s | stmts1' stmts2' stmts3' s1' s2' s3' Hstep Hrest IH];
    intros zs s_final Hyz.
  - exact Hyz.
  - eapply CsStar_step.
    + exact Hstep.
    + exact (IH zs s_final Hyz).
Qed.

Definition cs_done (stmts : list corest_stmt) (s : st_state) : Prop :=
  stmts = nil.

Fixpoint ds_core_expr (e : st_expr) : bool :=
  match e with
  | E_LIT l =>
      match l with
      | L_BOOL _ | L_INT _ => true
      | _ => false
      end
  | E_VAR _ => true
  | E_UNARY_OP op e1 =>
      match op with
      | U_NEG | U_NOT => ds_core_expr e1
      | U_ABS => false
      end
  | E_BIN_OP op e1 e2 =>
      match op with
      | B_DIV | B_MOD => false
      | _ => ds_core_expr e1 && ds_core_expr e2
      end
  | E_COMP _ e1 e2 => ds_core_expr e1 && ds_core_expr e2
  | E_AND e1 e2 | E_OR e1 e2 | E_XOR e1 e2 =>
      ds_core_expr e1 && ds_core_expr e2
  | _ => false
  end.

Lemma desugar_core_expr_eval_equiv :
  forall (s : st_state) (e : st_expr),
    ds_core_expr e = true ->
    eval_expr s e = corest_eval_expr s.(st_vars) (desugar_expr e).
Proof.
  intros s e.
  induction e as [lit | x | arr idx | uop e1 IHe1
    | bop e1 IHe1 e2 IHe2 | cop e1 IHe1 e2 IHe2
    | e1 IHe1 e2 IHe2 | e1 IHe1 e2 IHe2 | e1 IHe1 e2 IHe2
    | f args | q args]; intros Hcore; simpl in Hcore; try discriminate.
  - destruct lit; simpl; reflexivity.
  - simpl; reflexivity.
  - destruct uop; simpl in Hcore; try discriminate.
    + simpl. rewrite (IHe1 Hcore). reflexivity.
    + simpl. rewrite (IHe1 Hcore). reflexivity.
  - destruct bop; simpl in Hcore; try discriminate.
    all: apply andb_true_iff in Hcore.
    all: destruct Hcore as [H1 H2].
    all: simpl; rewrite (IHe1 H1); rewrite (IHe2 H2).
    all: destruct (corest_eval_expr (st_vars s) (desugar_expr e1))
      as [v1|] eqn:He1;
      [destruct (corest_eval_expr (st_vars s) (desugar_expr e2))
         as [v2|] eqn:He2;
       [destruct v1; destruct v2; reflexivity |
        destruct v1; reflexivity] | reflexivity].
  - apply andb_true_iff in Hcore.
    destruct Hcore as [H1 H2].
    simpl; rewrite (IHe1 H1); rewrite (IHe2 H2).
    destruct (corest_eval_expr (st_vars s) (desugar_expr e1)) as [v1|] eqn:He1;
      [destruct (corest_eval_expr (st_vars s) (desugar_expr e2)) as [v2|] eqn:He2;
       [unfold corest_eval_compare; destruct v1; destruct v2; reflexivity |
        destruct v1; reflexivity] | reflexivity].
  - apply andb_true_iff in Hcore.
    destruct Hcore as [H1 H2].
    simpl; rewrite (IHe1 H1); rewrite (IHe2 H2).
    destruct (corest_eval_expr (st_vars s) (desugar_expr e1)) as [v1|] eqn:He1;
      [destruct (corest_eval_expr (st_vars s) (desugar_expr e2)) as [v2|] eqn:He2;
       [unfold corest_eval_logic_and; destruct v1; destruct v2; reflexivity |
        destruct v1; reflexivity] | reflexivity].
  - apply andb_true_iff in Hcore.
    destruct Hcore as [H1 H2].
    simpl; rewrite (IHe1 H1); rewrite (IHe2 H2).
    destruct (corest_eval_expr (st_vars s) (desugar_expr e1)) as [v1|] eqn:He1;
      [destruct (corest_eval_expr (st_vars s) (desugar_expr e2)) as [v2|] eqn:He2;
       [unfold corest_eval_logic_or; destruct v1; destruct v2; reflexivity |
        destruct v1; reflexivity] | reflexivity].
  - apply andb_true_iff in Hcore.
    destruct Hcore as [H1 H2].
    simpl; rewrite (IHe1 H1); rewrite (IHe2 H2).
    destruct (corest_eval_expr (st_vars s) (desugar_expr e1)) as [v1|] eqn:He1;
      [destruct (corest_eval_expr (st_vars s) (desugar_expr e2)) as [v2|] eqn:He2;
       [unfold corest_eval_logic_xor; destruct v1; destruct v2; reflexivity |
        destruct v1; reflexivity] | reflexivity].
Qed.

Lemma desugar_case_values_cond_int :
  forall (s : st_state) (sel : corest_expr) (n : Z)
         (values : list case_value),
    corest_eval_expr s.(st_vars) sel = Some (ST_V_INT n) ->
    case_values_core values ->
    corest_eval_expr s.(st_vars) (desugar_case_values_cond sel values) =
    Some (ST_V_BOOL (match_case_values n values)).
Proof.
  intros s sel n values.
  induction values as [|v rest IH]; intros Hsel Hcore_values.
  - simpl. reflexivity.
  - destruct v as [lit | lo hi].
    + destruct lit; simpl in Hcore_values; try contradiction.
      rewrite desugar_case_values_cond_single_cons.
      specialize (IH Hsel Hcore_values).
      rewrite corest_eval_expr_or.
      rewrite corest_eval_expr_comp.
      rewrite IH.
      rewrite Hsel.
      unfold corest_eval_compare, corest_eval_compare_value,
        eval_compare_int, corest_eval_logic_or. simpl.
      destruct (Z.eqb n z); simpl; reflexivity.
    + destruct lo; simpl in Hcore_values; try contradiction.
      destruct hi; simpl in Hcore_values; try contradiction.
      rewrite desugar_case_values_cond_range_cons.
      specialize (IH Hsel Hcore_values).
      rewrite corest_eval_expr_or.
      rewrite corest_eval_expr_and.
      repeat rewrite corest_eval_expr_comp.
      rewrite IH.
      rewrite Hsel.
      unfold corest_eval_compare, corest_eval_compare_value,
        eval_compare_int, corest_eval_logic_and, corest_eval_logic_or.
      simpl.
      destruct (z <=? n), (n <=? z0), (match_case_values n rest);
        simpl; reflexivity.
Qed.

Lemma desugar_case_values_cond_dint :
  forall (s : st_state) (sel : corest_expr) (n : Z)
         (values : list case_value),
    corest_eval_expr s.(st_vars) sel = Some (ST_V_DINT n) ->
    case_values_core values ->
    corest_eval_expr s.(st_vars) (desugar_case_values_cond sel values) =
    Some (ST_V_BOOL (match_case_values n values)).
Proof.
  intros s sel n values.
  induction values as [|v rest IH]; intros Hsel Hcore_values.
  - simpl. reflexivity.
  - destruct v as [lit | lo hi].
    + destruct lit; simpl in Hcore_values; try contradiction.
      rewrite desugar_case_values_cond_single_cons.
      specialize (IH Hsel Hcore_values).
      rewrite corest_eval_expr_or.
      rewrite corest_eval_expr_comp.
      rewrite IH.
      rewrite Hsel.
      unfold corest_eval_compare, corest_eval_compare_value,
        eval_compare_int, corest_eval_logic_or. simpl.
      destruct (Z.eqb n z); simpl; reflexivity.
    + destruct lo; simpl in Hcore_values; try contradiction.
      destruct hi; simpl in Hcore_values; try contradiction.
      rewrite desugar_case_values_cond_range_cons.
      specialize (IH Hsel Hcore_values).
      rewrite corest_eval_expr_or.
      rewrite corest_eval_expr_and.
      repeat rewrite corest_eval_expr_comp.
      rewrite IH.
      rewrite Hsel.
      unfold corest_eval_compare, corest_eval_compare_value,
        eval_compare_int, corest_eval_logic_and, corest_eval_logic_or.
      simpl.
      destruct (z <=? n), (n <=? z0), (match_case_values n rest);
        simpl; reflexivity.
Qed.

Lemma desugar_case_chain_select_int :
  forall (s : st_state) (sel : corest_expr) (n : Z)
         (branches : list case_element)
         (default : option (list st_stmt)),
    corest_eval_expr s.(st_vars) sel = Some (ST_V_INT n) ->
    case_branches_core branches ->
    star_corest_step
      [desugar_case_chain sel branches default] s
      (desugar_stmts (select_case_stmts n branches default)) s.
Proof.
  intros s sel n branches.
  induction branches as [|[vals body] rest IH];
    intros default Hsel Hcore_branches.
  - simpl.
    unfold desugar_case_chain, desugar_case_chain_with.
    simpl.
    destruct default as [body|].
    + eapply CsStar_step.
      * eapply Cs_if_true; reflexivity.
      * rewrite app_nil_r. apply CsStar_refl.
    + eapply CsStar_step.
      * eapply Cs_if_true; reflexivity.
      * apply CsStar_refl.
  - simpl in Hcore_branches.
    destruct Hcore_branches as [Hcore_values Hcore_rest].
    pose proof (desugar_case_values_cond_int s sel n vals Hsel Hcore_values)
      as Hcond.
    destruct (match_case_values n vals) eqn:Hmatch.
    + simpl.
      unfold desugar_case_chain, desugar_case_chain_with.
      simpl.
      unfold select_case_stmts, find_case_branch.
      rewrite Hmatch.
      simpl.
      eapply CsStar_step.
      * eapply Cs_if_true; exact Hcond.
      * rewrite app_nil_r. apply CsStar_refl.
    + simpl.
      destruct rest as [|head rest'].
      * unfold desugar_case_chain, desugar_case_chain_with.
        simpl.
        unfold select_case_stmts, find_case_branch.
        rewrite Hmatch. simpl.
        destruct default as [db|].
        -- eapply CsStar_step.
           ++ eapply Cs_if_false; exact Hcond.
           ++ rewrite app_nil_r. apply CsStar_refl.
        -- eapply CsStar_step.
           ++ eapply Cs_if_false; exact Hcond.
           ++ apply CsStar_refl.
      * destruct head as [head_vals head_body].
        simpl in Hcore_rest.
        unfold select_case_stmts, find_case_branch.
        rewrite Hmatch. simpl.
        unfold desugar_case_chain, desugar_case_chain_with.
        simpl.
        eapply CsStar_step.
        -- eapply Cs_if_false; exact Hcond.
        -- apply IH.
           ++ exact Hsel.
           ++ exact Hcore_rest.
Qed.

Lemma desugar_case_chain_select_dint :
  forall (s : st_state) (sel : corest_expr) (n : Z)
         (branches : list case_element)
         (default : option (list st_stmt)),
    corest_eval_expr s.(st_vars) sel = Some (ST_V_DINT n) ->
    case_branches_core branches ->
    star_corest_step
      [desugar_case_chain sel branches default] s
      (desugar_stmts (select_case_stmts n branches default)) s.
Proof.
  intros s sel n branches.
  induction branches as [|[vals body] rest IH];
    intros default Hsel Hcore_branches.
  - simpl.
    unfold desugar_case_chain, desugar_case_chain_with.
    simpl.
    destruct default as [body|].
    + eapply CsStar_step.
      * eapply Cs_if_true; reflexivity.
      * rewrite app_nil_r. apply CsStar_refl.
    + eapply CsStar_step.
      * eapply Cs_if_true; reflexivity.
      * apply CsStar_refl.
  - simpl in Hcore_branches.
    destruct Hcore_branches as [Hcore_values Hcore_rest].
    pose proof (desugar_case_values_cond_dint s sel n vals Hsel Hcore_values)
      as Hcond.
    destruct (match_case_values n vals) eqn:Hmatch.
    + simpl.
      unfold desugar_case_chain, desugar_case_chain_with.
      simpl.
      unfold select_case_stmts, find_case_branch.
      rewrite Hmatch. simpl.
      eapply CsStar_step.
      * eapply Cs_if_true; exact Hcond.
      * rewrite app_nil_r. apply CsStar_refl.
    + simpl.
      destruct rest as [|head rest'].
      * unfold desugar_case_chain, desugar_case_chain_with.
        simpl.
        unfold select_case_stmts, find_case_branch.
        rewrite Hmatch. simpl.
        destruct default as [db|].
        -- eapply CsStar_step.
           ++ eapply Cs_if_false; exact Hcond.
           ++ rewrite app_nil_r. apply CsStar_refl.
        -- eapply CsStar_step.
           ++ eapply Cs_if_false; exact Hcond.
           ++ apply CsStar_refl.
      * destruct head as [head_vals head_body].
        simpl in Hcore_rest.
        unfold select_case_stmts, find_case_branch.
        rewrite Hmatch. simpl.
        unfold desugar_case_chain, desugar_case_chain_with.
        simpl.
        eapply CsStar_step.
        -- eapply Cs_if_false; exact Hcond.
        -- apply IH.
           ++ exact Hsel.
           ++ exact Hcore_rest.
Qed.

Lemma desugar_assign_step :
  forall (p : st_program) (x : ident) (e : st_expr)
         (rest : list st_stmt) (s : st_state) (v : st_value)
         (ty : st_type),
    lookup (build_program_env p) x = Some ty ->
    eval_expr s e = Some v ->
    ds_core_expr e = true ->
    corest_assign_value s x v = coerce_value_to_type ty v ->
    star_corest_step
      (desugar_stmts (S_ASSIGN x e :: rest)) s
      (desugar_stmts rest) (update_var s x (coerce_value_to_type ty v)).
Proof.
  intros p x e rest s v ty _ Heval Hcore Hassign.
  pose proof (desugar_core_expr_eval_equiv s e Hcore) as Heq.
  assert (Hcore_val :
    corest_eval_expr s.(st_vars) (desugar_expr e) = Some v).
  { rewrite <- Heq. exact Heval. }
  rewrite <- Hassign.
  rewrite desugar_stmts_cons.
  rewrite desugar_stmt_assign.
  eapply CsStar_step.
  - eapply Cs_assign; exact Hcore_val.
  - apply CsStar_refl.
Qed.

Lemma desugar_if_true_step :
  forall (p : st_program) (cond : st_expr)
         (then_body : list st_stmt) (else_body : option (list st_stmt))
         (rest : list st_stmt) (s : st_state),
    eval_expr s cond = Some (ST_V_BOOL true) ->
    ds_core_expr cond = true ->
    star_corest_step
      (desugar_stmts (S_IF cond then_body else_body :: rest)) s
      (desugar_stmts (then_body ++ rest)) s.
Proof.
  intros p cond then_body else_body rest s Heval Hcore.
  pose proof (desugar_core_expr_eval_equiv s cond Hcore) as Heq.
  assert (Hcore_val :
    corest_eval_expr s.(st_vars) (desugar_expr cond) =
      Some (ST_V_BOOL true)).
  { rewrite <- Heq. exact Heval. }
  rewrite desugar_stmts_cons.
  rewrite desugar_stmt_if.
  rewrite desugar_stmts_append.
  eapply CsStar_step.
  - eapply Cs_if_true; exact Hcore_val.
  - apply CsStar_refl.
Qed.

Lemma desugar_if_false_step :
  forall (p : st_program) (cond : st_expr)
         (then_body : list st_stmt) (else_body : option (list st_stmt))
         (rest : list st_stmt) (s : st_state),
    eval_expr s cond = Some (ST_V_BOOL false) ->
    ds_core_expr cond = true ->
    star_corest_step
      (desugar_stmts (S_IF cond then_body else_body :: rest)) s
      (desugar_stmts
        (match else_body with
         | Some body => body ++ rest
         | None => rest
         end)) s.
Proof.
  intros p cond then_body else_body rest s Heval Hcore.
  pose proof (desugar_core_expr_eval_equiv s cond Hcore) as Heq.
  assert (Hcore_val :
    corest_eval_expr s.(st_vars) (desugar_expr cond) =
      Some (ST_V_BOOL false)).
  { rewrite <- Heq. exact Heval. }
  rewrite desugar_stmts_cons.
  rewrite desugar_stmt_if.
  destruct else_body as [body|].
  - rewrite desugar_stmts_append.
    eapply CsStar_step.
    + eapply Cs_if_false; exact Hcore_val.
    + apply CsStar_refl.
  - simpl in *.
    eapply CsStar_step.
    + eapply Cs_if_false; exact Hcore_val.
    + apply CsStar_refl.
Qed.

Lemma desugar_while_true_step :
  forall (p : st_program) (cond : st_expr) (body : list st_stmt)
         (rest : list st_stmt) (s : st_state),
    eval_expr s cond = Some (ST_V_BOOL true) ->
    ds_core_expr cond = true ->
    star_corest_step
      (desugar_stmts (S_WHILE cond body :: rest)) s
      (desugar_stmts (body ++ S_WHILE cond body :: rest)) s.
Proof.
  intros p cond body rest s Heval Hcore.
  pose proof (desugar_core_expr_eval_equiv s cond Hcore) as Heq.
  assert (Hcore_val :
    corest_eval_expr s.(st_vars) (desugar_expr cond) =
      Some (ST_V_BOOL true)).
  { rewrite <- Heq. exact Heval. }
  rewrite desugar_stmts_cons.
  rewrite desugar_stmt_while.
  rewrite desugar_stmts_append.
  rewrite desugar_stmts_cons.
  rewrite desugar_stmt_while.
  eapply CsStar_step.
  - eapply Cs_while_true; exact Hcore_val.
  - apply CsStar_refl.
Qed.

Lemma desugar_while_false_step :
  forall (p : st_program) (cond : st_expr) (body : list st_stmt)
         (rest : list st_stmt) (s : st_state),
    eval_expr s cond = Some (ST_V_BOOL false) ->
    ds_core_expr cond = true ->
    star_corest_step
      (desugar_stmts (S_WHILE cond body :: rest)) s
      (desugar_stmts rest) s.
Proof.
  intros p cond body rest s Heval Hcore.
  pose proof (desugar_core_expr_eval_equiv s cond Hcore) as Heq.
  assert (Hcore_val :
    corest_eval_expr s.(st_vars) (desugar_expr cond) =
      Some (ST_V_BOOL false)).
  { rewrite <- Heq. exact Heval. }
  rewrite desugar_stmts_cons.
  rewrite desugar_stmt_while.
  eapply CsStar_step.
  - eapply Cs_while_false; exact Hcore_val.
  - apply CsStar_refl.
Qed.

Lemma desugar_for_step :
  forall (p : st_program) (v : ident) (start end_ : st_expr)
         (step : option st_expr) (body rest : list st_stmt)
         (s : st_state),
    star_corest_step
      (desugar_stmts (S_FOR v start end_ step body :: rest)) s
      (desugar_stmts (for_to_while v start end_ step body ++ rest)) s.
Proof.
  intros p v start end_ step body rest s.
  assert (Heq :
    desugar_stmts (S_FOR v start end_ step body :: rest) =
    desugar_stmts (for_to_while v start end_ step body ++ rest)).
  { rewrite desugar_stmts_cons.
    rewrite desugar_stmt_for.
    unfold for_to_while.
    rewrite desugar_stmts_append.
    rewrite desugar_stmts_cons.
    rewrite desugar_stmts_cons.
    rewrite desugar_stmt_assign.
    rewrite desugar_stmt_while.
    rewrite desugar_stmts_append.
    repeat rewrite app_assoc.
    reflexivity. }
  rewrite Heq.
  apply CsStar_refl.
Qed.

Lemma desugar_for_config_eq :
  forall (v : ident) (start end_ : st_expr) (step : option st_expr)
         (body rest : list st_stmt),
    desugar_stmts (S_FOR v start end_ step body :: rest) =
    desugar_stmts (for_to_while v start end_ step body ++ rest).
Proof.
  intros v start end_ step body rest.
  rewrite desugar_stmts_cons.
  rewrite desugar_stmt_for.
  unfold for_to_while.
  rewrite desugar_stmts_append.
  rewrite desugar_stmts_cons.
  rewrite desugar_stmts_cons.
  rewrite desugar_stmt_assign.
  rewrite desugar_stmt_while.
  rewrite desugar_stmts_append.
  repeat rewrite app_assoc.
  reflexivity.
Qed.

Lemma desugar_case_step_int :
  forall (p : st_program) (sel : st_expr)
         (branches : list case_element)
         (default : option (list st_stmt))
         (rest : list st_stmt) (s : st_state) (n : Z),
    eval_expr s sel = Some (ST_V_INT n) ->
    ds_core_expr sel = true ->
    case_branches_core branches ->
    star_corest_step
      (desugar_stmts (S_CASE sel branches default :: rest)) s
      (desugar_stmts (select_case_stmts n branches default ++ rest)) s.
Proof.
  intros p sel branches default rest s n Heval Hcore Hbranches.
  pose proof (desugar_core_expr_eval_equiv s sel Hcore) as Heq.
  assert (Hcore_val :
    corest_eval_expr s.(st_vars) (desugar_expr sel) = Some (ST_V_INT n)).
  { rewrite <- Heq. exact Heval. }
  rewrite desugar_stmts_cons.
  rewrite desugar_stmt_case.
  rewrite desugar_stmts_append.
  pose proof
    (desugar_case_chain_select_int s (desugar_expr sel) n
      branches default Hcore_val Hbranches) as Hselect.
  pose proof
    (ds_star_corest_step_tail
      [desugar_case_chain (desugar_expr sel) branches default]
      (desugar_stmts (select_case_stmts n branches default))
      s s (desugar_stmts rest) Hselect) as Htail.
  change (star_corest_step
    ([desugar_case_chain (desugar_expr sel) branches default] ++
     desugar_stmts rest) s
    (desugar_stmts (select_case_stmts n branches default) ++
     desugar_stmts rest) s) in Htail.
  exact Htail.
Qed.

Lemma desugar_case_step_dint :
  forall (p : st_program) (sel : st_expr)
         (branches : list case_element)
         (default : option (list st_stmt))
         (rest : list st_stmt) (s : st_state) (n : Z),
    eval_expr s sel = Some (ST_V_DINT n) ->
    ds_core_expr sel = true ->
    case_branches_core branches ->
    star_corest_step
      (desugar_stmts (S_CASE sel branches default :: rest)) s
      (desugar_stmts (select_case_stmts n branches default ++ rest)) s.
Proof.
  intros p sel branches default rest s n Heval Hcore Hbranches.
  pose proof (desugar_core_expr_eval_equiv s sel Hcore) as Heq.
  assert (Hcore_val :
    corest_eval_expr s.(st_vars) (desugar_expr sel) = Some (ST_V_DINT n)).
  { rewrite <- Heq. exact Heval. }
  rewrite desugar_stmts_cons.
  rewrite desugar_stmt_case.
  rewrite desugar_stmts_append.
  pose proof
    (desugar_case_chain_select_dint s (desugar_expr sel) n
      branches default Hcore_val Hbranches) as Hselect.
  pose proof
    (ds_star_corest_step_tail
      [desugar_case_chain (desugar_expr sel) branches default]
      (desugar_stmts (select_case_stmts n branches default))
      s s (desugar_stmts rest) Hselect) as Htail.
  change (star_corest_step
    ([desugar_case_chain (desugar_expr sel) branches default] ++
     desugar_stmts rest) s
    (desugar_stmts (select_case_stmts n branches default) ++
     desugar_stmts rest) s) in Htail.
  exact Htail.
Qed.

Lemma desugar_repeat_step :
  forall (p : st_program) (body : list st_stmt) (cond : st_expr)
         (rest : list st_stmt) (s : st_state),
    star_corest_step
      (desugar_stmts (S_REPEAT body cond :: rest)) s
      (desugar_stmts
        (body ++ S_WHILE (E_UNARY_OP U_NOT cond) body :: rest)) s.
Proof.
  intros p body cond rest s.
  rewrite desugar_stmts_cons.
  rewrite desugar_stmt_repeat.
  rewrite desugar_stmts_append.
  rewrite desugar_stmts_cons.
  rewrite desugar_stmt_while.
  repeat rewrite app_assoc.
  simpl.
  eapply CsStar_step.
  - eapply Cs_block.
  - apply CsStar_refl.
Qed.

Definition desugar_step_ready
           (p : st_program) (stmts : list st_stmt) (s : st_state) : Prop :=
  match stmts with
  | S_ASSIGN x e :: _ =>
      exists (ty : st_type) (v : st_value),
        lookup (build_program_env p) x = Some ty /\
        eval_expr s e = Some v /\
        ds_core_expr e = true /\
        corest_assign_value s x v = coerce_value_to_type ty v
  | S_IF cond _ _ :: _ =>
      ds_core_expr cond = true /\
      exists b : bool, eval_expr s cond = Some (ST_V_BOOL b)
  | S_WHILE cond _ :: _ =>
      ds_core_expr cond = true /\
      exists b : bool, eval_expr s cond = Some (ST_V_BOOL b)
  | S_REPEAT _ cond :: _ =>
      ds_core_expr cond = true
  | S_FOR _ _ _ _ _ :: _ => True
  | S_CASE sel branches _ :: _ =>
      ds_core_expr sel = true /\
      case_branches_core branches /\
      ((exists n : Z, eval_expr s sel = Some (ST_V_INT n)) \/
       (exists n : Z, eval_expr s sel = Some (ST_V_DINT n)))
  | _ => False
  end.

Theorem desugar_semantics_preservation_ready :
  forall (p : st_program) (stmts stmts' : list st_stmt)
         (s s' : st_state),
    desugar_step_ready p stmts s ->
    stmts_step p stmts s stmts' s' ->
    star_corest_step
      (desugar_stmts stmts) s (desugar_stmts stmts') s'.
Proof.
  intros p stmts stmts' s s' Hready Hstep.
  destruct stmts as [|stmt rest]; [inversion Hstep |].
  destruct stmt as
    [x e | x idx e | cond then_body else_body | sel branches default
    | v start end_ step body | cond body | body cond | inst params | |].
  - (* assignment *)
    inversion Hstep; subst.
    simpl in Hready.
    destruct Hready as
      [ready_ty [ready_v [Hlook [Heval [Hcore Hassign]]]]].
    assert (Hty_eq : ty = ready_ty) by congruence.
    assert (Hv_eq : v = ready_v) by congruence.
    subst ty. subst v.
    exact (desugar_assign_step p x e stmts' s ready_v ready_ty
             Hlook Heval Hcore Hassign).
  - (* array assignment is outside the core subset *)
    inversion Hstep.
  - (* IF *)
    inversion Hstep; subst.
    + simpl in Hready. destruct Hready as [Hcore _].
      eapply desugar_if_true_step; eauto.
    + simpl in Hready. destruct Hready as [Hcore _].
      eapply desugar_if_false_step; eauto.
  - (* CASE *)
    inversion Hstep; subst.
    + simpl in Hready. destruct Hready as [Hcore [Hbranches Hor]].
      eapply desugar_case_step_int; eauto.
    + simpl in Hready. destruct Hready as [Hcore [Hbranches Hor]].
      eapply desugar_case_step_dint; eauto.
  - (* FOR *)
    inversion Hstep; subst.
    eapply desugar_for_step; eauto.
  - (* WHILE *)
    inversion Hstep; subst.
    + simpl in Hready. destruct Hready as [Hcore _].
      eapply desugar_while_true_step; eauto.
    + simpl in Hready. destruct Hready as [Hcore _].
      eapply desugar_while_false_step; eauto.
  - (* REPEAT *)
    inversion Hstep; subst.
    eapply desugar_repeat_step; eauto.
  - (* FB call is outside the core subset *)
    inversion Hstep.
  - inversion Hstep.
  - inversion Hstep.
Qed.

Theorem desugar_semantics_preservation :
  forall (p : st_program) (stmts stmts' : list st_stmt)
         (s s' : st_state),
    desugar_step_ready p stmts s ->
    stmts_step p stmts s stmts' s' ->
    star_corest_step
      (desugar_stmts stmts) s (desugar_stmts stmts') s'.
Proof.
  intros p stmts stmts' s s' Hready Hstep.
  exact (desugar_semantics_preservation_ready
           p stmts stmts' s s' Hready Hstep).
Qed.
