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
  | DK_MISSING_ENTRY
  | DK_ALIAS
  | DK_ACCESS.

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
  | DK_ALIAS => "alias"
  | DK_ACCESS => "access"
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
   `inst#field`（声明序），供下游类型检查/desugar/codegen 作为
   真实 VAR_GLOBAL 处理。标记声明 inst (T_FB) 保留，供 codegen
   读取 inst→fbname 链接并计算 self 基址。

   连接符用 safest.derived_field_sep（`#`，源语言不可书写），
   派生名因此不会与用户名字空间相撞；对外的限定访问 `inst.field`
   由 parser 融合成同一个内部名。
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
      (* v1.5：VAR_IN_OUT 是调用方存储的别名，不分配实例副本，
         故既非"可写字段"也非 FB_DATA 成员（与 desugar 的
         cfunc_locals 分组保持一致，二者共同决定 self 相对偏移）。 *)
      | D_INPUT | D_IN_OUT => collect_writable rest
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
      Build_st_var_decl (ID (inst_name ++ derived_field_sep ++ fname)) fty D_GLOBAL Q_NONE None
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

(* ------------------------------------------------------------
   v1.5 VAR_IN_OUT 逐引用别名：调用点检查

   IN_OUT 端口编译为"指向调用方存储的地址"实参（codegen 用
   I32_LOAD_PTR / I32_STORE_PTR 解引用），别名要求被引用对象有
   稳定、可取地址的存储位置，因此其绑定形状比 INPUT/OUTPUT 更强。
   本层把这些要求显式成文，违规给出可定位的诊断（codegen 由此
   只需处理已验证的形状）：
     1) 实参名必须是该 FB 声明中的端口（INPUT/OUTPUT/IN_OUT），
        不允许拼错或绕过声明传参；
     2) 每个已声明的 IN_OUT 端口都必须被绑定（无初值可拷贝，
        不绑定即没有别名目标）；
     3) IN_OUT 实参必须是简单变量名，且解析到一个全局
        （VAR_GLOBAL 或实例展开出的 inst#field）；不能是调用方
        的局部变量、常量或表达式。例外：调用方自身的 IN_OUT 端口
        可以透传（其形参槽已持有地址）。
     4) 实参类型与端口类型完全相同（别名不做隐式转换），且宽度
        为 32 位 —— 解引用指令按 4 字节定宽读写。
   ------------------------------------------------------------ *)

Definition alias_port_width_ok (ty : st_type) : bool :=
  Z.eqb (type_width ty) 32.

Definition alias_type_match (port_ty actual_ty : st_type) : bool :=
  andb (type_eqb actual_ty port_ty) (alias_port_width_ok port_ty).

Fixpoint find_fb_decls (fbname : string) (pous : list st_pou)
         : option (list st_var_decl) :=
  match pous with
  | nil => None
  | P_FUNCTION_BLOCK (ID nm) decls _ :: rest =>
      if String.eqb nm fbname then Some decls else find_fb_decls fbname rest
  | _ :: rest => find_fb_decls fbname rest
  end.

Fixpoint in_out_port_decls (ds : list st_var_decl) : list st_var_decl :=
  match ds with
  | nil => nil
  | d :: rest =>
      if match d.(var_dir) with D_IN_OUT => true | _ => false end
      then d :: in_out_port_decls rest
      else in_out_port_decls rest
  end.

Fixpoint port_names (ds : list st_var_decl) : list ident :=
  match ds with
  | nil => nil
  | d :: rest =>
      if match d.(var_dir) with
         | D_INPUT | D_OUTPUT | D_IN_OUT => true
         | _ => false
         end
      then d.(var_name) :: port_names rest
      else port_names rest
  end.

Fixpoint lookup_bound_expr (params : list (ident * st_expr)) (nm : ident)
         : option st_expr :=
  match params with
  | nil => None
  | (k, e) :: rest => if ident_eq k nm then Some e else lookup_bound_expr rest nm
  end.

Definition make_alias_diag (pou_name : ident) (v : ident) (msg : string)
           : diagnostic :=
  {| dg_pou := pou_name; dg_var := Some v; dg_kind := DK_ALIAS;
     dg_msg := msg |}.

Fixpoint first_alias_diag (ds : list (option diagnostic))
         : option diagnostic :=
  match ds with
  | nil => None
  | Some d :: _ => Some d
  | None :: rest => first_alias_diag rest
  end.

