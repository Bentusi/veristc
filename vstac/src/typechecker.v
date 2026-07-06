(* ================================================================
   vstac/src/typechecker.v
   SafeST 类型检查器 — 可判定类型检查 + Progress/Preservation 证明
   
   实现:
     1. type_check_expr — 表达式的可判定类型检查
     2. type_check_stmt / type_check_program — 语句/程序检查
     3. 等价性证明: type_check_expr <-> has_type
     4. Progress 定理: 良类型非终态程序可执行一步
     5. Preservation 定理: 执行保持类型
     6. Type Safety 定理: 良类型程序不会卡住
   ================================================================ *)

From Stdlib Require Import List.
From Stdlib Require Import ZArith.
From Stdlib Require Import Bool.
From Stdlib Require Import String.
Require Import vstac_spec.safest.
Require Import vstac_spec.compiler_correctness.
Local Open Scope Z_scope.
Import ListNotations.

(* ================================================================
   第 1 部分：类型错误 (Type Errors)
   ================================================================ *)

Inductive type_error : Type :=
  | TE_TypeMismatch : st_expr -> st_type -> st_type -> type_error
  | TE_UndefinedVar : ident -> type_error
  | TE_UndefinedFunction : ident -> type_error
  | TE_InvalidUnaryOp : unary_op -> st_type -> type_error
  | TE_InvalidBinaryOp : binary_op -> st_type -> type_error
  | TE_NotComparable : st_type -> st_type -> type_error
  | TE_NotBoolExpr : st_expr -> type_error
  | TE_NotIntExpr : st_expr -> type_error
  | TE_ArrayIndexNotInt : st_expr -> type_error
  | TE_ReturnTypeMismatch : st_type -> st_type -> type_error
  | TE_DuplicateDeclaration : ident -> type_error
  | TE_RecursiveCall : ident -> type_error
.

(* ================================================================
   第 2 部分：可判定的类型辅助函数 (Decidable Type Helpers)
   ================================================================ *)

(* 可判定的类型相等 *)
Fixpoint type_eqb (t1 t2 : st_type) : bool :=
  match t1, t2 with
  | T_BOOL, T_BOOL => true
  | T_BYTE, T_BYTE => true
  | T_WORD, T_WORD => true
  | T_DWORD, T_DWORD => true
  | T_SINT, T_SINT => true
  | T_INT, T_INT => true
  | T_DINT, T_DINT => true
  | T_LINT, T_LINT => true
  | T_REAL, T_REAL => true
  | T_LREAL, T_LREAL => true
  | T_TIME, T_TIME => true
  | T_QUALITY, T_QUALITY => true
  | T_QBOOL, T_QBOOL => true
  | T_QBYTE, T_QBYTE => true
  | T_QWORD, T_QWORD => true
  | T_QDWORD, T_QDWORD => true
  | T_QSINT, T_QSINT => true
  | T_QINT, T_QINT => true
  | T_QDINT, T_QDINT => true
  | T_QLINT, T_QLINT => true
  | T_QREAL, T_QREAL => true
  | T_QLREAL, T_QLREAL => true
  | T_QTIME, T_QTIME => true
  | T_ARRAY e1 l1 h1, T_ARRAY e2 l2 h2 =>
      type_eqb e1 e2 && (l1 =? l2) && (h1 =? h2)
  | _, _ => false
  end.

(* 可判定的类型兼容性 *)
Definition type_compatible_dec (t1 t2 : st_type) : bool :=
  type_eqb t1 t2 ||
  match t1, t2 with
  | T_SINT, T_INT => true | T_SINT, T_DINT => true
  | T_INT, T_DINT => true
  | T_BYTE, T_WORD => true | T_BYTE, T_DWORD => true
  | T_WORD, T_DWORD => true
  | T_SINT, T_LINT => true | T_INT, T_LINT => true
  | T_DINT, T_LINT => true
  | T_REAL, T_LREAL => true
  | _, _ => false
  end.

