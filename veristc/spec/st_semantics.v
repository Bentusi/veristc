(* ================================================================
   veristc/spec/st_semantics.v
   源语言语义层 — SafeST 操作语义与状态模型

   本文件只依赖 safest.v，提供源语言状态、求值与 step_st。
   
   依赖: safest.v
   ================================================================ *)

From Stdlib Require Import ZArith.
From Stdlib Require Import List.
From Stdlib Require Import Bool.
From Stdlib Require Import Floats.
From Stdlib Require Import String.
Local Open Scope Z_scope.
Require Import veristc_spec.safest.
Import ListNotations.

(* ================================================================
   第 1 部分：ST 语言的操作语义 (Operational Semantics of SafeST)
   ================================================================ *)

(* ST 运行时值 *)
Inductive st_value : Type :=
  | ST_V_BOOL : bool -> st_value
  | ST_V_BYTE : Z -> st_value | ST_V_WORD : Z -> st_value | ST_V_DWORD : Z -> st_value
  | ST_V_SINT : Z -> st_value | ST_V_INT : Z -> st_value | ST_V_DINT : Z -> st_value
 | ST_V_REAL : float -> st_value
 | ST_V_TIME : Z -> st_value
  | ST_V_LINT : Z -> st_value               (* 64 位有符号整数, v1.1 *)
  | ST_V_LREAL : float -> st_value          (* 64 位浮点, v1.1 *)
.

(* ST 运行时状态
   包含所有变量的当前值、当前执行位置、调用栈 *)
Record st_state : Type := {
  st_vars     : list (ident * st_value);   (* 所有变量的当前值 *)
  st_quality  : list (ident * Z);           (* 质量码映射: 0=GOOD,1=BAD, v1.1 *)
  st_pou_idx  : Z;                          (* 当前执行的 POU 索引 *)
  st_stmt_idx : Z;                          (* 当前语句索引 *)
  st_call_stack : list Z;                   (* 调用栈 *)
  st_cycle_cnt : Z;                         (* 周期计数 *)
}.

(* 二元整数运算辅助 *)
Definition eval_binop_int (op : binary_op) (n1 n2 : Z) : Z :=
  match op with
  | B_ADD => n1 + n2
  | B_SUB => n1 - n2
  | B_MUL => n1 * n2
  | B_DIV => if Z.eqb n2 0 then 0 else n1 / n2
  | B_MOD => if Z.eqb n2 0 then 0 else Z.rem n1 n2
  end.

(* 二元浮点运算辅助 *)
Definition eval_binop_float (op : binary_op) (f1 f2 : float) : float :=
  match op with
  | B_ADD => PrimFloat.add f1 f2
  | B_SUB => PrimFloat.sub f1 f2
  | B_MUL => PrimFloat.mul f1 f2
  | B_DIV => PrimFloat.div f1 f2
  | B_MOD => f1  (* 浮点无取模，简化为返回 f1 *)
  end.

(* 整数比较辅助 *)
Definition eval_compare_int (op : compare_op) (n1 n2 : Z) : bool :=
  match op with
  | C_EQ => Z.eqb n1 n2
  | C_NE => negb (Z.eqb n1 n2)
  | C_LT => Z.ltb n1 n2
  | C_LE => Z.leb n1 n2
  | C_GT => Z.ltb n2 n1
  | C_GE => Z.leb n2 n1
  end.

(* 浮点比较辅助 *)
Definition eval_compare_float (op : compare_op) (f1 f2 : float) : bool :=
  match op with
  | C_EQ => PrimFloat.eqb f1 f2
  | C_NE => negb (PrimFloat.eqb f1 f2)
  | C_LT => PrimFloat.ltb f1 f2
  | C_LE => PrimFloat.leb f1 f2
  | C_GT => PrimFloat.ltb f2 f1
  | C_GE => PrimFloat.leb f2 f1
  end.

(* 布尔比较辅助 *)
Definition eval_compare_bool (op : compare_op) (b1 b2 : bool) : bool :=
  match op with
  | C_EQ => Bool.eqb b1 b2
  | C_NE => negb (Bool.eqb b1 b2)
  | C_LT => negb b1 && b2
  | C_LE => negb b1 || b2
  | C_GT => b1 && negb b2
  | C_GE => b1 || negb b2
  end.

(* 辅助：从状态中查找变量值 *)
Fixpoint lookup_var (vars : list (ident * st_value)) (x : ident) {struct vars} : option st_value :=
  match vars with
  | nil => None
  | (y, v) :: rest =>
      if ident_eq x y then Some v
      else lookup_var rest x
  end.

