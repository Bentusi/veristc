(* ================================================================
   veristc/src/inline.v
   SafeST pure-function inlining.

   The core generator accepts one PROGRAM and no CALL instructions.
   This pass expands explicitly declared, single-expression FUNCTION
   definitions at their call sites. The resulting program is checked
   and compiled by the existing verified core pipeline.
   ================================================================ *)

From Stdlib Require Import List.
From Stdlib Require Import Bool.
From Stdlib Require Import String.
Require Import veristc_spec.safest.
Import ListNotations.

Definition simple_function : Type :=
  list ident * st_expr.

Fixpoint function_param_names (decls : list st_var_decl) : list ident :=
  match decls with
  | nil => nil
  | d :: rest =>
      match d.(var_dir) with
      | D_INPUT => d.(var_name) :: function_param_names rest
      | _ => function_param_names rest
      end
  end.

Definition simple_function_body
           (name : ident) (body : list st_stmt) : option st_expr :=
  match body with
  | [S_ASSIGN lhs rhs] =>
      if ident_eq lhs name then Some rhs else None
  | _ => None
  end.

Fixpoint lookup_simple_function
         (name : ident) (pous : list st_pou) : option simple_function :=
  match pous with
  | nil => None
  | P_FUNCTION fn_name _ decls body :: rest =>
      if ident_eq name fn_name then
        match simple_function_body fn_name body with
        | Some rhs =>
            Some (function_param_names decls, rhs)
        | None =>
            lookup_simple_function name rest
        end
      else
        lookup_simple_function name rest
  | _ :: rest => lookup_simple_function name rest
  end.

Fixpoint lookup_argument
         (params : list ident) (args : list st_expr)
         (name : ident) : option st_expr :=
  match params, args with
  | p :: ps, a :: rest =>
      if ident_eq name p then Some a else lookup_argument ps rest name
  | _, _ => None
  end.

Fixpoint subst_expr
         (params : list ident) (args : list st_expr)
         (e : st_expr) : st_expr :=
  match e with
  | E_LIT lit => E_LIT lit
  | E_VAR name =>
      match lookup_argument params args name with
      | Some arg => arg
      | None => E_VAR name
      end
  | E_ARRAY_ACCESS arr idx =>
      E_ARRAY_ACCESS (subst_expr params args arr)
                     (subst_expr params args idx)
  | E_UNARY_OP op arg =>
      E_UNARY_OP op (subst_expr params args arg)
  | E_BIN_OP op lhs rhs =>
      E_BIN_OP op (subst_expr params args lhs)
                  (subst_expr params args rhs)
  | E_COMP op lhs rhs =>
      E_COMP op (subst_expr params args lhs)
                (subst_expr params args rhs)
  | E_AND lhs rhs =>
      E_AND (subst_expr params args lhs) (subst_expr params args rhs)
  | E_OR lhs rhs =>
      E_OR (subst_expr params args lhs) (subst_expr params args rhs)
  | E_XOR lhs rhs =>
      E_XOR (subst_expr params args lhs) (subst_expr params args rhs)
  | E_FUNC_CALL name call_args =>
      E_FUNC_CALL name (List.map (subst_expr params args) call_args)
  | E_QUALITY_OP op call_args =>
      E_QUALITY_OP op (List.map (subst_expr params args) call_args)
  end.

Definition inline_fuel : nat := 1000000.