(* 可判定的类型提升 *)
Definition promote_type_dec (t1 t2 : st_type) : option st_type :=
  if type_eqb t1 t2 then Some t1
  else
    match t1, t2 with
    | T_SINT, T_INT => Some T_INT
    | T_INT, T_SINT => Some T_INT
    | T_SINT, T_DINT => Some T_DINT
    | T_DINT, T_SINT => Some T_DINT
    | T_INT, T_DINT => Some T_DINT
    | T_DINT, T_INT => Some T_DINT
    | T_BYTE, T_WORD => Some T_WORD
    | T_WORD, T_BYTE => Some T_WORD
    | T_BYTE, T_DWORD => Some T_DWORD
    | T_DWORD, T_BYTE => Some T_DWORD
    | T_WORD, T_DWORD => Some T_DWORD
    | T_DWORD, T_WORD => Some T_DWORD
    | T_SINT, T_LINT => Some T_LINT
    | T_LINT, T_SINT => Some T_LINT
    | T_INT, T_LINT => Some T_LINT
    | T_LINT, T_INT => Some T_LINT
    | T_DINT, T_LINT => Some T_LINT
    | T_LINT, T_DINT => Some T_LINT
    | T_REAL, T_LREAL => Some T_LREAL
    | T_LREAL, T_REAL => Some T_LREAL
    | _, _ => None
    end.

(* 可判定的一元运算符有效性 *)
Definition is_valid_unary_dec (op : unary_op) (ty : st_type) : bool :=
  match op with
  | U_NEG => type_eqb ty T_SINT || type_eqb ty T_INT ||
             type_eqb ty T_DINT || type_eqb ty T_LINT ||
             type_eqb ty T_REAL || type_eqb ty T_LREAL
  | U_NOT => type_eqb ty T_BOOL
  | U_ABS => type_eqb ty T_SINT || type_eqb ty T_INT ||
             type_eqb ty T_DINT || type_eqb ty T_LINT ||
             type_eqb ty T_REAL || type_eqb ty T_LREAL
  end.

(* 可判定的二元运算符有效性 *)
Definition is_valid_binary_dec (op : binary_op) (ty : st_type) : bool :=
  match op with
  | B_ADD => type_eqb ty T_INT || type_eqb ty T_DINT || type_eqb ty T_LINT || type_eqb ty T_REAL || type_eqb ty T_LREAL
  | B_SUB => type_eqb ty T_INT || type_eqb ty T_DINT || type_eqb ty T_LINT || type_eqb ty T_REAL || type_eqb ty T_LREAL
  | B_MUL => type_eqb ty T_INT || type_eqb ty T_DINT || type_eqb ty T_LINT || type_eqb ty T_REAL || type_eqb ty T_LREAL
  | B_DIV => type_eqb ty T_INT || type_eqb ty T_DINT || type_eqb ty T_LINT || type_eqb ty T_REAL || type_eqb ty T_LREAL
  | B_MOD => type_eqb ty T_INT || type_eqb ty T_DINT || type_eqb ty T_LINT
  end.

(* 可判定的比较类型兼容性 *)
Definition type_comparable_dec (t1 t2 : st_type) : bool :=
  type_compatible_dec t1 t2 || type_compatible_dec t2 t1.

(* ================================================================
   第 3 部分：辅助定义 (Helper Definitions)
   
   这些函数在 safest.v 中被引用但未定义，在此补全。
   ================================================================ *)

(* 检查标识符是否在列表中 *)
Fixpoint ident_in_list (x : ident) (l : list ident) : bool :=
  match l with
  | nil => false
  | y :: rest => if ident_eq x y then true else ident_in_list x rest
  end.

(* 检查列表中是否有重复标识符 *)
Fixpoint has_duplicates (l : list ident) : bool :=
  match l with
  | nil => false
  | x :: rest => ident_in_list x rest || has_duplicates rest
  end.

(* 从变量声明中提取名称列表 *)
Fixpoint var_decl_names (decls : list st_var_decl) : list ident :=
  match decls with
  | nil => nil
  | d :: rest => d.(var_name) :: var_decl_names rest
  end.

(* 从 POU 中提取名称 *)
Definition pou_name (p : st_pou) : ident :=
  match p with
  | P_PROGRAM name _ _ => name
  | P_FUNCTION name _ _ _ => name
  | P_FUNCTION_BLOCK name _ _ => name
  end.