(* 质量查找 (v1.1) *)
Fixpoint lookup_quality (quals : list (ident * Z)) (x : ident) {struct quals} : Z :=
  match quals with
  | nil => 0  (* 默认 GOOD *)
  | (y, q) :: rest =>
      if ident_eq x y then q else lookup_quality rest x
  end.

(* 质量更新 (v1.1) *)
Definition update_quality (s : st_state) (x : ident) (q : Z) : st_state :=
  {| st_vars := s.(st_vars);
     st_quality := (x, q) :: s.(st_quality);
     st_pou_idx := s.(st_pou_idx);
     st_stmt_idx := s.(st_stmt_idx);
     st_call_stack := s.(st_call_stack);
     st_cycle_cnt := s.(st_cycle_cnt) + 1;
  |}.

(* worst() 函数: 质量序 GOOD(0) < BAD(1) *)
Definition worst_quality (q1 q2 : Z) : Z := Z.max q1 q2.

(* 判断 st_value 是否为 64 位 (v1.1) *)
Definition is_64bit_value (v : st_value) : bool :=
  match v with
  | ST_V_LINT _ | ST_V_LREAL _ => true
  | _ => false
  end.

(* ST 表达式求值 *)

Fixpoint eval_expr (s : st_state) (e : st_expr) : option st_value :=
  match e with
  | E_LIT l =>
      match l with
      | L_INT n    => Some (ST_V_INT n)
      | L_REAL f   => Some (ST_V_REAL f)
      | L_BOOL b   => Some (ST_V_BOOL b)
      | L_TIME t   => Some (ST_V_TIME t)
      | L_LINT n   => Some (ST_V_LINT n)     (* v1.1 *)
      | L_LREAL f  => Some (ST_V_LREAL f)    (* v1.1 *)
      end

  | E_VAR x => lookup_var s.(st_vars) x

  | E_ARRAY_ACCESS arr idx =>
      match eval_expr s arr with
      | Some _ =>
          match eval_expr s idx with
          | Some (ST_V_INT _) => Some (ST_V_INT 0)
          | _ => None
          end
      | _ => None
      end

  | E_UNARY_OP op e1 =>
      match eval_expr s e1 with
      | Some v =>
          match op, v with
          | U_NEG, ST_V_INT n    => Some (ST_V_INT (- n))
          | U_NEG, ST_V_SINT n   => Some (ST_V_SINT (- n))
          | U_NEG, ST_V_DINT n   => Some (ST_V_DINT (- n))
          | U_NEG, ST_V_LINT n   => Some (ST_V_LINT (- n))    (* v1.1 *)
          | U_NEG, ST_V_REAL f   => Some (ST_V_REAL f)
          | U_NEG, ST_V_LREAL f  => Some (ST_V_LREAL f)  (* v1.1 *)
          | U_NOT, ST_V_BOOL b   => Some (ST_V_BOOL (negb b))
          | U_ABS, ST_V_INT n    => Some (ST_V_INT (Z.abs n))
          | U_ABS, ST_V_SINT n   => Some (ST_V_SINT (Z.abs n))
          | U_ABS, ST_V_DINT n   => Some (ST_V_DINT (Z.abs n))
          | U_ABS, ST_V_LINT n   => Some (ST_V_LINT (Z.abs n))   (* v1.1 *)
          | U_ABS, ST_V_REAL f   => Some (ST_V_REAL f)
          | U_ABS, ST_V_LREAL f  => Some (ST_V_LREAL f)          (* v1.1 *)
          | _, _ => None
          end
      | None => None
      end

  | E_BIN_OP op e1 e2 =>
      match eval_expr s e1, eval_expr s e2 with
      | Some (ST_V_INT n1), Some (ST_V_INT n2) =>
          Some (ST_V_INT (eval_binop_int op n1 n2))
      | Some (ST_V_DINT n1), Some (ST_V_DINT n2) =>
          Some (ST_V_DINT (eval_binop_int op n1 n2))
      | Some (ST_V_LINT n1), Some (ST_V_LINT n2) =>          (* v1.1 *)
          Some (ST_V_LINT (eval_binop_int op n1 n2))
      | Some (ST_V_REAL f1), Some (ST_V_REAL f2) =>
          Some (ST_V_REAL (eval_binop_float op f1 f2))
      | Some (ST_V_LREAL f1), Some (ST_V_LREAL f2) =>        (* v1.1 *)
          Some (ST_V_LREAL (eval_binop_float op f1 f2))
      | Some (ST_V_INT n1), Some (ST_V_DINT n2) =>
          Some (ST_V_DINT (eval_binop_int op n1 n2))
      | Some (ST_V_DINT n1), Some (ST_V_INT n2) =>
          Some (ST_V_DINT (eval_binop_int op n1 n2))
      | Some (ST_V_DINT n1), Some (ST_V_LINT n2) =>          (* v1.1: DINT → LINT *)
          Some (ST_V_LINT (eval_binop_int op n1 n2))
      | Some (ST_V_LINT n1), Some (ST_V_DINT n2) =>          (* v1.1 *)
          Some (ST_V_LINT (eval_binop_int op n1 n2))
      | Some (ST_V_INT n1), Some (ST_V_LINT n2) =>           (* v1.1: INT → LINT *)
          Some (ST_V_LINT (eval_binop_int op n1 n2))
      | Some (ST_V_LINT n1), Some (ST_V_INT n2) =>           (* v1.1 *)
          Some (ST_V_LINT (eval_binop_int op n1 n2))
      | Some (ST_V_REAL f1), Some (ST_V_LREAL f2) =>         (* v1.1: REAL → LREAL *)
          Some (ST_V_LREAL (eval_binop_float op f1 f2))
      | Some (ST_V_LREAL f1), Some (ST_V_REAL f2) =>         (* v1.1 *)
          Some (ST_V_LREAL (eval_binop_float op f1 f2))
      | _, _ => None
      end

  | E_COMP op e1 e2 =>
      match eval_expr s e1, eval_expr s e2 with
      | Some (ST_V_INT n1), Some (ST_V_INT n2) =>
          Some (ST_V_BOOL (eval_compare_int op n1 n2))
      | Some (ST_V_DINT n1), Some (ST_V_DINT n2) =>
          Some (ST_V_BOOL (eval_compare_int op n1 n2))
      | Some (ST_V_INT n1), Some (ST_V_DINT n2) =>
          Some (ST_V_BOOL (eval_compare_int op n1 n2))
      | Some (ST_V_DINT n1), Some (ST_V_INT n2) =>
          Some (ST_V_BOOL (eval_compare_int op n1 n2))
      | Some (ST_V_LINT n1), Some (ST_V_LINT n2) =>          (* v1.1 *)
          Some (ST_V_BOOL (eval_compare_int op n1 n2))
      | Some (ST_V_REAL f1), Some (ST_V_REAL f2) =>
          Some (ST_V_BOOL (eval_compare_float op f1 f2))
      | Some (ST_V_LREAL f1), Some (ST_V_LREAL f2) =>        (* v1.1 *)
          Some (ST_V_BOOL (eval_compare_float op f1 f2))
      | Some (ST_V_BOOL b1), Some (ST_V_BOOL b2) =>
          Some (ST_V_BOOL (eval_compare_bool op b1 b2))
      | Some (ST_V_DINT n1), Some (ST_V_LINT n2) =>          (* v1.1: 混合比较 *)
          Some (ST_V_BOOL (eval_compare_int op n1 n2))
      | Some (ST_V_LINT n1), Some (ST_V_DINT n2) =>          (* v1.1 *)
          Some (ST_V_BOOL (eval_compare_int op n1 n2))
      | Some (ST_V_REAL f1), Some (ST_V_LREAL f2) =>         (* v1.1: 混合比较 *)
          Some (ST_V_BOOL (eval_compare_float op f1 f2))
      | Some (ST_V_LREAL f1), Some (ST_V_REAL f2) =>         (* v1.1 *)
          Some (ST_V_BOOL (eval_compare_float op f1 f2))
      | _, _ => None
      end

  | E_AND e1 e2 =>
      match eval_expr s e1, eval_expr s e2 with
      | Some (ST_V_BOOL b1), Some (ST_V_BOOL b2) =>
          Some (ST_V_BOOL (b1 && b2))
      | _, _ => None
      end

  | E_OR e1 e2 =>
      match eval_expr s e1, eval_expr s e2 with
      | Some (ST_V_BOOL b1), Some (ST_V_BOOL b2) =>
          Some (ST_V_BOOL (b1 || b2))
      | _, _ => None
      end

  | E_XOR e1 e2 =>
      match eval_expr s e1, eval_expr s e2 with
      | Some (ST_V_BOOL b1), Some (ST_V_BOOL b2) =>
          Some (ST_V_BOOL (xorb b1 b2))
      | _, _ => None
      end

  | E_FUNC_CALL f args =>
      (* 简化：函数调用返回默认值 *)
      Some (ST_V_INT 0)

  | E_QUALITY_OP op args =>
      match op with
      | Q_STATUS =>
          (* Q_STATUS(x): 从质量表中查找 *)
          match args with
          | [x] =>
              match x with
              | E_VAR id => Some (ST_V_INT (lookup_quality s.(st_quality) id))
              | _ => Some (ST_V_INT 0)  (* 默认 GOOD *)
              end
          | _ => None
          end
      | Q_VALUE =>
          (* Q_VALUE(x): 直接返回值（非 Q 变量时返回自身） *)
          match args with
          | [x] => Some (ST_V_INT 0)  (* 简化：返回默认值 *)
          | _ => None
          end
      | Q_GOOD =>
          match args with
          | [E_VAR id] => Some (ST_V_BOOL (lookup_quality s.(st_quality) id =? 0))
          | _ => Some (ST_V_BOOL true)
          end
      | Q_BAD =>
          match args with
          | [E_VAR id] => Some (ST_V_BOOL (lookup_quality s.(st_quality) id =? 1))
          | _ => Some (ST_V_BOOL false)
          end
      | _ => Some (ST_V_INT 0)  (* Q_SET, Q_WITH, Q_FORCE: 简化 *)
      end
  end.