(* 单个 IN_OUT 端口绑定的检查；None = 合法 *)
Definition check_one_alias_port
           (pou_name : ident) (caller_decls : list st_var_decl)
           (globals : type_env) (ports : list ident)
           (d : st_var_decl)
           (params : list (ident * st_expr)) : option diagnostic :=
  let nm := d.(var_name) in
  if negb (List.existsb (ident_eq nm) ports) then
    Some (make_alias_diag pou_name nm
            "VAR_IN_OUT port is not declared by the callee")
  else
    match lookup_bound_expr params nm with
    | None =>
        Some (make_alias_diag pou_name nm
                "VAR_IN_OUT port must be bound to a global variable")
    | Some (E_VAR g) =>
        (* 别名透传：调用方自身的 IN_OUT 端口也是合法目标（其形参槽
           本就持有地址，codegen 直接 LOCAL_GET 转发，无需静态地址）。 *)
        match lookup (build_env_from_decls (in_out_port_decls caller_decls)) g with
        | Some chain_ty =>
            if alias_type_match d.(var_type) chain_ty then
              None
            else
              Some (make_alias_diag pou_name g
                      "VAR_IN_OUT forwarding needs identical 32-bit type")
        | None =>
            if List.existsb (fun dd => ident_eq dd.(var_name) g) caller_decls then
              Some (make_alias_diag pou_name g
                      "VAR_IN_OUT alias target must be global, not a local of the caller")
            else
              match lookup globals g with
              | None =>
                  Some (make_alias_diag pou_name g
                          "VAR_IN_OUT alias target is not a global variable")
              | Some actual_ty =>
                  if alias_type_match d.(var_type) actual_ty then
                    None
                  else
                    Some (make_alias_diag pou_name g
                            "VAR_IN_OUT alias target needs identical 32-bit type")
              end
        end
    | Some _ =>
        Some (make_alias_diag pou_name nm
                "VAR_IN_OUT actual must be a simple global variable name")
    end.

Fixpoint check_alias_ports
           (pou_name : ident) (caller_decls : list st_var_decl)
           (globals : type_env) (ports : list ident)
           (iodecls : list st_var_decl)
           (params : list (ident * st_expr)) : option diagnostic :=
  match iodecls with
  | nil => None
  | d :: rest =>
      match check_one_alias_port pou_name caller_decls globals ports d params with
      | Some dg => Some dg
      | None => check_alias_ports pou_name caller_decls globals ports rest params
      end
  end.

Definition check_fb_call_aliases
           (pou_name : ident) (caller_decls : list st_var_decl)
           (pous : list st_pou) (globals : type_env)
           (inst : ident) (params : list (ident * st_expr))
           : option diagnostic :=
  match lookup (List.app (build_env_from_decls caller_decls) globals) inst with
  | Some (T_FB fbname) =>
      match find_fb_decls fbname pous with
      | None => None (* FB 定义缺失由既有类型检查报错，不在此重复 *)
      | Some fdecls =>
          let ports := port_names fdecls in
          let unknown :=
            first_alias_diag
              (List.map
                 (fun pe =>
                    if List.existsb (ident_eq (fst pe)) ports then
                      None
                    else
                      Some (make_alias_diag pou_name (fst pe)
                              "call binds a name that is not a declared port"))
                 params) in
          match unknown with
          | Some dg => Some dg
          | None =>
              check_alias_ports pou_name caller_decls globals ports
                (in_out_port_decls fdecls) params
          end
      end
  | _ => None
  end.

Fixpoint check_alias_in_stmt
           (pou_name : ident) (caller_decls : list st_var_decl)
           (pous : list st_pou) (globals : type_env)
           (s : st_stmt) : option diagnostic :=
  match s with
  | S_FB_CALL inst params =>
      if ident_eq inst (ID "PRINT") then None
      else check_fb_call_aliases pou_name caller_decls pous globals inst params
  | S_IF _ then_body else_body =>
      first_alias_diag
        (List.map (check_alias_in_stmt pou_name caller_decls pous globals)
                  then_body ++
         match else_body with
         | Some b => List.map (check_alias_in_stmt pou_name caller_decls pous globals) b
         | None => nil
         end)
  | S_CASE _ branches default =>
      first_alias_diag
        (List.concat
           (List.map
              (fun ce =>
                 match ce with
                 | CASE_ELEM _ body =>
                     List.map (check_alias_in_stmt pou_name caller_decls pous globals) body
                 end) branches) ++
         match default with
         | Some b => List.map (check_alias_in_stmt pou_name caller_decls pous globals) b
         | None => nil
         end)
  | S_FOR _ _ _ _ body =>
      first_alias_diag
        (List.map (check_alias_in_stmt pou_name caller_decls pous globals) body)
  | S_WHILE _ body =>
      first_alias_diag
        (List.map (check_alias_in_stmt pou_name caller_decls pous globals) body)
  | S_REPEAT body _ =>
      first_alias_diag
        (List.map (check_alias_in_stmt pou_name caller_decls pous globals) body)
  | _ => None
  end.