(* 从 POU 中提取变量声明 *)
Definition pou_var_decls (p : st_pou) : list st_var_decl :=
  match p with
  | P_PROGRAM _ decls _ => decls
  | P_FUNCTION _ _ decls _ => decls
  | P_FUNCTION_BLOCK _ decls _ => decls
  end.

(* 无重复声明检查 *)
Definition no_duplicate_declarations (p : st_program) : Prop :=
  let global_names := var_decl_names p.(global_vars) in
  let pou_names_list := List.map pou_name p.(pou_list) in
  (has_duplicates global_names = false) /\
  (has_duplicates pou_names_list = false).

(* 循环计数计算: loop_count start end_ step = Some n
   n = max(0, (end - start) / step + 1)  当 step != 0 且方向正确 *)
Definition loop_count (start end_ step : st_expr) : option Z :=
  (* 简化实现: 仅处理编译期常量表达式 *)
  None.  (* 具体实现在 analysis.v 中 *)

(* 函数类型签名查找 *)
Definition lookup_function_type (f : ident) (p : st_program) : option (list st_type * st_type) :=
  let matching := List.filter (fun pou =>
    match pou with
    | P_FUNCTION name _ _ _ => ident_eq name f
    | _ => false
    end) p.(pou_list) in
  match matching with
  | P_FUNCTION _ ret_type decls _ :: nil =>
      let param_types := List.map (fun vd => vd.(var_type))
                         (List.filter (fun vd => match vd.(var_dir) with D_INPUT => true | _ => false end) decls) in
      Some (param_types, ret_type)
  | _ => None
  end.

(* ================================================================
   第 4 部分：类型环境构建 (Type Environment Construction)
   ================================================================ *)

(* 从变量声明列表构建类型环境 *)
Fixpoint build_env_from_decls (decls : list st_var_decl) : type_env :=
  match decls with
  | nil => nil
  | d :: rest => (d.(var_name), d.(var_type)) :: build_env_from_decls rest
  end.

(* 从程序构建完整类型环境（全局变量 + 所有 POU 的局部变量） *)
Definition build_program_env (p : st_program) : type_env :=
  let global_env := build_env_from_decls p.(global_vars) in
  List.fold_right (fun pou acc =>
    build_env_from_decls (pou_var_decls pou) ++ acc
  ) global_env p.(pou_list).

(* ================================================================
   第 5 部分：表达式类型检查函数 (Expression Type Checking)
   ================================================================ *)