(* ST 状态更新 *)
Definition update_var (s : st_state) (x : ident) (v : st_value) : st_state :=
  {| st_vars := (x, v) :: s.(st_vars);
     st_quality := s.(st_quality);
     st_pou_idx := s.(st_pou_idx);
     st_stmt_idx := s.(st_stmt_idx);
     st_call_stack := s.(st_call_stack);
     st_cycle_cnt := s.(st_cycle_cnt) + 1;
  |}.

(* 进入语句块（简化占位） *)
Definition enter_block (s : st_state) (stmts : list st_stmt) : st_state :=
  s.

(* 退出语句块 *)
Definition exit_block (s : st_state) : st_state :=
  s.

(* 查找函数定义：在 POU 列表中搜索 FUNCTION 类型的定义 *)
Fixpoint lookup_function_in_pous (pous : list st_pou) (f : ident) : option (list st_type * list st_stmt) :=
  match pous with
  | nil => None
  | P_FUNCTION name _ _ body :: rest =>
      if ident_eq name f
      then Some (List.map (fun vd => vd.(var_type)) nil, body)
      else lookup_function_in_pous rest f
  | _ :: rest => lookup_function_in_pous rest f
  end.

Definition lookup_function_st (p : st_program) (f : ident) : option (list st_type * list st_stmt) :=
  lookup_function_in_pous p.(pou_list) f.

