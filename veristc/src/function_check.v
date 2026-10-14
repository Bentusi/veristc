(* ================================================================
   veristc/src/function_check.v
   Scoped type checking, diagnostics and preparation for IEC-like
   stateless FUNCTIONs.

   This module provides the engineering front-end for full FUNCTION
   support while keeping the existing verified core definitions
   untouched. It adds:
     - implicit function-result locals
     - local VAR initializers lowered to entry assignments
     - per-POU lexical scoping
     - call-aware expression typing
     - function purity and bounded-FOR checks
     - POU-level diagnostic messages
   ================================================================ *)

From Stdlib Require Import List.
From Stdlib Require Import Bool.
From Stdlib Require Import String.
From Stdlib Require Import ZArith.
Require Import veristc_spec.safest.
Require Import veristc_spec.st_semantics.
Require Import veristc_src.typechecker.
Local Open Scope Z_scope.
Local Open Scope string_scope.
Import ListNotations.

Definition ident_to_string (x : ident) : string :=
  match x with
  | ID s => s
  end.

Definition prepend_msg (prefix : string) (o : option string) : option string :=
  match o with
  | None => None
  | Some m => Some (String.append prefix m)
  end.

(* ------------------------------------------------------------
   WS-F：结构化诊断记录
   ------------------------------------------------------------
   旧实现把 POU 级错误压成一个自由文本 string，丢失了"这是哪个
   POU、哪一类错误、涉及哪个变量"的结构信息。这里引入诊断记录，
   每个错误携带 {pou_name; var_name; kind; msg} 四元组；对外的
   option string API（check_program_full_diag）改为由该记录渲染，
   渲染结果保留原有关键子串（如 "purity violation"），因此既有
   测试断言不回退。LOC 字段在解析阶段由 token 源位置填充；类型/
   纯性等检查阶段尚无 AST 内源位置，故渲染为 "-"（后续增量）。 *)

Inductive diag_kind : Type :=
  | DK_TYPE
  | DK_PURITY
  | DK_DECLARATIONS
  | DK_CONTROL
  | DK_FOR_BOUND
  | DK_RESERVED
  | DK_MISSING_ENTRY.

Record diagnostic : Type := {
  dg_pou  : ident;
  dg_var  : option ident;
  dg_kind : diag_kind;
  dg_msg  : string;
}.

Definition diag_kind_to_string (k : diag_kind) : string :=
  match k with
  | DK_TYPE => "type"
  | DK_PURITY => "purity"
  | DK_DECLARATIONS => "declaration"
  | DK_CONTROL => "control-flow"
  | DK_FOR_BOUND => "for-bound"
  | DK_RESERVED => "reserved-name"
  | DK_MISSING_ENTRY => "missing-entry"
  end.

Definition diag_var_string (o : option ident) : string :=
  match o with
  | Some v => ident_to_string v
  | None => "-"
  end.

Definition diagnostic_render (d : diagnostic) : string :=
  String.append "POU="
    (String.append (ident_to_string d.(dg_pou))
      (String.append " VAR="
        (String.append (diag_var_string d.(dg_var))
          (String.append " KIND="
            (String.append (diag_kind_to_string d.(dg_kind))
              (String.append " LOC=- MSG=" d.(dg_msg))))))).

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