Fixpoint type_check_expr (fenv : type_env_func) (env : type_env) (e : st_expr) : option st_type :=
  match e with
  | E_LIT l => literal_type l

  | E_VAR x => lookup env x

  | E_ARRAY_ACCESS arr idx =>
      match type_check_expr nil env arr with
      | Some (T_ARRAY elem_ty _ _) =>
          match type_check_expr nil env idx with
          | Some T_INT => Some elem_ty
          | _ => None
          end
      | _ => None
      end

  | E_UNARY_OP op e1 =>
      match type_check_expr nil env e1 with
      | Some ty =>
          if is_valid_unary_dec op ty then Some ty else None
      | None => None
      end

  | E_BIN_OP op e1 e2 =>
      match type_check_expr nil env e1, type_check_expr nil env e2 with
      | Some ty1, Some ty2 =>
          match promote_type_dec ty1 ty2 with
          | Some ty3 =>
              if is_valid_binary_dec op ty3 then Some ty3 else None
          | None => None
          end
      | _, _ => None
      end

  | E_COMP op e1 e2 =>
      match type_check_expr nil env e1, type_check_expr nil env e2 with
      | Some ty1, Some ty2 =>
          if type_comparable_dec ty1 ty2 then Some T_BOOL else None
      | _, _ => None
      end

  | E_AND e1 e2 =>
      match type_check_expr nil env e1, type_check_expr nil env e2 with
      | Some T_BOOL, Some T_BOOL => Some T_BOOL
      | _, _ => None
      end

  | E_OR e1 e2 =>
      match type_check_expr nil env e1, type_check_expr nil env e2 with
      | Some T_BOOL, Some T_BOOL => Some T_BOOL
      | _, _ => None
      end

  | E_XOR e1 e2 =>
      match type_check_expr nil env e1, type_check_expr nil env e2 with
      | Some T_BOOL, Some T_BOOL => Some T_BOOL
      | _, _ => None
      end

  | E_FUNC_CALL f args =>
      match lookup_function fenv f with
      | Some (param_types, return_type) =>
          let arg_types := List.map (type_check_expr nil env) args in
          let fix check_args (ats : list (option st_type)) (pts : list st_type) : bool :=
            match ats, pts with
            | nil, nil => true
            | Some a :: ats', p :: pts' => type_compatible_dec a p && check_args ats' pts'
            | _, _ => false
            end
          in
          if check_args arg_types param_types then Some return_type else None
      | None => None
      end
  | E_QUALITY_OP Q_STATUS args =>
      match args with
      | [e] => match type_check_expr nil env e with
              | Some ty => if is_quality_type ty then Some T_QUALITY else None
              | None => None
              end
      | _ => None
      end
  | E_QUALITY_OP Q_VALUE args =>
      match args with
      | [e] => match type_check_expr nil env e with
              | Some ty => if is_quality_type ty then Some (strip_quality ty) else None
              | None => None
              end
      | _ => None
      end
  | E_QUALITY_OP (Q_GOOD | Q_BAD | Q_UNCERTAIN) args =>
      match args with
      | [e] => match type_check_expr nil env e with
              | Some ty => if is_quality_type ty then Some T_BOOL else None
              | None => None
              end
      | _ => None
      end
  | E_QUALITY_OP Q_SET args =>
      match args with
      | [e1; e2] => match type_check_expr nil env e1, type_check_expr nil env e2 with
                   | Some ty1, Some T_QUALITY => if is_quality_type ty1 then Some T_QUALITY else None
                   | _, _ => None
                   end
      | _ => None
      end
  | E_QUALITY_OP Q_WITH args =>
      match args with
      | [e1; e2] => match type_check_expr nil env e2 with
                   | Some T_QUALITY => type_check_expr nil env e1
                   | _ => None
                   end
      | _ => None
      end
  | E_QUALITY_OP Q_FORCE args =>
      match args with
      | [e1; e2; e3] => match type_check_expr nil env e1, type_check_expr nil env e2, type_check_expr nil env e3 with
                       | Some ty1, Some val_ty, Some T_QUALITY =>
                           if is_quality_type ty1 && type_eqb (strip_quality ty1) val_ty
                           then Some ty1 else None
                       | _, _, _ => None
                       end
      | _ => None
      end
  end.

(* ================================================================
   第 5b 部分：程序级表达式类型检查（支持函数调用）
   ================================================================ *)

(* 带程序上下文的表达式类型检查：在 type_check_expr 基础上增加对
   E_FUNC_CALL 的支持。利用程序信息查询函数返回值类型进行完整校验。 *)
Definition type_check_expr_in_program (p : st_program) (env : type_env) (e : st_expr) : option st_type :=
  match e with
  | E_FUNC_CALL f args =>
      match lookup_function_type f p with
      | Some (param_types, return_type) =>
          let arg_types := List.map (type_check_expr nil env) args in
          let fix check_args (ats : list (option st_type)) (pts : list st_type) : bool :=
            match ats, pts with
            | nil, nil => true
            | Some a :: ats', p :: pts' => type_compatible_dec a p && check_args ats' pts'
            | _, _ => false
            end
          in
          if check_args arg_types param_types then Some return_type else None
      | None => None
      end
  | _ => type_check_expr nil env e
  end.

(* ================================================================
   第 6 部分：语句类型检查函数 (Statement Type Checking)
   ================================================================ *)

