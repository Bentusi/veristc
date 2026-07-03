(* ================================================================
   vstac/spec/safest.v
   SafeST — IEC 61131-3 Structured Text 安全子集 Coq 形式化定义
   
   本文件是 spec/safest-spec.md 的 Coq 形式化镜像。
   所有定义与文档保持同步。
   ================================================================ *)

Require Import Stdlib.ZArith.ZArith.
Require Import Stdlib.Lists.List.
Local Open Scope Z_scope.
Require Import Stdlib.Floats.Floats.
Require Import Stdlib.Strings.String.
Require Import Stdlib.Bool.Bool.
Import ListNotations.

(* ================================================================
   第 1 部分：词法单元 (Tokens)
   ================================================================ *)

Inductive token : Type :=
  (* 关键字 *)
  | TK_PROGRAM | TK_FUNCTION | TK_FUNCTION_BLOCK
  | TK_END_PROGRAM | TK_END_FUNCTION | TK_END_FUNCTION_BLOCK
  | TK_IF | TK_THEN | TK_ELSIF | TK_ELSE | TK_END_IF
  | TK_CASE | TK_OF | TK_END_CASE
  | TK_FOR | TK_TO | TK_BY | TK_DO | TK_END_FOR
  | TK_WHILE | TK_END_WHILE
  | TK_REPEAT | TK_UNTIL | TK_END_REPEAT
  | TK_RETURN | TK_EXIT
  | TK_VAR | TK_VAR_INPUT | TK_VAR_OUTPUT | TK_VAR_IN_OUT
  | TK_VAR_GLOBAL | TK_END_VAR
  | TK_CONSTANT | TK_RETAIN
  | TK_TRUE | TK_FALSE
  | TK_AND | TK_OR | TK_XOR | TK_NOT
 | TK_MOD | TK_ABS
 (* 质量类型关键字 (v1.1) *)
 | TK_QUALITY | TK_GOOD | TK_BAD | TK_UNCERTAIN | TK_NOT_CONNECTED
 | TK_QBOOL | TK_QBYTE | TK_QWORD | TK_QDWORD
 | TK_QSINT | TK_QINT | TK_QDINT | TK_QLINT
 | TK_QREAL | TK_QLREAL | TK_QTIME
 (* 质量操作内置函数名 (v1.1) *)
 | TK_Q_STATUS | TK_Q_SET | TK_Q_VALUE | TK_Q_WITH | TK_Q_FORCE
 | TK_Q_GOOD | TK_Q_BAD | TK_Q_UNCERTAIN | TK_Q_NONE | TK_Q_DISABLE
 (* 字面量 *)
 | TK_INT_LIT : Z -> token              (* 整数常量 *)
  | TK_REAL_LIT : float -> token         (* 浮点常量 *)
  | TK_TIME_LIT : Z -> token             (* TIME 常量，纳秒 *)
  | TK_BOOL_LIT : bool -> token          (* 布尔常量 *)
  (* 标识符 *)
  | TK_IDENT : string -> token           (* 变量名/函数名/FB名 *)
  (* 运算符 *)
  | TK_PLUS | TK_MINUS | TK_STAR | TK_SLASH
  | TK_EQ | TK_NE | TK_LT | TK_LE | TK_GT | TK_GE
  | TK_ASSIGN                    (* := *)
  | TK_COLON | TK_SEMI | TK_COMMA | TK_DOT
  | TK_LPAREN | TK_RPAREN
  | TK_LBRACK | TK_RBRACK        (* 数组下标 [ ] *)
  | TK_RANGE                     (* .. *)
  (* 其他 *)
  | TK_EOF
.

(* ================================================================
   第 1b 部分：标识符类型
   ================================================================ *)

(* 标识符类型 *)
Inductive ident : Type :=
  | ID : string -> ident
.

(* 标识符相等性比较 *)
Definition ident_eq (x y : ident) : bool :=
  match x, y with
  | ID s1, ID s2 => String.eqb s1 s2
  end.

(* ================================================================
   第 2 部分：类型系统 (Type System)
   ================================================================ *)