Fixpoint type_check_stmt_f
         (allow_cycle : bool)
         (fenv : type_env_func) (env : type_env) (s : st_stmt)
         {struct s} : bool :=
  match s with
  | S_ASSIGN x e =>
      match lookup env x, type_check_expr_f allow_cycle fenv env e with
      | Some lhs_ty, Some rhs_ty => type_compatible_dec rhs_ty lhs_ty
      | _, _ => false
      end
  | S_ARRAY_ASSIGN x idx e =>
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
      let then_ok := List.forallb (type_check_stmt_f allow_cycle fenv env) then_stmts in
      let else_ok :=
        match else_stmts with
        | Some stmts => List.forallb (type_check_stmt_f allow_cycle fenv env) stmts
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
                 List.forallb (type_check_stmt_f allow_cycle fenv env) stmts
             end) branches in
      let default_ok :=
        match default with
        | Some stmts => List.forallb (type_check_stmt_f allow_cycle fenv env) stmts
        | None => true
        end in
      sel_ok && branches_ok && default_ok
  | S_FOR v start finish step body =>
      let var_ok :=
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
      let body_ok := List.forallb (type_check_stmt_f allow_cycle fenv env) body in
      var_ok && start_ok && end_ok && step_ok && body_ok
  | S_WHILE cond body =>
      let cond_ok :=
        match type_check_expr_f allow_cycle fenv env cond with
        | Some T_BOOL => true
        | _ => false
        end in
      cond_ok && List.forallb (type_check_stmt_f allow_cycle fenv env) body
  | S_REPEAT body cond =>
      let body_ok := List.forallb (type_check_stmt_f allow_cycle fenv env) body in
      let cond_ok :=
        match type_check_expr_f allow_cycle fenv env cond with
        | Some T_BOOL => true
        | _ => false
        end in
      body_ok && cond_ok
  | S_FB_CALL inst params =>
      match inst with
      | ID "PRINT" =>
          List.forallb
            (fun p =>
               match type_check_expr_f allow_cycle fenv env (snd p) with
               | Some ty => is_print_type ty
               | None => false
               end) params
      | _ =>
          (* 真实 FB 实例调用：inst 必须解析为 T_FB 实例，且实参表达式良型 *)
          match lookup env inst with
          | Some (T_FB _) =>
              List.forallb
                (fun p =>
                   match type_check_expr_f allow_cycle fenv env (snd p) with
                   | Some _ => true
                   | None => false
                   end) params
          | _ => false
          end
      end
  | S_RETURN => true
  | S_EXIT => true
  end.

Definition type_check_stmts_f
           (allow_cycle : bool)
           (fenv : type_env_func) (env : type_env)
           (stmts : list st_stmt) : bool :=
  List.forallb (type_check_stmt_f allow_cycle fenv env) stmts.

(* ------------------------------------------------------------
   FUNCTION restrictions: purity and currently supported control flow
   ------------------------------------------------------------ *)

Definition const_int_lit (e : st_expr) : option Z :=
  match e with
  | E_LIT (L_INT n) => Some n
  | _ => None
  end.

Definition is_const_int_lit (e : st_expr) : bool :=
  match const_int_lit e with
  | Some _ => true
  | None => false
  end.

Definition positive_const_step (step : option st_expr) : bool :=
  match step with
  | None => true
  | Some e =>
      match const_int_lit e with
      | Some k => Z.gtb k 0
      | None => false
      end
  end.

Definition constant_for_bounds
           (start finish : st_expr) (step : option st_expr) : bool :=
  is_const_int_lit start && is_const_int_lit finish && positive_const_step step.

Fixpoint function_control_ok (s : st_stmt) : bool :=
  match s with
  | S_ASSIGN _ _ => true
  | S_ARRAY_ASSIGN _ _ _ => true
  | S_IF _ then_body else_body =>
      List.forallb function_control_ok then_body &&
      match else_body with
      | Some body => List.forallb function_control_ok body
      | None => true
      end
  | S_CASE _ branches default =>
      List.forallb
        (fun ce =>
           match ce with
           | CASE_ELEM _ body => List.forallb function_control_ok body
           end) branches &&
      match default with
      | Some body => List.forallb function_control_ok body
      | None => true
      end
  | S_FOR _ _ _ _ body => List.forallb function_control_ok body
  | S_RETURN => true
  | S_WHILE _ _ => false
  | S_REPEAT _ _ => false
  | S_FB_CALL _ _ => false
  | S_EXIT => false
  end.

Definition function_control_stmts_ok (stmts : list st_stmt) : bool :=
  List.forallb function_control_ok stmts.

Fixpoint function_for_bounds_ok (s : st_stmt) : bool :=
  match s with
  | S_IF _ then_body else_body =>
      List.forallb function_for_bounds_ok then_body &&
      match else_body with
      | Some body => List.forallb function_for_bounds_ok body
      | None => true
      end
  | S_CASE _ branches default =>
      List.forallb
        (fun ce =>
           match ce with
           | CASE_ELEM _ body => List.forallb function_for_bounds_ok body
           end) branches &&
      match default with
      | Some body => List.forallb function_for_bounds_ok body
      | None => true
      end
  | S_FOR _ start finish step body =>
      constant_for_bounds start finish step &&
      List.forallb function_for_bounds_ok body
  | _ => true
  end.

Definition function_for_bounds_stmts_ok (stmts : list st_stmt) : bool :=
  List.forallb function_for_bounds_ok stmts.