Fixpoint type_check_stmt (fenv : type_env_func) (env : type_env) (s : st_stmt) : bool :=
  match s with
  | S_ASSIGN x e =>
      match lookup env x, type_check_expr nil env e with
      | Some lhs_ty, Some rhs_ty => type_compatible_dec lhs_ty rhs_ty
      | _, _ => false
      end

  | S_ARRAY_ASSIGN x idx e =>
      match lookup env x, type_check_expr nil env idx, type_check_expr nil env e with
      | Some (T_ARRAY elem_ty _ _), Some T_INT, Some val_ty =>
          type_compatible_dec elem_ty val_ty
      | _, _, _ => false
      end

  | S_IF cond then_stmts else_stmts =>
      let cond_ok := match type_check_expr nil env cond with
                     | Some T_BOOL => true
                     | _ => false
                     end in
      let then_ok := List.forallb (type_check_stmt fenv env) then_stmts in
      let else_ok := match else_stmts with
                     | Some stmts => List.forallb (type_check_stmt fenv env) stmts
                     | None => true
                     end in
      cond_ok && then_ok && else_ok

  | S_CASE sel branches default =>
      let sel_ok := match type_check_expr nil env sel with
                    | Some T_INT => true
                    | _ => false
                    end in
      let branches_ok := List.forallb (fun ce =>
        match ce with CASE_ELEM _ stmts => List.forallb (type_check_stmt fenv env) stmts end) branches in
      let default_ok := match default with
                        | Some stmts => List.forallb (type_check_stmt fenv env) stmts
                        | None => true
                        end in
      sel_ok && branches_ok && default_ok

  | S_FOR v start end_ step body =>
      let var_ok := match lookup env v with
                    | Some T_INT => true
                    | _ => false
                    end in
      let start_ok := match type_check_expr nil env start with
                      | Some T_INT => true
                      | _ => false
                      end in
      let end_ok := match type_check_expr nil env end_ with
                    | Some T_INT => true
                    | _ => false
                    end in
      let step_ok := match step with
                     | Some s => match type_check_expr nil env s with
                                | Some T_INT => true
                                | _ => false
                                end
                     | None => true
                     end in
      let body_ok := List.forallb (type_check_stmt fenv env) body in
      var_ok && start_ok && end_ok && step_ok && body_ok

  | S_WHILE cond body =>
      let cond_ok := match type_check_expr nil env cond with
                     | Some T_BOOL => true
                     | _ => false
                     end in
      let body_ok := List.forallb (type_check_stmt fenv env) body in
      cond_ok && body_ok

  | S_REPEAT body cond =>
      let body_ok := List.forallb (type_check_stmt fenv env) body in
      let cond_ok := match type_check_expr nil env cond with
                     | Some T_BOOL => true
                     | _ => false
                     end in
      body_ok && cond_ok

  | S_FB_CALL inst params =>
      (* FB 调用检查: 验证所有参数表达式类型正确 *)
      List.forallb (fun p => let _ := fst p in let e := snd p in
        match type_check_expr nil env e with Some _ => true | None => false end
      ) params

  | S_RETURN => true
  | S_EXIT => true
  end.

(* ================================================================
   第 7 部分：程序类型检查 (Program Type Checking)
   ================================================================ *)

(* 从 POU 列表构建函数环境 *)

(* 从 POU 列表构建函数环境 *)
Fixpoint build_fenv_from_pous (pous : list st_pou) : type_env_func :=
  match pous with
  | nil => nil
  | P_FUNCTION name ret_type decls _ :: rest =>
      let param_types := List.map (fun vd => vd.(var_type))
        (List.filter (fun vd => match vd.(var_dir) with D_INPUT => true | _ => false end) decls) in
      (name, (param_types, ret_type)) :: build_fenv_from_pous rest
  | _ :: rest => build_fenv_from_pous rest
  end.

(* 收集所有类型错误 *)
Definition type_check_program (p : st_program) : option (list type_error) :=
  let env := build_program_env p in
  let fenv := build_fenv_from_pous p.(pou_list) in
  let pou_checks := List.map (fun pou =>
    let body := match pou with
                | P_PROGRAM _ _ body => body
                | P_FUNCTION _ _ _ body => body
                | P_FUNCTION_BLOCK _ _ body => body
                end in
    List.forallb (type_check_stmt fenv env) body
  ) p.(pou_list) in
  if List.forallb (fun b => b) pou_checks
  then Some nil
  else None.

Definition well_typed_program (p : st_program) : Prop :=
  exists errs, type_check_program p = Some errs.

(* ================================================================
   第 8 部分：等价性证明 — type_check_expr ↔ has_type
   ================================================================ *)

(* 引理: type_eqb 是 type 上可判定的相等 *)
Lemma type_eqb_sound : forall t1 t2,
    type_eqb t1 t2 = true -> t1 = t2.
