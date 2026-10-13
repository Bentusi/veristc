(* ================================================================
   veristc/spec/function_semantics.v
   Source-level semantics for stateless FUNCTION frames.

   This module defines the intended meaning of a SafeST FUNCTION call:
   a fresh environment is created from VAR_INPUT arguments and local
   declarations, the body is executed, and the implicit function-result
   variable is returned. It is intentionally separate from the legacy
   flat-state semantics so existing proofs remain stable while the
   CALL/RETURN preservation theorem is developed.
   ================================================================ *)

From Stdlib Require Import List.
From Stdlib Require Import Bool.
From Stdlib Require Import ZArith.
From Stdlib Require Import String.
From Stdlib Require Import Lia.
Require Import veristc_spec.safest.
Require Import veristc_spec.st_semantics.
Local Open Scope Z_scope.
Import ListNotations.

Definition st_env : Type := list (ident * st_value).

Fixpoint lookup_env (env : st_env) (x : ident) : option st_value :=
  match env with
  | nil => None
  | (y, v) :: rest => if ident_eq x y then Some v else lookup_env rest x
  end.

Fixpoint update_env (env : st_env) (x : ident) (v : st_value) : st_env :=
  match env with
  | nil => [(x, v)]
  | (y, old) :: rest =>
      if ident_eq x y then (x, v) :: rest
      else (y, old) :: update_env rest x v
  end.

Definition default_st_value (ty : st_type) : st_value :=
  match ty with
  | T_BOOL => ST_V_BOOL false
  | _ => ST_V_INT 0
  end.

Fixpoint init_env_from_decls (decls : list st_var_decl) : st_env :=
  match decls with
  | nil => nil
  | d :: rest =>
      (d.(var_name), default_st_value d.(var_type)) ::
      init_env_from_decls rest
  end.

Fixpoint input_param_names (decls : list st_var_decl) : list ident :=
  match decls with
  | nil => nil
  | d :: rest =>
      match d.(var_dir) with
      | D_INPUT => d.(var_name) :: input_param_names rest
      | _ => input_param_names rest
      end
  end.

Fixpoint non_input_decls (decls : list st_var_decl) : list st_var_decl :=
  match decls with
  | nil => nil
  | d :: rest =>
      match d.(var_dir) with
      | D_INPUT => non_input_decls rest
      | _ => d :: non_input_decls rest
      end
  end.

Fixpoint bind_args (params : list ident) (args : list st_value)
         : option st_env :=
  match params, args with
  | nil, nil => Some nil
  | p :: ps, a :: rest_args =>
      match bind_args ps rest_args with
      | Some env => Some ((p, a) :: env)
      | None => None
      end
  | _, _ => None
  end.

Fixpoint lookup_function_pou
         (name : ident) (pous : list st_pou)
         : option (st_type * list st_var_decl * list st_stmt) :=
  match pous with
  | nil => None
  | P_FUNCTION fn_name ty decls body :: rest =>
      if ident_eq name fn_name then Some (ty, decls, body)
      else lookup_function_pou name rest
  | _ :: rest => lookup_function_pou name rest
  end.

(* Extract an integer index value from a selector/current value (FOR control
   variables and CASE selectors are integer-typed in the FUNCTION subset). *)
Definition case_sel_to_z (v : st_value) : option Z :=
  match v with
  | ST_V_INT n => Some n
  | ST_V_DINT n => Some n
  | _ => None
  end.

Definition int_add_val (a b : st_value) : option st_value :=
  match a, b with
  | ST_V_INT x, ST_V_INT y => Some (ST_V_INT (x + y))
  | ST_V_DINT x, ST_V_DINT y => Some (ST_V_DINT (x + y))
  | ST_V_INT x, ST_V_DINT y => Some (ST_V_DINT (x + y))
  | ST_V_DINT x, ST_V_INT y => Some (ST_V_DINT (x + y))
  | _, _ => None
  end.

(* Select the first CASE branch whose value list matches the selector. *)
Fixpoint pick_case_branch (z : Z) (bs : list case_element)
         : option (list st_stmt) :=
  match bs with
  | nil => None
  | CASE_ELEM vals body :: rest =>
      if match_case_values z vals then Some body
      else pick_case_branch z rest
  end.

Inductive fn_result : Type :=
  | FN_CONTINUE : st_env -> fn_result
  | FN_RETURN : st_env -> fn_result
.

Definition fn_result_env (r : fn_result) : st_env :=
  match r with
  | FN_CONTINUE env => env
  | FN_RETURN env => env
  end.