Fixpoint function_writable_ok
         (writable : list ident) (s : st_stmt) : bool :=
  match s with
  | S_ASSIGN x _ => List.existsb (ident_eq x) writable
  | S_ARRAY_ASSIGN x _ _ => List.existsb (ident_eq x) writable
  | S_IF _ then_body else_body =>
      List.forallb (function_writable_ok writable) then_body &&
      match else_body with
      | Some body => List.forallb (function_writable_ok writable) body
      | None => true
      end
  | S_CASE _ branches default =>
      List.forallb
        (fun ce =>
           match ce with
           | CASE_ELEM _ body =>
               List.forallb (function_writable_ok writable) body
           end) branches &&
      match default with
      | Some body => List.forallb (function_writable_ok writable) body
      | None => true
      end
  | S_FOR v _ _ _ body =>
      List.existsb (ident_eq v) writable &&
      List.forallb (function_writable_ok writable) body
  | _ => true
  end.

Definition function_writable_stmts_ok
           (writable : list ident) (stmts : list st_stmt) : bool :=
  List.forallb (function_writable_ok writable) stmts.

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
       | D_INPUT, None => true
       | D_LOCAL, _ => true
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

Fixpoint clear_decl_inits (decls : list st_var_decl)
         : list st_var_decl :=
  match decls with
  | nil => nil
  | d :: rest =>
      Build_st_var_decl d.(var_name) d.(var_type) d.(var_dir)
                        d.(var_qual) None :: clear_decl_inits rest
  end.

Fixpoint local_init_stmts (decls : list st_var_decl) : list st_stmt :=
  match decls with
  | nil => nil
  | d :: rest =>
      match d.(var_dir), d.(var_init) with
      | D_LOCAL, Some lit =>
          S_ASSIGN d.(var_name) (E_LIT lit) :: local_init_stmts rest
      | _, _ => local_init_stmts rest
      end
  end.

(* ------------------------------------------------------------
   FB 实例展开 (P1 原生功能块: 逻辑一份 + 每实例数据分离)

   将实例声明 `inst : T_FB fbname` 展开为其可写字段的扁平全局
   `inst_<field>`（声明序），供下游类型检查/desugar/codegen 作为
   真实 VAR_GLOBAL 处理。标记声明 inst (T_FB) 保留，供 codegen
   读取 inst→fbname 链接并计算 self 基址。
   ------------------------------------------------------------ *)

Definition fb_writable_pair (d : st_var_decl) : option (ident * st_type) :=
  match d.(var_dir) with
  | D_OUTPUT | D_LOCAL => Some (d.(var_name), d.(var_type))
  | _ => None
  end.

Fixpoint collect_writable (ds : list st_var_decl) : list (ident * st_type) :=
  match ds with
  | nil => nil
  | d :: rest =>
      match d.(var_dir) with
      | D_INPUT => collect_writable rest
      | _ => (d.(var_name), d.(var_type)) :: collect_writable rest
      end
  end.

Fixpoint fb_writable_fields (fbname : string) (pous : list st_pou)
         : list (ident * st_type) :=
  match pous with
  | nil => nil
  | P_FUNCTION_BLOCK (ID nm) decls _ :: rest =>
      if String.eqb nm fbname
      then collect_writable decls
      else fb_writable_fields fbname rest
  | _ :: rest => fb_writable_fields fbname rest
  end.

Definition ident_string (x : ident) : string :=
  match x with ID s => s end.

Definition inst_field_global (inst_name : string) (p : ident * st_type)
         : st_var_decl :=
  match p with
  | (ID fname, fty) =>
      Build_st_var_decl (ID (inst_name ++ "_" ++ fname)) fty D_GLOBAL Q_NONE None
  end.

Fixpoint expand_instances (pous : list st_pou) (ds : list st_var_decl)
         : list st_var_decl :=
  match ds with
  | nil => nil
  | d :: rest =>
      match d.(var_type) with
      | T_FB fbname =>
          d ::
          List.map (inst_field_global (ident_string d.(var_name)))
                   (fb_writable_fields fbname pous)
          ++ expand_instances pous rest
      | _ => d :: expand_instances pous rest
      end
  end.

Definition prepare_function_pou (pou : st_pou) : option st_pou :=
  match pou with
  | P_FUNCTION name ty decls body =>
      if negb (function_decls_ok decls) then
        None
      else
        match find_var_decl name decls with
        | Some d =>
            match d.(var_dir) with
            | D_LOCAL =>
                if type_eqb d.(var_type) ty then
                  Some (P_FUNCTION name ty
                                   (clear_decl_inits decls)
                                   (List.app (local_init_stmts decls) body))
                else
                  None
            | _ => None
            end
        | None =>
            let result_decl := make_result_decl name ty in
            Some (P_FUNCTION name ty
                             (clear_decl_inits (List.app decls [result_decl]))
                             (List.app (local_init_stmts decls) body))
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
          Some {| global_vars := expand_instances pous p.(global_vars);
                  pou_list := pous;
                  io_mapping := p.(io_mapping);
                  entry_point := entry |}
      | None => None
      end
  | None => None
  end.