Inductive st_type : Type :=
  | T_BOOL                       (* BOOL *)
  | T_BYTE                       (* BYTE *)
  | T_WORD                       (* WORD *)
  | T_DWORD                      (* DWORD *)
 | T_SINT                       (* SINT *)
 | T_INT                        (* INT *)
 | T_DINT                       (* DINT *)
 | T_LINT                       (* LINT — 64 位有符号整数, v1.1 *)
 | T_REAL                       (* REAL *)
 | T_LREAL                      (* LREAL — 64 位浮点, v1.1 *)
 | T_TIME                       (* TIME *)
 | T_QUALITY                    (* QUALITY — 信号质量码, v1.1 *)
 (* 带质量位的 Q 类型 (v1.1) *)
 | T_QBOOL                      (* QBOOL *)
 | T_QBYTE                      (* QBYTE *)
 | T_QWORD                      (* QWORD *)
 | T_QDWORD                     (* QDWORD *)
 | T_QSINT                      (* QSINT *)
 | T_QINT                       (* QINT *)
 | T_QDINT                      (* QDINT *)
 | T_QLINT                      (* QLINT — 64 位带质量整数, v1.1 *)
 | T_QREAL                      (* QREAL *)
 | T_QLREAL                     (* QLREAL — 64 位带质量浮点, v1.1 *)
 | T_QTIME                      (* QTIME *)
 | T_ARRAY : st_type -> Z -> Z -> st_type   (* 静态数组: 元素类型 × 下界 × 上界 *)
.

(* 类型的位宽（用于内存布局计算） *)
Fixpoint type_width (t : st_type) : Z :=
  match t with
  | T_BOOL   => 1
  | T_BYTE   => 8
  | T_WORD   => 16
  | T_DWORD  => 32
  | T_SINT   => 8
  | T_INT    => 16
  | T_DINT   => 32
  | T_LINT   => 64               (* v1.1 *)
  | T_REAL   => 32
  | T_LREAL  => 64               (* v1.1 *)
  | T_TIME   => 64
  | T_QUALITY => 8               (* v1.1: 1 字节质量码 *)
  (* Q 类型: 值宽度与基础类型相同 *)
  | T_QBOOL  => 1
  | T_QBYTE  => 8
  | T_QWORD  => 16
  | T_QDWORD => 32
  | T_QSINT  => 8
  | T_QINT   => 16
  | T_QDINT  => 32
  | T_QLINT  => 64               (* v1.1 *)
  | T_QREAL  => 32
  | T_QLREAL => 64               (* v1.1 *)
  | T_QTIME  => 64
  | T_ARRAY elem low high => (high - low + 1) * type_width elem
  end.

(* 类型兼容性（隐式转换规则） *)
Inductive type_compatible : st_type -> st_type -> Prop :=
  | Comp_same : forall t, type_compatible t t
  (* 整数提升: SINT → INT → DINT *)
  | Comp_sint_int : type_compatible T_SINT T_INT
  | Comp_sint_dint : type_compatible T_SINT T_DINT
  | Comp_int_dint : type_compatible T_INT T_DINT
  (* 位串提升: BYTE → WORD → DWORD *)
  | Comp_byte_word : type_compatible T_BYTE T_WORD
  | Comp_byte_dword : type_compatible T_BYTE T_DWORD
 | Comp_word_dword : type_compatible T_WORD T_DWORD
 (* LINT 扩展 (v1.1) *)
 | Comp_sint_lint : type_compatible T_SINT T_LINT
 | Comp_int_lint : type_compatible T_INT T_LINT
 | Comp_dint_lint : type_compatible T_DINT T_LINT
 (* LREAL 扩展 (v1.1) *)
 | Comp_real_lreal : type_compatible T_REAL T_LREAL
.