Fixpoint eval_expr_fn
         (fuel : nat) (funs : list st_pou) (env : st_env)
         (e : st_expr) {struct fuel} : option st_value :=
  match fuel with
  | O => None
  | S fuel' =>
      match e with
      | E_LIT l =>
          match l with
          | L_BOOL b => Some (ST_V_BOOL b)
          | L_INT n => Some (ST_V_INT n)
          | L_REAL f => Some (ST_V_REAL f)
          | L_TIME t => Some (ST_V_TIME t)
          | L_LINT n => Some (ST_V_LINT n)
          | L_LREAL f => Some (ST_V_LREAL f)
          end
      | E_VAR x => lookup_env env x
      | E_UNARY_OP U_NEG e1 =>
          match eval_expr_fn fuel' funs env e1 with
          | Some (ST_V_INT n) => Some (ST_V_INT (- n))
          | Some (ST_V_DINT n) => Some (ST_V_DINT (- n))
          | _ => None
          end
      | E_UNARY_OP U_NOT e1 =>
          match eval_expr_fn fuel' funs env e1 with
          | Some (ST_V_BOOL b) => Some (ST_V_BOOL (negb b))
          | _ => None
          end
      | E_UNARY_OP U_ABS e1 =>
          match eval_expr_fn fuel' funs env e1 with
          | Some (ST_V_INT n) => Some (ST_V_INT (Z.abs n))
          | Some (ST_V_DINT n) => Some (ST_V_DINT (Z.abs n))
          | _ => None
          end
      | E_BIN_OP op e1 e2 =>
          match eval_expr_fn fuel' funs env e1,
                eval_expr_fn fuel' funs env e2 with
          | Some (ST_V_INT n1), Some (ST_V_INT n2) =>
              Some (ST_V_INT (eval_binop_int op n1 n2))
          | Some (ST_V_DINT n1), Some (ST_V_DINT n2) =>
              Some (ST_V_DINT (eval_binop_int op n1 n2))
          | Some (ST_V_INT n1), Some (ST_V_DINT n2) =>
              Some (ST_V_DINT (eval_binop_int op n1 n2))
          | Some (ST_V_DINT n1), Some (ST_V_INT n2) =>
              Some (ST_V_DINT (eval_binop_int op n1 n2))
          | Some (ST_V_REAL f1), Some (ST_V_REAL f2) =>
              Some (ST_V_REAL (eval_binop_float op f1 f2))
          | _, _ => None
          end
      | E_COMP op e1 e2 =>
          match eval_expr_fn fuel' funs env e1,
                eval_expr_fn fuel' funs env e2 with
          | Some (ST_V_BOOL b1), Some (ST_V_BOOL b2) =>
              Some (ST_V_BOOL (eval_compare_bool op b1 b2))
          | Some (ST_V_INT n1), Some (ST_V_INT n2) =>
              Some (ST_V_BOOL (eval_compare_int op n1 n2))
          | Some (ST_V_DINT n1), Some (ST_V_DINT n2) =>
              Some (ST_V_BOOL (eval_compare_int op n1 n2))
          | Some (ST_V_INT n1), Some (ST_V_DINT n2) =>
              Some (ST_V_BOOL (eval_compare_int op n1 n2))
          | Some (ST_V_DINT n1), Some (ST_V_INT n2) =>
              Some (ST_V_BOOL (eval_compare_int op n1 n2))
          | _, _ => None
          end
      | E_AND e1 e2 =>
          match eval_expr_fn fuel' funs env e1,
                eval_expr_fn fuel' funs env e2 with
          | Some (ST_V_BOOL b1), Some (ST_V_BOOL b2) =>
              Some (ST_V_BOOL (b1 && b2))
          | _, _ => None
          end
      | E_OR e1 e2 =>
          match eval_expr_fn fuel' funs env e1,
                eval_expr_fn fuel' funs env e2 with
          | Some (ST_V_BOOL b1), Some (ST_V_BOOL b2) =>
              Some (ST_V_BOOL (b1 || b2))
          | _, _ => None
          end
      | E_XOR e1 e2 =>
          match eval_expr_fn fuel' funs env e1,
                eval_expr_fn fuel' funs env e2 with
          | Some (ST_V_BOOL b1), Some (ST_V_BOOL b2) =>
              Some (ST_V_BOOL (xorb b1 b2))
          | _, _ => None
          end
      | E_FUNC_CALL name args =>
          match eval_exprs_fn fuel' funs env args with
          | Some vals => call_function_fn fuel' funs name vals
          | None => None
          end
      | _ => None
      end
  end

