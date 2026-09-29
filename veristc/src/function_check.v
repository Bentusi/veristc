(* ================================================================
   veristc/src/function_check.v
   Scoped type checking and preparation for IEC-like FUNCTIONs.

   This module is the engineering front-end for full stateless
   FUNCTION support. It keeps the existing verified core definitions
   untouched while adding:
     - an implicit function-result local variable
     - per-POU lexical scoping
     - function purity checks
     - call-aware expression type checking
   ================================================================ *)

From Stdlib Require Import List.
From Stdlib Require Import Bool.
From Stdlib Require Import String.
From Stdlib Require Import ZArith.
Require Import veristc_spec.safest.
Require Import veristc_spec.st_semantics.
Require Import veristc_src.typechecker.
Local Open Scope Z_scope.
Import ListNotations.

(* ------------------------------------------------------------
   Call-aware expression typing
   ------------------------------------------------------------ *)

Fixpoint check_arg_types_f
         (ats : list (option st_type)) (pts : list st_type) : bool :=
  match ats, pts with
  | nil, nil => true
  | Some a :: ats', p :: pts' =>
      type_compatible_dec a p && check_arg_types_f ats' pts'
  | _, _ => false
  end.

Fixpoint type_check_expr_f
         (allow_cycle : bool)
         (fenv : type_env_func) (env : type_env) (e : st_expr)
         {struct e} : option st_type :=
  match e with
  | E_LIT l => literal_type l
  | E_VAR x => lookup env x
  | E_ARRAY_ACCESS arr idx =>
      match type_check_expr_f allow_cycle fenv env arr with
      | Some (T_ARRAY elem_ty _ _) =>
          match type_check_expr_f allow_cycle fenv env idx with
          | Some T_INT => Some elem_ty
          | _ => None
          end
      | _ => None
      end
  | E_UNARY_OP op e1 =>
      match type_check_expr_f allow_cycle fenv env e1 with
      | Some ty => if is_valid_unary_dec op ty then Some ty else None
      | None => None
      end
  | E_BIN_OP op e1 e2 =>
      match type_check_expr_f allow_cycle fenv env e1,
            type_check_expr_f allow_cycle fenv env e2 with
      | Some ty1, Some ty2 =>
          match promote_type_dec ty1 ty2 with
          | Some ty3 => if is_valid_binary_dec op ty3 then Some ty3 else None
          | None => None
          end
      | _, _ => None
      end
  | E_COMP op e1 e2 =>
      match type_check_expr_f allow_cycle fenv env e1,
            type_check_expr_f allow_cycle fenv env e2 with
      | Some ty1, Some ty2 =>
          if type_comparable_dec ty1 ty2 then Some T_BOOL else None
      | _, _ => None
      end
  | E_AND e1 e2 =>
      match type_check_expr_f allow_cycle fenv env e1,
            type_check_expr_f allow_cycle fenv env e2 with
      | Some T_BOOL, Some T_BOOL => Some T_BOOL
      | _, _ => None
      end
  | E_OR e1 e2 =>
      match type_check_expr_f allow_cycle fenv env e1,
            type_check_expr_f allow_cycle fenv env e2 with
      | Some T_BOOL, Some T_BOOL => Some T_BOOL
      | _, _ => None
      end
  | E_XOR e1 e2 =>
      match type_check_expr_f allow_cycle fenv env e1,
            type_check_expr_f allow_cycle fenv env e2 with
      | Some T_BOOL, Some T_BOOL => Some T_BOOL
      | _, _ => None
      end
  | E_FUNC_CALL f args =>
      match f, args with
      | ID "CycleCounter", nil =>
          if allow_cycle then Some T_DINT else None
      | _, _ =>
          match lookup_function fenv f with
          | Some (param_types, return_type) =>
              if check_arg_types_f
                   (List.map (type_check_expr_f allow_cycle fenv env) args)
                   param_types
              then Some return_type
              else None
          | None => None
          end
      end
  | E_QUALITY_OP Q_STATUS args =>
      match args with
      | [e] =>
          match type_check_expr_f allow_cycle fenv env e with
          | Some ty => if is_quality_type ty then Some T_QUALITY else None
          | None => None
          end
      | _ => None
      end
  | E_QUALITY_OP Q_VALUE args =>
      match args with
      | [e] =>
          match type_check_expr_f allow_cycle fenv env e with
          | Some ty => if is_quality_type ty then Some (strip_quality ty) else None
          | None => None
          end
      | _ => None
      end
  | E_QUALITY_OP (Q_GOOD | Q_BAD) args =>
      match args with
      | [e] =>
          match type_check_expr_f allow_cycle fenv env e with
          | Some ty => if is_quality_type ty then Some T_BOOL else None
          | None => None
          end
      | _ => None
      end
  | E_QUALITY_OP Q_SET args =>
      match args with
      | [e1; e2] =>
          match type_check_expr_f allow_cycle fenv env e1,
                type_check_expr_f allow_cycle fenv env e2 with
          | Some ty1, Some T_QUALITY =>
              if is_quality_type ty1 then Some T_QUALITY else None
          | _, _ => None
          end
      | _ => None
      end
  | E_QUALITY_OP Q_WITH args =>
      match args with
      | [e1; e2] =>
          match type_check_expr_f allow_cycle fenv env e2 with
          | Some T_QUALITY =>
              match type_check_expr_f allow_cycle fenv env e1 with
              | Some ty1 =>
                  if is_plain_base_type ty1 then Some (add_quality ty1) else None
              | None => None
              end
          | _ => None
          end
      | _ => None
      end
  | E_QUALITY_OP Q_FORCE args =>
      match args with
      | [e1; e2; e3] =>
          match type_check_expr_f allow_cycle fenv env e1,
                type_check_expr_f allow_cycle fenv env e2,
                type_check_expr_f allow_cycle fenv env e3 with
          | Some ty1, Some val_ty, Some T_QUALITY =>
              if is_quality_type ty1 && type_eqb (strip_quality ty1) val_ty
              then Some ty1 else None
          | _, _, _ => None
          end
      | _ => None
      end
  end.