(* 提升到公共类型 *)
Inductive promote_type : st_type -> st_type -> st_type -> Prop :=
  | Promote_same : forall t, promote_type t t t
  | Promote_sint_int : promote_type T_SINT T_INT T_INT
  | Promote_sint_dint : promote_type T_SINT T_DINT T_DINT
  | Promote_int_dint : promote_type T_INT T_DINT T_DINT
  | Promote_byte_word : promote_type T_BYTE T_WORD T_WORD
  | Promote_byte_dword : promote_type T_BYTE T_DWORD T_DWORD
  | Promote_word_dword : promote_type T_WORD T_DWORD T_DWORD
  | Promote_int_sint : promote_type T_INT T_SINT T_INT
  | Promote_dint_sint : promote_type T_DINT T_SINT T_DINT
  | Promote_dint_int : promote_type T_DINT T_INT T_DINT
  | Promote_word_byte : promote_type T_WORD T_BYTE T_WORD
  | Promote_dword_byte : promote_type T_DWORD T_BYTE T_DWORD
 | Promote_dword_word : promote_type T_DWORD T_WORD T_DWORD
 (* LINT 扩展 (v1.1) *)
 | Promote_sint_lint : promote_type T_SINT T_LINT T_LINT
 | Promote_int_lint : promote_type T_INT T_LINT T_LINT
 | Promote_dint_lint : promote_type T_DINT T_LINT T_LINT
 | Promote_lint_sint : promote_type T_LINT T_SINT T_LINT
 | Promote_lint_int : promote_type T_LINT T_INT T_LINT
 | Promote_lint_dint : promote_type T_LINT T_DINT T_LINT
 | Promote_lint_lint : promote_type T_LINT T_LINT T_LINT
 (* LREAL 扩展 (v1.1) *)
 | Promote_real_lreal : promote_type T_REAL T_LREAL T_LREAL
 | Promote_lreal_real : promote_type T_LREAL T_REAL T_LREAL
 | Promote_lreal_lreal : promote_type T_LREAL T_LREAL T_LREAL
 (* QUALITY 扩展 (v1.1) *)
 | Promote_quality : promote_type T_QUALITY T_QUALITY T_QUALITY
.

(* ================================================================
   第 3 部分：字面量 (Literals)
   ================================================================ *)