with eval_exprs_fn
       (fuel : nat) (funs : list st_pou) (env : st_env)
       (es : list st_expr) {struct fuel} : option (list st_value) :=
  match fuel with
  | O => None
  | S fuel' =>
      match es with
      | nil => Some nil
      | e :: rest =>
          match eval_expr_fn fuel' funs env e,
                eval_exprs_fn fuel' funs env rest with
          | Some v, Some vs => Some (v :: vs)
          | _, _ => None
          end
      end
  end

with call_function_fn
       (fuel : nat) (funs : list st_pou) (name : ident)
       (args : list st_value) {struct fuel} : option st_value :=
  match fuel with
  | O => None
  | S fuel' =>
      match lookup_function_pou name funs with
      | Some (_, decls, body) =>
          let params := input_param_names decls in
          if Nat.eqb (List.length params) (List.length args) then
            match bind_args params args with
            | Some arg_env =>
                let local_env :=
                  arg_env ++
                  init_env_from_decls (non_input_decls decls) in
                match exec_stmts_fn fuel' funs local_env body with
                | Some r => lookup_env (fn_result_env r) name
                | None => None
                end
            | None => None
            end
          else
            None
      | None => None
      end
  end

with exec_stmt_fn
       (fuel : nat) (funs : list st_pou) (env : st_env)
       (s : st_stmt) {struct fuel} : option fn_result :=
  match fuel with
  | O => None
  | S fuel' =>
      match s with
      | S_ASSIGN x e =>
          match eval_expr_fn fuel' funs env e with
          | Some v => Some (FN_CONTINUE (update_env env x v))
          | None => None
          end
      | S_IF cond then_body else_body =>
          match eval_expr_fn fuel' funs env cond with
          | Some (ST_V_BOOL true) =>
              exec_stmts_fn fuel' funs env then_body
          | Some (ST_V_BOOL false) =>
              match else_body with
              | Some body => exec_stmts_fn fuel' funs env body
              | None => Some (FN_CONTINUE env)
              end
          | _ => None
          end
      | S_CASE sel branches default =>
          match eval_expr_fn fuel' funs env sel with
          | Some sv =>
              match case_sel_to_z sv with
              | Some z =>
                  match pick_case_branch z branches with
                  | Some body => exec_stmts_fn fuel' funs env body
                  | None =>
                      match default with
                      | Some body => exec_stmts_fn fuel' funs env body
                      | None => Some (FN_CONTINUE env)
                      end
                  end
              | None => None
              end
          | None => None
          end
      | S_WHILE cond body =>
          match eval_expr_fn fuel' funs env cond with
          | Some (ST_V_BOOL true) =>
              match exec_stmts_fn fuel' funs env body with
              | Some (FN_RETURN env'') => Some (FN_RETURN env'')
              | Some (FN_CONTINUE env'') =>
                  exec_stmt_fn fuel' funs env'' (S_WHILE cond body)
              | None => None
              end
          | Some (ST_V_BOOL false) => Some (FN_CONTINUE env)
          | _ => None
          end
      | S_REPEAT body cond =>
          match exec_stmts_fn fuel' funs env body with
          | Some (FN_RETURN env'') => Some (FN_RETURN env'')
          | Some (FN_CONTINUE env'') =>
              match eval_expr_fn fuel' funs env'' cond with
              | Some (ST_V_BOOL false) =>
                  exec_stmt_fn fuel' funs env'' (S_REPEAT body cond)
              | Some (ST_V_BOOL true) => Some (FN_CONTINUE env'')
              | _ => None
              end
          | None => None
          end
      | S_FOR v start finish mstep body =>
          match eval_expr_fn fuel' funs env start with
          | Some sv =>
              match eval_expr_fn fuel' funs env finish with
              | Some fv =>
                  match mstep with
                  | None =>
                      exec_for fuel' funs v fv (ST_V_INT 1) body
                        (update_env env v sv)
                  | Some se =>
                      match eval_expr_fn fuel' funs env se with
                      | Some stepv =>
                          exec_for fuel' funs v fv stepv body
                            (update_env env v sv)
                      | None => None
                      end
                  end
              | None => None
              end
          | None => None
          end
      | S_RETURN => Some (FN_RETURN env)
      | _ => None
      end
  end