Definition writable_ok
           (writable : option (list ident)) (x : ident) : bool :=
  match writable with
  | None => true
  | Some ys => List.existsb (ident_eq x) ys
  end.

Fixpoint type_check_stmt_f
         (allow_cycle : bool)
         (writable : option (list ident))
         (fenv : type_env_func) (env : type_env) (s : st_stmt)
         {struct s} : bool :=
  match s with
  | S_ASSIGN x e =>
      writable_ok writable x &&
      match lookup env x, type_check_expr_f allow_cycle fenv env e with
      | Some lhs_ty, Some rhs_ty => type_compatible_dec rhs_ty lhs_ty
      | _, _ => false
      end
  | S_ARRAY_ASSIGN x idx e =>
      writable_ok writable x &&
      match lookup env x,
            type_check_expr_f allow_cycle fenv env idx,
            type_check_expr_f allow_cycle fenv env e with
      | Some (T_ARRAY elem_ty _ _), Some T_INT, Some val_ty =>
          type_compatible_dec elem_ty val_ty
      | _, _, _ => false
      end
  | S_IF cond then_stmts else_stmts =>
      let cond_ok :=
        match type_check_expr_f allow_cycle fenv env cond with
        | Some T_BOOL => true
        | _ => false
        end in
      let then_ok :=
        List.forallb (type_check_stmt_f allow_cycle writable fenv env) then_stmts in
      let else_ok :=
        match else_stmts with
        | Some stmts =>
            List.forallb (type_check_stmt_f allow_cycle writable fenv env) stmts
        | None => true
        end in
      cond_ok && then_ok && else_ok
  | S_CASE sel branches default =>
      let sel_ok :=
        match type_check_expr_f allow_cycle fenv env sel with
        | Some T_INT | Some T_DINT => true
        | _ => false
        end in
      let branches_ok :=
        List.forallb
          (fun ce =>
             match ce with
             | CASE_ELEM _ stmts =>
                 List.forallb
                   (type_check_stmt_f allow_cycle writable fenv env) stmts
             end) branches in
      let default_ok :=
        match default with
        | Some stmts =>
            List.forallb (type_check_stmt_f allow_cycle writable fenv env) stmts
        | None => true
        end in
      sel_ok && branches_ok && default_ok
  | S_FOR v start finish step body =>
      match writable with
      | Some _ => false
      | None =>
      let var_ok :=
        writable_ok writable v &&
        match lookup env v with
        | Some T_INT => true
        | _ => false
        end in
      let start_ok :=
        match type_check_expr_f allow_cycle fenv env start with
        | Some T_INT => true
        | _ => false
        end in
      let end_ok :=
        match type_check_expr_f allow_cycle fenv env finish with
        | Some T_INT => true
        | _ => false
        end in
      let step_ok :=
        match step with
        | Some e =>
            match type_check_expr_f allow_cycle fenv env e with
            | Some T_INT => true
            | _ => false
            end
        | None => true
        end in
      let body_ok :=
        List.forallb (type_check_stmt_f allow_cycle writable fenv env) body in
      var_ok && start_ok && end_ok && step_ok && body_ok
      end
  | S_WHILE cond body =>
      match writable with
      | Some _ => false
      | None =>
      let cond_ok :=
        match type_check_expr_f allow_cycle fenv env cond with
        | Some T_BOOL => true
        | _ => false
        end in
      cond_ok &&
      List.forallb (type_check_stmt_f allow_cycle writable fenv env) body
      end
  | S_REPEAT body cond =>
      match writable with
      | Some _ => false
      | None =>
      let body_ok :=
        List.forallb (type_check_stmt_f allow_cycle writable fenv env) body in
      let cond_ok :=
        match type_check_expr_f allow_cycle fenv env cond with
        | Some T_BOOL => true
        | _ => false
        end in
      body_ok && cond_ok
      end
  | S_FB_CALL inst params =>
      match writable with
      | Some _ => false
      | None =>
          match inst with
          | ID "PRINT" =>
              List.forallb
                (fun p =>
                   match type_check_expr_f allow_cycle fenv env (snd p) with
                   | Some ty => is_print_type ty
                   | None => false
                   end) params
          | _ => false
          end
      end
  | S_RETURN => true
  | S_EXIT =>
      (* EXIT is only meaningful inside a loop. Loops are not yet allowed
         in FUNCTION bodies, so reject EXIT there instead of emitting an
         unstructured BR. *)
      match writable with
      | Some _ => false
      | None => true
      end
  end.