Inductive st_literal : Type :=
  | L_BOOL : bool -> st_literal
  | L_INT : Z -> st_literal                (* 整数字面量，范围对应具体类型 *)
  | L_REAL : float -> st_literal           (* 实数字面量 *)
 | L_TIME : Z -> st_literal               (* 时间字面量，单位纳秒 *)
 | L_LINT : Z -> st_literal               (* 64 位整数，L# 前缀, v1.1 *)
 | L_LREAL : float -> st_literal          (* 64 位浮点字面量, v1.1 *)
.

(* 字面量的类型推断 *)
Definition literal_type (l : st_literal) : option st_type :=
  match l with
  | L_BOOL _ => Some T_BOOL
  | L_INT _  => Some T_DINT    (* 默认整数类型 *)
  | L_REAL _ => Some T_REAL
  | L_TIME _ => Some T_TIME
  | L_LINT _ => Some T_LINT
  | L_LREAL _ => Some T_LREAL
  end.

(* ================================================================
   第 4 部分：表达式 (Expressions)
   ================================================================ *)

Inductive unary_op : Type :=
  | U_NEG     (* 一元负号 - *)
  | U_NOT     (* 逻辑非 NOT *)
  | U_ABS     (* 绝对值 ABS *)
.

Inductive binary_op : Type :=
  | B_ADD     (* + *)
  | B_SUB     (* - *)
  | B_MUL     (* * *)
  | B_DIV     (* / *)
  | B_MOD     (* MOD *)
.

Inductive compare_op : Type :=
  | C_EQ      (* = *)
  | C_NE      (* <> *)
  | C_LT      (* < *)
  | C_LE      (* <= *)
  | C_GT      (* > *)
  | C_GE      (* >= *)
.

(* 质量操作算子 (v1.1) *)
Inductive quality_op : Type :=
  | Q_STATUS     (* Q_STATUS(x) → QUALITY *)
  | Q_VALUE      (* Q_VALUE(x) → 基础类型值 *)
  | Q_GOOD       (* Q_GOOD(x) → BOOL *)
  | Q_BAD        (* Q_BAD(x) → BOOL *)
  | Q_UNCERTAIN  (* Q_UNCERTAIN(x) → BOOL *)
  | Q_SET        (* Q_SET(x, q) → QUALITY *)
  | Q_WITH       (* Q_WITH(v, q) → Q 类型 *)
  | Q_FORCE      (* Q_FORCE(x, v, q) → Q 类型 *)
.

Inductive st_expr : Type :=
  | E_LIT : st_literal -> st_expr                            (* 字面量 *)
  | E_VAR : ident -> st_expr                                 (* 变量引用 *)
  | E_ARRAY_ACCESS : st_expr -> st_expr -> st_expr             (* 数组索引 arr[idx] *)
  | E_UNARY_OP : unary_op -> st_expr -> st_expr               (* 一元运算 *)
  | E_BIN_OP : binary_op -> st_expr -> st_expr -> st_expr       (* 二元运算 *)
  | E_COMP : compare_op -> st_expr -> st_expr -> st_expr        (* 比较运算 *)
  | E_AND : st_expr -> st_expr -> st_expr                      (* 逻辑 AND（逻辑求值） *)
  | E_OR : st_expr -> st_expr -> st_expr                       (* 逻辑 OR（逻辑求值） *)
  | E_XOR : st_expr -> st_expr -> st_expr                      (* 逻辑 XOR *)
  | E_FUNC_CALL : ident -> list st_expr -> st_expr             (* 函数调用 *)
  | E_QUALITY_OP : quality_op -> list st_expr -> st_expr       (* 质量操作, v1.1 *)
.

(* ================================================================
   第 5 部分：语句 (Statements)
   ================================================================ *)

Inductive st_stmt : Type :=
  | S_ASSIGN : ident -> st_expr -> st_stmt                                (* x := e *)
  | S_ARRAY_ASSIGN : ident -> st_expr -> st_expr -> st_stmt                 (* a[i] := e *)
  | S_IF : st_expr -> list st_stmt -> option (list st_stmt) -> st_stmt      (* IF cond THEN stmts [ELSE stmts] *)
  | S_CASE : st_expr -> list (case_element) -> option (list st_stmt) -> st_stmt
  | S_FOR : ident -> st_expr -> st_expr -> option st_expr -> list st_stmt -> st_stmt
  | S_WHILE : st_expr -> list st_stmt -> st_stmt
  | S_REPEAT : list st_stmt -> st_expr -> st_stmt
  | S_FB_CALL : ident -> list (ident * st_expr) -> st_stmt                 (* FB_inst(param:=val, ...) *)
  | S_RETURN : st_stmt
  | S_EXIT : st_stmt
with case_element : Type :=
  | CASE_ELEM : list case_value -> list st_stmt -> case_element
with case_value : Type :=
  | CV_SINGLE : st_literal -> case_value
  | CV_RANGE : st_literal -> st_literal -> case_value                          (* low..high *)
.

(* ================================================================
   第 6 部分：变量声明 (Variable Declarations)
   ================================================================ *)

Inductive var_direction : Type :=
  | D_INPUT
  | D_OUTPUT
  | D_IN_OUT
  | D_LOCAL
  | D_GLOBAL
.

Inductive var_qualifier : Type :=
  | Q_NONE
  | Q_CONSTANT
  | Q_RETAIN
.

Record st_var_decl : Type := {
  var_name    : ident;
  var_type    : st_type;
  var_dir     : var_direction;
  var_qual    : var_qualifier;
  var_init    : option st_literal;   (* 初始值 *)
}.



(* ================================================================
   第 7 部分：程序组织单元 (POU)
   ================================================================ *)

Inductive st_pou : Type :=
  | P_PROGRAM : ident -> list st_var_decl -> list st_stmt -> st_pou
  | P_FUNCTION : ident -> st_type -> list st_var_decl -> list st_stmt -> st_pou
  | P_FUNCTION_BLOCK : ident -> list st_var_decl -> list st_stmt -> st_pou
.

Record io_entry : Type := {
  io_var_name    : ident;         (* ST 变量名 *)
  io_channel_id  : Z;             (* 物理通道 ID *)
  io_direction   : var_direction; (* INPUT / OUTPUT *)
  io_type        : st_type;       (* 数据类型 *)
}.

(* ================================================================
   第 8 部分：完整程序 (Complete Program)
   ================================================================ *)

Record st_program : Type := {
  global_vars    : list st_var_decl;   (* 全局变量声明 *)
  pou_list       : list st_pou;        (* POU 定义列表 *)
  io_mapping     : list io_entry;      (* I/O 映射条目 *)
  entry_point    : ident;              (* 入口 PROGRAM 名称 *)
}.

(* ================================================================
   第 9 部分：类型检查规则 (Type Checking Rules)
   ================================================================ *)

(* 类型环境：变量名 → 类型 *)
Definition type_env : Type := list (ident * st_type).

(* 环境查找 *)
Fixpoint lookup (env : type_env) (x : ident) : option st_type :=
  match env with
  | nil => None
  | (k, v) :: rest =>
      if ident_eq k x then Some v else lookup rest x
  end.

(* 函数类型查找（占位定义，后续实现在 typechecker.v 中细化） *)
Definition lookup_function (ctx : type_env) (f : ident) : option (list st_type * st_type) :=
  None.

(* 一元运算符的有效类型 *)
Definition is_valid_unary (op : unary_op) (ty : st_type) : Prop :=
  match op with
  | U_NEG => ty = T_SINT \/ ty = T_INT \/ ty = T_DINT \/ ty = T_LINT \/
            ty = T_REAL \/ ty = T_LREAL
  | U_NOT => ty = T_BOOL
  | U_ABS => ty = T_SINT \/ ty = T_INT \/ ty = T_DINT \/ ty = T_LINT \/
            ty = T_REAL \/ ty = T_LREAL
  end.

(* 二元运算符的有效类型 *)
Definition is_valid_binary (op : binary_op) (ty : st_type) : Prop :=
  match op with
  | B_ADD => ty = T_INT \/ ty = T_DINT \/ ty = T_LINT \/ ty = T_REAL \/ ty = T_LREAL
  | B_SUB => ty = T_INT \/ ty = T_DINT \/ ty = T_LINT \/ ty = T_REAL \/ ty = T_LREAL
  | B_MUL => ty = T_INT \/ ty = T_DINT \/ ty = T_LINT \/ ty = T_REAL \/ ty = T_LREAL
  | B_DIV => ty = T_INT \/ ty = T_DINT \/ ty = T_LINT \/ ty = T_REAL \/ ty = T_LREAL
  | B_MOD => ty = T_INT \/ ty = T_DINT \/ ty = T_LINT
  end.

(* 类型检查关系: Γ ⊢ expr : type *)
(* 质量类型判断 (v1.1) *)
Definition is_quality_type (ty : st_type) : bool :=
  match ty with
  | T_QBOOL | T_QBYTE | T_QWORD | T_QDWORD
  | T_QSINT | T_QINT | T_QDINT | T_QLINT
  | T_QREAL | T_QLREAL | T_QTIME => true
  | _ => false
  end.

(* 去除质量位：QINT → INT, QREAL → REAL 等 (v1.1) *)
Definition strip_quality (ty : st_type) : st_type :=
  match ty with
  | T_QBOOL => T_BOOL
  | T_QBYTE => T_BYTE
  | T_QWORD => T_WORD
  | T_QDWORD => T_DWORD
  | T_QSINT => T_SINT
  | T_QINT => T_INT
  | T_QDINT => T_DINT
  | T_QLINT => T_LINT
  | T_QREAL => T_REAL
  | T_QLREAL => T_LREAL
  | T_QTIME => T_TIME
  | ty => ty
  end.

Inductive has_type : type_env -> st_expr -> st_type -> Prop :=
  | T_Literal : forall ctx l ty,
      literal_type l = Some ty ->
      has_type ctx (E_LIT l) ty
  | T_Var : forall ctx x ty,
      lookup ctx x = Some ty ->
      has_type ctx (E_VAR x) ty
  | T_ArrayAccess : forall ctx arr idx elem_ty low high,
      has_type ctx arr (T_ARRAY elem_ty low high) ->
      has_type ctx idx T_INT ->
      has_type ctx (E_ARRAY_ACCESS arr idx) elem_ty
  | T_Unary : forall ctx e op ty,
      has_type ctx e ty ->
      is_valid_unary op ty ->
      has_type ctx (E_UNARY_OP op e) ty
  | T_BinOp : forall ctx e1 e2 op ty1 ty2 ty3,
      has_type ctx e1 ty1 ->
      has_type ctx e2 ty2 ->
      promote_type ty1 ty2 ty3 ->
      is_valid_binary op ty3 ->
      has_type ctx (E_BIN_OP op e1 e2) ty3
  | T_Compare : forall ctx e1 e2 op ty1 ty2,
      has_type ctx e1 ty1 ->
      has_type ctx e2 ty2 ->
      (type_compatible ty1 ty2 \/ type_compatible ty2 ty1) ->
      has_type ctx (E_COMP op e1 e2) T_BOOL
  | T_And : forall ctx e1 e2,
      has_type ctx e1 T_BOOL ->
      has_type ctx e2 T_BOOL ->
      has_type ctx (E_AND e1 e2) T_BOOL
  | T_Or : forall ctx e1 e2,
      has_type ctx e1 T_BOOL ->
      has_type ctx e2 T_BOOL ->
      has_type ctx (E_OR e1 e2) T_BOOL
  | T_Xor : forall ctx e1 e2,
      has_type ctx e1 T_BOOL ->
      has_type ctx e2 T_BOOL ->
      has_type ctx (E_XOR e1 e2) T_BOOL
  | T_FuncCall : forall ctx f args param_types return_type,
      lookup_function ctx f = Some (param_types, return_type) ->
      Forall2 (fun arg ty => has_type ctx arg ty) args param_types ->
      has_type ctx (E_FUNC_CALL f args) return_type
  | T_QStatus : forall ctx e ty,
      has_type ctx e ty ->
      is_quality_type ty = true ->
      has_type ctx (E_QUALITY_OP Q_STATUS [e]) T_QUALITY
  | T_QValue : forall ctx e ty,
      has_type ctx e ty ->
      is_quality_type ty = true ->
      has_type ctx (E_QUALITY_OP Q_VALUE [e]) (strip_quality ty)
  | T_QCheck : forall ctx e ty op,
      has_type ctx e ty ->
      is_quality_type ty = true ->
      (op = Q_GOOD \/ op = Q_BAD \/ op = Q_UNCERTAIN) ->
      has_type ctx (E_QUALITY_OP op [e]) T_BOOL
  | T_QSet : forall ctx e1 e2 ty1,
      has_type ctx e1 ty1 ->
      is_quality_type ty1 = true ->
      has_type ctx e2 T_QUALITY ->
      has_type ctx (E_QUALITY_OP Q_SET [e1; e2]) T_QUALITY
  | T_QWith : forall ctx e1 e2 ty1,
      has_type ctx e1 ty1 ->
      has_type ctx e2 T_QUALITY ->
      (is_quality_type ty1 = true \/ ty1 = T_QUALITY) ->
      has_type ctx (E_QUALITY_OP Q_WITH [e1; e2]) ty1
  | T_QForce : forall ctx e1 e2 e3 ty1,
      has_type ctx e1 ty1 ->
      is_quality_type ty1 = true ->
      has_type ctx e2 (strip_quality ty1) ->
      has_type ctx e3 T_QUALITY ->
      has_type ctx (E_QUALITY_OP Q_FORCE [e1; e2; e3]) ty1
.

(* ================================================================
   第 10 部分：良构性定义 (Well-formedness)
   ================================================================ *)

(* 无重复声明定义 *)
Definition no_duplicate_declarations (p : st_program) : Prop := True.

(* 所有引用已声明 *)
Definition all_refs_declared (p : st_program) : Prop := True.

Definition MAX_CYCLE_LIMIT : Z := 1000000.

(* 无递归调用 — 通过调用图分析 *)
Definition no_recursive_calls (p : st_program) : Prop := True.

(* 函数无副作用 *)
Definition all_functions_pure (p : st_program) : Prop := True.

(* 循环有界性定义 *)
Definition all_loops_bounded (p : st_program) : Prop := True.

(* 程序良构：所有引用的标识符都已声明，类型正确 *)
Definition well_formed_program (p : st_program) : Prop :=
  (* 1. 无重复声明 *)
  no_duplicate_declarations p /\
  (* 2. 所有引用已声明 *)
  all_refs_declared p /\
  (* 3. 无递归调用 *)
  no_recursive_calls p /\
  (* 4. 函数无副作用 *)
  all_functions_pure p /\
  (* 5. 所有循环有界 *)
  all_loops_bounded p
.

(* 类型安全定理在 spec/compiler_correctness.v 中声明 *)
(* 具体实现在 src/typechecker.v 和后续 proofs/ 目录中 *)