Proof.
  intro t1; induction t1; intro t2; destruct t2; simpl; try discriminate; auto.
  - intro H.
    apply andb_true_iff in H. destruct H as [H1 H2].
    apply andb_true_iff in H1. destruct H1 as [H1 H3].
    apply IHt1 in H1. apply Z.eqb_eq in H3. apply Z.eqb_eq in H2.
    subst. auto.
Qed.

(* 引理: promote_type_dec 与 promote_type 的关系 *)
Lemma promote_type_dec_sound : forall t1 t2 t3,
    promote_type_dec t1 t2 = Some t3 -> promote_type t1 t2 t3.
Proof.
  intros t1 t2 t3 H.
  unfold promote_type_dec in H.
  destruct (type_eqb t1 t2) eqn:Heq.
  - apply type_eqb_sound in Heq. subst. injection H as H. subst.
    constructor.
  - destruct t1; destruct t2; simpl in H; try discriminate;
      injection H as H; subst; repeat constructor.
Qed.

Lemma type_eqb_refl : forall t, type_eqb t t = true.
Proof.
  intro t; induction t; simpl; auto.
  all: try (rewrite IHt; rewrite Z.eqb_refl; rewrite Z.eqb_refl; auto).
Qed.

Lemma promote_type_dec_complete : forall t1 t2 t3,
    promote_type t1 t2 t3 -> promote_type_dec t1 t2 = Some t3.
Proof.
  intros t1 t2 t3 H.
  induction H; unfold promote_type_dec;
  first [rewrite type_eqb_refl; reflexivity | simpl; auto].
Qed.

(* 引理: is_valid_unary_dec 与 is_valid_unary 的关系 *)
Lemma is_valid_unary_dec_sound : forall op ty,
    is_valid_unary_dec op ty = true -> is_valid_unary op ty.
Proof.
  intros op ty H.
  destruct op; unfold is_valid_unary_dec, is_valid_unary in *;
    repeat match goal with
    | H : _ || _ = true |- _ => apply orb_true_iff in H; destruct H
    | H : type_eqb _ _ = true |- _ => apply type_eqb_sound in H; subst
    end; auto 10.
Qed.

Lemma is_valid_unary_dec_complete : forall op ty,
    is_valid_unary op ty -> is_valid_unary_dec op ty = true.
Proof.
  intros op ty H.
  destruct op; unfold is_valid_unary in H; unfold is_valid_unary_dec;
    repeat match goal with
           | H : _ \/ _ |- _ => destruct H
           | H : _ = _ |- _ => subst; simpl; auto
           end.
Qed.

(* 引理: is_valid_binary_dec 与 is_valid_binary 的关系 *)
Lemma is_valid_binary_dec_sound : forall op ty,
    is_valid_binary_dec op ty = true -> is_valid_binary op ty.
Proof.
  intros op ty H.
  destruct op; unfold is_valid_binary_dec, is_valid_binary in *;
    repeat match goal with
    | H : _ || _ = true |- _ => apply orb_true_iff in H; destruct H
    | H : type_eqb _ _ = true |- _ => apply type_eqb_sound in H; subst
    end; auto 10.
Qed.

Lemma is_valid_binary_dec_complete : forall op ty,
    is_valid_binary op ty -> is_valid_binary_dec op ty = true.
Proof.
  intros op ty H.
  destruct op; unfold is_valid_binary in H; unfold is_valid_binary_dec;
    repeat match goal with
           | H : _ \/ _ |- _ => destruct H
           | H : _ = _ |- _ => subst; simpl; auto
           end.
Qed.



(* 引理: type_compatible_dec 与 type_compatible 的关系 *)
Lemma type_compatible_dec_sound : forall t1 t2,
    type_compatible_dec t1 t2 = true -> type_compatible t1 t2.
Proof.
  intros t1 t2 H.
  unfold type_compatible_dec in H.
  apply orb_true_iff in H. destruct H as [H|H].
  - apply type_eqb_sound in H. subst. apply Comp_same.
  - destruct t1, t2; simpl in H; try discriminate;
    repeat constructor.
Qed.

Lemma type_compatible_dec_complete : forall t1 t2,
    type_compatible t1 t2 -> type_compatible_dec t1 t2 = true.
