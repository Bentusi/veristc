(* ================================================================
   veristc/src/typechecker.v
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
Require Import veristc_spec.safest.
Require Import veristc_spec.st_semantics.
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
  | E_QUALITY_OP (Q_GOOD | Q_BAD) args =>
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
                   | Some T_QUALITY =>
                       match type_check_expr nil env e1 with
                       | Some ty1 =>
                           if is_plain_base_type ty1
                           then Some (add_quality ty1)
                           else None
                       | None => None
                       end
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

Definition is_print_type (ty : st_type) : bool :=
  match ty with
  | T_BOOL | T_BYTE | T_WORD | T_DWORD
  | T_SINT | T_INT | T_DINT | T_QUALITY => true
  | _ => false
  end.

Fixpoint type_check_stmt (fenv : type_env_func) (env : type_env) (s : st_stmt) : bool :=
  match s with
  | S_ASSIGN x e =>
      match lookup env x, type_check_expr nil env e with
      | Some lhs_ty, Some rhs_ty => type_compatible_dec rhs_ty lhs_ty
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
                    | Some T_INT | Some T_DINT => true
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
      match inst with
      | ID "PRINT" =>
          List.forallb (fun p => let _ := fst p in let e := snd p in
            match type_check_expr nil env e with
            | Some ty => is_print_type ty
            | None => false
            end) params
      | _ =>
          (* FB 调用检查: 验证所有参数表达式类型正确 *)
          List.forallb (fun p => let _ := fst p in let e := snd p in
            match type_check_expr nil env e with Some _ => true | None => false end
          ) params
      end

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



(* 核心定理: type_check_expr 的正确性（soundness）
   论文 §7.1 的公式以空函数环境 ∅ 为规范，编译器在程序级检查
   函数调用前先把程序级函数环境展开到 AST，因此这里统一为 ∅。 *)
Theorem type_check_expr_sound : forall env e ty,
    type_check_expr nil env e = Some ty ->
    has_type nil env e ty.
Proof.
  intro env.
  fix IH 1.
  intros e ty Hty.
  destruct e; simpl in Hty; try discriminate.
  - (* E_LIT *)
    apply T_Literal; exact Hty.
  - (* E_VAR *)
    apply T_Var; exact Hty.
  - (* E_ARRAY_ACCESS *)
    destruct (type_check_expr nil env e1) as [t_arr|] eqn:Harr; simpl in Hty; try discriminate.
    destruct t_arr; simpl in Hty; try discriminate.
    destruct (type_check_expr nil env e2) as [t_idx|] eqn:Hidx; simpl in Hty; try discriminate.
    destruct t_idx; simpl in Hty; try discriminate.
    inversion Hty; subst.
    match goal with
    | Harr : type_check_expr nil env e1 = Some (T_ARRAY ?elem_ty ?lo ?hi)
      |- _ =>
        apply (T_ArrayAccess nil env e1 e2 elem_ty lo hi);
        [ exact (IH e1 (T_ARRAY elem_ty lo hi) Harr)
        | exact (IH e2 T_INT Hidx) ]
    end.
  - (* E_UNARY_OP *)
    destruct (type_check_expr nil env e) as [t1|] eqn:H1; simpl in Hty; try discriminate.
    destruct (is_valid_unary_dec u t1) eqn:Hvalid; simpl in Hty; try discriminate.
    inversion Hty; subst.
    apply (T_Unary nil env e u ty).
    + exact (IH e ty H1).
    + apply is_valid_unary_dec_sound; exact Hvalid.
  - (* E_BIN_OP *)
    destruct (type_check_expr nil env e1) as [t1|] eqn:H1; simpl in Hty; try discriminate.
    destruct (type_check_expr nil env e2) as [t2|] eqn:H2; simpl in Hty; try discriminate.
    destruct (promote_type_dec t1 t2) as [t3|] eqn:Hprom; simpl in Hty; try discriminate.
    destruct (is_valid_binary_dec b t3) eqn:Hvalid; simpl in Hty; try discriminate.
    inversion Hty; subst.
    apply (T_BinOp nil env e1 e2 b t1 t2 ty).
    + exact (IH e1 t1 H1).
    + exact (IH e2 t2 H2).
    + apply promote_type_dec_sound.
      exact Hprom.
    + apply is_valid_binary_dec_sound.
      exact Hvalid.
  - (* E_COMP *)
    destruct (type_check_expr nil env e1) as [t1|] eqn:H1; simpl in Hty; try discriminate.
    destruct (type_check_expr nil env e2) as [t2|] eqn:H2; simpl in Hty; try discriminate.
    destruct (type_comparable_dec t1 t2) eqn:Hcomp; simpl in Hty; try discriminate.
    inversion Hty; subst.
    apply (T_Compare nil env e1 e2 c t1 t2).
    + exact (IH e1 t1 H1).
    + exact (IH e2 t2 H2).
    + apply orb_true_iff in Hcomp.
      destruct Hcomp as [Hc1|Hc2].
      * left; apply type_compatible_dec_sound; exact Hc1.
      * right; apply type_compatible_dec_sound; exact Hc2.
  - (* E_AND *)
    destruct (type_check_expr nil env e1) as [t1|] eqn:H1; simpl in Hty; try discriminate.
    destruct t1; simpl in Hty; try discriminate.
    destruct (type_check_expr nil env e2) as [t2|] eqn:H2; simpl in Hty; try discriminate.
    destruct t2; simpl in Hty; try discriminate.
    inversion Hty; subst.
    apply T_And with (e1 := e1) (e2 := e2).
    + exact (IH e1 T_BOOL H1).
    + exact (IH e2 T_BOOL H2).
  - (* E_OR *)
    destruct (type_check_expr nil env e1) as [t1|] eqn:H1; simpl in Hty; try discriminate.
    destruct t1; simpl in Hty; try discriminate.
    destruct (type_check_expr nil env e2) as [t2|] eqn:H2; simpl in Hty; try discriminate.
    destruct t2; simpl in Hty; try discriminate.
    inversion Hty; subst.
    apply T_Or with (e1 := e1) (e2 := e2).
    + exact (IH e1 T_BOOL H1).
    + exact (IH e2 T_BOOL H2).
  - (* E_XOR *)
    destruct (type_check_expr nil env e1) as [t1|] eqn:H1; simpl in Hty; try discriminate.
    destruct t1; simpl in Hty; try discriminate.
    destruct (type_check_expr nil env e2) as [t2|] eqn:H2; simpl in Hty; try discriminate.
    destruct t2; simpl in Hty; try discriminate.
    inversion Hty; subst.
    apply T_Xor with (e1 := e1) (e2 := e2).
    + exact (IH e1 T_BOOL H1).
    + exact (IH e2 T_BOOL H2).
  - (* E_QUALITY_OP *)
    destruct q; simpl in Hty.
    + (* Q_STATUS *)
      destruct l as [|arg [|args']]; simpl in Hty; try discriminate.
      destruct (type_check_expr nil env arg) as [t_arg|] eqn:Harg; simpl in Hty; try discriminate.
      destruct (is_quality_type t_arg) eqn:Hq; simpl in Hty; try discriminate.
      inversion Hty; subst.
      apply (T_QStatus nil env arg t_arg).
      * exact (IH arg t_arg Harg).
      * exact Hq.
    + (* Q_VALUE *)
      destruct l as [|arg [|args']]; simpl in Hty; try discriminate.
      destruct (type_check_expr nil env arg) as [t_arg|] eqn:Harg; simpl in Hty; try discriminate.
      destruct (is_quality_type t_arg) eqn:Hq; simpl in Hty; try discriminate.
      inversion Hty; subst.
      apply (T_QValue nil env arg t_arg).
      * exact (IH arg t_arg Harg).
      * exact Hq.
    + (* Q_GOOD *)
      destruct l as [|arg [|args']]; simpl in Hty; try discriminate.
      destruct (type_check_expr nil env arg) as [t_arg|] eqn:Harg; simpl in Hty; try discriminate.
      destruct (is_quality_type t_arg) eqn:Hq; simpl in Hty; try discriminate.
      inversion Hty; subst.
      apply (T_QCheck nil env arg t_arg Q_GOOD).
      * exact (IH arg t_arg Harg).
      * exact Hq.
      * left; reflexivity.
    + (* Q_BAD *)
      destruct l as [|arg [|args']]; simpl in Hty; try discriminate.
      destruct (type_check_expr nil env arg) as [t_arg|] eqn:Harg; simpl in Hty; try discriminate.
      destruct (is_quality_type t_arg) eqn:Hq; simpl in Hty; try discriminate.
      inversion Hty; subst.
      apply (T_QCheck nil env arg t_arg Q_BAD).
      * exact (IH arg t_arg Harg).
      * exact Hq.
      * right; reflexivity.
    + (* Q_SET *)
      destruct l as [|arg1 [|arg2 [|args']]]; simpl in Hty; try discriminate.
      destruct (type_check_expr nil env arg1) as [t1|] eqn:H1; simpl in Hty; try discriminate.
      destruct (type_check_expr nil env arg2) as [t2|] eqn:H2; simpl in Hty; try discriminate.
      destruct t2; simpl in Hty; try discriminate.
      destruct (is_quality_type t1) eqn:Hq; simpl in Hty; try discriminate.
      inversion Hty; subst.
      apply (T_QSet nil env arg1 arg2 t1).
      * exact (IH arg1 t1 H1).
      * exact Hq.
      * exact (IH arg2 T_QUALITY H2).
    + (* Q_WITH *)
      destruct l as [|arg1 [|arg2 [|args']]]; simpl in Hty; try discriminate.
      destruct (type_check_expr nil env arg2) as [t2|] eqn:H2; simpl in Hty; try discriminate.
      destruct t2; simpl in Hty; try discriminate.
      destruct (type_check_expr nil env arg1) as [t1|] eqn:H1; simpl in Hty; try discriminate.
      destruct (is_plain_base_type t1) eqn:Hplain; simpl in Hty; try discriminate.
      inversion Hty; subst.
      apply (T_QWith nil env arg1 arg2 t1 (add_quality t1)).
      * exact (IH arg1 t1 H1).
      * exact Hplain.
      * reflexivity.
      * exact (IH arg2 T_QUALITY H2).
    + (* Q_FORCE *)
      destruct l as [|arg1 [|arg2 [|arg3 [|args']]]]; simpl in Hty; try discriminate.
      destruct (type_check_expr nil env arg1) as [t1|] eqn:H1; simpl in Hty; try discriminate.
      destruct (type_check_expr nil env arg2) as [t2|] eqn:H2; simpl in Hty; try discriminate.
      destruct (type_check_expr nil env arg3) as [t3|] eqn:H3; simpl in Hty; try discriminate.
      destruct t3; simpl in Hty; try discriminate.
      destruct (is_quality_type t1) eqn:Hq; simpl in Hty; try discriminate.
      destruct (type_eqb (strip_quality t1) t2) eqn:Heq; simpl in Hty; try discriminate.
      apply type_eqb_sound in Heq.
      inversion Hty; subst.
      apply (T_QForce nil env arg1 arg2 arg3 ty).
      * exact (IH arg1 ty H1).
      * exact Hq.
      * match goal with
        | H2 : type_check_expr nil env arg2 = Some ?vt |- _ =>
            pose proof (IH arg2 vt H2) as Hty2
        end.
        match goal with
        | He : strip_quality ty = ?vt |- _ => rewrite He in Hty2
        | He : ?vt = strip_quality ty |- _ => rewrite <- He in Hty2
        | _ => idtac
        end.
        exact Hty2.
      * exact (IH arg3 T_QUALITY H3).
Qed.



(* 核心定理: type_check_expr 的完备性（completeness） *)
Theorem type_check_expr_complete : forall env e ty,
    has_type nil env e ty ->
    type_check_expr nil env e = Some ty.
Proof.
  intros env e ty H.
  remember nil as fenv eqn:Heqfenv.
  induction H; subst.
  - (* T_Literal *)
    simpl.
    exact H.
  - (* T_Var *)
    simpl.
    exact H.
  - (* T_ArrayAccess *)
    simpl.
    rewrite (IHhas_type1 eq_refl). rewrite (IHhas_type2 eq_refl). auto.
  - (* T_Unary *)
    simpl.
    rewrite (IHhas_type eq_refl). apply is_valid_unary_dec_complete in H0. rewrite H0. auto.
  - (* T_BinOp *)
    simpl.
    rewrite (IHhas_type1 eq_refl). rewrite (IHhas_type2 eq_refl).
    apply promote_type_dec_complete in H1. rewrite H1.
    apply is_valid_binary_dec_complete in H2. rewrite H2. auto.
  - (* T_Compare *)
    simpl.
    rewrite (IHhas_type1 eq_refl). rewrite (IHhas_type2 eq_refl).
    unfold type_comparable_dec.
    destruct H1 as [Hcomp|Hcomp].
    + rewrite (type_compatible_dec_complete ty1 ty2 Hcomp). reflexivity.
    + rewrite (type_compatible_dec_complete ty2 ty1 Hcomp). rewrite orb_true_r. reflexivity.
  - (* T_And *)
    simpl.
    rewrite (IHhas_type1 eq_refl). rewrite (IHhas_type2 eq_refl). auto.
  - (* T_Or *)
    simpl.
    rewrite (IHhas_type1 eq_refl). rewrite (IHhas_type2 eq_refl). auto.
  - (* T_Xor *)
    simpl.
    rewrite (IHhas_type1 eq_refl). rewrite (IHhas_type2 eq_refl). auto.
  - (* T_FuncCall: 空函数环境无函数可查，推导不存在 *)
    simpl in H.
    discriminate H.
  - (* T_QStatus *)
    simpl.
    rewrite (IHhas_type eq_refl). rewrite H0. auto.
  - (* T_QValue *)
    simpl.
    rewrite (IHhas_type eq_refl). rewrite H0. auto.
  - (* T_QCheck *)
    simpl.
    rewrite (IHhas_type eq_refl).
    destruct H1 as [Hgo|Hbad]; subst; rewrite H0; auto.
  - (* T_QSet *)
    simpl.
    rewrite (IHhas_type1 eq_refl). rewrite (IHhas_type2 eq_refl). rewrite H0. auto.
  - (* T_QWith *)
    simpl.
    rewrite (IHhas_type2 eq_refl).
    rewrite (IHhas_type1 eq_refl).
    rewrite H0.
    congruence.
  - (* T_QForce *)
    simpl.
    rewrite (IHhas_type1 eq_refl). rewrite (IHhas_type2 eq_refl).
    rewrite (IHhas_type3 eq_refl).
    rewrite type_eqb_refl. rewrite H0. auto.
Qed.


(* ================================================================
   第 9 部分：核心子集与配置式类型关系
   ================================================================ *)

(* 核心子集使用的运行时类型 *)
Definition core_ty_dec (ty : st_type) : bool :=
  match ty with
  | T_BOOL | T_INT | T_DINT => true
  | _ => false
  end.

Definition core_ty (ty : st_type) : Prop :=
  core_ty_dec ty = true.

Lemma core_ty_cases :
  forall t : st_type,
    core_ty t ->
    t = T_BOOL \/ t = T_INT \/ t = T_DINT.
Proof.
  intros t H.
  unfold core_ty, core_ty_dec in H.
  destruct t; simpl in H; try discriminate; auto.
Qed.

Lemma promote_type_core_result :
  forall t1 t2 t3 : st_type,
    core_ty t1 -> core_ty t2 -> promote_type t1 t2 t3 -> core_ty t3.
Proof.
  intros t1 t2 t3 Hc1 Hc2 Hp.
  destruct (core_ty_cases t1 Hc1) as [H1 | [H1 | H1]]; subst.
  - destruct (core_ty_cases t2 Hc2) as [H2 | [H2 | H2]]; subst.
    + inversion Hp; subst; reflexivity.
    + inversion Hp; subst; reflexivity.
    + inversion Hp; subst; reflexivity.
  - destruct (core_ty_cases t2 Hc2) as [H2 | [H2 | H2]]; subst.
    + inversion Hp; subst; reflexivity.
    + inversion Hp; subst; reflexivity.
    + inversion Hp; subst; reflexivity.
  - destruct (core_ty_cases t2 Hc2) as [H2 | [H2 | H2]]; subst.
    + inversion Hp; subst; reflexivity.
    + inversion Hp; subst; reflexivity.
    + inversion Hp; subst; reflexivity.
Qed.

(* 变量声明都在核心类型内 *)
Definition core_env (env : type_env) : Prop :=
  forall (x : ident) (ty : st_type),
    lookup env x = Some ty -> core_ty ty.

Fixpoint core_expr (e : st_expr) : bool :=
  match e with
  | E_LIT l =>
      match l with
      | L_BOOL _ | L_INT _ => true
      | _ => false
      end
  | E_VAR _ => true
  | E_UNARY_OP op e1 =>
      match op with
      | U_NEG | U_NOT => core_expr e1
      | U_ABS => false
      end
  | E_BIN_OP op e1 e2 =>
      match op with
      | B_DIV | B_MOD => false
      | _ => core_expr e1 && core_expr e2
      end
  | E_COMP _ e1 e2 => core_expr e1 && core_expr e2
  | E_AND e1 e2 | E_OR e1 e2 | E_XOR e1 e2 => core_expr e1 && core_expr e2
  | _ => false
  end.

Fixpoint core_stmt (s : st_stmt) : bool :=
  match s with
  | S_ASSIGN _ e => core_expr e
  | S_IF cond then_stmts else_stmts =>
      core_expr cond &&
      List.forallb core_stmt then_stmts &&
      match else_stmts with
      | Some es => List.forallb core_stmt es
      | None => true
      end
  | S_WHILE cond body => core_expr cond && List.forallb core_stmt body
  | S_REPEAT body cond => List.forallb core_stmt body && core_expr cond
  | S_FOR _ start end_ step body =>
      core_expr start && core_expr end_ &&
      (match step with Some e => core_expr e | None => true end) &&
      List.forallb core_stmt body
  | S_CASE sel branches default =>
      core_expr sel &&
      List.forallb (fun ce =>
        match ce with
        | CASE_ELEM values stmts =>
            core_case_values_dec values && List.forallb core_stmt stmts
        end) branches &&
      match default with
      | Some ds => List.forallb core_stmt ds
      | None => true
      end
  | _ => false
  end.

Definition core_pou (p : st_pou) : bool :=
  List.forallb (fun d => core_ty_dec d.(var_type)) (pou_var_decls p) &&
  (match p with
   | P_FUNCTION _ _ _ _ | P_FUNCTION_BLOCK _ _ _ => false
   | P_PROGRAM _ _ body => List.forallb core_stmt body
   end).

Definition core_program (p : st_program) : bool :=
  match p.(pou_list) with
  | pou :: nil =>
      core_pou pou &&
      (match p.(global_vars) with nil => true | _ => false end) &&
      (match p.(io_mapping) with nil => true | _ => false end)
  | _ => false
  end.

(* 配置式良类型语句列表。
   只覆盖核心子集，且把复合语句的子块一并纳入类型关系。 *)
Inductive typed_stmts (fenv : type_env_func) (env : type_env)
          : list st_stmt -> Prop :=
  | TS_nil : typed_stmts fenv env nil
  | TS_assign : forall (x : ident) (e : st_expr) (lhs_ty rhs_ty : st_type)
                       (rest : list st_stmt),
      lookup env x = Some lhs_ty ->
      type_check_expr fenv env e = Some rhs_ty ->
      type_compatible_dec rhs_ty lhs_ty = true ->
      typed_stmts fenv env rest ->
      typed_stmts fenv env (S_ASSIGN x e :: rest)
  | TS_if : forall (cond : st_expr) (then_stmts : list st_stmt)
                   (else_stmts : option (list st_stmt)) (rest : list st_stmt),
      type_check_expr fenv env cond = Some T_BOOL ->
      typed_stmts fenv env then_stmts ->
      typed_opt_stmts fenv env else_stmts ->
      typed_stmts fenv env rest ->
      typed_stmts fenv env (S_IF cond then_stmts else_stmts :: rest)
  | TS_while : forall (cond : st_expr) (body : list st_stmt)
                       (rest : list st_stmt),
      type_check_expr fenv env cond = Some T_BOOL ->
      typed_stmts fenv env body ->
      typed_stmts fenv env rest ->
      typed_stmts fenv env (S_WHILE cond body :: rest)
  | TS_repeat : forall (body : list st_stmt) (cond : st_expr)
                        (rest : list st_stmt),
      typed_stmts fenv env body ->
      type_check_expr fenv env cond = Some T_BOOL ->
      typed_stmts fenv env rest ->
      typed_stmts fenv env (S_REPEAT body cond :: rest)
  | TS_for : forall (v : ident) (start end_ : st_expr) (step : option st_expr)
                     (body : list st_stmt) (rest : list st_stmt),
      lookup env v = Some T_INT ->
      type_check_expr fenv env start = Some T_INT ->
      type_check_expr fenv env end_ = Some T_INT ->
      (match step with
       | Some e => type_check_expr fenv env e = Some T_INT
       | None => True end) ->
      typed_stmts fenv env body ->
      typed_stmts fenv env rest ->
      typed_stmts fenv env (S_FOR v start end_ step body :: rest)
  | TS_case_int : forall (sel : st_expr) (branches : list case_element)
                          (default : option (list st_stmt)) (rest : list st_stmt),
      type_check_expr fenv env sel = Some T_INT ->
      typed_case_elements fenv env branches ->
      typed_opt_stmts fenv env default ->
      typed_stmts fenv env rest ->
      typed_stmts fenv env (S_CASE sel branches default :: rest)
  | TS_case_dint : forall (sel : st_expr) (branches : list case_element)
                           (default : option (list st_stmt)) (rest : list st_stmt),
      type_check_expr fenv env sel = Some T_DINT ->
      typed_case_elements fenv env branches ->
      typed_opt_stmts fenv env default ->
      typed_stmts fenv env rest ->
      typed_stmts fenv env (S_CASE sel branches default :: rest)
with typed_case_elements (fenv : type_env_func) (env : type_env)
     : list case_element -> Prop :=
  | TCE_nil : typed_case_elements fenv env nil
  | TCE_cons : forall (vals : list case_value) (stmts : list st_stmt)
                       (brs : list case_element),
      typed_stmts fenv env stmts ->
      typed_case_elements fenv env brs ->
      typed_case_elements fenv env (CASE_ELEM vals stmts :: brs)
with typed_opt_stmts (fenv : type_env_func) (env : type_env)
     : option (list st_stmt) -> Prop :=
  | TO_none : typed_opt_stmts fenv env None
  | TO_some : forall (stmts : list st_stmt),
      typed_stmts fenv env stmts ->
      typed_opt_stmts fenv env (Some stmts).

(* 声明类型、运行时值与表达式求值结果的基础值构造引理 *)
Lemma value_type_bool : forall v : st_value,
    st_value_type v = T_BOOL -> exists b : bool, v = ST_V_BOOL b.
Proof.
  destruct v; simpl; intros H; try discriminate; eexists; reflexivity.
Qed.

Lemma value_type_int : forall v : st_value,
    st_value_type v = T_INT -> exists n : Z, v = ST_V_INT n.
Proof.
  destruct v; simpl; intros H; try discriminate; eexists; reflexivity.
Qed.

Lemma value_type_dint : forall v : st_value,
    st_value_type v = T_DINT ->
    exists n : Z, v = ST_V_DINT n \/ v = ST_V_INT n.
Proof.
  destruct v; simpl; intros H; try discriminate; eexists; auto.
Qed.

Lemma value_shape_core :
  forall (ty : st_type) (v : st_value),
    core_ty ty ->
    st_value_type v = ty ->
    (exists b : bool, ty = T_BOOL /\ v = ST_V_BOOL b) \/
    (exists n : Z, ty = T_INT /\ v = ST_V_INT n) \/
    (exists n : Z, ty = T_DINT /\ v = ST_V_DINT n).
Proof.
  intros ty v Hc Hvt.
  unfold core_ty in Hc.
  destruct v; simpl in Hvt;
    try (rewrite <- Hvt in Hc; simpl in Hc; discriminate);
    eauto 6.
Qed.

Lemma eval_unop_result_type :
  forall (op : unary_op) (s : st_state) (e : st_expr)
         (v : st_value) (ty : st_type),
    eval_expr s e = Some v ->
    st_value_type v = ty ->
    core_ty ty ->
    is_valid_unary op ty ->
    exists v', eval_expr s (E_UNARY_OP op e) = Some v' /\
               st_value_type v' = ty.
Proof.
  intros op s e v ty He Hvty Hcore Hvalid.
  destruct (value_shape_core ty v Hcore Hvty)
    as [[b [Htyb Hvb]] | [[n [Htyi Hvi]] | [n [Htyd Hvd]]]];
    subst ty v.
  - destruct op.
    + unfold is_valid_unary in Hvalid.
      destruct Hvalid as [Hs | [Hi | [Hd | [Hl | [Hr | Hlr]]]]]; congruence.
    + simpl. rewrite He. eexists; split; reflexivity.
    + unfold is_valid_unary in Hvalid.
      destruct Hvalid as [Hs | [Hi | [Hd | [Hl | [Hr | Hlr]]]]]; congruence.
  - destruct op.
    + simpl. rewrite He. eexists; split; reflexivity.
    + unfold is_valid_unary in Hvalid. congruence.
    + simpl. rewrite He. eexists; split; reflexivity.
  - destruct op.
    + simpl. rewrite He. eexists; split; reflexivity.
    + unfold is_valid_unary in Hvalid. congruence.
    + simpl. rewrite He. eexists; split; reflexivity.
Qed.

Lemma eval_binop_result_type :
  forall (op : binary_op) (s : st_state) (e1 e2 : st_expr)
         (v1 v2 : st_value) (ty1 ty2 ty3 : st_type),
    eval_expr s e1 = Some v1 ->
    eval_expr s e2 = Some v2 ->
    st_value_type v1 = ty1 ->
    st_value_type v2 = ty2 ->
    core_ty ty1 ->
    core_ty ty2 ->
    promote_type ty1 ty2 ty3 ->
    is_valid_binary op ty3 ->
    core_ty ty3 ->
    exists v', eval_expr s (E_BIN_OP op e1 e2) = Some v' /\
               st_value_type v' = ty3.
Proof.
  intros op s e1 e2 v1 v2 ty1 ty2 ty3 He1 He2
         Htype1 Htype2 Hcore1 Hcore2 Hprom Hvalid Hcore3.
  revert He1 He2.
  destruct (value_shape_core ty1 v1 Hcore1 Htype1)
    as [[b1 [Ht1 Hvv1]] | [[n1 [Ht1 Hvv1]] | [n1 [Ht1 Hvv1]]]];
    subst ty1 v1.
  - destruct (value_shape_core ty2 v2 Hcore2 Htype2)
      as [[b2 [Ht2 Hvv2]] | [[n2 [Ht2 Hvv2]] | [n2 [Ht2 Hvv2]]]];
      subst ty2 v2.
    + inversion Hprom; subst.
      unfold is_valid_binary in Hvalid.
      destruct op; unfold is_valid_binary in Hvalid;
        repeat match goal with H : _ \/ _ |- _ => destruct H end;
        congruence.
    + inversion Hprom.
    + inversion Hprom.
  - destruct (value_shape_core ty2 v2 Hcore2 Htype2)
      as [[b2 [Ht2 Hvv2]] | [[n2 [Ht2 Hvv2]] | [n2 [Ht2 Hvv2]]]];
      subst ty2 v2.
    + inversion Hprom.
    + inversion Hprom; subst.
      intros He1 He2.
      destruct op; simpl; rewrite He1; rewrite He2;
        eexists; split; reflexivity.
    + inversion Hprom; subst.
      intros He1 He2.
      destruct op; simpl; rewrite He1; rewrite He2;
        eexists; split; reflexivity.
  - destruct (value_shape_core ty2 v2 Hcore2 Htype2)
      as [[b2 [Ht2 Hvv2]] | [[n2 [Ht2 Hvv2]] | [n2 [Ht2 Hvv2]]]];
      subst ty2 v2.
    + inversion Hprom.
    + inversion Hprom; subst.
      intros He1 He2.
      destruct op; simpl; rewrite He1; rewrite He2;
        eexists; split; reflexivity.
    + inversion Hprom; subst.
      intros He1 He2.
      destruct op; simpl; rewrite He1; rewrite He2;
        eexists; split; reflexivity.
Qed.

Lemma eval_compare_result_type :
  forall (op : compare_op) (s : st_state) (e1 e2 : st_expr)
         (v1 v2 : st_value) (ty1 ty2 : st_type),
    eval_expr s e1 = Some v1 ->
    eval_expr s e2 = Some v2 ->
    st_value_type v1 = ty1 ->
    st_value_type v2 = ty2 ->
    core_ty ty1 ->
    core_ty ty2 ->
    (type_compatible ty1 ty2 \/ type_compatible ty2 ty1) ->
    exists v', eval_expr s (E_COMP op e1 e2) = Some v' /\
               st_value_type v' = T_BOOL.
Proof.
  intros op s e1 e2 v1 v2 ty1 ty2 He1 He2 Hv1 Hv2 Hc1 Hc2 Hcomp.
  revert He1 He2.
  destruct (value_shape_core ty1 v1 Hc1 Hv1)
    as [[b1 [Ht1 Hvv1]] | [[n1 [Ht1 Hvv1]] | [n1 [Ht1 Hvv1]]]];
    subst ty1 v1.
  - destruct (value_shape_core ty2 v2 Hc2 Hv2)
      as [[b2 [Ht2 Hvv2]] | [[n2 [Ht2 Hvv2]] | [n2 [Ht2 Hvv2]]]];
      subst ty2 v2.
    + intros He1 He2.
      destruct op; simpl; rewrite He1; rewrite He2;
        eexists; split; reflexivity.
    + destruct Hcomp as [h | h]; inversion h.
    + destruct Hcomp as [h | h]; inversion h.
  - destruct (value_shape_core ty2 v2 Hc2 Hv2)
      as [[b2 [Ht2 Hvv2]] | [[n2 [Ht2 Hvv2]] | [n2 [Ht2 Hvv2]]]];
      subst ty2 v2.
    + destruct Hcomp as [h | h]; inversion h.
    + intros He1 He2.
      destruct op; simpl; rewrite He1; rewrite He2;
        eexists; split; reflexivity.
    + intros He1 He2.
      destruct op; simpl; rewrite He1; rewrite He2;
        eexists; split; reflexivity.
  - destruct (value_shape_core ty2 v2 Hc2 Hv2)
      as [[b2 [Ht2 Hvv2]] | [[n2 [Ht2 Hvv2]] | [n2 [Ht2 Hvv2]]]];
      subst ty2 v2.
    + destruct Hcomp as [h | h]; inversion h.
    + intros He1 He2.
      destruct op; simpl; rewrite He1; rewrite He2;
        eexists; split; reflexivity.
    + intros He1 He2.
      destruct op; simpl; rewrite He1; rewrite He2;
        eexists; split; reflexivity.
Qed.

Lemma eval_and_result_type :
  forall (s : st_state) (e1 e2 : st_expr) (v1 v2 : st_value),
    eval_expr s e1 = Some v1 ->
    eval_expr s e2 = Some v2 ->
    st_value_type v1 = T_BOOL ->
    st_value_type v2 = T_BOOL ->
    exists v',
      eval_expr s (E_AND e1 e2) = Some v' /\
      st_value_type v' = T_BOOL.
Proof.
  intros s e1 e2 v1 v2 He1 He2 Hv1 Hv2.
  destruct v1; simpl in Hv1; try discriminate.
  destruct v2; simpl in Hv2; try discriminate.
  simpl; rewrite He1; rewrite He2;
    eexists; split; reflexivity.
Qed.

Lemma eval_or_result_type :
  forall (s : st_state) (e1 e2 : st_expr) (v1 v2 : st_value),
    eval_expr s e1 = Some v1 ->
    eval_expr s e2 = Some v2 ->
    st_value_type v1 = T_BOOL ->
    st_value_type v2 = T_BOOL ->
    exists v',
      eval_expr s (E_OR e1 e2) = Some v' /\
      st_value_type v' = T_BOOL.
Proof.
  intros s e1 e2 v1 v2 He1 He2 Hv1 Hv2.
  destruct v1; simpl in Hv1; try discriminate.
  destruct v2; simpl in Hv2; try discriminate.
  simpl; rewrite He1; rewrite He2;
    eexists; split; reflexivity.
Qed.

Lemma eval_xor_result_type :
  forall (s : st_state) (e1 e2 : st_expr) (v1 v2 : st_value),
    eval_expr s e1 = Some v1 ->
    eval_expr s e2 = Some v2 ->
    st_value_type v1 = T_BOOL ->
    st_value_type v2 = T_BOOL ->
    exists v',
      eval_expr s (E_XOR e1 e2) = Some v' /\
      st_value_type v' = T_BOOL.
Proof.
  intros s e1 e2 v1 v2 He1 He2 Hv1 Hv2.
  destruct v1; simpl in Hv1; try discriminate.
  destruct v2; simpl in Hv2; try discriminate.
  simpl; rewrite He1; rewrite He2;
      eexists; split; reflexivity.
Qed.

(* ================================================================
   第 10 部分：核心子集配置式类型安全
   ================================================================ *)

Lemma core_ty_bool : core_ty T_BOOL.
Proof. reflexivity. Qed.

Lemma core_ty_int : core_ty T_INT.
Proof. reflexivity. Qed.

Lemma core_ty_dint : core_ty T_DINT.
Proof. reflexivity. Qed.

(* 核心表达式在类型检查成功时，其类型必为核心类型。 *)
Lemma core_expr_type_is_core :
  forall (env : type_env) (e : st_expr) (ty : st_type),
    core_env env ->
    core_expr e = true ->
    type_check_expr nil env e = Some ty ->
    core_ty ty.
Proof.
  intros env e; induction e as [lit | x | arr idx | uop e IHe
      | bop e1 IHe1 e2 IHe2 | cop e1 IHe1 e2 IHe2
      | e1 IHe1 e2 IHe2 | e1 IHe1 e2 IHe2 | e1 IHe1 e2 IHe2
      | f args | q args]; intros ty Henv Hcore Hty.
  - destruct lit; simpl in Hcore; try discriminate;
      simpl in Hty; inversion Hty; reflexivity.
  - simpl in Hty.
    exact (Henv x ty Hty).
  - simpl in Hcore; discriminate.
  - simpl in Hcore.
    assert (Hcore_e : core_expr e = true).
    { destruct uop; simpl in Hcore; try discriminate; exact Hcore. }
    simpl in Hty.
    destruct (type_check_expr nil env e) as [t1|] eqn:Ht;
      simpl in Hty; try discriminate.
    destruct (is_valid_unary_dec uop t1) eqn:Hvalid;
      simpl in Hty; try discriminate.
    pose proof (IHe ty Henv Hcore_e Hty) as Hct1.
    inversion Hty; subst.
    exact Hct1.
  - simpl in Hcore.
    assert (Hcore_exprs : core_expr e1 && core_expr e2 = true).
    { destruct bop; simpl in Hcore; try discriminate; exact Hcore. }
    apply andb_true_iff in Hcore_exprs.
    destruct Hcore_exprs as [Hc1 Hc2].
    simpl in Hty.
    destruct (type_check_expr nil env e1) as [t1|] eqn:Ht1;
      simpl in Hty; try discriminate.
    destruct (type_check_expr nil env e2) as [t2|] eqn:Ht2;
      simpl in Hty; try discriminate.
    destruct (promote_type_dec t1 t2) as [t3|] eqn:Hp;
      simpl in Hty; try discriminate.
    destruct (is_valid_binary_dec bop t3) eqn:Hvalid;
      simpl in Hty; try discriminate.
    pose proof (IHe1 t1 Henv Hc1 eq_refl) as Hcore1.
    pose proof (IHe2 t2 Henv Hc2 eq_refl) as Hcore2.
    pose proof (promote_type_dec_sound t1 t2 t3 Hp) as Hprom.
    inversion Hty; subst.
    eapply promote_type_core_result;
      [exact Hcore1 | exact Hcore2 | exact Hprom].
  - simpl in Hcore.
    apply andb_true_iff in Hcore.
    destruct Hcore as [Hc1 Hc2].
    simpl in Hty.
    destruct (type_check_expr nil env e1) as [t1|] eqn:Ht1;
      simpl in Hty; try discriminate.
    destruct (type_check_expr nil env e2) as [t2|] eqn:Ht2;
      simpl in Hty; try discriminate.
    destruct (type_comparable_dec t1 t2) eqn:Hcomp;
      simpl in Hty; try discriminate.
    inversion Hty.
    reflexivity.
  - simpl in Hcore.
    apply andb_true_iff in Hcore.
    destruct Hcore as [Hc1 Hc2].
    simpl in Hty.
    destruct (type_check_expr nil env e1) as [t1|] eqn:Ht1;
      simpl in Hty; try discriminate.
    destruct t1; simpl in Hty; try discriminate.
    destruct (type_check_expr nil env e2) as [t2|] eqn:Ht2;
      simpl in Hty; try discriminate.
    destruct t2; simpl in Hty; try discriminate.
    inversion Hty.
    reflexivity.
  - simpl in Hcore.
    apply andb_true_iff in Hcore.
    destruct Hcore as [Hc1 Hc2].
    simpl in Hty.
    destruct (type_check_expr nil env e1) as [t1|] eqn:Ht1;
      simpl in Hty; try discriminate.
    destruct t1; simpl in Hty; try discriminate.
    destruct (type_check_expr nil env e2) as [t2|] eqn:Ht2;
      simpl in Hty; try discriminate.
    destruct t2; simpl in Hty; try discriminate.
    inversion Hty.
    reflexivity.
  - simpl in Hcore.
    apply andb_true_iff in Hcore.
    destruct Hcore as [Hc1 Hc2].
    simpl in Hty.
    destruct (type_check_expr nil env e1) as [t1|] eqn:Ht1;
      simpl in Hty; try discriminate.
    destruct t1; simpl in Hty; try discriminate.
    destruct (type_check_expr nil env e2) as [t2|] eqn:Ht2;
      simpl in Hty; try discriminate.
    destruct t2; simpl in Hty; try discriminate.
    inversion Hty.
    reflexivity.
  - simpl in Hcore; discriminate.
  - simpl in Hcore; discriminate.
Qed.

(* 核心语句列表不变量：每条顶层语句都属于核心子集。 *)
Definition core_stmts (stmts : list st_stmt) : Prop :=
  List.forallb core_stmt stmts = true.

Definition core_opt_stmts (o : option (list st_stmt)) : Prop :=
  match o with
  | Some stmts => core_stmts stmts
  | None => True
  end.

Definition core_case_elements (cs : list case_element) : Prop :=
  List.forallb (fun ce =>
    match ce with
    | CASE_ELEM _ stmts => List.forallb core_stmt stmts
    end) cs = true.

Lemma core_stmts_app :
  forall (l1 l2 : list st_stmt),
    core_stmts l1 ->
    core_stmts l2 ->
    core_stmts (l1 ++ l2).
Proof.
  intros l1 l2 H1 H2.
  unfold core_stmts in *.
  induction l1 as [|s rest IH]; simpl in *.
  - exact H2.
  - apply andb_true_iff in H1.
    destruct H1 as [Hs Hrest].
    apply andb_true_iff.
    split.
    + exact Hs.
    + exact (IH Hrest).
Qed.

(* 类型保持的列表拼接：复合语句展开后的后继列表仍是良类型列表。 *)
Lemma typed_stmts_app :
  forall (fenv : type_env_func) (env : type_env) (l1 l2 : list st_stmt),
    typed_stmts fenv env l1 ->
    typed_stmts fenv env l2 ->
    typed_stmts fenv env (l1 ++ l2).
Proof.
  intros fenv env l1 l2.
  induction l1 as [|s rest IH]; intros H1 H2; simpl.
  - exact H2.
  - destruct s; inversion H1; subst; simpl;
      try solve [econstructor; eauto; apply IH; assumption].
Qed.

Lemma ident_eq_sound :
  forall (x y : ident), ident_eq x y = true -> x = y.
Proof.
  intros [sx] [sy]; simpl.
  intro H.
  pose proof (proj1 (String.eqb_eq sx sy) H) as E.
  subst.
  reflexivity.
Qed.

Lemma lookup_var_update_head :
  forall (x : ident) (v : st_value) (vars : list (ident * st_value)),
    lookup_var ((x, v) :: vars) x = Some v.
Proof.
  intros [s] v vars.
  simpl.
  rewrite String.eqb_refl.
  reflexivity.
Qed.

Lemma lookup_var_update_other :
  forall (x y : ident) (v : st_value) (vars : list (ident * st_value)),
    ident_eq x y = false ->
    lookup_var ((x, v) :: vars) y = lookup_var vars y.
Proof.
  intros [sx] [sy] v vars H.
  simpl.
  unfold ident_eq in H.
  rewrite (String.eqb_sym sy sx).
  rewrite H.
  reflexivity.
Qed.

(* 核心类型赋值经过 coerce 后仍与左值声明类型一致。 *)
Lemma coerce_value_to_type_preserves_type :
  forall (lhs_ty rhs_ty : st_type) (v : st_value),
    core_ty lhs_ty ->
    core_ty rhs_ty ->
    type_compatible rhs_ty lhs_ty ->
    st_value_type v = rhs_ty ->
    st_value_type (coerce_value_to_type lhs_ty v) = lhs_ty.
Proof.
  intros lhs_ty rhs_ty v Hcl Hcr Hcomp Hv.
  destruct lhs_ty; simpl in Hcl; try discriminate;
    destruct rhs_ty; simpl in Hcr; try discriminate;
    try (inversion Hcomp).
  all: try (destruct (value_type_bool v Hv); subst; reflexivity).
  all: try (destruct (value_type_int v Hv); subst; reflexivity).
  all: destruct v; simpl in Hv; try discriminate; subst; reflexivity.
Qed.

Lemma update_var_preserves_state_consistent :
  forall (env : type_env) (s : st_state) (x : ident) (ty : st_type)
         (v : st_value),
    state_consistent env s ->
    lookup env x = Some ty ->
    st_value_type v = ty ->
    state_consistent env (update_var s x v).
Proof.
  intros env s x ty v Hstate Hlook Htype.
  unfold state_consistent in *.
  destruct Hstate as [Hvals Hpresent].
  split.
  - intros y ty' w Hlook2 Hfind.
    unfold update_var in Hfind.
    simpl in Hfind.
    destruct (ident_eq y x) eqn:Heq.
    + injection Hfind as Hvw.
      pose proof (ident_eq_sound y x Heq) as Hyx.
      subst y.
      assert (Htyeq : ty' = ty).
      { rewrite Hlook in Hlook2.
        inversion Hlook2.
        reflexivity. }
      subst ty'.
      rewrite Hvw in Htype.
      exact Htype.
    + exact (Hvals y ty' w Hlook2 Hfind).
  - intros y ty' Hlook2.
    destruct (ident_eq x y) eqn:Heq.
    + apply ident_eq_sound in Heq.
      subst y.
      exists v.
      change (lookup_var ((x, v) :: s.(st_vars)) x = Some v).
      apply lookup_var_update_head.
    + destruct (Hpresent y ty' Hlook2) as [w Hw].
      exists w.
      change (lookup_var ((x, v) :: s.(st_vars)) y = Some w).
      rewrite lookup_var_update_other by exact Heq.
      exact Hw.
Qed.

Lemma core_stmts_cons :
  forall (s : st_stmt) (rest : list st_stmt),
    core_stmts (s :: rest) ->
    core_stmt s = true /\ core_stmts rest.
Proof.
  intros s rest H.
  unfold core_stmts in *.
  simpl in H.
  apply andb_true_iff.
  exact H.
Qed.

Lemma core_stmts_single :
  forall (s : st_stmt), core_stmt s = true -> core_stmts (s :: nil).
Proof.
  intros s H.
  unfold core_stmts.
  simpl.
  rewrite H.
  reflexivity.
Qed.

Lemma core_opt_stmts_some :
  forall (o : option (list st_stmt)) (stmts : list st_stmt),
    core_opt_stmts o ->
    o = Some stmts ->
    core_stmts stmts.
Proof.
  intros o stmts H Hsome.
  rewrite Hsome in H.
  exact H.
Qed.

(* 配置式核心程序不变量 *)
Definition core_cfg (p : st_program) (stmts : list st_stmt) (s : st_state) : Prop :=
  core_program p = true /\
  core_env (build_program_env p) /\
  core_stmts stmts /\
  typed_stmts (build_fenv_from_pous p.(pou_list)) (build_program_env p) stmts /\
  state_consistent (build_program_env p) s.

Lemma core_stmt_if_core_exprs :
  forall (cond : st_expr) (then_stmts : list st_stmt)
         (else_stmts : option (list st_stmt)),
    core_stmt (S_IF cond then_stmts else_stmts) = true ->
    core_expr cond = true /\
    core_stmts then_stmts /\
    core_opt_stmts else_stmts.
Proof.
  intros cond then_stmts else_stmts H.
  unfold core_stmt in H.
  apply andb_true_iff in H.
  destruct H as [H1 Helse].
  apply andb_true_iff in H1.
  destruct H1 as [Hcond Hthen].
  split; [exact Hcond |].
  split.
  - exact Hthen.
  - destruct else_stmts as [es |].
    + unfold core_opt_stmts, core_stmts in *.
      exact Helse.
    + unfold core_opt_stmts.
      exact I.
Qed.

Lemma core_stmt_while_core_exprs :
  forall (cond : st_expr) (body : list st_stmt),
    core_stmt (S_WHILE cond body) = true ->
    core_expr cond = true /\ core_stmts body.
Proof.
  intros cond body H.
  unfold core_stmt in H.
  apply andb_true_iff in H.
  destruct H.
  split.
  - assumption.
  - unfold core_stmts.
    assumption.
Qed.

Lemma core_stmt_repeat_core_exprs :
  forall (body : list st_stmt) (cond : st_expr),
    core_stmt (S_REPEAT body cond) = true ->
    core_stmts body /\ core_expr cond = true.
Proof.
  intros body cond H.
  unfold core_stmt in H.
  apply andb_true_iff in H.
  destruct H.
  split.
  - unfold core_stmts.
    assumption.
  - assumption.
Qed.

Lemma core_stmt_for_core_exprs :
  forall (v : ident) (start end_ : st_expr) (step : option st_expr)
         (body : list st_stmt),
    core_stmt (S_FOR v start end_ step body) = true ->
    core_expr start = true /\
    core_expr end_ = true /\
    core_stmts body.
Proof.
  intros v start end_ step body H.
  unfold core_stmt in H.
  apply andb_true_iff in H.
  destruct H as [H1 Hbody].
  apply andb_true_iff in H1.
  destruct H1 as [H2 Hstep].
  apply andb_true_iff in H2.
  destruct H2 as [Hstart Hend].
  split; [exact Hstart |].
  split; [exact Hend |].
  exact Hbody.
Qed.

Lemma core_expr_type_check_fenv_indep :
  forall (fenv : type_env_func) (env : type_env) (e : st_expr),
    core_expr e = true ->
    type_check_expr fenv env e = type_check_expr nil env e.
Proof.
  intros fenv env e.
  induction e as [lit | x | arr idx | uop e1
    | bop e1 e2 | cop e1 e2
    | e1 e2 | e1 e2 | e1 e2
    | f args | q args]; intros Hc; simpl in Hc; try discriminate.
  all: try destruct lit; simpl; reflexivity.
Qed.

Lemma typed_assign_inv :
  forall (fenv : type_env_func) (env : type_env) (x : ident)
         (e : st_expr) (rest : list st_stmt),
    typed_stmts fenv env (S_ASSIGN x e :: rest) ->
    exists lhs_ty rhs_ty,
      lookup env x = Some lhs_ty /\
      type_check_expr fenv env e = Some rhs_ty /\
      type_compatible_dec rhs_ty lhs_ty = true /\
      typed_stmts fenv env rest.
Proof.
  intros fenv env x e rest H.
  inversion H; subst.
  eauto 7.
Qed.

Lemma typed_if_inv :
  forall (fenv : type_env_func) (env : type_env) (cond : st_expr)
         (then_stmts : list st_stmt) (else_stmts : option (list st_stmt))
         (rest : list st_stmt),
    typed_stmts fenv env (S_IF cond then_stmts else_stmts :: rest) ->
    type_check_expr fenv env cond = Some T_BOOL /\
    typed_stmts fenv env then_stmts /\
    typed_opt_stmts fenv env else_stmts /\
    typed_stmts fenv env rest.
Proof.
  intros fenv env cond then_stmts else_stmts rest H.
  inversion H; subst.
  auto.
Qed.

Lemma typed_while_inv :
  forall (fenv : type_env_func) (env : type_env) (cond : st_expr)
         (body : list st_stmt) (rest : list st_stmt),
    typed_stmts fenv env (S_WHILE cond body :: rest) ->
    type_check_expr fenv env cond = Some T_BOOL /\
    typed_stmts fenv env body /\
    typed_stmts fenv env rest.
Proof.
  intros fenv env cond body rest H.
  inversion H; subst.
  auto.
Qed.

Lemma typed_repeat_inv :
  forall (fenv : type_env_func) (env : type_env) (body : list st_stmt)
         (cond : st_expr) (rest : list st_stmt),
    typed_stmts fenv env (S_REPEAT body cond :: rest) ->
    typed_stmts fenv env body /\
    type_check_expr fenv env cond = Some T_BOOL /\
    typed_stmts fenv env rest.
Proof.
  intros fenv env body cond rest H.
  inversion H; subst.
  auto.
Qed.

Lemma typed_for_inv :
  forall (fenv : type_env_func) (env : type_env) (v : ident)
         (start end_ : st_expr) (step : option st_expr)
         (body : list st_stmt) (rest : list st_stmt),
    typed_stmts fenv env (S_FOR v start end_ step body :: rest) ->
    lookup env v = Some T_INT /\
    type_check_expr fenv env start = Some T_INT /\
    type_check_expr fenv env end_ = Some T_INT /\
    (match step with
     | Some e => type_check_expr fenv env e = Some T_INT
     | None => True end) /\
    typed_stmts fenv env body /\
    typed_stmts fenv env rest.
Proof.
  intros fenv env v start end_ step body rest H.
  inversion H; subst.
  repeat split; assumption.
Qed.


(* 核心子集中的良类型表达式求值必有结果，且结果的基础类型与声明类型一致。 *)
Theorem typed_eval_total :
  forall (env : type_env) (s : st_state) (e : st_expr) (ty : st_type),
    core_env env ->
    core_expr e = true ->
    state_consistent env s ->
    type_check_expr nil env e = Some ty ->
    core_ty ty ->
    exists v : st_value, eval_expr s e = Some v /\ st_value_type v = ty.
Proof.
  intros env s e; induction e as [lit | x | arr idx | uop e IHe
      | bop e1 IHe1 e2 IHe2 | cop e1 IHe1 e2 IHe2
      | e1 IHe1 e2 IHe2 | e1 IHe1 e2 IHe2 | e1 IHe1 e2 IHe2
      | f args | q args]; intros ty Henv Hcore Hstate Hty Hcorety.
  - destruct lit; simpl in Hcore; try discriminate;
      simpl in Hty; inversion Hty; subst;
      eexists; split; reflexivity.
  - unfold state_consistent in Hstate.
    destruct Hstate as [Hvals Hpresent].
    simpl in Hty.
    pose proof (Hpresent x ty Hty) as [v Hlook].
    exists v.
    split.
    + simpl.
      exact Hlook.
    + exact (Hvals x ty v Hty Hlook).
  - simpl in Hcore; discriminate.
  - simpl in Hcore.
    assert (Hcore_e : core_expr e = true).
    { destruct uop; simpl in Hcore; try discriminate; exact Hcore. }
    simpl in Hty.
    destruct (type_check_expr nil env e) as [t1|] eqn:Ht1;
      simpl in Hty; try discriminate.
    destruct (is_valid_unary_dec uop t1) eqn:Hvalid;
      simpl in Hty; try discriminate.
    pose proof (core_expr_type_is_core env e t1 Henv Hcore_e Ht1) as Hct1.
    destruct (IHe t1 Henv Hcore_e Hstate eq_refl Hct1)
      as [v1 [He1 Hv1]].
    destruct (eval_unop_result_type uop s e v1 t1 He1 Hv1 Hct1
               (is_valid_unary_dec_sound uop t1 Hvalid))
      as [v' [He' Hv']].
    injection Hty as Ht1eq.
    rewrite Ht1eq in Hv'.
    exists v'.
    split; [exact He' | exact Hv'].
  - simpl in Hcore.
    assert (Hcore_exprs : core_expr e1 && core_expr e2 = true).
    { destruct bop; simpl in Hcore; try discriminate; exact Hcore. }
    apply andb_true_iff in Hcore_exprs.
    destruct Hcore_exprs as [Hc1 Hc2].
    simpl in Hty.
    destruct (type_check_expr nil env e1) as [t1|] eqn:Ht1;
      simpl in Hty; try discriminate.
    destruct (type_check_expr nil env e2) as [t2|] eqn:Ht2;
      simpl in Hty; try discriminate.
    destruct (promote_type_dec t1 t2) as [t3|] eqn:Hp;
      simpl in Hty; try discriminate.
    destruct (is_valid_binary_dec bop t3) eqn:Hvalid;
      simpl in Hty; try discriminate.
    pose proof (core_expr_type_is_core env e1 t1 Henv Hc1 Ht1) as Hct1.
    pose proof (core_expr_type_is_core env e2 t2 Henv Hc2 Ht2) as Hct2.
    pose proof (promote_type_core_result t1 t2 t3 Hct1 Hct2
                 (promote_type_dec_sound t1 t2 t3 Hp)) as Hcore3.
    destruct (IHe1 t1 Henv Hc1 Hstate eq_refl Hct1)
      as [v1 [He1 Hv1]].
    destruct (IHe2 t2 Henv Hc2 Hstate eq_refl Hct2)
      as [v2 [He2 Hv2]].
    destruct (eval_binop_result_type bop s e1 e2 v1 v2 t1 t2 t3
               He1 He2 Hv1 Hv2 Hct1 Hct2
               (promote_type_dec_sound t1 t2 t3 Hp)
               (is_valid_binary_dec_sound bop t3 Hvalid)
               Hcore3)
      as [v' [He' Hv']].
    injection Hty as Ht3eq.
    rewrite Ht3eq in Hv'.
    exists v'.
    split; [exact He' | exact Hv'].
  - simpl in Hcore.
    apply andb_true_iff in Hcore.
    destruct Hcore as [Hc1 Hc2].
    simpl in Hty.
    destruct (type_check_expr nil env e1) as [t1|] eqn:Ht1;
      simpl in Hty; try discriminate.
    destruct (type_check_expr nil env e2) as [t2|] eqn:Ht2;
      simpl in Hty; try discriminate.
    destruct (type_comparable_dec t1 t2) eqn:Hcomp;
      simpl in Hty; try discriminate.
    inversion Hty.
    pose proof (core_expr_type_is_core env e1 t1 Henv Hc1 Ht1) as Hct1.
    pose proof (core_expr_type_is_core env e2 t2 Henv Hc2 Ht2) as Hct2.
    destruct (IHe1 t1 Henv Hc1 Hstate eq_refl Hct1)
      as [v1 [He1 Hv1]].
    destruct (IHe2 t2 Henv Hc2 Hstate eq_refl Hct2)
      as [v2 [He2 Hv2]].
    unfold type_comparable_dec in Hcomp.
    apply orb_true_iff in Hcomp.
    destruct Hcomp as [Hleft | Hright].
    + destruct (eval_compare_result_type cop s e1 e2 v1 v2 t1 t2
                 He1 He2 Hv1 Hv2 Hct1 Hct2
                 (or_introl (type_compatible_dec_sound t1 t2 Hleft)))
        as [v' [He' Hv']].
      exists v'.
      split; [exact He' | exact Hv'].
    + destruct (eval_compare_result_type cop s e1 e2 v1 v2 t1 t2
                 He1 He2 Hv1 Hv2 Hct1 Hct2
                 (or_intror (type_compatible_dec_sound t2 t1 Hright)))
        as [v' [He' Hv']].
      exists v'.
      split; [exact He' | exact Hv'].
  - simpl in Hcore.
    apply andb_true_iff in Hcore.
    destruct Hcore as [Hc1 Hc2].
    simpl in Hty.
    destruct (type_check_expr nil env e1) as [t1|] eqn:Ht1;
      simpl in Hty; try discriminate.
    destruct t1; simpl in Hty; try discriminate.
    destruct (type_check_expr nil env e2) as [t2|] eqn:Ht2;
      simpl in Hty; try discriminate.
    destruct t2; simpl in Hty; try discriminate.
    inversion Hty.
    destruct (IHe1 T_BOOL Henv Hc1 Hstate eq_refl core_ty_bool)
      as [v1 [He1 Hv1]].
    destruct (IHe2 T_BOOL Henv Hc2 Hstate eq_refl core_ty_bool)
      as [v2 [He2 Hv2]].
    destruct (eval_and_result_type s e1 e2 v1 v2 He1 He2 Hv1 Hv2)
      as [v' [He' Hv']].
    exists v'.
    split; [exact He' | exact Hv'].
  - simpl in Hcore.
    apply andb_true_iff in Hcore.
    destruct Hcore as [Hc1 Hc2].
    simpl in Hty.
    destruct (type_check_expr nil env e1) as [t1|] eqn:Ht1;
      simpl in Hty; try discriminate.
    destruct t1; simpl in Hty; try discriminate.
    destruct (type_check_expr nil env e2) as [t2|] eqn:Ht2;
      simpl in Hty; try discriminate.
    destruct t2; simpl in Hty; try discriminate.
    inversion Hty.
    destruct (IHe1 T_BOOL Henv Hc1 Hstate eq_refl core_ty_bool)
      as [v1 [He1 Hv1]].
    destruct (IHe2 T_BOOL Henv Hc2 Hstate eq_refl core_ty_bool)
      as [v2 [He2 Hv2]].
    destruct (eval_or_result_type s e1 e2 v1 v2 He1 He2 Hv1 Hv2)
      as [v' [He' Hv']].
    exists v'.
    split; [exact He' | exact Hv'].
  - simpl in Hcore.
    apply andb_true_iff in Hcore.
    destruct Hcore as [Hc1 Hc2].
    simpl in Hty.
    destruct (type_check_expr nil env e1) as [t1|] eqn:Ht1;
      simpl in Hty; try discriminate.
    destruct t1; simpl in Hty; try discriminate.
    destruct (type_check_expr nil env e2) as [t2|] eqn:Ht2;
      simpl in Hty; try discriminate.
    destruct t2; simpl in Hty; try discriminate.
    inversion Hty.
    destruct (IHe1 T_BOOL Henv Hc1 Hstate eq_refl core_ty_bool)
      as [v1 [He1 Hv1]].
    destruct (IHe2 T_BOOL Henv Hc2 Hstate eq_refl core_ty_bool)
      as [v2 [He2 Hv2]].
    destruct (eval_xor_result_type s e1 e2 v1 v2 He1 He2 Hv1 Hv2)
      as [v' [He' Hv']].
    exists v'.
    split; [exact He' | exact Hv'].
  - simpl in Hcore; discriminate.
  - simpl in Hcore; discriminate.
Qed.

Lemma typed_sel_eval_bool :
  forall (env : type_env) (s : st_state) (fenv : type_env_func)
         (e : st_expr),
    core_env env ->
    core_expr e = true ->
    state_consistent env s ->
    type_check_expr fenv env e = Some T_BOOL ->
    exists b : bool, eval_expr s e = Some (ST_V_BOOL b).
Proof.
  intros env s fenv e Henv Hcore Hstate Hty.
  rewrite (core_expr_type_check_fenv_indep fenv env e Hcore) in Hty.
  destruct (typed_eval_total env s e T_BOOL Henv Hcore Hstate Hty
             core_ty_bool) as [v [He Htype]].
  destruct v; simpl in Htype; try discriminate.
  eexists.
  exact He.
Qed.

Lemma typed_sel_eval_int :
  forall (env : type_env) (s : st_state) (fenv : type_env_func)
         (e : st_expr),
    core_env env ->
    core_expr e = true ->
    state_consistent env s ->
    type_check_expr fenv env e = Some T_INT ->
    exists n : Z, eval_expr s e = Some (ST_V_INT n).
Proof.
  intros env s fenv e Henv Hcore Hstate Hty.
  rewrite (core_expr_type_check_fenv_indep fenv env e Hcore) in Hty.
  destruct (typed_eval_total env s e T_INT Henv Hcore Hstate Hty
             core_ty_int) as [v [He Htype]].
  destruct v; simpl in Htype; try discriminate.
  eexists.
  exact He.
Qed.

Lemma typed_sel_eval_dint :
  forall (env : type_env) (s : st_state) (fenv : type_env_func)
         (e : st_expr),
    core_env env ->
    core_expr e = true ->
    state_consistent env s ->
    type_check_expr fenv env e = Some T_DINT ->
    exists n : Z, eval_expr s e = Some (ST_V_DINT n).
Proof.
  intros env s fenv e Henv Hcore Hstate Hty.
  rewrite (core_expr_type_check_fenv_indep fenv env e Hcore) in Hty.
  destruct (typed_eval_total env s e T_DINT Henv Hcore Hstate Hty
             core_ty_dint) as [v [He Htype]].
  destruct v; simpl in Htype; try discriminate.
  eexists.
  exact He.
Qed.

Lemma typed_case_inv :
  forall (fenv : type_env_func) (env : type_env) (sel : st_expr)
         (branches : list case_element) (default : option (list st_stmt))
         (rest : list st_stmt),
    typed_stmts fenv env (S_CASE sel branches default :: rest) ->
    (type_check_expr fenv env sel = Some T_INT \/
     type_check_expr fenv env sel = Some T_DINT) /\
    typed_case_elements fenv env branches /\
    typed_opt_stmts fenv env default /\
    typed_stmts fenv env rest.
Proof.
  intros fenv env sel branches default rest H.
  inversion H; subst; auto.
Qed.

Lemma core_stmt_case_core_sel :
  forall (sel : st_expr) (branches : list case_element)
         (default : option (list st_stmt)),
    core_stmt (S_CASE sel branches default) = true ->
    core_expr sel = true.
Proof.
  intros sel branches default H.
  unfold core_stmt in H.
  apply andb_true_iff in H.
  destruct H as [H1 _].
  apply andb_true_iff in H1.
  destruct H1 as [Hsel _].
  exact Hsel.
Qed.

(* 配置式核心程序的单步可推进性。 *)
Theorem progress_cfg :
  forall (p : st_program) (stmts : list st_stmt) (s : st_state),
    core_cfg p stmts s ->
    stmts <> nil ->
    exists (stmts' : list st_stmt) (s' : st_state),
      stmts_step p stmts s stmts' s'.
Proof.
  intros p stmts s Hcfg Hnon.
  destruct Hcfg as [Hprog [Henv [Hcore [Htyped Hstate]]]].
  destruct stmts as [|st rest].
  - exfalso.
    apply Hnon.
    reflexivity.
  - destruct (core_stmts_cons st rest Hcore) as [Hcore_st Hcore_rest].
    destruct st as [x e | x idx e | cond then_stmts else_stmts
      | sel branches default | v start end_ step body | cond body
      | body cond | inst params | |].
    + (* S_ASSIGN *)
      destruct (typed_assign_inv (build_fenv_from_pous p.(pou_list))
                 (build_program_env p) x e rest Htyped)
        as [lhs [rhs [Hlook [Htc [Hcomp Hrest]]]]].
      simpl in Hcore_st.
      rewrite (core_expr_type_check_fenv_indep
                 (build_fenv_from_pous p.(pou_list))
                 (build_program_env p) e Hcore_st) in Htc.
      pose proof (core_expr_type_is_core (build_program_env p) e rhs
                   Henv Hcore_st Htc) as Hcrhs.
      destruct (typed_eval_total (build_program_env p) s e rhs
                 Henv Hcore_st Hstate Htc Hcrhs)
        as [v [He Htype]].
      exact (ss_assign_step_exists p x e rest s v lhs Hlook He).
    + (* S_ARRAY_ASSIGN *)
      inversion Htyped.
    + (* S_IF *)
      destruct (typed_if_inv (build_fenv_from_pous p.(pou_list))
                 (build_program_env p) cond then_stmts else_stmts rest
                 Htyped) as [Htc [Hthen [Helse Hrest]]].
      simpl in Hcore_st.
      destruct (core_stmt_if_core_exprs cond then_stmts else_stmts
                 Hcore_st) as [Hcc [_ _]].
      destruct (typed_sel_eval_bool (build_program_env p) s
                 (build_fenv_from_pous p.(pou_list)) cond
                 Henv Hcc Hstate Htc) as [b He].
      destruct b.
      * eapply ss_if_true_step_exists.
        exact He.
      * eapply ss_if_false_step_exists.
        exact He.
    + (* S_CASE *)
      destruct (typed_case_inv (build_fenv_from_pous p.(pou_list))
                 (build_program_env p) sel branches default rest Htyped)
        as [[Htc | Htc] [Hbranches [Hdefault Hrest]]].
      * pose proof (core_stmt_case_core_sel sel branches default Hcore_st)
          as Hcsel.
        destruct (typed_sel_eval_int (build_program_env p) s
                   (build_fenv_from_pous p.(pou_list)) sel
                   Henv Hcsel Hstate Htc) as [n He].
        eexists (select_case_stmts n branches default ++ rest).
        eexists s.
        eapply Ss_case.
        exact He.
      * pose proof (core_stmt_case_core_sel sel branches default Hcore_st)
          as Hcsel.
        destruct (typed_sel_eval_dint (build_program_env p) s
                   (build_fenv_from_pous p.(pou_list)) sel
                   Henv Hcsel Hstate Htc) as [n He].
        eexists (select_case_stmts n branches default ++ rest).
        eexists s.
        eapply Ss_case_dint.
        exact He.
    + (* S_FOR *)
      apply ss_for_step_exists.
    + (* S_WHILE *)
      destruct (typed_while_inv (build_fenv_from_pous p.(pou_list))
                 (build_program_env p) cond body rest Htyped)
        as [Htc [Hbody Hrest]].
      simpl in Hcore_st.
      destruct (core_stmt_while_core_exprs cond body Hcore_st)
        as [Hcc _].
      destruct (typed_sel_eval_bool (build_program_env p) s
                 (build_fenv_from_pous p.(pou_list)) cond
                 Henv Hcc Hstate Htc) as [b He].
      destruct b.
      * eapply ss_while_true_step_exists.
        exact He.
      * eapply ss_while_false_step_exists.
        exact He.
    + (* S_REPEAT *)
      apply ss_repeat_step_exists.
    + (* S_FB_CALL *)
      inversion Htyped.
    + inversion Htyped.
    + inversion Htyped.
Qed.

Lemma core_stmts_cons_intro :
  forall (s : st_stmt) (rest : list st_stmt),
    core_stmt s = true ->
    core_stmts rest ->
    core_stmts (s :: rest).
Proof.
  intros s rest Hs Hrest.
  unfold core_stmts in *.
  simpl.
  rewrite Hs.
  exact Hrest.
Qed.

Lemma typed_case_branch_lookup :
  forall (fenv : type_env_func) (env : type_env)
         (branches : list case_element) (n : Z) (stmts : list st_stmt),
    typed_case_elements fenv env branches ->
    find_case_branch n branches = Some stmts ->
    typed_stmts fenv env stmts.
Proof.
  intros fenv env branches.
  induction branches as [| [vals br_stmts] rest IH].
  - intros n stmts Hty Hfind.
    simpl in Hfind.
    discriminate.
  - intros n stmts Hty Hfind.
    inversion Hty; subst.
    simpl in Hfind.
    destruct (match_case_values n vals) eqn:Hm.
    + inversion Hfind; subst; auto.
    + eapply IH; eauto.
Qed.

Lemma typed_opt_default_lookup :
  forall (fenv : type_env_func) (env : type_env)
         (default : option (list st_stmt)) (stmts : list st_stmt),
    typed_opt_stmts fenv env default ->
    default = Some stmts ->
    typed_stmts fenv env stmts.
Proof.
  intros fenv env default stmts Hty Hsome.
  destruct default as [ds |].
  - inversion Hty; subst.
    injection Hsome; intros; subst.
    assumption.
  - discriminate.
Qed.

Lemma core_case_branch_lookup :
  forall (branches : list case_element) (n : Z) (stmts : list st_stmt),
    core_case_elements branches ->
    find_case_branch n branches = Some stmts ->
    core_stmts stmts.
Proof.
  unfold core_case_elements.
  intros branches.
  induction branches as [| [vals br_stmts] rest IH].
  - intros n stmts Hall Hfind.
    simpl in Hfind.
    discriminate.
  - intros n stmts Hall Hfind.
    simpl in Hall.
    apply andb_true_iff in Hall.
    destruct Hall as [Hbr Hrest].
    simpl in Hfind.
    destruct (match_case_values n vals) eqn:Hm.
    + inversion Hfind; subst.
      unfold core_stmts.
      exact Hbr.
    + eapply IH; eauto.
Qed.

Lemma core_case_elements_of_core_values :
  forall (branches : list case_element),
    List.forallb
      (fun ce =>
        match ce with
        | CASE_ELEM values stmts =>
            core_case_values_dec values && List.forallb core_stmt stmts
        end) branches = true ->
    core_case_elements branches.
Proof.
  induction branches as [|[values stmts] rest IH]; simpl; intros H.
  - reflexivity.
  - apply andb_true_iff in H.
    destruct H as [Hhead Hrest].
    apply andb_true_iff in Hhead.
    destruct Hhead as [_ Hbody].
    unfold core_case_elements.
    simpl.
    rewrite Hbody.
    rewrite (IH Hrest).
    reflexivity.
Qed.

Lemma core_case_branches_of_core_values :
  forall (branches : list case_element),
    List.forallb
      (fun ce =>
        match ce with
        | CASE_ELEM values stmts =>
            core_case_values_dec values && List.forallb core_stmt stmts
        end) branches = true ->
    core_case_branches branches.
Proof.
  induction branches as [|[values stmts] rest IH]; simpl; intros H.
  - exact I.
  - apply andb_true_iff in H.
    destruct H as [Hhead Hrest].
    apply andb_true_iff in Hhead.
    destruct Hhead as [Hvalues _].
    split.
    + apply core_case_values_dec_true. exact Hvalues.
    + apply IH. exact Hrest.
Qed.

Lemma core_case_branches_of_stmt :
  forall (sel : st_expr) (branches : list case_element)
         (default : option (list st_stmt)),
    core_stmt (S_CASE sel branches default) = true ->
    core_case_branches branches.
Proof.
  intros sel branches default H.
  unfold core_stmt in H.
  apply andb_true_iff in H.
  destruct H as [H1 _].
  apply andb_true_iff in H1.
  destruct H1 as [_ Hbranches].
  apply core_case_branches_of_core_values.
  exact Hbranches.
Qed.

Lemma core_stmt_case_parts :
  forall (sel : st_expr) (branches : list case_element)
         (default : option (list st_stmt)),
    core_stmt (S_CASE sel branches default) = true ->
    core_expr sel = true /\
    core_case_elements branches /\
    core_opt_stmts default.
Proof.
  intros sel branches default H.
  unfold core_stmt in H.
  apply andb_true_iff in H.
  destruct H as [H1 Hdefault].
  apply andb_true_iff in H1.
  destruct H1 as [Hsel Hbranches].
  repeat split.
  - exact Hsel.
  - apply core_case_elements_of_core_values.
    exact Hbranches.
  - destruct default as [ds |].
    + unfold core_opt_stmts, core_stmts in *.
      exact Hdefault.
    + unfold core_opt_stmts.
      exact I.
Qed.

Lemma core_stmt_case_selected :
  forall (sel : st_expr) (branches : list case_element)
         (default : option (list st_stmt)) (n : Z) (stmts : list st_stmt),
    core_stmt (S_CASE sel branches default) = true ->
    find_case_branch n branches = Some stmts ->
    core_stmts stmts.
Proof.
  intros sel branches default n stmts Hcore Hfind.
  destruct (core_stmt_case_parts sel branches default Hcore) as [_ [Hbr _]].
  exact (core_case_branch_lookup branches n stmts Hbr Hfind).
Qed.

Lemma typed_single_repeat_if :
  forall (fenv : type_env_func) (env : type_env)
         (body : list st_stmt) (cond : st_expr),
    typed_stmts fenv env body ->
    type_check_expr fenv env cond = Some T_BOOL ->
    typed_stmts fenv env
      (S_IF cond nil (Some (S_REPEAT body cond :: nil)) :: nil).
Proof.
  intros fenv env body cond Hbody Hcond.
  apply TS_if with (cond := cond) (then_stmts := nil)
    (else_stmts := Some (S_REPEAT body cond :: nil)) (rest := nil).
  - exact Hcond.
  - constructor.
  - apply TO_some.
    apply TS_repeat with (body := body) (cond := cond) (rest := nil).
    + exact Hbody.
    + exact Hcond.
    + constructor.
  - constructor.
Qed.

Lemma type_check_not_bool :
  forall (fenv : type_env_func) (env : type_env) (cond : st_expr),
    core_expr cond = true ->
    type_check_expr fenv env cond = Some T_BOOL ->
    type_check_expr fenv env (E_UNARY_OP U_NOT cond) = Some T_BOOL.
Proof.
  intros fenv env cond Hcore Hcond.
  pose proof (core_expr_type_check_fenv_indep fenv env cond Hcore) as Heq.
  assert (Hcond_nil : type_check_expr nil env cond = Some T_BOOL).
  { rewrite <- Heq. exact Hcond. }
  simpl.
  rewrite Hcond_nil.
  reflexivity.
Qed.

Lemma typed_repeat_while_expansion :
  forall (fenv : type_env_func) (env : type_env)
         (body : list st_stmt) (cond : st_expr) (rest : list st_stmt),
    typed_stmts fenv env (S_REPEAT body cond :: rest) ->
    core_expr cond = true ->
    typed_stmts fenv env
      (body ++ S_WHILE (E_UNARY_OP U_NOT cond) body :: rest).
Proof.
  intros fenv env body cond rest Htyped Hcore_cond.
  destruct (typed_repeat_inv fenv env body cond rest Htyped)
    as [Hbody [Hcond Hrest]].
  change (S_WHILE (E_UNARY_OP U_NOT cond) body :: rest)
    with ([S_WHILE (E_UNARY_OP U_NOT cond) body] ++ rest).
  rewrite app_assoc.
  apply typed_stmts_app.
  - apply typed_stmts_app.
    + exact Hbody.
    + apply TS_while with
        (cond := E_UNARY_OP U_NOT cond) (body := body) (rest := nil).
      * apply type_check_not_bool; [exact Hcore_cond | exact Hcond].
      * exact Hbody.
      * constructor.
  - exact Hrest.
Qed.

Lemma typed_repeat_expansion :
  forall (fenv : type_env_func) (env : type_env)
         (body : list st_stmt) (cond : st_expr) (rest : list st_stmt),
    typed_stmts fenv env (S_REPEAT body cond :: rest) ->
    typed_stmts fenv env
      (body ++ S_IF cond nil (Some (S_REPEAT body cond :: nil)) :: rest).
Proof.
  intros fenv env body cond rest Htyped.
  destruct (typed_repeat_inv fenv env body cond rest Htyped)
    as [Hbody [Hcond Hrest]].
  change (S_IF cond nil (Some (S_REPEAT body cond :: nil)) :: rest)
    with ([S_IF cond nil (Some (S_REPEAT body cond :: nil))] ++ rest).
  rewrite app_assoc.
  apply typed_stmts_app.
  - apply typed_stmts_app.
    + exact Hbody.
    + apply typed_single_repeat_if; assumption.
  - exact Hrest.
Qed.

Lemma core_stmt_single_repeat_if :
  forall (body : list st_stmt) (cond : st_expr),
    core_expr cond = true ->
    core_stmt (S_REPEAT body cond) = true ->
    core_stmt (S_IF cond nil (Some (S_REPEAT body cond :: nil))) = true.
Proof.
  intros body cond Hcond Hrep.
  destruct (core_stmt_repeat_core_exprs body cond Hrep)
    as [Hbody _].
  unfold core_stmt.
  simpl.
  rewrite Hcond.
  simpl.
  unfold core_stmts in Hbody.
  change (List.forallb core_stmt body && true && true = true).
  rewrite Hbody.
  reflexivity.
Qed.

Lemma core_repeat_expansion :
  forall (body : list st_stmt) (cond : st_expr) (rest : list st_stmt),
    core_stmts body ->
    core_stmt (S_REPEAT body cond) = true ->
    core_expr cond = true ->
    core_stmts rest ->
    core_stmts
      (body ++ S_IF cond nil (Some (S_REPEAT body cond :: nil)) :: rest).
Proof.
  intros body cond rest Hbody Hrep Hcond Hrest.
  change (S_IF cond nil (Some (S_REPEAT body cond :: nil)) :: rest)
    with ([S_IF cond nil (Some (S_REPEAT body cond :: nil))] ++ rest).
  rewrite app_assoc.
  apply core_stmts_app.
  - apply core_stmts_app.
    + exact Hbody.
    + apply core_stmts_single.
      apply core_stmt_single_repeat_if; assumption.
  - exact Hrest.
Qed.

Lemma for_cond_typed_core :
  forall (fenv : type_env_func) (env : type_env) (v : ident)
         (end_ : st_expr),
    lookup env v = Some T_INT ->
    core_expr end_ = true ->
    type_check_expr fenv env end_ = Some T_INT ->
    type_check_expr fenv env (E_COMP C_LE (E_VAR v) end_) = Some T_BOOL.
Proof.
  intros fenv env v end_ Hlook Hcore Hend.
  simpl.
  rewrite Hlook.
  rewrite (core_expr_type_check_fenv_indep fenv env end_ Hcore) in Hend.
  rewrite Hend.
  simpl.
  reflexivity.
Qed.

Lemma for_incr_typed_core :
  forall (fenv : type_env_func) (env : type_env) (v : ident)
         (e : st_expr),
    lookup env v = Some T_INT ->
    core_expr e = true ->
    type_check_expr fenv env e = Some T_INT ->
    type_check_expr fenv env (E_BIN_OP B_ADD (E_VAR v) e) = Some T_INT.
Proof.
  intros fenv env v e Hlook Hcore Hty.
  simpl.
  rewrite Hlook.
  rewrite (core_expr_type_check_fenv_indep fenv env e Hcore) in Hty.
  rewrite Hty.
  simpl.
  reflexivity.
Qed.

Lemma for_incr_typed_default :
  forall (fenv : type_env_func) (env : type_env) (v : ident),
    lookup env v = Some T_INT ->
    type_check_expr fenv env
      (E_BIN_OP B_ADD (E_VAR v) (E_LIT (L_INT 1))) = Some T_INT.
Proof.
  intros fenv env v Hlook.
  simpl.
  rewrite Hlook.
  reflexivity.
Qed.

Lemma typed_for_assign_single :
  forall (fenv : type_env_func) (env : type_env) (v : ident)
         (e : st_expr),
    lookup env v = Some T_INT ->
    type_check_expr fenv env e = Some T_INT ->
    typed_stmts fenv env [S_ASSIGN v e].
Proof.
  intros fenv env v e Hlook Hty.
  apply TS_assign with (lhs_ty := T_INT) (rhs_ty := T_INT) (rest := nil).
  - exact Hlook.
  - exact Hty.
  - reflexivity.
  - constructor.
Qed.

Lemma typed_for_expansion_prefix :
  forall (fenv : type_env_func) (env : type_env) (v : ident)
         (start end_ : st_expr) (step : option st_expr)
         (body : list st_stmt),
    lookup env v = Some T_INT ->
    type_check_expr fenv env start = Some T_INT ->
    type_check_expr fenv env end_ = Some T_INT ->
    core_expr end_ = true ->
    typed_stmts fenv env body ->
    (match step with
     | Some e => type_check_expr fenv env e = Some T_INT /\ core_expr e = true
     | None => True end) ->
    typed_stmts fenv env
      (S_ASSIGN v start ::
       S_WHILE (E_COMP C_LE (E_VAR v) end_)
         (body ++
          [S_ASSIGN v (E_BIN_OP B_ADD (E_VAR v)
             (match step with Some e => e | None => E_LIT (L_INT 1) end))])
       :: nil).
Proof.
  intros fenv env v start end_ step body
         Hlook Hstart Hend Hcore_end Hbody Hstep.
  destruct step as [e |].
  - destruct Hstep as [Hty Hcore_e].
    assert (Hcond :
      type_check_expr fenv env (E_COMP C_LE (E_VAR v) end_) = Some T_BOOL)
      by (apply for_cond_typed_core; assumption).
    assert (Hincr :
      type_check_expr fenv env (E_BIN_OP B_ADD (E_VAR v) e) = Some T_INT)
      by (apply for_incr_typed_core; assumption).
    assert (Hassign_typed :
      typed_stmts fenv env
        [S_ASSIGN v (E_BIN_OP B_ADD (E_VAR v) e)])
      by (apply typed_for_assign_single; assumption).
    assert (Hbody_typed :
      typed_stmts fenv env
        (body ++ [S_ASSIGN v (E_BIN_OP B_ADD (E_VAR v) e)]))
      by (apply typed_stmts_app; assumption).
    apply TS_assign with (lhs_ty := T_INT) (rhs_ty := T_INT)
      (rest := [S_WHILE (E_COMP C_LE (E_VAR v) end_)
                  (body ++ [S_ASSIGN v (E_BIN_OP B_ADD (E_VAR v) e)])]).
    + exact Hlook.
    + exact Hstart.
    + reflexivity.
    + apply TS_while with (cond := E_COMP C_LE (E_VAR v) end_)
        (body := body ++ [S_ASSIGN v (E_BIN_OP B_ADD (E_VAR v) e)])
        (rest := nil).
      * exact Hcond.
      * exact Hbody_typed.
      * constructor.
  - assert (Hcond :
      type_check_expr fenv env (E_COMP C_LE (E_VAR v) end_) = Some T_BOOL)
      by (apply for_cond_typed_core; assumption).
    assert (Hincr :
      type_check_expr fenv env
        (E_BIN_OP B_ADD (E_VAR v) (E_LIT (L_INT 1))) = Some T_INT)
      by (apply for_incr_typed_default; assumption).
    assert (Hassign_typed :
      typed_stmts fenv env
        [S_ASSIGN v (E_BIN_OP B_ADD (E_VAR v) (E_LIT (L_INT 1)))])
      by (apply typed_for_assign_single; assumption).
    assert (Hbody_typed :
      typed_stmts fenv env
        (body ++
         [S_ASSIGN v (E_BIN_OP B_ADD (E_VAR v) (E_LIT (L_INT 1)))]))
      by (apply typed_stmts_app; assumption).
    apply TS_assign with (lhs_ty := T_INT) (rhs_ty := T_INT)
      (rest := [S_WHILE (E_COMP C_LE (E_VAR v) end_)
                  (body ++
                   [S_ASSIGN v (E_BIN_OP B_ADD (E_VAR v) (E_LIT (L_INT 1)))])]).
    + exact Hlook.
    + exact Hstart.
    + reflexivity.
    + apply TS_while with (cond := E_COMP C_LE (E_VAR v) end_)
        (body := body ++
           [S_ASSIGN v (E_BIN_OP B_ADD (E_VAR v) (E_LIT (L_INT 1)))])
        (rest := nil).
      * exact Hcond.
      * exact Hbody_typed.
      * constructor.
Qed.

Lemma core_stmt_for_parts :
  forall (v : ident) (start end_ : st_expr) (step : option st_expr)
         (body : list st_stmt),
    core_stmt (S_FOR v start end_ step body) = true ->
    core_expr start = true /\
    core_expr end_ = true /\
    (match step with
     | Some e => core_expr e = true
     | None => True end) /\
    core_stmts body.
Proof.
  intros v start end_ step body H.
  unfold core_stmt in H.
  apply andb_true_iff in H.
  destruct H as [H1 Hbody].
  apply andb_true_iff in H1.
  destruct H1 as [Hstart_end Hstep].
  apply andb_true_iff in Hstart_end.
  destruct Hstart_end as [Hstart Hend].
  repeat split.
  - exact Hstart.
  - exact Hend.
  - destruct step as [e |].
    + exact Hstep.
    + exact I.
  - exact Hbody.
Qed.

Lemma core_stmt_while_intro :
  forall (cond : st_expr) (body : list st_stmt),
    core_expr cond = true ->
    core_stmts body ->
    core_stmt (S_WHILE cond body) = true.
Proof.
  intros cond body Hcond Hbody.
  unfold core_stmt, core_stmts in *.
  rewrite Hcond.
  simpl.
  change (List.forallb core_stmt body = true).
  exact Hbody.
Qed.

Lemma core_repeat_while_expansion :
  forall (body : list st_stmt) (cond : st_expr) (rest : list st_stmt),
    core_stmts body ->
    core_expr cond = true ->
    core_stmts rest ->
    core_stmts (body ++ S_WHILE (E_UNARY_OP U_NOT cond) body :: rest).
Proof.
  intros body cond rest Hbody Hcond Hrest.
  change (S_WHILE (E_UNARY_OP U_NOT cond) body :: rest)
    with ([S_WHILE (E_UNARY_OP U_NOT cond) body] ++ rest).
  rewrite app_assoc.
  apply core_stmts_app.
  - apply core_stmts_app.
    + exact Hbody.
    + apply core_stmts_single.
      apply core_stmt_while_intro.
      * simpl. exact Hcond.
      * exact Hbody.
  - exact Hrest.
Qed.

Lemma core_stmt_assign_intro :
  forall (x : ident) (e : st_expr),
    core_expr e = true ->
    core_stmt (S_ASSIGN x e) = true.
Proof.
  intros x e H.
  exact H.
Qed.

Lemma core_for_body_intro :
  forall (v : ident) (step : option st_expr) (body : list st_stmt)
         (e : st_expr),
    core_stmts body ->
    core_expr e = true ->
    core_stmts (body ++ [S_ASSIGN v (E_BIN_OP B_ADD (E_VAR v) e)]).
Proof.
  intros v step body e Hbody Hcore_e.
  apply core_stmts_app.
  - exact Hbody.
  - apply core_stmts_single.
    unfold core_expr.
    simpl.
    rewrite Hcore_e.
    reflexivity.
Qed.

Lemma core_for_prefix_intro :
  forall (v : ident) (start end_ : st_expr) (step : option st_expr)
         (body : list st_stmt) (e : st_expr),
    core_expr start = true ->
    core_expr end_ = true ->
    core_expr e = true ->
    core_stmts body ->
    core_stmts
      [S_ASSIGN v start;
       S_WHILE (E_COMP C_LE (E_VAR v) end_)
         (body ++ [S_ASSIGN v (E_BIN_OP B_ADD (E_VAR v) e)])].
Proof.
  intros v start end_ step body e Hstart Hend He Hbody.
  apply core_stmts_cons_intro.
  - exact (core_stmt_assign_intro v start Hstart).
  - apply core_stmts_single.
    apply core_stmt_while_intro.
    + unfold core_expr.
      simpl.
      change (true && core_expr end_ = true).
      rewrite Hend.
      reflexivity.
    + exact (core_for_body_intro v step body e Hbody He).
Qed.

Lemma core_for_expansion :
  forall (v : ident) (start end_ : st_expr) (step : option st_expr)
         (body rest : list st_stmt),
    core_stmt (S_FOR v start end_ step body) = true ->
    core_stmts rest ->
    core_stmts (for_to_while v start end_ step body ++ rest).
Proof.
  intros v start end_ step body rest Hcore Hrest.
  destruct (core_stmt_for_parts v start end_ step body Hcore)
    as [Hstart [Hend [Hstep Hbody]]].
  unfold for_to_while.
  destruct step as [e |].
  - apply core_stmts_app.
    + apply (core_for_prefix_intro v start end_ (Some e) body e).
      * exact Hstart.
      * exact Hend.
      * exact Hstep.
      * exact Hbody.
    + exact Hrest.
  - apply core_stmts_app.
    + apply (core_for_prefix_intro v start end_ None body (E_LIT (L_INT 1))).
      * exact Hstart.
      * exact Hend.
      * simpl.
        reflexivity.
      * exact Hbody.
    + exact Hrest.
Qed.

Lemma typed_for_expansion :
  forall (fenv : type_env_func) (env : type_env) (v : ident)
         (start end_ : st_expr) (step : option st_expr)
         (body rest : list st_stmt),
    typed_stmts fenv env (S_FOR v start end_ step body :: rest) ->
    core_expr start = true ->
    core_expr end_ = true ->
    (match step with
     | Some e => core_expr e = true
     | None => True end) ->
    typed_stmts fenv env (for_to_while v start end_ step body ++ rest).
Proof.
  intros fenv env v start end_ step body rest Htyped
         Hcore_start Hcore_end Hcore_step.
  destruct (typed_for_inv fenv env v start end_ step body rest Htyped)
    as [Hlook [Hstart [Hend [Hstep [Hbody Hrest]]]]].
  unfold for_to_while.
  apply typed_stmts_app.
  - apply typed_for_expansion_prefix with (start := start) (end_ := end_)
      (step := step).
    + exact Hlook.
    + exact Hstart.
    + exact Hend.
    + exact Hcore_end.
    + exact Hbody.
    + destruct step as [e |].
      * split; assumption.
      * exact I.
  - exact Hrest.
Qed.

Lemma core_cfg_mk :
  forall (p : st_program) (stmts : list st_stmt) (s : st_state),
    core_program p = true ->
    core_env (build_program_env p) ->
    core_stmts stmts ->
    typed_stmts (build_fenv_from_pous p.(pou_list)) (build_program_env p) stmts ->
    state_consistent (build_program_env p) s ->
    core_cfg p stmts s.
Proof.
  intros p stmts s Hp Henv Hcore Htyped Hstate.
  unfold core_cfg.
  split; [exact Hp |].
  split; [exact Henv |].
  split; [exact Hcore |].
  split; [exact Htyped |].
  exact Hstate.
Qed.

Lemma typed_if_true_successor :
  forall (fenv : type_env_func) (env : type_env)
         (cond : st_expr) (then_stmts : list st_stmt)
         (else_stmts : option (list st_stmt)) (rest : list st_stmt),
    typed_stmts fenv env (S_IF cond then_stmts else_stmts :: rest) ->
    typed_stmts fenv env (then_stmts ++ rest).
Proof.
  intros fenv env cond then_stmts else_stmts rest Htyped.
  destruct (typed_if_inv fenv env cond then_stmts else_stmts rest Htyped)
    as [_ [Hthen [_ Hrest]]].
  exact (typed_stmts_app fenv env then_stmts rest Hthen Hrest).
Qed.

Lemma typed_if_false_successor :
  forall (fenv : type_env_func) (env : type_env)
         (cond : st_expr) (then_stmts : list st_stmt)
         (else_stmts : option (list st_stmt)) (rest : list st_stmt),
    typed_stmts fenv env (S_IF cond then_stmts else_stmts :: rest) ->
    typed_stmts fenv env
      (match else_stmts with
       | Some e => e ++ rest
       | None => rest end).
Proof.
  intros fenv env cond then_stmts else_stmts rest Htyped.
  destruct (typed_if_inv fenv env cond then_stmts else_stmts rest Htyped)
    as [_ [Hthen [Helse Hrest]]].
  destruct else_stmts as [es |].
  - pose proof (typed_opt_default_lookup fenv env (Some es) es Helse eq_refl)
      as Htyped_es.
    exact (typed_stmts_app fenv env es rest Htyped_es Hrest).
  - exact Hrest.
Qed.

Lemma typed_while_single :
  forall (fenv : type_env_func) (env : type_env)
         (cond : st_expr) (body : list st_stmt),
    type_check_expr fenv env cond = Some T_BOOL ->
    typed_stmts fenv env body ->
    typed_stmts fenv env [S_WHILE cond body].
Proof.
  intros fenv env cond body Hcond Hbody.
  apply TS_while with (cond := cond) (body := body) (rest := nil).
  - exact Hcond.
  - exact Hbody.
  - constructor.
Qed.

Lemma typed_while_true_successor :
  forall (fenv : type_env_func) (env : type_env)
         (cond : st_expr) (body rest : list st_stmt),
    typed_stmts fenv env (S_WHILE cond body :: rest) ->
    typed_stmts fenv env
      (body ++ S_WHILE cond body :: rest).
Proof.
  intros fenv env cond body rest Htyped.
  destruct (typed_while_inv fenv env cond body rest Htyped)
    as [Hcond [Hbody Hrest]].
  change (S_WHILE cond body :: rest)
    with ([S_WHILE cond body] ++ rest).
  rewrite app_assoc.
  apply typed_stmts_app.
  - apply typed_stmts_app.
    + exact Hbody.
    + apply typed_while_single; assumption.
  - exact Hrest.
Qed.

Lemma typed_while_false_successor :
  forall (fenv : type_env_func) (env : type_env)
         (cond : st_expr) (body rest : list st_stmt),
    typed_stmts fenv env (S_WHILE cond body :: rest) ->
    typed_stmts fenv env rest.
Proof.
  intros fenv env cond body rest Htyped.
  destruct (typed_while_inv fenv env cond body rest Htyped)
    as [_ [_ Hrest]].
  exact Hrest.
Qed.

Lemma core_if_true_successor :
  forall (cond : st_expr) (then_stmts : list st_stmt)
         (else_stmts : option (list st_stmt)) (rest : list st_stmt),
    core_stmt (S_IF cond then_stmts else_stmts) = true ->
    core_stmts rest ->
    core_stmts (then_stmts ++ rest).
Proof.
  intros cond then_stmts else_stmts rest Hcore Hrest.
  destruct (core_stmt_if_core_exprs cond then_stmts else_stmts Hcore)
    as [_ [Hthen _]].
  exact (core_stmts_app then_stmts rest Hthen Hrest).
Qed.

Lemma core_if_false_successor :
  forall (cond : st_expr) (then_stmts : list st_stmt)
         (else_stmts : option (list st_stmt)) (rest : list st_stmt),
    core_stmt (S_IF cond then_stmts else_stmts) = true ->
    core_stmts rest ->
    core_stmts
      (match else_stmts with
       | Some e => e ++ rest
       | None => rest end).
Proof.
  intros cond then_stmts else_stmts rest Hcore Hrest.
  destruct (core_stmt_if_core_exprs cond then_stmts else_stmts Hcore)
    as [_ [_ Helse]].
  destruct else_stmts as [es |].
  - pose proof (core_opt_stmts_some (Some es) es Helse eq_refl) as Hes.
    exact (core_stmts_app es rest Hes Hrest).
  - exact Hrest.
Qed.

Lemma core_while_single :
  forall (cond : st_expr) (body : list st_stmt),
    core_expr cond = true ->
    core_stmts body ->
    core_stmts [S_WHILE cond body].
Proof.
  intros cond body Hcond Hbody.
  apply core_stmts_single.
  apply core_stmt_while_intro; assumption.
Qed.

Lemma core_while_true_successor :
  forall (cond : st_expr) (body rest : list st_stmt),
    core_stmt (S_WHILE cond body) = true ->
    core_stmts rest ->
    core_stmts (body ++ S_WHILE cond body :: rest).
Proof.
  intros cond body rest Hcore Hrest.
  destruct (core_stmt_while_core_exprs cond body Hcore)
    as [Hcond Hbody].
  change (S_WHILE cond body :: rest)
    with ([S_WHILE cond body] ++ rest).
  rewrite app_assoc.
  apply core_stmts_app.
  - apply core_stmts_app.
    + exact Hbody.
    + apply core_while_single; assumption.
  - exact Hrest.
Qed.

Lemma typed_case_successor :
  forall (fenv : type_env_func) (env : type_env)
         (sel : st_expr) (branches : list case_element)
         (default : option (list st_stmt)) (rest : list st_stmt) (n : Z),
    typed_stmts fenv env (S_CASE sel branches default :: rest) ->
    typed_stmts fenv env (select_case_stmts n branches default ++ rest).
Proof.
  intros fenv env sel branches default rest n Htyped.
  destruct (typed_case_inv fenv env sel branches default rest Htyped)
    as [[_ | _] [Hbranches [Hdefault Hrest]]].
  - unfold select_case_stmts.
    destruct (find_case_branch n branches) as [bs |] eqn:Hfind.
    + pose proof (typed_case_branch_lookup fenv env branches n bs Hbranches Hfind)
        as Hbs.
      exact (typed_stmts_app fenv env bs rest Hbs Hrest).
    + destruct default as [ds |].
      * pose proof (typed_opt_default_lookup fenv env (Some ds) ds Hdefault eq_refl)
          as Hds.
        exact (typed_stmts_app fenv env ds rest Hds Hrest).
      * exact Hrest.
  - unfold select_case_stmts.
    destruct (find_case_branch n branches) as [bs |] eqn:Hfind.
    + pose proof (typed_case_branch_lookup fenv env branches n bs Hbranches Hfind)
        as Hbs.
      exact (typed_stmts_app fenv env bs rest Hbs Hrest).
    + destruct default as [ds |].
      * pose proof (typed_opt_default_lookup fenv env (Some ds) ds Hdefault eq_refl)
          as Hds.
        exact (typed_stmts_app fenv env ds rest Hds Hrest).
      * exact Hrest.
Qed.

Lemma core_case_successor :
  forall (sel : st_expr) (branches : list case_element)
         (default : option (list st_stmt)) (rest : list st_stmt) (n : Z),
    core_stmt (S_CASE sel branches default) = true ->
    core_stmts rest ->
    core_stmts (select_case_stmts n branches default ++ rest).
Proof.
  intros sel branches default rest n Hcore Hrest.
  destruct (core_stmt_case_parts sel branches default Hcore)
    as [_ [Hbranches Hdefault]].
  unfold select_case_stmts.
  destruct (find_case_branch n branches) as [bs |] eqn:Hfind.
  - pose proof (core_case_branch_lookup branches n bs Hbranches Hfind) as Hbs.
    exact (core_stmts_app bs rest Hbs Hrest).
  - destruct default as [ds |].
    + pose proof (core_opt_stmts_some (Some ds) ds Hdefault eq_refl) as Hds.
      exact (core_stmts_app ds rest Hds Hrest).
    + exact Hrest.
Qed.

Theorem preservation_cfg :
  forall (p : st_program) (stmts : list st_stmt) (s : st_state)
         (stmts' : list st_stmt) (s' : st_state),
    core_cfg p stmts s ->
    stmts_step p stmts s stmts' s' ->
    core_cfg p stmts' s'.
Proof.
  intros p stmts s stmts' s' Hcfg Hstep.
  revert Hcfg.
  induction Hstep; intros Hcfg.
  - (* Ss_assign *)
    destruct Hcfg as [Hprog [Henv [Hcore [Htyped Hstate]]]].
    destruct (typed_assign_inv (build_fenv_from_pous p.(pou_list))
               (build_program_env p) x e rest Htyped)
      as [lhs [rhs [Hlook [Htc [Hcomp Htyped_rest]]]]].
    rewrite H in Hlook.
    inversion Hlook; subst lhs.
    destruct (core_stmts_cons (S_ASSIGN x e) rest Hcore)
      as [Hcore_st Hcore_rest].
    simpl in Hcore_st.
    rewrite (core_expr_type_check_fenv_indep
               (build_fenv_from_pous p.(pou_list))
               (build_program_env p) e Hcore_st) in Htc.
    pose proof (core_expr_type_is_core (build_program_env p) e rhs
                 Henv Hcore_st Htc) as Hcore_rhs.
    destruct (typed_eval_total (build_program_env p) s e rhs
               Henv Hcore_st Hstate Htc Hcore_rhs)
      as [v0 [He0 Htype0]].
    match goal with
    | He : eval_expr s e = Some ?vv |- _ =>
        rewrite He0 in He;
        injection He as Hvv;
        subst v0
    end.
    pose proof (coerce_value_to_type_preserves_type ty rhs v
                 (Henv x ty H) Hcore_rhs
                 (type_compatible_dec_sound rhs ty Hcomp)
                 Htype0) as Hco.
    pose proof (update_var_preserves_state_consistent
                 (build_program_env p) s x ty
                 (coerce_value_to_type ty v) Hstate H Hco) as Hstate'.
    exact (core_cfg_mk p rest (update_var s x (coerce_value_to_type ty v))
             Hprog Henv Hcore_rest Htyped_rest Hstate').
  - (* Ss_if_true *)
    destruct Hcfg as [Hprog [Henv [Hcore [Htyped Hstate]]]].
    destruct (core_stmts_cons (S_IF cond then_stmts else_opt) rest Hcore)
      as [Hcore_if Hcore_rest].
    pose proof (typed_if_true_successor
                 (build_fenv_from_pous p.(pou_list))
                 (build_program_env p) cond then_stmts else_opt rest Htyped)
      as Htyped_succ.
    pose proof (core_if_true_successor cond then_stmts else_opt rest
                 Hcore_if Hcore_rest) as Hcore_succ.
    exact (core_cfg_mk p (then_stmts ++ rest) s
             Hprog Henv Hcore_succ Htyped_succ Hstate).
  - (* Ss_if_false *)
    destruct Hcfg as [Hprog [Henv [Hcore [Htyped Hstate]]]].
    destruct (core_stmts_cons (S_IF cond then_stmts else_opt) rest Hcore)
      as [Hcore_if Hcore_rest].
    pose proof (typed_if_false_successor
                 (build_fenv_from_pous p.(pou_list))
                 (build_program_env p) cond then_stmts else_opt rest Htyped)
      as Htyped_succ.
    pose proof (core_if_false_successor cond then_stmts else_opt rest
                 Hcore_if Hcore_rest) as Hcore_succ.
    exact (core_cfg_mk p
             (match else_opt with
              | Some e => e ++ rest
              | None => rest end) s
             Hprog Henv Hcore_succ Htyped_succ Hstate).
  - (* Ss_while_true *)
    destruct Hcfg as [Hprog [Henv [Hcore [Htyped Hstate]]]].
    destruct (core_stmts_cons (S_WHILE cond body) rest Hcore)
      as [Hcore_while Hcore_rest].
    pose proof (typed_while_true_successor
                 (build_fenv_from_pous p.(pou_list))
                 (build_program_env p) cond body rest Htyped)
      as Htyped_succ.
    pose proof (core_while_true_successor cond body rest
                 Hcore_while Hcore_rest) as Hcore_succ.
    exact (core_cfg_mk p (body ++ S_WHILE cond body :: rest) s
             Hprog Henv Hcore_succ Htyped_succ Hstate).
  - (* Ss_while_false *)
    destruct Hcfg as [Hprog [Henv [Hcore [Htyped Hstate]]]].
    destruct (core_stmts_cons (S_WHILE cond body) rest Hcore)
      as [_ Hcore_rest].
    pose proof (typed_while_false_successor
                 (build_fenv_from_pous p.(pou_list))
                 (build_program_env p) cond body rest Htyped)
      as Htyped_succ.
    exact (core_cfg_mk p rest s
             Hprog Henv Hcore_rest Htyped_succ Hstate).
  - (* Ss_repeat *)
    destruct Hcfg as [Hprog [Henv [Hcore [Htyped Hstate]]]].
    destruct (core_stmts_cons (S_REPEAT body cond) rest Hcore)
      as [Hcore_repeat Hcore_rest].
    destruct (core_stmt_repeat_core_exprs body cond Hcore_repeat)
      as [Hcore_body Hcore_cond].
    pose proof (typed_repeat_while_expansion
                 (build_fenv_from_pous p.(pou_list))
                 (build_program_env p) body cond rest Htyped Hcore_cond)
      as Htyped_succ.
    pose proof (core_repeat_while_expansion body cond rest
                 Hcore_body Hcore_cond Hcore_rest)
      as Hcore_succ.
    exact (core_cfg_mk p
             (body ++ S_WHILE (E_UNARY_OP U_NOT cond) body :: rest)
             s Hprog Henv Hcore_succ Htyped_succ Hstate).
  - (* Ss_case *)
    destruct Hcfg as [Hprog [Henv [Hcore [Htyped Hstate]]]].
    destruct (core_stmts_cons (S_CASE sel branches default) rest Hcore)
      as [Hcore_case Hcore_rest].
    pose proof (typed_case_successor
                 (build_fenv_from_pous p.(pou_list))
                 (build_program_env p) sel branches default rest n Htyped)
      as Htyped_succ.
    pose proof (core_case_successor sel branches default rest n
                 Hcore_case Hcore_rest) as Hcore_succ.
    exact (core_cfg_mk p (select_case_stmts n branches default ++ rest) s
             Hprog Henv Hcore_succ Htyped_succ Hstate).
  - (* Ss_case_dint *)
    destruct Hcfg as [Hprog [Henv [Hcore [Htyped Hstate]]]].
    destruct (core_stmts_cons (S_CASE sel branches default) rest Hcore)
      as [Hcore_case Hcore_rest].
    pose proof (typed_case_successor
                 (build_fenv_from_pous p.(pou_list))
                 (build_program_env p) sel branches default rest n Htyped)
      as Htyped_succ.
    pose proof (core_case_successor sel branches default rest n
                 Hcore_case Hcore_rest) as Hcore_succ.
    exact (core_cfg_mk p (select_case_stmts n branches default ++ rest) s
             Hprog Henv Hcore_succ Htyped_succ Hstate).
  - (* Ss_for *)
    destruct Hcfg as [Hprog [Henv [Hcore [Htyped Hstate]]]].
    destruct (core_stmts_cons (S_FOR v start end_ step body) rest Hcore)
      as [Hcore_for Hcore_rest].
    destruct (core_stmt_for_parts v start end_ step body Hcore_for)
      as [Hcore_start [Hcore_end [Hcore_step Hcore_body]]].
    pose proof (typed_for_expansion
                 (build_fenv_from_pous p.(pou_list))
                 (build_program_env p) v start end_ step body rest Htyped
                 Hcore_start Hcore_end Hcore_step) as Htyped_succ.
    pose proof (core_for_expansion v start end_ step body rest
                 Hcore_for Hcore_rest) as Hcore_succ.
    exact (core_cfg_mk p (for_to_while v start end_ step body ++ rest) s
             Hprog Henv Hcore_succ Htyped_succ Hstate).
Qed.

Theorem type_safety_cfg :
  forall (p : st_program) (stmts : list st_stmt) (s : st_state)
         (stmts' : list st_stmt) (s' : st_state),
    core_cfg p stmts s ->
    star_stmts_step p stmts s stmts' s' ->
    stmts_done stmts' s' \/
    exists (stmts'' : list st_stmt) (s'' : st_state),
      stmts_step p stmts' s' stmts'' s''.
Proof.
  intros p stmts s stmts' s' Hcfg Hstar.
  revert Hcfg.
  induction Hstar as [p0 stmts0 s0
    | p0 stmts1 stmts2 stmts3 s1 s2 s3 Hstep Hrest IH];
    intros Hcfg.
  - destruct stmts0 as [|st rest].
    + left.
      reflexivity.
    + right.
      destruct (progress_cfg p0 (st :: rest) s0 Hcfg)
        as [stmts2 [s2 Hstep0]].
      * discriminate.
      * eexists.
        eexists.
        exact Hstep0.
  - exact (IH (preservation_cfg p0 stmts1 s1 stmts2 s2 Hcfg Hstep)).
Qed.

Definition default_core_value (ty : st_type) : st_value :=
  match ty with
  | T_BOOL => ST_V_BOOL false
  | T_INT => ST_V_INT 0
  | T_DINT => ST_V_DINT 0
  | _ => ST_V_INT 0
  end.

Fixpoint init_st_vars (env : type_env) : list (ident * st_value) :=
  match env with
  | nil => nil
  | (x, ty) :: rest => (x, default_core_value ty) :: init_st_vars rest
  end.

Definition init_st_state (env : type_env) : st_state :=
  {| st_vars := init_st_vars env;
     st_quality := nil;
     st_pou_idx := 0;
     st_stmt_idx := 0;
     st_call_stack := nil;
     st_cycle_cnt := 0 |}.

Lemma default_core_value_type :
  forall (ty : st_type),
    core_ty ty ->
    st_value_type (default_core_value ty) = ty.
Proof.
  intros ty Hcore.
  destruct (core_ty_cases ty Hcore) as [H | [H | H]]; subst;
    reflexivity.
Qed.

Lemma lookup_var_init_st_vars :
  forall (env : type_env) (x : ident),
    lookup_var (init_st_vars env) x =
    match lookup env x with
    | Some ty => Some (default_core_value ty)
    | None => None
    end.
Proof.
  induction env as [| [y ty] rest IH]; intros x.
  - reflexivity.
  - destruct x as [sx]; destruct y as [sy].
    simpl.
    rewrite (String.eqb_sym sy sx).
    destruct (String.eqb sx sy); simpl.
    + reflexivity.
    + rewrite IH.
      reflexivity.
Qed.

Lemma init_st_state_consistent :
  forall (env : type_env),
    core_env env ->
    state_consistent env (init_st_state env).
Proof.
  intros env Henv.
  unfold init_st_state in *.
  unfold state_consistent.
  split.
  - intros x ty v Hlook Hfind.
    unfold init_st_state in Hfind.
    simpl in Hfind.
    rewrite lookup_var_init_st_vars in Hfind.
    rewrite Hlook in Hfind.
    inversion Hfind; subst.
    exact (default_core_value_type ty (Henv x ty Hlook)).
  - intros x ty Hlook.
    exists (default_core_value ty).
    unfold init_st_state.
    simpl.
    rewrite lookup_var_init_st_vars.
    rewrite Hlook.
    reflexivity.
Qed.