Fixpoint expand_expr
         (fuel : nat) (defs : list st_pou) (e : st_expr)
         {struct fuel} : option st_expr :=
  match fuel with
  | O => None
  | S fuel' =>
      match e with
      | E_LIT lit => Some (E_LIT lit)
      | E_VAR name => Some (E_VAR name)
      | E_ARRAY_ACCESS arr idx =>
          match expand_expr fuel' defs arr,
                expand_expr fuel' defs idx with
          | Some arr', Some idx' => Some (E_ARRAY_ACCESS arr' idx')
          | _, _ => None
          end
      | E_UNARY_OP op arg =>
          match expand_expr fuel' defs arg with
          | Some arg' => Some (E_UNARY_OP op arg')
          | None => None
          end
      | E_BIN_OP op lhs rhs =>
          match expand_expr fuel' defs lhs,
                expand_expr fuel' defs rhs with
          | Some lhs', Some rhs' => Some (E_BIN_OP op lhs' rhs')
          | _, _ => None
          end
      | E_COMP op lhs rhs =>
          match expand_expr fuel' defs lhs,
                expand_expr fuel' defs rhs with
          | Some lhs', Some rhs' => Some (E_COMP op lhs' rhs')
          | _, _ => None
          end
      | E_AND lhs rhs =>
          match expand_expr fuel' defs lhs,
                expand_expr fuel' defs rhs with
          | Some lhs', Some rhs' => Some (E_AND lhs' rhs')
          | _, _ => None
          end
      | E_OR lhs rhs =>
          match expand_expr fuel' defs lhs,
                expand_expr fuel' defs rhs with
          | Some lhs', Some rhs' => Some (E_OR lhs' rhs')
          | _, _ => None
          end
      | E_XOR lhs rhs =>
          match expand_expr fuel' defs lhs,
                expand_expr fuel' defs rhs with
          | Some lhs', Some rhs' => Some (E_XOR lhs' rhs')
          | _, _ => None
          end
      | E_FUNC_CALL name args =>
          match expand_exprs fuel' defs args with
          | Some args' =>
              match lookup_simple_function name defs with
              | Some (params, body) =>
                  if Nat.eqb (List.length params) (List.length args') then
                    expand_expr fuel' defs (subst_expr params args' body)
                  else
                    None
              | None => None
              end
          | None => None
          end
      | E_QUALITY_OP op args =>
          match expand_exprs fuel' defs args with
          | Some args' => Some (E_QUALITY_OP op args')
          | None => None
          end
      end
  end
with expand_exprs
       (fuel : nat) (defs : list st_pou) (exprs : list st_expr)
       {struct fuel} : option (list st_expr) :=
  match fuel with
  | O => None
  | S fuel' =>
      match exprs with
      | nil => Some nil
      | e :: rest =>
          match expand_expr fuel' defs e,
                expand_exprs fuel' defs rest with
          | Some e', Some rest' => Some (e' :: rest')
          | _, _ => None
          end
      end
  end.