(* 查找 FB 定义：在 POU 列表中搜索匹配的 FB/PROGRAM *)
Fixpoint lookup_fb_in_pous (pous : list st_pou) (inst : ident) : option st_pou :=
  match pous with
  | nil => None
  | fb :: rest =>
      let name := match fb with P_PROGRAM n _ _ => n | P_FUNCTION n _ _ _ => n | P_FUNCTION_BLOCK n _ _ => n end in
      if ident_eq name inst then Some fb
      else lookup_fb_in_pous rest inst
  end.

Definition lookup_fb (p : st_program) (inst : ident) : option st_pou :=
  lookup_fb_in_pous p.(pou_list) inst.

(* 函数调用栈帧操作 *)
Definition push_call_frame (s : st_state) (f : ident) (args : list st_expr) (body : list st_stmt) : st_state :=
  {| st_vars := s.(st_vars);
     st_quality := s.(st_quality);
     st_pou_idx := s.(st_pou_idx);
     st_stmt_idx := 0;
     st_call_stack := s.(st_pou_idx) :: s.(st_call_stack);
     st_cycle_cnt := s.(st_cycle_cnt) + 1;
  |}.

Definition pop_call_frame (s : st_state) (ret_val : st_value) : st_state :=
  match s.(st_call_stack) with
  | nil => s
  | caller_pou :: rest =>
      {| st_vars := s.(st_vars);
         st_quality := s.(st_quality);
         st_pou_idx := caller_pou;
         st_stmt_idx := s.(st_stmt_idx);
         st_call_stack := rest;
         st_cycle_cnt := s.(st_cycle_cnt) + 1;
      |}
  end.

(* 辅助：顺序执行语句列表（仅执行赋值，复合语句简化为保持状态不变） *)
Fixpoint execute_stmts (s : st_state) (stmts : list st_stmt) : st_state :=
  match stmts with
  | nil => s
  | stmt :: rest =>
      let s' := match stmt with
                | S_ASSIGN x e =>
                    match eval_expr s e with
                    | Some v => update_var s x v
                    | None => s
                    end
                | S_ARRAY_ASSIGN x idx e => s  (* 简化 *)
                | _ => s  (* 复合语句由 step_st 规则处理，此处保持状态不变 *)
                end
      in execute_stmts s' rest
  end.