Definition type_check_stmts_f
           (allow_cycle : bool)
           (writable : option (list ident))
           (fenv : type_env_func) (env : type_env)
           (stmts : list st_stmt) : bool :=
  List.forallb (type_check_stmt_f allow_cycle writable fenv env) stmts.

(* ------------------------------------------------------------
   FUNCTION purity
   ------------------------------------------------------------ *)

Fixpoint local_writable_names (decls : list st_var_decl) : list ident :=
  match decls with
  | nil => nil
  | d :: rest =>
      match d.(var_dir) with
      | D_LOCAL => d.(var_name) :: local_writable_names rest
      | _ => local_writable_names rest
      end
  end.

Definition function_decls_ok (decls : list st_var_decl) : bool :=
  List.forallb
    (fun d =>
       match d.(var_dir), d.(var_init) with
       | (D_INPUT | D_LOCAL), None => true
       | _, _ => false
       end) decls.

(* ------------------------------------------------------------
   Program preparation
   ------------------------------------------------------------ *)

Fixpoint find_var_decl (x : ident) (decls : list st_var_decl)
         : option st_var_decl :=
  match decls with
  | nil => None
  | d :: rest => if ident_eq d.(var_name) x then Some d else find_var_decl x rest
  end.

Definition make_result_decl (name : ident) (ty : st_type) : st_var_decl :=
  Build_st_var_decl name ty D_LOCAL Q_NONE None.

Definition prepare_function_pou (pou : st_pou) : option st_pou :=
  match pou with
  | P_FUNCTION name ty decls body =>
      match find_var_decl name decls with
      | Some d =>
          match d.(var_dir) with
          | D_LOCAL => if type_eqb d.(var_type) ty then Some pou else None
          | _ => None
          end
      | None =>
          Some (P_FUNCTION name ty
                           (decls ++ [make_result_decl name ty])
                           body)
      end
  | _ => Some pou
  end.

Fixpoint prepare_pous (pous : list st_pou) : option (list st_pou) :=
  match pous with
  | nil => Some nil
  | pou :: rest =>
      match prepare_function_pou pou, prepare_pous rest with
      | Some pou', Some rest' => Some (pou' :: rest')
      | _, _ => None
      end
  end.

Fixpoint find_program_entry (pous : list st_pou) : option ident :=
  match pous with
  | nil => None
  | P_PROGRAM name _ _ :: _ => Some name
  | _ :: rest => find_program_entry rest
  end.

Definition prepare_program (p : st_program) : option st_program :=
  match prepare_pous p.(pou_list) with
  | Some pous =>
      match find_program_entry pous with
      | Some entry =>
          Some {| global_vars := p.(global_vars);
                  pou_list := pous;
                  io_mapping := p.(io_mapping);
                  entry_point := entry |}
      | None => None
      end
  | None => None
  end.

Definition check_pou_full
           (globals : type_env) (fenv : type_env_func)
           (pou : st_pou) : bool :=
  let decls := pou_var_decls pou in
  let env := build_env_from_decls decls ++ globals in
  match pou with
  | P_PROGRAM _ _ body =>
      type_check_stmts_f true None fenv env body
  | P_FUNCTION name _ fdecls body =>
      function_decls_ok fdecls &&
      type_check_stmts_f false
                         (Some (name :: local_writable_names fdecls))
                         fenv env body
  | P_FUNCTION_BLOCK _ _ body =>
      type_check_stmts_f true None fenv env body
  end.

Definition check_program_full (p : st_program) : bool :=
  let globals := build_env_from_decls p.(global_vars) in
  let fenv := build_fenv_from_pous p.(pou_list) in
  match find_program_entry p.(pou_list) with
  | Some _ =>
      let no_reserved_cycle_counter :=
        negb
          (List.existsb
             (fun d => ident_eq d.(var_name) (ID "__veristc_cycle_counter"))
             p.(global_vars)) in
      no_reserved_cycle_counter &&
      List.forallb (check_pou_full globals fenv) p.(pou_list)
  | None => false
  end.