Definition check_pou_aliases
           (pous : list st_pou) (globals : type_env)
           (pou : st_pou) : option diagnostic :=
  let name := match pou with
              | P_PROGRAM n _ _ => n
              | P_FUNCTION n _ _ _ => n
              | P_FUNCTION_BLOCK n _ _ => n
              end in
  let decls := pou_var_decls pou in
  let body := match pou with
              | P_PROGRAM _ _ b => b
              | P_FUNCTION _ _ _ b => b
              | P_FUNCTION_BLOCK _ _ b => b
              end in
  first_alias_diag
    (List.map (check_alias_in_stmt name decls pous globals) body).

Definition check_program_aliases
           (pous : list st_pou) (globals : type_env)
           : option diagnostic :=
  first_alias_diag (List.map (check_pou_aliases pous globals) pous).

(* ------------------------------------------------------------
   v1.5.1 限定访问的方向规则（封装）

   `inst.field` 由 parser 融合成派生名 inst#field，而该名字正是
   expand_instances 生成的扁平全局名。也就是说：只要类型对得上，任何
   POU 都能读写任何实例的任何被展开字段 —— 这在安全级代码里是不可
   接受的隐式共享状态。本层把可见性显式成文：
     1) FB 的内部 `VAR`（跨周期持久状态）对外不可见：既不能读也不能写；
     2) 实例的 `VAR_OUTPUT` 对调用方只读：写输出等于绕过 FB 算法直接
        篡改其结果；
     3) `VAR_INPUT` / `VAR_IN_OUT` 根本不生成派生名（INPUT 经调用实参、
        IN_OUT 经指针形参槽传递），引用它们自然按未声明名字被类型检查
        拒绝，本层无需重复。
   判定依据是一张由「实例声明 × FB 声明」重新派生的方向表：与
   expand_instances 用同一连接符 safest.derived_field_sep 拼名，因此不
   解析字符串、也不可能被用户伪造出的名字骗到。表里查不到的名字即非
   派生名（普通全局），不受本规则约束。
   ------------------------------------------------------------ *)

Fixpoint collect_field_dirs (ds : list st_var_decl)
         : list (ident * var_direction) :=
  match ds with
  | nil => nil
  | d :: rest =>
      match d.(var_dir) with
      | D_INPUT | D_IN_OUT => collect_field_dirs rest
      | _ => (d.(var_name), d.(var_dir)) :: collect_field_dirs rest
      end
  end.

Fixpoint fb_field_dirs (fbname : string) (pous : list st_pou)
         : list (ident * var_direction) :=
  match pous with
  | nil => nil
  | P_FUNCTION_BLOCK (ID nm) decls _ :: rest =>
      if String.eqb nm fbname then collect_field_dirs decls
      else fb_field_dirs fbname rest
  | _ :: rest => fb_field_dirs fbname rest
  end.