(* 辅助：检查 CASE 值是否匹配 *)
Fixpoint match_case_values (sel_num : Z) (vs : list case_value) : bool :=
  match vs with
  | nil => false
  | CV_SINGLE (L_INT n) :: vs' =>
      Z.eqb sel_num n || match_case_values sel_num vs'
  | CV_RANGE (L_INT lo) (L_INT hi) :: vs' =>
      ((lo <=? sel_num) && (sel_num <=? hi)) ||
      match_case_values sel_num vs'
  | _ :: vs' => match_case_values sel_num vs'
  end.

Fixpoint core_case_values (values : list case_value) : Prop :=
  match values with
  | nil => True
  | CV_SINGLE (L_INT _) :: rest => core_case_values rest
  | CV_RANGE (L_INT _) (L_INT _) :: rest => core_case_values rest
  | _ => False
  end.

Fixpoint core_case_values_dec (values : list case_value) : bool :=
  match values with
  | nil => true
  | CV_SINGLE (L_INT _) :: rest => core_case_values_dec rest
  | CV_RANGE (L_INT _) (L_INT _) :: rest => core_case_values_dec rest
  | _ => false
  end.

Lemma core_case_values_dec_true :
  forall (values : list case_value),
    core_case_values_dec values = true -> core_case_values values.
Proof.
  intros values.
  induction values as [|v rest IH]; simpl; intros H.
  - exact I.
  - destruct v as [lit | lo hi].
    + destruct lit; try discriminate.
      apply IH. exact H.
    + destruct lo; try discriminate.
      destruct hi; try discriminate.
      apply IH. exact H.
Qed.

Fixpoint core_case_branches (branches : list case_element) : Prop :=
  match branches with
  | nil => True
  | CASE_ELEM values body :: rest =>
      core_case_values values /\ core_case_branches rest
  end.

(* 辅助：查找匹配的 CASE 分支 *)
Fixpoint find_case_branch (sel_num : Z) (brs : list case_element) : option (list st_stmt) :=
  match brs with
  | nil => None
  | CASE_ELEM vals stmts :: rest =>
      if match_case_values sel_num vals then Some stmts else find_case_branch sel_num rest
  end.

(* 辅助：执行 CASE 语句（选择匹配分支） *)
Definition execute_case (s : st_state) (sel : st_expr) (branches : list case_element) (default : option (list st_stmt)) : st_state :=
  match eval_expr s sel with
  | Some (ST_V_INT sel_num) =>
      match find_case_branch sel_num branches with
      | Some stmts => execute_stmts s stmts
      | None => match default with Some d => execute_stmts s d | None => s end
      end
  | Some (ST_V_DINT sel_num) =>
      match find_case_branch sel_num branches with
      | Some stmts => execute_stmts s stmts
      | None => match default with Some d => execute_stmts s d | None => s end
      end
  | _ => s
  end.

(* 执行 FB *)
Definition execute_fb (s : st_state) (fb_def : st_pou) (params : list (ident * st_expr)) : st_state :=
  let body := match fb_def with P_PROGRAM _ _ b => b | P_FUNCTION _ _ _ b => b | P_FUNCTION_BLOCK _ _ b => b end in
  execute_stmts s body.
(* 运行时值的基础类型 *)
Definition st_value_type (v : st_value) : st_type :=
  match v with
  | ST_V_BOOL _  => T_BOOL
  | ST_V_BYTE _  => T_BYTE
  | ST_V_WORD _  => T_WORD
  | ST_V_DWORD _ => T_DWORD
  | ST_V_SINT _  => T_SINT
  | ST_V_INT _   => T_INT
  | ST_V_DINT _  => T_DINT
  | ST_V_LINT _  => T_LINT
  | ST_V_REAL _  => T_REAL
  | ST_V_LREAL _ => T_LREAL
  | ST_V_TIME _  => T_TIME
  end.

(* 声明环境构造（与 typechecker 共享，避免语义层反向依赖类型检查器） *)
Definition pou_name (p : st_pou) : ident :=
  match p with
  | P_PROGRAM name _ _ => name
  | P_FUNCTION name _ _ _ => name
  | P_FUNCTION_BLOCK name _ _ => name
  end.

