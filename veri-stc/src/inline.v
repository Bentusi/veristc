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
From Stdlib Require Import ZArith.
Require Import veristc_spec.safest.
Import ListNotations.
Local Open Scope Z_scope.

Definition simple_function : Type :=
  list ident * st_expr.

Definition cycle_counter_name : ident := ID "__veristc_cycle_counter".

Definition is_builtin_function (name : ident) : bool :=
  match name with
  | ID "CycleCounter" => true
  | _ => false
  end.

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
              | None =>
                  if is_builtin_function name then
                    match args' with
                    | nil => Some (E_VAR cycle_counter_name)
                    | _ => None
                    end
                  else
                    None
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
          match expand_exprs fuel' defs (List.map snd params) with
          | Some args' =>
              Some (S_FB_CALL inst
                      (List.combine (List.map fst params) args'))
          | None => None
          end
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
      | Some body' =>
          let increment :=
            S_ASSIGN cycle_counter_name
              (E_BIN_OP B_ADD (E_VAR cycle_counter_name)
                              (E_LIT (L_INT 1%Z))) in
          Some (Some (P_PROGRAM name decls (increment :: body')))
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
      let counter_decl :=
        Build_st_var_decl cycle_counter_name T_DINT D_GLOBAL Q_NONE None in
      Some {| global_vars := p.(global_vars) ++ [counter_decl];
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

(* ================================================================
   Normalization for full FUNCTION support

   This pass replaces the old mandatory single-expression inliner.
   It expands only builtins and keeps user FUNCTION definitions so
   the backend can emit real CALL instructions. Simple functions may
   later be inlined as an optimization, but inlining is no longer a
   validity requirement.
   ================================================================ *)

Fixpoint normalize_expr
         (fuel : nat) (e : st_expr)
         {struct fuel} : option st_expr :=
  match fuel with
  | O => None
  | S fuel' =>
      match e with
      | E_LIT lit => Some (E_LIT lit)
      | E_VAR name => Some (E_VAR name)
      | E_ARRAY_ACCESS arr idx =>
          match normalize_expr fuel' arr, normalize_expr fuel' idx with
          | Some arr', Some idx' => Some (E_ARRAY_ACCESS arr' idx')
          | _, _ => None
          end
      | E_UNARY_OP op arg =>
          match normalize_expr fuel' arg with
          | Some arg' => Some (E_UNARY_OP op arg')
          | None => None
          end
      | E_BIN_OP op lhs rhs =>
          match normalize_expr fuel' lhs, normalize_expr fuel' rhs with
          | Some lhs', Some rhs' => Some (E_BIN_OP op lhs' rhs')
          | _, _ => None
          end
      | E_COMP op lhs rhs =>
          match normalize_expr fuel' lhs, normalize_expr fuel' rhs with
          | Some lhs', Some rhs' => Some (E_COMP op lhs' rhs')
          | _, _ => None
          end
      | E_AND lhs rhs =>
          match normalize_expr fuel' lhs, normalize_expr fuel' rhs with
          | Some lhs', Some rhs' => Some (E_AND lhs' rhs')
          | _, _ => None
          end
      | E_OR lhs rhs =>
          match normalize_expr fuel' lhs, normalize_expr fuel' rhs with
          | Some lhs', Some rhs' => Some (E_OR lhs' rhs')
          | _, _ => None
          end
      | E_XOR lhs rhs =>
          match normalize_expr fuel' lhs, normalize_expr fuel' rhs with
          | Some lhs', Some rhs' => Some (E_XOR lhs' rhs')
          | _, _ => None
          end
      | E_FUNC_CALL name args =>
          match normalize_exprs fuel' args with
          | Some args' =>
              if is_builtin_function name then
                match args' with
                | nil => Some (E_VAR cycle_counter_name)
                | _ => None
                end
              else
                Some (E_FUNC_CALL name args')
          | None => None
          end
      | E_QUALITY_OP op args =>
          match normalize_exprs fuel' args with
          | Some args' => Some (E_QUALITY_OP op args')
          | None => None
          end
      end
  end

with normalize_exprs
       (fuel : nat) (exprs : list st_expr)
       {struct fuel} : option (list st_expr) :=
  match fuel with
  | O => None
  | S fuel' =>
      match exprs with
      | nil => Some nil
      | e :: rest =>
          match normalize_expr fuel' e, normalize_exprs fuel' rest with
          | Some e', Some rest' => Some (e' :: rest')
          | _, _ => None
          end
      end
  end.

Fixpoint normalize_stmt
         (fuel : nat) (stmt : st_stmt)
         {struct fuel} : option st_stmt :=
  match fuel with
  | O => None
  | S fuel' =>
      match stmt with
      | S_ASSIGN name rhs =>
          match normalize_expr fuel' rhs with
          | Some rhs' => Some (S_ASSIGN name rhs')
          | None => None
          end
      | S_ARRAY_ASSIGN name idx rhs =>
          match normalize_expr fuel' idx, normalize_expr fuel' rhs with
          | Some idx', Some rhs' => Some (S_ARRAY_ASSIGN name idx' rhs')
          | _, _ => None
          end
      | S_IF cond then_body else_body =>
          match normalize_expr fuel' cond,
                normalize_stmts fuel' then_body,
                normalize_opt_stmts fuel' else_body with
          | Some cond', Some then', Some else' =>
              Some (S_IF cond' then' else')
          | _, _, _ => None
          end
      | S_CASE selector branches default =>
          match normalize_expr fuel' selector,
                normalize_case_elements fuel' branches,
                normalize_opt_stmts fuel' default with
          | Some selector', Some branches', Some default' =>
              Some (S_CASE selector' branches' default')
          | _, _, _ => None
          end
      | S_FOR name start finish step body =>
          match normalize_expr fuel' start,
                normalize_expr fuel' finish,
                normalize_opt_expr fuel' step,
                normalize_stmts fuel' body with
          | Some start', Some finish', Some step', Some body' =>
              Some (S_FOR name start' finish' step' body')
          | _, _, _, _ => None
          end
      | S_WHILE cond body =>
          match normalize_expr fuel' cond, normalize_stmts fuel' body with
          | Some cond', Some body' => Some (S_WHILE cond' body')
          | _, _ => None
          end
      | S_REPEAT body cond =>
          match normalize_stmts fuel' body, normalize_expr fuel' cond with
          | Some body', Some cond' => Some (S_REPEAT body' cond')
          | _, _ => None
          end
      | S_FB_CALL inst params =>
          match normalize_exprs fuel' (List.map snd params) with
          | Some args' =>
              Some (S_FB_CALL inst (List.combine (List.map fst params) args'))
          | None => None
          end
      | S_RETURN => Some S_RETURN
      | S_EXIT => Some S_EXIT
      end
  end

with normalize_stmts
       (fuel : nat) (stmts : list st_stmt)
       {struct fuel} : option (list st_stmt) :=
  match fuel with
  | O => None
  | S fuel' =>
      match stmts with
      | nil => Some nil
      | stmt :: rest =>
          match normalize_stmt fuel' stmt, normalize_stmts fuel' rest with
          | Some stmt', Some rest' => Some (stmt' :: rest')
          | _, _ => None
          end
      end
  end

with normalize_opt_stmts
       (fuel : nat) (stmts : option (list st_stmt))
       {struct fuel} : option (option (list st_stmt)) :=
  match fuel with
  | O => None
  | S fuel' =>
      match stmts with
      | None => Some None
      | Some body =>
          match normalize_stmts fuel' body with
          | Some body' => Some (Some body')
          | None => None
          end
      end
  end

with normalize_opt_expr
       (fuel : nat) (expr : option st_expr)
       {struct fuel} : option (option st_expr) :=
  match fuel with
  | O => None
  | S fuel' =>
      match expr with
      | None => Some None
      | Some e =>
          match normalize_expr fuel' e with
          | Some e' => Some (Some e')
          | None => None
          end
      end
  end

with normalize_case_elements
       (fuel : nat) (branches : list case_element)
       {struct fuel} : option (list case_element) :=
  match fuel with
  | O => None
  | S fuel' =>
      match branches with
      | nil => Some nil
      | CASE_ELEM values body :: rest =>
          match normalize_stmts fuel' body,
                normalize_case_elements fuel' rest with
          | Some body', Some rest' =>
              Some (CASE_ELEM values body' :: rest')
          | _, _ => None
          end
      end
  end.

Definition normalize_pou (fuel : nat) (pou : st_pou) : option st_pou :=
  match pou with
  | P_PROGRAM name decls body =>
      match normalize_stmts fuel body with
      | Some body' =>
          let increment :=
            S_ASSIGN cycle_counter_name
              (E_BIN_OP B_ADD (E_VAR cycle_counter_name)
                              (E_LIT (L_INT 1%Z))) in
          Some (P_PROGRAM name decls (increment :: body'))
      | None => None
      end
  | P_FUNCTION name ty decls body =>
      match normalize_stmts fuel body with
      | Some body' => Some (P_FUNCTION name ty decls body')
      | None => None
      end
  | P_FUNCTION_BLOCK name decls body =>
      match normalize_stmts fuel body with
      | Some body' => Some (P_FUNCTION_BLOCK name decls body')
      | None => None
      end
  end.

Fixpoint normalize_pous
         (fuel : nat) (pous : list st_pou)
         {struct pous} : option (list st_pou) :=
  match pous with
  | nil => Some nil
  | pou :: rest =>
      match normalize_pou fuel pou, normalize_pous fuel rest with
      | Some pou', Some rest' => Some (pou' :: rest')
      | _, _ => None
      end
  end.

Definition normalize_program (p : st_program) : option st_program :=
  match normalize_pous inline_fuel p.(pou_list) with
  | Some pous =>
      let counter_decl :=
        Build_st_var_decl cycle_counter_name T_DINT D_GLOBAL Q_NONE None in
      Some {| global_vars := p.(global_vars) ++ [counter_decl];
              pou_list := pous;
              io_mapping := p.(io_mapping);
              entry_point := p.(entry_point) |}
  | None => None
  end.

(* ================================================================
   Selective inlining optimization

   Inlining is optional and must preserve semantics. This pass only
   expands small single-expression functions whose bodies contain no
   remaining user calls and whose arguments contain no user calls.
   Complex functions remain real SafeASM CALLs.
   ================================================================ *)

Definition inline_size_limit : nat := 64.

Fixpoint expr_nodes_le (fuel : nat) (e : st_expr) {struct fuel} : bool :=
  match fuel with
  | O => false
  | S fuel' =>
      match e with
      | E_LIT _ | E_VAR _ => true
      | E_ARRAY_ACCESS a i =>
          expr_nodes_le fuel' a && expr_nodes_le fuel' i
      | E_UNARY_OP _ a => expr_nodes_le fuel' a
      | E_BIN_OP _ a b | E_COMP _ a b
      | E_AND a b | E_OR a b | E_XOR a b =>
          expr_nodes_le fuel' a && expr_nodes_le fuel' b
      | E_FUNC_CALL _ args | E_QUALITY_OP _ args =>
          exprs_nodes_le fuel' args
      end
  end

with exprs_nodes_le (fuel : nat) (es : list st_expr) {struct fuel} : bool :=
  match fuel with
  | O => false
  | S fuel' =>
      match es with
      | nil => true
      | e :: rest => expr_nodes_le fuel' e && exprs_nodes_le fuel' rest
      end
  end.

Fixpoint expr_has_user_call (e : st_expr) {struct e} : bool :=
  match e with
  | E_LIT _ | E_VAR _ => false
  | E_ARRAY_ACCESS a i => expr_has_user_call a || expr_has_user_call i
  | E_UNARY_OP _ a => expr_has_user_call a
  | E_BIN_OP _ a b | E_COMP _ a b
  | E_AND a b | E_OR a b | E_XOR a b =>
      expr_has_user_call a || expr_has_user_call b
  | E_FUNC_CALL name args =>
      negb (is_builtin_function name) ||
      List.existsb expr_has_user_call args
  | E_QUALITY_OP _ args => List.existsb expr_has_user_call args
  end.

Definition function_inline_decls_ok (name : ident)
           (decls : list st_var_decl) : bool :=
  List.forallb
    (fun d =>
       match d.(var_dir) with
       | D_INPUT => true
       | D_LOCAL => ident_eq d.(var_name) name
       | _ => false
       end) decls.

Fixpoint lookup_inlineable_function
         (name : ident) (defs : list st_pou)
         : option (list ident * st_expr) :=
  match defs with
  | nil => None
  | P_FUNCTION fn_name _ decls body :: rest =>
      if ident_eq name fn_name then
        match simple_function_body fn_name body with
        | Some rhs =>
            if function_inline_decls_ok fn_name decls &&
               negb (expr_has_user_call rhs) &&
               expr_nodes_le inline_size_limit rhs
            then Some (function_param_names decls, rhs)
            else None
        | None => None
        end
      else
        lookup_inlineable_function name rest
  | _ :: rest => lookup_inlineable_function name rest
  end.

Fixpoint inline_leaf_expr (defs : list st_pou) (e : st_expr)
         {struct e} : st_expr :=
  match e with
  | E_LIT lit => E_LIT lit
  | E_VAR name => E_VAR name
  | E_ARRAY_ACCESS arr idx =>
      E_ARRAY_ACCESS (inline_leaf_expr defs arr)
                     (inline_leaf_expr defs idx)
  | E_UNARY_OP op arg => E_UNARY_OP op (inline_leaf_expr defs arg)
  | E_BIN_OP op lhs rhs =>
      E_BIN_OP op (inline_leaf_expr defs lhs) (inline_leaf_expr defs rhs)
  | E_COMP op lhs rhs =>
      E_COMP op (inline_leaf_expr defs lhs) (inline_leaf_expr defs rhs)
  | E_AND lhs rhs =>
      E_AND (inline_leaf_expr defs lhs) (inline_leaf_expr defs rhs)
  | E_OR lhs rhs =>
      E_OR (inline_leaf_expr defs lhs) (inline_leaf_expr defs rhs)
  | E_XOR lhs rhs =>
      E_XOR (inline_leaf_expr defs lhs) (inline_leaf_expr defs rhs)
  | E_FUNC_CALL name args =>
      let args' := List.map (inline_leaf_expr defs) args in
      match lookup_inlineable_function name defs with
      | Some (params, body) =>
          if Nat.eqb (List.length params) (List.length args') &&
             negb (List.existsb expr_has_user_call args')
          then
            let expanded := subst_expr params args' body in
            if expr_nodes_le inline_size_limit expanded then
              expanded
            else
              E_FUNC_CALL name args'
          else
            E_FUNC_CALL name args'
      | None => E_FUNC_CALL name args'
      end
  | E_QUALITY_OP op args =>
      E_QUALITY_OP op (List.map (inline_leaf_expr defs) args)
  end.

Fixpoint inline_leaf_stmt (defs : list st_pou) (s : st_stmt)
         {struct s} : st_stmt :=
  match s with
  | S_ASSIGN x e => S_ASSIGN x (inline_leaf_expr defs e)
  | S_ARRAY_ASSIGN x idx e =>
      S_ARRAY_ASSIGN x (inline_leaf_expr defs idx) (inline_leaf_expr defs e)
  | S_IF cond then_body else_body =>
      S_IF (inline_leaf_expr defs cond)
           (List.map (inline_leaf_stmt defs) then_body)
           (match else_body with
            | None => None
            | Some body => Some (List.map (inline_leaf_stmt defs) body)
            end)
  | S_CASE sel branches default =>
      S_CASE (inline_leaf_expr defs sel)
             (List.map
                (fun ce =>
                   match ce with
                   | CASE_ELEM values body =>
                       CASE_ELEM values (List.map (inline_leaf_stmt defs) body)
                   end) branches)
             (match default with
              | None => None
              | Some body => Some (List.map (inline_leaf_stmt defs) body)
              end)
  | S_FOR v start finish step body =>
      S_FOR v
            (inline_leaf_expr defs start)
            (inline_leaf_expr defs finish)
            (match step with
             | None => None
             | Some e => Some (inline_leaf_expr defs e)
             end)
            (List.map (inline_leaf_stmt defs) body)
  | S_WHILE cond body =>
      S_WHILE (inline_leaf_expr defs cond)
              (List.map (inline_leaf_stmt defs) body)
  | S_REPEAT body cond =>
      S_REPEAT (List.map (inline_leaf_stmt defs) body)
               (inline_leaf_expr defs cond)
  | S_FB_CALL inst params =>
      S_FB_CALL inst
                (List.map (fun p => (fst p, inline_leaf_expr defs (snd p)))
                          params)
  | S_RETURN => S_RETURN
  | S_EXIT => S_EXIT
  end.

Definition inline_leaf_pou (defs : list st_pou) (pou : st_pou) : st_pou :=
  match pou with
  | P_PROGRAM name decls body =>
      P_PROGRAM name decls (List.map (inline_leaf_stmt defs) body)
  | P_FUNCTION name ty decls body =>
      P_FUNCTION name ty decls (List.map (inline_leaf_stmt defs) body)
  | P_FUNCTION_BLOCK name decls body =>
      P_FUNCTION_BLOCK name decls (List.map (inline_leaf_stmt defs) body)
  end.

Fixpoint inline_leaf_pous_passes
         (passes : nat) (pous : list st_pou) : list st_pou :=
  match passes with
  | O => pous
  | S passes' =>
      inline_leaf_pous_passes passes'
        (List.map (inline_leaf_pou pous) pous)
  end.

Fixpoint expr_calls_name (name : ident) (e : st_expr) {struct e} : bool :=
  match e with
  | E_LIT _ | E_VAR _ => false
  | E_ARRAY_ACCESS a i => expr_calls_name name a || expr_calls_name name i
  | E_UNARY_OP _ a => expr_calls_name name a
  | E_BIN_OP _ a b | E_COMP _ a b
  | E_AND a b | E_OR a b | E_XOR a b =>
      expr_calls_name name a || expr_calls_name name b
  | E_FUNC_CALL f args =>
      ident_eq f name || List.existsb (expr_calls_name name) args
  | E_QUALITY_OP _ args => List.existsb (expr_calls_name name) args
  end.

Fixpoint stmt_calls_name (name : ident) (s : st_stmt) {struct s} : bool :=
  match s with
  | S_ASSIGN _ e => expr_calls_name name e
  | S_ARRAY_ASSIGN _ idx e =>
      expr_calls_name name idx || expr_calls_name name e
  | S_IF cond then_body else_body =>
      expr_calls_name name cond ||
      List.existsb (stmt_calls_name name) then_body ||
      match else_body with
      | None => false
      | Some body => List.existsb (stmt_calls_name name) body
      end
  | S_CASE sel branches default =>
      expr_calls_name name sel ||
      List.existsb
        (fun ce =>
           match ce with
           | CASE_ELEM _ body => List.existsb (stmt_calls_name name) body
           end) branches ||
      match default with
      | None => false
      | Some body => List.existsb (stmt_calls_name name) body
      end
  | S_FOR _ start finish step body =>
      expr_calls_name name start ||
      expr_calls_name name finish ||
      (match step with
       | None => false
       | Some e => expr_calls_name name e
       end) ||
      List.existsb (stmt_calls_name name) body
  | S_WHILE cond body =>
      expr_calls_name name cond ||
      List.existsb (stmt_calls_name name) body
  | S_REPEAT body cond =>
      List.existsb (stmt_calls_name name) body ||
      expr_calls_name name cond
  | S_FB_CALL _ params =>
      List.existsb (fun p => expr_calls_name name (snd p)) params
  | S_RETURN | S_EXIT => false
  end.

Definition pou_calls_name (name : ident) (pou : st_pou) : bool :=
  let body :=
    match pou with
    | P_PROGRAM _ _ b => b
    | P_FUNCTION _ _ _ b => b
    | P_FUNCTION_BLOCK _ _ b => b
    end in
  List.existsb (stmt_calls_name name) body.

Definition pou_name_of (pou : st_pou) : ident :=
  match pou with
  | P_PROGRAM name _ _ => name
  | P_FUNCTION name _ _ _ => name
  | P_FUNCTION_BLOCK name _ _ => name
  end.

Definition other_pous_call_name
           (name : ident) (pous : list st_pou) : bool :=
  List.existsb
    (fun pou =>
       negb (ident_eq (pou_name_of pou) name) && pou_calls_name name pou)
    pous.

Definition remove_dead_functions (pous : list st_pou) : list st_pou :=
  List.filter
    (fun pou =>
       match pou with
       | P_FUNCTION name _ _ _ => other_pous_call_name name pous
       | _ => true
       end) pous.

Fixpoint remove_dead_functions_iter
         (passes : nat) (pous : list st_pou) : list st_pou :=
  match passes with
  | O => pous
  | S passes' =>
      remove_dead_functions_iter passes' (remove_dead_functions pous)
  end.

Definition optimize_inline_program (p : st_program) : st_program :=
  let inline_passes := S (List.length p.(pou_list)) in
  let pous1 := inline_leaf_pous_passes inline_passes p.(pou_list) in
  let pous2 := remove_dead_functions_iter (S (List.length pous1)) pous1 in
  {| global_vars := p.(global_vars);
     pou_list := pous2;
     io_mapping := p.(io_mapping);
     entry_point := p.(entry_point) |}.

(* ================================================================
   WS-E：选择性内联的可靠性引理（结构级）
   ----------------------------------------------------------------
   本段证明 optimize_inline_program 的两个安全前置：
   (E.2) 只有“纯叶子单表达式函数”会被 lookup_inlineable_function
         判定为可内联：函数体恰为单条 result := rhs、rhs 不含任何
         用户调用 (expr_has_user_call rhs = false)、形参恰为 D_INPUT
         声明、非输入声明只允许是结果变量本身；
   (E.3) remove_dead_functions 只会删除 P_FUNCTION，且仅当没有任何
         其它 POU 引用它；非函数 POU（含入口 PROGRAM）永不因该 pass
         被删除。
   这两点是“内联=call-site 替换、删死代码不改变可观测行为”的必要前置；
   跨 subst_expr 与 call_function_fn 的完整大步值级等价仍为后续前沿。
   ================================================================ *)

Lemma ident_eq_true :
  forall x y : ident, ident_eq x y = true -> x = y.
Proof.
  destruct x as [s1]; destruct y as [s2]. simpl.
  intro H. apply f_equal. apply (proj1 (String.eqb_eq _ _)). exact H.
Qed.

(* E.2：判定可内联蕴含被内联者为纯叶子单表达式函数。 *)
Lemma lookup_inlineable_function_Some :
  forall (defs : list st_pou) (name : ident)
         (params : list ident) (rhs : st_expr),
    lookup_inlineable_function name defs = Some (params, rhs) ->
    exists ty decls body,
      In (P_FUNCTION name ty decls body) defs /\
      simple_function_body name body = Some rhs /\
      params = function_param_names decls /\
      function_inline_decls_ok name decls = true /\
      expr_has_user_call rhs = false /\
      expr_nodes_le inline_size_limit rhs = true.
Proof.
  induction defs as [|d rest IH]; intros name params rhs H;
    cbn [lookup_inlineable_function] in H.
  - discriminate.
  - destruct d as [pn pdecls pbody | fn fty fdecls fbody | bn bdecls bbody].
    + destruct (IH name params rhs H)
        as [ty [decls [body [Hin [Hb [Hp [Hok [Huc Hnl]]]]]]]].
      exists ty, decls, body.
      split; [apply List.in_cons; exact Hin |].
      split; [exact Hb |].
      split; [exact Hp |].
      split; [exact Hok |].
      split; [exact Huc |].
      exact Hnl.
    + destruct (ident_eq name fn) eqn:Heq.
      * apply ident_eq_true in Heq. subst fn.
        destruct (simple_function_body name fbody) as [rhs'|] eqn:Hb;
          try discriminate.
        destruct (function_inline_decls_ok name fdecls
                    && negb (expr_has_user_call rhs')
                    && expr_nodes_le inline_size_limit rhs') eqn:Hok.
        {
          inversion H; subst.
          apply (proj1 (andb_true_iff _ _)) in Hok.
          destruct Hok as [HAB HC].
          apply (proj1 (andb_true_iff _ _)) in HAB.
          destruct HAB as [Hok1 HB].
          exists fty, fdecls, fbody.
          split; [apply List.in_eq |].
          split; [exact Hb |].
          split; [reflexivity |].
          split; [exact Hok1 |].
          split; [apply (proj1 (negb_true_iff _)); exact HB |].
          exact HC.
        }
        { discriminate. }
      * destruct (IH name params rhs H)
          as [ty [decls [body [Hin [Hb [Hp [Hok [Huc Hnl]]]]]]]].
        exists ty, decls, body.
        split; [apply List.in_cons; exact Hin |].
        split; [exact Hb |].
        split; [exact Hp |].
        split; [exact Hok |].
        split; [exact Huc |].
        exact Hnl.
    + destruct (IH name params rhs H)
        as [ty [decls [body [Hin [Hb [Hp [Hok [Huc Hnl]]]]]]]].
      exists ty, decls, body.
      split; [apply List.in_cons; exact Hin |].
      split; [exact Hb |].
      split; [exact Hp |].
      split; [exact Hok |].
      split; [exact Huc |].
      exact Hnl.
Qed.

(* E.2 补充：function_inline_decls_ok 为真时，每个声明要么为输入，
   要么是名字等于结果变量的局部（不允许其它方向/额外局部）。 *)
Lemma function_inline_decls_ok_spec :
  forall (name : ident) (decls : list st_var_decl),
    function_inline_decls_ok name decls = true ->
    forall d, In d decls ->
      var_dir d = D_INPUT \/
      (var_dir d = D_LOCAL /\ var_name d = name).
Proof.
  intros name decls Hok d Hd.
  unfold function_inline_decls_ok in Hok.
  rewrite forallb_forall in Hok.
  specialize (Hok d Hd). cbn beta in Hok.
  destruct (var_dir d) eqn:Hdr; cbn in Hok;
    [ left; reflexivity
    | discriminate
    | discriminate
    | right; split; [reflexivity | apply ident_eq_true; exact Hok]
    | discriminate ].
Qed.

(* E.3：非函数 POU 不会被 remove_dead_functions 删除。 *)
Lemma remove_dead_functions_keeps :
  forall pous pou, In pou pous ->
    (match pou with
     | P_FUNCTION _ _ _ _ => True
     | _ => In pou (remove_dead_functions pous) end).
Proof.
  intros pous pou Hin.
  destruct pou as [pn d b | fn ty d b | bn d b].
  - unfold remove_dead_functions.
    apply (proj2 (List.filter_In _ _ _)). split; [exact Hin | reflexivity].
  - exact I.
  - unfold remove_dead_functions.
    apply (proj2 (List.filter_In _ _ _)). split; [exact Hin | reflexivity].
Qed.

(* E.3：被删除的函数一定没有任何其它 POU 引用它。 *)
Lemma remove_dead_functions_drop_not_called :
  forall pous name ty decls body,
    other_pous_call_name name pous = false ->
    ~ In (P_FUNCTION name ty decls body) (remove_dead_functions pous).
Proof.
  intros pous name ty decls body Hfalse Hin.
  unfold remove_dead_functions in Hin.
  apply (proj1 (List.filter_In _ _ _)) in Hin.
  destruct Hin as [_ HPred]. simpl in HPred.
  rewrite Hfalse in HPred. discriminate.
Qed.