(* 派生名 inst#field ↦ 该字段在 FB 声明中的方向 *)
Fixpoint build_field_dir_map (pous : list st_pou) (ds : list st_var_decl)
         : list (ident * var_direction) :=
  match ds with
  | nil => nil
  | d :: rest =>
      match d.(var_type) with
      | T_FB fbname =>
          List.map
            (fun p =>
               (ID (ident_string d.(var_name) ++ derived_field_sep
                      ++ ident_string (fst p)), snd p))
            (fb_field_dirs fbname pous)
          ++ build_field_dir_map pous rest
      | _ => build_field_dir_map pous rest
      end
  end.

Fixpoint lookup_field_dir (m : list (ident * var_direction)) (n : ident)
         : option var_direction :=
  match m with
  | nil => None
  | (k, dir) :: rest =>
      if ident_eq k n then Some dir else lookup_field_dir rest n
  end.

Definition make_access_diag (pou_name : ident) (v : ident) (msg : string)
           : diagnostic :=
  {| dg_pou := pou_name; dg_var := Some v; dg_kind := DK_ACCESS;
     dg_msg := msg |}.

(* 内部 VAR 对任何外部 POU 都不可见；OUTPUT 只读不可写。 *)
Definition field_read_forbidden (dir : var_direction) : bool :=
  match dir with D_LOCAL => true | _ => false end.

Definition field_write_forbidden (dir : var_direction) : bool :=
  match dir with D_LOCAL | D_OUTPUT => true | _ => false end.

Fixpoint expr_access_diag (pou_name : ident)
           (m : list (ident * var_direction)) (e : st_expr)
           : option diagnostic :=
  match e with
  | E_VAR n =>
      match lookup_field_dir m n with
      | Some dir =>
          if field_read_forbidden dir then
            Some (make_access_diag pou_name n
                    "instance internal state (VAR) is not visible outside its FUNCTION_BLOCK")
          else None
      | None => None
      end
  | E_ARRAY_ACCESS a b =>
      first_alias_diag (expr_access_diag pou_name m a
                           :: expr_access_diag pou_name m b :: nil)
  | E_UNARY_OP _ a => expr_access_diag pou_name m a
  | E_BIN_OP _ a b => first_alias_diag (expr_access_diag pou_name m a
                                          :: expr_access_diag pou_name m b :: nil)
  | E_COMP _ a b => first_alias_diag (expr_access_diag pou_name m a
                                        :: expr_access_diag pou_name m b :: nil)
  | E_AND a b => first_alias_diag (expr_access_diag pou_name m a
                                     :: expr_access_diag pou_name m b :: nil)
  | E_OR a b => first_alias_diag (expr_access_diag pou_name m a
                                    :: expr_access_diag pou_name m b :: nil)
  | E_XOR a b => first_alias_diag (expr_access_diag pou_name m a
                                     :: expr_access_diag pou_name m b :: nil)
  | E_FUNC_CALL _ args =>
      first_alias_diag (List.map (expr_access_diag pou_name m) args)
  | E_QUALITY_OP _ args =>
      first_alias_diag (List.map (expr_access_diag pou_name m) args)
  | _ => None
  end.

(* 只在 st_stmt 上递归（与本文件 check_alias_in_stmt 同法）：语句序列一律
   用 List.map + first_alias_diag 就地展开，避免与 list st_stmt 互相递归
   导致 guard checker 无法判定递减。 *)
Fixpoint stmt_access_diag (pou_name : ident)
           (m : list (ident * var_direction)) (s : st_stmt)
           : option diagnostic :=
  match s with
  | S_ASSIGN tgt rhs =>
      match lookup_field_dir m tgt with
      | Some dir =>
          if field_write_forbidden dir then
            Some (make_access_diag pou_name tgt
                    "instance field is read-only (or invisible) outside its FUNCTION_BLOCK")
          else expr_access_diag pou_name m rhs
      | None => expr_access_diag pou_name m rhs
      end
  | S_ARRAY_ASSIGN _ idx rhs =>
      first_alias_diag (expr_access_diag pou_name m idx
                           :: expr_access_diag pou_name m rhs :: nil)
  | S_IF cond then_body else_body =>
      first_alias_diag
        ((expr_access_diag pou_name m cond ::
            first_alias_diag (List.map (stmt_access_diag pou_name m) then_body) :: nil) ++
         match else_body with
         | Some b => first_alias_diag (List.map (stmt_access_diag pou_name m) b) :: nil
         | None => nil
         end)
  | S_CASE cond branches default =>
      first_alias_diag
        ((expr_access_diag pou_name m cond :: nil) ++
         List.map
           (fun ce =>
              match ce with
              | CASE_ELEM _ body =>
                  first_alias_diag (List.map (stmt_access_diag pou_name m) body)
              end)
           branches ++
         match default with
         | Some b => first_alias_diag (List.map (stmt_access_diag pou_name m) b) :: nil
         | None => nil
         end)
  | S_FOR _ from to step body =>
      first_alias_diag
        (expr_access_diag pou_name m from ::
           expr_access_diag pou_name m to ::
           match step with
           | Some se => expr_access_diag pou_name m se :: nil
           | None => nil
           end ++
           first_alias_diag (List.map (stmt_access_diag pou_name m) body) :: nil)
  | S_WHILE cond body =>
      first_alias_diag
        (expr_access_diag pou_name m cond ::
           first_alias_diag (List.map (stmt_access_diag pou_name m) body) :: nil)
  | S_REPEAT body cond =>
      first_alias_diag
        (first_alias_diag (List.map (stmt_access_diag pou_name m) body) ::
           expr_access_diag pou_name m cond :: nil)
  | S_FB_CALL _ params =>
      first_alias_diag
        (List.map (fun p => expr_access_diag pou_name m (snd p)) params)
  | _ => None
  end.

Definition check_pou_access
           (pous : list st_pou) (dir_map : list (ident * var_direction))
           (pou : st_pou) : option diagnostic :=
  let name := match pou with
              | P_PROGRAM n _ _ => n
              | P_FUNCTION n _ _ _ => n
              | P_FUNCTION_BLOCK n _ _ => n
              end in
  let body := match pou with
              | P_PROGRAM _ _ b => b
              | P_FUNCTION _ _ _ b => b
              | P_FUNCTION_BLOCK _ _ b => b
              end in
  first_alias_diag (List.map (stmt_access_diag name dir_map) body).

Definition check_program_access
           (pous : list st_pou) (gdecls : list st_var_decl)
           : option diagnostic :=
  let dir_map := build_field_dir_map pous gdecls in
  first_alias_diag (List.map (check_pou_access pous dir_map) pous).

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

(* ------------------------------------------------------------
   IOMAP 条目必须绑定到已声明的全局变量
   ------------------------------------------------------------
   映射条目的内存偏移按名字从 build_global_env 解析
   （global_codegen.resolve_io_map）。名字不在全局声明里 ⇒ 地址无处可取，
   物理通道和程序变量各走各的，运行期表现为「输入读不到、输出写不出」
   且全程不报错，因此在编译期就拒绝。 *)
Fixpoint check_io_mapping_all (globals : type_env)
                              (entries : list io_entry) : list diagnostic :=
  match entries with
  | nil => nil
  | e :: rest =>
      let bad :=
        match lookup globals e.(io_var_name) with
        | None =>
            [ {| dg_pou := ID "";
                 dg_var := Some e.(io_var_name);
                 dg_kind := DK_DECLARATIONS;
                 dg_msg :=
                   "IOMAP entry binds an undeclared global variable" |} ]
        | Some _ => nil
        end in
      List.app bad (check_io_mapping_all globals rest)
  end.

Definition check_io_mapping (globals : type_env)
                             (entries : list io_entry) : option diagnostic :=
  match check_io_mapping_all globals entries with
  | nil => None
  | d :: _ => Some d
  end.

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
        match check_pous_full_struct globals fenv p.(pou_list) with
        | Some d => Some d
        | None =>
            match check_program_aliases p.(pou_list) globals with
            | Some d => Some d
            | None =>
                match check_program_access p.(pou_list) p.(global_vars) with
                | Some d => Some d
                | None => check_io_mapping globals p.(io_mapping)
                end
            end
        end
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

(* ================================================================
   Phase 6 / G0 产出物 1 —— 全量诊断与机器可读行投影
   ------------------------------------------------------------
   既有 API（check_program_full_diag 及其渲染器）只返回**第一条**诊断，
   并把 dg_pou/dg_var 压进一行文本；IDE 需要「一次编译看到全部错误」和
   结构化字段。本层是纯新增的并行实现：
     * 收集顺序与单条版逐字一致 ⇒ 结果表首项恒等于旧版那条诊断；
     * 不修改任何既有定义，文本输出与 KIND= 词汇不受影响。
   本文件在证明锥之外（compiler_correctness.v 不依赖它），无定理影响。
   语句级/端口级 LOC 仍为 "-"（D3：推到 G2，届时需给 st_stmt/st_expr
   加位置字段，那属锥内改动）。 *)

Fixpoint cat_diags (ds : list (option diagnostic)) : list diagnostic :=
  match ds with
  | nil => nil
  | Some d :: rest => d :: cat_diags rest
  | None :: rest => cat_diags rest
  end.

(* ---- VAR_IN_OUT 别名检查的全量版 ---- *)

Definition check_one_alias_port_all
           (pou_name : ident) (caller_decls : list st_var_decl)
           (globals : type_env) (ports : list ident)
           (d : st_var_decl)
           (params : list (ident * st_expr)) : list diagnostic :=
  let nm := d.(var_name) in
  if negb (List.existsb (ident_eq nm) ports) then
    [make_alias_diag pou_name nm
       "VAR_IN_OUT port is not declared by the callee"]
  else
    match lookup_bound_expr params nm with
    | None =>
        [make_alias_diag pou_name nm
           "VAR_IN_OUT port must be bound to a global variable"]
    | Some (E_VAR g) =>
        match lookup (build_env_from_decls (in_out_port_decls caller_decls)) g with
        | Some chain_ty =>
            if alias_type_match d.(var_type) chain_ty then
              nil
            else
              [make_alias_diag pou_name g
                 "VAR_IN_OUT forwarding needs identical 32-bit type"]
        | None =>
            if List.existsb (fun dd => ident_eq dd.(var_name) g) caller_decls then
              [make_alias_diag pou_name g
                 "VAR_IN_OUT alias target must be global, not a local of the caller"]
            else
              match lookup globals g with
              | None =>
                  [make_alias_diag pou_name g
                     "VAR_IN_OUT alias target is not a global variable"]
              | Some actual_ty =>
                  if alias_type_match d.(var_type) actual_ty then
                    nil
                  else
                    [make_alias_diag pou_name g
                       "VAR_IN_OUT alias target needs identical 32-bit type"]
              end
        end
    | Some _ =>
        [make_alias_diag pou_name nm
           "VAR_IN_OUT actual must be a simple global variable name"]
    end.

Fixpoint check_alias_ports_all
           (pou_name : ident) (caller_decls : list st_var_decl)
           (globals : type_env) (ports : list ident)
           (iodecls : list st_var_decl)
           (params : list (ident * st_expr)) : list diagnostic :=
  match iodecls with
  | nil => nil
  | d :: rest =>
      List.app
        (check_one_alias_port_all pou_name caller_decls globals ports d params)
        (check_alias_ports_all pou_name caller_decls globals ports rest params)
  end.

Definition check_fb_call_aliases_all
           (pou_name : ident) (caller_decls : list st_var_decl)
           (pous : list st_pou) (globals : type_env)
           (inst : ident) (params : list (ident * st_expr))
           : list diagnostic :=
  match lookup (List.app (build_env_from_decls caller_decls) globals) inst with
  | Some (T_FB fbname) =>
      match find_fb_decls fbname pous with
      | None => nil (* FB 定义缺失由既有类型检查报错，不在此重复 *)
      | Some fdecls =>
          let ports := port_names fdecls in
          List.app
            (cat_diags
               (List.map
                  (fun pe =>
                     if List.existsb (ident_eq (fst pe)) ports then
                       None
                     else
                       Some (make_alias_diag pou_name (fst pe)
                               "call binds a name that is not a declared port"))
                  params))
            (check_alias_ports_all pou_name caller_decls globals ports
               (in_out_port_decls fdecls) params)
      end
  | _ => nil
  end.

Fixpoint check_alias_in_stmt_all
           (pou_name : ident) (caller_decls : list st_var_decl)
           (pous : list st_pou) (globals : type_env)
           (s : st_stmt) : list diagnostic :=
  match s with
  | S_FB_CALL inst params =>
      if ident_eq inst (ID "PRINT") then
        nil
      else
        check_fb_call_aliases_all pou_name caller_decls pous globals inst params
  | S_IF _ then_body else_body =>
      List.concat
        (List.map (check_alias_in_stmt_all pou_name caller_decls pous globals)
                  then_body ++
         match else_body with
         | Some b => List.map (check_alias_in_stmt_all pou_name caller_decls pous globals) b
         | None => nil
         end)
  | S_CASE _ branches default =>
      List.concat
        (List.concat
           (List.map
              (fun ce =>
                 match ce with
                 | CASE_ELEM _ body =>
                     List.map (check_alias_in_stmt_all pou_name caller_decls pous globals) body
                 end) branches) ++
         match default with
         | Some b => List.map (check_alias_in_stmt_all pou_name caller_decls pous globals) b
         | None => nil
         end)
  | S_FOR _ _ _ _ body =>
      List.concat
        (List.map (check_alias_in_stmt_all pou_name caller_decls pous globals) body)
  | S_WHILE _ body =>
      List.concat
        (List.map (check_alias_in_stmt_all pou_name caller_decls pous globals) body)
  | S_REPEAT body _ =>
      List.concat
        (List.map (check_alias_in_stmt_all pou_name caller_decls pous globals) body)
  | _ => nil
  end.

Definition check_pou_aliases_all
           (pous : list st_pou) (globals : type_env)
           (pou : st_pou) : list diagnostic :=
  let name := match pou with
              | P_PROGRAM n _ _ => n
              | P_FUNCTION n _ _ _ => n
              | P_FUNCTION_BLOCK n _ _ => n
              end in
  let decls := pou_var_decls pou in
  let body := match pou with
              | P_PROGRAM _ _ b => b
              | P_FUNCTION _ _ _ b => b
              | P_FUNCTION_BLOCK _ _ b => b
              end in
  List.concat (List.map (check_alias_in_stmt_all name decls pous globals) body).

Definition check_program_aliases_all
           (pous : list st_pou) (globals : type_env) : list diagnostic :=
  List.concat (List.map (check_pou_aliases_all pous globals) pous).

(* ---- 限定访问封装检查的全量版 ---- *)

Fixpoint expr_access_all (pou_name : ident)
           (m : list (ident * var_direction)) (e : st_expr) : list diagnostic :=
  match e with
  | E_VAR n =>
      match lookup_field_dir m n with
      | Some dir =>
          if field_read_forbidden dir then
            [make_access_diag pou_name n
               "instance internal state (VAR) is not visible outside its FUNCTION_BLOCK"]
          else nil
      | None => nil
      end
  | E_ARRAY_ACCESS a b =>
      List.app (expr_access_all pou_name m a) (expr_access_all pou_name m b)
  | E_UNARY_OP _ a => expr_access_all pou_name m a
  | E_BIN_OP _ a b =>
      List.app (expr_access_all pou_name m a) (expr_access_all pou_name m b)
  | E_COMP _ a b =>
      List.app (expr_access_all pou_name m a) (expr_access_all pou_name m b)
  | E_AND a b =>
      List.app (expr_access_all pou_name m a) (expr_access_all pou_name m b)
  | E_OR a b =>
      List.app (expr_access_all pou_name m a) (expr_access_all pou_name m b)
  | E_XOR a b =>
      List.app (expr_access_all pou_name m a) (expr_access_all pou_name m b)
  | E_FUNC_CALL _ args =>
      List.concat (List.map (expr_access_all pou_name m) args)
  | E_QUALITY_OP _ args =>
      List.concat (List.map (expr_access_all pou_name m) args)
  | _ => nil
  end.

Fixpoint stmt_access_all (pou_name : ident)
           (m : list (ident * var_direction)) (s : st_stmt) : list diagnostic :=
  match s with
  | S_ASSIGN tgt rhs =>
      match lookup_field_dir m tgt with
      | Some dir =>
          if field_write_forbidden dir then
            [make_access_diag pou_name tgt
               "instance field is read-only (or invisible) outside its FUNCTION_BLOCK"]
          else expr_access_all pou_name m rhs
      | None => expr_access_all pou_name m rhs
      end
  | S_ARRAY_ASSIGN _ idx rhs =>
      List.app (expr_access_all pou_name m idx) (expr_access_all pou_name m rhs)
  | S_IF cond then_body else_body =>
      List.app (expr_access_all pou_name m cond)
        (List.app
           (List.concat (List.map (stmt_access_all pou_name m) then_body))
           (match else_body with
            | Some b => List.concat (List.map (stmt_access_all pou_name m) b)
            | None => nil
            end))
  | S_CASE cond branches default =>
      List.app (expr_access_all pou_name m cond)
        (List.app
           (List.concat
              (List.map
                 (fun ce =>
                    match ce with
                    | CASE_ELEM _ body =>
                        List.concat (List.map (stmt_access_all pou_name m) body)
                    end)
                 branches))
           (match default with
            | Some b => List.concat (List.map (stmt_access_all pou_name m) b)
            | None => nil
            end))
  | S_FOR _ from to step body =>
      List.app (expr_access_all pou_name m from)
        (List.app (expr_access_all pou_name m to)
           (List.app
              (match step with
               | Some se => expr_access_all pou_name m se
               | None => nil
               end)
              (List.concat (List.map (stmt_access_all pou_name m) body))))
  | S_WHILE cond body =>
      List.app (expr_access_all pou_name m cond)
        (List.concat (List.map (stmt_access_all pou_name m) body))
  | S_REPEAT body cond =>
      List.app (List.concat (List.map (stmt_access_all pou_name m) body))
        (expr_access_all pou_name m cond)
  | S_FB_CALL _ params =>
      List.concat (List.map (fun p => expr_access_all pou_name m (snd p)) params)
  | _ => nil
  end.

Definition check_pou_access_all
           (pous : list st_pou) (dir_map : list (ident * var_direction))
           (pou : st_pou) : list diagnostic :=
  let name := match pou with
              | P_PROGRAM n _ _ => n
              | P_FUNCTION n _ _ _ => n
              | P_FUNCTION_BLOCK n _ _ => n
              end in
  let body := match pou with
              | P_PROGRAM _ _ b => b
              | P_FUNCTION _ _ _ b => b
              | P_FUNCTION_BLOCK _ _ b => b
              end in
  List.concat (List.map (stmt_access_all name dir_map) body).

Definition check_program_access_all
           (pous : list st_pou) (gdecls : list st_var_decl) : list diagnostic :=
  let dir_map := build_field_dir_map pous gdecls in
  List.concat (List.map (check_pou_access_all pous dir_map) pous).

(* ---- 逐 POU 检查的全量版 ---- *)

Definition check_pou_full_all
           (globals : type_env) (fenv : type_env_func)
           (pou : st_pou) : list diagnostic :=
  let decls := pou_var_decls pou in
  let env := List.app (build_env_from_decls decls) globals in
  match pou with
  | P_PROGRAM name _ body =>
      if type_check_stmts_f true fenv env body then
        nil
      else
        [ {| dg_pou := name; dg_var := None;
             dg_kind := DK_TYPE; dg_msg := "type error" |} ]
  | P_FUNCTION name _ fdecls body =>
      (if negb (function_decls_ok fdecls) then
         [ {| dg_pou := name; dg_var := None; dg_kind := DK_DECLARATIONS;
              dg_msg :=
                "declarations may only use VAR_INPUT and local VAR" |} ]
       else nil) ++
      (if negb (function_control_stmts_ok body) then
         [ {| dg_pou := name; dg_var := None; dg_kind := DK_CONTROL;
              dg_msg :=
                "unsupported control flow (WHILE/REPEAT/EXIT/FB calls are not allowed in FUNCTION yet)" |} ]
       else nil) ++
      (if negb (function_for_bounds_stmts_ok body) then
         [ {| dg_pou := name; dg_var := None; dg_kind := DK_FOR_BOUND;
              dg_msg :=
                "FOR inside FUNCTION currently requires constant INT bounds and positive constant step" |} ]
       else nil) ++
      (if negb (function_writable_stmts_ok
                   (name :: local_writable_names fdecls) body) then
         [ {| dg_pou := name; dg_var := None; dg_kind := DK_PURITY;
              dg_msg :=
                "purity violation (only local VAR and function result may be assigned)" |} ]
       else nil) ++
      (if negb (type_check_stmts_f false fenv env body) then
         [ {| dg_pou := name; dg_var := None; dg_kind := DK_TYPE;
              dg_msg := "type error" |} ]
       else nil)
  | P_FUNCTION_BLOCK name _ body =>
      if type_check_stmts_f true fenv env body then
        nil
      else
        [ {| dg_pou := name; dg_var := None;
             dg_kind := DK_TYPE; dg_msg := "type error" |} ]
  end.

Fixpoint check_pous_full_all
           (globals : type_env) (fenv : type_env_func)
           (pous : list st_pou) : list diagnostic :=
  match pous with
  | nil => nil
  | pou :: rest =>
      List.app (check_pou_full_all globals fenv pou)
               (check_pous_full_all globals fenv rest)
  end.

(* 两道前置闸保持短路：用到保留名或缺少 PROGRAM 入口时，变量环境本身
   不成立，后续检查的结果没有意义。其余三趟全量收集。 *)
Definition check_program_full_diags (p : st_program) : list diagnostic :=
  if uses_reserved_cycle_counter p.(global_vars) then
    [ {| dg_pou := ID ""; dg_var := None; dg_kind := DK_RESERVED;
         dg_msg :=
           "global variable uses reserved name __veristc_cycle_counter" |} ]
  else
    match find_program_entry p.(pou_list) with
    | None =>
        [ {| dg_pou := ID ""; dg_var := None; dg_kind := DK_MISSING_ENTRY;
             dg_msg := "missing PROGRAM entry point" |} ]
    | Some _ =>
        let globals := build_env_from_decls p.(global_vars) in
        let fenv := build_fenv_from_pous p.(pou_list) in
        List.app
          (check_pous_full_all globals fenv p.(pou_list))
          (List.app
             (check_program_aliases_all p.(pou_list) globals)
             (List.app
                (check_program_access_all p.(pou_list) p.(global_vars))
                (check_io_mapping_all globals p.(io_mapping))))
    end.

(* 机器可读行：(POU 名, 变量名, KIND, MSG)。变量名保留派生形式
   （实例#字段），IDE 侧据此反查画布上的块与端口。 *)
Definition diag_row : Type :=
  (string * option string * string * string).

Definition diagnostic_row (d : diagnostic) : diag_row :=
  (ident_to_string d.(dg_pou),
   option_map ident_to_string d.(dg_var),
   diag_kind_to_string d.(dg_kind),
   d.(dg_msg)).

Definition check_program_full_diag_rows (p : st_program) : list diag_row :=
  List.map diagnostic_row (check_program_full_diags p).