Definition pou_var_decls (p : st_pou) : list st_var_decl :=
  match p with
  | P_PROGRAM _ decls _ => decls
  | P_FUNCTION _ _ decls _ => decls
  | P_FUNCTION_BLOCK _ decls _ => decls
  end.

Fixpoint build_env_from_decls (decls : list st_var_decl) : type_env :=
  match decls with
  | nil => nil
  | d :: rest => (d.(var_name), d.(var_type)) :: build_env_from_decls rest
  end.

Definition build_program_env (p : st_program) : type_env :=
  let global_env := build_env_from_decls p.(global_vars) in
  List.fold_right (fun pou acc =>
    build_env_from_decls (pou_var_decls pou) ++ acc
  ) global_env p.(pou_list).

(* 赋值时把求值结果归一化为变量的声明类型，使 INT 值可无损存入 DINT。 *)
Definition coerce_value_to_type (ty : st_type) (v : st_value) : st_value :=
  match ty, v with
  | T_DINT, ST_V_INT n => ST_V_DINT n
  | T_INT, ST_V_DINT n => ST_V_INT n
  | T_LINT, ST_V_INT n | T_LINT, ST_V_DINT n => ST_V_LINT n
  | T_LREAL, ST_V_REAL f => ST_V_LREAL f
  | _, v => v
  end.

(* 运行时类型一致性：状态中每个变量的实际基础类型与声明类型兼容 *)
Definition state_consistent (env : type_env) (s : st_state) : Prop :=
  (forall (x : ident) (ty : st_type) (v : st_value),
    lookup env x = Some ty ->
    lookup_var s.(st_vars) x = Some v ->
    st_value_type v = ty) /\
  (forall (x : ident) (ty : st_type),
    lookup env x = Some ty ->
    exists (v : st_value), lookup_var s.(st_vars) x = Some v).

(* 质量一致性：质量码只能为 GOOD(0) 或 BAD(1) *)
Definition quality_consistent (s : st_state) : Prop :=
  forall (x : ident) (q : Z),
    List.In (x, q) s.(st_quality) ->
    q = 0 \/ q = 1.

(* ================================================================
   配置式语句小步语义

   配置 = 当前剩余语句列表 + 运行时状态。
   每条规则消费列表头部的一条语句，并把复合结构展开到后续列表中。
   这是 typechecker 与 codegen 后续证明所需的真实语义基准。
   ================================================================ *)

Definition st_config : Type := (list st_stmt * st_state)%type.

(* FOR 语句展开：先赋初值，再用 WHILE 循环主体 + 自增 *)
Definition for_to_while (v : ident) (start end_ : st_expr)
           (step : option st_expr) (body : list st_stmt) : list st_stmt :=
  let step_expr := match step with
                   | Some e => e
                   | None => E_LIT (L_INT 1)
                   end in
  S_ASSIGN v start ::
  S_WHILE (E_COMP C_LE (E_VAR v) end_)
    (body ++ [S_ASSIGN v (E_BIN_OP B_ADD (E_VAR v) step_expr)]) :: nil.

(* CASE 分支选择：命中分支优先，否则使用 default；两者都缺失时为空列表。 *)
Definition select_case_stmts (sel_num : Z) (branches : list case_element)
           (default : option (list st_stmt)) : list st_stmt :=
  match find_case_branch sel_num branches with
  | Some stmts => stmts
  | None =>
      match default with
      | Some stmts => stmts
      | None => nil
      end
  end.