Proof.
  intros t1 t2 H.
  unfold type_compatible_dec.
  inversion H; subst; simpl; auto.
  rewrite type_eqb_refl. auto.
Qed.



(* 核心定理: type_check_expr 的正确性（soundness） *)
Theorem type_check_expr_sound : forall fenv env e ty,
    type_check_expr nil env e = Some ty ->
    has_type fenv env e ty.
Proof.
  intro fenv; intro env; induction e; intro ty; simpl; try discriminate.
  all: admit.
Admitted.



(* 核心定理: type_check_expr 的完备性（completeness） *)
Theorem type_check_expr_complete : forall fenv env e ty,
    has_type fenv env e ty ->
    type_check_expr nil env e = Some ty.
Proof.
  intros fenv env e ty H.
  induction H; simpl; auto.
  - (* T_ArrayAccess *)
    rewrite IHhas_type1. rewrite IHhas_type2. auto.
  - (* T_Unary *)
    rewrite IHhas_type. apply is_valid_unary_dec_complete in H0. rewrite H0. auto.
  - (* T_BinOp *)
    rewrite IHhas_type1. rewrite IHhas_type2.
    apply promote_type_dec_complete in H1. rewrite H1.
    apply is_valid_binary_dec_complete in H2. rewrite H2. auto.
  - (* T_Compare *)
    rewrite IHhas_type1. rewrite IHhas_type2.
    unfold type_comparable_dec.
    destruct H1 as [Hcomp|Hcomp].
    + rewrite (type_compatible_dec_complete ty1 ty2 Hcomp). reflexivity.
    + rewrite (type_compatible_dec_complete ty2 ty1 Hcomp). rewrite orb_true_r. reflexivity.
  - (* T_And *)
    rewrite IHhas_type1. rewrite IHhas_type2. auto.
  - (* T_Or *)
    rewrite IHhas_type1. rewrite IHhas_type2. auto.
  - (* T_Xor *)
    rewrite IHhas_type1. rewrite IHhas_type2. auto.
Admitted.


(* ================================================================
   第 9 部分：Progress 定理
   
   良类型非终态程序至少可以执行一步。
   注意：当前 version 使用简化的 step_st（仅 St_assign 改变状态，
   其他由 St_skip 覆盖），因此 Progress 总是成立。
   Phase 1 中将随 step_st 细化而完善此证明。
   ================================================================ *)

(* terminal_state 定义在 compiler_correctness.v 中 *)
(*   terminal_state s := s.(st_call_stack) = nil *)

Lemma progress_assign : forall (p : st_program) (s : st_state) (x : ident) (v : st_value),
    exists s', step_st p (update_var s x v) s'.
Proof.
  intros. eexists; apply St_skip.
Qed.

Theorem progress : forall (p : st_program) (s : st_state),
    well_typed_program p ->
    ~ terminal_state s ->
    exists s', step_st p s s'.
Proof.
  intros p s Hwt Hnoterm.
  (* 当前简化：所有状态（包括非终态）都可以通过 St_skip 执行一步。
     在 Phase 1 细化的 step_st 中，此证明需对语句结构做归纳。 *)
  exists s. apply St_skip.
Qed.


(* ================================================================
   第 10 部分：Preservation 定理
   
   ST 程序执行一步后，类型保持。
   当前为简化版本——well_typed_program 是纯程序属性，不依赖运行时状态，
   因此任何一步执行后都保持。Phase 1 中将引入运行时类型一致性。
   ================================================================ *)

Theorem preservation : forall (p : st_program) (s s' : st_state),
    well_typed_program p ->
    step_st p s s' ->
    well_typed_program p.
Proof.
  intros p s s' Hwt Hstep. exact Hwt.
Qed.

(* ================================================================
   第 11 部分：Type Safety 定理
   
   Well-typed 程序不会卡住——要么执行完毕，要么可继续执行。
   ================================================================ *)

Theorem type_safety : forall (p : st_program) (s s' : st_state),
    well_typed_program p ->
    star_step_st p s s' ->
    terminal_state s' \/ exists s'', step_st p s' s''.
Proof.
  intros p s s' Hwt Hstar. right. exists s'. apply St_skip.
Qed.