with exec_stmts_fn
       (fuel : nat) (funs : list st_pou) (env : st_env)
       (stmts : list st_stmt) {struct fuel} : option fn_result :=
  match fuel with
  | O => None
  | S fuel' =>
      match stmts with
      | nil => Some (FN_CONTINUE env)
      | s :: rest =>
          match exec_stmt_fn fuel' funs env s with
          | Some (FN_RETURN env') => Some (FN_RETURN env')
          | Some (FN_CONTINUE env') =>
              exec_stmts_fn fuel' funs env' rest
          | None => None
          end
      end
  end

(* Ascending FOR loop over an integer control variable: the loop continues
   while the current value is <= the (constant) finish bound; after each body
   the control variable is advanced by the step. The env already holds the
   initialized control variable. *)
with exec_for
       (fuel : nat) (funs : list st_pou)
       (v : ident) (finish stepv : st_value) (body : list st_stmt)
       (env : st_env) {struct fuel} : option fn_result :=
  match fuel with
  | O => None
  | S fuel' =>
      match lookup_env env v with
      | Some cur =>
          match case_sel_to_z cur, case_sel_to_z finish with
          | Some c, Some f =>
              if (c <=? f) then
                match exec_stmts_fn fuel' funs env body with
                | Some (FN_RETURN env'') => Some (FN_RETURN env'')
                | Some (FN_CONTINUE env'') =>
                    match lookup_env env'' v with
                    | Some cur' =>
                        match int_add_val cur' stepv with
                        | Some next =>
                            exec_for fuel' funs v finish stepv body
                              (update_env env'' v next)
                        | None => None
                        end
                    | None => None
                    end
                | None => None
                end
              else
                Some (FN_CONTINUE env)
          | _, _ => None
          end
      | None => None
      end
  end.

Lemma bind_args_length :
  forall (params : list ident) (args : list st_value) (env : st_env),
    bind_args params args = Some env ->
    List.length params = List.length args.
Proof.
  induction params as [|p ps IH]; intros args env H.
  - destruct args as [|a rest]; simpl in H; try discriminate.
    inversion H; subst. reflexivity.
  - destruct args as [|a rest]; simpl in H; try discriminate.
    destruct (bind_args ps rest) eqn:Hbind; try discriminate.
    inversion H; subst.
    specialize (IH rest s Hbind).
    simpl. lia.
Qed.

Lemma lookup_env_update_same :
  forall (env : st_env) (x : ident) (v : st_value),
    lookup_env (update_env env x v) x = Some v.
Proof.
  induction env as [|hd rest IH]; intros x v.
  - destruct x as [s]. simpl.
    rewrite String.eqb_refl. reflexivity.
  - destruct x as [s]. destruct hd as [[sy] old]. simpl.
    destruct (String.eqb s sy) eqn:Hxy.
    + simpl. rewrite String.eqb_refl. reflexivity.
    + simpl. rewrite Hxy. simpl. apply IH.
Qed.

(* ================================================================
   WS-A.4: frame invariants for FUNCTION calls.

   These lemmas capture the properties that WS-B/WS-C rely on when
   relating a source-level call to the SafeASM Pc_call / Pc_return
   step: identifier equality is a proper boolean equality, reading a
   variable is single-valued and unaffected by writes to *other*
   variables (so the function-result variable stays uniquely
   determined), argument binding enforces the parameter/argument
   arity, and executing an empty body preserves the frame.
   ================================================================ *)

Lemma ident_eq_sym :
  forall x y : ident, ident_eq x y = ident_eq y x.
Proof.
  destruct x as [s1]; destruct y as [s2]. simpl.
  rewrite String.eqb_sym. reflexivity.
Qed.

Lemma ident_eq_refl :
  forall x : ident, ident_eq x x = true.
Proof.
  destruct x as [s]. simpl. rewrite String.eqb_refl. reflexivity.
Qed.

Lemma ident_eq_true_iff :
  forall x y : ident, ident_eq x y = true <-> x = y.
Proof.
  destruct x as [s1]; destruct y as [s2]. simpl. split.
  - intro H. apply f_equal. apply (proj1 (String.eqb_eq _ _)). exact H.
  - intro H. injection H as Hs. apply (proj2 (String.eqb_eq _ _)). exact Hs.
Qed.

(* Writing to one variable never changes the value read for a
   different variable. *)
Lemma lookup_env_update_other :
  forall (env : st_env) (x y : ident) (v : st_value),
    ident_eq x y = false ->
    lookup_env (update_env env x v) y = lookup_env env y.
Proof.
  induction env as [|hd rest IH]; intros x y v Hne.
  - simpl. rewrite (ident_eq_sym y x), Hne. reflexivity.
  - destruct hd as [sy old]. simpl.
    destruct (ident_eq x sy) eqn:Hx.
    + simpl. apply ident_eq_true_iff in Hx.
      rewrite <- Hx.
      destruct (ident_eq y x) eqn:Hy.
      * exfalso.
        apply ident_eq_true_iff in Hy.
        rewrite Hy in Hne.
        rewrite ident_eq_refl in Hne. discriminate.
      * reflexivity.
    + simpl.
      destruct (ident_eq y sy) eqn:Hy.
      * reflexivity.
      * rewrite (IH x y v Hne). reflexivity.
Qed.

(* The result-variable read is single-valued: a frame determines at
   most one value for any name. *)
Lemma lookup_env_unique :
  forall (env : st_env) (x : ident) (v1 v2 : st_value),
    lookup_env env x = Some v1 ->
    lookup_env env x = Some v2 ->
    v1 = v2.
Proof.
  intros env x v1 v2 H1 H2. rewrite H1 in H2. inversion H2. reflexivity.
Qed.

(* An empty statement list leaves the frame environment untouched. *)
Lemma exec_stmts_fn_nil_step :
  forall fuel funs env,
    exec_stmts_fn (S fuel) funs env nil = Some (FN_CONTINUE env).
Proof. reflexivity. Qed.

(* Binding arguments produces a frame of exactly the parameter count. *)
Lemma bind_args_env_length :
  forall (params : list ident) (args : list st_value) (env : st_env),
    bind_args params args = Some env ->
    List.length env = List.length params.
Proof.
  induction params as [|p ps IH]; intros args env H.
  - destruct args as [|a rest]; simpl in H; try discriminate.
    inversion H; subst; reflexivity.
  - destruct args as [|a rest]; simpl in H; try discriminate.
    destruct (bind_args ps rest) eqn:Hb; try discriminate.
    inversion H; subst.
    specialize (IH rest s Hb).
    simpl. rewrite <- IH. reflexivity.
Qed.

(* A successful call only happens when the callee is present and its
   formal input-parameter count matches the actual argument count. *)
Lemma call_function_fn_arity :
  forall fuel funs name args v,
    call_function_fn fuel funs name args = Some v ->
    exists ty decls body,
      lookup_function_pou name funs = Some (ty, decls, body) /\
      List.length (input_param_names decls) = List.length args.
Proof.
  intros fuel. induction fuel as [|f IH]; intros funs name args v H.
  - simpl in H. discriminate.
  - simpl in H.
    destruct (lookup_function_pou name funs) as [fo|] eqn:Hlk;
      try discriminate.
    destruct fo as [[ty decls] body].
    destruct (Nat.eqb (List.length (input_param_names decls))
                      (List.length args)) eqn:Hlen; try discriminate.
    destruct (bind_args (input_param_names decls) args) eqn:Hb;
      try discriminate.
    exists ty, decls, body.
    split.
    + reflexivity.
    + apply (bind_args_length _ _ _ Hb).
Qed.

(* ================================================================
   WS-D.2a: 有界 FOR 循环的终止度量（source-level）。

   出厂管线仅放行常数界的 FOR（function_check.v），desugar 后循环统一
   以 fuel 大步模型执行。exec_for 的递归结构是 {struct fuel}，并且每
   迭代一次消耗一格 fuel、控制变量按 step 前进。下面两个引理刻画该
   终止度量：其一，燃料耗尽（fuel = O）时循环不求值；其二，一旦控制
   变量越过常数上界（c > finish），循环在仅一格 fuel 下立即返回，不再
   执行循环体——即迭代次数由 (finish - start)/step + 1 有界，与燃料预
   算一致。
   ================================================================ *)

(* 燃料耗尽时 exec_for 不求值（fuel 是循环的终止度量）。 *)
Lemma exec_for_zero_fuel_none :
  forall (funs : list st_pou) (v : ident)
         (finish stepv : st_value) (body : list st_stmt) (env : st_env),
    exec_for O funs v finish stepv body env = None.
Proof. reflexivity. Qed.

(* 控制变量已超过常数上界：循环立即终止，返回原帧，不执行循环体。 *)
Lemma exec_for_past_bound_terminates :
  forall (fuel : nat) (funs : list st_pou) (v : ident)
         (finish stepv : st_value) (body : list st_stmt) (env : st_env)
         (cur : st_value) (c f : Z),
    lookup_env env v = Some cur ->
    case_sel_to_z cur = Some c ->
    case_sel_to_z finish = Some f ->
    (f < c)%Z ->
    exec_for (S fuel) funs v finish stepv body env = Some (FN_CONTINUE env).
Proof.
  intros fuel funs v finish stepv body env cur c f Hv Hc Hf Hlt.
  cbn [exec_for].
  rewrite Hv, Hc, Hf.
  cbn [case_sel_to_z].
  destruct (Z.leb c f) eqn:Hle.
  - assert (c <= f)%Z by (apply Z.leb_le; exact Hle). lia.
  - reflexivity.
Qed.