Inductive stmts_step : st_program -> list st_stmt -> st_state ->
                       list st_stmt -> st_state -> Prop :=
  | Ss_assign : forall (p : st_program) (x : ident) (e : st_expr)
                       (rest : list st_stmt) (s : st_state)
                       (v : st_value) (ty : st_type),
      lookup (build_program_env p) x = Some ty ->
      eval_expr s e = Some v ->
      stmts_step p (S_ASSIGN x e :: rest) s rest
                 (update_var s x (coerce_value_to_type ty v))

  | Ss_if_true : forall (p : st_program) (cond : st_expr)
                        (then_stmts : list st_stmt) (else_opt : option (list st_stmt))
                        (rest : list st_stmt) (s : st_state),
      eval_expr s cond = Some (ST_V_BOOL true) ->
      stmts_step p (S_IF cond then_stmts else_opt :: rest) s
                 (then_stmts ++ rest) s

  | Ss_if_false : forall (p : st_program) (cond : st_expr)
                         (then_stmts : list st_stmt) (else_opt : option (list st_stmt))
                         (rest : list st_stmt) (s : st_state),
      eval_expr s cond = Some (ST_V_BOOL false) ->
      stmts_step p (S_IF cond then_stmts else_opt :: rest) s
                 (match else_opt with Some e => e ++ rest | None => rest end) s

  | Ss_while_true : forall (p : st_program) (cond : st_expr)
                           (body : list st_stmt) (rest : list st_stmt)
                           (s : st_state),
      eval_expr s cond = Some (ST_V_BOOL true) ->
      stmts_step p (S_WHILE cond body :: rest) s
                 (body ++ S_WHILE cond body :: rest) s

  | Ss_while_false : forall (p : st_program) (cond : st_expr)
                            (body : list st_stmt) (rest : list st_stmt)
                            (s : st_state),
      eval_expr s cond = Some (ST_V_BOOL false) ->
      stmts_step p (S_WHILE cond body :: rest) s rest s

  | Ss_repeat : forall (p : st_program) (body : list st_stmt)
                       (cond : st_expr) (rest : list st_stmt) (s : st_state),
      stmts_step p (S_REPEAT body cond :: rest) s
                 (body ++ (S_WHILE (E_UNARY_OP U_NOT cond) body) :: rest) s

  | Ss_case : forall (p : st_program) (sel : st_expr)
                     (branches : list case_element) (default : option (list st_stmt))
                     (rest : list st_stmt) (s : st_state) (n : Z),
      eval_expr s sel = Some (ST_V_INT n) ->
      stmts_step p (S_CASE sel branches default :: rest) s
                 (select_case_stmts n branches default ++ rest) s

  | Ss_case_dint : forall (p : st_program) (sel : st_expr)
                          (branches : list case_element) (default : option (list st_stmt))
                          (rest : list st_stmt) (s : st_state) (n : Z),
      eval_expr s sel = Some (ST_V_DINT n) ->
      stmts_step p (S_CASE sel branches default :: rest) s
                 (select_case_stmts n branches default ++ rest) s

  | Ss_for : forall (p : st_program) (v : ident) (start end_ : st_expr)
                    (step : option st_expr) (body : list st_stmt)
                    (rest : list st_stmt) (s : st_state),
      stmts_step p (S_FOR v start end_ step body :: rest) s
                 (for_to_while v start end_ step body ++ rest) s
.

(* 配置多步执行 *)
Inductive star_stmts_step : st_program -> list st_stmt -> st_state ->
                            list st_stmt -> st_state -> Prop :=
  | Star_stmts_refl : forall (p : st_program) (stmts : list st_stmt)
                             (s : st_state),
      star_stmts_step p stmts s stmts s
  | Star_stmts_step : forall (p : st_program) (stmts1 stmts2 stmts3 : list st_stmt)
                             (s1 s2 s3 : st_state),
      stmts_step p stmts1 s1 stmts2 s2 ->
      star_stmts_step p stmts2 s2 stmts3 s3 ->
      star_stmts_step p stmts1 s1 stmts3 s3
.

(* 语句列表执行结束：无剩余语句即终止 *)
Definition stmts_done (stmts : list st_stmt) (s : st_state) : Prop :=
  stmts = nil.

(* ================================================================
   单步存在性引理（Progress 的最小构成单元）
   每个引理只要求其求值前提成立，后续由类型系统证明这些前提。
   ================================================================ *)

Lemma ss_assign_step_exists :
  forall (p : st_program) (x : ident) (e : st_expr)
         (rest : list st_stmt) (s : st_state) (v : st_value)
         (ty : st_type),
    lookup (build_program_env p) x = Some ty ->
    eval_expr s e = Some v ->
    exists (rest' : list st_stmt) (s' : st_state),
      stmts_step p (S_ASSIGN x e :: rest) s rest' s'.
Proof.
  intros. eexists; eexists; econstructor; [exact H | exact H0].
Qed.

Lemma ss_if_true_step_exists :
  forall (p : st_program) (cond : st_expr) (then_stmts : list st_stmt)
         (else_opt : option (list st_stmt)) (rest : list st_stmt) (s : st_state),
    eval_expr s cond = Some (ST_V_BOOL true) ->
    exists (rest' : list st_stmt) (s' : st_state),
      stmts_step p (S_IF cond then_stmts else_opt :: rest) s rest' s'.
Proof.
  intros. eexists; eexists; econstructor; exact H.
Qed.

Lemma ss_if_false_step_exists :
  forall (p : st_program) (cond : st_expr) (then_stmts : list st_stmt)
         (else_opt : option (list st_stmt)) (rest : list st_stmt) (s : st_state),
    eval_expr s cond = Some (ST_V_BOOL false) ->
    exists (rest' : list st_stmt) (s' : st_state),
      stmts_step p (S_IF cond then_stmts else_opt :: rest) s rest' s'.
