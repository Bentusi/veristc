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
  - simpl. destruct x; simpl.
    reflexivity.
  - destruct hd as [y old]. simpl.
    destruct (ident_eq x y) eqn:Hxy.
    + apply ident_eq_eq in Hxy. subst y. reflexivity.
    + exact IH.
Qed.