Fixpoint expand_stmt
         (fuel : nat) (defs : list st_pou) (stmt : st_stmt)
         {struct fuel} : option st_stmt :=
  match fuel with
  | O => None
  | S fuel' =>
      match stmt with
      | S_ASSIGN name rhs =>
          match expand_expr fuel' defs rhs with
          | Some rhs' => Some (S_ASSIGN name rhs')
          | None => None
          end
      | S_ARRAY_ASSIGN name idx rhs =>
          match expand_expr fuel' defs idx,
                expand_expr fuel' defs rhs with
          | Some idx', Some rhs' => Some (S_ARRAY_ASSIGN name idx' rhs')
          | _, _ => None
          end
      | S_IF cond then_body else_body =>
          match expand_expr fuel' defs cond,
                expand_stmts fuel' defs then_body,
                expand_opt_stmts fuel' defs else_body with
          | Some cond', Some then', Some else' =>
              Some (S_IF cond' then' else')
          | _, _, _ => None
          end
      | S_CASE selector branches default =>
          match expand_expr fuel' defs selector,
                expand_case_elements fuel' defs branches,
                expand_opt_stmts fuel' defs default with
          | Some selector', Some branches', Some default' =>
              Some (S_CASE selector' branches' default')
          | _, _, _ => None
          end
      | S_FOR name start finish step body =>
          match expand_expr fuel' defs start,
                expand_expr fuel' defs finish,
                expand_opt_expr fuel' defs step,
                expand_stmts fuel' defs body with
          | Some start', Some finish', Some step', Some body' =>
              Some (S_FOR name start' finish' step' body')
          | _, _, _, _ => None
          end
      | S_WHILE cond body =>
          match expand_expr fuel' defs cond,
                expand_stmts fuel' defs body with
          | Some cond', Some body' => Some (S_WHILE cond' body')
          | _, _ => None
          end
      | S_REPEAT body cond =>
          match expand_stmts fuel' defs body,
                expand_expr fuel' defs cond with
          | Some body', Some cond' => Some (S_REPEAT body' cond')
          | _, _ => None
          end
      | S_FB_CALL inst params =>
          Some (S_FB_CALL inst params)
      | S_RETURN => Some S_RETURN
      | S_EXIT => Some S_EXIT
      end
  end
with expand_stmts
       (fuel : nat) (defs : list st_pou) (stmts : list st_stmt)
       {struct fuel} : option (list st_stmt) :=
  match fuel with
  | O => None
  | S fuel' =>
      match stmts with
      | nil => Some nil
      | stmt :: rest =>
          match expand_stmt fuel' defs stmt,
                expand_stmts fuel' defs rest with
          | Some stmt', Some rest' => Some (stmt' :: rest')
          | _, _ => None
          end
      end
  end
with expand_opt_stmts
       (fuel : nat) (defs : list st_pou)
       (stmts : option (list st_stmt)) {struct fuel}
       : option (option (list st_stmt)) :=
  match fuel with
  | O => None
  | S fuel' =>
      match stmts with
      | None => Some None
      | Some body =>
          match expand_stmts fuel' defs body with
          | Some body' => Some (Some body')
          | None => None
          end
      end
  end
with expand_opt_expr
       (fuel : nat) (defs : list st_pou)
       (expr : option st_expr) {struct fuel} : option (option st_expr) :=
  match fuel with
  | O => None
  | S fuel' =>
      match expr with
      | None => Some None
      | Some e =>
          match expand_expr fuel' defs e with
          | Some e' => Some (Some e')
          | None => None
          end
      end
  end
with expand_case_elements
       (fuel : nat) (defs : list st_pou)
       (branches : list case_element) {struct fuel}
       : option (list case_element) :=
  match fuel with
  | O => None
  | S fuel' =>
      match branches with
      | nil => Some nil
      | CASE_ELEM values body :: rest =>
          match expand_stmts fuel' defs body,
                expand_case_elements fuel' defs rest with
          | Some body', Some rest' =>
              Some (CASE_ELEM values body' :: rest')
          | _, _ => None
          end
      end
  end.

Definition expand_program_pou
           (fuel : nat) (defs : list st_pou) (pou : st_pou)
           : option (option st_pou) :=
  match pou with
  | P_PROGRAM name decls body =>
      match expand_stmts fuel defs body with
      | Some body' => Some (Some (P_PROGRAM name decls body'))
      | None => None
      end
  | P_FUNCTION _ _ _ _ => Some None
  | P_FUNCTION_BLOCK _ _ _ => Some (Some pou)
  end.

Fixpoint expand_program_pous
         (fuel : nat) (defs : list st_pou) (pous : list st_pou)
         {struct pous} : option (list st_pou) :=
  match pous with
  | nil => Some nil
  | pou :: rest =>
      match expand_program_pou fuel defs pou,
            expand_program_pous fuel defs rest with
      | Some (Some pou'), Some rest' => Some (pou' :: rest')
      | Some None, Some rest' => Some rest'
      | _, _ => None
      end
  end.

Definition inline_program (p : st_program) : option st_program :=
  match expand_program_pous inline_fuel p.(pou_list) p.(pou_list) with
  | Some pous =>
      Some {| global_vars := p.(global_vars);
              pou_list := pous;
              io_mapping := p.(io_mapping);
              entry_point := p.(entry_point) |}
  | None => None
  end.

Lemma inline_program_preserves_io_mapping :
  forall (p p' : st_program),
    inline_program p = Some p' ->
    p'.(io_mapping) = p.(io_mapping).
Proof.
  intros p p' H.
  unfold inline_program in H.
  destruct (expand_program_pous inline_fuel
              p.(pou_list) p.(pou_list)) as [pous|] eqn:Heq;
    try discriminate.
  inversion H. reflexivity.
Qed.