Definition check_pou_full_struct
           (globals : type_env) (fenv : type_env_func)
           (pou : st_pou) : option diagnostic :=
  let decls := pou_var_decls pou in
  let env := List.app (build_env_from_decls decls) globals in
  match pou with
  | P_PROGRAM name _ body =>
      if type_check_stmts_f true fenv env body then
        None
      else
        Some {| dg_pou := name; dg_var := None;
                dg_kind := DK_TYPE; dg_msg := "type error" |}
  | P_FUNCTION name _ fdecls body =>
      if negb (function_decls_ok fdecls) then
        Some {| dg_pou := name; dg_var := None; dg_kind := DK_DECLARATIONS;
                dg_msg :=
                  "declarations may only use VAR_INPUT and local VAR" |}
      else if negb (function_control_stmts_ok body) then
        Some {| dg_pou := name; dg_var := None; dg_kind := DK_CONTROL;
                dg_msg :=
                  "unsupported control flow (WHILE/REPEAT/EXIT/FB calls are not allowed in FUNCTION yet)" |}
      else if negb (function_for_bounds_stmts_ok body) then
        Some {| dg_pou := name; dg_var := None; dg_kind := DK_FOR_BOUND;
                dg_msg :=
                  "FOR inside FUNCTION currently requires constant INT bounds and positive constant step" |}
      else if negb (function_writable_stmts_ok
                      (name :: local_writable_names fdecls) body) then
        Some {| dg_pou := name; dg_var := None; dg_kind := DK_PURITY;
                dg_msg :=
                  "purity violation (only local VAR and function result may be assigned)" |}
      else if negb (type_check_stmts_f false fenv env body) then
        Some {| dg_pou := name; dg_var := None; dg_kind := DK_TYPE;
                dg_msg := "type error" |}
      else
        None
  | P_FUNCTION_BLOCK name _ body =>
      if type_check_stmts_f true fenv env body then
        None
      else
        Some {| dg_pou := name; dg_var := None; dg_kind := DK_TYPE;
                dg_msg := "type error" |}
  end.

Fixpoint check_pous_full_struct
         (globals : type_env) (fenv : type_env_func)
         (pous : list st_pou) : option diagnostic :=
  match pous with
  | nil => None
  | pou :: rest =>
      match check_pou_full_struct globals fenv pou with
      | Some d => Some d
      | None => check_pous_full_struct globals fenv rest
      end
  end.

Definition uses_reserved_cycle_counter (globals : list st_var_decl) : bool :=
  List.existsb
    (fun d => ident_eq d.(var_name) (ID "__veristc_cycle_counter"))
    globals.

Definition check_program_full_diag_struct (p : st_program) : option diagnostic :=
  if uses_reserved_cycle_counter p.(global_vars) then
    Some {| dg_pou := ID ""; dg_var := None; dg_kind := DK_RESERVED;
            dg_msg :=
              "global variable uses reserved name __veristc_cycle_counter" |}
  else
    match find_program_entry p.(pou_list) with
    | None =>
        Some {| dg_pou := ID ""; dg_var := None; dg_kind := DK_MISSING_ENTRY;
                dg_msg := "missing PROGRAM entry point" |}
    | Some _ =>
        let globals := build_env_from_decls p.(global_vars) in
        let fenv := build_fenv_from_pous p.(pou_list) in
        check_pous_full_struct globals fenv p.(pou_list)
    end.

Definition check_pou_full_diag
           (globals : type_env) (fenv : type_env_func)
           (pou : st_pou) : option string :=
  option_map diagnostic_render (check_pou_full_struct globals fenv pou).

Definition check_pous_full_diag
           (globals : type_env) (fenv : type_env_func)
           (pous : list st_pou) : option string :=
  option_map diagnostic_render (check_pous_full_struct globals fenv pous).

Definition check_program_full_diag (p : st_program) : option string :=
  option_map diagnostic_render (check_program_full_diag_struct p).

Definition check_program_full (p : st_program) : bool :=
  match check_program_full_diag p with
  | None => true
  | Some _ => false
  end.