Proof.
  intros. eexists; eexists; econstructor; exact H.
Qed.

Lemma ss_while_true_step_exists :
  forall (p : st_program) (cond : st_expr) (body : list st_stmt)
         (rest : list st_stmt) (s : st_state),
    eval_expr s cond = Some (ST_V_BOOL true) ->
    exists (rest' : list st_stmt) (s' : st_state),
      stmts_step p (S_WHILE cond body :: rest) s rest' s'.
Proof.
  intros. eexists; eexists; econstructor; exact H.
Qed.

Lemma ss_while_false_step_exists :
  forall (p : st_program) (cond : st_expr) (body : list st_stmt)
         (rest : list st_stmt) (s : st_state),
    eval_expr s cond = Some (ST_V_BOOL false) ->
    exists (rest' : list st_stmt) (s' : st_state),
      stmts_step p (S_WHILE cond body :: rest) s rest' s'.
Proof.
  intros. eexists; eexists; econstructor; exact H.
Qed.

Lemma ss_repeat_step_exists :
  forall (p : st_program) (body : list st_stmt) (cond : st_expr)
         (rest : list st_stmt) (s : st_state),
    exists (rest' : list st_stmt) (s' : st_state),
      stmts_step p (S_REPEAT body cond :: rest) s rest' s'.
Proof.
  intros. eexists; eexists; econstructor.
Qed.

Lemma ss_for_step_exists :
  forall (p : st_program) (v : ident) (start end_ : st_expr)
         (step : option st_expr) (body : list st_stmt)
         (rest : list st_stmt) (s : st_state),
    exists (rest' : list st_stmt) (s' : st_state),
      stmts_step p (S_FOR v start end_ step body :: rest) s rest' s'.
Proof.
  intros. eexists; eexists; econstructor.
Qed.

(* 良类型字面量求值总有定义：literal_type l = Some ty 时，
   eval_expr 对 E_LIT l 一定返回某个值。 *)
Lemma eval_literal_typed_total :
  forall (s : st_state) (l : st_literal) (ty : st_type),
    literal_type l = Some ty ->
    exists (v : st_value), eval_expr s (E_LIT l) = Some v.
Proof.
  intros s l ty H.
  destruct l; simpl in H; inversion H; subst.
  all: eexists; reflexivity.
Qed.

(* 整数字面量算术求值总有定义。 *)
Lemma eval_int_literal_binop_total :
  forall (s : st_state) (op : binary_op) (n1 n2 : Z),
    exists (v : st_value),
      eval_expr s (E_BIN_OP op (E_LIT (L_INT n1)) (E_LIT (L_INT n2))) = Some v.
Proof.
  intros s op n1 n2.
  destruct op; simpl; eexists; reflexivity.
Qed.

(* 整数字面量比较求值总有定义。 *)
Lemma eval_int_literal_compare_total :
  forall (s : st_state) (c : compare_op) (n1 n2 : Z),
    exists (v : st_value),
      eval_expr s (E_COMP c (E_LIT (L_INT n1)) (E_LIT (L_INT n2))) = Some v.
Proof.
  intros s c n1 n2.
  destruct c; simpl; eexists; reflexivity.
Qed.

(* 布尔逻辑字面量求值总有定义。 *)
Lemma eval_bool_logic_literal_total :
  forall (s : st_state) (b1 b2 : bool),
    exists (v : st_value),
      eval_expr s (E_AND (E_LIT (L_BOOL b1)) (E_LIT (L_BOOL b2))) = Some v.
Proof.
  intros s b1 b2.
  destruct b1, b2; simpl; eexists; reflexivity.
Qed.

Lemma eval_bool_or_literal_total :
  forall (s : st_state) (b1 b2 : bool),
    exists (v : st_value),
      eval_expr s (E_OR (E_LIT (L_BOOL b1)) (E_LIT (L_BOOL b2))) = Some v.
Proof.
  intros s b1 b2.
  destruct b1, b2; simpl; eexists; reflexivity.
Qed.

Lemma eval_bool_xor_literal_total :
  forall (s : st_state) (b1 b2 : bool),
    exists (v : st_value),
      eval_expr s (E_XOR (E_LIT (L_BOOL b1)) (E_LIT (L_BOOL b2))) = Some v.
Proof.
  intros s b1 b2.
  destruct b1, b2; simpl; eexists; reflexivity.
Qed.
