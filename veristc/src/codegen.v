(* ================================================================
   veristc/src/codegen.v
   CoreST → SafeASM 代码生成器 + 正确性证明

   实现:
     1. compile_expr — CoreST 表达式 → SafeASM 指令序列
     2. compile_stmt — CoreST 语句 → SafeASM 指令序列
     3. compile_program — CoreST 程序 → SafeASM 模块
     4. 值栈保持证明 — 表达式编译的正确性
     5. 语句保持证明 — 基本语句编译的正确性

   约定:
     - 变量映射: LOCAL_GET/LOCAL_SET idx
     - 控制流: BLOCK/LOOP/BR/BR_IF（结构化控制流）
     - 所有值在值栈上传递
   ================================================================ *)

From Stdlib Require Import List.
From Stdlib Require Import ZArith.
From Stdlib Require Import String.
From Stdlib Require Import Lia.
From Stdlib Require Import Bool.
Require Import veristc_spec.safest.
Require Import veristc_spec.safeasm.
Require Import veristc_src.desugar.
Require Import veristc_spec.st_semantics.
Require Import veristc_src.analysis.
Local Open Scope Z_scope.
Import ListNotations.

Lemma app_singleton_cons :
  forall (A : Type) (xs ys : list A) (x : A),
    (xs ++ [x]) ++ ys = xs ++ x :: ys.
Proof.
  intros A xs ys x.
  induction xs as [|z zs IH]; simpl.
  - reflexivity.
  - rewrite IH. reflexivity.
Qed.

Lemma app_cons_assoc :
  forall (A : Type) (xs zs : list A) (y : A) (ys : list A),
    (xs ++ (y :: ys)) ++ zs = xs ++ (y :: (ys ++ zs)).
Proof.
  intros A xs zs y ys.
  induction xs as [|a xs IH]; simpl.
  - reflexivity.
  - rewrite IH. reflexivity.
Qed.

  (* ================================================================
   第 1 部分：编译环境 (Compilation Environment)

   变量名 → 局部变量索引（后续可扩展为内存偏移）
   ================================================================ *)

Definition compile_env : Type := list (ident * Z).

(* 影子质量内存区基址（编译器确定的常数）*)
Definition Q_BASE : Z := 256.  (* 假设位于线性内存偏移 256 处 *)

(* 在编译环境中查找变量索引 *)
Fixpoint lookup_var_idx (env : compile_env) (x : ident) : option Z :=
  match env with
  | nil => None
  | (k, idx) :: rest =>
      match x, k with
      | ID s1, ID s2 => if String.eqb s1 s2 then Some idx else lookup_var_idx rest x
      end
  end.

Definition compile_env_injective (env : compile_env) : Prop :=
  forall (x y : ident) (ix iy : Z),
    lookup_var_idx env x = Some ix ->
    lookup_var_idx env y = Some iy ->
    ix = iy ->
    x = y.

Definition compile_env_nonneg (env : compile_env) : Prop :=
  forall (x : ident) (idx : Z),
    lookup_var_idx env x = Some idx ->
    0 <= idx.

Definition compile_env_fits_frame (env : compile_env) (f : sasm_frame) : Prop :=
  forall (x : ident) (idx : Z),
    lookup_var_idx env x = Some idx ->
    (Z.to_nat idx < List.length f.(frame_locals))%nat.

(* 类型环境：变量名 → 类型 *)
Definition compile_type_env : Type := list (ident * st_type).

(* 构建类型环境 *)
Definition build_compile_type_env (f : corest_function) : compile_type_env :=
  f.(cfunc_params) ++ f.(cfunc_locals).

(* 从类型环境中查找变量类型 *)
Fixpoint lookup_var_type (env_ty : compile_type_env) (x : ident) : option st_type :=
  match env_ty with
  | nil => None
  | (y, ty) :: rest =>
      match x, y with
      | ID s1, ID s2 => if String.eqb s1 s2 then Some ty else lookup_var_type rest x
      end
  end.

(* ST 类型 → SafeASM 值类型（用于编译时的类型映射） *)
Definition st_type_to_sasm (t : st_type) : sasm_value_type :=
  match t with
  | T_BOOL | T_BYTE | T_SINT  => I32
  | T_WORD | T_INT             => I32
  | T_DWORD | T_DINT           => I32
  | T_REAL                     => F32
  | T_LREAL                    => F64
  | T_TIME                     => I64
  | T_LINT                     => I64
  | T_QUALITY                  => I32
  | T_QBOOL | T_QBYTE | T_QWORD | T_QDWORD
  | T_QSINT | T_QINT | T_QDINT => I32
  | T_QLINT                    => I64
  | T_QREAL                    => F32
  | T_QLREAL                   => F64
  | T_QTIME                    => I64
  | T_ARRAY _ _ _             => I32  (* 数组基址视为 i32 指针 *)
  end.

(* 从 CoreST 函数构建编译环境 *)
Fixpoint assign_env_indices (vars : list (ident * st_type)) (base : Z) : compile_env :=
  match vars with
  | nil => nil
  | (n, _) :: rest => (n, base) :: assign_env_indices rest (base + 1)
  end.

Definition build_compile_env (f : corest_function) : compile_env :=
  assign_env_indices f.(cfunc_params) 0 ++
  assign_env_indices f.(cfunc_locals) (Z.of_nat (List.length f.(cfunc_params))).

Lemma lookup_var_idx_assign_env_indices :
  forall (vars : list (ident * st_type)) (base : Z)
         (x : ident) (idx : Z),
    lookup_var_idx (assign_env_indices vars base) x = Some idx ->
    exists n : nat,
      List.nth_error (List.map fst vars) n = Some x /\
      idx = base + Z.of_nat n.
Proof.
  induction vars as [|[y ty] rest IH]; intros base x idx H; simpl in H.
  - discriminate.
  - destruct x as [sx], y as [sy]; simpl in H.
    destruct (String.eqb sx sy) eqn:Heq.
    + apply String.eqb_eq in Heq. subst sy.
      inversion H; subst idx.
      exists 0%nat. simpl. split; [reflexivity |].
      rewrite Z.add_0_r. reflexivity.
    + destruct (IH (base + 1) (ID sx) idx H)
        as [n [Hnth Hidx]].
      exists (S n). simpl. split.
      * exact Hnth.
      * simpl in Hidx. lia.
Qed.

Lemma lookup_var_idx_of_type_assign :
  forall (vars : list (ident * st_type)) (base : Z)
         (x : ident) (ty : st_type),
    lookup_var_type vars x = Some ty ->
    exists idx : Z,
      lookup_var_idx (assign_env_indices vars base) x = Some idx.
Proof.
  induction vars as [|[y y_ty] rest IH]; intros base x ty Htype;
    simpl in Htype.
  - discriminate.
  - destruct x as [sx], y as [sy]; simpl in Htype.
    destruct (String.eqb sx sy) eqn:Heq.
    + apply String.eqb_eq in Heq. subst sy.
      inversion Htype; subst ty.
      exists base. simpl. rewrite String.eqb_refl. reflexivity.
    + destruct (IH (base + 1) (ID sx) ty Htype) as [idx Hidx].
      exists idx. simpl. rewrite Heq. exact Hidx.
Qed.

Lemma assign_env_indices_nonneg :
  forall (vars : list (ident * st_type)) (base : Z),
    0 <= base ->
    compile_env_nonneg (assign_env_indices vars base).
Proof.
  intros vars base Hbase x idx Hlook.
  destruct (lookup_var_idx_assign_env_indices vars base x idx Hlook)
    as [n [_ Hidx]].
  subst idx.
  pose proof (Zle_0_nat n). lia.
Qed.

Lemma assign_env_indices_injective :
  forall (vars : list (ident * st_type)) (base : Z),
    compile_env_injective (assign_env_indices vars base).
Proof.
  intros vars base x y ix iy Hx Hy Heq.
  destruct (lookup_var_idx_assign_env_indices vars base x ix Hx)
    as [nx [Hnx Hix]].
  destruct (lookup_var_idx_assign_env_indices vars base y iy Hy)
    as [ny [Hny Hiy]].
  assert (Hnxy : nx = ny) by lia.
  subst ny.
  rewrite Hnx in Hny.
  inversion Hny. subst. reflexivity.
Qed.

Lemma assign_env_indices_app :
  forall (xs ys : list (ident * st_type)) (base : Z),
    assign_env_indices (xs ++ ys) base =
    assign_env_indices xs base ++
    assign_env_indices ys (base + Z.of_nat (List.length xs)).
Proof.
  induction xs as [|[x ty] rest IH]; intros ys base; simpl.
  - rewrite Z.add_0_r. reflexivity.
  - rewrite IH.
    apply app_inv_head with (l := assign_env_indices rest (base + 1)).
    replace (base + 1 + Z.of_nat (Datatypes.length rest))
      with (base + Z.pos (PosDef.Pos.of_succ_nat (Datatypes.length rest)))
      by (rewrite Zpos_P_of_succ_nat; ring).
    reflexivity.
Qed.

Lemma build_compile_env_idx_of_type :
  forall (cf : corest_function) (x : ident) (ty : st_type),
    lookup_var_type (build_compile_type_env cf) x = Some ty ->
    exists idx : Z, lookup_var_idx (build_compile_env cf) x = Some idx.
Proof.
  intros cf x ty Htype.
  unfold build_compile_env, build_compile_type_env in *.
  rewrite <- assign_env_indices_app.
  apply (lookup_var_idx_of_type_assign
           (cf.(cfunc_params) ++ cf.(cfunc_locals)) 0 x ty Htype).
Qed.

Lemma assign_env_indices_bound :
  forall (vars : list (ident * st_type)) (base : Z)
         (x : ident) (idx : Z),
    lookup_var_idx (assign_env_indices vars base) x = Some idx ->
    base <= idx < base + Z.of_nat (List.length vars).
Proof.
  intros vars base x idx Hlook.
  destruct (lookup_var_idx_assign_env_indices vars base x idx Hlook)
    as [n [Hnth Hidx]].
  subst idx.
  split; [lia |].
  assert (Hnmap : (n < List.length (List.map fst vars))%nat).
  { apply (List.nth_error_Some (List.map fst vars) n).
    rewrite Hnth. discriminate. }
  rewrite List.length_map in Hnmap.
  lia.
Qed.

Lemma build_compile_env_nonneg :
  forall (f : corest_function),
    compile_env_nonneg (build_compile_env f).
Proof.
  intros f.
  unfold build_compile_env.
  rewrite <- assign_env_indices_app.
  apply assign_env_indices_nonneg. lia.
Qed.

Lemma build_compile_env_injective :
  forall (f : corest_function),
    compile_env_injective (build_compile_env f).
Proof.
  intros f.
  unfold build_compile_env.
  rewrite <- assign_env_indices_app.
  apply assign_env_indices_injective.
Qed.

Lemma build_compile_env_bound :
  forall (f : corest_function) (x : ident) (idx : Z),
    lookup_var_idx (build_compile_env f) x = Some idx ->
    0 <= idx <
      Z.of_nat (List.length f.(cfunc_params) +
                List.length f.(cfunc_locals)).
Proof.
  intros f x idx Hlook.
  unfold build_compile_env in Hlook.
  rewrite <- assign_env_indices_app in Hlook.
  pose proof (assign_env_indices_bound
                (f.(cfunc_params) ++ f.(cfunc_locals)) 0 x idx Hlook)
    as Hbound.
  rewrite List.length_app in Hbound.
  simpl in Hbound.
  lia.
Qed.

(* ================================================================
   第 2 部分：指令编码尺寸计算

   用于填充 BLOCK/LOOP 的 len 参数。
   ================================================================ *)

(* 指令编码后的字节数 *)
Definition instr_size (i : sasm_instr) : Z :=
  match i with
  (* 无立即数: 1 字节 *)
  | UNREACHABLE | NOP | RETURN | DROP | SELECT => 1
  | I32_EQZ | I32_EQ | I32_NE | I32_LT_S | I32_LE_S | I32_GT_S | I32_GE_S => 1
  | I32_ADD | I32_SUB | I32_MUL | I32_DIV_S | I32_REM_S => 1
  | I32_AND | I32_OR | I32_XOR | I32_SHL | I32_SHR_S | I32_ROTL | I32_ROTR => 1
  | I64_EQZ | I64_EQ | I64_NE | I64_LT_S | I64_LE_S | I64_GT_S | I64_GE_S => 1
  | I64_ADD | I64_SUB | I64_MUL | I64_DIV_S | I64_REM_S => 1
  | I64_AND | I64_OR | I64_XOR | I64_SHL | I64_SHR_S => 1
  | F32_ADD | F32_SUB | F32_MUL | F32_DIV => 1
  | F32_EQ | F32_NE | F32_LT | F32_LE | F32_GT | F32_GE => 1
  | F32_ABS | F32_NEG | F32_SQRT => 1
  | F64_ADD | F64_SUB | F64_MUL | F64_DIV => 1
  | F64_EQ | F64_NE | F64_LT | F64_LE | F64_GT | F64_GE => 1
  | F64_ABS | F64_NEG | F64_SQRT => 1
  | I32_WRAP_I64 | I64_EXTEND_I32_S => 1
  | I32_TRUNC_F32_S | I32_TRUNC_F64_S => 1
  | F32_CONVERT_I32_S | F64_CONVERT_I32_S => 1

  (* 1 字节操作码 + 4 字节立即数 *)
  | BLOCK _ | LOOP _ => 5
  | BR _ | BR_IF _ => 5
  | CALL _ => 5
  | LOCAL_GET _ | LOCAL_SET _ | LOCAL_TEE _ => 5
  | I32_CONST _ => 5
  | I64_CONST _ => 9  (* 1 + 8 *)

  (* 浮点常量 *)
  | F32_CONST _ => 5   (* 1 + 4 *)
  | F64_CONST _ => 9   (* 1 + 8 *)

  (* 内存操作: 1 + 4 (memory_arg) *)
  | I32_LOAD _ | I64_LOAD _ | F32_LOAD _ | F64_LOAD _ | I32_LOAD8_U _ => 5
  | I32_STORE _ | I64_STORE _ | F32_STORE _ | F64_STORE _ | I32_STORE8 _ => 5

  (* 安全扩展 *)
  | SAFE_ASSERT (ASSERT_CYCLE_LIMIT _) => 6    (* 1+1+4 *)
  | SAFE_ASSERT (ASSERT_STACK_DEPTH _) => 6
  | SAFE_ASSERT (ASSERT_MEM_BOUNDS _ _) => 10  (* 1+1+4+4 *)
  | SAFE_BOUNDS_CHECK _ _ => 9              (* 1+4+4 *)
  end.

(* 指令序列的编码总字节数 *)
Fixpoint instr_seq_size (instrs : list sasm_instr) : Z :=
  match instrs with
  | nil => 0
  | i :: rest => instr_size i + instr_seq_size rest
  end.

Lemma instr_seq_size_eq_total :
  forall (instrs : list sasm_instr),
    instr_seq_size instrs = instrs_total_size instrs.
Proof.
  induction instrs as [|i rest IH]; simpl.
  - reflexivity.
  - rewrite IH. reflexivity.
Qed.

(* ================================================================
   第 3 部分：表达式编译 (Expression Compilation)

   将 CoreST 表达式编译为 SafeASM 指令序列。
   编译结果在值栈顶留下表达式的值。
   ================================================================ *)

Definition compile_quality_status (env : compile_env) (args : list corest_expr) : list sasm_instr :=
  match args with
  | [CE_VAR x] =>
      match lookup_var_idx env x with
      | Some idx => [I32_CONST Q_BASE; I32_CONST idx; I32_ADD;
                     I32_LOAD8_U {| mem_align := 2; mem_offset := 0 |}]
      | None => [I32_CONST 0]
      end
  | _ => [I32_CONST 0]
  end.

Fixpoint compile_expr (env : compile_env) (e : corest_expr) {struct e} : list sasm_instr :=
  match e with
  | CE_LIT l =>
      match l with
      | L_BOOL b => [I32_CONST (if b then 1 else 0)]
      | L_INT n => [I32_CONST n]
      | L_REAL f => [F32_CONST f]
      | L_TIME t => [I64_CONST t]
      | L_LINT n => [I64_CONST n]           (* v1.1 *)
      | L_LREAL f => [F64_CONST f]          (* v1.1 *)
      end

  | CE_VAR x =>
      match lookup_var_idx env x with
      | Some idx => [LOCAL_GET idx]
      | None => [I32_CONST 0]  (* 未定义变量 → 安全默认值 *)
      end

  | CE_ARRAY_ACCESS arr idx =>
      (* arr[idx] = [arr_base] [idx_offset] I32_ADD I32_LOAD *)
      compile_expr env arr ++
      compile_expr env idx ++
      [I32_ADD; I32_LOAD (Build_memory_arg 2 0)]

  | CE_UNARY_OP U_NEG e1 =>
      (* -x = 0 - x *)
      [I32_CONST 0] ++ compile_expr env e1 ++ [I32_SUB]
  | CE_UNARY_OP U_NOT e1 =>
      compile_expr env e1 ++ [I32_EQZ]
  | CE_UNARY_OP U_ABS e1 =>
      (* abs(x) = x >= 0 ? x : -x
         用 LOCAL_SET/GET 暂存 x 避免使用 LOCAL_TEE *)
      compile_expr env e1 ++
      [LOCAL_SET 255;
       LOCAL_GET 255;
       I32_CONST 0;
       I32_LT_S;          (* x < 0 ? *)
       I32_CONST 0;
       LOCAL_GET 255;
       I32_SUB;           (* 0 - x = -x *)
       LOCAL_GET 255;
       SELECT]

  | CE_BIN_OP B_ADD e1 e2 =>
      compile_expr env e1 ++ compile_expr env e2 ++ [I32_ADD]
  | CE_BIN_OP B_SUB e1 e2 =>
      compile_expr env e1 ++ compile_expr env e2 ++ [I32_SUB]
  | CE_BIN_OP B_MUL e1 e2 =>
      compile_expr env e1 ++ compile_expr env e2 ++ [I32_MUL]
  | CE_BIN_OP B_DIV e1 e2 =>
      compile_expr env e1 ++ compile_expr env e2 ++
      [I32_DIV_S]
  | CE_BIN_OP B_MOD e1 e2 =>
      compile_expr env e1 ++ compile_expr env e2 ++ [I32_REM_S]

  | CE_COMP C_EQ e1 e2 =>
      compile_expr env e1 ++ compile_expr env e2 ++ [I32_EQ]
  | CE_COMP C_NE e1 e2 =>
      compile_expr env e1 ++ compile_expr env e2 ++ [I32_NE]
  | CE_COMP C_LT e1 e2 =>
      compile_expr env e1 ++ compile_expr env e2 ++ [I32_LT_S]
  | CE_COMP C_LE e1 e2 =>
      compile_expr env e1 ++ compile_expr env e2 ++ [I32_LE_S]
  | CE_COMP C_GT e1 e2 =>
      compile_expr env e1 ++ compile_expr env e2 ++ [I32_GT_S]
  | CE_COMP C_GE e1 e2 =>
      compile_expr env e1 ++ compile_expr env e2 ++ [I32_GE_S]

  | CE_AND e1 e2 =>
      (* e1 AND e2 = e1 & e2（布尔值 0/1 等效于位运算） *)
      compile_expr env e1 ++ compile_expr env e2 ++ [I32_AND]

  | CE_OR e1 e2 =>
      (* e1 OR e2 = e1 | e2（布尔值 0/1 等效于位运算） *)
      compile_expr env e1 ++ compile_expr env e2 ++ [I32_OR]

  | CE_XOR e1 e2 =>
      compile_expr env e1 ++ compile_expr env e2 ++ [I32_XOR]

  | CE_FUNC_CALL f args =>
      (* 参数从右到左入栈（符合 ST 调用约定） *)
      let compiled_args := List.fold_right (fun arg acc =>
        compile_expr env arg ++ acc) [] (List.rev args) in
      [I32_CONST 0]  (* 函数调用语义暂为 ST_V_INT 0，与 corest_eval_expr 的占位语义保持一致 *)

  | CE_QUALITY_OP Q_STATUS args =>
      match args with
      | [CE_VAR x] =>
          match lookup_var_idx env x with
          | Some idx =>
              (* Q_STATUS(x) = 读影子质量字节 mem[Q_BASE + idx] *)
              [I32_CONST Q_BASE; I32_CONST idx; I32_ADD; I32_LOAD8_U (Build_memory_arg 2 0)]
          | None => [I32_CONST 0]  (* 未知变量：默认 GOOD *)
          end
      | _ => [I32_CONST 0]  (* 非常量参数：默认 GOOD *)
      end
  | CE_QUALITY_OP Q_VALUE args =>
      (* Q_VALUE(x) = 取 Q 变量的值部分（与普通变量引用相同） *)
      List.concat (List.map (compile_expr env) args)
  | CE_QUALITY_OP Q_GOOD args =>
      (* Q_GOOD(x) = Q_STATUS(x) == 0 *)
      compile_quality_status env args ++ [I32_CONST 0; I32_EQ]
  | CE_QUALITY_OP Q_BAD args =>
      compile_quality_status env args ++ [I32_CONST 1; I32_EQ]
  | CE_QUALITY_OP Q_SET args =>
      (* Q_SET(x, q) = 写影子质量字节 mem[Q_BASE + idx] = q *)
      match args with
      | [CE_VAR x; qexpr] =>
          match lookup_var_idx env x with
          | Some idx =>
              compile_expr env qexpr ++
              [I32_CONST Q_BASE; I32_CONST idx; I32_ADD; I32_STORE8 (Build_memory_arg 2 0)]
          | None => [NOP]
          end
      | _ => [NOP]
      end
  | CE_QUALITY_OP Q_WITH args =>
      (* Q_WITH(v, q) = 值 + 质量码同时入栈 *)
      match args with
      | [v; q] => compile_expr env v ++ compile_expr env q
      | _ => [I32_CONST 0; I32_CONST 0]
      end
  | CE_QUALITY_OP Q_FORCE args =>
      (* Q_FORCE(x, v, q) = 赋值 v 到 x 的值部分 + Q_SET(x, q) *)
      match args with
      | [CE_VAR x; v; q] =>
          match lookup_var_idx env x with
          | Some idx =>
              compile_expr env v ++ [LOCAL_SET idx] ++
              compile_expr env q ++
              [I32_CONST Q_BASE; I32_CONST idx; I32_ADD;
               I32_STORE8 {| mem_align := 2; mem_offset := 0 |}]
          | None => [NOP]
          end
      | _ => [NOP]
      end
  end.

(* 带类型的表达式编译：根据期望类型分派 I32/I64/F32/F64 指令。
   当已知表达式的结果类型时（例如赋值语句的 RHS），用此函数代替 compile_expr 以生成正确的宽位指令。 *)
Fixpoint compile_expr_typed (env : compile_env) (env_ty : compile_type_env) (ty : st_type) (e : corest_expr) {struct e} : list sasm_instr :=
  match e with
  | CE_LIT l =>
      match l, ty with
      | L_LINT n, _ => [I64_CONST n]
      | L_LREAL f, _ => [F64_CONST f]
      | L_TIME t, _ => [I64_CONST t]
      | L_INT n, T_LINT => [I64_CONST n]
      | L_REAL f, T_LREAL => [F64_CONST f]
      | _, _ => compile_expr env e
      end
  | CE_UNARY_OP op e1 =>
      let c1 := compile_expr_typed env env_ty ty e1 in
      match op, ty with
      | U_NEG, T_LINT => [I64_CONST 0] ++ c1 ++ [I64_SUB]
      | U_NEG, T_REAL => c1 ++ [F32_NEG]
      | U_NEG, T_LREAL => c1 ++ [F64_NEG]
      | U_NEG, _ => [I32_CONST 0] ++ c1 ++ [I32_SUB]
      | U_ABS, T_LINT =>
          c1 ++ [LOCAL_SET 255; LOCAL_GET 255; I64_CONST 0; I64_LT_S;
                 I64_CONST 0; LOCAL_GET 255; I64_SUB; LOCAL_GET 255; SELECT]
      | U_ABS, T_REAL => c1 ++ [F32_ABS]
      | U_ABS, T_LREAL => c1 ++ [F64_ABS]
      | U_ABS, _ =>
          c1 ++ [LOCAL_SET 255; LOCAL_GET 255; I32_CONST 0; I32_LT_S;
                 I32_CONST 0; LOCAL_GET 255; I32_SUB; LOCAL_GET 255; SELECT]
      | U_NOT, _ => c1 ++ [I32_EQZ]
      end
  | CE_BIN_OP op e1 e2 =>
      let c1 := compile_expr env e1 in
      let c2 := compile_expr env e2 in
      c1 ++ c2 ++
      match ty with
      | T_LINT =>
          match op with
          | B_ADD => [I64_ADD] | B_SUB => [I64_SUB] | B_MUL => [I64_MUL]
          | B_DIV => [I64_DIV_S] | B_MOD => [I64_REM_S]
          end
      | T_LREAL =>
          match op with
          | B_ADD => [F64_ADD] | B_SUB => [F64_SUB] | B_MUL => [F64_MUL]
          | B_DIV => [F64_DIV] | _ => [F64_ADD]
          end
      | T_REAL =>
          match op with
          | B_ADD => [F32_ADD] | B_SUB => [F32_SUB] | B_MUL => [F32_MUL]
          | B_DIV => [F32_DIV] | _ => [F32_ADD]
          end
      | _ =>
          match op with
          | B_ADD => [I32_ADD] | B_SUB => [I32_SUB] | B_MUL => [I32_MUL]
          | B_DIV => [I32_DIV_S] | B_MOD => [I32_REM_S]
          end
      end
  | CE_COMP op e1 e2 =>
      compile_expr env e1 ++ compile_expr env e2 ++
      match ty with
      | T_LINT =>
          match op with
          | C_EQ => [I64_EQ] | C_NE => [I64_NE] | C_LT => [I64_LT_S]
          | C_LE => [I64_LE_S] | C_GT => [I64_GT_S] | C_GE => [I64_GE_S]
          end
      | T_LREAL | T_REAL =>
          match op with
          | C_EQ => [F64_EQ] | C_NE => [F64_NE] | C_LT => [F64_LT]
          | C_LE => [F64_LE] | C_GT => [F64_GT] | C_GE => [F64_GE]
          end
      | _ =>
          match op with
          | C_EQ => [I32_EQ] | C_NE => [I32_NE] | C_LT => [I32_LT_S]
          | C_LE => [I32_LE_S] | C_GT => [I32_GT_S] | C_GE => [I32_GE_S]
          end
      end
  | _ => compile_expr env e
  end.

Definition codegen_core_ty (ty : st_type) : Prop :=
  ty = T_BOOL \/ ty = T_INT \/ ty = T_DINT.

Lemma list_set_length :
  forall (A : Type) (l : list A) (n : nat) (x : A),
    (n < List.length l)%nat ->
    List.length (list_set l n x) = List.length l.
Proof.
  intros A l.
  induction l as [|a l IH]; intros n x Hlt; simpl in Hlt.
  - lia.
  - destruct n as [|n]; simpl.
    + reflexivity.
    + rewrite IH.
      * reflexivity.
      * apply Nat.succ_lt_mono in Hlt. exact Hlt.
Qed.

Lemma list_set_nth_same :
  forall (A : Type) (l : list A) (n : nat) (x : A),
    List.nth_error (list_set l n x) n = Some x.
Proof.
  intros A lst n.
  revert lst.
  induction n as [|n IH]; intros xs x.
  - destruct xs; simpl; reflexivity.
  - destruct xs as [|a tail]; simpl.
    + change (List.nth_error (List.repeat x (S n)) n = Some x).
      apply List.nth_error_repeat. lia.
    + exact (IH tail x).
Qed.

Lemma list_set_nth_diff :
  forall (A : Type) (l : list A) (n m : nat) (x : A),
    n <> m ->
    (n < List.length l)%nat ->
    List.nth_error (list_set l n x) m = List.nth_error l m.
Proof.
  intros A lst n.
  revert lst.
  induction n as [|n IH]; intros xs m x Hneq Hlt.
  - destruct xs as [|a tail]; [simpl in Hlt; lia|].
    destruct m as [|m]; simpl.
    + exfalso. apply Hneq. reflexivity.
    + reflexivity.
  - destruct xs as [|a tail]; [simpl in Hlt; lia|].
    destruct m as [|m]; simpl.
    + reflexivity.
    + assert (Hneq' : n <> m) by
        (intro H; apply Hneq; f_equal; exact H).
      apply Nat.succ_lt_mono in Hlt.
      exact (IH tail m x Hneq' Hlt).
Qed.

Lemma compile_expr_typed_core_eq :
  forall (env : compile_env) (env_ty : compile_type_env)
         (ty : st_type) (e : corest_expr),
    codegen_core_ty ty ->
    compile_expr_typed env env_ty ty e = compile_expr env e.
Proof.
  intros env env_ty ty e Hcore.
  destruct Hcore as [H | [H | H]]; subst.
  all: induction e as [l | x | e1 e2 IHe1 IHe2 | u e IHe
    | b e1 e2 IHe1 IHe2 | c e1 e2 IHe1 IHe2
    | e1 e2 IHe1 IHe2 | e1 e2 IHe1 IHe2 | e1 e2 IHe1 IHe2
    | f args | q args]; simpl.
  - destruct l; reflexivity.
  - reflexivity.
  - reflexivity.
  - destruct u; simpl; rewrite IHe; reflexivity.
  - destruct b; reflexivity.
  - destruct c; reflexivity.
  - reflexivity.
  - reflexivity.
  - reflexivity.
  - reflexivity.
  - reflexivity.
  - destruct l; reflexivity.
  - reflexivity.
  - reflexivity.
  - destruct u; simpl; rewrite IHe; reflexivity.
  - destruct b; reflexivity.
  - destruct c; reflexivity.
  - reflexivity.
  - reflexivity.
  - reflexivity.
  - reflexivity.
  - reflexivity.
  - destruct l; reflexivity.
  - reflexivity.
  - reflexivity.
  - destruct u; simpl; rewrite IHe; reflexivity.
  - destruct b; reflexivity.
  - destruct c; reflexivity.
  - reflexivity.
  - reflexivity.
  - reflexivity.
  - reflexivity.
  - reflexivity.
Qed.

(* ================================================================
   第 4 部分：语句编译 (Statement Compilation)

   将 CoreST 语句编译为 SafeASM 指令序列。
   使用 BLOCK/LOOP/BR/BR_IF 实现结构化控制流。
   ================================================================ *)

(* 控制流深度追踪（用于 BR depth 计算） *)
Inductive ctrl_stack_entry : Type :=
  | CTRL_BLOCK                  (* 普通 block *)
  | CTRL_LOOP                   (* 循环 block *)
.

(* 计算需要跳出的 depth: 从内到外搜索指定类型的 ctrl 入口 *)
Fixpoint find_ctrl_depth (stack : list ctrl_stack_entry) (target : ctrl_stack_entry) : Z :=
  match stack with
  | nil => 0
  | c :: rest =>
      match c, target with CTRL_BLOCK, CTRL_BLOCK => 0 | CTRL_LOOP, CTRL_LOOP => 0 | _, _ => 1 + find_ctrl_depth rest target end
  end.

(* ================================================================
   第 4a 部分：语句编译（单个语句）
   ================================================================ *)

Fixpoint compile_stmt (env : compile_env) (env_ty : compile_type_env) (s : corest_stmt) : list sasm_instr :=
  match s with
  | CS_ASSIGN x e =>
      let rhs :=
        match lookup_var_type env_ty x with
        | Some ty => compile_expr_typed env env_ty ty e
        | None => compile_expr env e
        end in
      match lookup_var_idx env x with
      | Some idx => rhs ++ [LOCAL_SET idx]
      | None => [NOP]  (* 未定义变量 → 跳过 *)
      end

  | CS_ARRAY_ASSIGN x idx e =>
      let addr := compile_expr env (CE_VAR x) in
      let idx_code := compile_expr env idx in
      let val_code := compile_expr env e in
      addr ++ idx_code ++ [I32_ADD] ++ val_code ++ [I32_STORE (Build_memory_arg 2 0)]

  | CS_IF cond then_body else_body =>
      (*
        BLOCK else_body_size + 5  (5 for BR at end of then)
          BLOCK then_body_size
            [cond]
            I32_EQZ
            BR_IF 0         ; cond=false → exit inner block → else
            [then_body]
            BR 1            ; skip else
          [else_body]
            BR 0            ; 显式退出外层 BLOCK，避免块栈残留
      *)
      let compiled_cond := compile_expr env cond in
      let compiled_then := List.concat (List.map (compile_stmt env env_ty) then_body) in
      let compiled_else :=
        List.concat (List.map (compile_stmt env env_ty) else_body) ++ [BR 0] in
      let then_size := instr_seq_size compiled_then in
      let br_to_end := BR 1 in       (* 1: exit outer block *)
      let br_to_else := BR_IF 0 in   (* 0: exit inner block *)
      let inner_block_instrs := compiled_cond ++ [I32_EQZ] ++
                                [br_to_else] ++ compiled_then ++ [br_to_end] in
      let outer_block_instrs :=
        [BLOCK (instr_seq_size inner_block_instrs)] ++
        inner_block_instrs ++ compiled_else in
      [BLOCK (instr_seq_size outer_block_instrs)] ++
      outer_block_instrs

  | CS_WHILE cond body =>
      (*
        BLOCK exit_size + 5   (5 for BR_IF at start)
          LOOP body_size + 10 (for header+br)
            [cond]
            I32_EQZ           ; not cond
            BR_IF 1           ; exit loop (depth 1 = outer BLOCK)
            [body]
            BR 0              ; continue loop
      *)
      let compiled_cond := compile_expr env cond in
      let compiled_body := List.concat (List.map (compile_stmt env env_ty) body) in
      let header_instrs := compiled_cond ++ [I32_EQZ; BR_IF 1] in
      let loop_body := compiled_body ++ [BR 0] in
      let loop_size := instr_seq_size (header_instrs ++ loop_body) in
      let exit_instrs := [LOOP loop_size] ++ header_instrs ++ loop_body in
      let exit_size := instr_seq_size exit_instrs in
      [BLOCK exit_size] ++ exit_instrs

  | CS_FB_CALL inst params =>
      (* FB 调用: 参数压栈 + CALL *)
      let compiled_params := List.concat (List.map (fun p => let _ := fst p in let e := snd p in
        compile_expr env e) params) in
      compiled_params ++ [CALL 0]  (* 函数索引暂为 0 *)

  | CS_RETURN => [RETURN]
  | CS_EXIT => [BR 0]  (* 退出当前 block *)

  | CS_BLOCK stmts =>
      List.concat (List.map (compile_stmt env env_ty) stmts)
  end.

Definition compile_stmts (env : compile_env) (env_ty : compile_type_env)
           (stmts : list corest_stmt) : list sasm_instr :=
  List.concat (List.map (compile_stmt env env_ty) stmts).

Lemma compile_stmt_assign_core_shape :
  forall (env : compile_env) (env_ty : compile_type_env)
         (x : ident) (e : corest_expr) (ty : st_type) (idx : Z),
    lookup_var_type env_ty x = Some ty ->
    codegen_core_ty ty ->
    lookup_var_idx env x = Some idx ->
    compile_stmt env env_ty (CS_ASSIGN x e) =
      compile_expr env e ++ [LOCAL_SET idx].
Proof.
  intros env env_ty x e ty idx Htype Hcore Hidx.
  unfold compile_stmt.
  rewrite Htype.
  rewrite Hidx.
  simpl.
  rewrite compile_expr_typed_core_eq by exact Hcore.
  reflexivity.
Qed.

Lemma compile_stmt_if_some_shape :
  forall (env : compile_env) (env_ty : compile_type_env)
         (cond : corest_expr) (then_stmts else_stmts : list corest_stmt),
    let c := compile_expr env cond in
    let t := compile_stmts env env_ty then_stmts in
    let e := compile_stmts env env_ty else_stmts in
    let inner := c ++ [I32_EQZ; BR_IF 0] ++ t ++ [BR 1] in
    let outer := [BLOCK (instr_seq_size inner)] ++ inner ++ e ++ [BR 0] in
    compile_stmt env env_ty (CS_IF cond then_stmts else_stmts) =
    [BLOCK (instr_seq_size outer)] ++ outer.
Proof.
  reflexivity.
Qed.

Lemma pc_enter_two_blocks :
  forall (m : sasm_module) (fn : sasm_function) (f : sasm_frame)
         (fr : frame_stack) (input : value_stack) (mem : list Z)
         (cyc : Z) (prefix rest suffix : list sasm_instr)
         (outer_len inner_len : Z),
    lookup_function m f.(frame_func_idx) = Some fn ->
    fn.(sasm_body) =
      prefix ++ BLOCK outer_len :: BLOCK inner_len :: rest ++ suffix ->
    f.(frame_pc) = instrs_total_size prefix ->
    exists (s' : runtime_state) (f' : sasm_frame),
      multi_pc_step m
        {| rt_values := input; rt_frames := f :: fr;
           rt_memory := mem; rt_cycle_cnt := cyc |}
        s' /\
      s'.(rt_frames) = f' :: fr /\
      s'.(rt_values) = input /\
      s'.(rt_memory) = mem /\
      f'.(frame_locals) = f.(frame_locals) /\
      f'.(frame_func_idx) = f.(frame_func_idx) /\
      f'.(frame_pc) = f.(frame_pc) + 10 /\
      f'.(frame_block_stack) =
        (f.(frame_pc) + 10 + inner_len) ::
        (f.(frame_pc) + 5 + outer_len) ::
        f.(frame_block_stack).
Proof.
  intros m fn f fr input mem cyc prefix rest suffix outer_len inner_len
    Hlook Hbody Hpc.
  set (outer_target := f.(frame_pc) + instr_size (BLOCK outer_len) + outer_len).
  set (next1 := instrs_total_size prefix + instr_size (BLOCK outer_len)).
  set (s0 := {| rt_values := input; rt_frames := f :: fr;
                rt_memory := mem; rt_cycle_cnt := cyc |}).
  set (f1 := frame_push_block (set_frame_pc f next1) outer_target).
  set (s1 := set_top_values_cycle s0 f1 input).
  assert (Hfetch1 : fetch_frame_instr m f = Some (BLOCK outer_len, next1)).
  { subst next1.
    apply fetch_frame_instr_app_exact with
      (fn := fn) (prefix := prefix) (i := BLOCK outer_len)
      (rest := BLOCK inner_len :: rest ++ suffix);
      [exact Hlook | exact Hbody | exact Hpc]. }
  assert (Hstep1 : multi_pc_step m s0 s1).
  { subst s1 s0 f1 outer_target.
    apply pc_block_multi with (rest := fr); [reflexivity | exact Hfetch1]. }
  assert (Hframes1 : s1.(rt_frames) = f1 :: fr).
  { subst s1 s0 f1. simpl. reflexivity. }
  assert (Hvalues1 : s1.(rt_values) = input).
  { subst s1 s0 f1. simpl. reflexivity. }
  assert (Hmem1 : s1.(rt_memory) = mem).
  { subst s1 s0 f1. simpl. reflexivity. }
  set (prefix2 := prefix ++ [BLOCK outer_len]).
  set (next2 := instrs_total_size prefix2 + instr_size (BLOCK inner_len)).
  set (inner_target := f1.(frame_pc) + instr_size (BLOCK inner_len) + inner_len).
  set (f2 := frame_push_block (set_frame_pc f1 next2) inner_target).
  set (s2 := set_top_values_cycle s1 f2 input).
  assert (Hpc1 : f1.(frame_pc) = instrs_total_size prefix2).
  { subst f1 next1 prefix2. simpl.
    rewrite instrs_total_size_app.
    simpl.
    lia. }
  assert (Hfetch2 : fetch_frame_instr m f1 = Some (BLOCK inner_len, next2)).
  { subst next2.
    apply fetch_frame_instr_app_exact with
      (fn := fn) (prefix := prefix2) (i := BLOCK inner_len)
      (rest := rest ++ suffix);
      [exact Hlook | | exact Hpc1].
    subst prefix2.
    rewrite Hbody.
    repeat rewrite app_assoc.
    rewrite app_singleton_cons.
    reflexivity. }
  assert (Hstep2 : multi_pc_step m s1 s2).
  { subst s2 f2 inner_target.
    eapply pc_block_multi with (rest := fr);
      [exact Hframes1 | exact Hfetch2]. }
  assert (Hframes2 : s2.(rt_frames) = f2 :: fr).
  { subst s2. simpl. reflexivity. }
  assert (Hvalues2 : s2.(rt_values) = input).
  { subst s2. simpl. exact Hvalues1. }
  assert (Hmem2 : s2.(rt_memory) = mem).
  { subst s2. simpl. exact Hmem1. }
  exists s2, f2.
  split.
  - eapply multi_pc_step_trans; [exact Hstep1 | exact Hstep2].
  - split; [exact Hframes2 |].
    split; [exact Hvalues2 |].
    split; [exact Hmem2 |].
    split.
    + subst f2 f1. simpl. reflexivity.
    + split.
      * subst f2 f1. simpl. reflexivity.
      * split.
        -- subst f2 f1 next2 next1 prefix2 outer_target inner_target.
           simpl.
           rewrite instrs_total_size_app.
           simpl.
           rewrite Hpc.
           ring.
        -- subst f2 f1 next2 next1 prefix2 outer_target inner_target.
           simpl.
           replace (frame_pc f + 10 + inner_len)
             with (instrs_total_size prefix + 5 + 5 + inner_len)
             by (rewrite Hpc; ring).
           replace (frame_pc f + 5 + outer_len)
             with (instrs_total_size prefix + 5 + outer_len)
             by (rewrite Hpc; ring).
           reflexivity.
Qed.

Lemma compile_stmts_cons :
  forall (env : compile_env) (env_ty : compile_type_env)
         (s : corest_stmt) (rest : list corest_stmt),
    compile_stmts env env_ty (s :: rest) =
    compile_stmt env env_ty s ++ compile_stmts env env_ty rest.
Proof.
  reflexivity.
Qed.

Lemma compile_stmts_singleton :
  forall (env : compile_env) (env_ty : compile_type_env)
         (stmt : corest_stmt),
    compile_stmts env env_ty [stmt] = compile_stmt env env_ty stmt.
Proof.
  intros env env_ty stmt.
  unfold compile_stmts.
  simpl.
  rewrite app_nil_r.
  reflexivity.
Qed.

(* ================================================================
   第 5 部分：函数编译 (Function Compilation)
   ================================================================ *)

Definition compile_function (env : compile_env) (env_ty : compile_type_env) (f : corest_function) : sasm_function :=
  let core_body := List.concat (List.map (compile_stmt env env_ty) f.(cfunc_body)) in
  let body :=
    match f.(cfunc_return_type) with
    | Some _ => core_body ++ [RETURN]
    | None => core_body
    end in
  let local_types := List.map (fun p => snd p) env_ty in
  let safeasm_types := List.map (fun ty => st_type_to_sasm ty) local_types in
  {| sasm_func_type_idx := 0;
     sasm_locals := safeasm_types;
     sasm_body := body;
     sasm_stack_depth := instr_seq_size body;
     sasm_cycle_budget := 1000000;
  |}.

Lemma compile_function_locals_length :
  forall (env : compile_env) (env_ty : compile_type_env)
         (f : corest_function),
    List.length (compile_function env env_ty f).(sasm_locals) =
    List.length env_ty.
Proof.
  intros env env_ty f.
  unfold compile_function.
  simpl.
  repeat rewrite List.length_map.
  reflexivity.
Qed.

(* ================================================================
   第 6 部分：程序编译 (Program Compilation)
   ================================================================ *)

Definition build_sasm_func_type (f : corest_function) : sasm_func_type :=
  let param_sasm := List.map (fun p => st_type_to_sasm (snd p)) f.(cfunc_params) in
  let ret_sasm := match f.(cfunc_return_type) with
                  | Some t => [st_type_to_sasm t]
                  | None => []
                  end in
  {| sasm_param_types := param_sasm; sasm_return_types := ret_sasm |}.

Fixpoint all_params_types (funcs : list corest_function) : list sasm_value_type :=
  match funcs with
  | nil => []
  | f :: rest => List.map (fun p => st_type_to_sasm (snd p)) f.(cfunc_params) ++ all_params_types rest
  end.

(* 估算总内存: 每个 local 4 字节 + I/O 预留 1KB + 质量影子区 256 字节 *)
Definition estimate_total_memory (funcs : list corest_function) : Z :=
  let local_count := List.fold_right (fun f acc =>
    acc + Z.of_nat (List.length f.(cfunc_params) + List.length f.(cfunc_locals))
  ) 0 funcs in
  Z.max (local_count * 4 + 1024 + 256) 256.

(* 构建全局变量区段 *)
(* ST IO 方向 → SafeASM IO 方向 *)
Definition st_dir_to_sasm_dir (d : var_direction) : io_direction :=
  match d with D_INPUT => IO_INPUT | D_OUTPUT => IO_OUTPUT | _ => IO_INPUT end.

(* ST 类型 → SafeASM IO 类型 (AI/AO/DI/DO) *)
Definition st_type_to_io_type (dir : var_direction) (t : st_type) : io_type :=
  match dir, t with
  | D_INPUT, T_INT | D_INPUT, T_DINT | D_INPUT, T_REAL => IO_AI
  | D_OUTPUT, T_INT | D_OUTPUT, T_DINT | D_OUTPUT, T_REAL => IO_AO
  | D_INPUT, _ => IO_DI
  | D_OUTPUT, _ => IO_DO
  | _, _ => IO_DI
  end.

(* ST 类型 → 单个 IOMAP 偏移（简化：从 1024 开始递增）*)
Fixpoint assign_io_offsets (entries : list io_entry) (base : Z) : list (Z * io_entry) :=
  match entries with
  | nil => nil
  | e :: rest => (base, e) :: assign_io_offsets rest (base + 4)
  end.

(* ST io_entry → SafeASM io_entry_sasm *)
Definition io_entry_to_sasm (offset : Z) (e : io_entry) : io_entry_sasm :=
  let 'Build_io_entry name_ ch_ dir_ ty_ := e in
  let s : string := match name_ with ID s => s end in
  Build_io_entry_sasm s offset ch_
    (st_dir_to_sasm_dir dir_)
    (st_type_to_io_type dir_ ty_)
    (type_width ty_)
    PrimFloat.one PrimFloat.zero
    (-2147483648) 2147483647.

Definition build_global_mem_segment (funcs : list corest_function) : memory_segment :=
  let total := estimate_total_memory funcs in
  {| seg_type := SEG_GLOBAL; seg_start := 0; seg_size := total |}.

Definition compile_program (p : corest_program) : sasm_module :=
  let funcs := List.map (fun f =>
    let env := build_compile_env f in
    let ty := build_compile_type_env f in
    compile_function env ty f) p.(cprog_functions) in
  let types := List.map build_sasm_func_type p.(cprog_functions) in
  let total_mem := estimate_total_memory p.(cprog_functions) in
  let global_seg := build_global_mem_segment p.(cprog_functions) in
  let io_offsets := assign_io_offsets p.(cprog_io_mapping) 1024 in
  let io_map := List.map (fun p' => io_entry_to_sasm (fst p') (snd p')) io_offsets in
  {| sasm_magic := "SASM";
     sasm_version := 1;
     sasm_flags := 0;
     sasm_types := types;
     sasm_functions := funcs;
     sasm_memory_segments := [global_seg];
     sasm_total_memory_size := total_mem;
     sasm_io_map := io_map;
     sasm_safety := {| safe_level := 0;
                       safe_cycle_limit := 1000000;
                       safe_stack_depth := analyze_stack_depth p;
                       safe_loop_bounds := [];
                       safe_mem_access_map := [{| mar_low := 0; mar_high := total_mem |}];
                    |};
     sasm_wcet := None;
     sasm_entry_function := 0;
  |}.

(* ================================================================
   第 7 部分：SafeASM 指令执行语义 (Instruction Execution Semantics)

   定义 compile_expr 生成的指令序列对 SafeASM 运行时状态的影响。
   ================================================================ *)

(* ST 值到 SafeASM 值的映射（与 compiler_correctness.v 一致） *)
Definition st_val_to_sasm_val (v : st_value) : sasm_value :=
  match v with
  | ST_V_BOOL b => V_I32 (if b then 1 else 0)
  | ST_V_BYTE z => V_I32 z | ST_V_WORD z => V_I32 z | ST_V_DWORD z => V_I32 z
  | ST_V_SINT z => V_I32 z | ST_V_INT z => V_I32 z | ST_V_DINT z => V_I32 z
  | ST_V_REAL f => V_F32 f | ST_V_TIME z => V_I64 z
  | ST_V_LINT z => V_I64 z
  | ST_V_LREAL f => V_F64 f
  end.

Definition compile_state_env_matches (decls : compile_type_env)
           (env_s : corest_eval_env) : Prop :=
  forall (x : ident) (v : st_value),
    lookup_var env_s x = Some v ->
    exists ty : st_type, lookup_var_type decls x = Some ty.

Fixpoint sasm_locals_of_decls (decls : compile_type_env)
         (env_s : corest_eval_env) : list sasm_value :=
  match decls with
  | nil => nil
  | (x, _) :: rest =>
      match lookup_var env_s x with
      | Some v => st_val_to_sasm_val v
      | None => V_I32 0
      end :: sasm_locals_of_decls rest env_s
  end.

Lemma sasm_locals_of_decls_lookup :
  forall (decls : compile_type_env) (env_s : corest_eval_env)
         (base : Z) (x : ident) (ty : st_type) (v : st_value),
    lookup_var_type decls x = Some ty ->
    lookup_var env_s x = Some v ->
    exists idx : Z,
      lookup_var_idx (assign_env_indices decls base) x = Some idx /\
      List.nth_error (sasm_locals_of_decls decls env_s)
        (Z.to_nat (idx - base)) = Some (st_val_to_sasm_val v).
Proof.
  induction decls as [|[y y_ty] rest IH]; intros env_s base x ty v Htype Hlook.
  - simpl in Htype. discriminate.
  - simpl in Htype.
    destruct x as [sx], y as [sy].
    destruct (String.eqb sx sy) eqn:Heq.
    + apply String.eqb_eq in Heq. subst sy.
      inversion Htype; subst ty.
      exists base.
      simpl.
      rewrite String.eqb_refl.
      split; [reflexivity |].
      replace (base - base) with 0 by ring.
      simpl.
      rewrite Hlook.
      reflexivity.
    + destruct (IH env_s (base + 1) (ID sx) ty v Htype Hlook)
        as [idx [Hidx Hnth]].
      exists idx.
      simpl.
      rewrite Heq.
      split; [exact Hidx |].
      replace (idx - base) with ((idx - (base + 1)) + 1) by ring.
      destruct (lookup_var_idx_assign_env_indices rest (base + 1)
                  (ID sx) idx Hidx) as [n [_ Hidx_eq]].
      rewrite Z2Nat.inj_add by lia.
      replace (Nat.add (Z.to_nat (idx - (base + 1)))
                       (Z.to_nat 1))
        with (S (Z.to_nat (idx - (base + 1)))) by (simpl; lia).
      simpl.
      exact Hnth.
Qed.

(* 构建与 CoreST 求值环境匹配的初始 SafeASM 状态 *)
Definition build_sasm_state (env_s : corest_eval_env) : runtime_state :=
  let locals : list sasm_value := List.map (fun (p : ident * st_value) => let (_, v) := p in st_val_to_sasm_val v) env_s in
  let main_frame := {| frame_locals := locals;
                       frame_func_idx := 0;
                       frame_pc := 0;
                       frame_block_stack := []; |} in
  {| rt_values := nil;
     rt_frames := main_frame :: nil;
     rt_memory := nil;
     rt_cycle_cnt := 0;
  |}.

(* 单条 SafeASM 指令的大步执行语义 *)
Definition exec_instr (st : runtime_state) (i : sasm_instr) : option runtime_state :=
  match i with
  | NOP => Some st
  | DROP =>
      match st.(rt_values) with
      | _ :: vs => Some {| rt_values := vs; rt_frames := st.(rt_frames);
                          rt_memory := st.(rt_memory); rt_cycle_cnt := st.(rt_cycle_cnt) + 1; |}
      | nil => None
      end
  | I32_CONST n => Some (push_value (V_I32 n) st)
  | LOCAL_GET idx =>
      (* 简化：从帧的局部变量中读取 *)
      match st.(rt_frames) with
      | f :: _ =>
          match List.nth_error f.(frame_locals) (Z.to_nat idx) with
          | Some v => Some (push_value v st)
          | None => Some (push_value (V_I32 0) st)
          end
      | nil => Some (push_value (V_I32 0) st)
      end
  | LOCAL_SET idx =>
      match st.(rt_values) with
      | v :: vs =>
          match st.(rt_frames) with
          | f :: fs =>
              let f' := set_local f idx v in
              Some {| rt_values := vs; rt_frames := f' :: fs;
                      rt_memory := st.(rt_memory); rt_cycle_cnt := st.(rt_cycle_cnt) + 1; |}
          | nil => Some {| rt_values := vs; rt_frames := [];
                          rt_memory := st.(rt_memory); rt_cycle_cnt := st.(rt_cycle_cnt) + 1; |}
          end
      | nil => None
      end
  | LOCAL_TEE idx =>
      match st.(rt_values) with
      | v :: _ =>
          match st.(rt_frames) with
          | f :: fs =>
              let f' := set_local f idx v in
              Some {| rt_values := st.(rt_values); rt_frames := f' :: fs;
                      rt_memory := st.(rt_memory); rt_cycle_cnt := st.(rt_cycle_cnt) + 1; |}
          | nil => Some (push_value v st)
          end
      | nil => None
      end
  | I32_ADD =>
      match st.(rt_values) with
      | V_I32 n2 :: V_I32 n1 :: vs =>
          Some {| rt_values := V_I32 (n1 + n2) :: vs; rt_frames := st.(rt_frames);
                  rt_memory := st.(rt_memory); rt_cycle_cnt := st.(rt_cycle_cnt) + 1; |}
      | _ => None
      end
  | I32_SUB =>
      match st.(rt_values) with
      | V_I32 n2 :: V_I32 n1 :: vs =>
          Some {| rt_values := V_I32 (n1 - n2) :: vs; rt_frames := st.(rt_frames);
                  rt_memory := st.(rt_memory); rt_cycle_cnt := st.(rt_cycle_cnt) + 1; |}
      | _ => None
      end
  | I32_MUL =>
      match st.(rt_values) with
      | V_I32 n2 :: V_I32 n1 :: vs =>
          Some {| rt_values := V_I32 (n1 * n2) :: vs; rt_frames := st.(rt_frames);
                  rt_memory := st.(rt_memory); rt_cycle_cnt := st.(rt_cycle_cnt) + 1; |}
      | _ => None
      end
  | I32_DIV_S =>
      match st.(rt_values) with
      | V_I32 n2 :: V_I32 n1 :: vs =>
          Some {| rt_values := V_I32 (if Z.eqb n2 0 then 0 else n1 / n2) :: vs; rt_frames := st.(rt_frames);
                       rt_memory := st.(rt_memory); rt_cycle_cnt := st.(rt_cycle_cnt) + 1; |}
      | _ => None
      end
  | I32_REM_S =>
      match st.(rt_values) with
      | V_I32 n2 :: V_I32 n1 :: vs =>
          Some {| rt_values := V_I32 (if Z.eqb n2 0 then 0 else Z.rem n1 n2) :: vs; rt_frames := st.(rt_frames);
                       rt_memory := st.(rt_memory); rt_cycle_cnt := st.(rt_cycle_cnt) + 1; |}
      | _ => None
      end
  | I32_EQZ =>
      match st.(rt_values) with
      | V_I32 n :: vs =>
          Some {| rt_values := V_I32 (if Z.eqb n 0 then 1 else 0) :: vs;
                  rt_frames := st.(rt_frames); rt_memory := st.(rt_memory);
                  rt_cycle_cnt := st.(rt_cycle_cnt) + 1; |}
      | _ => None
      end
  | I32_EQ =>
      match st.(rt_values) with
      | V_I32 n2 :: V_I32 n1 :: vs =>
          Some {| rt_values := V_I32 (if Z.eqb n1 n2 then 1 else 0) :: vs;
                  rt_frames := st.(rt_frames); rt_memory := st.(rt_memory);
                  rt_cycle_cnt := st.(rt_cycle_cnt) + 1; |}
      | _ => None
      end
  | I32_NE =>
      match st.(rt_values) with
      | V_I32 n2 :: V_I32 n1 :: vs =>
          Some {| rt_values := V_I32 (if Z.eqb n1 n2 then 0 else 1) :: vs;
                  rt_frames := st.(rt_frames); rt_memory := st.(rt_memory);
                  rt_cycle_cnt := st.(rt_cycle_cnt) + 1; |}
      | _ => None
      end
  | I32_LT_S =>
      match st.(rt_values) with
      | V_I32 n2 :: V_I32 n1 :: vs =>
          Some {| rt_values := V_I32 (if n1 <? n2 then 1 else 0) :: vs;
                  rt_frames := st.(rt_frames); rt_memory := st.(rt_memory);
                  rt_cycle_cnt := st.(rt_cycle_cnt) + 1; |}
      | _ => None
      end
  | I32_LE_S =>
      match st.(rt_values) with
      | V_I32 n2 :: V_I32 n1 :: vs =>
          Some {| rt_values := V_I32 (if n1 <=? n2 then 1 else 0) :: vs;
                  rt_frames := st.(rt_frames); rt_memory := st.(rt_memory);
                  rt_cycle_cnt := st.(rt_cycle_cnt) + 1; |}
      | _ => None
      end
  | I32_GT_S =>
      match st.(rt_values) with
      | V_I32 n2 :: V_I32 n1 :: vs =>
          Some {| rt_values := V_I32 (if n1 >? n2 then 1 else 0) :: vs;
                  rt_frames := st.(rt_frames); rt_memory := st.(rt_memory);
                  rt_cycle_cnt := st.(rt_cycle_cnt) + 1; |}
      | _ => None
      end
  | I32_GE_S =>
      match st.(rt_values) with
      | V_I32 n2 :: V_I32 n1 :: vs =>
          Some {| rt_values := V_I32 (if n1 >=? n2 then 1 else 0) :: vs;
                  rt_frames := st.(rt_frames); rt_memory := st.(rt_memory);
                  rt_cycle_cnt := st.(rt_cycle_cnt) + 1; |}
      | _ => None
      end
  | I32_AND =>
      match st.(rt_values) with
      | V_I32 n2 :: V_I32 n1 :: vs =>
          Some {| rt_values := V_I32 (Z.land n1 n2) :: vs; rt_frames := st.(rt_frames);
                  rt_memory := st.(rt_memory); rt_cycle_cnt := st.(rt_cycle_cnt) + 1; |}
      | _ => None
      end
  | I32_OR =>
      match st.(rt_values) with
      | V_I32 n2 :: V_I32 n1 :: vs =>
          Some {| rt_values := V_I32 (Z.lor n1 n2) :: vs; rt_frames := st.(rt_frames);
                  rt_memory := st.(rt_memory); rt_cycle_cnt := st.(rt_cycle_cnt) + 1; |}
      | _ => None
      end
  | I32_XOR =>
      match st.(rt_values) with
      | V_I32 n2 :: V_I32 n1 :: vs =>
          Some {| rt_values := V_I32 (Z.lxor n1 n2) :: vs; rt_frames := st.(rt_frames);
                  rt_memory := st.(rt_memory); rt_cycle_cnt := st.(rt_cycle_cnt) + 1; |}
      | _ => None
      end
  | SELECT =>
      match st.(rt_values) with
      | V_I32 c :: V_I32 v1 :: V_I32 v0 :: vs =>
          Some {| rt_values := (if Z.eqb c 0 then V_I32 v0 else V_I32 v1) :: vs;
                  rt_frames := st.(rt_frames); rt_memory := st.(rt_memory);
                  rt_cycle_cnt := st.(rt_cycle_cnt) + 1; |}
      | _ => None
      end

  (* ── i32 位运算 (0x71-0x77) ── *)
  | I32_SHL =>
      match st.(rt_values) with
      | V_I32 n2 :: V_I32 n1 :: vs =>
          Some {| rt_values := V_I32 (Z.shiftl n1 n2) :: vs; rt_frames := st.(rt_frames);
                  rt_memory := st.(rt_memory); rt_cycle_cnt := st.(rt_cycle_cnt) + 1; |}
      | _ => None
      end
  | I32_SHR_S =>
      match st.(rt_values) with
      | V_I32 n2 :: V_I32 n1 :: vs =>
          Some {| rt_values := V_I32 (Z.shiftr n1 n2) :: vs; rt_frames := st.(rt_frames);
                  rt_memory := st.(rt_memory); rt_cycle_cnt := st.(rt_cycle_cnt) + 1; |}
      | _ => None
      end
  | I32_ROTL =>
      match st.(rt_values) with
      | V_I32 n2 :: V_I32 n1 :: vs =>
          Some {| rt_values := V_I32 (Z.lor (Z.shiftl n1 n2) (Z.shiftr n1 (32 - n2))) :: vs;
                  rt_frames := st.(rt_frames); rt_memory := st.(rt_memory);
                  rt_cycle_cnt := st.(rt_cycle_cnt) + 1; |}
      | _ => None
      end
  | I32_ROTR =>
      match st.(rt_values) with
      | V_I32 n2 :: V_I32 n1 :: vs =>
          Some {| rt_values := V_I32 (Z.lor (Z.shiftr n1 n2) (Z.shiftl n1 (32 - n2))) :: vs;
                  rt_frames := st.(rt_frames); rt_memory := st.(rt_memory);
                  rt_cycle_cnt := st.(rt_cycle_cnt) + 1; |}
      | _ => None
      end

  (* ── i64 常量 ── *)
  | I64_CONST n => Some (push_value (V_I64 n) st)

  (* ── i64 比较 ── *)
  | I64_EQZ =>
      match st.(rt_values) with
      | V_I64 n :: vs =>
          Some {| rt_values := V_I64 (if Z.eqb n 0 then 1 else 0) :: vs;
                  rt_frames := st.(rt_frames); rt_memory := st.(rt_memory);
                  rt_cycle_cnt := st.(rt_cycle_cnt) + 1; |}
      | _ => None
      end
  | I64_EQ =>
      match st.(rt_values) with
      | V_I64 n2 :: V_I64 n1 :: vs =>
          Some {| rt_values := V_I64 (if Z.eqb n1 n2 then 1 else 0) :: vs;
                  rt_frames := st.(rt_frames); rt_memory := st.(rt_memory);
                  rt_cycle_cnt := st.(rt_cycle_cnt) + 1; |}
      | _ => None
      end
  | I64_NE =>
      match st.(rt_values) with
      | V_I64 n2 :: V_I64 n1 :: vs =>
          Some {| rt_values := V_I64 (if Z.eqb n1 n2 then 0 else 1) :: vs;
                  rt_frames := st.(rt_frames); rt_memory := st.(rt_memory);
                  rt_cycle_cnt := st.(rt_cycle_cnt) + 1; |}
      | _ => None
      end
  | I64_LT_S =>
      match st.(rt_values) with
      | V_I64 n2 :: V_I64 n1 :: vs =>
          Some {| rt_values := V_I64 (if n1 <? n2 then 1 else 0) :: vs;
                  rt_frames := st.(rt_frames); rt_memory := st.(rt_memory);
                  rt_cycle_cnt := st.(rt_cycle_cnt) + 1; |}
      | _ => None
      end
  | I64_LE_S =>
      match st.(rt_values) with
      | V_I64 n2 :: V_I64 n1 :: vs =>
          Some {| rt_values := V_I64 (if n1 <=? n2 then 1 else 0) :: vs;
                  rt_frames := st.(rt_frames); rt_memory := st.(rt_memory);
                  rt_cycle_cnt := st.(rt_cycle_cnt) + 1; |}
      | _ => None
      end
  | I64_GT_S =>
      match st.(rt_values) with
      | V_I64 n2 :: V_I64 n1 :: vs =>
          Some {| rt_values := V_I64 (if n1 >? n2 then 1 else 0) :: vs;
                  rt_frames := st.(rt_frames); rt_memory := st.(rt_memory);
                  rt_cycle_cnt := st.(rt_cycle_cnt) + 1; |}
      | _ => None
      end
  | I64_GE_S =>
      match st.(rt_values) with
      | V_I64 n2 :: V_I64 n1 :: vs =>
          Some {| rt_values := V_I64 (if n1 >=? n2 then 1 else 0) :: vs;
                  rt_frames := st.(rt_frames); rt_memory := st.(rt_memory);
                  rt_cycle_cnt := st.(rt_cycle_cnt) + 1; |}
      | _ => None
      end

  (* ── i64 算术 ── *)
  | I64_ADD =>
      match st.(rt_values) with
      | V_I64 n2 :: V_I64 n1 :: vs =>
          Some {| rt_values := V_I64 (n1 + n2) :: vs; rt_frames := st.(rt_frames);
                  rt_memory := st.(rt_memory); rt_cycle_cnt := st.(rt_cycle_cnt) + 1; |}
      | _ => None
      end
  | I64_SUB =>
      match st.(rt_values) with
      | V_I64 n2 :: V_I64 n1 :: vs =>
          Some {| rt_values := V_I64 (n1 - n2) :: vs; rt_frames := st.(rt_frames);
                  rt_memory := st.(rt_memory); rt_cycle_cnt := st.(rt_cycle_cnt) + 1; |}
      | _ => None
      end
  | I64_MUL =>
      match st.(rt_values) with
      | V_I64 n2 :: V_I64 n1 :: vs =>
          Some {| rt_values := V_I64 (n1 * n2) :: vs; rt_frames := st.(rt_frames);
                  rt_memory := st.(rt_memory); rt_cycle_cnt := st.(rt_cycle_cnt) + 1; |}
      | _ => None
      end
  | I64_DIV_S =>
      match st.(rt_values) with
      | V_I64 n2 :: V_I64 n1 :: vs =>
          Some {| rt_values := V_I64 (if Z.eqb n2 0 then 0 else n1 / n2) :: vs;
                  rt_frames := st.(rt_frames); rt_memory := st.(rt_memory);
                  rt_cycle_cnt := st.(rt_cycle_cnt) + 1; |}
      | _ => None
      end
  | I64_REM_S =>
      match st.(rt_values) with
      | V_I64 n2 :: V_I64 n1 :: vs =>
          Some {| rt_values := V_I64 (if Z.eqb n2 0 then 0 else Z.rem n1 n2) :: vs;
                  rt_frames := st.(rt_frames); rt_memory := st.(rt_memory);
                  rt_cycle_cnt := st.(rt_cycle_cnt) + 1; |}
      | _ => None
      end

  (* ── i64 位运算 ── *)
  | I64_AND =>
      match st.(rt_values) with
      | V_I64 n2 :: V_I64 n1 :: vs =>
          Some {| rt_values := V_I64 (Z.land n1 n2) :: vs; rt_frames := st.(rt_frames);
                  rt_memory := st.(rt_memory); rt_cycle_cnt := st.(rt_cycle_cnt) + 1; |}
      | _ => None
      end
  | I64_OR =>
      match st.(rt_values) with
      | V_I64 n2 :: V_I64 n1 :: vs =>
          Some {| rt_values := V_I64 (Z.lor n1 n2) :: vs; rt_frames := st.(rt_frames);
                  rt_memory := st.(rt_memory); rt_cycle_cnt := st.(rt_cycle_cnt) + 1; |}
      | _ => None
      end
  | I64_XOR =>
      match st.(rt_values) with
      | V_I64 n2 :: V_I64 n1 :: vs =>
          Some {| rt_values := V_I64 (Z.lxor n1 n2) :: vs; rt_frames := st.(rt_frames);
                  rt_memory := st.(rt_memory); rt_cycle_cnt := st.(rt_cycle_cnt) + 1; |}
      | _ => None
      end
  | I64_SHL =>
      match st.(rt_values) with
      | V_I64 n2 :: V_I64 n1 :: vs =>
          Some {| rt_values := V_I64 (Z.shiftl n1 n2) :: vs; rt_frames := st.(rt_frames);
                  rt_memory := st.(rt_memory); rt_cycle_cnt := st.(rt_cycle_cnt) + 1; |}
      | _ => None
      end
  | I64_SHR_S =>
      match st.(rt_values) with
      | V_I64 n2 :: V_I64 n1 :: vs =>
          Some {| rt_values := V_I64 (Z.shiftr n1 n2) :: vs; rt_frames := st.(rt_frames);
                  rt_memory := st.(rt_memory); rt_cycle_cnt := st.(rt_cycle_cnt) + 1; |}
      | _ => None
      end

  (* ── 浮点常量 ── *)
  | F32_CONST f => Some (push_value (V_F32 f) st)
  | F64_CONST f => Some (push_value (V_F64 f) st)

  (* ── f32 算术 ── *)
  | F32_ADD =>
      match st.(rt_values) with
      | V_F32 f2 :: V_F32 f1 :: vs =>
          Some {| rt_values := V_F32 (PrimFloat.add f1 f2) :: vs; rt_frames := st.(rt_frames);
                  rt_memory := st.(rt_memory); rt_cycle_cnt := st.(rt_cycle_cnt) + 1; |}
      | _ => None
      end
  | F32_SUB =>
      match st.(rt_values) with
      | V_F32 f2 :: V_F32 f1 :: vs =>
          Some {| rt_values := V_F32 (PrimFloat.sub f1 f2) :: vs; rt_frames := st.(rt_frames);
                  rt_memory := st.(rt_memory); rt_cycle_cnt := st.(rt_cycle_cnt) + 1; |}
      | _ => None
      end
  | F32_MUL =>
      match st.(rt_values) with
      | V_F32 f2 :: V_F32 f1 :: vs =>
          Some {| rt_values := V_F32 (PrimFloat.mul f1 f2) :: vs; rt_frames := st.(rt_frames);
                  rt_memory := st.(rt_memory); rt_cycle_cnt := st.(rt_cycle_cnt) + 1; |}
      | _ => None
      end
  | F32_DIV =>
      match st.(rt_values) with
      | V_F32 f2 :: V_F32 f1 :: vs =>
          Some {| rt_values := V_F32 (PrimFloat.div f1 f2) :: vs; rt_frames := st.(rt_frames);
                  rt_memory := st.(rt_memory); rt_cycle_cnt := st.(rt_cycle_cnt) + 1; |}
      | _ => None
      end
  | F32_EQ =>
      match st.(rt_values) with
      | V_F32 f2 :: V_F32 f1 :: vs =>
          Some {| rt_values := V_I32 (if PrimFloat.eqb f1 f2 then 1 else 0) :: vs;
                  rt_frames := st.(rt_frames); rt_memory := st.(rt_memory);
                  rt_cycle_cnt := st.(rt_cycle_cnt) + 1; |}
      | _ => None
      end
  | F32_NE =>
      match st.(rt_values) with
      | V_F32 f2 :: V_F32 f1 :: vs =>
          Some {| rt_values := V_I32 (if PrimFloat.eqb f1 f2 then 0 else 1) :: vs;
                  rt_frames := st.(rt_frames); rt_memory := st.(rt_memory);
                  rt_cycle_cnt := st.(rt_cycle_cnt) + 1; |}
      | _ => None
      end
  | F32_LT =>
      match st.(rt_values) with
      | V_F32 f2 :: V_F32 f1 :: vs =>
          Some {| rt_values := V_I32 (if PrimFloat.ltb f1 f2 then 1 else 0) :: vs;
                  rt_frames := st.(rt_frames); rt_memory := st.(rt_memory);
                  rt_cycle_cnt := st.(rt_cycle_cnt) + 1; |}
      | _ => None
      end
  | F32_LE =>
      match st.(rt_values) with
      | V_F32 f2 :: V_F32 f1 :: vs =>
          Some {| rt_values := V_I32 (if PrimFloat.leb f1 f2 then 1 else 0) :: vs;
                  rt_frames := st.(rt_frames); rt_memory := st.(rt_memory);
                  rt_cycle_cnt := st.(rt_cycle_cnt) + 1; |}
      | _ => None
      end
  | F32_GT =>
      match st.(rt_values) with
      | V_F32 f2 :: V_F32 f1 :: vs =>
          Some {| rt_values := V_I32 (if PrimFloat.ltb f2 f1 then 1 else 0) :: vs;
                  rt_frames := st.(rt_frames); rt_memory := st.(rt_memory);
                  rt_cycle_cnt := st.(rt_cycle_cnt) + 1; |}
      | _ => None
      end
  | F32_GE =>
      match st.(rt_values) with
      | V_F32 f2 :: V_F32 f1 :: vs =>
          Some {| rt_values := V_I32 (if PrimFloat.leb f2 f1 then 1 else 0) :: vs;
                  rt_frames := st.(rt_frames); rt_memory := st.(rt_memory);
                  rt_cycle_cnt := st.(rt_cycle_cnt) + 1; |}
      | _ => None
      end
  | F32_ABS =>
      match st.(rt_values) with
      | V_F32 f :: vs =>
          Some {| rt_values := V_F32 (PrimFloat.abs f) :: vs; rt_frames := st.(rt_frames);
                  rt_memory := st.(rt_memory); rt_cycle_cnt := st.(rt_cycle_cnt) + 1; |}
      | _ => None
      end
  | F32_NEG =>
      match st.(rt_values) with
      | V_F32 f :: vs =>
          Some {| rt_values := V_F32 (PrimFloat.opp f) :: vs; rt_frames := st.(rt_frames);
                  rt_memory := st.(rt_memory); rt_cycle_cnt := st.(rt_cycle_cnt) + 1; |}
      | _ => None
      end
  | F32_SQRT =>
      match st.(rt_values) with
      | V_F32 f :: vs =>
          Some {| rt_values := V_F32 (PrimFloat.sqrt f) :: vs; rt_frames := st.(rt_frames);
                  rt_memory := st.(rt_memory); rt_cycle_cnt := st.(rt_cycle_cnt) + 1; |}
      | _ => None
      end

  (* ── f64 算术 ── *)
  | F64_ADD =>
      match st.(rt_values) with
      | V_F64 f2 :: V_F64 f1 :: vs =>
          Some {| rt_values := V_F64 (PrimFloat.add f1 f2) :: vs; rt_frames := st.(rt_frames);
                  rt_memory := st.(rt_memory); rt_cycle_cnt := st.(rt_cycle_cnt) + 1; |}
      | _ => None
      end
  | F64_SUB =>
      match st.(rt_values) with
      | V_F64 f2 :: V_F64 f1 :: vs =>
          Some {| rt_values := V_F64 (PrimFloat.sub f1 f2) :: vs; rt_frames := st.(rt_frames);
                  rt_memory := st.(rt_memory); rt_cycle_cnt := st.(rt_cycle_cnt) + 1; |}
      | _ => None
      end
  | F64_MUL =>
      match st.(rt_values) with
      | V_F64 f2 :: V_F64 f1 :: vs =>
          Some {| rt_values := V_F64 (PrimFloat.mul f1 f2) :: vs; rt_frames := st.(rt_frames);
                  rt_memory := st.(rt_memory); rt_cycle_cnt := st.(rt_cycle_cnt) + 1; |}
      | _ => None
      end
  | F64_DIV =>
      match st.(rt_values) with
      | V_F64 f2 :: V_F64 f1 :: vs =>
          Some {| rt_values := V_F64 (PrimFloat.div f1 f2) :: vs; rt_frames := st.(rt_frames);
                  rt_memory := st.(rt_memory); rt_cycle_cnt := st.(rt_cycle_cnt) + 1; |}
      | _ => None
      end
  | F64_EQ =>
      match st.(rt_values) with
      | V_F64 f2 :: V_F64 f1 :: vs =>
          Some {| rt_values := V_I32 (if PrimFloat.eqb f1 f2 then 1 else 0) :: vs;
                  rt_frames := st.(rt_frames); rt_memory := st.(rt_memory);
                  rt_cycle_cnt := st.(rt_cycle_cnt) + 1; |}
      | _ => None
      end
  | F64_NE =>
      match st.(rt_values) with
      | V_F64 f2 :: V_F64 f1 :: vs =>
          Some {| rt_values := V_I32 (if PrimFloat.eqb f1 f2 then 0 else 1) :: vs;
                  rt_frames := st.(rt_frames); rt_memory := st.(rt_memory);
                  rt_cycle_cnt := st.(rt_cycle_cnt) + 1; |}
      | _ => None
      end
  | F64_LT =>
      match st.(rt_values) with
      | V_F64 f2 :: V_F64 f1 :: vs =>
          Some {| rt_values := V_I32 (if PrimFloat.ltb f1 f2 then 1 else 0) :: vs;
                  rt_frames := st.(rt_frames); rt_memory := st.(rt_memory);
                  rt_cycle_cnt := st.(rt_cycle_cnt) + 1; |}
      | _ => None
      end
  | F64_LE =>
      match st.(rt_values) with
      | V_F64 f2 :: V_F64 f1 :: vs =>
          Some {| rt_values := V_I32 (if PrimFloat.leb f1 f2 then 1 else 0) :: vs;
                  rt_frames := st.(rt_frames); rt_memory := st.(rt_memory);
                  rt_cycle_cnt := st.(rt_cycle_cnt) + 1; |}
      | _ => None
      end
  | F64_GT =>
      match st.(rt_values) with
      | V_F64 f2 :: V_F64 f1 :: vs =>
          Some {| rt_values := V_I32 (if PrimFloat.ltb f2 f1 then 1 else 0) :: vs;
                  rt_frames := st.(rt_frames); rt_memory := st.(rt_memory);
                  rt_cycle_cnt := st.(rt_cycle_cnt) + 1; |}
      | _ => None
      end
  | F64_GE =>
      match st.(rt_values) with
      | V_F64 f2 :: V_F64 f1 :: vs =>
          Some {| rt_values := V_I32 (if PrimFloat.leb f2 f1 then 1 else 0) :: vs;
                  rt_frames := st.(rt_frames); rt_memory := st.(rt_memory);
                  rt_cycle_cnt := st.(rt_cycle_cnt) + 1; |}
      | _ => None
      end
  | F64_ABS =>
      match st.(rt_values) with
      | V_F64 f :: vs =>
          Some {| rt_values := V_F64 (PrimFloat.abs f) :: vs; rt_frames := st.(rt_frames);
                  rt_memory := st.(rt_memory); rt_cycle_cnt := st.(rt_cycle_cnt) + 1; |}
      | _ => None
      end
  | F64_NEG =>
      match st.(rt_values) with
      | V_F64 f :: vs =>
          Some {| rt_values := V_F64 (PrimFloat.opp f) :: vs; rt_frames := st.(rt_frames);
                  rt_memory := st.(rt_memory); rt_cycle_cnt := st.(rt_cycle_cnt) + 1; |}
      | _ => None
      end
  | F64_SQRT =>
      match st.(rt_values) with
      | V_F64 f :: vs =>
          Some {| rt_values := V_F64 (PrimFloat.sqrt f) :: vs; rt_frames := st.(rt_frames);
                  rt_memory := st.(rt_memory); rt_cycle_cnt := st.(rt_cycle_cnt) + 1; |}
      | _ => None
      end

  (* ── 类型转换 ── *)
  | I32_WRAP_I64 =>
      match st.(rt_values) with
      | V_I64 n :: vs =>
          Some {| rt_values := V_I32 (Z.land n 4294967295) :: vs; rt_frames := st.(rt_frames);
                  rt_memory := st.(rt_memory); rt_cycle_cnt := st.(rt_cycle_cnt) + 1; |}
      | _ => None
      end
  | I64_EXTEND_I32_S =>
      match st.(rt_values) with
      | V_I32 n :: vs =>
          Some {| rt_values := V_I64 n :: vs; rt_frames := st.(rt_frames);
                  rt_memory := st.(rt_memory); rt_cycle_cnt := st.(rt_cycle_cnt) + 1; |}
      | _ => None
      end
  | I32_TRUNC_F32_S =>
      match st.(rt_values) with
      | V_F32 f :: vs => Some {| rt_values := V_I32 0 :: vs; rt_frames := st.(rt_frames);
                                  rt_memory := st.(rt_memory); rt_cycle_cnt := st.(rt_cycle_cnt) + 1; |}
      | _ => None
      end
  | I32_TRUNC_F64_S =>
      match st.(rt_values) with
      | V_F64 f :: vs => Some {| rt_values := V_I32 0 :: vs; rt_frames := st.(rt_frames);
                                  rt_memory := st.(rt_memory); rt_cycle_cnt := st.(rt_cycle_cnt) + 1; |}
      | _ => None
      end
  | F32_CONVERT_I32_S =>
      match st.(rt_values) with
      | V_I32 _ :: vs => Some {| rt_values := V_F32 (PrimFloat.zero) :: vs;
                                 rt_frames := st.(rt_frames); rt_memory := st.(rt_memory);
                                 rt_cycle_cnt := st.(rt_cycle_cnt) + 1; |}
      | _ => None
      end
  | F64_CONVERT_I32_S =>
      match st.(rt_values) with
      | V_I32 _ :: vs => Some {| rt_values := V_F64 (PrimFloat.zero) :: vs;
                                 rt_frames := st.(rt_frames); rt_memory := st.(rt_memory);
                                 rt_cycle_cnt := st.(rt_cycle_cnt) + 1; |}
      | _ => None
      end

  (* ── 内存操作 ── *)
  | I32_LOAD arg | I64_LOAD arg | F32_LOAD arg | F64_LOAD arg =>
      match st.(rt_values) with
      | V_I32 addr :: vs =>
          match read_memory st addr arg.(mem_offset) with
          | Some v => Some {| rt_values := v :: vs;
                              rt_frames := st.(rt_frames);
                              rt_memory := st.(rt_memory);
                              rt_cycle_cnt := st.(rt_cycle_cnt) + 1; |}
          | None => None
          end
      | _ => None
      end
  | I32_LOAD8_U arg =>
      match st.(rt_values) with
      | V_I32 addr :: vs =>
          let byte_val := match read_memory st addr arg.(mem_offset) with
                          | Some (V_I32 v) => v mod 256
                          | _ => 0
                          end in
          Some {| rt_values := V_I32 byte_val :: vs;
                  rt_frames := st.(rt_frames);
                  rt_memory := st.(rt_memory);
                  rt_cycle_cnt := st.(rt_cycle_cnt) + 1; |}
      | _ => None
      end
  | I32_STORE _ | I64_STORE _ | F32_STORE _ | F64_STORE _ =>
      match st.(rt_values) with
      | V_I32 _ :: V_I32 _ :: vs =>
          Some {| rt_values := vs; rt_frames := st.(rt_frames);
                  rt_memory := st.(rt_memory); rt_cycle_cnt := st.(rt_cycle_cnt) + 1; |}
      | _ => None
      end
  | I32_STORE8 _ =>
      match st.(rt_values) with
      | V_I32 _ :: V_I32 _ :: vs =>
          Some {| rt_values := vs; rt_frames := st.(rt_frames);
                  rt_memory := st.(rt_memory); rt_cycle_cnt := st.(rt_cycle_cnt) + 1; |}
      | _ => None
      end

  (* ── 控制流 ── *)
  | BR depth =>
      match st.(rt_frames) with
      | f :: fr =>
          let new_pc := match List.nth_error f.(frame_block_stack) (Z.to_nat depth) with
                        | Some addr => addr
                        | None => f.(frame_pc)
                        end in
          let new_bs := List.firstn (Z.to_nat depth) f.(frame_block_stack) in
          let f' := {| frame_locals := f.(frame_locals);
                       frame_func_idx := f.(frame_func_idx);
                       frame_pc := new_pc;
                       frame_block_stack := new_bs |} in
          Some {| rt_values := st.(rt_values);
                  rt_frames := f' :: fr;
                  rt_memory := st.(rt_memory);
                  rt_cycle_cnt := st.(rt_cycle_cnt) + 1 |}
      | nil => None
      end
  | BR_IF depth =>
      match st.(rt_values) with
      | V_I32 0 :: vs =>
          Some {| rt_values := vs; rt_frames := st.(rt_frames);
                  rt_memory := st.(rt_memory); rt_cycle_cnt := st.(rt_cycle_cnt) + 1 |}
      | V_I32 _ :: vs =>
          (* nonzero → branch *)
          match st.(rt_frames) with
          | f :: fr =>
              let new_pc := match List.nth_error f.(frame_block_stack) (Z.to_nat depth) with
                            | Some addr => addr
                            | None => f.(frame_pc)
                            end in
              let new_bs := List.firstn (Z.to_nat depth) f.(frame_block_stack) in
              let f' := {| frame_locals := f.(frame_locals);
                           frame_func_idx := f.(frame_func_idx);
                           frame_pc := new_pc;
                           frame_block_stack := new_bs |} in
              Some {| rt_values := vs; rt_frames := f' :: fr;
                      rt_memory := st.(rt_memory);
                      rt_cycle_cnt := st.(rt_cycle_cnt) + 1 |}
          | nil => None
          end
      | _ :: vs =>
          Some {| rt_values := vs; rt_frames := st.(rt_frames);
                  rt_memory := st.(rt_memory); rt_cycle_cnt := st.(rt_cycle_cnt) + 1 |}
      | nil => None
      end
  | BLOCK len =>
      match st.(rt_frames) with
      | f :: fr =>
          let new_bs := (f.(frame_pc) + len) :: f.(frame_block_stack) in
          let f' := {| frame_locals := f.(frame_locals);
                       frame_func_idx := f.(frame_func_idx);
                       frame_pc := f.(frame_pc);
                       frame_block_stack := new_bs |} in
          Some {| rt_values := st.(rt_values); rt_frames := f' :: fr;
                  rt_memory := st.(rt_memory); rt_cycle_cnt := st.(rt_cycle_cnt) + 1 |}
      | nil => None
      end
  | LOOP len =>
      match st.(rt_frames) with
      | f :: fr =>
          let new_bs := f.(frame_pc) :: f.(frame_block_stack) in
          let f' := {| frame_locals := f.(frame_locals);
                       frame_func_idx := f.(frame_func_idx);
                       frame_pc := f.(frame_pc);
                       frame_block_stack := new_bs |} in
          Some {| rt_values := st.(rt_values); rt_frames := f' :: fr;
                  rt_memory := st.(rt_memory); rt_cycle_cnt := st.(rt_cycle_cnt) + 1 |}
      | nil => None
      end
  | RETURN =>
      match st.(rt_frames) with
      | _ :: fr =>
          Some {| rt_values := st.(rt_values); rt_frames := fr;
                  rt_memory := st.(rt_memory); rt_cycle_cnt := st.(rt_cycle_cnt) + 1 |}
      | nil => None
      end
  | CALL _ =>
      None

  (* ── 安全扩展 ── *)
  | UNREACHABLE => None
  | SAFE_ASSERT _ => Some st
  | SAFE_BOUNDS_CHECK _ _ => Some st

  (* 其余指令由上面的分支覆盖 *)
  end.

(* 序列执行: 依次执行每条指令，失败则返回 None *)
Fixpoint exec_instrs (st : runtime_state) (instrs : list sasm_instr) : option runtime_state :=
  match instrs with
  | nil => Some st
  | i :: rest =>
      match exec_instr st i with
      | Some st' => exec_instrs st' rest
      | None => None
      end
  end.

(* ================================================================
   第 7b 节：帧栈长度不变引理

   compile_expr 生成的指令序列不改变帧栈长度（仅操作值栈）。
   注意：LOCAL_SET/LOCAL_TEE 会通过 set_local 修改栈帧内容，
   因此无法保证帧栈精确相等，只能保证长度不变。
   ================================================================ *)

Lemma exec_instr_not_return_preserves_frame_count : forall (st : runtime_state) (i : sasm_instr) (st' : runtime_state),
    exec_instr st i = Some st' ->
    i <> RETURN ->
    List.length st'.(rt_frames) = List.length st.(rt_frames).
Proof.
  intros st i st' Hexec Hnotret.
  destruct i; simpl in Hexec; try discriminate.
  all: try (exfalso; apply Hnotret; reflexivity).
  all: repeat match type of Hexec with
    | context[match ?x with _ => _ end] =>
        destruct x eqn:?; simpl in Hexec; try discriminate
    | context[if ?x then _ else _] =>
        destruct x eqn:?; simpl in Hexec; try discriminate
    end;
    inversion Hexec; subst; simpl; rewrite ?Heqf, ?Heq0, ?Heq1, ?Heq2, ?Heq3, ?Heq4; simpl; reflexivity.
Qed.

Lemma exec_instrs_preserves_frame_count : forall (st : runtime_state) (instrs : list sasm_instr) (st' : runtime_state),
    exec_instrs st instrs = Some st' ->
    Forall (fun i => i <> RETURN) instrs ->
    List.length st'.(rt_frames) = List.length st.(rt_frames).
Proof.
  intros st instrs st' Hexec Hno_ret.
  revert st st' Hexec Hno_ret.
  induction instrs as [|i instrs']; intros st st' Hexec Hno_ret; simpl in Hexec.
  - inversion Hexec; reflexivity.
  - inversion Hno_ret as [|? ? Hi_not_ret Hrest']; subst.
    destruct (exec_instr st i) as [st1|] eqn:Hei; [|discriminate].
    eapply IHinstrs' in Hexec; [|exact Hrest'].
    eapply exec_instr_not_return_preserves_frame_count in Hei; [|exact Hi_not_ret].
    rewrite Hei in Hexec; exact Hexec.
Qed.

(* 说明：exec_instrs_preserves_frame_count 要求序列中所有指令都不是 RETURN。
   BLOCK/LOOP/BR/BR_IF 虽然操作块栈但不改变帧列表长度。 *)

(* ================================================================
   第 7c 节：指令序列拼接引理
   ================================================================ *)

Lemma exec_instrs_app : forall (st : runtime_state) (instrs1 instrs2 : list sasm_instr),
    exec_instrs st (instrs1 ++ instrs2) =
    match exec_instrs st instrs1 with
    | Some st' => exec_instrs st' instrs2
    | None => None
    end.
Proof.
  intros st instrs1. revert st. induction instrs1 as [|i instrs1']; intros st instrs2.
  - simpl. reflexivity.
  - simpl. destruct (exec_instr st i) as [st' |] eqn:Hei.
    + rewrite (IHinstrs1' st' instrs2). reflexivity.
    + reflexivity.
Qed.

Lemma exec_after_some : forall (st : runtime_state) (instrs1 instrs2 : list sasm_instr) (st1 : runtime_state),
    exec_instrs st instrs1 = Some st1 ->
    exec_instrs st (instrs1 ++ instrs2) = exec_instrs st1 instrs2.
Proof.
  intros st instrs1 instrs2 st1 Hexec.
  rewrite exec_instrs_app.
  rewrite Hexec.
  reflexivity.
Qed.

Lemma exec_after_some2 : forall (st : runtime_state) (a b c : list sasm_instr) (st1 st2 : runtime_state),
    exec_instrs st a = Some st1 ->
    exec_instrs st1 b = Some st2 ->
    exec_instrs st ((a ++ b) ++ c) = exec_instrs st2 c.
Proof.
  intros st a b c st1 st2 Hexec_a Hexec_b.
  rewrite (exec_after_some st (a ++ b) c st2).
  - reflexivity.
  - rewrite (exec_after_some st a b st1 Hexec_a). exact Hexec_b.
Qed.

(* ================================================================
   第 7d 节：通用栈引理 — compile_expr_correct_stack

   corest_eval_expr env_s e = Some v →
   从任意初始状态 st0 执行 compile_expr env e，
   只要 st0 的帧栈与 build_sasm_state env_s 一致，
   且 st0 的值栈恰好是 extra，
   则执行后值栈变为 st_val_to_sasm_val v :: extra，
   且帧栈不变。
   ================================================================ *)
Lemma compile_quality_status_no_return : forall (env : compile_env) (args : list corest_expr),
    Forall (fun i => i <> RETURN) (compile_quality_status env args).
Proof.
  intros env args.
  destruct args as [|a [|]].
  - (assert (H: compile_quality_status env [] = I32_CONST 0 :: nil)
       by (unfold compile_quality_status; compute; reflexivity);
     rewrite H; apply Forall_cons; congruence || apply Forall_nil).
  - destruct a as [lit | x | e1 e2 | op e | b e1 e2 | c e1 e2 | e1 e2 | e1 e2 | e1 e2 | f args' | q args''].
    ** (assert (H: compile_quality_status env [CE_LIT lit] = I32_CONST 0 :: nil)
           by (unfold compile_quality_status; compute; reflexivity);
        rewrite H; apply Forall_cons; congruence || apply Forall_nil).
    ** unfold compile_quality_status; destruct (lookup_var_idx env x) as [idx |];
       simpl; repeat constructor; try congruence.
    ** (assert (H: compile_quality_status env [CE_ARRAY_ACCESS e1 e2] = I32_CONST 0 :: nil)
           by (unfold compile_quality_status; compute; reflexivity);
        rewrite H; apply Forall_cons; congruence || apply Forall_nil).
    ** (assert (H: compile_quality_status env [CE_UNARY_OP op e] = I32_CONST 0 :: nil)
           by (unfold compile_quality_status; compute; reflexivity);
        rewrite H; apply Forall_cons; congruence || apply Forall_nil).
    ** (assert (H: compile_quality_status env [CE_BIN_OP b e1 e2] = I32_CONST 0 :: nil)
           by (unfold compile_quality_status; compute; reflexivity);
        rewrite H; apply Forall_cons; congruence || apply Forall_nil).
    ** (assert (H: compile_quality_status env [CE_COMP c e1 e2] = I32_CONST 0 :: nil)
           by (unfold compile_quality_status; compute; reflexivity);
        rewrite H; apply Forall_cons; congruence || apply Forall_nil).
    ** (assert (H: compile_quality_status env [CE_AND e1 e2] = I32_CONST 0 :: nil)
           by (unfold compile_quality_status; compute; reflexivity);
        rewrite H; apply Forall_cons; congruence || apply Forall_nil).
    ** (assert (H: compile_quality_status env [CE_OR e1 e2] = I32_CONST 0 :: nil)
           by (unfold compile_quality_status; compute; reflexivity);
        rewrite H; apply Forall_cons; congruence || apply Forall_nil).
    ** (assert (H: compile_quality_status env [CE_XOR e1 e2] = I32_CONST 0 :: nil)
           by (unfold compile_quality_status; compute; reflexivity);
        rewrite H; apply Forall_cons; congruence || apply Forall_nil).
    ** (assert (H: compile_quality_status env [CE_FUNC_CALL f args'] = I32_CONST 0 :: nil)
           by (unfold compile_quality_status; compute; reflexivity);
        rewrite H; apply Forall_cons; congruence || apply Forall_nil).
    ** (assert (H: compile_quality_status env [CE_QUALITY_OP q args''] = I32_CONST 0 :: nil)
           by (unfold compile_quality_status; compute; reflexivity);
        rewrite H; apply Forall_cons; congruence || apply Forall_nil).
  - (assert (H: compile_quality_status env (a :: c :: l) = I32_CONST 0 :: nil)
       by (unfold compile_quality_status; destruct a; reflexivity);
     rewrite H; apply Forall_cons; congruence || apply Forall_nil).
Qed.


Lemma compile_expr_no_return : forall (env : compile_env) (e : corest_expr),
    Forall (fun i => i <> RETURN) (compile_expr env e).
Proof.
      intro env.
      fix IH 1.                    (* ← 递归假设 IH，可作用于任意更小的 corest_expr *)
      intro e.
      destruct e as [lit | x | e1 e2 | op e1 | b e1 e2 | c e1 e2 | e1 e2 | e1 e2 | e1 e2 | f args | q args]; simpl.
      - (* CE_LIT *)
    destruct lit; repeat constructor; try congruence.
  - (* CE_VAR *)
    destruct (lookup_var_idx env x); repeat constructor; try congruence.
  - (* CE_ARRAY_ACCESS *)
    rewrite Forall_app; split; [apply IH |].
    rewrite Forall_app; split; [apply IH |].
    repeat constructor; try congruence.
  - (* CE_UNARY_OP *)
    destruct op; simpl.
    + (* U_NEG *)
      constructor; [try congruence |].
      rewrite Forall_app; split; [apply IH |].
      repeat constructor; try congruence.
    + (* U_NOT *)
      rewrite Forall_app; split; [apply IH |].
      repeat constructor; try congruence.
    + (* U_ABS *)
      rewrite Forall_app; split; [apply IH |].
      repeat constructor; try congruence.
  - (* CE_BIN_OP *)
    destruct b; simpl;
      rewrite Forall_app; split; try apply IH;
      rewrite Forall_app; split; try apply IH;
      repeat constructor; try congruence.
  - (* CE_COMP *)
    destruct c; simpl;
      rewrite Forall_app; split; try apply IH;
      rewrite Forall_app; split; try apply IH;
      repeat constructor; try congruence.
  - (* CE_AND *)
    simpl; rewrite Forall_app; split; try apply IH;
    rewrite Forall_app; split; try apply IH;
    repeat constructor; try congruence.
  - (* CE_OR *)
    simpl; rewrite Forall_app; split; try apply IH;
    rewrite Forall_app; split; try apply IH;
    repeat constructor; try congruence.
  - (* CE_XOR *)
    simpl; rewrite Forall_app; split; try apply IH;
    rewrite Forall_app; split; try apply IH;
    repeat constructor; try congruence.
  - (* CE_FUNC_CALL *)
    simpl; repeat constructor; try congruence.
  - (* CE_QUALITY_OP *)
    destruct q; simpl.
    -- (* Q_STATUS *)
      apply compile_quality_status_no_return.
    -- (* Q_VALUE *)
      induction args as [|a l IHl]; simpl.
      +++ repeat constructor; try congruence.
      +++ rewrite Forall_app; split; [apply IH; exact a | exact IHl].
    -- (* Q_GOOD *)
      rewrite Forall_app; split; [apply compile_quality_status_no_return | repeat constructor; try congruence].
    -- (* Q_BAD *)
      rewrite Forall_app; split; [apply compile_quality_status_no_return | repeat constructor; try congruence].
    -- (* Q_SET *)
      destruct args as [|a1 [|a2 [|a3 rest]]]; simpl.
      all: try solve [repeat constructor; discriminate].
      all: destruct a1; simpl.
      all: try solve [repeat constructor; discriminate].
      all: try solve [repeat constructor; discriminate].
      destruct (lookup_var_idx env i) as [idx|]; simpl;
        [ rewrite Forall_app; split;
          [ apply IH; exact a2
          | repeat constructor; try congruence ]
        | repeat constructor; try congruence ].
    -- (* Q_WITH *)
      destruct args as [|a1 [|a2 [|a3 rest]]]; simpl.
      all: try solve [repeat constructor; discriminate].
      rewrite Forall_app; split.
      + apply IH; exact a1.
      + apply IH; exact a2.
    -- (* Q_FORCE *)
      destruct args as [|a1 [|a2 [|a3 [|a4 rest]]]]; simpl.
      all: try solve [repeat constructor; discriminate].
      all: destruct a1; simpl.
      all: try solve [repeat constructor; discriminate].
      all: try solve [repeat constructor; discriminate].
      destruct (lookup_var_idx env i) as [idx|]; simpl;
        [ rewrite Forall_app; split;
          [ apply IH; exact a2
          | repeat constructor; try congruence;
            rewrite Forall_app; split;
            [ apply IH; exact a3
            | repeat constructor; try congruence ] ]
        | repeat constructor; try congruence ].
Qed.

(* ================================================================
   第 7e 节：compile_expr_preserves_frame_count

   compile_expr 生成的指令序列执行后，帧栈长度不变。
   ================================================================ *)

Lemma compile_expr_preserves_frame_count :
  forall (st0 st' : runtime_state) (env : compile_env) (e : corest_expr),
    exec_instrs st0 (compile_expr env e) = Some st' ->
    List.length st'.(rt_frames) = List.length st0.(rt_frames).
Proof.
  intros st0 st' env e Hexec.
  apply (exec_instrs_preserves_frame_count st0 (compile_expr env e) st' Hexec).
  apply compile_expr_no_return.
Qed.

(* ================================================================
   第 7e 节：表达式逐构造保持引理

   当前提供 compile_literal_correct / compile_var_correct /
   compile_int_binop_literal_correct；整体命题待 frame/memory 不变量重构。
   ================================================================ *)

(* 编译环境与求值环境的一致性 *)
Definition compile_env_matches (env : compile_env) (env_s : corest_eval_env) : Prop :=
  forall (x : ident) (idx : Z),
    lookup_var_idx env x = Some idx ->
    exists (v : st_value), List.In (x, v) env_s.

(* R1 支持的 32 位核心表达式。ABS/FB/质量/数组/浮点仍分别由后续证明处理。 *)
Fixpoint pc_expr_supported (e : corest_expr) : bool :=
  match e with
  | CE_LIT (L_BOOL _) | CE_LIT (L_INT _) | CE_VAR _ => true
  | CE_UNARY_OP U_NEG e1 | CE_UNARY_OP U_NOT e1 =>
      pc_expr_supported e1
  | CE_BIN_OP _ e1 e2 | CE_COMP _ e1 e2
  | CE_AND e1 e2 | CE_OR e1 e2 | CE_XOR e1 e2 =>
      pc_expr_supported e1 && pc_expr_supported e2
  | _ => false
  end.

Definition core_value_nonzero (v : st_value) : Prop :=
  match v with
  | ST_V_INT n | ST_V_DINT n => n <> 0
  | _ => False
  end.

Definition st_value_as_i32 (v : st_value) : option Z :=
  match v with
  | ST_V_BOOL b => Some (if b then 1 else 0)
  | ST_V_INT n | ST_V_DINT n => Some n
  | _ => None
  end.

Definition compile_state_values_i32 (env_s : corest_eval_env) : Prop :=
  forall (x : ident) (v : st_value),
    lookup_var env_s x = Some v ->
    exists n : Z,
      st_value_as_i32 v = Some n /\ st_val_to_sasm_val v = V_I32 n.

Lemma st_value_as_i32_sound :
  forall (v : st_value) (n : Z),
    st_value_as_i32 v = Some n ->
    st_val_to_sasm_val v = V_I32 n.
Proof.
  intros v n H.
  destruct v; simpl in H; try discriminate; inversion H; subst;
    reflexivity.
Qed.

Lemma core_value_nonzero_as_i32 :
  forall (v : st_value) (n : Z),
    core_value_nonzero v ->
    st_value_as_i32 v = Some n ->
    n <> 0.
Proof.
  intros v n Hnz Hv.
  destruct v; simpl in *; try contradiction; inversion Hv; subst; assumption.
Qed.

(* 运行期除法安全：递归子表达式可求值，且 DIV/MOD 的除数非零。 *)
Fixpoint pc_expr_safe (env_s : corest_eval_env) (e : corest_expr) : Prop :=
  match e with
  | CE_BIN_OP B_DIV e1 e2 =>
      pc_expr_safe env_s e1 /\
      pc_expr_safe env_s e2 /\
      (forall (v1 v2 : st_value),
        corest_eval_expr env_s e1 = Some v1 ->
        corest_eval_expr env_s e2 = Some v2 ->
        core_value_nonzero v2)
  | CE_BIN_OP B_MOD e1 e2 =>
      pc_expr_safe env_s e1 /\
      pc_expr_safe env_s e2 /\
      (forall (v1 v2 : st_value),
        corest_eval_expr env_s e1 = Some v1 ->
        corest_eval_expr env_s e2 = Some v2 ->
        core_value_nonzero v2)
  | CE_UNARY_OP _ e1 => pc_expr_safe env_s e1
  | CE_BIN_OP _ e1 e2 | CE_COMP _ e1 e2
  | CE_AND e1 e2 | CE_OR e1 e2 | CE_XOR e1 e2 =>
      pc_expr_safe env_s e1 /\ pc_expr_safe env_s e2
  | _ => True
  end.

Lemma pc_expr_safe_div_nonzero :
  forall (env_s : corest_eval_env) (e1 e2 : corest_expr)
         (v1 v2 : st_value),
    pc_expr_safe env_s (CE_BIN_OP B_DIV e1 e2) ->
    corest_eval_expr env_s e1 = Some v1 ->
    corest_eval_expr env_s e2 = Some v2 ->
    core_value_nonzero v2.
Proof.
  intros env_s e1 e2 v1 v2 Hsafe He1 He2.
  unfold pc_expr_safe in Hsafe.
  simpl in Hsafe.
  exact (proj2 (proj2 Hsafe) v1 v2 He1 He2).
Qed.

Lemma pc_expr_safe_mod_nonzero :
  forall (env_s : corest_eval_env) (e1 e2 : corest_expr)
         (v1 v2 : st_value),
    pc_expr_safe env_s (CE_BIN_OP B_MOD e1 e2) ->
    corest_eval_expr env_s e1 = Some v1 ->
    corest_eval_expr env_s e2 = Some v2 ->
    core_value_nonzero v2.
Proof.
  intros env_s e1 e2 v1 v2 Hsafe He1 He2.
  unfold pc_expr_safe in Hsafe.
  simpl in Hsafe.
  exact (proj2 (proj2 Hsafe) v1 v2 He1 He2).
Qed.

Lemma pc_expr_safe_div_nonzero_i32 :
  forall (env_s : corest_eval_env) (e1 e2 : corest_expr)
         (v1 v2 : st_value) (n : Z),
    pc_expr_safe env_s (CE_BIN_OP B_DIV e1 e2) ->
    corest_eval_expr env_s e1 = Some v1 ->
    corest_eval_expr env_s e2 = Some v2 ->
    st_value_as_i32 v2 = Some n ->
    n <> 0.
Proof.
  intros env_s e1 e2 v1 v2 n Hsafe He1 He2 Hn.
  eapply core_value_nonzero_as_i32.
  - eapply pc_expr_safe_div_nonzero; eauto.
  - exact Hn.
Qed.

Lemma pc_expr_safe_mod_nonzero_i32 :
  forall (env_s : corest_eval_env) (e1 e2 : corest_expr)
         (v1 v2 : st_value) (n : Z),
    pc_expr_safe env_s (CE_BIN_OP B_MOD e1 e2) ->
    corest_eval_expr env_s e1 = Some v1 ->
    corest_eval_expr env_s e2 = Some v2 ->
    st_value_as_i32 v2 = Some n ->
    n <> 0.
Proof.
  intros env_s e1 e2 v1 v2 n Hsafe He1 He2 Hn.
  eapply core_value_nonzero_as_i32.
  - eapply pc_expr_safe_mod_nonzero; eauto.
  - exact Hn.
Qed.

Lemma pc_expr_safe_binop_parts :
  forall (env_s : corest_eval_env) (op : binary_op)
         (e1 e2 : corest_expr),
    pc_expr_safe env_s (CE_BIN_OP op e1 e2) ->
    pc_expr_safe env_s e1 /\ pc_expr_safe env_s e2.
Proof.
  intros env_s op e1 e2 Hsafe.
  destruct op; simpl in Hsafe; tauto.
Qed.

Lemma pc_expr_safe_compare_parts :
  forall (env_s : corest_eval_env) (op : compare_op)
         (e1 e2 : corest_expr),
    pc_expr_safe env_s (CE_COMP op e1 e2) ->
    pc_expr_safe env_s e1 /\ pc_expr_safe env_s e2.
Proof.
  intros env_s op e1 e2 Hsafe.
  simpl in Hsafe; tauto.
Qed.

Lemma pc_expr_safe_and_parts :
  forall (env_s : corest_eval_env) (e1 e2 : corest_expr),
    pc_expr_safe env_s (CE_AND e1 e2) ->
    pc_expr_safe env_s e1 /\ pc_expr_safe env_s e2.
Proof.
  intros env_s e1 e2 Hsafe.
  simpl in Hsafe; tauto.
Qed.

Lemma pc_expr_safe_or_parts :
  forall (env_s : corest_eval_env) (e1 e2 : corest_expr),
    pc_expr_safe env_s (CE_OR e1 e2) ->
    pc_expr_safe env_s e1 /\ pc_expr_safe env_s e2.
Proof.
  intros env_s e1 e2 Hsafe.
  simpl in Hsafe; tauto.
Qed.

Lemma pc_expr_safe_xor_parts :
  forall (env_s : corest_eval_env) (e1 e2 : corest_expr),
    pc_expr_safe env_s (CE_XOR e1 e2) ->
    pc_expr_safe env_s e1 /\ pc_expr_safe env_s e2.
Proof.
  intros env_s e1 e2 Hsafe.
  simpl in Hsafe; tauto.
Qed.

Lemma binop_eval_witnesses :
  forall (env_s : corest_eval_env) (op : binary_op)
         (e1 e2 : corest_expr) (v : st_value),
    corest_eval_expr env_s (CE_BIN_OP op e1 e2) = Some v ->
    exists (v1 v2 : st_value),
      corest_eval_expr env_s e1 = Some v1 /\
      corest_eval_expr env_s e2 = Some v2.
Proof.
  intros env_s op e1 e2 v H.
  destruct op; unfold corest_eval_binop in H; simpl in H.
  all: destruct (corest_eval_expr env_s e1) as [v1|]; [|discriminate H].
  all: destruct (corest_eval_expr env_s e2) as [v2|]; [|discriminate H].
  all: exists v1, v2; auto.
Qed.

Lemma compare_eval_witnesses :
  forall (env_s : corest_eval_env) (op : compare_op)
         (e1 e2 : corest_expr) (v : st_value),
    corest_eval_expr env_s (CE_COMP op e1 e2) = Some v ->
    exists (v1 v2 : st_value),
      corest_eval_expr env_s e1 = Some v1 /\
      corest_eval_expr env_s e2 = Some v2.
Proof.
  intros env_s op e1 e2 v H.
  destruct op; unfold corest_eval_compare in H; simpl in H.
  all: destruct (corest_eval_expr env_s e1) as [v1|]; [|discriminate H].
  all: destruct (corest_eval_expr env_s e2) as [v2|]; [|discriminate H].
  all: exists v1, v2; auto.
Qed.

Lemma and_eval_witnesses :
  forall (env_s : corest_eval_env) (e1 e2 : corest_expr)
         (v : st_value),
    corest_eval_expr env_s (CE_AND e1 e2) = Some v ->
    exists (v1 v2 : st_value),
      corest_eval_expr env_s e1 = Some v1 /\
      corest_eval_expr env_s e2 = Some v2.
Proof.
  intros env_s e1 e2 v H.
  unfold corest_eval_logic_and in H; simpl in H.
  destruct (corest_eval_expr env_s e1) as [v1|]; [|discriminate H].
  destruct v1; simpl in H; try discriminate.
  destruct (corest_eval_expr env_s e2) as [v2|]; [|discriminate H].
  destruct v2; simpl in H; try discriminate.
  eexists; eexists; auto.
Qed.

Lemma or_eval_witnesses :
  forall (env_s : corest_eval_env) (e1 e2 : corest_expr)
         (v : st_value),
    corest_eval_expr env_s (CE_OR e1 e2) = Some v ->
    exists (v1 v2 : st_value),
      corest_eval_expr env_s e1 = Some v1 /\
      corest_eval_expr env_s e2 = Some v2.
Proof.
  intros env_s e1 e2 v H.
  unfold corest_eval_logic_or in H; simpl in H.
  destruct (corest_eval_expr env_s e1) as [v1|]; [|discriminate H].
  destruct v1; simpl in H; try discriminate.
  destruct (corest_eval_expr env_s e2) as [v2|]; [|discriminate H].
  destruct v2; simpl in H; try discriminate.
  eexists; eexists; auto.
Qed.

Lemma xor_eval_witnesses :
  forall (env_s : corest_eval_env) (e1 e2 : corest_expr)
         (v : st_value),
    corest_eval_expr env_s (CE_XOR e1 e2) = Some v ->
    exists (v1 v2 : st_value),
      corest_eval_expr env_s e1 = Some v1 /\
      corest_eval_expr env_s e2 = Some v2.
Proof.
  intros env_s e1 e2 v H.
  unfold corest_eval_logic_xor in H; simpl in H.
  destruct (corest_eval_expr env_s e1) as [v1|]; [|discriminate H].
  destruct v1; simpl in H; try discriminate.
  destruct (corest_eval_expr env_s e2) as [v2|]; [|discriminate H].
  destruct v2; simpl in H; try discriminate.
  eexists; eexists; auto.
Qed.

Lemma neg_eval_witness :
  forall (env_s : corest_eval_env) (e1 : corest_expr) (v : st_value),
    corest_eval_expr env_s (CE_UNARY_OP U_NEG e1) = Some v ->
    exists v1 : st_value, corest_eval_expr env_s e1 = Some v1.
Proof.
  intros env_s e1 v H.
  simpl in H.
  destruct (corest_eval_expr env_s e1) as [v1|]; [|discriminate H].
  exists v1. reflexivity.
Qed.

Lemma not_eval_witness :
  forall (env_s : corest_eval_env) (e1 : corest_expr) (v : st_value),
    corest_eval_expr env_s (CE_UNARY_OP U_NOT e1) = Some v ->
    exists v1 : st_value, corest_eval_expr env_s e1 = Some v1.
Proof.
  intros env_s e1 v H.
  simpl in H.
  destruct (corest_eval_expr env_s e1) as [v1|]; [|discriminate H].
  exists v1. reflexivity.
Qed.

Definition pc_frame_env_matches (env : compile_env)
           (env_s : corest_eval_env) (f : sasm_frame) : Prop :=
  forall (x : ident) (v : st_value),
    corest_eval_expr env_s (CE_VAR x) = Some v ->
    exists (idx : Z) (n : Z),
      lookup_var_idx env x = Some idx /\
      st_value_as_i32 v = Some n /\
      List.nth_error f.(frame_locals) (Z.to_nat idx) = Some (V_I32 n).

Lemma pc_frame_env_matches_build_compile_env :
  forall (cf : corest_function) (env_s : corest_eval_env),
    compile_state_env_matches (build_compile_type_env cf) env_s ->
    compile_state_values_i32 env_s ->
    pc_frame_env_matches (build_compile_env cf) env_s
      {| frame_locals :=
           sasm_locals_of_decls (build_compile_type_env cf) env_s;
         frame_func_idx := 0;
         frame_pc := 0;
         frame_block_stack := [] |}.
Proof.
  intros cf env_s Hmatch Hvalues.
  unfold pc_frame_env_matches.
  intros x v Heval.
  destruct (Hmatch x v Heval) as [ty Htype].
  destruct (build_compile_env_idx_of_type cf x ty Htype) as [idx Hidx].
  destruct (sasm_locals_of_decls_lookup
              (build_compile_type_env cf) env_s 0 x ty v Htype Heval)
    as [idx' [Hidx' Hnth]].
  assert (Hidx_combined :
    lookup_var_idx
      (assign_env_indices (cf.(cfunc_params) ++ cf.(cfunc_locals)) 0) x =
    Some idx).
  { unfold build_compile_env in Hidx.
    rewrite <- assign_env_indices_app in Hidx.
    exact Hidx. }
  unfold build_compile_type_env in Hidx'.
  rewrite Hidx_combined in Hidx'.
  inversion Hidx'; subst idx'.
  destruct (Hvalues x v Heval) as [n [Hn Hsv]].
  exists idx, n.
  split.
  + unfold build_compile_env.
    rewrite <- assign_env_indices_app.
    exact Hidx_combined.
  + split; [exact Hn |].
    replace (idx - 0) with idx in Hnth by ring.
    change (List.nth_error
              (sasm_locals_of_decls (build_compile_type_env cf) env_s)
              (Z.to_nat idx) = Some (V_I32 n)).
    rewrite Hnth, Hsv.
    reflexivity.
Qed.

Lemma sasm_locals_of_decls_length :
  forall (decls : compile_type_env) (env_s : corest_eval_env),
    List.length (sasm_locals_of_decls decls env_s) = List.length decls.
Proof.
  induction decls as [|[x ty] rest IH]; intros env_s; simpl.
  - reflexivity.
  - destruct (lookup_var env_s x); simpl; rewrite IH; reflexivity.
Qed.

Lemma compile_env_fits_locals_of_decls :
  forall (cf : corest_function) (env_s : corest_eval_env),
    compile_env_fits_frame (build_compile_env cf)
      {| frame_locals :=
           sasm_locals_of_decls (build_compile_type_env cf) env_s;
         frame_func_idx := 0;
         frame_pc := 0;
         frame_block_stack := [] |}.
Proof.
  intros cf env_s x idx Hidx.
  pose proof (build_compile_env_bound cf x idx Hidx) as [Hnonneg Hbound].
  pose proof (build_compile_env_nonneg cf x idx Hidx) as Hnonneg'.
  change (Z.to_nat idx <
    List.length (sasm_locals_of_decls (build_compile_type_env cf) env_s))%nat.
  rewrite sasm_locals_of_decls_length.
  unfold build_compile_type_env in *.
  rewrite List.length_app.
  assert (Hnat :
    (Z.to_nat idx <
     Z.to_nat
       (Z.of_nat (List.length (cfunc_params cf) +
                  List.length (cfunc_locals cf))))%nat).
  { apply (proj1 (Z2Nat.inj_lt idx
      (Z.of_nat (List.length (cfunc_params cf) +
                  List.length (cfunc_locals cf)))
      Hnonneg' (Zle_0_nat _))).
    exact Hbound. }
  rewrite Nat2Z.id in Hnat.
  exact Hnat.
Qed.

Lemma ident_eq_sound_codegen :
  forall (x y : ident),
    ident_eq x y = true -> x = y.
Proof.
  intros [sx] [sy] H.
  simpl in H.
  apply String.eqb_eq in H.
  subst. reflexivity.
Qed.

Lemma ident_eq_false_neq :
  forall (x y : ident),
    ident_eq x y = false -> x <> y.
Proof.
  intros [sx] [sy] H Heq.
  inversion Heq; subst.
  simpl in H.
  rewrite String.eqb_refl in H.
  discriminate.
Qed.

Lemma lookup_var_cons :
  forall (x y : ident) (v : st_value) (vars : corest_eval_env),
    lookup_var ((x, v) :: vars) y =
    if ident_eq y x then Some v else lookup_var vars y.
Proof.
  intros x y v vars.
  simpl.
  destruct (ident_eq y x); reflexivity.
Qed.

Lemma pc_frame_env_matches_update :
  forall (env : compile_env) (s : st_state) (f : sasm_frame)
         (x : ident) (v : st_value) (n idx : Z),
    compile_env_injective env ->
    compile_env_nonneg env ->
    lookup_var_idx env x = Some idx ->
    st_value_as_i32 v = Some n ->
    (Z.to_nat idx < List.length f.(frame_locals))%nat ->
    pc_frame_env_matches env s.(st_vars) f ->
    pc_frame_env_matches env ((x, v) :: s.(st_vars))
      {| frame_locals := list_set f.(frame_locals) (Z.to_nat idx) (V_I32 n);
         frame_func_idx := f.(frame_func_idx);
         frame_pc := f.(frame_pc);
         frame_block_stack := f.(frame_block_stack) |}.
Proof.
  intros env s f x v n idx Hinj Hnonneg Hidx Hn Hbound Henv.
  unfold pc_frame_env_matches in *.
  intros y vy.
  intro Hy.
  simpl in Hy.
  destruct (ident_eq y x) eqn:Hyx.
  - apply ident_eq_sound_codegen in Hyx.
    subst y.
    inversion Hy; subst vy.
    exists idx, n.
    repeat split; [exact Hidx | exact Hn |].
    apply list_set_nth_same.
  - pose proof (ident_eq_false_neq y x Hyx) as Hneq_yx.
    destruct (Henv y vy Hy) as [iy [ny [Hiy [Hny Hnth]]]].
    exists iy, ny.
    repeat split; [exact Hiy | exact Hny |].
    assert (Hiy_ne : iy <> idx).
    { intro Heq.
      apply Hneq_yx.
      symmetry.
      eapply Hinj; [exact Hidx | exact Hiy | symmetry; exact Heq]. }
    assert (Hnat_ne : Z.to_nat idx <> Z.to_nat iy).
    { intro Heq.
      pose proof (Z2Nat.inj idx iy
                    (Hnonneg x idx Hidx) (Hnonneg y iy Hiy) Heq) as Hziy.
      apply Hiy_ne. symmetry. exact Hziy. }
    etransitivity.
    + apply list_set_nth_diff.
      * exact Hnat_ne.
      * exact Hbound.
    + exact Hnth.
Qed.

Lemma pc_frame_env_matches_locals_eq :
  forall (env : compile_env) (env_s : corest_eval_env)
         (f f' : sasm_frame),
    f'.(frame_locals) = f.(frame_locals) ->
    pc_frame_env_matches env env_s f ->
    pc_frame_env_matches env env_s f'.
Proof.
  intros env env_s f f' Hlocals Hmatch x v Heval.
  destruct (Hmatch x v Heval) as [idx [n [Hidx [Hn Hnth]]]].
  exists idx, n.
  repeat split; [exact Hidx | exact Hn |].
  rewrite Hlocals.
  exact Hnth.
Qed.

Lemma compile_env_fits_frame_update :
  forall (env : compile_env) (f : sasm_frame) (x : ident) (idx : Z)
         (v : sasm_value),
    compile_env_fits_frame env f ->
    lookup_var_idx env x = Some idx ->
    compile_env_fits_frame env
      {| frame_locals := list_set f.(frame_locals) (Z.to_nat idx) v;
         frame_func_idx := f.(frame_func_idx);
         frame_pc := f.(frame_pc);
         frame_block_stack := f.(frame_block_stack) |}.
Proof.
  intros env f x idx v Hfit Hidx y iy Hlook.
  unfold compile_env_fits_frame in *.
  simpl.
  rewrite list_set_length.
  - exact (Hfit y iy Hlook).
    - exact (Hfit x idx Hidx).
Qed.

Lemma compile_env_fits_frame_locals_eq :
  forall (env : compile_env) (f f' : sasm_frame),
    f'.(frame_locals) = f.(frame_locals) ->
    compile_env_fits_frame env f ->
    compile_env_fits_frame env f'.
Proof.
  intros env f f' Hlocals Hfit x idx Hidx.
  rewrite Hlocals.
  exact (Hfit x idx Hidx).
Qed.

Definition expr_pc_post (f : sasm_frame) (fr : frame_stack)
           (input : value_stack) (mem : list Z) (code : list sasm_instr)
           (s' : runtime_state) (v : st_value) : Prop :=
  s'.(rt_values) = st_val_to_sasm_val v :: input /\
  s'.(rt_frames) =
    set_frame_pc f (f.(frame_pc) + instrs_total_size code) :: fr /\
  s'.(rt_memory) = mem.

Definition expr_pc_result_i32 (f : sasm_frame) (fr : frame_stack)
           (input : value_stack) (mem : list Z) (code : list sasm_instr)
           (s' : runtime_state) (v : st_value) (n : Z) : Prop :=
  expr_pc_post f fr input mem code s' v /\
  st_value_as_i32 v = Some n.

Lemma exists_snd_extract :
  forall (A : Type) (P : A -> Prop),
    (exists (a : A) (n : Z), P a) ->
    exists a : A, P a.
Proof.
  intros A P H.
  destruct H as [a [n Ha]].
  exists a. exact Ha.
Qed.

Lemma exists_snd_with_extra :
  forall (A : Type) (P : A -> Prop) (Q : Z -> Prop),
    (exists (a : A) (n : Z), P a /\ Q n) ->
    exists a : A, P a.
Proof.
  intros A P Q H.
  destruct H as [a [n [Pa Qn]]].
  exists a. exact Pa.
Qed.

Lemma exists_snd_drop_component :
  forall (A : Type) (P R : A -> Prop) (Q : Z -> Prop),
    (exists (a : A) (n : Z), P a /\ R a /\ Q n) ->
    exists a : A, P a /\ R a.
Proof.
  intros A P R Q H.
  destruct H as [a [n [Pa [Ra Qn]]]].
  exists a. split; assumption.
Qed.

Definition expr_pc_property (env : compile_env) (env_s : corest_eval_env)
           (e : corest_expr) (v : st_value) (code : list sasm_instr) : Prop :=
  forall (m : sasm_module) (fn : sasm_function) (f : sasm_frame)
         (fr : frame_stack) (input : value_stack) (mem : list Z) (cyc : Z)
         (prefix suffix : list sasm_instr),
    lookup_function m f.(frame_func_idx) = Some fn ->
    fn.(sasm_body) = prefix ++ code ++ suffix ->
    f.(frame_pc) = instrs_total_size prefix ->
    pc_frame_env_matches env env_s f ->
    pc_expr_safe env_s e ->
    corest_eval_expr env_s e = Some v ->
    exists (s' : runtime_state) (n : Z),
      multi_pc_step m
        {| rt_values := input; rt_frames := f :: fr;
           rt_memory := mem; rt_cycle_cnt := cyc |}
        s' /\
      expr_pc_post f fr input mem code s' v /\
      st_value_as_i32 v = Some n.

Lemma set_frame_pc_set_frame_pc :
  forall (f : sasm_frame) (p q : Z),
    set_frame_pc (set_frame_pc f p) q = set_frame_pc f q.
Proof.
  intros f p q.
  unfold set_frame_pc.
  reflexivity.
Qed.

Lemma instrs_total_size_singleton :
  forall (i : sasm_instr),
    instrs_total_size [i] = instr_size i.
Proof.
  intros i. simpl. rewrite Z.add_0_r. reflexivity.
Qed.

Lemma instrs_total_size_append_singleton :
  forall (c1 c2 : list sasm_instr) (op : sasm_instr),
    instrs_total_size (c1 ++ c2 ++ [op]) =
    instrs_total_size c1 + instrs_total_size c2 + instr_size op.
Proof.
  intros c1 c2 op.
  rewrite instrs_total_size_app.
  rewrite instrs_total_size_app.
  rewrite instrs_total_size_singleton.
  lia.
Qed.

Lemma pc_set_frame_after_append :
  forall (f : sasm_frame) (prefix suffix : list sasm_instr),
    f.(frame_pc) = instrs_total_size prefix ->
    set_frame_pc f (instrs_total_size prefix + instrs_total_size suffix) =
    set_frame_pc f (f.(frame_pc) + instrs_total_size suffix).
Proof.
  intros f prefix suffix Hpc.
  rewrite <- Hpc.
  reflexivity.
Qed.

Lemma pc_set_frame_after_singleton :
  forall (f : sasm_frame) (prefix : list sasm_instr) (i : sasm_instr),
    f.(frame_pc) = instrs_total_size prefix ->
    set_frame_pc f (instrs_total_size prefix + instr_size i) =
    set_frame_pc f (f.(frame_pc) + instrs_total_size [i]).
Proof.
  intros f prefix i Hpc.
  rewrite <- Hpc.
  rewrite instrs_total_size_singleton.
  reflexivity.
Qed.

Lemma compile_lit_int_pc :
  forall (m : sasm_module) (fn : sasm_function) (f : sasm_frame)
         (fr : frame_stack) (env : compile_env) (env_s : corest_eval_env)
         (n : Z) (v : st_value) (vs : value_stack) (mem : list Z) (cyc : Z)
         (prefix suffix : list sasm_instr),
    lookup_function m f.(frame_func_idx) = Some fn ->
    fn.(sasm_body) = prefix ++ [I32_CONST n] ++ suffix ->
    f.(frame_pc) = instrs_total_size prefix ->
    corest_eval_expr env_s (CE_LIT (L_INT n)) = Some v ->
    exists (s' : runtime_state),
      multi_pc_step m
        {| rt_values := vs; rt_frames := f :: fr;
           rt_memory := mem; rt_cycle_cnt := cyc |}
        s' /\
      s'.(rt_values) = st_val_to_sasm_val v :: vs /\
      s'.(rt_frames) =
        set_frame_pc f
          (f.(frame_pc) + instrs_total_size [I32_CONST n]) :: fr /\
      s'.(rt_memory) = mem.
Proof.
  intros m fn f fr env env_s n v vs mem cyc prefix suffix
    Hlook Hbody Hpc Heval.
  simpl in Heval.
  inversion Heval; subst.
  set (next := instrs_total_size prefix + instr_size (I32_CONST n)).
  exists (push_value (V_I32 n)
    (replace_top_frame_noinc
      {| rt_values := vs; rt_frames := f :: fr;
         rt_memory := mem; rt_cycle_cnt := cyc |}
      (set_frame_pc f next))).
  split.
  - eapply pc_i32_const_multi with
      (rest := fr) (n := n) (next := next).
    + reflexivity.
    + subst next.
      apply fetch_frame_instr_app_exact with
        (fn := fn) (prefix := prefix) (i := I32_CONST n) (rest := suffix);
        [exact Hlook | | exact Hpc].
      change (fn.(sasm_body) =
        prefix ++ I32_CONST n :: suffix).
      simpl in Hbody.
      exact Hbody.
  - subst next.
    split.
    + reflexivity.
    + split.
      * change (set_frame_pc f
                  (instrs_total_size prefix + instr_size (I32_CONST n)) :: fr =
                set_frame_pc f
                  (f.(frame_pc) + instrs_total_size [I32_CONST n]) :: fr).
        f_equal. apply pc_set_frame_after_singleton; exact Hpc.
      * reflexivity.
Qed.

Lemma compile_lit_bool_pc :
  forall (m : sasm_module) (fn : sasm_function) (f : sasm_frame)
         (fr : frame_stack) (env : compile_env) (env_s : corest_eval_env)
         (b : bool) (v : st_value) (vs : value_stack) (mem : list Z) (cyc : Z)
         (prefix suffix : list sasm_instr),
    lookup_function m f.(frame_func_idx) = Some fn ->
    fn.(sasm_body) =
      prefix ++ [I32_CONST (if b then 1 else 0)] ++ suffix ->
    f.(frame_pc) = instrs_total_size prefix ->
    corest_eval_expr env_s (CE_LIT (L_BOOL b)) = Some v ->
    exists (s' : runtime_state),
      multi_pc_step m
        {| rt_values := vs; rt_frames := f :: fr;
           rt_memory := mem; rt_cycle_cnt := cyc |}
        s' /\
      s'.(rt_values) = st_val_to_sasm_val v :: vs /\
      s'.(rt_frames) =
        set_frame_pc f
          (f.(frame_pc) + instrs_total_size [I32_CONST (if b then 1 else 0)])
        :: fr /\
      s'.(rt_memory) = mem.
Proof.
  intros m fn f fr env env_s b v vs mem cyc prefix suffix
    Hlook Hbody Hpc Heval.
  simpl in Heval.
  inversion Heval; subst.
  set (next := instrs_total_size prefix +
                 instr_size (I32_CONST (if b then 1 else 0))).
  exists (push_value (V_I32 (if b then 1 else 0))
    (replace_top_frame_noinc
      {| rt_values := vs; rt_frames := f :: fr;
         rt_memory := mem; rt_cycle_cnt := cyc |}
      (set_frame_pc f next))).
  split.
  - eapply pc_i32_const_multi with
      (rest := fr) (n := if b then 1 else 0) (next := next).
    + reflexivity.
    + subst next.
      apply fetch_frame_instr_app_exact with
        (fn := fn) (prefix := prefix)
        (i := I32_CONST (if b then 1 else 0)) (rest := suffix);
        [exact Hlook | | exact Hpc].
      change (fn.(sasm_body) =
        prefix ++ I32_CONST (if b then 1 else 0) :: suffix).
      simpl in Hbody.
      exact Hbody.
  - subst next.
    destruct b; simpl.
    + split; [reflexivity |].
      split.
      * change (set_frame_pc f
                  (instrs_total_size prefix + instr_size (I32_CONST 1)) :: fr =
                set_frame_pc f
                  (f.(frame_pc) + instrs_total_size [I32_CONST 1]) :: fr).
        f_equal. apply pc_set_frame_after_singleton; exact Hpc.
      * reflexivity.
    + split; [reflexivity |].
      split.
      * change (set_frame_pc f
                  (instrs_total_size prefix + instr_size (I32_CONST 0)) :: fr =
                set_frame_pc f
                  (f.(frame_pc) + instrs_total_size [I32_CONST 0]) :: fr).
        f_equal. apply pc_set_frame_after_singleton; exact Hpc.
      * reflexivity.
Qed.

Lemma lit_int_zero_property :
  forall (env : compile_env) (env_s : corest_eval_env),
    expr_pc_property env env_s (CE_LIT (L_INT 0)) (ST_V_INT 0)
      [I32_CONST 0].
Proof.
  intros env env_s.
  unfold expr_pc_property.
  intros m fn f fr input mem cyc prefix suffix
    Hlook Hbody Hpc Henv Hsafe Heval.
  simpl in Heval.
  inversion Heval; subst.
  destruct (compile_lit_int_pc m fn f fr env env_s 0 (ST_V_INT 0)
              input mem cyc prefix suffix Hlook Hbody Hpc Heval)
    as [s' [Hmulti Hpost]].
  exists s', 0.
  split; [exact Hmulti | split; [exact Hpost | reflexivity]].
Qed.

Lemma lit_int_property :
  forall (env : compile_env) (env_s : corest_eval_env) (n : Z),
    expr_pc_property env env_s (CE_LIT (L_INT n)) (ST_V_INT n)
      [I32_CONST n].
Proof.
  intros env env_s n.
  unfold expr_pc_property.
  intros m fn f fr input mem cyc prefix suffix
    Hlook Hbody Hpc Henv Hsafe Heval.
  simpl in Heval.
  inversion Heval; subst.
  destruct (compile_lit_int_pc m fn f fr env env_s n (ST_V_INT n)
              input mem cyc prefix suffix Hlook Hbody Hpc Heval)
    as [s' [Hmulti Hpost]].
  exists s', n.
  split; [exact Hmulti | split; [exact Hpost | reflexivity]].
Qed.

Lemma lit_bool_property :
  forall (env : compile_env) (env_s : corest_eval_env) (b : bool),
    expr_pc_property env env_s (CE_LIT (L_BOOL b)) (ST_V_BOOL b)
      [I32_CONST (if b then 1 else 0)].
Proof.
  intros env env_s b.
  unfold expr_pc_property.
  intros m fn f fr input mem cyc prefix suffix
    Hlook Hbody Hpc Henv Hsafe Heval.
  simpl in Heval.
  inversion Heval; subst.
  destruct (compile_lit_bool_pc m fn f fr env env_s b (ST_V_BOOL b)
              input mem cyc prefix suffix Hlook Hbody Hpc Heval)
    as [s' [Hmulti Hpost]].
  exists s', (if b then 1 else 0).
  destruct b; simpl.
  - split; [exact Hmulti | split; [exact Hpost | reflexivity]].
  - split; [exact Hmulti | split; [exact Hpost | reflexivity]].
Qed.

Lemma compile_var_pc :
  forall (m : sasm_module) (fn : sasm_function) (f : sasm_frame)
         (fr : frame_stack) (env : compile_env) (env_s : corest_eval_env)
         (x : ident) (v : st_value) (vs : value_stack)
         (mem : list Z) (cyc : Z) (prefix suffix : list sasm_instr),
    lookup_function m f.(frame_func_idx) = Some fn ->
    fn.(sasm_body) = prefix ++ compile_expr env (CE_VAR x) ++ suffix ->
    f.(frame_pc) = instrs_total_size prefix ->
    pc_frame_env_matches env env_s f ->
    corest_eval_expr env_s (CE_VAR x) = Some v ->
    exists (s' : runtime_state),
      multi_pc_step m
        {| rt_values := vs; rt_frames := f :: fr;
           rt_memory := mem; rt_cycle_cnt := cyc |}
        s' /\
      s'.(rt_values) = st_val_to_sasm_val v :: vs /\
      s'.(rt_frames) =
        set_frame_pc f
          (f.(frame_pc) + instrs_total_size (compile_expr env (CE_VAR x)))
        :: fr /\
      s'.(rt_memory) = mem.
Proof.
  intros m fn f fr env env_s x v vs mem cyc prefix suffix
    Hlook Hbody Hpc Henv Heval.
  destruct (Henv x v Heval) as [idx [n [Hidx [Hn Hnth]]]].
  pose proof (st_value_as_i32_sound v n Hn) as Hsv.
  simpl in Hbody.
  rewrite Hidx in Hbody.
  simpl in Hbody.
  set (next := instrs_total_size prefix + instr_size (LOCAL_GET idx)).
  exists (push_value (V_I32 n)
    (replace_top_frame_noinc
      {| rt_values := vs; rt_frames := f :: fr;
         rt_memory := mem; rt_cycle_cnt := cyc |}
      (set_frame_pc f next))).
  split.
  - eapply pc_i32_local_get_multi with
      (rest := fr) (idx := idx) (next := next)
      (v := V_I32 n).
    + reflexivity.
    + subst next.
      apply fetch_frame_instr_app_exact with
        (fn := fn) (prefix := prefix) (i := LOCAL_GET idx) (rest := suffix);
        [exact Hlook | exact Hbody | exact Hpc].
    + exact Hnth.
  - subst next.
    split.
    + rewrite Hsv. reflexivity.
    + split.
      * simpl.
        rewrite Hidx.
        simpl.
        replace (instrs_total_size prefix + 5)
          with (f.(frame_pc) + 5) by lia.
        reflexivity.
      * reflexivity.
Qed.

Lemma var_expr_property :
  forall (env : compile_env) (env_s : corest_eval_env)
         (x : ident) (v : st_value),
    expr_pc_property env env_s (CE_VAR x) v (compile_expr env (CE_VAR x)).
Proof.
  intros env env_s x v.
  unfold expr_pc_property.
  intros m fn f fr input mem cyc prefix suffix
    Hlook Hbody Hpc Henv Hsafe Heval.
  destruct (Henv x v Heval) as [idx [n [Hidx [Hn Hnth]]]].
  destruct (compile_var_pc m fn f fr env env_s x v input mem cyc
              prefix suffix Hlook Hbody Hpc Henv Heval)
    as [s' [Hmulti [Hval [Hframes Hmemory]]]].
  exists s', n.
  split; [exact Hmulti |].
  split.
  - unfold expr_pc_post.
    split; [exact Hval | split; [exact Hframes | exact Hmemory]].
  - exact Hn.
Qed.

(* 统一的 I32 指令规范：把后续表达式的“最后一条二元指令”收敛到一个
   可组合关系，避免对每条 PC 规则重复展开。 *)
Inductive i32_binop_spec : sasm_instr -> Z -> Z -> Z -> Prop :=
  | I32Spec_add : forall n1 n2 r,
      r = n1 + n2 ->
      i32_binop_spec I32_ADD n1 n2 r
  | I32Spec_sub : forall n1 n2 r,
      r = n1 - n2 ->
      i32_binop_spec I32_SUB n1 n2 r
  | I32Spec_mul : forall n1 n2 r,
      r = n1 * n2 ->
      i32_binop_spec I32_MUL n1 n2 r
  | I32Spec_div : forall n1 n2 r,
      n2 <> 0 ->
      r = n1 / n2 ->
      i32_binop_spec I32_DIV_S n1 n2 r
  | I32Spec_rem : forall n1 n2 r,
      n2 <> 0 ->
      r = Z.rem n1 n2 ->
      i32_binop_spec I32_REM_S n1 n2 r
  | I32Spec_eq : forall n1 n2 r,
      r = (if Z.eqb n1 n2 then 1 else 0) ->
      i32_binop_spec I32_EQ n1 n2 r
  | I32Spec_ne : forall n1 n2 r,
      r = (if negb (Z.eqb n1 n2) then 1 else 0) ->
      i32_binop_spec I32_NE n1 n2 r
  | I32Spec_lt : forall n1 n2 r,
      r = (if n1 <? n2 then 1 else 0) ->
      i32_binop_spec I32_LT_S n1 n2 r
  | I32Spec_le : forall n1 n2 r,
      r = (if n1 <=? n2 then 1 else 0) ->
      i32_binop_spec I32_LE_S n1 n2 r
  | I32Spec_gt : forall n1 n2 r,
      r = (if n2 <? n1 then 1 else 0) ->
      i32_binop_spec I32_GT_S n1 n2 r
  | I32Spec_ge : forall n1 n2 r,
      r = (if n2 <=? n1 then 1 else 0) ->
      i32_binop_spec I32_GE_S n1 n2 r
  | I32Spec_and : forall n1 n2 r,
      r = Z.land n1 n2 ->
      i32_binop_spec I32_AND n1 n2 r
  | I32Spec_or : forall n1 n2 r,
      r = Z.lor n1 n2 ->
      i32_binop_spec I32_OR n1 n2 r
  | I32Spec_xor : forall n1 n2 r,
      r = Z.lxor n1 n2 ->
      i32_binop_spec I32_XOR n1 n2 r.

Lemma pc_i32_binop_spec_multi :
  forall (m : sasm_module) (s : runtime_state) (f : sasm_frame)
         (fr : frame_stack) (op : sasm_instr) (n1 n2 r : Z)
         (vs : value_stack) (next : Z),
    s.(rt_frames) = f :: fr ->
    fetch_frame_instr m f = Some (op, next) ->
    s.(rt_values) = V_I32 n2 :: V_I32 n1 :: vs ->
    i32_binop_spec op n1 n2 r ->
    multi_pc_step m s
      (set_top_values_cycle s (set_frame_pc f next) (V_I32 r :: vs)).
Proof.
  intros m s f fr op n1 n2 r vs next Hframe Hfetch Hvalues Hspec.
  inversion Hspec; subst.
  all: eapply Multi_pc_step; [econstructor; eauto | apply Multi_pc_refl].
Qed.

Inductive i32_unop_spec : sasm_instr -> Z -> Z -> Prop :=
  | I32Spec_eqz : forall n r,
      r = (if Z.eqb n 0 then 1 else 0) ->
      i32_unop_spec I32_EQZ n r.

Lemma pc_i32_unop_spec_multi :
  forall (m : sasm_module) (s : runtime_state) (f : sasm_frame)
         (fr : frame_stack) (op : sasm_instr) (n r : Z)
         (vs : value_stack) (next : Z),
    s.(rt_frames) = f :: fr ->
    fetch_frame_instr m f = Some (op, next) ->
    s.(rt_values) = V_I32 n :: vs ->
    i32_unop_spec op n r ->
    multi_pc_step m s
      (set_top_values_cycle s (set_frame_pc f next) (V_I32 r :: vs)).
Proof.
  intros m s f fr op n r vs next Hframe Hfetch Hvalues Hspec.
  inversion Hspec; subst.
  eapply Multi_pc_step.
  - eapply Pc_i32_eqz; eauto.
  - apply Multi_pc_refl.
Qed.

Definition binop_i32_instr (op : binary_op) : sasm_instr :=
  match op with
  | B_ADD => I32_ADD
  | B_SUB => I32_SUB
  | B_MUL => I32_MUL
  | B_DIV => I32_DIV_S
  | B_MOD => I32_REM_S
  end.

Definition compare_i32_instr (op : compare_op) : sasm_instr :=
  match op with
  | C_EQ => I32_EQ
  | C_NE => I32_NE
  | C_LT => I32_LT_S
  | C_LE => I32_LE_S
  | C_GT => I32_GT_S
  | C_GE => I32_GE_S
  end.

Lemma compile_expr_binop_shape :
  forall (env : compile_env) (op : binary_op)
         (e1 e2 : corest_expr),
    compile_expr env (CE_BIN_OP op e1 e2) =
    compile_expr env e1 ++ compile_expr env e2 ++
    [binop_i32_instr op].
Proof.
  intros env op e1 e2.
  destruct op; reflexivity.
Qed.

Lemma compile_expr_compare_shape :
  forall (env : compile_env) (op : compare_op)
         (e1 e2 : corest_expr),
    compile_expr env (CE_COMP op e1 e2) =
    compile_expr env e1 ++ compile_expr env e2 ++
    [compare_i32_instr op].
Proof.
  intros env op e1 e2.
  destruct op; reflexivity.
Qed.

Lemma compile_expr_and_shape :
  forall (env : compile_env) (e1 e2 : corest_expr),
    compile_expr env (CE_AND e1 e2) =
    compile_expr env e1 ++ compile_expr env e2 ++ [I32_AND].
Proof.
  reflexivity.
Qed.

Lemma compile_expr_or_shape :
  forall (env : compile_env) (e1 e2 : corest_expr),
    compile_expr env (CE_OR e1 e2) =
    compile_expr env e1 ++ compile_expr env e2 ++ [I32_OR].
Proof.
  reflexivity.
Qed.

Lemma compile_expr_xor_shape :
  forall (env : compile_env) (e1 e2 : corest_expr),
    compile_expr env (CE_XOR e1 e2) =
    compile_expr env e1 ++ compile_expr env e2 ++ [I32_XOR].
Proof.
  reflexivity.
Qed.

Lemma compile_expr_neg_shape :
  forall (env : compile_env) (e1 : corest_expr),
    compile_expr env (CE_UNARY_OP U_NEG e1) =
    [I32_CONST 0] ++ compile_expr env e1 ++ [I32_SUB].
Proof.
  reflexivity.
Qed.

Lemma compile_expr_not_shape :
  forall (env : compile_env) (e1 : corest_expr),
    compile_expr env (CE_UNARY_OP U_NOT e1) =
    compile_expr env e1 ++ [I32_EQZ].
Proof.
  reflexivity.
Qed.

Lemma corest_binop_spec_i32 :
  forall (env_s : corest_eval_env) (op : binary_op)
         (e1 e2 : corest_expr) (v1 v2 v : st_value) (n1 n2 : Z),
    corest_eval_expr env_s e1 = Some v1 ->
    corest_eval_expr env_s e2 = Some v2 ->
    corest_eval_expr env_s (CE_BIN_OP op e1 e2) = Some v ->
    st_value_as_i32 v1 = Some n1 ->
    st_value_as_i32 v2 = Some n2 ->
    pc_expr_safe env_s (CE_BIN_OP op e1 e2) ->
    exists n : Z,
      st_value_as_i32 v = Some n /\
      i32_binop_spec (binop_i32_instr op) n1 n2 n.
Proof.
  intros env_s op e1 e2 v1 v2 v n1 n2 He1 He2 Heval Hn1 Hn2 Hsafe.
  simpl in Heval.
  rewrite He1, He2 in Heval.
  destruct op; simpl in Heval.
  - destruct v1; simpl in Hn1; try discriminate;
      destruct v2; simpl in Hn2; try discriminate;
      simpl in Heval; try discriminate; inversion Heval; subst;
      inversion Hn1; subst; inversion Hn2; subst.
    all: eexists; split; [reflexivity | constructor; reflexivity].
  - destruct v1; simpl in Hn1; try discriminate;
      destruct v2; simpl in Hn2; try discriminate;
      simpl in Heval; try discriminate; inversion Heval; subst;
      inversion Hn1; subst; inversion Hn2; subst.
    all: eexists; split; [reflexivity | constructor; reflexivity].
  - destruct v1; simpl in Hn1; try discriminate;
      destruct v2; simpl in Hn2; try discriminate;
      simpl in Heval; try discriminate; inversion Heval; subst;
      inversion Hn1; subst; inversion Hn2; subst.
    all: eexists; split; [reflexivity | constructor; reflexivity].
  - assert (Hnz_core : core_value_nonzero v2)
      by (eapply pc_expr_safe_div_nonzero; eauto).
    assert (Hnz : n2 <> 0)
      by (eapply core_value_nonzero_as_i32; eauto).
    destruct v1; simpl in Hn1; try discriminate;
      destruct v2; simpl in Hn2; try discriminate;
      simpl in Heval; try discriminate; inversion Heval; subst;
      inversion Hn1; subst; inversion Hn2; subst.
    all: eexists; split; [reflexivity |].
    all: replace (if n2 =? 0 then 0 else n1 / n2) with (n1 / n2)
      by (destruct (n2 =? 0) eqn:Hzero;
          [apply Z.eqb_eq in Hzero; contradiction | reflexivity]).
    all: exact (I32Spec_div n1 n2 (n1 / n2) Hnz eq_refl).
  - assert (Hnz_core : core_value_nonzero v2)
      by (eapply pc_expr_safe_mod_nonzero; eauto).
    assert (Hnz : n2 <> 0)
      by (eapply core_value_nonzero_as_i32; eauto).
    destruct v1; simpl in Hn1; try discriminate;
      destruct v2; simpl in Hn2; try discriminate;
      simpl in Heval; try discriminate; inversion Heval; subst;
      inversion Hn1; subst; inversion Hn2; subst.
    all: eexists; split; [reflexivity |].
    all: replace (if n2 =? 0 then 0 else Z.rem n1 n2)
      with (Z.rem n1 n2)
      by (destruct (n2 =? 0) eqn:Hzero;
          [apply Z.eqb_eq in Hzero; contradiction | reflexivity]).
    all: exact (I32Spec_rem n1 n2 (Z.rem n1 n2) Hnz eq_refl).
Qed.

Lemma corest_compare_spec_i32 :
  forall (env_s : corest_eval_env) (op : compare_op)
         (e1 e2 : corest_expr) (v1 v2 v : st_value) (n1 n2 : Z),
    corest_eval_expr env_s e1 = Some v1 ->
    corest_eval_expr env_s e2 = Some v2 ->
    corest_eval_expr env_s (CE_COMP op e1 e2) = Some v ->
    st_value_as_i32 v1 = Some n1 ->
    st_value_as_i32 v2 = Some n2 ->
    exists n : Z,
      st_value_as_i32 v = Some n /\
      i32_binop_spec (compare_i32_instr op) n1 n2 n.
Proof.
  intros env_s op e1 e2 v1 v2 v n1 n2 He1 He2 Heval Hn1 Hn2.
  simpl in Heval.
  rewrite He1, He2 in Heval.
  destruct op; simpl in Heval.
  all: destruct v1; simpl in Hn1; try discriminate;
       destruct v2; simpl in Hn2; try discriminate;
       simpl in Heval; try discriminate; inversion Heval; subst;
       inversion Hn1; subst; inversion Hn2; subst.
  all: try (destruct b; destruct b0; simpl).
  all: try rewrite Z.gtb_ltb.
  all: try rewrite Z.geb_leb.
  all: simpl in *.
  all: eexists; split; [reflexivity |].
  all: first
    [ eapply I32Spec_eq; reflexivity
    | eapply I32Spec_ne; reflexivity
    | eapply I32Spec_lt; reflexivity
    | eapply I32Spec_le; reflexivity
    | eapply I32Spec_gt; reflexivity
    | eapply I32Spec_ge; reflexivity ].
Qed.

Lemma corest_and_spec_i32 :
  forall (env_s : corest_eval_env) (e1 e2 : corest_expr)
         (v1 v2 v : st_value) (n1 n2 : Z),
    corest_eval_expr env_s e1 = Some v1 ->
    corest_eval_expr env_s e2 = Some v2 ->
    corest_eval_expr env_s (CE_AND e1 e2) = Some v ->
    st_value_as_i32 v1 = Some n1 ->
    st_value_as_i32 v2 = Some n2 ->
    exists n : Z,
      st_value_as_i32 v = Some n /\
      i32_binop_spec I32_AND n1 n2 n.
Proof.
  intros env_s e1 e2 v1 v2 v n1 n2 He1 He2 Heval Hn1 Hn2.
  simpl in Heval.
  rewrite He1, He2 in Heval.
  destruct v1; simpl in Hn1; try discriminate;
    destruct v2; simpl in Hn2; try discriminate;
    simpl in Heval; try discriminate; inversion Heval; subst;
    inversion Hn1; subst; inversion Hn2; subst.
  all: try (destruct b; destruct b0; simpl).
  all: eexists; split; [reflexivity |].
  all: eapply I32Spec_and; reflexivity.
Qed.

Lemma corest_or_spec_i32 :
  forall (env_s : corest_eval_env) (e1 e2 : corest_expr)
         (v1 v2 v : st_value) (n1 n2 : Z),
    corest_eval_expr env_s e1 = Some v1 ->
    corest_eval_expr env_s e2 = Some v2 ->
    corest_eval_expr env_s (CE_OR e1 e2) = Some v ->
    st_value_as_i32 v1 = Some n1 ->
    st_value_as_i32 v2 = Some n2 ->
    exists n : Z,
      st_value_as_i32 v = Some n /\
      i32_binop_spec I32_OR n1 n2 n.
Proof.
  intros env_s e1 e2 v1 v2 v n1 n2 He1 He2 Heval Hn1 Hn2.
  simpl in Heval.
  rewrite He1, He2 in Heval.
  destruct v1; simpl in Hn1; try discriminate;
    destruct v2; simpl in Hn2; try discriminate;
    simpl in Heval; try discriminate; inversion Heval; subst;
    inversion Hn1; subst; inversion Hn2; subst.
  all: try (destruct b; destruct b0; simpl).
  all: eexists; split; [reflexivity |].
  all: eapply I32Spec_or; reflexivity.
Qed.

Lemma corest_xor_spec_i32 :
  forall (env_s : corest_eval_env) (e1 e2 : corest_expr)
         (v1 v2 v : st_value) (n1 n2 : Z),
    corest_eval_expr env_s e1 = Some v1 ->
    corest_eval_expr env_s e2 = Some v2 ->
    corest_eval_expr env_s (CE_XOR e1 e2) = Some v ->
    st_value_as_i32 v1 = Some n1 ->
    st_value_as_i32 v2 = Some n2 ->
    exists n : Z,
      st_value_as_i32 v = Some n /\
      i32_binop_spec I32_XOR n1 n2 n.
Proof.
  intros env_s e1 e2 v1 v2 v n1 n2 He1 He2 Heval Hn1 Hn2.
  simpl in Heval.
  rewrite He1, He2 in Heval.
  destruct v1; simpl in Hn1; try discriminate;
    destruct v2; simpl in Hn2; try discriminate;
    simpl in Heval; try discriminate; inversion Heval; subst;
    inversion Hn1; subst; inversion Hn2; subst.
  all: try (destruct b; destruct b0; simpl).
  all: eexists; split; [reflexivity |].
  all: eapply I32Spec_xor; reflexivity.
Qed.

Lemma corest_neg_spec_i32 :
  forall (env_s : corest_eval_env) (e1 : corest_expr)
         (v1 v : st_value) (n1 : Z),
    corest_eval_expr env_s e1 = Some v1 ->
    corest_eval_expr env_s (CE_UNARY_OP U_NEG e1) = Some v ->
    st_value_as_i32 v1 = Some n1 ->
    exists r : Z,
      st_value_as_i32 v = Some r /\
      i32_binop_spec I32_SUB 0 n1 r.
Proof.
  intros env_s e1 v1 v n1 He1 Heval Hn1.
  simpl in Heval.
  rewrite He1 in Heval.
  destruct v1; simpl in Hn1; try discriminate;
    simpl in Heval; try discriminate; inversion Heval; subst;
    inversion Hn1; subst.
  all: eexists; split; [reflexivity |].
  all: eapply I32Spec_sub; ring.
Qed.

Lemma corest_not_spec_i32 :
  forall (env_s : corest_eval_env) (e1 : corest_expr)
         (v1 v : st_value) (n1 : Z),
    corest_eval_expr env_s e1 = Some v1 ->
    corest_eval_expr env_s (CE_UNARY_OP U_NOT e1) = Some v ->
    st_value_as_i32 v1 = Some n1 ->
    exists r : Z,
      st_value_as_i32 v = Some r /\
      i32_unop_spec I32_EQZ n1 r.
Proof.
  intros env_s e1 v1 v n1 He1 Heval Hn1.
  simpl in Heval.
  rewrite He1 in Heval.
  destruct v1; simpl in Hn1; try discriminate;
    simpl in Heval; try discriminate; inversion Heval; subst;
    inversion Hn1; subst; destruct b.
  all: eexists; split; [reflexivity |].
  all: eapply I32Spec_eqz; reflexivity.
Qed.

Lemma compile_binop_pc_from_subs :
  forall (m : sasm_module) (fn : sasm_function) (f : sasm_frame)
         (fr : frame_stack) (vs : value_stack) (mem : list Z) (cyc : Z)
         (prefix c1 c2 : list sasm_instr) (op : sasm_instr)
         (suffix : list sasm_instr) (v1 v2 v : st_value) (n1 n2 r : Z),
    lookup_function m f.(frame_func_idx) = Some fn ->
    fn.(sasm_body) = (prefix ++ c1 ++ c2) ++ op :: suffix ->
    f.(frame_pc) = instrs_total_size prefix ->
    st_val_to_sasm_val v1 = V_I32 n1 ->
    st_val_to_sasm_val v2 = V_I32 n2 ->
    st_val_to_sasm_val v = V_I32 r ->
    i32_binop_spec op n1 n2 r ->
    (exists (s1 : runtime_state),
      multi_pc_step m
        {| rt_values := vs; rt_frames := f :: fr;
           rt_memory := mem; rt_cycle_cnt := cyc |}
        s1 /\
      expr_pc_post f fr vs mem c1 s1 v1) ->
    (forall (s1 : runtime_state),
      expr_pc_post f fr vs mem c1 s1 v1 ->
      exists (s2 : runtime_state),
        multi_pc_step m s1 s2 /\
      expr_pc_post
          (set_frame_pc f (f.(frame_pc) + instrs_total_size c1))
          fr (st_val_to_sasm_val v1 :: vs) mem c2 s2 v2) ->
    exists (s3 : runtime_state),
      multi_pc_step m
        {| rt_values := vs; rt_frames := f :: fr;
           rt_memory := mem; rt_cycle_cnt := cyc |}
        s3 /\
      expr_pc_post f fr vs mem (c1 ++ c2 ++ [op]) s3 v.
Proof.
  intros m fn f fr vs mem cyc prefix c1 c2 op suffix
    v1 v2 v n1 n2 r Hlook Hbody Hpc Hv1 Hv2 Hv Hspec
    Hrun1 Hrun2.
  destruct Hrun1 as [s1 [Hmulti1 [Hval1 [Hframes1 Hmem1]]]].
  set (f1 := set_frame_pc f (f.(frame_pc) + instrs_total_size c1)).
  assert (Hpost1 : expr_pc_post f fr vs mem c1 s1 v1).
  { unfold expr_pc_post.
    subst f1.
    repeat split; assumption. }
  destruct (Hrun2 s1 Hpost1) as [s2 [Hmulti2 [Hval2 [Hframes2 Hmem2]]]].
  set (f2 := set_frame_pc f1 (f1.(frame_pc) + instrs_total_size c2)).
  assert (Hframes2' : s2.(rt_frames) = f2 :: fr).
  { subst f2. exact Hframes2. }
  assert (Hpc2 : f2.(frame_pc) =
                   instrs_total_size ((prefix ++ c1) ++ c2)).
  { subst f2 f1.
    simpl.
    rewrite Hpc.
    repeat rewrite instrs_total_size_app.
    ring. }
  assert (Hbody2 :
    fn.(sasm_body) = ((prefix ++ c1) ++ c2) ++ op :: suffix).
  { rewrite Hbody.
    repeat rewrite app_assoc.
    reflexivity. }
  assert (Hfetch2 :
    fetch_frame_instr m f2 = Some (op, instrs_total_size ((prefix ++ c1) ++ c2) +
                                        instr_size op)).
  { apply fetch_frame_instr_app_exact with
      (fn := fn) (prefix := (prefix ++ c1) ++ c2)
      (i := op) (rest := suffix);
      [exact Hlook | exact Hbody2 | exact Hpc2]. }
  assert (Hvalues2 : s2.(rt_values) = V_I32 n2 :: V_I32 n1 :: vs).
  { rewrite <- Hv2, <- Hv1.
    exact Hval2. }
  set (next := f2.(frame_pc) + instr_size op).
  set (s3 := set_top_values_cycle s2 (set_frame_pc f2 next)
               (V_I32 r :: vs)).
  exists s3.
  split.
  - eapply multi_pc_step_trans.
    + exact Hmulti1.
    + eapply multi_pc_step_trans.
      * exact Hmulti2.
      * subst s3 next.
        assert (Hfetch2' :
          fetch_frame_instr m f2 =
          Some (op, f2.(frame_pc) + instr_size op)).
        { rewrite Hpc2. exact Hfetch2. }
        exact (pc_i32_binop_spec_multi m s2 f2 fr op n1 n2 r vs
                 (f2.(frame_pc) + instr_size op)
                 Hframes2' Hfetch2' Hvalues2 Hspec).
  - unfold expr_pc_post.
    split.
    + subst s3. unfold set_top_values_cycle. rewrite Hframes2'.
      rewrite Hv. reflexivity.
    + split.
      * subst s3 next f2.
        unfold set_top_values_cycle.
        rewrite Hframes2'.
        simpl.
        replace
          (set_frame_pc
             (set_frame_pc f (f.(frame_pc) + instrs_total_size c1))
             (f.(frame_pc) + instrs_total_size c1 +
              instrs_total_size c2 + instr_size op) :: fr)
          with
          (set_frame_pc f
             (f.(frame_pc) + instrs_total_size c1 +
              instrs_total_size c2 + instr_size op) :: fr)
          by (rewrite set_frame_pc_set_frame_pc; reflexivity).
        replace (f.(frame_pc) + instrs_total_size c1 +
                 instrs_total_size c2 + instr_size op)
          with (f.(frame_pc) + instrs_total_size (c1 ++ c2 ++ [op]))
          by (rewrite instrs_total_size_append_singleton; lia).
        reflexivity.
      * subst s3. unfold set_top_values_cycle. rewrite Hframes2'. exact Hmem2.
Qed.

Lemma compile_unop_pc_from_sub :
  forall (m : sasm_module) (fn : sasm_function) (f : sasm_frame)
         (fr : frame_stack) (input : value_stack) (mem : list Z) (cyc : Z)
         (prefix code : list sasm_instr) (opcode : sasm_instr)
         (suffix : list sasm_instr) (v1 v : st_value) (n1 r : Z),
    lookup_function m f.(frame_func_idx) = Some fn ->
    fn.(sasm_body) = prefix ++ code ++ [opcode] ++ suffix ->
    f.(frame_pc) = instrs_total_size prefix ->
    st_val_to_sasm_val v1 = V_I32 n1 ->
    st_val_to_sasm_val v = V_I32 r ->
    i32_unop_spec opcode n1 r ->
    (exists (s1 : runtime_state),
      multi_pc_step m
        {| rt_values := input; rt_frames := f :: fr;
           rt_memory := mem; rt_cycle_cnt := cyc |}
        s1 /\
      expr_pc_post f fr input mem code s1 v1) ->
    exists (s2 : runtime_state),
      multi_pc_step m
        {| rt_values := input; rt_frames := f :: fr;
           rt_memory := mem; rt_cycle_cnt := cyc |}
        s2 /\
      expr_pc_post f fr input mem (code ++ [opcode]) s2 v.
Proof.
  intros m fn f fr input mem cyc prefix code opcode suffix
    v1 v n1 r Hlook Hbody Hpc Hsv1 Hsv Hspec Hrun.
  destruct Hrun as [s1 [Hmulti1 [Hval1 [Hframes1 Hmem1]]]].
  set (f1 := set_frame_pc f (f.(frame_pc) + instrs_total_size code)).
  assert (Hframes1' : s1.(rt_frames) = f1 :: fr).
  { subst f1. exact Hframes1. }
  assert (Hpc1 : f1.(frame_pc) = instrs_total_size (prefix ++ code)).
  { subst f1.
    simpl.
    rewrite Hpc.
    rewrite instrs_total_size_app.
    reflexivity. }
  assert (Hbody' :
    fn.(sasm_body) = (prefix ++ code) ++ opcode :: suffix).
  { rewrite Hbody.
    repeat rewrite app_assoc.
    rewrite app_singleton_cons.
    reflexivity. }
  assert (Hfetch :
    fetch_frame_instr m f1 =
    Some (opcode, instrs_total_size (prefix ++ code) + instr_size opcode)).
  { apply fetch_frame_instr_app_exact with
      (fn := fn) (prefix := prefix ++ code) (i := opcode) (rest := suffix);
      [exact Hlook | exact Hbody' | exact Hpc1]. }
  assert (Hvalues1 : s1.(rt_values) = V_I32 n1 :: input).
  { rewrite <- Hsv1. exact Hval1. }
  set (next := f1.(frame_pc) + instr_size opcode).
  set (s2 := set_top_values_cycle s1 (set_frame_pc f1 next)
               (V_I32 r :: input)).
  exists s2.
  split.
  - eapply multi_pc_step_trans.
    + exact Hmulti1.
    + subst s2 next.
      assert (Hfetch' :
        fetch_frame_instr m f1 =
        Some (opcode, f1.(frame_pc) + instr_size opcode)).
      { rewrite Hpc1. exact Hfetch. }
      exact (pc_i32_unop_spec_multi m s1 f1 fr opcode n1 r input
               (f1.(frame_pc) + instr_size opcode)
               Hframes1' Hfetch' Hvalues1 Hspec).
  - unfold expr_pc_post.
    split.
    + subst s2. unfold set_top_values_cycle. rewrite Hframes1'.
      rewrite Hsv. reflexivity.
    + split.
      * subst s2 next f1.
        unfold set_top_values_cycle.
        rewrite Hframes1'.
        simpl.
        replace (f.(frame_pc) + instrs_total_size code + instr_size opcode)
          with (f.(frame_pc) + instrs_total_size (code ++ [opcode]))
          by (rewrite instrs_total_size_app, instrs_total_size_singleton; ring).
        reflexivity.
      * subst s2. unfold set_top_values_cycle. rewrite Hframes1'. exact Hmem1.
Qed.

Lemma pc_local_set_after_expr :
  forall (m : sasm_module) (fn : sasm_function) (f : sasm_frame)
         (fr : frame_stack) (input : value_stack) (mem : list Z) (cyc : Z)
         (prefix code suffix : list sasm_instr) (idx : Z)
         (v : st_value) (n : Z),
    lookup_function m f.(frame_func_idx) = Some fn ->
    fn.(sasm_body) = prefix ++ code ++ [LOCAL_SET idx] ++ suffix ->
    f.(frame_pc) = instrs_total_size prefix ->
    st_value_as_i32 v = Some n ->
    (exists (s1 : runtime_state),
      multi_pc_step m
        {| rt_values := input; rt_frames := f :: fr;
           rt_memory := mem; rt_cycle_cnt := cyc |}
        s1 /\
      expr_pc_post f fr input mem code s1 v) ->
    exists (s2 : runtime_state),
      multi_pc_step m
        {| rt_values := input; rt_frames := f :: fr;
           rt_memory := mem; rt_cycle_cnt := cyc |}
        s2 /\
      s2.(rt_values) = input /\
      s2.(rt_frames) =
        {| frame_locals := list_set f.(frame_locals) (Z.to_nat idx) (V_I32 n);
           frame_func_idx := f.(frame_func_idx);
           frame_pc := f.(frame_pc) + instrs_total_size code + instr_size (LOCAL_SET idx);
           frame_block_stack := f.(frame_block_stack) |} :: fr /\
      s2.(rt_memory) = mem.
Proof.
  intros m fn f fr input mem cyc prefix code suffix idx v n
    Hlook Hbody Hpc Hvn Hrun.
  destruct Hrun as [s1 [Hmulti1 [Hval1 [Hframes1 Hmem1]]]].
  pose proof (st_value_as_i32_sound v n Hvn) as Hsv.
  set (f1 := set_frame_pc f (f.(frame_pc) + instrs_total_size code)).
  assert (Hframes1' : s1.(rt_frames) = f1 :: fr).
  { subst f1. exact Hframes1. }
  assert (Hpc1 : f1.(frame_pc) = instrs_total_size (prefix ++ code)).
  { subst f1. simpl. rewrite Hpc. rewrite instrs_total_size_app. reflexivity. }
  assert (Hbody' :
    fn.(sasm_body) = (prefix ++ code) ++ LOCAL_SET idx :: suffix).
  { rewrite Hbody.
    repeat rewrite app_assoc.
    rewrite app_singleton_cons.
    reflexivity. }
  assert (Hfetch :
    fetch_frame_instr m f1 =
      Some (LOCAL_SET idx,
            instrs_total_size (prefix ++ code) + instr_size (LOCAL_SET idx))).
  { apply fetch_frame_instr_app_exact with
      (fn := fn) (prefix := prefix ++ code)
      (i := LOCAL_SET idx) (rest := suffix);
      [exact Hlook | exact Hbody' | exact Hpc1]. }
  assert (Hvalues1 : s1.(rt_values) = V_I32 n :: input).
  { rewrite <- Hsv. exact Hval1. }
  set (next := f1.(frame_pc) + instr_size (LOCAL_SET idx)).
  set (updated :=
    {| frame_locals := list_set f.(frame_locals) (Z.to_nat idx) (V_I32 n);
       frame_func_idx := f.(frame_func_idx);
       frame_pc := f.(frame_pc) + instrs_total_size code +
                   instr_size (LOCAL_SET idx);
       frame_block_stack := f.(frame_block_stack) |}).
  exists (set_top_values_cycle s1 updated input).
  split.
  - eapply multi_pc_step_trans.
    + exact Hmulti1.
    + subst next updated.
      assert (Hfetch' :
        fetch_frame_instr m f1 =
          Some (LOCAL_SET idx, f1.(frame_pc) + instr_size (LOCAL_SET idx))).
      { rewrite Hpc1. exact Hfetch. }
      exact (pc_i32_local_set_multi m s1 f1 fr idx
               (f1.(frame_pc) + instr_size (LOCAL_SET idx))
               (V_I32 n) input Hframes1' Hfetch' Hvalues1).
  - subst updated.
    unfold set_top_values_cycle.
    rewrite Hframes1'.
    simpl.
    split; [reflexivity |].
    split.
    + replace (f1.(frame_pc) + instr_size (LOCAL_SET idx))
        with (f.(frame_pc) + instrs_total_size code +
              instr_size (LOCAL_SET idx)) by (subst f1; simpl; lia).
      reflexivity.
    + exact Hmem1.
Qed.

Lemma compile_binop_expr_correct_pc :
  forall (m : sasm_module) (fn : sasm_function) (f : sasm_frame)
         (fr : frame_stack) (env : compile_env) (env_s : corest_eval_env)
         (op : binary_op) (e1 e2 : corest_expr)
         (v1 v2 v : st_value) (n1 n2 : Z)
         (vs : value_stack) (mem : list Z) (cyc : Z)
         (prefix suffix : list sasm_instr),
    lookup_function m f.(frame_func_idx) = Some fn ->
    fn.(sasm_body) =
      prefix ++ compile_expr env (CE_BIN_OP op e1 e2) ++ suffix ->
    f.(frame_pc) = instrs_total_size prefix ->
    st_value_as_i32 v1 = Some n1 ->
    st_value_as_i32 v2 = Some n2 ->
    corest_eval_expr env_s e1 = Some v1 ->
    corest_eval_expr env_s e2 = Some v2 ->
    corest_eval_expr env_s (CE_BIN_OP op e1 e2) = Some v ->
    pc_expr_safe env_s (CE_BIN_OP op e1 e2) ->
    (exists (s1 : runtime_state),
      multi_pc_step m
        {| rt_values := vs; rt_frames := f :: fr;
           rt_memory := mem; rt_cycle_cnt := cyc |}
        s1 /\
      expr_pc_post f fr vs mem (compile_expr env e1) s1 v1) ->
    (forall (s1 : runtime_state),
      expr_pc_post f fr vs mem (compile_expr env e1) s1 v1 ->
      exists (s2 : runtime_state),
        multi_pc_step m s1 s2 /\
        expr_pc_post
          (set_frame_pc f
             (f.(frame_pc) + instrs_total_size (compile_expr env e1)))
          fr (st_val_to_sasm_val v1 :: vs) mem
          (compile_expr env e2) s2 v2) ->
    exists (s3 : runtime_state) (n : Z),
      multi_pc_step m
        {| rt_values := vs; rt_frames := f :: fr;
           rt_memory := mem; rt_cycle_cnt := cyc |}
        s3 /\
      expr_pc_post f fr vs mem
        (compile_expr env e1 ++ compile_expr env e2 ++
         [binop_i32_instr op]) s3 v /\
      st_value_as_i32 v = Some n.
Proof.
  intros m fn f fr env env_s op e1 e2 v1 v2 v n1 n2
    vs mem cyc prefix suffix Hlook Hbody Hpc Hn1 Hn2
    He1 He2 Heval Hsafe Hrun1 Hrun2.
  destruct (corest_binop_spec_i32 env_s op e1 e2 v1 v2 v n1 n2
              He1 He2 Heval Hn1 Hn2 Hsafe) as [n [Hvn Hspec]].
  pose proof (compile_expr_binop_shape env op e1 e2) as Hshape.
  assert (Hbody' :
    fn.(sasm_body) =
    (prefix ++ compile_expr env e1 ++ compile_expr env e2) ++
    binop_i32_instr op :: suffix).
  { rewrite Hshape in Hbody.
    rewrite Hbody.
    repeat rewrite app_assoc.
    rewrite app_singleton_cons.
    reflexivity. }
  pose proof (st_value_as_i32_sound v1 n1 Hn1) as Hsv1.
  pose proof (st_value_as_i32_sound v2 n2 Hn2) as Hsv2.
  pose proof (st_value_as_i32_sound v n Hvn) as Hsv.
  destruct (compile_binop_pc_from_subs m fn f fr vs mem cyc prefix
              (compile_expr env e1) (compile_expr env e2)
              (binop_i32_instr op) suffix v1 v2 v n1 n2 n
              Hlook Hbody' Hpc Hsv1 Hsv2 Hsv Hspec Hrun1 Hrun2)
    as [s3 [Hmulti Hpost]].
  exists s3, n.
  split; [exact Hmulti | split; [exact Hpost | exact Hvn]].
Qed.

Lemma compile_binary_expr_correct_pc_generic :
  forall (m : sasm_module) (fn : sasm_function) (f : sasm_frame)
         (fr : frame_stack) (c1 c2 : list sasm_instr)
         (opcode : sasm_instr) (v1 v2 v : st_value)
         (n1 n2 n : Z) (vs : value_stack) (mem : list Z) (cyc : Z)
         (prefix suffix : list sasm_instr),
    lookup_function m f.(frame_func_idx) = Some fn ->
    fn.(sasm_body) =
      (prefix ++ c1 ++ c2) ++ opcode :: suffix ->
    f.(frame_pc) = instrs_total_size prefix ->
    st_val_to_sasm_val v1 = V_I32 n1 ->
    st_val_to_sasm_val v2 = V_I32 n2 ->
    st_value_as_i32 v = Some n ->
    i32_binop_spec opcode n1 n2 n ->
    (exists (s1 : runtime_state),
      multi_pc_step m
        {| rt_values := vs; rt_frames := f :: fr;
           rt_memory := mem; rt_cycle_cnt := cyc |}
        s1 /\
      expr_pc_post f fr vs mem c1 s1 v1) ->
    (forall (s1 : runtime_state),
      expr_pc_post f fr vs mem c1 s1 v1 ->
      exists (s2 : runtime_state),
        multi_pc_step m s1 s2 /\
        expr_pc_post
          (set_frame_pc f (f.(frame_pc) + instrs_total_size c1))
          fr (st_val_to_sasm_val v1 :: vs) mem c2 s2 v2) ->
    exists (s3 : runtime_state),
      multi_pc_step m
        {| rt_values := vs; rt_frames := f :: fr;
           rt_memory := mem; rt_cycle_cnt := cyc |}
        s3 /\
      expr_pc_post f fr vs mem (c1 ++ c2 ++ [opcode]) s3 v /\
      st_value_as_i32 v = Some n.
Proof.
  intros m fn f fr c1 c2 opcode v1 v2 v n1 n2 n
    vs mem cyc prefix suffix Hlook Hbody Hpc Hv1 Hv2 Hvn Hspec Hrun1 Hrun2.
  pose proof (st_value_as_i32_sound v n Hvn) as Hv.
  destruct (compile_binop_pc_from_subs m fn f fr vs mem cyc prefix
              c1 c2 opcode suffix v1 v2 v n1 n2 n
              Hlook Hbody Hpc Hv1 Hv2 Hv Hspec Hrun1 Hrun2)
    as [s3 [Hmulti Hpost]].
  exists s3.
  split; [exact Hmulti |].
  split; [exact Hpost |].
  exact Hvn.
Qed.

Lemma binary_subruns_from_ih :
  forall (env : compile_env) (env_s : corest_eval_env)
         (e1 e2 : corest_expr) (v1 v2 : st_value)
         (c1 c2 : list sasm_instr),
    expr_pc_property env env_s e1 v1 c1 ->
    expr_pc_property env env_s e2 v2 c2 ->
    forall (m : sasm_module) (fn : sasm_function) (f : sasm_frame)
           (fr : frame_stack) (input : value_stack) (mem : list Z)
           (cyc : Z) (prefix suffix : list sasm_instr),
      lookup_function m f.(frame_func_idx) = Some fn ->
      fn.(sasm_body) = (prefix ++ c1 ++ c2) ++ suffix ->
      f.(frame_pc) = instrs_total_size prefix ->
      pc_frame_env_matches env env_s f ->
      pc_expr_safe env_s e1 ->
      pc_expr_safe env_s e2 ->
      corest_eval_expr env_s e1 = Some v1 ->
      corest_eval_expr env_s e2 = Some v2 ->
      exists (s1 : runtime_state) (n1 : Z),
        multi_pc_step m
          {| rt_values := input; rt_frames := f :: fr;
             rt_memory := mem; rt_cycle_cnt := cyc |}
          s1 /\
        expr_pc_post f fr input mem c1 s1 v1 /\
        st_value_as_i32 v1 = Some n1 /\
        (forall (s1' : runtime_state),
          expr_pc_post f fr input mem c1 s1' v1 ->
          exists (s2 : runtime_state) (n2 : Z),
            multi_pc_step m s1' s2 /\
            expr_pc_post
              (set_frame_pc f (f.(frame_pc) + instrs_total_size c1))
              fr (st_val_to_sasm_val v1 :: input) mem c2 s2 v2 /\
            st_value_as_i32 v2 = Some n2).
Proof.
  intros env env_s e1 e2 v1 v2 c1 c2 HIH1 HIH2
    m fn f fr input mem cyc prefix suffix
    Hlook Hbody Hpc Henv Hsafe1 Hsafe2 He1 He2.
  assert (Hbody1 :
    fn.(sasm_body) = prefix ++ c1 ++ c2 ++ suffix).
  { rewrite Hbody. repeat rewrite app_assoc. reflexivity. }
  destruct (HIH1 m fn f fr input mem cyc prefix (c2 ++ suffix)
              Hlook Hbody1 Hpc Henv Hsafe1 He1)
    as [s1 [n1 [Hmulti1 [Hpost1 Hn1]]]].
  exists s1, n1.
  split; [exact Hmulti1 |].
  split; [exact Hpost1 |].
  split; [exact Hn1 |].
  intros s1' Hpost1'.
  destruct Hpost1' as [Hval1 [Hframes1 Hmem1]].
  set (f1 := set_frame_pc f (f.(frame_pc) + instrs_total_size c1)).
  assert (Hframes1' : s1'.(rt_frames) = f1 :: fr).
  { subst f1. exact Hframes1. }
  assert (Hpc1 : f1.(frame_pc) = instrs_total_size (prefix ++ c1)).
  { subst f1.
    simpl.
    rewrite Hpc.
    rewrite instrs_total_size_app.
    reflexivity. }
  assert (Hbody2 :
    fn.(sasm_body) = (prefix ++ c1) ++ c2 ++ suffix).
  { rewrite Hbody. repeat rewrite app_assoc. reflexivity. }
  assert (Hs1 :
    s1' = {| rt_values := st_val_to_sasm_val v1 :: input;
              rt_frames := f1 :: fr;
              rt_memory := s1'.(rt_memory);
              rt_cycle_cnt := s1'.(rt_cycle_cnt) |}).
  { destruct s1' as [vals frames memory cycles].
    simpl in Hval1, Hframes1.
    subst vals.
    subst frames.
    reflexivity. }
  destruct (HIH2 m fn f1 fr (st_val_to_sasm_val v1 :: input)
              s1'.(rt_memory) s1'.(rt_cycle_cnt)
              (prefix ++ c1) suffix Hlook Hbody2 Hpc1 Henv
              Hsafe2 He2)
    as [s2 [n2 [Hmulti2 [Hpost2 Hn2]]]].
  rewrite <- Hs1 in Hmulti2.
  rewrite Hmem1 in Hpost2.
  exists s2, n2.
  split; [exact Hmulti2 |].
  split; [exact Hpost2 | exact Hn2].
Qed.

Lemma binop_expr_property_from_ih :
  forall (env : compile_env) (env_s : corest_eval_env)
         (op : binary_op) (e1 e2 : corest_expr) (v : st_value),
    (forall (v1 : st_value),
      corest_eval_expr env_s e1 = Some v1 ->
      expr_pc_property env env_s e1 v1 (compile_expr env e1)) ->
    (forall (v2 : st_value),
      corest_eval_expr env_s e2 = Some v2 ->
      expr_pc_property env env_s e2 v2 (compile_expr env e2)) ->
    expr_pc_property env env_s (CE_BIN_OP op e1 e2) v
      (compile_expr env (CE_BIN_OP op e1 e2)).
Proof.
  intros env env_s op e1 e2 v HIH1 HIH2.
  unfold expr_pc_property.
  intros m fn f fr input mem cyc prefix suffix
    Hlook Hbody Hpc Henv Hsafe_whole.
  intro Heval.
  destruct (binop_eval_witnesses env_s op e1 e2 v Heval)
    as [v1 [v2 [He1 He2]]].
  pose proof (HIH1 v1 He1) as Hprop1.
  pose proof (HIH2 v2 He2) as Hprop2.
  destruct (pc_expr_safe_binop_parts env_s op e1 e2 Hsafe_whole)
    as [Hsafe1 Hsafe2].
  pose proof (compile_expr_binop_shape env op e1 e2) as Hshape.
  assert (Hbody_sub :
    fn.(sasm_body) =
    (prefix ++ compile_expr env e1 ++ compile_expr env e2) ++
    binop_i32_instr op :: suffix).
  { rewrite Hshape in Hbody.
    rewrite Hbody.
    repeat rewrite app_assoc.
    rewrite app_singleton_cons.
    reflexivity. }
  destruct (binary_subruns_from_ih env env_s e1 e2 v1 v2
              (compile_expr env e1) (compile_expr env e2)
              Hprop1 Hprop2 m fn f fr input mem cyc prefix
              (binop_i32_instr op :: suffix)
              Hlook Hbody_sub Hpc Henv Hsafe1 Hsafe2 He1 He2)
    as [s1 [n1 [Hmulti1 [Hpost1 [Hn1 Hrun2]]]]].
  destruct (Hrun2 s1 Hpost1) as [s2 [n2 [Hmulti2 [Hpost2 Hn2]]]].
  destruct (corest_binop_spec_i32 env_s op e1 e2 v1 v2 v n1 n2
              He1 He2 Heval Hn1 Hn2 Hsafe_whole) as [n [Hvn Hspec]].
  pose proof (st_value_as_i32_sound v1 n1 Hn1) as Hsv1.
  pose proof (st_value_as_i32_sound v2 n2 Hn2) as Hsv2.
  destruct (compile_binary_expr_correct_pc_generic m fn f fr
              (compile_expr env e1) (compile_expr env e2)
              (binop_i32_instr op) v1 v2 v n1 n2 n input mem cyc
              prefix suffix Hlook Hbody_sub Hpc Hsv1 Hsv2
              Hvn Hspec
              (ex_intro _ s1 (conj Hmulti1 Hpost1))
              (fun s1' Hs1' =>
                 exists_snd_drop_component runtime_state
                   (fun s2' => multi_pc_step m s1' s2')
                   (fun s2' =>
                     expr_pc_post
                       (set_frame_pc f
                          (f.(frame_pc) +
                           instrs_total_size (compile_expr env e1)))
                       fr (st_val_to_sasm_val v1 :: input) mem
                       (compile_expr env e2) s2' v2)
                   (fun n2' => st_value_as_i32 v2 = Some n2')
                   (Hrun2 s1' Hs1')))
    as [s3 [Hmulti3 [Hpost3 Hn3]]].
  rewrite <- Hshape in Hpost3.
  exists s3, n.
  split; [exact Hmulti3 | split; [exact Hpost3 | exact Hvn]].
Qed.

Lemma compare_expr_property_from_ih :
  forall (env : compile_env) (env_s : corest_eval_env)
         (op : compare_op) (e1 e2 : corest_expr) (v : st_value),
    (forall (v1 : st_value),
      corest_eval_expr env_s e1 = Some v1 ->
      expr_pc_property env env_s e1 v1 (compile_expr env e1)) ->
    (forall (v2 : st_value),
      corest_eval_expr env_s e2 = Some v2 ->
      expr_pc_property env env_s e2 v2 (compile_expr env e2)) ->
    expr_pc_property env env_s (CE_COMP op e1 e2) v
      (compile_expr env (CE_COMP op e1 e2)).
Proof.
  intros env env_s op e1 e2 v HIH1 HIH2.
  unfold expr_pc_property.
  intros m fn f fr input mem cyc prefix suffix
    Hlook Hbody Hpc Henv Hsafe_whole.
  intro Heval.
  destruct (compare_eval_witnesses env_s op e1 e2 v Heval)
    as [v1 [v2 [He1 He2]]].
  pose proof (HIH1 v1 He1) as Hprop1.
  pose proof (HIH2 v2 He2) as Hprop2.
  destruct (pc_expr_safe_compare_parts env_s op e1 e2 Hsafe_whole)
    as [Hsafe1 Hsafe2].
  pose proof (compile_expr_compare_shape env op e1 e2) as Hshape.
  assert (Hbody_sub :
    fn.(sasm_body) =
    (prefix ++ compile_expr env e1 ++ compile_expr env e2) ++
    compare_i32_instr op :: suffix).
  { rewrite Hshape in Hbody.
    rewrite Hbody.
    repeat rewrite app_assoc.
    rewrite app_singleton_cons.
    reflexivity. }
  destruct (binary_subruns_from_ih env env_s e1 e2 v1 v2
              (compile_expr env e1) (compile_expr env e2)
              Hprop1 Hprop2 m fn f fr input mem cyc prefix
              (compare_i32_instr op :: suffix)
              Hlook Hbody_sub Hpc Henv Hsafe1 Hsafe2 He1 He2)
    as [s1 [n1 [Hmulti1 [Hpost1 [Hn1 Hrun2]]]]].
  destruct (Hrun2 s1 Hpost1) as [s2 [n2 [Hmulti2 [Hpost2 Hn2]]]].
  destruct (corest_compare_spec_i32 env_s op e1 e2 v1 v2 v n1 n2
              He1 He2 Heval Hn1 Hn2) as [n [Hvn Hspec]].
  pose proof (st_value_as_i32_sound v1 n1 Hn1) as Hsv1.
  pose proof (st_value_as_i32_sound v2 n2 Hn2) as Hsv2.
  destruct (compile_binary_expr_correct_pc_generic m fn f fr
              (compile_expr env e1) (compile_expr env e2)
              (compare_i32_instr op) v1 v2 v n1 n2 n input mem cyc
              prefix suffix Hlook Hbody_sub Hpc Hsv1 Hsv2
              Hvn Hspec
              (ex_intro _ s1 (conj Hmulti1 Hpost1))
              (fun s1' Hs1' =>
                 exists_snd_drop_component runtime_state
                   (fun s2' => multi_pc_step m s1' s2')
                   (fun s2' =>
                     expr_pc_post
                       (set_frame_pc f
                          (f.(frame_pc) +
                           instrs_total_size (compile_expr env e1)))
                       fr (st_val_to_sasm_val v1 :: input) mem
                       (compile_expr env e2) s2' v2)
                   (fun n2' => st_value_as_i32 v2 = Some n2')
                   (Hrun2 s1' Hs1')))
    as [s3 [Hmulti3 [Hpost3 Hn3]]].
  rewrite <- Hshape in Hpost3.
  exists s3, n.
  split; [exact Hmulti3 | split; [exact Hpost3 | exact Hvn]].
Qed.

Lemma and_expr_property_from_ih :
  forall (env : compile_env) (env_s : corest_eval_env)
         (e1 e2 : corest_expr) (v : st_value),
    (forall (v1 : st_value),
      corest_eval_expr env_s e1 = Some v1 ->
      expr_pc_property env env_s e1 v1 (compile_expr env e1)) ->
    (forall (v2 : st_value),
      corest_eval_expr env_s e2 = Some v2 ->
      expr_pc_property env env_s e2 v2 (compile_expr env e2)) ->
    expr_pc_property env env_s (CE_AND e1 e2) v
      (compile_expr env (CE_AND e1 e2)).
Proof.
  intros env env_s e1 e2 v HIH1 HIH2.
  unfold expr_pc_property.
  intros m fn f fr input mem cyc prefix suffix
    Hlook Hbody Hpc Henv Hsafe_whole.
  intro Heval.
  destruct (and_eval_witnesses env_s e1 e2 v Heval)
    as [v1 [v2 [He1 He2]]].
  pose proof (HIH1 v1 He1) as Hprop1.
  pose proof (HIH2 v2 He2) as Hprop2.
  destruct (pc_expr_safe_and_parts env_s e1 e2 Hsafe_whole)
    as [Hsafe1 Hsafe2].
  pose proof (compile_expr_and_shape env e1 e2) as Hshape.
  assert (Hbody_sub :
    fn.(sasm_body) =
    (prefix ++ compile_expr env e1 ++ compile_expr env e2) ++
    I32_AND :: suffix).
  { rewrite Hshape in Hbody.
    rewrite Hbody.
    repeat rewrite app_assoc.
    rewrite app_singleton_cons.
    reflexivity. }
  destruct (binary_subruns_from_ih env env_s e1 e2 v1 v2
              (compile_expr env e1) (compile_expr env e2)
              Hprop1 Hprop2 m fn f fr input mem cyc prefix
              (I32_AND :: suffix)
              Hlook Hbody_sub Hpc Henv Hsafe1 Hsafe2 He1 He2)
    as [s1 [n1 [Hmulti1 [Hpost1 [Hn1 Hrun2]]]]].
  destruct (Hrun2 s1 Hpost1) as [s2 [n2 [Hmulti2 [Hpost2 Hn2]]]].
  destruct (corest_and_spec_i32 env_s e1 e2 v1 v2 v n1 n2
              He1 He2 Heval Hn1 Hn2) as [n [Hvn Hspec]].
  pose proof (st_value_as_i32_sound v1 n1 Hn1) as Hsv1.
  pose proof (st_value_as_i32_sound v2 n2 Hn2) as Hsv2.
  destruct (compile_binary_expr_correct_pc_generic m fn f fr
              (compile_expr env e1) (compile_expr env e2)
              I32_AND v1 v2 v n1 n2 n input mem cyc
              prefix suffix Hlook Hbody_sub Hpc Hsv1 Hsv2
              Hvn Hspec
              (ex_intro _ s1 (conj Hmulti1 Hpost1))
              (fun s1' Hs1' =>
                 exists_snd_drop_component runtime_state
                   (fun s2' => multi_pc_step m s1' s2')
                   (fun s2' =>
                     expr_pc_post
                       (set_frame_pc f
                          (f.(frame_pc) +
                           instrs_total_size (compile_expr env e1)))
                       fr (st_val_to_sasm_val v1 :: input) mem
                       (compile_expr env e2) s2' v2)
                   (fun n2' => st_value_as_i32 v2 = Some n2')
                   (Hrun2 s1' Hs1')))
    as [s3 [Hmulti3 [Hpost3 Hn3]]].
  rewrite <- Hshape in Hpost3.
  exists s3, n.
  split; [exact Hmulti3 | split; [exact Hpost3 | exact Hvn]].
Qed.

Lemma or_expr_property_from_ih :
  forall (env : compile_env) (env_s : corest_eval_env)
         (e1 e2 : corest_expr) (v : st_value),
    (forall (v1 : st_value),
      corest_eval_expr env_s e1 = Some v1 ->
      expr_pc_property env env_s e1 v1 (compile_expr env e1)) ->
    (forall (v2 : st_value),
      corest_eval_expr env_s e2 = Some v2 ->
      expr_pc_property env env_s e2 v2 (compile_expr env e2)) ->
    expr_pc_property env env_s (CE_OR e1 e2) v
      (compile_expr env (CE_OR e1 e2)).
Proof.
  intros env env_s e1 e2 v HIH1 HIH2.
  unfold expr_pc_property.
  intros m fn f fr input mem cyc prefix suffix
    Hlook Hbody Hpc Henv Hsafe_whole.
  intro Heval.
  destruct (or_eval_witnesses env_s e1 e2 v Heval)
    as [v1 [v2 [He1 He2]]].
  pose proof (HIH1 v1 He1) as Hprop1.
  pose proof (HIH2 v2 He2) as Hprop2.
  destruct (pc_expr_safe_or_parts env_s e1 e2 Hsafe_whole)
    as [Hsafe1 Hsafe2].
  pose proof (compile_expr_or_shape env e1 e2) as Hshape.
  assert (Hbody_sub :
    fn.(sasm_body) =
    (prefix ++ compile_expr env e1 ++ compile_expr env e2) ++
    I32_OR :: suffix).
  { rewrite Hshape in Hbody.
    rewrite Hbody.
    repeat rewrite app_assoc.
    rewrite app_singleton_cons.
    reflexivity. }
  destruct (binary_subruns_from_ih env env_s e1 e2 v1 v2
              (compile_expr env e1) (compile_expr env e2)
              Hprop1 Hprop2 m fn f fr input mem cyc prefix
              (I32_OR :: suffix)
              Hlook Hbody_sub Hpc Henv Hsafe1 Hsafe2 He1 He2)
    as [s1 [n1 [Hmulti1 [Hpost1 [Hn1 Hrun2]]]]].
  destruct (Hrun2 s1 Hpost1) as [s2 [n2 [Hmulti2 [Hpost2 Hn2]]]].
  destruct (corest_or_spec_i32 env_s e1 e2 v1 v2 v n1 n2
              He1 He2 Heval Hn1 Hn2) as [n [Hvn Hspec]].
  pose proof (st_value_as_i32_sound v1 n1 Hn1) as Hsv1.
  pose proof (st_value_as_i32_sound v2 n2 Hn2) as Hsv2.
  destruct (compile_binary_expr_correct_pc_generic m fn f fr
              (compile_expr env e1) (compile_expr env e2)
              I32_OR v1 v2 v n1 n2 n input mem cyc
              prefix suffix Hlook Hbody_sub Hpc Hsv1 Hsv2
              Hvn Hspec
              (ex_intro _ s1 (conj Hmulti1 Hpost1))
              (fun s1' Hs1' =>
                 exists_snd_drop_component runtime_state
                   (fun s2' => multi_pc_step m s1' s2')
                   (fun s2' =>
                     expr_pc_post
                       (set_frame_pc f
                          (f.(frame_pc) +
                           instrs_total_size (compile_expr env e1)))
                       fr (st_val_to_sasm_val v1 :: input) mem
                       (compile_expr env e2) s2' v2)
                   (fun n2' => st_value_as_i32 v2 = Some n2')
                   (Hrun2 s1' Hs1')))
    as [s3 [Hmulti3 [Hpost3 Hn3]]].
  rewrite <- Hshape in Hpost3.
  exists s3, n.
  split; [exact Hmulti3 | split; [exact Hpost3 | exact Hvn]].
Qed.

Lemma xor_expr_property_from_ih :
  forall (env : compile_env) (env_s : corest_eval_env)
         (e1 e2 : corest_expr) (v : st_value),
    (forall (v1 : st_value),
      corest_eval_expr env_s e1 = Some v1 ->
      expr_pc_property env env_s e1 v1 (compile_expr env e1)) ->
    (forall (v2 : st_value),
      corest_eval_expr env_s e2 = Some v2 ->
      expr_pc_property env env_s e2 v2 (compile_expr env e2)) ->
    expr_pc_property env env_s (CE_XOR e1 e2) v
      (compile_expr env (CE_XOR e1 e2)).
Proof.
  intros env env_s e1 e2 v HIH1 HIH2.
  unfold expr_pc_property.
  intros m fn f fr input mem cyc prefix suffix
    Hlook Hbody Hpc Henv Hsafe_whole.
  intro Heval.
  destruct (xor_eval_witnesses env_s e1 e2 v Heval)
    as [v1 [v2 [He1 He2]]].
  pose proof (HIH1 v1 He1) as Hprop1.
  pose proof (HIH2 v2 He2) as Hprop2.
  destruct (pc_expr_safe_xor_parts env_s e1 e2 Hsafe_whole)
    as [Hsafe1 Hsafe2].
  pose proof (compile_expr_xor_shape env e1 e2) as Hshape.
  assert (Hbody_sub :
    fn.(sasm_body) =
    (prefix ++ compile_expr env e1 ++ compile_expr env e2) ++
    I32_XOR :: suffix).
  { rewrite Hshape in Hbody.
    rewrite Hbody.
    repeat rewrite app_assoc.
    rewrite app_singleton_cons.
    reflexivity. }
  destruct (binary_subruns_from_ih env env_s e1 e2 v1 v2
              (compile_expr env e1) (compile_expr env e2)
              Hprop1 Hprop2 m fn f fr input mem cyc prefix
              (I32_XOR :: suffix)
              Hlook Hbody_sub Hpc Henv Hsafe1 Hsafe2 He1 He2)
    as [s1 [n1 [Hmulti1 [Hpost1 [Hn1 Hrun2]]]]].
  destruct (Hrun2 s1 Hpost1) as [s2 [n2 [Hmulti2 [Hpost2 Hn2]]]].
  destruct (corest_xor_spec_i32 env_s e1 e2 v1 v2 v n1 n2
              He1 He2 Heval Hn1 Hn2) as [n [Hvn Hspec]].
  pose proof (st_value_as_i32_sound v1 n1 Hn1) as Hsv1.
  pose proof (st_value_as_i32_sound v2 n2 Hn2) as Hsv2.
  destruct (compile_binary_expr_correct_pc_generic m fn f fr
              (compile_expr env e1) (compile_expr env e2)
              I32_XOR v1 v2 v n1 n2 n input mem cyc
              prefix suffix Hlook Hbody_sub Hpc Hsv1 Hsv2
              Hvn Hspec
              (ex_intro _ s1 (conj Hmulti1 Hpost1))
              (fun s1' Hs1' =>
                 exists_snd_drop_component runtime_state
                   (fun s2' => multi_pc_step m s1' s2')
                   (fun s2' =>
                     expr_pc_post
                       (set_frame_pc f
                          (f.(frame_pc) +
                           instrs_total_size (compile_expr env e1)))
                       fr (st_val_to_sasm_val v1 :: input) mem
                       (compile_expr env e2) s2' v2)
                   (fun n2' => st_value_as_i32 v2 = Some n2')
                   (Hrun2 s1' Hs1')))
    as [s3 [Hmulti3 [Hpost3 Hn3]]].
  rewrite <- Hshape in Hpost3.
  exists s3, n.
  split; [exact Hmulti3 | split; [exact Hpost3 | exact Hvn]].
Qed.

Lemma not_expr_property_from_ih :
  forall (env : compile_env) (env_s : corest_eval_env)
         (e1 : corest_expr) (v : st_value),
    (forall (v1 : st_value),
      corest_eval_expr env_s e1 = Some v1 ->
      expr_pc_property env env_s e1 v1 (compile_expr env e1)) ->
    expr_pc_property env env_s (CE_UNARY_OP U_NOT e1) v
      (compile_expr env (CE_UNARY_OP U_NOT e1)).
Proof.
  intros env env_s e1 v HIH1.
  unfold expr_pc_property.
  intros m fn f fr input mem cyc prefix suffix
    Hlook Hbody Hpc Henv Hsafe_whole.
  intro Heval.
  destruct (not_eval_witness env_s e1 v Heval) as [v1 He1].
  pose proof (HIH1 v1 He1) as Hprop1.
  simpl in Hsafe_whole.
  pose proof (compile_expr_not_shape env e1) as Hshape.
  assert (Hbody_sub :
    fn.(sasm_body) = prefix ++ compile_expr env e1 ++ I32_EQZ :: suffix).
  { rewrite Hshape in Hbody.
    rewrite Hbody.
    repeat rewrite app_assoc.
    rewrite app_singleton_cons.
    reflexivity. }
  destruct (Hprop1 m fn f fr input mem cyc prefix (I32_EQZ :: suffix)
              Hlook Hbody_sub Hpc Henv Hsafe_whole He1)
    as [s1 [n1 [Hmulti1 [Hpost1 Hn1]]]].
  destruct (corest_not_spec_i32 env_s e1 v1 v n1 He1 Heval Hn1)
    as [r [Hvr Hspec]].
  pose proof (st_value_as_i32_sound v1 n1 Hn1) as Hsv1.
  destruct (compile_unop_pc_from_sub m fn f fr input mem cyc
              prefix (compile_expr env e1) I32_EQZ suffix
              v1 v n1 r Hlook Hbody_sub Hpc Hsv1
              (st_value_as_i32_sound v r Hvr) Hspec
              (ex_intro _ s1 (conj Hmulti1 Hpost1)))
    as [s2 [Hmulti2 Hpost2]].
  rewrite <- Hshape in Hpost2.
  exists s2, r.
  split; [exact Hmulti2 | split; [exact Hpost2 | exact Hvr]].
Qed.

Lemma neg_expr_property_from_ih :
  forall (env : compile_env) (env_s : corest_eval_env)
         (e1 : corest_expr) (v : st_value),
    (forall (v1 : st_value),
      corest_eval_expr env_s e1 = Some v1 ->
      expr_pc_property env env_s e1 v1 (compile_expr env e1)) ->
    expr_pc_property env env_s (CE_UNARY_OP U_NEG e1) v
      (compile_expr env (CE_UNARY_OP U_NEG e1)).
Proof.
  intros env env_s e1 v HIH1.
  unfold expr_pc_property.
  intros m fn f fr input mem cyc prefix suffix
    Hlook Hbody Hpc Henv Hsafe_whole.
  intro Heval.
  destruct (neg_eval_witness env_s e1 v Heval) as [ve He].
  pose proof (HIH1 ve He) as Hprop_e.
  pose proof (lit_int_zero_property env env_s) as Hprop_zero.
  simpl in Hsafe_whole.
  pose proof (compile_expr_neg_shape env e1) as Hshape.
  assert (Hbody_sub :
    fn.(sasm_body) =
    (prefix ++ [I32_CONST 0] ++ compile_expr env e1) ++ I32_SUB :: suffix).
  { rewrite Hshape in Hbody.
    rewrite Hbody.
    repeat rewrite app_assoc.
    rewrite app_singleton_cons.
    reflexivity. }
  destruct (binary_subruns_from_ih env env_s
              (CE_LIT (L_INT 0)) e1 (ST_V_INT 0) ve
              [I32_CONST 0] (compile_expr env e1)
              Hprop_zero Hprop_e m fn f fr input mem cyc prefix
              (I32_SUB :: suffix)
              Hlook Hbody_sub Hpc Henv I Hsafe_whole eq_refl He)
    as [s1 [n0 [Hmulti1 [Hpost1 [Hn0 Hrun2]]]]].
  destruct (Hrun2 s1 Hpost1) as [s2 [ne [Hmulti2 [Hpost2 Hne]]]].
  destruct (corest_neg_spec_i32 env_s e1 ve v ne He Heval Hne)
    as [r [Hvr Hspec]].
  pose proof (st_value_as_i32_sound (ST_V_INT 0) n0 Hn0) as Hsv0.
  pose proof (st_value_as_i32_sound ve ne Hne) as Hsv_e.
  inversion Hn0; subst n0.
  destruct (compile_binary_expr_correct_pc_generic m fn f fr
              [I32_CONST 0] (compile_expr env e1) I32_SUB
              (ST_V_INT 0) ve v 0 ne r input mem cyc
              prefix suffix Hlook Hbody_sub Hpc Hsv0 Hsv_e
              Hvr Hspec
              (ex_intro _ s1 (conj Hmulti1 Hpost1))
              (fun s1' Hs1' =>
                 exists_snd_drop_component runtime_state
                   (fun s2' => multi_pc_step m s1' s2')
                   (fun s2' =>
                     expr_pc_post
                       (set_frame_pc f
                          (f.(frame_pc) + instrs_total_size [I32_CONST 0]))
                       fr (st_val_to_sasm_val (ST_V_INT 0) :: input) mem
                       (compile_expr env e1) s2' ve)
                   (fun n2' => st_value_as_i32 ve = Some n2')
                   (Hrun2 s1' Hs1')))
    as [s3 [Hmulti3 [Hpost3 Hn3]]].
  rewrite <- Hshape in Hpost3.
  exists s3, r.
  split; [exact Hmulti3 | split; [exact Hpost3 | exact Hvr]].
Qed.

Theorem compile_expr_correct_pc :
  forall (env : compile_env) (env_s : corest_eval_env)
         (e : corest_expr),
    pc_expr_supported e = true ->
    forall (v : st_value),
      corest_eval_expr env_s e = Some v ->
      expr_pc_property env env_s e v (compile_expr env e).
Proof.
  intros env env_s e.
  induction e as [lit | x | arr idx IHa IHidx | uop e1 IHe1
    | bop e1 IHe1 e2 IHe2 | cop e1 IHe1 e2 IHe2
    | e1 IHe1 e2 IHe2 | e1 IHe1 e2 IHe2 | e1 IHe1 e2 IHe2
    | fname args | qop args]; intros Hsupport v Heval.
  - destruct lit; simpl in Hsupport; try discriminate.
    + simpl in Heval; inversion Heval; subst.
      apply lit_bool_property.
    + simpl in Heval; inversion Heval; subst.
      apply lit_int_property.
  - apply var_expr_property.
  - simpl in Hsupport; discriminate.
  - simpl in Hsupport.
    destruct uop; simpl in Hsupport; try discriminate.
    + apply neg_expr_property_from_ih.
      intros v1 He1.
      exact (IHe1 Hsupport v1 He1).
    + apply not_expr_property_from_ih.
      intros v1 He1.
      exact (IHe1 Hsupport v1 He1).
  - simpl in Hsupport.
    apply andb_true_iff in Hsupport.
    destruct Hsupport as [Hsup1 Hsup2].
    apply binop_expr_property_from_ih.
    + intros v1 He1. exact (IHe1 Hsup1 v1 He1).
    + intros v2 He2. exact (IHe2 Hsup2 v2 He2).
  - simpl in Hsupport.
    apply andb_true_iff in Hsupport.
    destruct Hsupport as [Hsup1 Hsup2].
    apply compare_expr_property_from_ih.
    + intros v1 He1. exact (IHe1 Hsup1 v1 He1).
    + intros v2 He2. exact (IHe2 Hsup2 v2 He2).
  - simpl in Hsupport.
    apply andb_true_iff in Hsupport.
    destruct Hsupport as [Hsup1 Hsup2].
    apply and_expr_property_from_ih.
    + intros v1 He1. exact (IHe1 Hsup1 v1 He1).
    + intros v2 He2. exact (IHe2 Hsup2 v2 He2).
  - simpl in Hsupport.
    apply andb_true_iff in Hsupport.
    destruct Hsupport as [Hsup1 Hsup2].
    apply or_expr_property_from_ih.
    + intros v1 He1. exact (IHe1 Hsup1 v1 He1).
    + intros v2 He2. exact (IHe2 Hsup2 v2 He2).
  - simpl in Hsupport.
    apply andb_true_iff in Hsupport.
    destruct Hsupport as [Hsup1 Hsup2].
    apply xor_expr_property_from_ih.
    + intros v1 He1. exact (IHe1 Hsup1 v1 He1).
    + intros v2 He2. exact (IHe2 Hsup2 v2 He2).
  - simpl in Hsupport; discriminate.
  - simpl in Hsupport; discriminate.
Qed.

Lemma compile_assign_correct_pc :
  forall (m : sasm_module) (fn : sasm_function) (f : sasm_frame)
         (fr : frame_stack) (env : compile_env) (env_ty : compile_type_env)
         (s : st_state) (x : ident) (e : corest_expr) (ty : st_type)
         (v : st_value) (n idx : Z) (input : value_stack) (mem : list Z)
         (cyc : Z) (prefix suffix : list sasm_instr),
    compile_env_injective env ->
    compile_env_nonneg env ->
    lookup_var_type env_ty x = Some ty ->
    codegen_core_ty ty ->
    lookup_var_idx env x = Some idx ->
    (Z.to_nat idx < List.length f.(frame_locals))%nat ->
    lookup_function m f.(frame_func_idx) = Some fn ->
    fn.(sasm_body) =
      prefix ++ compile_stmt env env_ty (CS_ASSIGN x e) ++ suffix ->
    f.(frame_pc) = instrs_total_size prefix ->
    pc_frame_env_matches env s.(st_vars) f ->
    pc_expr_supported e = true ->
    pc_expr_safe s.(st_vars) e ->
    corest_eval_expr s.(st_vars) e = Some v ->
    st_value_as_i32 v = Some n ->
    exists (s' : runtime_state),
      multi_pc_step m
        {| rt_values := input; rt_frames := f :: fr;
           rt_memory := mem; rt_cycle_cnt := cyc |}
        s' /\
      s'.(rt_values) = input /\
      s'.(rt_frames) =
        {| frame_locals := list_set f.(frame_locals) (Z.to_nat idx) (V_I32 n);
           frame_func_idx := f.(frame_func_idx);
           frame_pc := f.(frame_pc) +
             instrs_total_size (compile_expr env e) +
             instr_size (LOCAL_SET idx);
           frame_block_stack := f.(frame_block_stack) |} :: fr /\
      s'.(rt_memory) = mem /\
      pc_frame_env_matches env ((x, v) :: s.(st_vars))
        {| frame_locals := list_set f.(frame_locals) (Z.to_nat idx) (V_I32 n);
           frame_func_idx := f.(frame_func_idx);
           frame_pc := f.(frame_pc) +
             instrs_total_size (compile_expr env e) +
             instr_size (LOCAL_SET idx);
           frame_block_stack := f.(frame_block_stack) |}.
Proof.
  intros m fn f fr env env_ty s x e ty v n idx input mem cyc prefix suffix
    Hinj Hnonneg Htype Hcore Hidx Hbound Hlook Hbody Hpc Henv
    Hsupport Hsafe Heval Hvn.
  pose proof (compile_stmt_assign_core_shape env env_ty x e ty idx
                Htype Hcore Hidx) as Hshape.
  assert (Hbody' :
    fn.(sasm_body) =
      prefix ++ compile_expr env e ++ [LOCAL_SET idx] ++ suffix).
  { rewrite Hshape in Hbody.
    rewrite Hbody.
    repeat rewrite app_assoc.
    rewrite app_singleton_cons.
    reflexivity. }
  pose proof (compile_expr_correct_pc env s.(st_vars) e Hsupport v Heval)
    as Hprop.
  destruct (Hprop m fn f fr input mem cyc prefix
              ([LOCAL_SET idx] ++ suffix)
              Hlook Hbody' Hpc Henv Hsafe Heval)
    as [s1 [n' [Hmulti1 [Hpost1 Hn']]]].
  assert (Hn'eq : n' = n).
  { rewrite Hvn in Hn'. inversion Hn'. reflexivity. }
  subst n'.
  destruct (pc_local_set_after_expr m fn f fr input mem cyc prefix
              (compile_expr env e) suffix idx v n
              Hlook Hbody' Hpc Hvn
              (ex_intro _ s1 (conj Hmulti1 Hpost1)))
    as [s2 [Hmulti2 [Hval2 [Hframes2 Hmem2]]]].
  set (updated :=
    {| frame_locals := list_set f.(frame_locals) (Z.to_nat idx) (V_I32 n);
       frame_func_idx := f.(frame_func_idx);
       frame_pc := f.(frame_pc) + instrs_total_size (compile_expr env e) +
                   instr_size (LOCAL_SET idx);
       frame_block_stack := f.(frame_block_stack) |}).
  exists s2.
  split; [exact Hmulti2 |].
  split; [exact Hval2 |].
  split.
  { subst updated. exact Hframes2. }
  split; [exact Hmem2 |].
  subst updated.
  eapply pc_frame_env_matches_update;
    [exact Hinj | exact Hnonneg | exact Hidx | exact Hvn | exact Hbound | exact Henv].
Qed.

Lemma compile_assign_correct_build_env_pc :
  forall (m : sasm_module) (fn : sasm_function) (f : sasm_frame)
         (fr : frame_stack) (cf : corest_function)
         (s : st_state) (x : ident) (e : corest_expr) (ty : st_type)
         (v : st_value) (n idx : Z) (input : value_stack) (mem : list Z)
         (cyc : Z) (prefix suffix : list sasm_instr),
    lookup_var_type (build_compile_type_env cf) x = Some ty ->
    codegen_core_ty ty ->
    lookup_var_idx (build_compile_env cf) x = Some idx ->
    List.length f.(frame_locals) =
      List.length (build_compile_type_env cf) ->
    lookup_function m f.(frame_func_idx) = Some fn ->
    fn.(sasm_body) =
      prefix ++
      compile_stmt (build_compile_env cf) (build_compile_type_env cf)
        (CS_ASSIGN x e) ++ suffix ->
    f.(frame_pc) = instrs_total_size prefix ->
    pc_frame_env_matches (build_compile_env cf) s.(st_vars) f ->
    pc_expr_supported e = true ->
    pc_expr_safe s.(st_vars) e ->
    corest_eval_expr s.(st_vars) e = Some v ->
    st_value_as_i32 v = Some n ->
    exists (s' : runtime_state),
      multi_pc_step m
        {| rt_values := input; rt_frames := f :: fr;
           rt_memory := mem; rt_cycle_cnt := cyc |}
        s' /\
      pc_frame_env_matches (build_compile_env cf) ((x, v) :: s.(st_vars))
        {| frame_locals := list_set f.(frame_locals) (Z.to_nat idx) (V_I32 n);
           frame_func_idx := f.(frame_func_idx);
           frame_pc := f.(frame_pc) +
             instrs_total_size (compile_expr (build_compile_env cf) e) +
             instr_size (LOCAL_SET idx);
           frame_block_stack := f.(frame_block_stack) |}.
Proof.
  intros m fn f fr cf s x e ty v n idx input mem cyc prefix suffix
    Htype Hcore Hidx Hlen Hlook Hbody Hpc Henv Hsupport Hsafe Heval Hvn.
  pose proof (build_compile_env_bound cf x idx Hidx) as Hbound.
  destruct Hbound as [Hidx_nonneg Hidx_lt].
  assert (Hidx_nat :
    (Z.to_nat idx <
      (List.length cf.(cfunc_params) + List.length cf.(cfunc_locals)))%nat).
  { assert (Hidx_nat_raw :
      (Z.to_nat idx <
       Z.to_nat (Z.of_nat (List.length cf.(cfunc_params) +
                           List.length cf.(cfunc_locals))))%nat) by
      (exact (proj1 (Z2Nat.inj_lt idx
                      (Z.of_nat (List.length cf.(cfunc_params) +
                                 List.length cf.(cfunc_locals)))
                      Hidx_nonneg (Zle_0_nat _)) Hidx_lt)).
    rewrite Nat2Z.id in Hidx_nat_raw.
    exact Hidx_nat_raw. }
  unfold build_compile_type_env in Hlen.
  rewrite List.length_app in Hlen.
  rewrite <- Hlen in Hidx_nat.
  destruct (compile_assign_correct_pc m fn f fr
              (build_compile_env cf) (build_compile_type_env cf)
              s x e ty v n idx input mem cyc prefix suffix
              (build_compile_env_injective cf)
              (build_compile_env_nonneg cf)
              Htype Hcore Hidx Hidx_nat Hlook Hbody Hpc Henv
              Hsupport Hsafe Heval Hvn)
    as [s' [Hmulti [_ [_ [_ Hrel]]]]].
  exists s'.
  split; [exact Hmulti | exact Hrel].
Qed.

Fixpoint assign_sequence_ok (env : compile_env) (env_ty : compile_type_env)
         (s : st_state) (stmts : list corest_stmt) : Prop :=
  match stmts with
  | nil => True
  | CS_ASSIGN x e :: rest =>
      exists (ty : st_type) (v : st_value) (n idx : Z),
        lookup_var_type env_ty x = Some ty /\
        codegen_core_ty ty /\
        lookup_var_idx env x = Some idx /\
        pc_expr_supported e = true /\
        pc_expr_safe s.(st_vars) e /\
        corest_eval_expr s.(st_vars) e = Some v /\
        st_value_as_i32 v = Some n /\
        st_value_as_i32 (corest_assign_value s x v) = Some n /\
        assign_sequence_ok env env_ty
          (update_var s x (corest_assign_value s x v)) rest
  | _ => False
  end.

Lemma compile_assign_sequence_correct_pc :
  forall (env : compile_env) (env_ty : compile_type_env)
         (stmts : list corest_stmt),
    forall (s : st_state),
      assign_sequence_ok env env_ty s stmts ->
      forall (m : sasm_module) (fn : sasm_function) (f : sasm_frame)
             (fr : frame_stack) (input : value_stack) (mem : list Z)
             (cyc : Z) (prefix suffix : list sasm_instr),
        compile_env_injective env ->
        compile_env_nonneg env ->
        compile_env_fits_frame env f ->
        lookup_function m f.(frame_func_idx) = Some fn ->
        fn.(sasm_body) =
          prefix ++ compile_stmts env env_ty stmts ++ suffix ->
        f.(frame_pc) = instrs_total_size prefix ->
        pc_frame_env_matches env s.(st_vars) f ->
        exists (s_asm : runtime_state) (f_asm : sasm_frame)
               (s_core : st_state),
          multi_pc_step m
            {| rt_values := input; rt_frames := f :: fr;
               rt_memory := mem; rt_cycle_cnt := cyc |}
            s_asm /\
          star_corest_step stmts s nil s_core /\
          s_asm.(rt_frames) = f_asm :: fr /\
          s_asm.(rt_values) = input /\
          s_asm.(rt_memory) = mem /\
          pc_frame_env_matches env s_core.(st_vars) f_asm /\
          f_asm.(frame_block_stack) = f.(frame_block_stack) /\
          f_asm.(frame_func_idx) = f.(frame_func_idx) /\
          f_asm.(frame_pc) =
            f.(frame_pc) + instrs_total_size (compile_stmts env env_ty stmts) /\
          List.length f_asm.(frame_locals) = List.length f.(frame_locals).
Proof.
  intros env env_ty stmts.
  induction stmts as [|stmt rest IH]; intros s Hok m fn f fr input mem cyc
    prefix suffix Hinj Hnonneg Hfit Hlook Hbody Hpc Henv.
  - simpl in Hok.
    exists
      {| rt_values := input; rt_frames := f :: fr;
         rt_memory := mem; rt_cycle_cnt := cyc |}, f, s.
    split; [apply Multi_pc_refl |].
    split; [apply CsStar_refl |].
    split; [reflexivity |].
    split; [reflexivity |].
    split; [reflexivity |].
    split; [exact Henv |].
    split; [reflexivity |].
    split; [reflexivity |].
    split; [simpl; rewrite Z.add_0_r; reflexivity | reflexivity].
  - destruct stmt as [x e | x idx e | cond then_body else_body | cond body
      | inst params | | | body].
    all: simpl in Hok; try contradiction.
    destruct Hok as
      [ty [v [n [idx [Htype [Hcore [Hidx [Hsupport [Hsafe
        [Heval [Hvn [Hvn_coerced Hrest]]]]]]]]]]]].
    pose proof (compile_stmt_assign_core_shape env env_ty x e ty idx
                  Htype Hcore Hidx) as Hshape.
    pose proof (compile_stmts_cons env env_ty (CS_ASSIGN x e) rest) as Hcons.
    assert (Hbody_assign :
      fn.(sasm_body) =
      prefix ++ compile_stmt env env_ty (CS_ASSIGN x e) ++
      compile_stmts env env_ty rest ++ suffix).
    { rewrite Hcons in Hbody.
      rewrite Hbody.
      repeat rewrite app_assoc.
      reflexivity. }
    assert (Hbound : (Z.to_nat idx < List.length f.(frame_locals))%nat).
    { exact (Hfit x idx Hidx). }
    destruct (compile_assign_correct_pc m fn f fr env env_ty s x e ty v n idx
                input mem cyc prefix
                (compile_stmts env env_ty rest ++ suffix)
                Hinj Hnonneg Htype Hcore Hidx Hbound Hlook Hbody_assign
                Hpc Henv Hsupport Hsafe Heval Hvn)
      as [s1 [Hmulti1 [Hval1 [Hframes1 [Hmem1 Hrel1]]]]].
    set (f1 :=
      {| frame_locals := list_set f.(frame_locals) (Z.to_nat idx) (V_I32 n);
         frame_func_idx := f.(frame_func_idx);
         frame_pc := f.(frame_pc) +
           instrs_total_size (compile_expr env e) +
           instr_size (LOCAL_SET idx);
         frame_block_stack := f.(frame_block_stack) |}).
    assert (Hframes1' : s1.(rt_frames) = f1 :: fr).
    { subst f1. exact Hframes1. }
    assert (Hpc1 : f1.(frame_pc) =
                   instrs_total_size
                     (prefix ++ compile_stmt env env_ty (CS_ASSIGN x e))).
    { rewrite Hshape.
      subst f1. simpl.
      repeat rewrite instrs_total_size_app.
      rewrite instrs_total_size_singleton.
      rewrite Hpc.
      simpl in *.
      ring. }
    assert (Hfit1 : compile_env_fits_frame env f1).
    { subst f1. eapply compile_env_fits_frame_update;
        [exact Hfit | exact Hidx]. }
    assert (Hbody_rest :
      fn.(sasm_body) =
      (prefix ++ compile_stmt env env_ty (CS_ASSIGN x e)) ++
      compile_stmts env env_ty rest ++ suffix).
    { rewrite Hbody_assign. repeat rewrite app_assoc. reflexivity. }
    assert (Hrel1_coerced :
      pc_frame_env_matches env
        ((x, corest_assign_value s x v) :: s.(st_vars)) f1).
    { subst f1. eapply pc_frame_env_matches_update;
        [exact Hinj | exact Hnonneg | exact Hidx | exact Hvn_coerced |
         exact Hbound | exact Henv]. }
    destruct (IH (update_var s x (corest_assign_value s x v)) Hrest
                m fn f1 fr input mem
                s1.(rt_cycle_cnt)
                (prefix ++ compile_stmt env env_ty (CS_ASSIGN x e))
                suffix Hinj Hnonneg Hfit1 Hlook Hbody_rest Hpc1
                Hrel1_coerced)
      as [s_asm [f_asm [s_core Hrest2]]].
    destruct Hrest2 as
      (Hmulti2 & Hstar & Hframes2 & Hval2 & Hmem2 &
       Hrel2 & Hblock2 & Hfunc2 & Hpc2 & Hlen2).
    assert (Hs1_eq :
      s1 = {| rt_values := input; rt_frames := f1 :: fr;
              rt_memory := mem; rt_cycle_cnt := s1.(rt_cycle_cnt) |}).
    { destruct s1 as [vals frames memory cycles].
      simpl in Hval1, Hframes1, Hmem1.
      subst vals. subst frames. subst memory.
      reflexivity. }
    rewrite <- Hs1_eq in Hmulti2.
    exists s_asm, f_asm, s_core.
    split.
    + eapply multi_pc_step_trans; [exact Hmulti1 | exact Hmulti2].
    + split.
      * eapply CsStar_step.
        -- eapply Cs_assign; exact Heval.
        -- exact Hstar.
      * split; [exact Hframes2 |].
        split; [exact Hval2 |].
        split; [exact Hmem2 |].
        split; [exact Hrel2 |].
        split.
        -- subst f1. simpl. exact Hblock2.
        -- split.
           --- subst f1. simpl. exact Hfunc2.
           --- rewrite Hcons.
              rewrite instrs_total_size_app.
              assert (Hf1pc : f1.(frame_pc) =
                f.(frame_pc) +
                instrs_total_size (compile_stmt env env_ty (CS_ASSIGN x e))).
              { rewrite instrs_total_size_app in Hpc1.
                rewrite <- Hpc in Hpc1.
                exact Hpc1. }
              rewrite Hpc2.
              rewrite Hf1pc.
              assert (Hlen1 :
                List.length f1.(frame_locals) =
                List.length f.(frame_locals)).
              { subst f1. apply list_set_length. exact Hbound. }
              split; [ring | rewrite Hlen2; exact Hlen1].
Qed.

Definition pc_stmts_spec (env : compile_env) (env_ty : compile_type_env)
           (s : st_state) (stmts : list corest_stmt) : Prop :=
  forall (m : sasm_module) (fn : sasm_function) (f : sasm_frame)
         (fr : frame_stack) (input : value_stack) (mem : list Z)
         (cyc : Z) (prefix suffix : list sasm_instr),
    compile_env_injective env ->
    compile_env_nonneg env ->
    compile_env_fits_frame env f ->
    lookup_function m f.(frame_func_idx) = Some fn ->
    fn.(sasm_body) =
      prefix ++ compile_stmts env env_ty stmts ++ suffix ->
    f.(frame_pc) = instrs_total_size prefix ->
    pc_frame_env_matches env s.(st_vars) f ->
    exists (s_asm : runtime_state) (f_asm : sasm_frame)
           (s_core : st_state),
      multi_pc_step m
        {| rt_values := input; rt_frames := f :: fr;
           rt_memory := mem; rt_cycle_cnt := cyc |}
        s_asm /\
      star_corest_step stmts s nil s_core /\
      s_asm.(rt_frames) = f_asm :: fr /\
      s_asm.(rt_values) = input /\
      s_asm.(rt_memory) = mem /\
      pc_frame_env_matches env s_core.(st_vars) f_asm /\
      f_asm.(frame_block_stack) = f.(frame_block_stack) /\
      f_asm.(frame_func_idx) = f.(frame_func_idx) /\
      f_asm.(frame_pc) =
        f.(frame_pc) + instrs_total_size (compile_stmts env env_ty stmts) /\
      List.length f_asm.(frame_locals) = List.length f.(frame_locals).

Definition pc_stmt_spec (env : compile_env) (env_ty : compile_type_env)
           (s : st_state) (stmt : corest_stmt) : Prop :=
  forall (m : sasm_module) (fn : sasm_function) (f : sasm_frame)
         (fr : frame_stack) (input : value_stack) (mem : list Z)
         (cyc : Z) (prefix suffix : list sasm_instr),
    compile_env_injective env ->
    compile_env_nonneg env ->
    compile_env_fits_frame env f ->
    lookup_function m f.(frame_func_idx) = Some fn ->
    fn.(sasm_body) =
      prefix ++ compile_stmt env env_ty stmt ++ suffix ->
    f.(frame_pc) = instrs_total_size prefix ->
    pc_frame_env_matches env s.(st_vars) f ->
    exists (s_asm : runtime_state) (f_asm : sasm_frame)
           (s_core : st_state),
      multi_pc_step m
        {| rt_values := input; rt_frames := f :: fr;
           rt_memory := mem; rt_cycle_cnt := cyc |}
        s_asm /\
      star_corest_step [stmt] s nil s_core /\
      s_asm.(rt_frames) = f_asm :: fr /\
      s_asm.(rt_values) = input /\
      s_asm.(rt_memory) = mem /\
      pc_frame_env_matches env s_core.(st_vars) f_asm /\
      f_asm.(frame_block_stack) = f.(frame_block_stack) /\
      f_asm.(frame_func_idx) = f.(frame_func_idx) /\
      f_asm.(frame_pc) =
        f.(frame_pc) + instrs_total_size (compile_stmt env env_ty stmt) /\
      List.length f_asm.(frame_locals) = List.length f.(frame_locals).

Lemma star_corest_step_app :
  forall (xs : list corest_stmt) (s1 : st_state)
         (ys : list corest_stmt) (s2 : st_state)
         (zs : list corest_stmt) (s3 : st_state),
    star_corest_step xs s1 ys s2 ->
    star_corest_step ys s2 zs s3 ->
    star_corest_step xs s1 zs s3.
Proof.
  intros xs s1 ys s2 zs s3 Hxy.
  revert zs s3.
  induction Hxy as [stmts s
    | stmts1 stmts2 stmts3 s1' s2' s3' Hstep Hrest IH];
    intros zs s_final Hyz.
  - exact Hyz.
  - eapply CsStar_step.
    + exact Hstep.
    + exact (IH zs s_final Hyz).
Qed.

Lemma corest_step_tail :
  forall (stmts1 stmts2 : list corest_stmt)
         (s1 s2 : st_state) (tail : list corest_stmt),
    corest_step stmts1 s1 stmts2 s2 ->
    corest_step (stmts1 ++ tail) s1 (stmts2 ++ tail) s2.
Proof.
  intros stmts1 stmts2 s1 s2 tail Hstep.
  inversion Hstep; subst; simpl.
  - eapply Cs_assign; eauto.
  - replace ((then_body ++ rest) ++ tail)
      with (then_body ++ (rest ++ tail))
      by (rewrite app_assoc; reflexivity).
    eapply Cs_if_true; eauto.
  - replace ((else_body ++ rest) ++ tail)
      with (else_body ++ (rest ++ tail))
      by (rewrite app_assoc; reflexivity).
    eapply Cs_if_false; eauto.
  - rewrite app_cons_assoc.
    eapply Cs_while_true; eauto.
  - eapply Cs_while_false; eauto.
  - replace ((body ++ rest) ++ tail)
      with (body ++ (rest ++ tail))
      by (rewrite app_assoc; reflexivity).
    eapply Cs_block; eauto.
Qed.

Lemma star_corest_step_tail :
  forall (stmts1 stmts2 : list corest_stmt)
         (s1 s2 : st_state) (tail : list corest_stmt),
    star_corest_step stmts1 s1 stmts2 s2 ->
    star_corest_step (stmts1 ++ tail) s1 (stmts2 ++ tail) s2.
Proof.
  intros stmts1 stmts2 s1 s2 tail Hstar.
  induction Hstar as
    [stmts s | stmts1 stmts2 stmts3 s1' s2' s3' Hstep Hrest IH].
  - apply CsStar_refl.
  - eapply CsStar_step.
    + apply corest_step_tail. exact Hstep.
    + exact IH.
Qed.

Lemma pc_stmts_spec_cons :
  forall (env : compile_env) (env_ty : compile_type_env)
         (s : st_state) (stmt : corest_stmt)
         (rest : list corest_stmt),
    pc_stmt_spec env env_ty s stmt ->
    (forall (s_core : st_state),
      star_corest_step [stmt] s nil s_core ->
      pc_stmts_spec env env_ty s_core rest) ->
    pc_stmts_spec env env_ty s (stmt :: rest).
Proof.
  intros env env_ty s stmt rest Hstmt Hrest.
  unfold pc_stmts_spec.
  intros m fn f fr input mem cyc prefix suffix
    Hinj Hnonneg Hfit Hlook Hbody Hpc Henv.
  assert (Hbody_head :
    fn.(sasm_body) =
      prefix ++ compile_stmt env env_ty stmt ++
      (compile_stmts env env_ty rest ++ suffix)).
  { rewrite Hbody.
    rewrite (compile_stmts_cons env env_ty stmt rest).
    repeat rewrite app_assoc.
    reflexivity. }
  destruct (Hstmt m fn f fr input mem cyc prefix
              (compile_stmts env env_ty rest ++ suffix)
              Hinj Hnonneg Hfit Hlook Hbody_head Hpc Henv)
    as [s1 [f1 [s_mid Hrest1]]].
  destruct Hrest1 as
    (Hmulti1 & Hstar1 & Hframes1 & Hval1 & Hmem1 &
     Hrel1 & Hblock1 & Hfunc1 & Hpc1 & Hlen_stmt).
  set (prefix_stmt := prefix ++ compile_stmt env env_ty stmt).
  assert (Hpc1' : f1.(frame_pc) = instrs_total_size prefix_stmt).
  { subst prefix_stmt.
    rewrite instrs_total_size_app.
    rewrite <- Hpc.
    exact Hpc1. }
  assert (Hlook1 : lookup_function m f1.(frame_func_idx) = Some fn).
  { rewrite Hfunc1. exact Hlook. }
  assert (Hfit1 : compile_env_fits_frame env f1).
  { intros x idx Hidx.
    unfold compile_env_fits_frame in Hfit.
    rewrite Hlen_stmt.
    exact (Hfit x idx Hidx). }
  assert (Hbody_rest :
    fn.(sasm_body) =
      prefix_stmt ++ compile_stmts env env_ty rest ++ suffix).
  { subst prefix_stmt.
    rewrite Hbody.
    rewrite (compile_stmts_cons env env_ty stmt rest).
    repeat rewrite app_assoc.
    reflexivity. }
  destruct (Hrest s_mid Hstar1 m fn f1 fr input mem s1.(rt_cycle_cnt)
              prefix_stmt suffix
              Hinj Hnonneg Hfit1
              Hlook1 Hbody_rest Hpc1' Hrel1)
    as [s2 [f2 [s_final Hrest2]]].
  destruct Hrest2 as
    (Hmulti2 & Hstar2 & Hframes2 & Hval2 & Hmem2 &
     Hrel2 & Hblock2 & Hfunc2 & Hpc2 & Hlen_rest).
  assert (Hs1 :
    s1 =
      {| rt_values := input; rt_frames := f1 :: fr;
         rt_memory := mem; rt_cycle_cnt := s1.(rt_cycle_cnt) |}).
  { destruct s1 as [vals frames memory cycles].
    simpl in Hval1, Hframes1, Hmem1.
    subst vals. subst frames. subst memory. reflexivity. }
  rewrite <- Hs1 in Hmulti2.
  exists s2, f2, s_final.
  split.
  - eapply multi_pc_step_trans; [exact Hmulti1 | exact Hmulti2].
  - split.
    + change (star_corest_step ([stmt] ++ rest) s nil s_final).
      eapply star_corest_step_app with
        (ys := rest) (s2 := s_mid).
      * pose proof (star_corest_step_tail [stmt] nil s s_mid rest Hstar1)
          as Hstar1_tail.
        change (star_corest_step ([stmt] ++ rest) s ([] ++ rest) s_mid)
          in Hstar1_tail.
        exact Hstar1_tail.
      * exact Hstar2.
    + split; [exact Hframes2 |].
      split; [exact Hval2 |].
      split; [exact Hmem2 |].
      split; [exact Hrel2 |].
      split.
      * rewrite Hblock2. rewrite Hblock1. reflexivity.
      * split.
        -- rewrite Hfunc2. rewrite Hfunc1. reflexivity.
        -- rewrite Hpc2. rewrite Hpc1.
           split.
           ++ rewrite (compile_stmts_cons env env_ty stmt rest).
              rewrite instrs_total_size_app.
              ring.
           ++ rewrite Hlen_rest. exact Hlen_stmt.
Qed.

Lemma assign_sequence_pc_stmts_spec :
  forall (env : compile_env) (env_ty : compile_type_env)
         (s : st_state) (stmts : list corest_stmt),
    assign_sequence_ok env env_ty s stmts ->
    pc_stmts_spec env env_ty s stmts.
Proof.
  intros env env_ty s stmts Hok.
  unfold pc_stmts_spec.
  intros m fn f fr input mem cyc prefix suffix
    Hinj Hnonneg Hfit Hlook Hbody Hpc Henv.
  exact (compile_assign_sequence_correct_pc env env_ty stmts s Hok
           m fn f fr input mem cyc prefix suffix
           Hinj Hnonneg Hfit Hlook Hbody Hpc Henv).
Qed.

Lemma compile_stmts_then_br_correct_pc :
  forall (env : compile_env) (env_ty : compile_type_env)
         (stmts : list corest_stmt) (s : st_state),
    pc_stmts_spec env env_ty s stmts ->
    forall (m : sasm_module) (fn : sasm_function) (f : sasm_frame)
           (fr : frame_stack) (input : value_stack) (mem : list Z)
           (cyc : Z) (prefix suffix : list sasm_instr)
           (depth target : Z),
      compile_env_injective env ->
      compile_env_nonneg env ->
      compile_env_fits_frame env f ->
      lookup_function m f.(frame_func_idx) = Some fn ->
      fn.(sasm_body) =
        prefix ++ compile_stmts env env_ty stmts ++ [BR depth] ++ suffix ->
      f.(frame_pc) = instrs_total_size prefix ->
      pc_frame_env_matches env s.(st_vars) f ->
      List.nth_error f.(frame_block_stack) (Z.to_nat depth) = Some target ->
      exists (s_asm : runtime_state) (f_asm : sasm_frame)
             (s_core : st_state),
        multi_pc_step m
          {| rt_values := input; rt_frames := f :: fr;
             rt_memory := mem; rt_cycle_cnt := cyc |}
          s_asm /\
        star_corest_step stmts s nil s_core /\
        s_asm.(rt_frames) = f_asm :: fr /\
        s_asm.(rt_values) = input /\
        s_asm.(rt_memory) = mem /\
        pc_frame_env_matches env s_core.(st_vars) f_asm /\
        f_asm.(frame_block_stack) =
          List.skipn (Z.to_nat depth + 1) f.(frame_block_stack) /\
        f_asm.(frame_func_idx) = f.(frame_func_idx) /\
        f_asm.(frame_pc) = target /\
        List.length f_asm.(frame_locals) = List.length f.(frame_locals).
Proof.
  intros env env_ty stmts s Hspec m fn f fr input mem cyc prefix suffix
    depth target Hinj Hnonneg Hfit Hlook Hbody Hpc Henv Hnth.
  destruct (Hspec m fn f fr input mem cyc prefix (BR depth :: suffix)
              Hinj Hnonneg Hfit Hlook Hbody Hpc Henv)
    as [s1 [f1 [s_core Hrest]]].
  destruct Hrest as
    (Hmulti1 & Hstar & Hframes1 & Hval1 & Hmem1 &
     Hrel1 & Hblock1 & Hfunc1 & Hpc1 & Hlen1).
  set (prefix_body := prefix ++ compile_stmts env env_ty stmts).
  assert (Hpc1' : f1.(frame_pc) = instrs_total_size prefix_body).
  { subst prefix_body.
    rewrite instrs_total_size_app.
    rewrite <- Hpc.
    exact Hpc1. }
  assert (Hbody_br :
    fn.(sasm_body) = prefix_body ++ BR depth :: suffix).
  { subst prefix_body.
    rewrite Hbody.
    repeat rewrite app_assoc.
    rewrite app_singleton_cons.
    reflexivity. }
  assert (Hlook1 : lookup_function m f1.(frame_func_idx) = Some fn).
  { rewrite Hfunc1. exact Hlook. }
  assert (Hfetch :
    fetch_frame_instr m f1 =
      Some (BR depth, f1.(frame_pc) + instr_size (BR depth))).
  { rewrite Hpc1'.
    apply fetch_frame_instr_app_exact with
      (fn := fn) (prefix := prefix_body) (i := BR depth) (rest := suffix);
      [exact Hlook1 | exact Hbody_br | exact Hpc1']. }
  assert (Hnth1 :
    List.nth_error f1.(frame_block_stack) (Z.to_nat depth) = Some target).
  { rewrite Hblock1. exact Hnth. }
  set (f2 := frame_branch_to f1 depth target).
  set (s2 := set_top_values_cycle s1 f2 s1.(rt_values)).
  assert (Hmulti2 : multi_pc_step m s1 s2).
  { subst s2 f2.
    eapply pc_br_multi with
      (rest := fr) (depth := depth) (target := target)
      (next := f1.(frame_pc) + instr_size (BR depth)).
    - exact Hframes1.
    - exact Hfetch.
    - exact Hnth1. }
  exists s2, f2, s_core.
  split.
  - eapply multi_pc_step_trans; [exact Hmulti1 | exact Hmulti2].
  - split; [exact Hstar |].
    split.
    + subst s2 f2. unfold set_top_values_cycle. rewrite Hframes1.
      reflexivity.
    + split.
      * subst s2. unfold set_top_values_cycle. rewrite Hframes1.
        exact Hval1.
      * split.
        -- subst s2. unfold set_top_values_cycle. rewrite Hframes1.
           exact Hmem1.
        -- split; [exact Hrel1 |].
           split.
           ++ subst f2. unfold frame_branch_to. rewrite Hblock1.
              reflexivity.
           ++ split.
              ** subst f2. unfold frame_branch_to. rewrite Hfunc1.
                 reflexivity.
              ** split.
                 --- subst f2. unfold frame_branch_to. reflexivity.
                 --- subst f2. unfold frame_branch_to. simpl.
                     exact Hlen1.
Qed.

Lemma compile_assign_sequence_then_br_correct_pc :
  forall (env : compile_env) (env_ty : compile_type_env)
         (stmts : list corest_stmt),
    forall (s : st_state),
      assign_sequence_ok env env_ty s stmts ->
      forall (m : sasm_module) (fn : sasm_function) (f : sasm_frame)
             (fr : frame_stack) (input : value_stack) (mem : list Z)
             (cyc : Z) (prefix suffix : list sasm_instr)
             (depth target : Z),
        compile_env_injective env ->
        compile_env_nonneg env ->
        compile_env_fits_frame env f ->
        lookup_function m f.(frame_func_idx) = Some fn ->
        fn.(sasm_body) =
          prefix ++ compile_stmts env env_ty stmts ++ [BR depth] ++ suffix ->
        f.(frame_pc) = instrs_total_size prefix ->
        pc_frame_env_matches env s.(st_vars) f ->
        List.nth_error f.(frame_block_stack) (Z.to_nat depth) = Some target ->
        exists (s_asm : runtime_state) (f_asm : sasm_frame)
               (s_core : st_state),
          multi_pc_step m
            {| rt_values := input; rt_frames := f :: fr;
               rt_memory := mem; rt_cycle_cnt := cyc |}
            s_asm /\
          star_corest_step stmts s nil s_core /\
          s_asm.(rt_frames) = f_asm :: fr /\
          s_asm.(rt_values) = input /\
          s_asm.(rt_memory) = mem /\
          pc_frame_env_matches env s_core.(st_vars) f_asm /\
          f_asm.(frame_block_stack) =
            List.skipn (Z.to_nat depth + 1) f.(frame_block_stack) /\
          f_asm.(frame_func_idx) = f.(frame_func_idx) /\
          f_asm.(frame_pc) = target.
Proof.
  intros env env_ty stmts s Hok m fn f fr input mem cyc prefix suffix
    depth target Hinj Hnonneg Hfit Hlook Hbody Hpc Henv Hnth.
  destruct (compile_assign_sequence_correct_pc env env_ty stmts s Hok
              m fn f fr input mem cyc prefix (BR depth :: suffix)
              Hinj Hnonneg Hfit Hlook Hbody Hpc Henv)
    as [s1 [f1 [s_core Hrest]]].
  destruct Hrest as
    (Hmulti1 & Hstar & Hframes1 & Hval1 & Hmem1 &
     Hrel1 & Hblock1 & Hfunc1 & Hpc1 & Hlen1).
  set (prefix_body := prefix ++ compile_stmts env env_ty stmts).
  assert (Hpc1' : f1.(frame_pc) = instrs_total_size prefix_body).
  { subst prefix_body.
    rewrite instrs_total_size_app.
    rewrite <- Hpc.
    exact Hpc1. }
  assert (Hbody_br :
    fn.(sasm_body) = prefix_body ++ BR depth :: suffix).
  { subst prefix_body.
    rewrite Hbody.
    repeat rewrite app_assoc.
    rewrite app_singleton_cons.
    reflexivity. }
  assert (Hlook1 : lookup_function m f1.(frame_func_idx) = Some fn).
  { rewrite Hfunc1. exact Hlook. }
  assert (Hfetch :
    fetch_frame_instr m f1 =
      Some (BR depth, f1.(frame_pc) + instr_size (BR depth))).
  { rewrite Hpc1'.
    apply fetch_frame_instr_app_exact with
      (fn := fn) (prefix := prefix_body) (i := BR depth) (rest := suffix);
      [exact Hlook1 | exact Hbody_br | exact Hpc1']. }
  assert (Hnth1 :
    List.nth_error f1.(frame_block_stack) (Z.to_nat depth) = Some target).
  { rewrite Hblock1. exact Hnth. }
  set (f2 := frame_branch_to f1 depth target).
  set (s2 := set_top_values_cycle s1 f2 s1.(rt_values)).
  assert (Hmulti2 : multi_pc_step m s1 s2).
  { subst s2 f2.
    eapply pc_br_multi with
      (rest := fr) (depth := depth) (target := target)
      (next := f1.(frame_pc) + instr_size (BR depth)).
    - exact Hframes1.
    - exact Hfetch.
    - exact Hnth1. }
  exists s2, f2, s_core.
  split.
  - eapply multi_pc_step_trans; [exact Hmulti1 | exact Hmulti2].
  - split; [exact Hstar |].
    split.
    + subst s2 f2. unfold set_top_values_cycle. rewrite Hframes1.
      reflexivity.
    + split.
      * subst s2. unfold set_top_values_cycle. rewrite Hframes1.
        exact Hval1.
      * split.
        -- subst s2. unfold set_top_values_cycle. rewrite Hframes1.
           exact Hmem1.
        -- split.
           ++ exact Hrel1.
           ++ split.
              ** subst f2. unfold frame_branch_to. rewrite Hblock1.
                 reflexivity.
              ** split.
                 --- subst f2. unfold frame_branch_to. rewrite Hfunc1.
                     reflexivity.
                 --- subst f2. unfold frame_branch_to. reflexivity.
Qed.

Lemma compile_if_condition_true_pc :
  forall (env : compile_env) (env_s : corest_eval_env)
         (cond : corest_expr)
         (m : sasm_module) (fn : sasm_function) (f : sasm_frame)
         (fr : frame_stack) (input : value_stack) (mem : list Z)
         (cyc : Z) (prefix rest : list sasm_instr),
    lookup_function m f.(frame_func_idx) = Some fn ->
    fn.(sasm_body) =
      prefix ++ compile_expr env cond ++ [I32_EQZ; BR_IF 0] ++ rest ->
    f.(frame_pc) = instrs_total_size prefix ->
    pc_frame_env_matches env env_s f ->
    pc_expr_supported cond = true ->
    pc_expr_safe env_s cond ->
    corest_eval_expr env_s cond = Some (ST_V_BOOL true) ->
    exists (s' : runtime_state) (f' : sasm_frame),
      multi_pc_step m
        {| rt_values := input; rt_frames := f :: fr;
           rt_memory := mem; rt_cycle_cnt := cyc |}
        s' /\
      s'.(rt_frames) = f' :: fr /\
      s'.(rt_values) = input /\
      s'.(rt_memory) = mem /\
      f'.(frame_locals) = f.(frame_locals) /\
      f'.(frame_func_idx) = f.(frame_func_idx) /\
      f'.(frame_block_stack) = f.(frame_block_stack) /\
      f'.(frame_pc) =
        f.(frame_pc) + instrs_total_size (compile_expr env cond) +
        instr_size I32_EQZ + instr_size (BR_IF 0).
Proof.
  intros env env_s cond m fn f fr input mem cyc prefix rest
    Hlook Hbody Hpc Henv Hsupport Hsafe Heval.
  destruct (compile_expr_correct_pc env env_s cond Hsupport
              (ST_V_BOOL true) Heval
              m fn f fr input mem cyc prefix
              ([I32_EQZ; BR_IF 0] ++ rest)
              Hlook Hbody Hpc Henv Hsafe Heval)
    as [s1 [n [Hmulti1 [Hpost1 Hn]]]].
  destruct Hpost1 as [Hval1 [Hframes1 Hmem1]].
  inversion Hn; subst n.
  set (f1 := set_frame_pc f
               (f.(frame_pc) + instrs_total_size (compile_expr env cond))).
  assert (Hframes1' : s1.(rt_frames) = f1 :: fr).
  { subst f1. exact Hframes1. }
  assert (Hbody_eqz :
    fn.(sasm_body) =
      (prefix ++ compile_expr env cond) ++ I32_EQZ :: BR_IF 0 :: rest).
  { rewrite Hbody. rewrite <- app_assoc. simpl. reflexivity. }
  assert (Hpc1 : f1.(frame_pc) =
                 instrs_total_size (prefix ++ compile_expr env cond)).
  { subst f1. simpl. rewrite Hpc. rewrite instrs_total_size_app. reflexivity. }
  assert (Hlook1 : lookup_function m f1.(frame_func_idx) = Some fn).
  { subst f1. simpl. exact Hlook. }
  assert (Hs1 :
    s1 =
      {| rt_values := V_I32 1 :: input; rt_frames := f1 :: fr;
         rt_memory := mem; rt_cycle_cnt := s1.(rt_cycle_cnt) |}).
  { destruct s1 as [vals frames memory cycles].
    simpl in Hval1, Hframes1, Hmem1.
    subst vals. subst frames. subst memory. reflexivity. }
  set (f2 :=
    set_frame_pc f1
      (instrs_total_size (prefix ++ compile_expr env cond) +
       instr_size I32_EQZ + instr_size (BR_IF 0))).
  assert (Hmulti2 :
    multi_pc_step m s1
      {| rt_values := input; rt_frames := f2 :: fr;
         rt_memory := mem; rt_cycle_cnt := s1.(rt_cycle_cnt) + 2 |}).
  { subst f2.
    rewrite Hs1.
    eapply pc_eqz_brif_nonzero_fallthrough_multi with
      (fn := fn) (f := f1) (fr := fr) (input := input) (mem := mem)
      (cyc := s1.(rt_cycle_cnt)) (n := 1)
      (prefix := prefix ++ compile_expr env cond) (rest := rest).
    - exact Hlook1.
    - exact Hbody_eqz.
    - exact Hpc1.
    - discriminate. }
  exists {| rt_values := input; rt_frames := f2 :: fr;
            rt_memory := mem; rt_cycle_cnt := s1.(rt_cycle_cnt) + 2 |}, f2.
  split.
  - eapply multi_pc_step_trans; [exact Hmulti1 | exact Hmulti2].
  - split; [reflexivity |].
    split; [reflexivity |].
    split; [reflexivity |].
    split.
    + subst f2 f1. simpl. reflexivity.
    + split.
      * subst f2 f1. simpl. reflexivity.
      * split.
        -- subst f2 f1. simpl. reflexivity.
        -- subst f2 f1.
           simpl.
           rewrite Hpc.
           rewrite instrs_total_size_app.
           reflexivity.
Qed.

Lemma compile_if_condition_false_pc :
  forall (env : compile_env) (env_s : corest_eval_env)
         (cond : corest_expr)
         (m : sasm_module) (fn : sasm_function) (f : sasm_frame)
         (fr : frame_stack) (input : value_stack) (mem : list Z)
         (cyc : Z) (prefix rest : list sasm_instr) (target : Z),
    lookup_function m f.(frame_func_idx) = Some fn ->
    fn.(sasm_body) =
      prefix ++ compile_expr env cond ++ [I32_EQZ; BR_IF 0] ++ rest ->
    f.(frame_pc) = instrs_total_size prefix ->
    pc_frame_env_matches env env_s f ->
    pc_expr_supported cond = true ->
    pc_expr_safe env_s cond ->
    corest_eval_expr env_s cond = Some (ST_V_BOOL false) ->
    List.nth_error f.(frame_block_stack) 0 = Some target ->
    exists (s' : runtime_state) (f' : sasm_frame),
      multi_pc_step m
        {| rt_values := input; rt_frames := f :: fr;
           rt_memory := mem; rt_cycle_cnt := cyc |}
        s' /\
      s'.(rt_frames) = f' :: fr /\
      s'.(rt_values) = input /\
      s'.(rt_memory) = mem /\
      f'.(frame_locals) = f.(frame_locals) /\
      f'.(frame_func_idx) = f.(frame_func_idx) /\
      f'.(frame_block_stack) = List.skipn 1 f.(frame_block_stack) /\
      f'.(frame_pc) = target.
Proof.
  intros env env_s cond m fn f fr input mem cyc prefix rest target
    Hlook Hbody Hpc Henv Hsupport Hsafe Heval Hnth.
  destruct (compile_expr_correct_pc env env_s cond Hsupport
              (ST_V_BOOL false) Heval
              m fn f fr input mem cyc prefix
              ([I32_EQZ; BR_IF 0] ++ rest)
              Hlook Hbody Hpc Henv Hsafe Heval)
    as [s1 [n [Hmulti1 [Hpost1 Hn]]]].
  destruct Hpost1 as [Hval1 [Hframes1 Hmem1]].
  inversion Hn; subst n.
  set (f1 := set_frame_pc f
               (f.(frame_pc) + instrs_total_size (compile_expr env cond))).
  assert (Hframes1' : s1.(rt_frames) = f1 :: fr).
  { subst f1. exact Hframes1. }
  assert (Hbody_eqz :
    fn.(sasm_body) =
      (prefix ++ compile_expr env cond) ++ I32_EQZ :: BR_IF 0 :: rest).
  { rewrite Hbody. rewrite <- app_assoc. simpl. reflexivity. }
  assert (Hpc1 : f1.(frame_pc) =
                 instrs_total_size (prefix ++ compile_expr env cond)).
  { subst f1. simpl. rewrite Hpc. rewrite instrs_total_size_app. reflexivity. }
  assert (Hlook1 : lookup_function m f1.(frame_func_idx) = Some fn).
  { subst f1. simpl. exact Hlook. }
  assert (Hs1 :
    s1 =
      {| rt_values := V_I32 0 :: input; rt_frames := f1 :: fr;
         rt_memory := mem; rt_cycle_cnt := s1.(rt_cycle_cnt) |}).
  { destruct s1 as [vals frames memory cycles].
    simpl in Hval1, Hframes1, Hmem1.
    subst vals. subst frames. subst memory. reflexivity. }
  assert (Hnth1 : List.nth_error f1.(frame_block_stack) 0 = Some target).
  { subst f1. simpl. exact Hnth. }
  set (f2 := frame_branch_to f1 0 target).
  assert (Hmulti2 :
    multi_pc_step m s1
      {| rt_values := input; rt_frames := f2 :: fr;
         rt_memory := mem; rt_cycle_cnt := s1.(rt_cycle_cnt) + 2 |}).
  { subst f2.
    rewrite Hs1.
    eapply pc_eqz_brif_zero_jump_multi_depth with
      (fn := fn) (f := f1) (fr := fr) (input := input) (mem := mem)
      (cyc := s1.(rt_cycle_cnt)) (prefix := prefix ++ compile_expr env cond)
      (rest := rest) (target := target).
    - exact Hlook1.
    - exact Hbody_eqz.
    - exact Hpc1.
    - exact Hnth1. }
  exists {| rt_values := input; rt_frames := f2 :: fr;
            rt_memory := mem; rt_cycle_cnt := s1.(rt_cycle_cnt) + 2 |}, f2.
  split.
  - eapply multi_pc_step_trans; [exact Hmulti1 | exact Hmulti2].
  - split; [reflexivity |].
    split; [reflexivity |].
    split; [reflexivity |].
    split.
    + subst f2 f1. unfold frame_branch_to. simpl. reflexivity.
    + split.
      * subst f2 f1. unfold frame_branch_to. simpl. reflexivity.
      * split.
        -- subst f2 f1. unfold frame_branch_to. simpl. reflexivity.
        -- subst f2 f1. unfold frame_branch_to. simpl. reflexivity.
Qed.

Lemma compile_condition_false_pc :
  forall (env : compile_env) (env_s : corest_eval_env)
         (cond : corest_expr)
         (m : sasm_module) (fn : sasm_function) (f : sasm_frame)
         (fr : frame_stack) (input : value_stack) (mem : list Z)
         (cyc : Z) (prefix rest : list sasm_instr)
         (depth target : Z),
    lookup_function m f.(frame_func_idx) = Some fn ->
    fn.(sasm_body) =
      prefix ++ compile_expr env cond ++ [I32_EQZ; BR_IF depth] ++ rest ->
    f.(frame_pc) = instrs_total_size prefix ->
    pc_frame_env_matches env env_s f ->
    pc_expr_supported cond = true ->
    pc_expr_safe env_s cond ->
    corest_eval_expr env_s cond = Some (ST_V_BOOL false) ->
    List.nth_error f.(frame_block_stack) (Z.to_nat depth) = Some target ->
    exists (s' : runtime_state) (f' : sasm_frame),
      multi_pc_step m
        {| rt_values := input; rt_frames := f :: fr;
           rt_memory := mem; rt_cycle_cnt := cyc |}
        s' /\
      s'.(rt_frames) = f' :: fr /\
      s'.(rt_values) = input /\
      s'.(rt_memory) = mem /\
      f'.(frame_locals) = f.(frame_locals) /\
      f'.(frame_func_idx) = f.(frame_func_idx) /\
      f'.(frame_block_stack) =
        List.skipn (Z.to_nat depth + 1) f.(frame_block_stack) /\
      f'.(frame_pc) = target.
Proof.
  intros env env_s cond m fn f fr input mem cyc prefix rest depth target
    Hlook Hbody Hpc Henv Hsupport Hsafe Heval Hnth.
  destruct (compile_expr_correct_pc env env_s cond Hsupport
              (ST_V_BOOL false) Heval
              m fn f fr input mem cyc prefix
              ([I32_EQZ; BR_IF depth] ++ rest)
              Hlook Hbody Hpc Henv Hsafe Heval)
    as [s1 [n [Hmulti1 [Hpost1 Hn]]]].
  destruct Hpost1 as [Hval1 [Hframes1 Hmem1]].
  inversion Hn; subst n.
  set (f1 := set_frame_pc f
               (f.(frame_pc) + instrs_total_size (compile_expr env cond))).
  assert (Hframes1' : s1.(rt_frames) = f1 :: fr).
  { subst f1. exact Hframes1. }
  assert (Hbody_eqz :
    fn.(sasm_body) =
      (prefix ++ compile_expr env cond) ++ I32_EQZ :: BR_IF depth :: rest).
  { rewrite Hbody. rewrite <- app_assoc. simpl. reflexivity. }
  assert (Hpc1 : f1.(frame_pc) =
                 instrs_total_size (prefix ++ compile_expr env cond)).
  { subst f1. simpl. rewrite Hpc. rewrite instrs_total_size_app. reflexivity. }
  assert (Hlook1 : lookup_function m f1.(frame_func_idx) = Some fn).
  { subst f1. simpl. exact Hlook. }
  assert (Hs1 :
    s1 =
      {| rt_values := V_I32 0 :: input; rt_frames := f1 :: fr;
         rt_memory := mem; rt_cycle_cnt := s1.(rt_cycle_cnt) |}).
  { destruct s1 as [vals frames memory cycles].
    simpl in Hval1, Hframes1, Hmem1.
    subst vals. subst frames. subst memory. reflexivity. }
  assert (Hnth1 :
    List.nth_error f1.(frame_block_stack) (Z.to_nat depth) = Some target).
  { subst f1. simpl. exact Hnth. }
  set (f2 := frame_branch_to f1 depth target).
  assert (Hmulti2 :
    multi_pc_step m s1
      {| rt_values := input; rt_frames := f2 :: fr;
         rt_memory := mem; rt_cycle_cnt := s1.(rt_cycle_cnt) + 2 |}).
  { subst f2.
    rewrite Hs1.
    eapply pc_eqz_brif_zero_jump_multi_depth with
      (fn := fn) (f := f1) (fr := fr) (input := input) (mem := mem)
      (cyc := s1.(rt_cycle_cnt)) (prefix := prefix ++ compile_expr env cond)
      (rest := rest) (depth := depth) (target := target).
    - exact Hlook1.
    - exact Hbody_eqz.
    - exact Hpc1.
    - exact Hnth1. }
  exists {| rt_values := input; rt_frames := f2 :: fr;
            rt_memory := mem; rt_cycle_cnt := s1.(rt_cycle_cnt) + 2 |}, f2.
  split.
  - eapply multi_pc_step_trans; [exact Hmulti1 | exact Hmulti2].
  - split; [reflexivity |].
    split; [reflexivity |].
    split; [reflexivity |].
    split.
    + subst f2 f1. unfold frame_branch_to. simpl. reflexivity.
    + split.
      * subst f2 f1. unfold frame_branch_to. simpl. reflexivity.
      * split.
        -- subst f2 f1. unfold frame_branch_to. reflexivity.
        -- subst f2 f1. unfold frame_branch_to. reflexivity.
Qed.

Lemma compile_condition_true_pc :
  forall (env : compile_env) (env_s : corest_eval_env)
         (cond : corest_expr)
         (m : sasm_module) (fn : sasm_function) (f : sasm_frame)
         (fr : frame_stack) (input : value_stack) (mem : list Z)
         (cyc : Z) (prefix rest : list sasm_instr) (depth : Z),
    lookup_function m f.(frame_func_idx) = Some fn ->
    fn.(sasm_body) =
      prefix ++ compile_expr env cond ++ [I32_EQZ; BR_IF depth] ++ rest ->
    f.(frame_pc) = instrs_total_size prefix ->
    pc_frame_env_matches env env_s f ->
    pc_expr_supported cond = true ->
    pc_expr_safe env_s cond ->
    corest_eval_expr env_s cond = Some (ST_V_BOOL true) ->
    exists (s' : runtime_state) (f' : sasm_frame),
      multi_pc_step m
        {| rt_values := input; rt_frames := f :: fr;
           rt_memory := mem; rt_cycle_cnt := cyc |}
        s' /\
      s'.(rt_frames) = f' :: fr /\
      s'.(rt_values) = input /\
      s'.(rt_memory) = mem /\
      f'.(frame_locals) = f.(frame_locals) /\
      f'.(frame_func_idx) = f.(frame_func_idx) /\
      f'.(frame_block_stack) = f.(frame_block_stack) /\
      f'.(frame_pc) =
        f.(frame_pc) + instrs_total_size (compile_expr env cond) +
        instr_size I32_EQZ + instr_size (BR_IF depth).
Proof.
  intros env env_s cond m fn f fr input mem cyc prefix rest depth
    Hlook Hbody Hpc Henv Hsupport Hsafe Heval.
  destruct (compile_expr_correct_pc env env_s cond Hsupport
              (ST_V_BOOL true) Heval
              m fn f fr input mem cyc prefix
              ([I32_EQZ; BR_IF depth] ++ rest)
              Hlook Hbody Hpc Henv Hsafe Heval)
    as [s1 [n [Hmulti1 [Hpost1 Hn]]]].
  destruct Hpost1 as [Hval1 [Hframes1 Hmem1]].
  inversion Hn; subst n.
  set (f1 := set_frame_pc f
               (f.(frame_pc) + instrs_total_size (compile_expr env cond))).
  assert (Hframes1' : s1.(rt_frames) = f1 :: fr).
  { subst f1. exact Hframes1. }
  assert (Hbody_eqz :
    fn.(sasm_body) =
      (prefix ++ compile_expr env cond) ++ I32_EQZ :: BR_IF depth :: rest).
  { rewrite Hbody. rewrite <- app_assoc. simpl. reflexivity. }
  assert (Hpc1 : f1.(frame_pc) =
                 instrs_total_size (prefix ++ compile_expr env cond)).
  { subst f1. simpl. rewrite Hpc. rewrite instrs_total_size_app. reflexivity. }
  assert (Hlook1 : lookup_function m f1.(frame_func_idx) = Some fn).
  { subst f1. simpl. exact Hlook. }
  assert (Hs1 :
    s1 =
      {| rt_values := V_I32 1 :: input; rt_frames := f1 :: fr;
         rt_memory := mem; rt_cycle_cnt := s1.(rt_cycle_cnt) |}).
  { destruct s1 as [vals frames memory cycles].
    simpl in Hval1, Hframes1, Hmem1.
    subst vals. subst frames. subst memory. reflexivity. }
  set (f2 := set_frame_pc f1
    (instrs_total_size (prefix ++ compile_expr env cond) +
     instr_size I32_EQZ + instr_size (BR_IF depth))).
  assert (Hmulti2 :
    multi_pc_step m s1
      {| rt_values := input; rt_frames := f2 :: fr;
         rt_memory := mem; rt_cycle_cnt := s1.(rt_cycle_cnt) + 1 + 1 |}).
  { rewrite Hs1.
    subst f2.
    eapply pc_eqz_brif_nonzero_fallthrough_multi_depth with
      (fn := fn) (f := f1) (fr := fr) (input := input) (mem := mem)
      (cyc := s1.(rt_cycle_cnt)) (depth := depth) (n := 1)
      (prefix := prefix ++ compile_expr env cond) (rest := rest).
    - exact Hlook1.
    - exact Hbody_eqz.
    - exact Hpc1.
    - discriminate. }
  exists {| rt_values := input; rt_frames := f2 :: fr;
            rt_memory := mem; rt_cycle_cnt := s1.(rt_cycle_cnt) + 1 + 1 |}, f2.
  split.
  - eapply multi_pc_step_trans; [exact Hmulti1 | exact Hmulti2].
  - split; [reflexivity |].
    split; [reflexivity |].
    split; [reflexivity |].
    split.
    + subst f2 f1. simpl. reflexivity.
    + split.
      * subst f2 f1. simpl. reflexivity.
      * split.
        -- subst f2 f1. simpl. reflexivity.
        -- subst f2 f1.
           simpl.
           rewrite instrs_total_size_app.
           rewrite <- Hpc.
           ring.
Qed.

Lemma compile_if_true_correct_pc :
  forall (env : compile_env) (env_ty : compile_type_env)
         (cond : corest_expr) (then_body else_body : list corest_stmt)
         (s : st_state),
    pc_stmts_spec env env_ty s then_body ->
    corest_eval_expr s.(st_vars) cond = Some (ST_V_BOOL true) ->
    pc_expr_supported cond = true ->
    pc_expr_safe s.(st_vars) cond ->
    forall (m : sasm_module) (fn : sasm_function) (f : sasm_frame)
           (fr : frame_stack) (input : value_stack) (mem : list Z)
           (cyc : Z) (prefix suffix : list sasm_instr),
      compile_env_injective env ->
      compile_env_nonneg env ->
      compile_env_fits_frame env f ->
      lookup_function m f.(frame_func_idx) = Some fn ->
      fn.(sasm_body) =
        prefix ++ compile_stmt env env_ty
          (CS_IF cond then_body else_body) ++ suffix ->
      f.(frame_pc) = instrs_total_size prefix ->
      pc_frame_env_matches env s.(st_vars) f ->
      exists (s_asm : runtime_state) (f_asm : sasm_frame)
             (s_core : st_state),
        multi_pc_step m
          {| rt_values := input; rt_frames := f :: fr;
             rt_memory := mem; rt_cycle_cnt := cyc |}
          s_asm /\
        star_corest_step
          [CS_IF cond then_body else_body] s nil s_core /\
        s_asm.(rt_frames) = f_asm :: fr /\
        s_asm.(rt_values) = input /\
        s_asm.(rt_memory) = mem /\
        pc_frame_env_matches env s_core.(st_vars) f_asm /\
        f_asm.(frame_block_stack) = f.(frame_block_stack) /\
        f_asm.(frame_func_idx) = f.(frame_func_idx) /\
        f_asm.(frame_pc) =
          f.(frame_pc) +
          instrs_total_size
            (compile_stmt env env_ty (CS_IF cond then_body else_body)) /\
        List.length f_asm.(frame_locals) = List.length f.(frame_locals).
Proof.
  intros env env_ty cond then_body else_body s
    Hthen Hcond Hsupport Hsafe
    m fn f fr input mem cyc prefix suffix
    Hinj Hnonneg Hfit Hlook Hbody Hpc Henv.
  set (c := compile_expr env cond) in *.
  set (t := compile_stmts env env_ty then_body) in *.
  set (e := compile_stmts env env_ty else_body) in *.
  set (inner := c ++ [I32_EQZ; BR_IF 0] ++ t ++ [BR 1]) in *.
  set (outer :=
         [BLOCK (instr_seq_size inner)] ++ inner ++ e ++ [BR 0]) in *.
  set (ifcode := [BLOCK (instr_seq_size outer)] ++ outer) in *.
  assert (Hifshape :
    compile_stmt env env_ty (CS_IF cond then_body else_body) = ifcode).
  { subst ifcode outer inner c t e. reflexivity. }
  rewrite Hifshape in Hbody.
  assert (Hbody_blocks :
    fn.(sasm_body) =
      prefix ++ BLOCK (instr_seq_size outer) ::
      BLOCK (instr_seq_size inner) ::
      (inner ++ e ++ [BR 0]) ++ suffix).
  { rewrite Hbody. subst ifcode outer. simpl. reflexivity. }
  destruct (pc_enter_two_blocks m fn f fr input mem cyc prefix
              (inner ++ e ++ [BR 0]) suffix
              (instr_seq_size outer) (instr_seq_size inner)
              Hlook Hbody_blocks Hpc)
    as [s2 [f2 Hrest2]].
  destruct Hrest2 as
    (Hmulti12 & Hframes2 & Hvalues2 & Hmem2 &
     Hlocals2 & Hfunc2 & Hpc2 & Hstack2).
  set (prefix_blocks :=
         prefix ++ [BLOCK (instr_seq_size outer);
                     BLOCK (instr_seq_size inner)]).
  assert (Hpc2' : f2.(frame_pc) = instrs_total_size prefix_blocks).
  { subst prefix_blocks.
    rewrite instrs_total_size_app.
    simpl.
    rewrite <- Hpc.
    exact Hpc2. }
  assert (Hbody_cond :
    fn.(sasm_body) =
      prefix_blocks ++ c ++ [I32_EQZ; BR_IF 0] ++
      (t ++ [BR 1] ++ e ++ [BR 0] ++ suffix)).
  { subst prefix_blocks.
    rewrite Hbody_blocks.
    subst inner outer ifcode.
    repeat rewrite <- app_assoc.
    simpl.
    repeat rewrite app_assoc.
    simpl.
    reflexivity. }
  assert (Hlook2 : lookup_function m f2.(frame_func_idx) = Some fn).
  { rewrite Hfunc2. exact Hlook. }
  assert (Henv2 : pc_frame_env_matches env s.(st_vars) f2).
  { eapply pc_frame_env_matches_locals_eq; [exact Hlocals2 | exact Henv]. }
  assert (Hfit2 : compile_env_fits_frame env f2).
  { eapply compile_env_fits_frame_locals_eq; [exact Hlocals2 | exact Hfit]. }
  destruct (compile_if_condition_true_pc env s.(st_vars) cond
              m fn f2 fr input mem s2.(rt_cycle_cnt) prefix_blocks
              (t ++ [BR 1] ++ e ++ [BR 0] ++ suffix)
              Hlook2 Hbody_cond Hpc2' Henv2 Hsupport Hsafe Hcond)
    as [s3 [f3 Hrest3]].
  destruct Hrest3 as
    (Hmulti23 & Hframes3 & Hvalues3 & Hmem3 &
     Hlocals3 & Hfunc3 & Hstack3 & Hpc3).
  set (prefix_then := prefix_blocks ++ c ++ [I32_EQZ; BR_IF 0]).
  set (target_outer := f.(frame_pc) + 5 + instr_seq_size outer).
  assert (Hbody_then :
    fn.(sasm_body) =
      prefix_then ++ t ++ [BR 1] ++ (e ++ [BR 0] ++ suffix)).
  { rewrite Hbody_cond. subst prefix_then.
    repeat rewrite app_assoc.
    reflexivity. }
  assert (Hpc3' : f3.(frame_pc) = instrs_total_size prefix_then).
  { rewrite Hpc3. subst prefix_then. subst c.
    rewrite instrs_total_size_app.
    repeat rewrite instrs_total_size_app.
    simpl.
    rewrite Hpc2'.
    lia. }
  assert (Hlook3 : lookup_function m f3.(frame_func_idx) = Some fn).
  { rewrite Hfunc3. exact Hlook2. }
  assert (Henv3 : pc_frame_env_matches env s.(st_vars) f3).
  { eapply pc_frame_env_matches_locals_eq; [exact Hlocals3 | exact Henv2]. }
  assert (Hfit3 : compile_env_fits_frame env f3).
  { eapply compile_env_fits_frame_locals_eq; [exact Hlocals3 | exact Hfit2]. }
  assert (Hnth_then :
    List.nth_error f3.(frame_block_stack) 1 = Some target_outer).
  { rewrite Hstack3. rewrite Hstack2.
    subst target_outer.
    simpl.
    reflexivity. }
  destruct (compile_stmts_then_br_correct_pc env env_ty
              then_body s Hthen m fn f3 fr input mem s3.(rt_cycle_cnt)
              prefix_then (e ++ [BR 0] ++ suffix) 1 target_outer
              Hinj Hnonneg Hfit3 Hlook3 Hbody_then Hpc3' Henv3 Hnth_then)
    as [s4 [f4 [s_core Hrest4]]].
  destruct Hrest4 as
    (Hmulti34 & Hstar & Hframes4 & Hvalues4 & Hmem4 &
     Hrel4 & Hblock4 & Hfunc4 & Hpc4 & Hlen4).
  assert (Hs2 :
    s2 =
      {| rt_values := input; rt_frames := f2 :: fr;
         rt_memory := mem; rt_cycle_cnt := s2.(rt_cycle_cnt) |}).
  { destruct s2 as [vals frames memory cycles].
    simpl in Hvalues2, Hframes2, Hmem2.
    subst vals. subst frames. subst memory. reflexivity. }
  rewrite <- Hs2 in Hmulti23.
  assert (Hs3 :
    s3 =
      {| rt_values := input; rt_frames := f3 :: fr;
         rt_memory := mem; rt_cycle_cnt := s3.(rt_cycle_cnt) |}).
  { destruct s3 as [vals frames memory cycles].
    simpl in Hvalues3, Hframes3, Hmem3.
    subst vals. subst frames. subst memory. reflexivity. }
  rewrite <- Hs3 in Hmulti34.
  exists s4, f4, s_core.
  split.
  - eapply multi_pc_step_trans; [exact Hmulti12 |].
    eapply multi_pc_step_trans; [exact Hmulti23 | exact Hmulti34].
  - split.
    + eapply CsStar_step.
      * eapply Cs_if_true; exact Hcond.
      * change (star_corest_step (then_body ++ []) s nil s_core).
        rewrite app_nil_r.
        exact Hstar.
    + split; [exact Hframes4 |].
      split; [exact Hvalues4 |].
      split; [exact Hmem4 |].
      split; [exact Hrel4 |].
      split.
      * rewrite Hblock4. rewrite Hstack3. rewrite Hstack2. simpl.
        reflexivity.
      * split.
        -- rewrite Hfunc4. rewrite Hfunc3. exact Hfunc2.
        -- split.
           ++ rewrite Hpc4. subst target_outer.
              rewrite Hifshape.
              change (frame_pc f + 5 + instr_seq_size outer =
                      frame_pc f + (5 + instrs_total_size outer)).
              rewrite instr_seq_size_eq_total.
              lia.
           ++ rewrite Hlen4. rewrite Hlocals3. rewrite Hlocals2.
              reflexivity.
Qed.

Lemma compile_if_false_correct_pc :
  forall (env : compile_env) (env_ty : compile_type_env)
         (cond : corest_expr) (then_body else_body : list corest_stmt)
         (s : st_state),
    pc_stmts_spec env env_ty s else_body ->
    corest_eval_expr s.(st_vars) cond = Some (ST_V_BOOL false) ->
    pc_expr_supported cond = true ->
    pc_expr_safe s.(st_vars) cond ->
    forall (m : sasm_module) (fn : sasm_function) (f : sasm_frame)
           (fr : frame_stack) (input : value_stack) (mem : list Z)
           (cyc : Z) (prefix suffix : list sasm_instr),
      compile_env_injective env ->
      compile_env_nonneg env ->
      compile_env_fits_frame env f ->
      lookup_function m f.(frame_func_idx) = Some fn ->
      fn.(sasm_body) =
        prefix ++ compile_stmt env env_ty
          (CS_IF cond then_body else_body) ++ suffix ->
      f.(frame_pc) = instrs_total_size prefix ->
      pc_frame_env_matches env s.(st_vars) f ->
      exists (s_asm : runtime_state) (f_asm : sasm_frame)
             (s_core : st_state),
        multi_pc_step m
          {| rt_values := input; rt_frames := f :: fr;
             rt_memory := mem; rt_cycle_cnt := cyc |}
          s_asm /\
        star_corest_step
          [CS_IF cond then_body else_body] s nil s_core /\
        s_asm.(rt_frames) = f_asm :: fr /\
        s_asm.(rt_values) = input /\
        s_asm.(rt_memory) = mem /\
        pc_frame_env_matches env s_core.(st_vars) f_asm /\
        f_asm.(frame_block_stack) = f.(frame_block_stack) /\
        f_asm.(frame_func_idx) = f.(frame_func_idx) /\
        f_asm.(frame_pc) =
          f.(frame_pc) +
          instrs_total_size
            (compile_stmt env env_ty (CS_IF cond then_body else_body)) /\
        List.length f_asm.(frame_locals) = List.length f.(frame_locals).
Proof.
  intros env env_ty cond then_body else_body s
    Helse Hcond Hsupport Hsafe
    m fn f fr input mem cyc prefix suffix
    Hinj Hnonneg Hfit Hlook Hbody Hpc Henv.
  set (c := compile_expr env cond) in *.
  set (t := compile_stmts env env_ty then_body) in *.
  set (e := compile_stmts env env_ty else_body) in *.
  set (inner := c ++ [I32_EQZ; BR_IF 0] ++ t ++ [BR 1]) in *.
  set (outer :=
         [BLOCK (instr_seq_size inner)] ++ inner ++ e ++ [BR 0]) in *.
  set (ifcode := [BLOCK (instr_seq_size outer)] ++ outer) in *.
  assert (Hifshape :
    compile_stmt env env_ty (CS_IF cond then_body else_body) = ifcode).
  { subst ifcode outer inner c t e. reflexivity. }
  rewrite Hifshape in Hbody.
  assert (Hbody_blocks :
    fn.(sasm_body) =
      prefix ++ BLOCK (instr_seq_size outer) ::
      BLOCK (instr_seq_size inner) ::
      (inner ++ e ++ [BR 0]) ++ suffix).
  { rewrite Hbody. subst ifcode outer. simpl. reflexivity. }
  destruct (pc_enter_two_blocks m fn f fr input mem cyc prefix
              (inner ++ e ++ [BR 0]) suffix
              (instr_seq_size outer) (instr_seq_size inner)
              Hlook Hbody_blocks Hpc)
    as [s2 [f2 Hrest2]].
  destruct Hrest2 as
    (Hmulti12 & Hframes2 & Hvalues2 & Hmem2 &
     Hlocals2 & Hfunc2 & Hpc2 & Hstack2).
  set (prefix_blocks :=
         prefix ++ [BLOCK (instr_seq_size outer);
                     BLOCK (instr_seq_size inner)]).
  assert (Hpc2' : f2.(frame_pc) = instrs_total_size prefix_blocks).
  { subst prefix_blocks.
    rewrite instrs_total_size_app.
    simpl.
    rewrite <- Hpc.
    exact Hpc2. }
  assert (Hbody_cond :
    fn.(sasm_body) =
      prefix_blocks ++ c ++ [I32_EQZ; BR_IF 0] ++
      (t ++ [BR 1] ++ e ++ [BR 0] ++ suffix)).
  { subst prefix_blocks.
    rewrite Hbody_blocks.
    subst inner outer ifcode.
    repeat rewrite <- app_assoc.
    simpl.
    repeat rewrite app_assoc.
    simpl.
    reflexivity. }
  assert (Hlook2 : lookup_function m f2.(frame_func_idx) = Some fn).
  { rewrite Hfunc2. exact Hlook. }
  assert (Henv2 : pc_frame_env_matches env s.(st_vars) f2).
  { eapply pc_frame_env_matches_locals_eq; [exact Hlocals2 | exact Henv]. }
  assert (Hfit2 : compile_env_fits_frame env f2).
  { eapply compile_env_fits_frame_locals_eq; [exact Hlocals2 | exact Hfit]. }
  set (target_inner := f.(frame_pc) + 10 + instr_seq_size inner).
  assert (Hnth_inner :
    List.nth_error f2.(frame_block_stack) 0 = Some target_inner).
  { rewrite Hstack2. subst target_inner. simpl. reflexivity. }
  destruct (compile_if_condition_false_pc env s.(st_vars) cond
              m fn f2 fr input mem s2.(rt_cycle_cnt) prefix_blocks
              (t ++ [BR 1] ++ e ++ [BR 0] ++ suffix) target_inner
              Hlook2 Hbody_cond Hpc2' Henv2 Hsupport Hsafe Hcond Hnth_inner)
    as [s3 [f3 Hrest3]].
  destruct Hrest3 as
    (Hmulti23 & Hframes3 & Hvalues3 & Hmem3 &
     Hlocals3 & Hfunc3 & Hstack3 & Hpc3).
  set (prefix_else := prefix_blocks ++ c ++ [I32_EQZ; BR_IF 0] ++ t ++ [BR 1]).
  set (target_outer := f.(frame_pc) + 5 + instr_seq_size outer).
  assert (Hbody_else :
    fn.(sasm_body) =
      prefix_else ++ e ++ [BR 0] ++ suffix).
  { rewrite Hbody_cond. subst prefix_else.
    repeat rewrite app_assoc.
    reflexivity. }
  assert (Hpc3' : f3.(frame_pc) = instrs_total_size prefix_else).
  { rewrite Hpc3.
    subst prefix_else target_inner. subst inner. subst prefix_blocks.
    rewrite instr_seq_size_eq_total.
    repeat rewrite instrs_total_size_app.
    simpl.
    rewrite Hpc.
    ring. }
  assert (Hlook3 : lookup_function m f3.(frame_func_idx) = Some fn).
  { rewrite Hfunc3. exact Hlook2. }
  assert (Henv3 : pc_frame_env_matches env s.(st_vars) f3).
  { eapply pc_frame_env_matches_locals_eq; [exact Hlocals3 | exact Henv2]. }
  assert (Hfit3 : compile_env_fits_frame env f3).
  { eapply compile_env_fits_frame_locals_eq; [exact Hlocals3 | exact Hfit2]. }
  assert (Hnth_else :
    List.nth_error f3.(frame_block_stack) 0 = Some target_outer).
  { rewrite Hstack3. rewrite Hstack2.
    subst target_outer.
    simpl.
    reflexivity. }
  destruct (compile_stmts_then_br_correct_pc env env_ty
              else_body s Helse m fn f3 fr input mem s3.(rt_cycle_cnt)
              prefix_else suffix 0 target_outer
              Hinj Hnonneg Hfit3 Hlook3 Hbody_else Hpc3' Henv3 Hnth_else)
    as [s4 [f4 [s_core Hrest4]]].
  destruct Hrest4 as
    (Hmulti34 & Hstar & Hframes4 & Hvalues4 & Hmem4 &
     Hrel4 & Hblock4 & Hfunc4 & Hpc4 & Hlen4).
  assert (Hs2 :
    s2 =
      {| rt_values := input; rt_frames := f2 :: fr;
         rt_memory := mem; rt_cycle_cnt := s2.(rt_cycle_cnt) |}).
  { destruct s2 as [vals frames memory cycles].
    simpl in Hvalues2, Hframes2, Hmem2.
    subst vals. subst frames. subst memory. reflexivity. }
  rewrite <- Hs2 in Hmulti23.
  assert (Hs3 :
    s3 =
      {| rt_values := input; rt_frames := f3 :: fr;
         rt_memory := mem; rt_cycle_cnt := s3.(rt_cycle_cnt) |}).
  { destruct s3 as [vals frames memory cycles].
    simpl in Hvalues3, Hframes3, Hmem3.
    subst vals. subst frames. subst memory. reflexivity. }
  rewrite <- Hs3 in Hmulti34.
  exists s4, f4, s_core.
  split.
  - eapply multi_pc_step_trans; [exact Hmulti12 |].
    eapply multi_pc_step_trans; [exact Hmulti23 | exact Hmulti34].
  - split.
    + eapply CsStar_step.
      * eapply Cs_if_false; exact Hcond.
      * change (star_corest_step (else_body ++ []) s nil s_core).
        rewrite app_nil_r.
        exact Hstar.
    + split; [exact Hframes4 |].
      split; [exact Hvalues4 |].
      split; [exact Hmem4 |].
      split; [exact Hrel4 |].
      split.
      * rewrite Hblock4. rewrite Hstack3. rewrite Hstack2. simpl.
        reflexivity.
      * split.
        -- rewrite Hfunc4. rewrite Hfunc3. exact Hfunc2.
        -- split.
           ++ rewrite Hpc4. subst target_outer.
              rewrite Hifshape.
              change (frame_pc f + 5 + instr_seq_size outer =
                      frame_pc f + (5 + instrs_total_size outer)).
              rewrite instr_seq_size_eq_total.
              lia.
           ++ rewrite Hlen4. rewrite Hlocals3. rewrite Hlocals2.
              reflexivity.
Qed.

Lemma compile_if_correct_pc :
  forall (env : compile_env) (env_ty : compile_type_env)
         (cond : corest_expr) (then_body else_body : list corest_stmt)
         (s : st_state),
    pc_stmts_spec env env_ty s then_body ->
    pc_stmts_spec env env_ty s else_body ->
    forall (b : bool),
    corest_eval_expr s.(st_vars) cond = Some (ST_V_BOOL b) ->
    pc_expr_supported cond = true ->
    pc_expr_safe s.(st_vars) cond ->
    forall (m : sasm_module) (fn : sasm_function) (f : sasm_frame)
           (fr : frame_stack) (input : value_stack) (mem : list Z)
           (cyc : Z) (prefix suffix : list sasm_instr),
      compile_env_injective env ->
      compile_env_nonneg env ->
      compile_env_fits_frame env f ->
      lookup_function m f.(frame_func_idx) = Some fn ->
      fn.(sasm_body) =
        prefix ++ compile_stmt env env_ty
          (CS_IF cond then_body else_body) ++ suffix ->
      f.(frame_pc) = instrs_total_size prefix ->
      pc_frame_env_matches env s.(st_vars) f ->
      exists (s_asm : runtime_state) (f_asm : sasm_frame)
             (s_core : st_state),
        multi_pc_step m
          {| rt_values := input; rt_frames := f :: fr;
             rt_memory := mem; rt_cycle_cnt := cyc |}
          s_asm /\
        star_corest_step
          [CS_IF cond then_body else_body] s nil s_core /\
        s_asm.(rt_frames) = f_asm :: fr /\
        s_asm.(rt_values) = input /\
        s_asm.(rt_memory) = mem /\
        pc_frame_env_matches env s_core.(st_vars) f_asm /\
        f_asm.(frame_block_stack) = f.(frame_block_stack) /\
        f_asm.(frame_func_idx) = f.(frame_func_idx) /\
        f_asm.(frame_pc) =
          f.(frame_pc) +
          instrs_total_size
            (compile_stmt env env_ty (CS_IF cond then_body else_body)) /\
        List.length f_asm.(frame_locals) = List.length f.(frame_locals).
Proof.
  intros env env_ty cond then_body else_body s
    Hthen Helse b Hcond Hsupport Hsafe
    m fn f fr input mem cyc prefix suffix
    Hinj Hnonneg Hfit Hlook Hbody Hpc Henv.
  destruct b.
  - eapply compile_if_true_correct_pc; eauto.
  - eapply compile_if_false_correct_pc; eauto.
Qed.

Lemma compile_block_correct_pc :
  forall (env : compile_env) (env_ty : compile_type_env)
         (body : list corest_stmt) (s : st_state),
    pc_stmts_spec env env_ty s body ->
    forall (m : sasm_module) (fn : sasm_function) (f : sasm_frame)
           (fr : frame_stack) (input : value_stack) (mem : list Z)
           (cyc : Z) (prefix suffix : list sasm_instr),
      compile_env_injective env ->
      compile_env_nonneg env ->
      compile_env_fits_frame env f ->
      lookup_function m f.(frame_func_idx) = Some fn ->
      fn.(sasm_body) =
        prefix ++ compile_stmt env env_ty (CS_BLOCK body) ++ suffix ->
      f.(frame_pc) = instrs_total_size prefix ->
      pc_frame_env_matches env s.(st_vars) f ->
      exists (s_asm : runtime_state) (f_asm : sasm_frame)
             (s_core : st_state),
        multi_pc_step m
          {| rt_values := input; rt_frames := f :: fr;
             rt_memory := mem; rt_cycle_cnt := cyc |}
          s_asm /\
        star_corest_step [CS_BLOCK body] s nil s_core /\
        s_asm.(rt_frames) = f_asm :: fr /\
        s_asm.(rt_values) = input /\
        s_asm.(rt_memory) = mem /\
        pc_frame_env_matches env s_core.(st_vars) f_asm /\
        f_asm.(frame_block_stack) = f.(frame_block_stack) /\
        f_asm.(frame_func_idx) = f.(frame_func_idx) /\
        f_asm.(frame_pc) =
          f.(frame_pc) +
          instrs_total_size (compile_stmt env env_ty (CS_BLOCK body)) /\
        List.length f_asm.(frame_locals) = List.length f.(frame_locals).
Proof.
  intros env env_ty body s Hok m fn f fr input mem cyc prefix suffix
    Hinj Hnonneg Hfit Hlook Hbody Hpc Henv.
  change (fn.(sasm_body) =
          prefix ++ compile_stmts env env_ty body ++ suffix) in Hbody.
  destruct (Hok m fn f fr input mem cyc prefix suffix
              Hinj Hnonneg Hfit Hlook Hbody Hpc Henv)
    as [s_asm [f_asm [s_core Hrest]]].
  destruct Hrest as
    (Hmulti & Hstar & Hframes & Hvalues & Hmem &
     Hrel & Hblock & Hfunc & Hpc' & Hlen).
  exists s_asm, f_asm, s_core.
  split; [exact Hmulti |].
  split.
  - eapply CsStar_step.
    + eapply Cs_block.
    + change (star_corest_step (body ++ []) s nil s_core).
      rewrite app_nil_r.
      exact Hstar.
  - split; [exact Hframes |].
    split; [exact Hvalues |].
    split; [exact Hmem |].
    split; [exact Hrel |].
    split; [exact Hblock |].
    split; [exact Hfunc |].
    split.
    + change (f_asm.(frame_pc) =
        f.(frame_pc) + instrs_total_size (compile_stmts env env_ty body)).
      exact Hpc'.
    + exact Hlen.
Qed.

Lemma pc_stmts_spec_singleton :
  forall (env : compile_env) (env_ty : compile_type_env)
         (s : st_state) (stmt : corest_stmt),
    pc_stmts_spec env env_ty s [stmt] ->
    pc_stmt_spec env env_ty s stmt.
Proof.
  intros env env_ty s stmt Hspec.
  unfold pc_stmt_spec.
  intros m fn f fr input mem cyc prefix suffix
    Hinj Hnonneg Hfit Hlook Hbody Hpc Henv.
  rewrite <- (compile_stmts_singleton env env_ty stmt) in Hbody.
  destruct (Hspec m fn f fr input mem cyc prefix suffix
              Hinj Hnonneg Hfit Hlook Hbody Hpc Henv)
    as [s_asm [f_asm [s_core Hrest]]].
  destruct Hrest as
    (Hmulti & Hstar & Hframes & Hvalues & Hmem &
     Hrel & Hblock & Hfunc & Hpc' & Hlen).
  rewrite (compile_stmts_singleton env env_ty stmt) in Hpc'.
  exists s_asm, f_asm, s_core.
  repeat split; assumption.
Qed.

Lemma pc_stmt_spec_if :
  forall (env : compile_env) (env_ty : compile_type_env)
         (s : st_state) (cond : corest_expr)
         (then_body else_body : list corest_stmt) (b : bool),
    corest_eval_expr s.(st_vars) cond = Some (ST_V_BOOL b) ->
    pc_expr_supported cond = true ->
    pc_expr_safe s.(st_vars) cond ->
    pc_stmts_spec env env_ty s then_body ->
    pc_stmts_spec env env_ty s else_body ->
    pc_stmt_spec env env_ty s (CS_IF cond then_body else_body).
Proof.
  intros env env_ty s cond then_body else_body b
    Heval Hsupport Hsafe Hthen Helse.
  unfold pc_stmt_spec.
  intros m fn f fr input mem cyc prefix suffix
    Hinj Hnonneg Hfit Hlook Hbody Hpc Henv.
  exact (compile_if_correct_pc env env_ty cond then_body else_body s
           Hthen Helse b Heval Hsupport Hsafe
           m fn f fr input mem cyc prefix suffix
           Hinj Hnonneg Hfit Hlook Hbody Hpc Henv).
Qed.

Lemma pc_stmt_spec_if_true :
  forall (env : compile_env) (env_ty : compile_type_env)
         (s : st_state) (cond : corest_expr)
         (then_body else_body : list corest_stmt),
    corest_eval_expr s.(st_vars) cond = Some (ST_V_BOOL true) ->
    pc_expr_supported cond = true ->
    pc_expr_safe s.(st_vars) cond ->
    pc_stmts_spec env env_ty s then_body ->
    pc_stmt_spec env env_ty s (CS_IF cond then_body else_body).
Proof.
  intros env env_ty s cond then_body else_body
    Heval Hsupport Hsafe Hthen.
  unfold pc_stmt_spec.
  intros m fn f fr input mem cyc prefix suffix
    Hinj Hnonneg Hfit Hlook Hbody Hpc Henv.
  exact (compile_if_true_correct_pc env env_ty cond then_body else_body s
           Hthen Heval Hsupport Hsafe
           m fn f fr input mem cyc prefix suffix
           Hinj Hnonneg Hfit Hlook Hbody Hpc Henv).
Qed.

Lemma pc_stmt_spec_if_false :
  forall (env : compile_env) (env_ty : compile_type_env)
         (s : st_state) (cond : corest_expr)
         (then_body else_body : list corest_stmt),
    corest_eval_expr s.(st_vars) cond = Some (ST_V_BOOL false) ->
    pc_expr_supported cond = true ->
    pc_expr_safe s.(st_vars) cond ->
    pc_stmts_spec env env_ty s else_body ->
    pc_stmt_spec env env_ty s (CS_IF cond then_body else_body).
Proof.
  intros env env_ty s cond then_body else_body
    Heval Hsupport Hsafe Helse.
  unfold pc_stmt_spec.
  intros m fn f fr input mem cyc prefix suffix
    Hinj Hnonneg Hfit Hlook Hbody Hpc Henv.
  exact (compile_if_false_correct_pc env env_ty cond then_body else_body s
           Helse Heval Hsupport Hsafe
           m fn f fr input mem cyc prefix suffix
           Hinj Hnonneg Hfit Hlook Hbody Hpc Henv).
Qed.

Lemma pc_stmt_spec_block :
  forall (env : compile_env) (env_ty : compile_type_env)
         (s : st_state) (body : list corest_stmt),
    pc_stmts_spec env env_ty s body ->
    pc_stmt_spec env env_ty s (CS_BLOCK body).
Proof.
  intros env env_ty s body Hbody_spec.
  unfold pc_stmt_spec.
  intros m fn f fr input mem cyc prefix suffix
    Hinj Hnonneg Hfit Hlook Hbody Hpc Henv.
  exact (compile_block_correct_pc env env_ty body s Hbody_spec
           m fn f fr input mem cyc prefix suffix
           Hinj Hnonneg Hfit Hlook Hbody Hpc Henv).
Qed.

Lemma pc_stmt_spec_assign :
  forall (env : compile_env) (env_ty : compile_type_env)
         (s : st_state) (x : ident) (e : corest_expr),
    assign_sequence_ok env env_ty s [CS_ASSIGN x e] ->
    pc_stmt_spec env env_ty s (CS_ASSIGN x e).
Proof.
  intros env env_ty s x e Hok.
  apply pc_stmts_spec_singleton.
  apply assign_sequence_pc_stmts_spec.
  exact Hok.
Qed.

Inductive pc_while_trace (env : compile_env) (env_ty : compile_type_env)
          (cond : corest_expr) (body : list corest_stmt)
  : st_state -> st_state -> Prop :=
  | pc_while_trace_stop : forall (s : st_state),
      corest_eval_expr s.(st_vars) cond = Some (ST_V_BOOL false) ->
      pc_expr_supported cond = true ->
      pc_expr_safe s.(st_vars) cond ->
      pc_while_trace env env_ty cond body s s
  | pc_while_trace_step : forall (s s_body s_final : st_state),
      corest_eval_expr s.(st_vars) cond = Some (ST_V_BOOL true) ->
      pc_expr_supported cond = true ->
      pc_expr_safe s.(st_vars) cond ->
      pc_stmts_spec env env_ty s body ->
      star_corest_step body s nil s_body ->
      pc_while_trace env env_ty cond body s_body s_final ->
      pc_while_trace env env_ty cond body s s_final.

Lemma corest_step_deterministic :
  forall (stmts1 stmts2 stmts3 : list corest_stmt)
         (s1 s2 s3 : st_state),
    corest_step stmts1 s1 stmts2 s2 ->
    corest_step stmts1 s1 stmts3 s3 ->
    stmts2 = stmts3 /\ s2 = s3.
Proof.
  intros stmts1 stmts2 stmts3 s1 s2 s3 H1 H2.
  destruct stmts1 as [|stmt rest]; [inversion H1 |].
  destruct stmt as [x e | x idx e | cond then_body else_body
    | cond body | inst params | | | body].
  - inversion H1; subst. inversion H2; subst.
    assert (v = v0) by congruence.
    subst. split; reflexivity.
  - inversion H1.
  - inversion H1; subst; inversion H2; subst;
      try congruence; split; reflexivity.
  - inversion H1; subst; inversion H2; subst;
      try congruence; split; reflexivity.
  - inversion H1.
  - inversion H1.
  - inversion H1.
  - inversion H1; subst; inversion H2; subst. split; reflexivity.
Qed.

Lemma star_corest_step_nil :
  forall (s : st_state) (stmts3 : list corest_stmt) (s3 : st_state),
    star_corest_step nil s stmts3 s3 ->
    stmts3 = nil /\ s = s3.
Proof.
  intros s stmts3 s3 Hstar.
  inversion Hstar as
    [stmts0 s0 | stmts1 stmts2 stmts3' s1 s2 s3' Hstep Hrest].
  - split; reflexivity.
  - inversion Hstep.
Qed.

Lemma star_corest_step_to_nil_deterministic :
  forall (stmts1 : list corest_stmt) (s1 s2 s3 : st_state),
    star_corest_step stmts1 s1 nil s2 ->
    star_corest_step stmts1 s1 nil s3 ->
    s2 = s3.
Proof.
  intros stmts1 s1 s2 s3 H12 H13.
  remember nil as target eqn:Htarget.
  revert H13 Htarget.
  induction H12 as [stmts s | stmts1' stmts_mid stmts2'
    s1' s_mid s2' Hstep Hrest IH]; intros H13 Htarget.
  - symmetry in Htarget. subst stmts.
    inversion H13 as
      [stmts0 s0 | stmts_a stmts_b stmts_c sa sb sc Hstep13 Hrest13].
    + reflexivity.
    + inversion Hstep13.
  - subst stmts2'.
    inversion H13 as
      [stmts0 s0 | stmts_a stmts_b stmts_c sa sb sc Hstep13 Hrest13];
      subst.
    + inversion Hstep.
    + destruct (corest_step_deterministic _ _ _ _ _ _
                  Hstep Hstep13) as [Hstmts Hs].
      subst stmts_b. subst sb.
      exact (IH Hrest13 eq_refl).
Qed.

Lemma pc_while_trace_star :
  forall (env : compile_env) (env_ty : compile_type_env)
         (cond : corest_expr) (body : list corest_stmt)
         (s s_final : st_state),
    pc_while_trace env env_ty cond body s s_final ->
    star_corest_step [CS_WHILE cond body] s nil s_final.
Proof.
  intros env env_ty cond body s s_final Htrace.
  induction Htrace as
    [s0 Hfalse Hsupport Hsafe
    | s0 s_body s_final Htrue Hsupport Hsafe
      Hbody_spec Hbody_star Htail IH].
  - eapply CsStar_step.
    + eapply Cs_while_false; exact Hfalse.
    + apply CsStar_refl.
  - eapply CsStar_step.
    + eapply Cs_while_true; exact Htrue.
    + pose proof
        (star_corest_step_tail body nil s0 s_body
          [CS_WHILE cond body] Hbody_star) as Hbody_tail.
      change (star_corest_step (body ++ [CS_WHILE cond body]) s0
                ([] ++ [CS_WHILE cond body]) s_body) in Hbody_tail.
      eapply star_corest_step_app with
        (xs := body ++ [CS_WHILE cond body])
        (ys := [CS_WHILE cond body]) (zs := nil)
        (s2 := s_body).
      * exact Hbody_tail.
      * exact IH.
Qed.

Lemma pc_while_exit_false :
  forall (env : compile_env) (env_ty : compile_type_env)
         (cond : corest_expr) (body : list corest_stmt) (s : st_state),
    corest_eval_expr s.(st_vars) cond = Some (ST_V_BOOL false) ->
    pc_expr_supported cond = true ->
    pc_expr_safe s.(st_vars) cond ->
    forall (m : sasm_module) (fn : sasm_function) (f : sasm_frame)
           (fr : frame_stack) (input : value_stack) (mem : list Z)
           (cyc : Z) (prefix suffix : list sasm_instr)
           (loop_size exit_target : Z) (old_stack : list Z),
      compile_env_injective env ->
      compile_env_nonneg env ->
      compile_env_fits_frame env f ->
      lookup_function m f.(frame_func_idx) = Some fn ->
      fn.(sasm_body) =
        prefix ++ LOOP loop_size ::
          compile_expr env cond ++ [I32_EQZ; BR_IF 1] ++
          compile_stmts env env_ty body ++ [BR 0] ++ suffix ->
      f.(frame_pc) = instrs_total_size prefix ->
      f.(frame_block_stack) = exit_target :: old_stack ->
      pc_frame_env_matches env s.(st_vars) f ->
      exists (s_asm : runtime_state) (f_asm : sasm_frame),
        multi_pc_step m
          {| rt_values := input; rt_frames := f :: fr;
             rt_memory := mem; rt_cycle_cnt := cyc |}
          s_asm /\
        s_asm.(rt_frames) = f_asm :: fr /\
        s_asm.(rt_values) = input /\
        s_asm.(rt_memory) = mem /\
        pc_frame_env_matches env s.(st_vars) f_asm /\
        f_asm.(frame_block_stack) = old_stack /\
        f_asm.(frame_func_idx) = f.(frame_func_idx) /\
        f_asm.(frame_pc) = exit_target /\
        List.length f_asm.(frame_locals) = List.length f.(frame_locals).
Proof.
  intros env env_ty cond body s Hfalse Hsupport Hsafe
    m fn f fr input mem cyc prefix suffix loop_size exit_target old_stack
    Hinj Hnonneg Hfit Hlook Hbody Hpc Hstack Henv.
  set (loop_start := f.(frame_pc)).
  set (next_loop := f.(frame_pc) + instr_size (LOOP loop_size)).
  set (f1 := frame_push_block (set_frame_pc f next_loop) loop_start).
  set (rest_loop :=
    compile_expr env cond ++ [I32_EQZ; BR_IF 1] ++
    compile_stmts env env_ty body ++ [BR 0] ++ suffix).
  assert (Hbody_loop :
    fn.(sasm_body) = prefix ++ LOOP loop_size :: rest_loop).
  { subst rest_loop. rewrite Hbody. repeat rewrite app_assoc. reflexivity. }
  assert (Hfetch_loop :
    fetch_frame_instr m f = Some (LOOP loop_size, next_loop)).
  { subst next_loop. rewrite Hpc.
    apply fetch_frame_instr_app_exact with
      (fn := fn) (prefix := prefix) (i := LOOP loop_size)
      (rest := rest_loop); [exact Hlook | exact Hbody_loop | exact Hpc]. }
  set (s0 := {| rt_values := input; rt_frames := f :: fr;
                rt_memory := mem; rt_cycle_cnt := cyc |}).
  set (s1 := set_top_values_cycle s0 f1 input).
  assert (Hs1 : s1 = {| rt_values := input; rt_frames := f1 :: fr;
                         rt_memory := mem; rt_cycle_cnt := cyc + 1 |}).
  { subst s1 s0 f1 next_loop loop_start.
    unfold set_top_values_cycle. simpl. reflexivity. }
  assert (Hstep_loop : multi_pc_step m s0 s1).
  { subst s1 f1 next_loop loop_start.
    eapply pc_loop_multi.
    - subst s0. reflexivity.
    - exact Hfetch_loop. }
  rewrite Hs1 in Hstep_loop.
  set (prefix_loop := prefix ++ [LOOP loop_size]).
  assert (Hbody_cond :
    fn.(sasm_body) =
      prefix_loop ++ compile_expr env cond ++ [I32_EQZ; BR_IF 1] ++
      (compile_stmts env env_ty body ++ [BR 0] ++ suffix)).
  { subst prefix_loop.
    rewrite Hbody.
    subst rest_loop.
    repeat rewrite <- app_assoc.
    simpl.
    repeat rewrite app_assoc.
    simpl.
    reflexivity. }
  assert (Hpc1 : f1.(frame_pc) = instrs_total_size prefix_loop).
  { subst prefix_loop f1 next_loop loop_start.
    rewrite Hpc. rewrite instrs_total_size_app. simpl. ring. }
  assert (Hlook1 : lookup_function m f1.(frame_func_idx) = Some fn).
  { subst f1. simpl. exact Hlook. }
  assert (Hfit1 : compile_env_fits_frame env f1).
  { subst f1. simpl. exact Hfit. }
  assert (Hstack1 : f1.(frame_block_stack) = loop_start :: exit_target :: old_stack).
  { subst f1 loop_start. simpl. rewrite Hstack. reflexivity. }
  assert (Hnth1 :
    List.nth_error f1.(frame_block_stack) (Z.to_nat 1) = Some exit_target).
  { rewrite Hstack1. simpl. reflexivity. }
  assert (Hlocals1 : f1.(frame_locals) = f.(frame_locals)).
  { subst f1. simpl. reflexivity. }
  assert (Henv1 : pc_frame_env_matches env s.(st_vars) f1).
  { eapply pc_frame_env_matches_locals_eq; [exact Hlocals1 | exact Henv]. }
  destruct (compile_condition_false_pc env s.(st_vars) cond
              m fn f1 fr input mem (cyc + 1) prefix_loop
              (compile_stmts env env_ty body ++ [BR 0] ++ suffix)
              1 exit_target
              Hlook1 Hbody_cond Hpc1 Henv1
              Hsupport Hsafe Hfalse Hnth1)
    as [s2 [f2 Hrest]].
  destruct Hrest as
    (Hmulti2 & Hframes2 & Hval2 & Hmem2 & Hlocals2 & Hfunc2 &
     Hstack2 & Hpc2).
  exists s2, f2.
  split.
  - eapply multi_pc_step_trans; [exact Hstep_loop | exact Hmulti2].
  - split; [exact Hframes2 |].
    split; [exact Hval2 |].
    split; [exact Hmem2 |].
    split.
    + eapply pc_frame_env_matches_locals_eq;
        [exact Hlocals2 | exact Henv].
    + split.
      * rewrite Hstack2. rewrite Hstack1. simpl. reflexivity.
      * split.
        -- rewrite Hfunc2. subst f1. simpl. reflexivity.
        -- split; [exact Hpc2 |].
           rewrite Hlocals2. subst f1. simpl. reflexivity.
Qed.

Lemma pc_while_iteration_correct :
  forall (env : compile_env) (env_ty : compile_type_env)
         (cond : corest_expr) (body : list corest_stmt)
         (s s_body : st_state),
    corest_eval_expr s.(st_vars) cond = Some (ST_V_BOOL true) ->
    pc_expr_supported cond = true ->
    pc_expr_safe s.(st_vars) cond ->
    pc_stmts_spec env env_ty s body ->
    star_corest_step body s nil s_body ->
    forall (m : sasm_module) (fn : sasm_function) (f : sasm_frame)
           (fr : frame_stack) (input : value_stack) (mem : list Z)
           (cyc : Z) (prefix suffix : list sasm_instr)
           (loop_size exit_target : Z) (old_stack : list Z),
      compile_env_injective env ->
      compile_env_nonneg env ->
      compile_env_fits_frame env f ->
      lookup_function m f.(frame_func_idx) = Some fn ->
      fn.(sasm_body) =
        prefix ++ LOOP loop_size ::
          compile_expr env cond ++ [I32_EQZ; BR_IF 1] ++
          compile_stmts env env_ty body ++ [BR 0] ++ suffix ->
      f.(frame_pc) = instrs_total_size prefix ->
      f.(frame_block_stack) = exit_target :: old_stack ->
      pc_frame_env_matches env s.(st_vars) f ->
      exists (s_asm : runtime_state) (f_asm : sasm_frame),
        multi_pc_step m
          {| rt_values := input; rt_frames := f :: fr;
             rt_memory := mem; rt_cycle_cnt := cyc |}
          s_asm /\
        s_asm.(rt_frames) = f_asm :: fr /\
        s_asm.(rt_values) = input /\
        s_asm.(rt_memory) = mem /\
        pc_frame_env_matches env s_body.(st_vars) f_asm /\
        f_asm.(frame_block_stack) = exit_target :: old_stack /\
        f_asm.(frame_func_idx) = f.(frame_func_idx) /\
        f_asm.(frame_pc) = f.(frame_pc) /\
        List.length f_asm.(frame_locals) = List.length f.(frame_locals).
Proof.
  intros env env_ty cond body s s_body Htrue Hsupport Hsafe
    Hbody_spec Hbody_star
    m fn f fr input mem cyc prefix suffix loop_size exit_target old_stack
    Hinj Hnonneg Hfit Hlook Hbody Hpc Hstack Henv.
  set (loop_start := f.(frame_pc)).
  set (next_loop := f.(frame_pc) + instr_size (LOOP loop_size)).
  set (f1 := frame_push_block (set_frame_pc f next_loop) loop_start).
  set (rest_loop :=
    compile_expr env cond ++ [I32_EQZ; BR_IF 1] ++
    compile_stmts env env_ty body ++ [BR 0] ++ suffix).
  assert (Hbody_loop :
    fn.(sasm_body) = prefix ++ LOOP loop_size :: rest_loop).
  { subst rest_loop. rewrite Hbody. repeat rewrite app_assoc. reflexivity. }
  assert (Hfetch_loop :
    fetch_frame_instr m f = Some (LOOP loop_size, next_loop)).
  { subst next_loop. rewrite Hpc.
    apply fetch_frame_instr_app_exact with
      (fn := fn) (prefix := prefix) (i := LOOP loop_size)
      (rest := rest_loop); [exact Hlook | exact Hbody_loop | exact Hpc]. }
  set (s0 := {| rt_values := input; rt_frames := f :: fr;
                rt_memory := mem; rt_cycle_cnt := cyc |}).
  set (s1 := set_top_values_cycle s0 f1 input).
  assert (Hs1 : s1 = {| rt_values := input; rt_frames := f1 :: fr;
                         rt_memory := mem; rt_cycle_cnt := cyc + 1 |}).
  { subst s1 s0 f1 next_loop loop_start.
    unfold set_top_values_cycle. simpl. reflexivity. }
  assert (Hstep_loop : multi_pc_step m s0 s1).
  { subst s1 f1 next_loop loop_start.
    eapply pc_loop_multi.
    - subst s0. reflexivity.
    - exact Hfetch_loop. }
  rewrite Hs1 in Hstep_loop.
  set (prefix_loop := prefix ++ [LOOP loop_size]).
  assert (Hbody_cond :
    fn.(sasm_body) =
      prefix_loop ++ compile_expr env cond ++ [I32_EQZ; BR_IF 1] ++
      (compile_stmts env env_ty body ++ [BR 0] ++ suffix)).
  { subst prefix_loop.
    rewrite Hbody.
    subst rest_loop.
    repeat rewrite <- app_assoc.
    simpl.
    repeat rewrite app_assoc.
    simpl.
    reflexivity. }
  assert (Hpc1 : f1.(frame_pc) = instrs_total_size prefix_loop).
  { subst prefix_loop f1 next_loop loop_start.
    rewrite Hpc. rewrite instrs_total_size_app. simpl. ring. }
  assert (Hlook1 : lookup_function m f1.(frame_func_idx) = Some fn).
  { subst f1. simpl. exact Hlook. }
  assert (Hfit1 : compile_env_fits_frame env f1).
  { subst f1. simpl. exact Hfit. }
  assert (Hstack1 : f1.(frame_block_stack) = loop_start :: exit_target :: old_stack).
  { subst f1 loop_start. simpl. rewrite Hstack. reflexivity. }
  assert (Hlocals1 : f1.(frame_locals) = f.(frame_locals)).
  { subst f1. simpl. reflexivity. }
  assert (Henv1 : pc_frame_env_matches env s.(st_vars) f1).
  { eapply pc_frame_env_matches_locals_eq; [exact Hlocals1 | exact Henv]. }
  destruct (compile_condition_true_pc env s.(st_vars) cond
              m fn f1 fr input mem (cyc + 1) prefix_loop
              (compile_stmts env env_ty body ++ [BR 0] ++ suffix)
              1 Hlook1 Hbody_cond Hpc1 Henv1 Hsupport Hsafe Htrue)
    as [s2 [f2 Hrest2]].
  destruct Hrest2 as
    (Hmulti2 & Hframes2 & Hval2 & Hmem2 & Hlocals2 & Hfunc2 &
     Hstack2 & Hpc2).
  set (prefix_body := prefix_loop ++ compile_expr env cond ++ [I32_EQZ; BR_IF 1]).
  assert (Hbody_body :
    fn.(sasm_body) =
      prefix_body ++ compile_stmts env env_ty body ++ [BR 0] ++ suffix).
  { subst prefix_body.
    rewrite Hbody_cond.
    repeat rewrite app_assoc.
    reflexivity. }
  assert (Hpc2' : f2.(frame_pc) = instrs_total_size prefix_body).
  { rewrite Hpc2. subst prefix_body prefix_loop.
    repeat rewrite instrs_total_size_app.
    simpl.
    subst next_loop. rewrite Hpc.
    replace (instr_size (LOOP loop_size)) with 5 by reflexivity.
    ring_simplify. reflexivity. }
  assert (Hlook2 : lookup_function m f2.(frame_func_idx) = Some fn).
  { rewrite Hfunc2. exact Hlook1. }
  assert (Hfit2 : compile_env_fits_frame env f2).
  { eapply compile_env_fits_frame_locals_eq; [exact Hlocals2 | exact Hfit1]. }
  assert (Henv2 : pc_frame_env_matches env s.(st_vars) f2).
  { eapply pc_frame_env_matches_locals_eq; [exact Hlocals2 | exact Henv1]. }
  assert (Hnth_loop :
    List.nth_error f2.(frame_block_stack) 0 = Some loop_start).
  { rewrite Hstack2. rewrite Hstack1. simpl. reflexivity. }
  destruct (compile_stmts_then_br_correct_pc env env_ty body s Hbody_spec
              m fn f2 fr input mem s2.(rt_cycle_cnt) prefix_body suffix
              0 loop_start Hinj Hnonneg Hfit2 Hlook2 Hbody_body Hpc2'
              Henv2 Hnth_loop)
    as [s3 [f3 [s_core3 Hrest3]]].
  destruct Hrest3 as
    (Hmulti3 & Hstar3 & Hframes3 & Hval3 & Hmem3 & Hrel3 &
     Hstack3 & Hfunc3 & Hpc3 & Hlen3).
  assert (Hs2 :
    s2 =
      {| rt_values := input; rt_frames := f2 :: fr;
         rt_memory := mem; rt_cycle_cnt := s2.(rt_cycle_cnt) |}).
  { destruct s2 as [vals frames memory cycles].
    simpl in Hval2, Hframes2, Hmem2.
    subst vals. subst frames. subst memory. reflexivity. }
  rewrite <- Hs2 in Hmulti3.
  pose proof
    (star_corest_step_to_nil_deterministic body s s_core3 s_body
      Hstar3 Hbody_star) as Hcore_eq.
  subst s_core3.
  exists s3, f3.
  split.
  - eapply multi_pc_step_trans; [exact Hstep_loop |].
    eapply multi_pc_step_trans; [exact Hmulti2 | exact Hmulti3].
  - split; [exact Hframes3 |].
    split; [exact Hval3 |].
    split; [exact Hmem3 |].
    split; [exact Hrel3 |].
    split.
    + rewrite Hstack3. rewrite Hstack2. rewrite Hstack1. simpl. reflexivity.
    + split.
      * rewrite Hfunc3. rewrite Hfunc2. subst f1. simpl. reflexivity.
      * split.
        -- rewrite Hpc3. subst loop_start. reflexivity.
        -- rewrite Hlen3. rewrite Hlocals2. rewrite Hlocals1. reflexivity.
Qed.

Lemma pc_while_header_correct :
  forall (env : compile_env) (env_ty : compile_type_env)
         (cond : corest_expr) (body : list corest_stmt)
         (s s_final : st_state),
    pc_while_trace env env_ty cond body s s_final ->
    forall (m : sasm_module) (fn : sasm_function) (f : sasm_frame)
           (fr : frame_stack) (input : value_stack) (mem : list Z)
           (cyc : Z) (prefix suffix : list sasm_instr)
           (loop_size exit_target : Z) (old_stack : list Z),
      compile_env_injective env ->
      compile_env_nonneg env ->
      compile_env_fits_frame env f ->
      lookup_function m f.(frame_func_idx) = Some fn ->
      fn.(sasm_body) =
        prefix ++ LOOP loop_size ::
          compile_expr env cond ++ [I32_EQZ; BR_IF 1] ++
          compile_stmts env env_ty body ++ [BR 0] ++ suffix ->
      f.(frame_pc) = instrs_total_size prefix ->
      f.(frame_block_stack) = exit_target :: old_stack ->
      pc_frame_env_matches env s.(st_vars) f ->
      exists (s_asm : runtime_state) (f_asm : sasm_frame)
             (s_core : st_state),
        multi_pc_step m
          {| rt_values := input; rt_frames := f :: fr;
             rt_memory := mem; rt_cycle_cnt := cyc |}
          s_asm /\
        star_corest_step [CS_WHILE cond body] s nil s_core /\
        s_asm.(rt_frames) = f_asm :: fr /\
        s_asm.(rt_values) = input /\
        s_asm.(rt_memory) = mem /\
        pc_frame_env_matches env s_core.(st_vars) f_asm /\
        f_asm.(frame_block_stack) = old_stack /\
        f_asm.(frame_func_idx) = f.(frame_func_idx) /\
        f_asm.(frame_pc) = exit_target /\
        List.length f_asm.(frame_locals) = List.length f.(frame_locals).
Proof.
  intros env env_ty cond body s s_final Htrace.
  induction Htrace as
    [s0 Hfalse Hsupport_trace Hsafe_trace
    | s0 s_body s_final Htrue Hsupport_trace Hsafe_trace
      Hbody_spec Hbody_star Htail IH].
  - intros m fn f fr input mem cyc prefix suffix loop_size exit_target
      old_stack Hinj Hnonneg Hfit Hlook Hbody Hpc Hstack Henv.
    destruct (pc_while_exit_false env env_ty cond body s0 Hfalse
                Hsupport_trace Hsafe_trace m fn f fr input mem cyc
                prefix suffix loop_size exit_target old_stack
                Hinj Hnonneg Hfit Hlook Hbody Hpc Hstack Henv)
      as [s1 [f1 Hrest]].
    destruct Hrest as
      (Hmulti & Hframes & Hvalues & Hmem & Hrel & Hstack' &
       Hfunc & Hpc' & Hlen).
    exists s1, f1, s0.
    split; [exact Hmulti |].
    split.
    + eapply CsStar_step.
      * eapply Cs_while_false; exact Hfalse.
      * apply CsStar_refl.
    + repeat split; assumption.
  - intros m fn f fr input mem cyc prefix suffix loop_size exit_target
      old_stack Hinj Hnonneg Hfit Hlook Hbody Hpc Hstack Henv.
    destruct (pc_while_iteration_correct env env_ty cond body s0 s_body
                Htrue Hsupport_trace Hsafe_trace Hbody_spec Hbody_star
                m fn f fr input mem cyc prefix suffix loop_size
                exit_target old_stack Hinj Hnonneg Hfit Hlook Hbody Hpc
                Hstack Henv)
      as [s1 [f1 Hrest1]].
    destruct Hrest1 as
      (Hmulti1 & Hframes1 & Hvalues1 & Hmem1 & Hrel1 & Hstack1 &
       Hfunc1 & Hpc1 & Hlen1).
    assert (Hfit1 : compile_env_fits_frame env f1).
    { intros x idx Hidx. unfold compile_env_fits_frame in Hfit.
      rewrite Hlen1. exact (Hfit x idx Hidx). }
    assert (Hlook1 : lookup_function m f1.(frame_func_idx) = Some fn).
    { rewrite Hfunc1. exact Hlook. }
    assert (Hpc1' : f1.(frame_pc) = instrs_total_size prefix).
    { rewrite Hpc1. exact Hpc. }
    destruct (IH m fn f1 fr input mem s1.(rt_cycle_cnt) prefix suffix
                loop_size exit_target old_stack
                Hinj Hnonneg Hfit1 Hlook1 Hbody Hpc1'
                Hstack1 Hrel1)
      as [s2 [f2 [s_core Hrest2]]].
    destruct Hrest2 as
      (Hmulti2 & Hstar2 & Hframes2 & Hvalues2 & Hmem2 & Hrel2 &
       Hstack2 & Hfunc2 & Hpc2 & Hlen2).
    assert (Hs1 :
      s1 =
        {| rt_values := input; rt_frames := f1 :: fr;
           rt_memory := mem; rt_cycle_cnt := s1.(rt_cycle_cnt) |}).
    { destruct s1 as [vals frames memory cycles].
      simpl in Hvalues1, Hframes1, Hmem1.
      subst vals. subst frames. subst memory. reflexivity. }
    rewrite <- Hs1 in Hmulti2.
    exists s2, f2, s_core.
    split.
    + eapply multi_pc_step_trans; [exact Hmulti1 | exact Hmulti2].
    + split.
      * eapply CsStar_step.
        -- eapply Cs_while_true; exact Htrue.
        -- pose proof
             (star_corest_step_tail body nil s0 s_body
               [CS_WHILE cond body] Hbody_star) as Hbody_tail.
           change (star_corest_step (body ++ [CS_WHILE cond body]) s0
                     ([] ++ [CS_WHILE cond body]) s_body) in Hbody_tail.
           eapply star_corest_step_app with
             (xs := body ++ [CS_WHILE cond body])
             (ys := [CS_WHILE cond body]) (zs := nil) (s2 := s_body).
           ++ exact Hbody_tail.
           ++ exact Hstar2.
      * split; [exact Hframes2 |].
        split; [exact Hvalues2 |].
        split; [exact Hmem2 |].
        split; [exact Hrel2 |].
        split; [exact Hstack2 |].
        split; [rewrite Hfunc2; exact Hfunc1 |].
        split; [exact Hpc2 |].
        rewrite Hlen2. exact Hlen1.
Qed.

Lemma compile_while_correct_pc :
  forall (env : compile_env) (env_ty : compile_type_env)
         (cond : corest_expr) (body : list corest_stmt)
         (s s_final : st_state),
    pc_while_trace env env_ty cond body s s_final ->
    forall (m : sasm_module) (fn : sasm_function) (f : sasm_frame)
           (fr : frame_stack) (input : value_stack) (mem : list Z)
           (cyc : Z) (prefix suffix : list sasm_instr),
      compile_env_injective env ->
      compile_env_nonneg env ->
      compile_env_fits_frame env f ->
      lookup_function m f.(frame_func_idx) = Some fn ->
      fn.(sasm_body) =
        prefix ++ compile_stmt env env_ty (CS_WHILE cond body) ++ suffix ->
      f.(frame_pc) = instrs_total_size prefix ->
      pc_frame_env_matches env s.(st_vars) f ->
      exists (s_asm : runtime_state) (f_asm : sasm_frame)
             (s_core : st_state),
        multi_pc_step m
          {| rt_values := input; rt_frames := f :: fr;
             rt_memory := mem; rt_cycle_cnt := cyc |}
          s_asm /\
        star_corest_step [CS_WHILE cond body] s nil s_core /\
        s_asm.(rt_frames) = f_asm :: fr /\
        s_asm.(rt_values) = input /\
        s_asm.(rt_memory) = mem /\
        pc_frame_env_matches env s_core.(st_vars) f_asm /\
        f_asm.(frame_block_stack) = f.(frame_block_stack) /\
        f_asm.(frame_func_idx) = f.(frame_func_idx) /\
        f_asm.(frame_pc) =
          f.(frame_pc) +
          instrs_total_size (compile_stmt env env_ty (CS_WHILE cond body)) /\
        List.length f_asm.(frame_locals) = List.length f.(frame_locals).
Proof.
  intros env env_ty cond body s s_final Htrace
    m fn f fr input mem cyc prefix suffix
    Hinj Hnonneg Hfit Hlook Hbody Hpc Henv.
  set (c := compile_expr env cond).
  set (body_code := compile_stmts env env_ty body).
  set (header := c ++ [I32_EQZ; BR_IF 1]).
  set (loop_body := body_code ++ [BR 0]).
  set (loop_size := instr_seq_size (header ++ loop_body)).
  set (rest := [LOOP loop_size] ++ header ++ loop_body).
  set (exit_size := instr_seq_size rest).
  assert (Hwhile_shape :
    compile_stmt env env_ty (CS_WHILE cond body) =
      [BLOCK exit_size] ++ rest).
  { subst exit_size rest loop_size header loop_body body_code c.
    reflexivity. }
  rewrite Hwhile_shape in Hbody.
  set (exit_target :=
    f.(frame_pc) + instr_size (BLOCK exit_size) + exit_size).
  set (f1 := frame_push_block
    (set_frame_pc f (f.(frame_pc) + instr_size (BLOCK exit_size)))
    exit_target).
  set (prefix_block := prefix ++ [BLOCK exit_size]).
  assert (Hbody_header :
    fn.(sasm_body) =
      prefix_block ++ LOOP loop_size ::
        c ++ [I32_EQZ; BR_IF 1] ++ body_code ++ [BR 0] ++ suffix).
  { subst prefix_block header loop_body c body_code.
    rewrite Hbody.
    subst rest exit_size loop_size.
    repeat rewrite <- app_assoc.
    simpl.
    repeat rewrite app_assoc.
    simpl.
    reflexivity. }
  assert (Hfetch_block :
    fetch_frame_instr m f = Some (BLOCK exit_size, f1.(frame_pc))).
  { subst f1 exit_target. rewrite Hpc.
    apply fetch_frame_instr_app_exact with
      (fn := fn) (prefix := prefix) (i := BLOCK exit_size)
      (rest := rest ++ suffix); [exact Hlook | | exact Hpc].
    rewrite Hbody. subst exit_size rest. reflexivity. }
  set (s0 := {| rt_values := input; rt_frames := f :: fr;
                rt_memory := mem; rt_cycle_cnt := cyc |}).
  set (s1 := set_top_values_cycle s0 f1 input).
  assert (Hs1 : s1 = {| rt_values := input; rt_frames := f1 :: fr;
                         rt_memory := mem; rt_cycle_cnt := cyc + 1 |}).
  { subst s1 s0 f1 exit_target.
    unfold set_top_values_cycle. simpl. reflexivity. }
  assert (Hstep_block : multi_pc_step m s0 s1).
  { subst s1 f1 exit_target.
    eapply pc_block_multi.
    - subst s0. reflexivity.
    - exact Hfetch_block. }
  rewrite Hs1 in Hstep_block.
  assert (Hpc1 : f1.(frame_pc) = instrs_total_size prefix_block).
  { subst prefix_block f1 exit_target.
    rewrite instrs_total_size_app. simpl.
    rewrite Hpc. ring. }
  assert (Hlook1 : lookup_function m f1.(frame_func_idx) = Some fn).
  { subst f1. simpl. exact Hlook. }
  assert (Hfit1 : compile_env_fits_frame env f1).
  { subst f1. simpl. exact Hfit. }
  assert (Henv1 : pc_frame_env_matches env s.(st_vars) f1).
  { eapply pc_frame_env_matches_locals_eq; [| exact Henv].
    subst f1. simpl. reflexivity. }
  assert (Hstack1 :
    f1.(frame_block_stack) = exit_target :: f.(frame_block_stack)).
  { subst f1. simpl. reflexivity. }
  destruct (pc_while_header_correct env env_ty cond body s s_final Htrace
              m fn f1 fr input mem s1.(rt_cycle_cnt) prefix_block suffix
              loop_size exit_target f.(frame_block_stack)
              Hinj Hnonneg Hfit1 Hlook1 Hbody_header Hpc1 Hstack1 Henv1)
    as [s2 [f2 [s_core Hrest]]].
  destruct Hrest as
    (Hmulti2 & Hstar & Hframes2 & Hvalues2 & Hmem2 & Hrel2 &
     Hstack2 & Hfunc2 & Hpc2 & Hlen2).
  assert (Hs1_eq :
    s1 = {| rt_values := input; rt_frames := f1 :: fr;
            rt_memory := mem; rt_cycle_cnt := s1.(rt_cycle_cnt) |}).
  { destruct s1 as [vals frames memory cycles].
    simpl in Hs1.
    inversion Hs1; subst. reflexivity. }
  rewrite <- Hs1_eq in Hmulti2.
  exists s2, f2, s_core.
  split.
  - eapply multi_pc_step_trans; [exact Hstep_block | exact Hmulti2].
  - split; [exact Hstar |].
    split; [exact Hframes2 |].
    split; [exact Hvalues2 |].
    split; [exact Hmem2 |].
    split; [exact Hrel2 |].
    split.
    + rewrite Hstack2. subst exit_target f1. simpl. reflexivity.
    + split.
      * rewrite Hfunc2. subst f1. simpl. reflexivity.
      * split.
        -- rewrite Hpc2. subst exit_target.
           rewrite Hwhile_shape.
           assert (Hexit_total : exit_size = instrs_total_size rest).
           { unfold exit_size. apply instr_seq_size_eq_total. }
           assert (Hcode_size :
             instrs_total_size ([BLOCK exit_size] ++ rest) = 5 + exit_size).
           { rewrite instrs_total_size_app.
             rewrite instrs_total_size_singleton.
             rewrite <- Hexit_total.
             replace (instr_size (BLOCK exit_size)) with 5 by reflexivity.
             ring. }
           rewrite Hcode_size.
           replace (instr_size (BLOCK exit_size)) with 5 by reflexivity.
           ring.
        -- rewrite Hlen2. subst f1. simpl. reflexivity.
Qed.

Lemma pc_stmt_spec_while_of_trace :
  forall (env : compile_env) (env_ty : compile_type_env)
         (s s_final : st_state) (cond : corest_expr)
         (body : list corest_stmt),
    pc_while_trace env env_ty cond body s s_final ->
    pc_stmt_spec env env_ty s (CS_WHILE cond body).
Proof.
  intros env env_ty s s_final cond body Htrace.
  unfold pc_stmt_spec.
  intros m fn f fr input mem cyc prefix suffix
    Hinj Hnonneg Hfit Hlook Hbody Hpc Henv.
  exact (compile_while_correct_pc env env_ty cond body s s_final Htrace
           m fn f fr input mem cyc prefix suffix
           Hinj Hnonneg Hfit Hlook Hbody Hpc Henv).
Qed.

Inductive pc_stmts_trace (env : compile_env) (env_ty : compile_type_env)
  : list corest_stmt -> st_state -> st_state -> Prop :=
  | pc_stmts_trace_nil : forall (s : st_state),
      pc_stmts_trace env env_ty nil s s
  | pc_stmts_trace_assign :
      forall (x : ident) (e : corest_expr)
             (rest : list corest_stmt)
             (s s_final : st_state) (v : st_value),
      corest_eval_expr s.(st_vars) e = Some v ->
      assign_sequence_ok env env_ty s [CS_ASSIGN x e] ->
      pc_stmts_trace env env_ty rest
        (update_var s x (corest_assign_value s x v)) s_final ->
      pc_stmts_trace env env_ty (CS_ASSIGN x e :: rest) s s_final
  | pc_stmts_trace_if_true :
      forall (cond : corest_expr)
             (then_body else_body rest : list corest_stmt)
             (s s_body s_final : st_state),
      corest_eval_expr s.(st_vars) cond = Some (ST_V_BOOL true) ->
      pc_expr_supported cond = true ->
      pc_expr_safe s.(st_vars) cond ->
      pc_stmts_trace env env_ty then_body s s_body ->
      pc_stmts_trace env env_ty rest s_body s_final ->
      pc_stmts_trace env env_ty
        (CS_IF cond then_body else_body :: rest) s s_final
  | pc_stmts_trace_if_false :
      forall (cond : corest_expr)
             (then_body else_body rest : list corest_stmt)
             (s s_body s_final : st_state),
      corest_eval_expr s.(st_vars) cond = Some (ST_V_BOOL false) ->
      pc_expr_supported cond = true ->
      pc_expr_safe s.(st_vars) cond ->
      pc_stmts_trace env env_ty else_body s s_body ->
      pc_stmts_trace env env_ty rest s_body s_final ->
      pc_stmts_trace env env_ty
        (CS_IF cond then_body else_body :: rest) s s_final
  | pc_stmts_trace_while :
      forall (cond : corest_expr) (body rest : list corest_stmt)
             (s s_body s_final : st_state),
      pc_while_trace env env_ty cond body s s_body ->
      pc_stmts_trace env env_ty rest s_body s_final ->
      pc_stmts_trace env env_ty (CS_WHILE cond body :: rest) s s_final
  | pc_stmts_trace_block :
      forall (body rest : list corest_stmt)
             (s s_body s_final : st_state),
      pc_stmts_trace env env_ty body s s_body ->
      pc_stmts_trace env env_ty rest s_body s_final ->
      pc_stmts_trace env env_ty (CS_BLOCK body :: rest) s s_final.

Lemma pc_stmts_trace_app_split :
  forall (env : compile_env) (env_ty : compile_type_env)
         (xs ys : list corest_stmt) (s s_final : st_state),
    pc_stmts_trace env env_ty (xs ++ ys) s s_final ->
    exists (s_mid : st_state),
      pc_stmts_trace env env_ty xs s s_mid /\
      pc_stmts_trace env env_ty ys s_mid s_final.
Proof.
  intros env env_ty xs.
  induction xs as [|stmt xs IH]; intros ys s s_final Htrace.
  - simpl in Htrace.
    exists s.
    split; [constructor | exact Htrace].
  - simpl in Htrace.
    destruct stmt as
      [x e | x idx e | cond then_body else_body | cond body
      | inst params | | | body].
    + inversion Htrace as
        [s0
        | x0 e0 rest0 s0 s_final0 v0 Heval Hok Hrest
        | cond0 then0 else0 rest0 s0 s_body s_final0 Heval Hsupport
          Hsafe Hbranch Hrest
        | cond0 then0 else0 rest0 s0 s_body s_final0 Heval Hsupport
          Hsafe Hbranch Hrest
        | cond0 body0 rest0 s0 s_body s_final0 Hwhile Hrest
        | body0 rest0 s0 s_body s_final0 Hbody Hrest];
        subst; try solve [discriminate | congruence].
      destruct (IH ys (update_var s x (corest_assign_value s x v0))
                  s_final Hrest) as [s_mid [Hxs Hys]].
      exists s_mid.
      split; [| exact Hys].
      apply (pc_stmts_trace_assign env env_ty x e xs s s_mid v0
               Heval Hok Hxs).
    + inversion Htrace.
    + inversion Htrace; subst; clear Htrace.
      all: rename H3 into Heval.
      all: rename H4 into Hsupport.
      all: rename H7 into Hsafe.
      all: rename H8 into Hbranch.
      all: rename H9 into Hrest.
      all: destruct (IH ys s_body s_final Hrest) as [s_mid [Hxs Hys]].
      all: exists s_mid.
      all: split; [| exact Hys].
      all: first
        [ exact (pc_stmts_trace_if_true env env_ty cond then_body else_body
                   xs s s_body s_mid Heval Hsupport Hsafe Hbranch Hxs)
        | exact (pc_stmts_trace_if_false env env_ty cond then_body else_body
                   xs s s_body s_mid Heval Hsupport Hsafe Hbranch Hxs) ].
    + inversion Htrace as
        [s0
        | x0 e0 rest0 s0 s_final0 v0 Heval Hok Hrest
        | cond0 then0 else0 rest0 s0 s_body s_final0 Heval Hsupport
          Hsafe Hbranch Hrest
        | cond0 then0 else0 rest0 s0 s_body s_final0 Heval Hsupport
          Hsafe Hbranch Hrest
        | cond0 body0 rest0 s0 s_body s_final0 Hwhile Hrest
        | body0 rest0 s0 s_body s_final0 Hbody Hrest];
        subst; try solve [discriminate | congruence].
      destruct (IH ys s_body s_final Hrest) as [s_mid [Hxs Hys]].
      exists s_mid.
      split; [| exact Hys].
      apply (pc_stmts_trace_while env env_ty cond body xs
               s s_body s_mid Hwhile Hxs).
    + inversion Htrace.
    + inversion Htrace.
    + inversion Htrace.
    + inversion Htrace as
        [s0
        | x0 e0 rest0 s0 s_final0 v0 Heval Hok Hrest
        | cond0 then0 else0 rest0 s0 s_body s_final0 Heval Hsupport
          Hsafe Hbranch Hrest
        | cond0 then0 else0 rest0 s0 s_body s_final0 Heval Hsupport
          Hsafe Hbranch Hrest
        | cond0 body0 rest0 s0 s_body s_final0 Hwhile Hrest
        | body0 rest0 s0 s_body s_final0 Hbody Hrest];
        subst; try solve [discriminate | congruence].
      destruct (IH ys s_body s_final Hrest) as [s_mid [Hxs Hys]].
      exists s_mid.
      split; [| exact Hys].
      apply (pc_stmts_trace_block env env_ty body xs
               s s_body s_mid Hbody Hxs).
Qed.

Lemma pc_stmts_trace_star :
  forall (env : compile_env) (env_ty : compile_type_env)
         (stmts : list corest_stmt) (s s_final : st_state),
    pc_stmts_trace env env_ty stmts s s_final ->
    star_corest_step stmts s nil s_final.
Proof.
  intros env env_ty stmts s s_final Htrace.
  induction Htrace as
    [s0
    | x e rest s0 s_final v Heval Hassign Hrest IH
    | cond then_body else_body rest s0 s_body s_final
      Heval Hsupport Hsafe Hbranch IHbranch Hrest IHrest
    | cond then_body else_body rest s0 s_body s_final
      Heval Hsupport Hsafe Hbranch IHbranch Hrest IHrest
    | cond body rest s0 s_body s_final Hwhile IHrest
    | body rest s0 s_body s_final Hbody IHbody Hrest IHrest].
  - apply CsStar_refl.
  - eapply CsStar_step.
    + eapply Cs_assign; exact Heval.
    + exact IH.
  - eapply CsStar_step.
    + eapply Cs_if_true; exact Heval.
    + pose proof
        (star_corest_step_tail then_body nil s0 s_body rest IHbranch)
        as Hbranch_tail.
      change (star_corest_step (then_body ++ rest) s0 (nil ++ rest) s_body)
        in Hbranch_tail.
      eapply star_corest_step_app with
        (xs := then_body ++ rest) (ys := rest) (zs := nil) (s2 := s_body).
      * exact Hbranch_tail.
      * exact IHrest.
  - eapply CsStar_step.
    + eapply Cs_if_false; exact Heval.
    + pose proof
        (star_corest_step_tail else_body nil s0 s_body rest IHbranch)
        as Hbranch_tail.
      change (star_corest_step (else_body ++ rest) s0 (nil ++ rest) s_body)
        in Hbranch_tail.
      eapply star_corest_step_app with
        (xs := else_body ++ rest) (ys := rest) (zs := nil) (s2 := s_body).
      * exact Hbranch_tail.
      * exact IHrest.
  - pose proof
      (star_corest_step_tail [CS_WHILE cond body] nil s0 s_body rest
        (pc_while_trace_star env env_ty cond body s0 s_body Hwhile))
      as Hwhile_tail.
    change (star_corest_step (CS_WHILE cond body :: rest) s0
              (nil ++ rest) s_body) in Hwhile_tail.
    eapply star_corest_step_app with
      (xs := CS_WHILE cond body :: rest) (ys := rest) (zs := nil)
      (s2 := s_body).
    + exact Hwhile_tail.
    + exact IHIHrest.
  - eapply CsStar_step.
    + eapply Cs_block.
    + pose proof
        (star_corest_step_tail body nil s0 s_body rest IHbody)
        as Hbody_tail.
      change (star_corest_step (body ++ rest) s0 (nil ++ rest) s_body)
        in Hbody_tail.
      eapply star_corest_step_app with
        (xs := body ++ rest) (ys := rest) (zs := nil) (s2 := s_body).
      * exact Hbody_tail.
      * exact IHrest.
Qed.

Lemma pc_stmts_spec_of_trace :
  forall (env : compile_env) (env_ty : compile_type_env)
         (stmts : list corest_stmt) (s s_final : st_state),
    pc_stmts_trace env env_ty stmts s s_final ->
    pc_stmts_spec env env_ty s stmts.
Proof.
  intros env env_ty stmts s s_final Htrace.
  induction Htrace as
    [s0
    | x e rest s0 s_final v Heval Hassign Hrest IHrest
    | cond then_body else_body rest s0 s_body s_final
      Heval Hsupport Hsafe Hbranch IHbranch Hrest IHrest
    | cond then_body else_body rest s0 s_body s_final
      Heval Hsupport Hsafe Hbranch IHbranch Hrest IHrest
    | cond body rest s0 s_body s_final Hwhile IHrest
    | body rest s0 s_body s_final Hbody IHbody Hrest IHrest].
  - apply assign_sequence_pc_stmts_spec. simpl. exact I.
  - assert (Hhead : pc_stmt_spec env env_ty s0 (CS_ASSIGN x e)).
    { apply pc_stmt_spec_assign. exact Hassign. }
    eapply pc_stmts_spec_cons with
      (stmt := CS_ASSIGN x e) (rest := rest).
    + exact Hhead.
    + intros s_core Hstar_head.
      assert (Hknown : star_corest_step [CS_ASSIGN x e] s0 nil
                        (update_var s0 x (corest_assign_value s0 x v))).
      { eapply CsStar_step.
        - eapply Cs_assign; exact Heval.
        - apply CsStar_refl. }
      assert (Hs_core : s_core =
                        update_var s0 x (corest_assign_value s0 x v)).
      { eapply star_corest_step_to_nil_deterministic;
          [exact Hstar_head | exact Hknown]. }
      subst. exact IHrest.
  - assert (Hhead :
      pc_stmt_spec env env_ty s0 (CS_IF cond then_body else_body)).
    { eapply pc_stmt_spec_if_true; eauto. }
    eapply pc_stmts_spec_cons with
      (stmt := CS_IF cond then_body else_body) (rest := rest).
    + exact Hhead.
    + intros s_core Hstar_head.
      assert (Hknown : star_corest_step
                        [CS_IF cond then_body else_body] s0 nil s_body).
      { eapply CsStar_step.
        - eapply Cs_if_true; exact Heval.
        - rewrite app_nil_r.
          exact (pc_stmts_trace_star env env_ty then_body s0 s_body Hbranch). }
      assert (Hs_core : s_core = s_body).
      { eapply star_corest_step_to_nil_deterministic;
          [exact Hstar_head | exact Hknown]. }
      subst. exact IHrest.
  - assert (Hhead :
      pc_stmt_spec env env_ty s0 (CS_IF cond then_body else_body)).
    { eapply pc_stmt_spec_if_false; eauto. }
    eapply pc_stmts_spec_cons with
      (stmt := CS_IF cond then_body else_body) (rest := rest).
    + exact Hhead.
    + intros s_core Hstar_head.
      assert (Hknown : star_corest_step
                        [CS_IF cond then_body else_body] s0 nil s_body).
      { eapply CsStar_step.
        - eapply Cs_if_false; exact Heval.
        - rewrite app_nil_r.
          exact (pc_stmts_trace_star env env_ty else_body s0 s_body Hbranch). }
      assert (Hs_core : s_core = s_body).
      { eapply star_corest_step_to_nil_deterministic;
          [exact Hstar_head | exact Hknown]. }
      subst. exact IHrest.
  - assert (Hhead : pc_stmt_spec env env_ty s0 (CS_WHILE cond body)).
    { exact (pc_stmt_spec_while_of_trace env env_ty s0 s_body cond body Hwhile). }
    eapply pc_stmts_spec_cons with
      (stmt := CS_WHILE cond body) (rest := rest).
    + exact Hhead.
    + intros s_core Hstar_head.
      assert (Hknown :
        star_corest_step [CS_WHILE cond body] s0 nil s_body).
      { exact (pc_while_trace_star env env_ty cond body s0 s_body Hwhile). }
      assert (Hs_core : s_core = s_body).
      { eapply star_corest_step_to_nil_deterministic;
          [exact Hstar_head | exact Hknown]. }
      subst. exact IHIHrest.
  - assert (Hhead : pc_stmt_spec env env_ty s0 (CS_BLOCK body)).
    { eapply pc_stmt_spec_block. exact IHbody. }
    eapply pc_stmts_spec_cons with (stmt := CS_BLOCK body) (rest := rest).
    + exact Hhead.
    + intros s_core Hstar_head.
      assert (Hknown : star_corest_step [CS_BLOCK body] s0 nil s_body).
      { eapply CsStar_step.
        - eapply Cs_block.
        - rewrite app_nil_r.
          exact (pc_stmts_trace_star env env_ty body s0 s_body Hbody). }
      assert (Hs_core : s_core = s_body).
      { eapply star_corest_step_to_nil_deterministic;
          [exact Hstar_head | exact Hknown]. }
      subst. exact IHrest.
Qed.

Theorem compile_stmt_correct_pc :
  forall (env : compile_env) (env_ty : compile_type_env)
         (stmt : corest_stmt) (s s_final : st_state),
    pc_stmts_trace env env_ty [stmt] s s_final ->
    pc_stmt_spec env env_ty s stmt.
Proof.
  intros env env_ty stmt s s_final Htrace.
  apply pc_stmts_spec_singleton.
  exact (pc_stmts_spec_of_trace env env_ty [stmt] s s_final Htrace).
Qed.

Theorem codegen_stmts_correct_pc :
  forall (env : compile_env) (env_ty : compile_type_env)
         (stmts : list corest_stmt) (s s_final : st_state),
    pc_stmts_trace env env_ty stmts s s_final ->
    pc_stmts_spec env env_ty s stmts.
Proof.
  intros env env_ty stmts s s_final Htrace.
  exact (pc_stmts_spec_of_trace env env_ty stmts s s_final Htrace).
Qed.

Definition singleton_corest_program (cf : corest_function) : corest_program :=
  {| cprog_functions := [cf];
     cprog_global_vars := nil;
     cprog_entry := cf.(cfunc_name);
     cprog_io_mapping := nil |}.

Lemma lookup_compile_singleton_program :
  forall (cf : corest_function),
    lookup_function (compile_program (singleton_corest_program cf)) 0 =
    Some (compile_function (build_compile_env cf)
            (build_compile_type_env cf) cf).
Proof.
  intros cf.
  unfold lookup_function, compile_program, singleton_corest_program.
  simpl.
  reflexivity.
Qed.

Lemma compile_function_body_none :
  forall (cf : corest_function),
    cf.(cfunc_return_type) = None ->
    (compile_function (build_compile_env cf) (build_compile_type_env cf) cf).(sasm_body) =
    compile_stmts (build_compile_env cf) (build_compile_type_env cf) cf.(cfunc_body).
Proof.
  intros cf Hret.
  unfold compile_function.
  rewrite Hret.
  reflexivity.
Qed.

Theorem codegen_singleton_program_correct_pc :
  forall (cf : corest_function)
         (input : value_stack) (mem : list Z) (cyc : Z)
         (s s_final : st_state),
    cf.(cfunc_return_type) = None ->
    compile_state_env_matches (build_compile_type_env cf) s.(st_vars) ->
    compile_state_values_i32 s.(st_vars) ->
    pc_stmts_trace (build_compile_env cf) (build_compile_type_env cf)
      cf.(cfunc_body) s s_final ->
    let m := compile_program (singleton_corest_program cf) in
    let fn := compile_function (build_compile_env cf)
                (build_compile_type_env cf) cf in
    let f0 := {| frame_locals :=
                   sasm_locals_of_decls (build_compile_type_env cf) s.(st_vars);
                 frame_func_idx := 0;
                 frame_pc := 0;
                 frame_block_stack := [] |} in
    exists (s_asm : runtime_state) (f_asm : sasm_frame),
      multi_pc_step m
        {| rt_values := input; rt_frames := f0 :: nil;
           rt_memory := mem; rt_cycle_cnt := cyc |}
        s_asm /\
      pc_final_entry m s_asm /\
      s_asm.(rt_frames) = f_asm :: nil /\
      s_asm.(rt_values) = input /\
      s_asm.(rt_memory) = mem /\
      pc_frame_env_matches (build_compile_env cf) s_final.(st_vars) f_asm /\
      f_asm.(frame_block_stack) = [] /\
      f_asm.(frame_func_idx) = 0.
Proof.
  intros cf input mem cyc s s_final Hret Hmatch Hvalues Htrace.
  set (m := compile_program (singleton_corest_program cf)).
  set (fn := compile_function (build_compile_env cf)
                (build_compile_type_env cf) cf).
  set (f0 := {| frame_locals :=
                  sasm_locals_of_decls (build_compile_type_env cf) s.(st_vars);
                frame_func_idx := 0;
                frame_pc := 0;
                frame_block_stack := [] |}).
  pose proof (codegen_stmts_correct_pc
                (build_compile_env cf) (build_compile_type_env cf)
                cf.(cfunc_body) s s_final Htrace) as Hspec.
  pose proof (lookup_compile_singleton_program cf) as Hlook0.
  fold m fn in Hlook0.
  assert (Hfit : compile_env_fits_frame (build_compile_env cf) f0).
  { subst f0. apply compile_env_fits_locals_of_decls. }
  assert (Hbody : fn.(sasm_body) =
                 compile_stmts (build_compile_env cf)
                   (build_compile_type_env cf) cf.(cfunc_body)).
  { subst fn. apply compile_function_body_none. exact Hret. }
  assert (Hpc : f0.(frame_pc) = instrs_total_size nil) by reflexivity.
  assert (Henv0 : pc_frame_env_matches (build_compile_env cf)
                    s.(st_vars) f0).
  { subst f0. apply pc_frame_env_matches_build_compile_env; assumption. }
  assert (Hbody_app :
    fn.(sasm_body) =
    [] ++ compile_stmts (build_compile_env cf)
             (build_compile_type_env cf) cf.(cfunc_body) ++ []).
  { rewrite Hbody. simpl. rewrite app_nil_r. reflexivity. }
  unfold pc_stmts_spec in Hspec.
  destruct (Hspec m fn f0 nil input mem cyc nil nil
              (build_compile_env_injective cf)
              (build_compile_env_nonneg cf)
              Hfit Hlook0 Hbody_app Hpc Henv0)
    as [s_asm [f_asm [s_core Hrest]]].
  destruct Hrest as
    (Hmulti & Hstar & Hframes & Hvalues' & Hmem & Hrel &
     Hblock & Hfunc & Hpc_end & Hlen).
  assert (Hstar_final :
    star_corest_step cf.(cfunc_body) s nil s_final).
  { exact (pc_stmts_trace_star (build_compile_env cf)
             (build_compile_type_env cf) cf.(cfunc_body) s s_final Htrace). }
  assert (Hs_core : s_core = s_final).
  { eapply star_corest_step_to_nil_deterministic;
      [exact Hstar | exact Hstar_final]. }
  subst s_core.
  exists s_asm, f_asm.
  split; [exact Hmulti |].
  split.
  - unfold pc_final_entry.
    exists f_asm.
    split; [exact Hframes |].
    assert (Hlook_asm :
      lookup_function m f_asm.(frame_func_idx) = Some fn).
    { rewrite Hfunc. exact Hlook0. }
    unfold pc_at_body_end.
    rewrite Hlook_asm.
    split.
    + rewrite Hbody.
      rewrite Hpc_end.
      simpl.
      reflexivity.
    + exact Hblock.
  - split; [exact Hframes |].
    split; [exact Hvalues' |].
    split; [exact Hmem |].
    split; [exact Hrel |].
    split; [exact Hblock | exact Hfunc].
Qed.

(* 字面量编译保持：corest_eval_expr (CE_LIT l) = v
   等价于 I32/I64/F32/F64_CONST 执行后值栈顶 = st_val_to_sasm_val v。 *)
Lemma compile_literal_correct : forall (env : compile_env) (l : st_literal)
                                 (env_s : corest_eval_env) (v : st_value),
    corest_eval_expr env_s (CE_LIT l) = Some v ->
    forall (st0 : runtime_state),
      exists (st' : runtime_state),
        exec_instrs st0 (compile_expr env (CE_LIT l)) = Some st' /\
        List.hd (V_I32 0) st'.(rt_values) = st_val_to_sasm_val v.
Proof.
  intros env l env_s v Heval st0.
  destruct l; simpl in Heval; try discriminate;
    inversion Heval; subst.
  all: eexists; split.
  all: try reflexivity.
  all: reflexivity.
Qed.

(* 变量引用保持：当前帧 locals[idx] 与 env_s 中的值一致时，
   LOCAL_GET idx 执行后值栈顶为该值。 *)
Lemma compile_var_correct :
  forall (env : compile_env) (x : ident) (v : st_value) (idx : Z)
         (st0 : runtime_state) (f : sasm_frame),
    lookup_var_idx env x = Some idx ->
    st0.(rt_frames) = f :: nil ->
    List.nth_error f.(frame_locals) (Z.to_nat idx) = Some (st_val_to_sasm_val v) ->
    exists (st' : runtime_state),
      exec_instrs st0 (compile_expr env (CE_VAR x)) = Some st' /\
      List.hd (V_I32 0) st'.(rt_values) = st_val_to_sasm_val v.
Proof.
  intros env x v idx st0 f Hidx Hfr Hframe.
  simpl.
  rewrite Hidx. simpl.
  rewrite Hfr. simpl.
  rewrite Hframe. simpl.
  eexists; split; reflexivity.
Qed.

(* 整数负号字面量：-n 编译为 0 - n。 *)
Lemma compile_int_neg_literal_correct :
  forall (env : compile_env) (n : Z) (env_s : corest_eval_env)
         (v : st_value),
    corest_eval_expr env_s
      (CE_UNARY_OP U_NEG (CE_LIT (L_INT n))) = Some v ->
    forall (st0 : runtime_state),
      exists (st' : runtime_state),
        exec_instrs st0
          (compile_expr env (CE_UNARY_OP U_NEG (CE_LIT (L_INT n)))) = Some st' /\
        List.hd (V_I32 0) st'.(rt_values) = st_val_to_sasm_val v.
Proof.
  intros env n env_s v Heval st0.
  simpl in Heval; inversion Heval; subst.
  eexists; split; [reflexivity | reflexivity].
Qed.

(* 布尔非字面量：NOT b 编译为 EQZ。 *)
Lemma compile_bool_not_literal_correct :
  forall (env : compile_env) (b : bool) (env_s : corest_eval_env)
         (v : st_value),
    corest_eval_expr env_s
      (CE_UNARY_OP U_NOT (CE_LIT (L_BOOL b))) = Some v ->
    forall (st0 : runtime_state),
      exists (st' : runtime_state),
        exec_instrs st0
          (compile_expr env (CE_UNARY_OP U_NOT (CE_LIT (L_BOOL b)))) = Some st' /\
        List.hd (V_I32 0) st'.(rt_values) = st_val_to_sasm_val v.
Proof.
  intros env b env_s v Heval st0.
  simpl in Heval; inversion Heval; subst.
  destruct b; simpl.
  all: eexists; split; [reflexivity | reflexivity].
Qed.

Lemma compile_bool_and_literal_correct :
  forall (env : compile_env) (b1 b2 : bool)
         (env_s : corest_eval_env) (v : st_value),
    corest_eval_expr env_s
      (CE_AND (CE_LIT (L_BOOL b1)) (CE_LIT (L_BOOL b2))) = Some v ->
    forall (st0 : runtime_state),
      exists (st' : runtime_state),
        exec_instrs st0
          (compile_expr env
             (CE_AND (CE_LIT (L_BOOL b1)) (CE_LIT (L_BOOL b2)))) = Some st' /\
        List.hd (V_I32 0) st'.(rt_values) = st_val_to_sasm_val v.
Proof.
  intros env b1 b2 env_s v Heval st0.
  destruct b1, b2; simpl in Heval; inversion Heval; subst.
  all: eexists; split; [reflexivity | reflexivity].
Qed.

Lemma compile_bool_or_literal_correct :
  forall (env : compile_env) (b1 b2 : bool)
         (env_s : corest_eval_env) (v : st_value),
    corest_eval_expr env_s
      (CE_OR (CE_LIT (L_BOOL b1)) (CE_LIT (L_BOOL b2))) = Some v ->
    forall (st0 : runtime_state),
      exists (st' : runtime_state),
        exec_instrs st0
          (compile_expr env
             (CE_OR (CE_LIT (L_BOOL b1)) (CE_LIT (L_BOOL b2)))) = Some st' /\
        List.hd (V_I32 0) st'.(rt_values) = st_val_to_sasm_val v.
Proof.
  intros env b1 b2 env_s v Heval st0.
  destruct b1, b2; simpl in Heval; inversion Heval; subst.
  all: eexists; split; [reflexivity | reflexivity].
Qed.

Lemma compile_bool_xor_literal_correct :
  forall (env : compile_env) (b1 b2 : bool)
         (env_s : corest_eval_env) (v : st_value),
    corest_eval_expr env_s
      (CE_XOR (CE_LIT (L_BOOL b1)) (CE_LIT (L_BOOL b2))) = Some v ->
    forall (st0 : runtime_state),
      exists (st' : runtime_state),
        exec_instrs st0
          (compile_expr env
             (CE_XOR (CE_LIT (L_BOOL b1)) (CE_LIT (L_BOOL b2)))) = Some st' /\
        List.hd (V_I32 0) st'.(rt_values) = st_val_to_sasm_val v.
Proof.
  intros env b1 b2 env_s v Heval st0.
  destruct b1, b2; simpl in Heval; inversion Heval; subst.
  all: eexists; split; [reflexivity | reflexivity].
Qed.

(* 32 位整数字面量比较：编译后的 I32 比较指令与 CoreST 求值一致。 *)
Lemma compile_int_compare_literal_correct :
  forall (env : compile_env) (c : compare_op) (n1 n2 : Z)
         (env_s : corest_eval_env) (v : st_value),
    corest_eval_expr env_s
      (CE_COMP c (CE_LIT (L_INT n1)) (CE_LIT (L_INT n2))) = Some v ->
    forall (st0 : runtime_state),
      exists (st' : runtime_state),
        exec_instrs st0
          (compile_expr env
             (CE_COMP c (CE_LIT (L_INT n1)) (CE_LIT (L_INT n2)))) = Some st' /\
        List.hd (V_I32 0) st'.(rt_values) = st_val_to_sasm_val v.
Proof.
  intros env c n1 n2 env_s v Heval st0.
  destruct c; simpl in Heval; inversion Heval; subst.
  - (* C_EQ *)
    eexists; split; [reflexivity | reflexivity].
  - (* C_NE *)
    eexists; split; [reflexivity |].
    destruct (Z.eqb n1 n2); reflexivity.
  - (* C_LT *)
    eexists; split; [reflexivity | reflexivity].
  - (* C_LE *)
    eexists; split; [reflexivity | reflexivity].
  - (* C_GT *)
    eexists; split; [reflexivity |].
    rewrite Z.gtb_ltb.
    reflexivity.
  - (* C_GE *)
    eexists; split; [reflexivity |].
    rewrite Z.geb_leb.
    reflexivity.
Qed.

(* 32 位整数字面量二元运算：CoreST 求值结果与编译后的 I32 指令序列一致。 *)
Lemma compile_int_binop_literal_correct :
  forall (env : compile_env) (op : binary_op) (n1 n2 : Z)
         (env_s : corest_eval_env) (v : st_value),
    corest_eval_expr env_s
      (CE_BIN_OP op (CE_LIT (L_INT n1)) (CE_LIT (L_INT n2))) = Some v ->
    forall (st0 : runtime_state),
      exists (st' : runtime_state),
        exec_instrs st0
          (compile_expr env
             (CE_BIN_OP op (CE_LIT (L_INT n1)) (CE_LIT (L_INT n2)))) = Some st' /\
        List.hd (V_I32 0) st'.(rt_values) = st_val_to_sasm_val v.
Proof.
  intros env op n1 n2 env_s v Heval st0.
  destruct op; simpl in Heval; inversion Heval; subst.
  all: eexists; split; [reflexivity | reflexivity].
Qed.

(* 赋值语句最小垂直切片：x := 42 在“x 是 0 号局部、类型 DINT”时，
   compile_stmt 生成的 I32_CONST + LOCAL_SET 0 会更新帧 locals[0]。 *)
Lemma compile_int_assign_local0_correct :
  forall (n old : Z) (st0 : runtime_state) (v : st_value),
    st0 = {| rt_values := nil;
             rt_frames := (Build_sasm_frame [V_I32 old] 0 0 []) :: nil;
             rt_memory := nil;
             rt_cycle_cnt := 0 |} ->
    corest_eval_expr nil (CE_LIT (L_INT n)) = Some v ->
    exists (st' : runtime_state),
      exec_instrs st0
        (compile_stmt ((ID "x", 0) :: nil)
           ((ID "x", T_DINT) :: nil)
           (CS_ASSIGN (ID "x") (CE_LIT (L_INT n)))) = Some st' /\
      match st'.(rt_frames) with
      | f :: _ => List.nth_error f.(frame_locals) 0 = Some (V_I32 n)
      | nil => False
      end.
Proof.
  intros n old st0 v Hst Heval.
  rewrite Hst.
  simpl in Heval.
  inversion Heval; subst.
  eexists; split; simpl; reflexivity.
Qed.

(* 布尔字面量赋值垂直切片：x := FALSE/TRUE 在 x 为 0 号 BOOL 局部时，
   I32_CONST 0/1 + LOCAL_SET 0 会更新帧 locals[0]。 *)
Lemma compile_bool_assign_local0_correct :
  forall (b : bool) (old : Z) (st0 : runtime_state) (v : st_value),
    st0 = {| rt_values := nil;
             rt_frames := (Build_sasm_frame [V_I32 old] 0 0 []) :: nil;
             rt_memory := nil;
             rt_cycle_cnt := 0 |} ->
    corest_eval_expr nil (CE_LIT (L_BOOL b)) = Some v ->
    exists (st' : runtime_state),
      exec_instrs st0
        (compile_stmt ((ID "x", 0) :: nil)
           ((ID "x", T_BOOL) :: nil)
           (CS_ASSIGN (ID "x") (CE_LIT (L_BOOL b)))) = Some st' /\
      match st'.(rt_frames) with
      | f :: _ =>
          List.nth_error f.(frame_locals) 0 = Some (V_I32 (if b then 1 else 0))
      | nil => False
      end.
Proof.
  intros b old st0 v Hst Heval.
  rewrite Hst.
  simpl in Heval; inversion Heval; subst.
  destruct b; simpl.
  all: eexists; split; [reflexivity | reflexivity].
Qed.

(* 旧的整体命题 compile_expr_correct 缺少帧一致性、内存/质量区初始化和
   类型分派前提，对任意 st0 并不成立。
   当前以逐构造闭合引理替代：
   - compile_literal_correct
   - compile_var_correct
   - compile_int_binop_literal_correct
   完整语义保持定理需在引入 frame/memory/type 一致性不变量后重建。 *)

(* 第 8/9 部分：CoreST → SafeASM 语义保持
   旧的 compile_stmt_correct/codegen_correct 空真版本已删除。
   真实版本待 SafeASM PC 字节语义落地后，按配置式 CoreST 语义重建。 *)

Lemma compile_int_assign_local0_shape :
  forall (n : Z),
    compile_stmt ((ID "x", 0) :: nil)
      ((ID "x", T_DINT) :: nil)
      (CS_ASSIGN (ID "x") (CE_LIT (L_INT n))) =
    [I32_CONST n; LOCAL_SET 0].
Proof.
  intros n.
  reflexivity.
Qed.

Lemma compile_bool_assign_local0_shape :
  forall (b : bool),
    compile_stmt ((ID "x", 0) :: nil)
      ((ID "x", T_BOOL) :: nil)
      (CS_ASSIGN (ID "x") (CE_LIT (L_BOOL b))) =
    [I32_CONST (if b then 1 else 0); LOCAL_SET 0].
Proof.
  intros b.
  destruct b; reflexivity.
Qed.

Lemma compile_var_local0_shape :
  compile_expr ((ID "x", 0) :: nil) (CE_VAR (ID "x")) =
  [LOCAL_GET 0].
Proof.
  reflexivity.
Qed.

Lemma compile_int_add_literal_shape :
  forall (n1 n2 : Z),
    compile_expr nil
      (CE_BIN_OP B_ADD (CE_LIT (L_INT n1)) (CE_LIT (L_INT n2))) =
    [I32_CONST n1; I32_CONST n2; I32_ADD].
Proof.
  intros n1 n2.
  reflexivity.
Qed.

Lemma compile_var_local0_pc :
  forall (m : sasm_module) (fn : sasm_function) (old : Z),
    lookup_function m 0 = Some fn ->
    fn.(sasm_body) = [LOCAL_GET 0] ->
    exists (s' : runtime_state),
      multi_pc_step m
        {| rt_values := nil;
           rt_frames :=
             Build_sasm_frame [V_I32 old] 0 0 [] :: nil;
           rt_memory := nil;
           rt_cycle_cnt := 0 |}
        s' /\
      s'.(rt_values) = [V_I32 old].
Proof.
  intros m fn old Hlook Hbody.
  set (f := Build_sasm_frame [V_I32 old] 0 0 []).
  set (s0 := {| rt_values := nil;
                rt_frames := f :: nil;
                rt_memory := nil;
                rt_cycle_cnt := 0 |}).
  exists (push_value (V_I32 old)
            (replace_top_frame_noinc s0 (set_frame_pc f 5))).
  split.
  - apply pc_i32_local_get_multi with (rest := nil) (idx := 0)
      (next := 5).
    + subst s0.
      reflexivity.
    + subst f.
      apply fetch_frame_instr_head with (fn := fn) (i := LOCAL_GET 0)
        (rest := nil).
      * exact Hlook.
      * exact Hbody.
      * reflexivity.
    + subst f.
      reflexivity.
  - subst s0 f.
    reflexivity.
Qed.

Lemma compile_int_assign_local0_pc :
  forall (m : sasm_module) (fn : sasm_function) (n : Z)
         (old : Z),
    lookup_function m 0 = Some fn ->
    fn.(sasm_body) = [I32_CONST n; LOCAL_SET 0] ->
    exists (s' : runtime_state),
      multi_pc_step m
        {| rt_values := nil;
           rt_frames :=
             Build_sasm_frame [V_I32 old] 0 0 [] :: nil;
           rt_memory := nil;
           rt_cycle_cnt := 0 |}
        s' /\
      match s'.(rt_frames) with
      | f :: _ =>
          List.nth_error f.(frame_locals) 0 = Some (V_I32 n)
      | nil => False
      end.
Proof.
  intros m fn n old Hlook Hbody.
  set (f := Build_sasm_frame [V_I32 old] 0 0 []).
  set (s0 := {| rt_values := nil;
                rt_frames := f :: nil;
                rt_memory := nil;
                rt_cycle_cnt := 0 |}).
  set (f1 := set_frame_pc f 5).
  set (s1 := push_value (V_I32 n) (replace_top_frame_noinc s0 f1)).
  set (f2 := {| frame_locals := list_set f.(frame_locals) 0 (V_I32 n);
                frame_func_idx := 0;
                frame_pc := 10;
                frame_block_stack := nil |}).
  exists (set_top_values_cycle s1 f2 nil).
  split.
  - apply pc_i32_const_local_set_multi with (m := m) (s := s0)
      (f := f) (rest := nil) (n := n) (next1 := 5) (next2 := 10)
      (restvs := nil).
    + subst s0.
      reflexivity.
    + subst s0.
      reflexivity.
    + subst f1 f.
      apply fetch_frame_instr_head with (fn := fn) (i := I32_CONST n)
        (rest := [LOCAL_SET 0]).
      * exact Hlook.
      * exact Hbody.
      * reflexivity.
    + subst f1 f.
      apply fetch_frame_instr_second with (fn := fn) (i := I32_CONST n)
        (j := LOCAL_SET 0) (rest := nil).
      * exact Hlook.
      * exact Hbody.
      * reflexivity.
  - subst f2 s1 s0 f.
    simpl.
    reflexivity.
Qed.

Lemma compile_bool_assign_local0_pc :
  forall (m : sasm_module) (fn : sasm_function) (b : bool)
         (old : Z),
    lookup_function m 0 = Some fn ->
    fn.(sasm_body) =
      [I32_CONST (if b then 1 else 0); LOCAL_SET 0] ->
    exists (s' : runtime_state),
      multi_pc_step m
        {| rt_values := nil;
           rt_frames :=
             Build_sasm_frame [V_I32 old] 0 0 [] :: nil;
           rt_memory := nil;
           rt_cycle_cnt := 0 |}
        s' /\
      match s'.(rt_frames) with
      | f :: _ =>
          List.nth_error f.(frame_locals) 0 =
            Some (V_I32 (if b then 1 else 0))
      | nil => False
      end.
Proof.
  intros m fn b old Hlook Hbody.
  destruct b.
  - exact (compile_int_assign_local0_pc m fn 1 old Hlook Hbody).
  - exact (compile_int_assign_local0_pc m fn 0 old Hlook Hbody).
Qed.

Lemma compile_var_assign_local0_pc :
  forall (m : sasm_module) (fn : sasm_function) (old src : Z),
    lookup_function m 0 = Some fn ->
    fn.(sasm_body) = [LOCAL_GET 1; LOCAL_SET 0] ->
    exists (s' : runtime_state),
      multi_pc_step m
        {| rt_values := nil;
           rt_frames :=
             Build_sasm_frame [V_I32 old; V_I32 src] 0 0 [] :: nil;
           rt_memory := nil;
           rt_cycle_cnt := 0 |}
        s' /\
      (match s'.(rt_frames) with
       | f :: _ =>
           List.nth_error f.(frame_locals) 0 = Some (V_I32 src)
       | nil => False
       end) /\
      pc_final_entry m s'.
Proof.
  intros m fn old src Hlook Hbody.
  set (f0 := Build_sasm_frame [V_I32 old; V_I32 src] 0 0 []).
  set (s0 := {| rt_values := nil;
                rt_frames := f0 :: nil;
                rt_memory := nil;
                rt_cycle_cnt := 0 |}).
  set (f1 := set_frame_pc f0 5).
  set (s1 := push_value (V_I32 src) (replace_top_frame_noinc s0 f1)).
  set (f2 :=
    {| frame_locals := list_set f1.(frame_locals) 0 (V_I32 src);
       frame_func_idx := f1.(frame_func_idx);
       frame_pc := 10;
       frame_block_stack := f1.(frame_block_stack) |}).
  exists (set_top_values_cycle s1 f2 nil).
  split.
  - eapply multi_pc_step_trans.
    + eapply pc_i32_local_get_multi with (m := m) (s := s0) (f := f0)
        (rest := nil) (idx := 1) (next := 5) (v := V_I32 src).
      * subst s0.
        reflexivity.
      * subst f0.
        apply fetch_frame_instr_head with (fn := fn) (i := LOCAL_GET 1)
          (rest := [LOCAL_SET 0]).
        -- exact Hlook.
        -- exact Hbody.
        -- reflexivity.
      * subst f0.
        reflexivity.
    + eapply Multi_pc_step.
      * eapply Pc_local_set.
        -- subst s1 s0.
           reflexivity.
        -- subst f2 f1 f0.
           apply fetch_frame_instr_second with (fn := fn)
             (i := LOCAL_GET 1) (j := LOCAL_SET 0) (rest := nil).
           ++ exact Hlook.
           ++ exact Hbody.
           ++ reflexivity.
        -- subst s1 s0.
           reflexivity.
      * apply Multi_pc_refl.
  - split.
    + subst f2 s1 s0 f1 f0.
      reflexivity.
    + unfold pc_final_entry.
      exists f2.
      split.
      * subst f2 s1 s0 f1 f0.
        reflexivity.
      * unfold pc_at_body_end.
        subst f2 s1 s0 f1 f0.
        simpl.
        rewrite Hlook.
        rewrite Hbody.
        simpl.
        split; reflexivity.
Qed.

Definition var_assign_program : corest_program :=
  {| cprog_functions :=
       [{| cfunc_name := ID "P";
           cfunc_return_type := None;
           cfunc_params := nil;
           cfunc_locals := [(ID "x", T_DINT); (ID "y", T_DINT)];
           cfunc_body := [CS_ASSIGN (ID "x") (CE_VAR (ID "y"))] |}];
     cprog_global_vars := nil;
     cprog_entry := ID "P";
     cprog_io_mapping := nil |}.

Lemma compile_var_assign_function_body :
  (compile_program var_assign_program).(sasm_functions) =
  [ {| sasm_func_type_idx := 0;
       sasm_locals := [I32; I32];
       sasm_body := [LOCAL_GET 1; LOCAL_SET 0];
       sasm_stack_depth := instr_seq_size [LOCAL_GET 1; LOCAL_SET 0];
       sasm_cycle_budget := 1000000 |} ].
Proof.
  unfold var_assign_program, compile_program.
  reflexivity.
Qed.

Theorem compile_var_assign_program_pc :
  forall (old src : Z),
    let m := compile_program var_assign_program in
    exists (s' : runtime_state),
      multi_pc_step m
        {| rt_values := nil;
           rt_frames :=
             Build_sasm_frame [V_I32 old; V_I32 src] 0 0 [] :: nil;
           rt_memory := nil;
           rt_cycle_cnt := 0 |}
        s' /\
      (match s'.(rt_frames) with
       | f :: _ =>
           List.nth_error f.(frame_locals) 0 = Some (V_I32 src)
       | nil => False
       end) /\
      pc_final_entry m s'.
Proof.
  intros old src.
  set (fn0 := {| sasm_func_type_idx := 0;
                 sasm_locals := [I32; I32];
                 sasm_body := [LOCAL_GET 1; LOCAL_SET 0];
                 sasm_stack_depth := instr_seq_size [LOCAL_GET 1; LOCAL_SET 0];
                 sasm_cycle_budget := 1000000 |}).
  pose proof compile_var_assign_function_body as Hfn.
  assert (Hlook : lookup_function (compile_program var_assign_program) 0
                    = Some fn0).
  { subst fn0.
    unfold lookup_function.
    rewrite Hfn.
    simpl.
    reflexivity. }
  assert (Hbody : fn0.(sasm_body) = [LOCAL_GET 1; LOCAL_SET 0]).
  { subst fn0.
    reflexivity. }
  destruct (compile_var_assign_local0_pc
              (compile_program var_assign_program) fn0 old src Hlook Hbody)
    as [s' [Hmulti [Hlocal Hfinal]]].
  exists s'.
  repeat split; assumption.
Qed.

Definition lit_assign_program (n : Z) : corest_program :=
  {| cprog_functions :=
       [{| cfunc_name := ID "P";
           cfunc_return_type := None;
           cfunc_params := nil;
           cfunc_locals := [(ID "x", T_DINT)];
           cfunc_body := [CS_ASSIGN (ID "x") (CE_LIT (L_INT n))] |}];
     cprog_global_vars := nil;
     cprog_entry := ID "P";
     cprog_io_mapping := nil |}.

Lemma compile_lit_assign_function_body :
  forall (n : Z),
    (compile_program (lit_assign_program n)).(sasm_functions) =
    [ {| sasm_func_type_idx := 0;
         sasm_locals := [I32];
         sasm_body := [I32_CONST n; LOCAL_SET 0];
         sasm_stack_depth :=
           instr_seq_size [I32_CONST n; LOCAL_SET 0];
         sasm_cycle_budget := 1000000 |} ].
Proof.
  intros n.
  unfold lit_assign_program, compile_program.
  reflexivity.
Qed.

Definition add_assign_program (n1 n2 : Z) : corest_program :=
  {| cprog_functions :=
       [{| cfunc_name := ID "P";
           cfunc_return_type := None;
           cfunc_params := nil;
           cfunc_locals := [(ID "x", T_DINT)];
           cfunc_body :=
             [CS_ASSIGN (ID "x")
                (CE_BIN_OP B_ADD (CE_LIT (L_INT n1)) (CE_LIT (L_INT n2)))] |}];
     cprog_global_vars := nil;
     cprog_entry := ID "P";
     cprog_io_mapping := nil |}.

Lemma compile_add_assign_function_body :
  forall (n1 n2 : Z),
    (compile_program (add_assign_program n1 n2)).(sasm_functions) =
    [ {| sasm_func_type_idx := 0;
         sasm_locals := [I32];
         sasm_body := [I32_CONST n1; I32_CONST n2; I32_ADD; LOCAL_SET 0];
         sasm_stack_depth :=
           instr_seq_size [I32_CONST n1; I32_CONST n2; I32_ADD; LOCAL_SET 0];
         sasm_cycle_budget := 1000000 |} ].
Proof.
  intros n1 n2.
  unfold add_assign_program, compile_program.
  reflexivity.
Qed.

Theorem compile_lit_program_pc :
  forall (n old : Z),
    let m := compile_program (lit_assign_program n) in
    exists (s' : runtime_state),
      multi_pc_step m
        {| rt_values := nil;
           rt_frames :=
             Build_sasm_frame [V_I32 old] 0 0 [] :: nil;
           rt_memory := nil;
           rt_cycle_cnt := 0 |}
        s' /\
      pc_final_entry m s' /\
      match s'.(rt_frames) with
      | f :: _ =>
          List.nth_error f.(frame_locals) 0 = Some (V_I32 n)
      | nil => False
      end.
Proof.
  intros n old.
  set (fn0 := {| sasm_func_type_idx := 0;
                 sasm_locals := [I32];
                 sasm_body := [I32_CONST n; LOCAL_SET 0];
                 sasm_stack_depth :=
                   instr_seq_size [I32_CONST n; LOCAL_SET 0];
                 sasm_cycle_budget := 1000000 |}).
  set (f := Build_sasm_frame [V_I32 old] 0 0 []).
  set (s0 := {| rt_values := nil;
                rt_frames := f :: nil;
                rt_memory := nil;
                rt_cycle_cnt := 0 |}).
  set (f1 := set_frame_pc f 5).
  set (s1 := push_value (V_I32 n) (replace_top_frame_noinc s0 f1)).
  set (f2 := {| frame_locals := list_set f.(frame_locals) 0 (V_I32 n);
                frame_func_idx := 0;
                frame_pc := 10;
                frame_block_stack := nil |}).
  pose proof (compile_lit_assign_function_body n) as Hfn.
  assert (Hlook : lookup_function (compile_program (lit_assign_program n)) 0
                    = Some fn0).
  { subst fn0.
    unfold lookup_function.
    rewrite Hfn.
    simpl.
    reflexivity. }
  assert (Hbody : fn0.(sasm_body) = [I32_CONST n; LOCAL_SET 0]).
  { subst fn0.
    reflexivity. }
  exists (set_top_values_cycle s1 f2 nil).
  split.
  - apply pc_i32_const_local_set_multi with (m := compile_program (lit_assign_program n))
      (s := s0) (f := f) (rest := nil) (n := n)
      (next1 := 5) (next2 := 10) (restvs := nil).
    + subst s0.
      reflexivity.
    + subst s0.
      reflexivity.
    + subst f1 f.
      apply fetch_frame_instr_head with (fn := fn0) (i := I32_CONST n)
        (rest := [LOCAL_SET 0]).
      * exact Hlook.
      * exact Hbody.
      * reflexivity.
    + subst f1 f.
      apply fetch_frame_instr_second with (fn := fn0) (i := I32_CONST n)
        (j := LOCAL_SET 0) (rest := nil).
      * exact Hlook.
      * exact Hbody.
      * reflexivity.
  - split.
    + unfold pc_final_entry.
      exists f2.
      split.
      * subst f2 s1 s0 f.
        reflexivity.
      * unfold pc_at_body_end.
        subst f2.
        simpl.
        split; reflexivity.
    + subst f2 s1 s0 f.
      reflexivity.
Qed.

Lemma compile_int_add_literal_pc :
  forall (m : sasm_module) (fn : sasm_function) (n1 n2 : Z),
    lookup_function m 0 = Some fn ->
    fn.(sasm_body) = [I32_CONST n1; I32_CONST n2; I32_ADD] ->
    exists (s' : runtime_state),
      multi_pc_step m
        {| rt_values := nil;
           rt_frames := Build_sasm_frame [] 0 0 [] :: nil;
           rt_memory := nil;
           rt_cycle_cnt := 0 |}
        s' /\
      s'.(rt_values) = [V_I32 (n1 + n2)] /\
      pc_final_entry m s'.
Proof.
  intros m fn n1 n2 Hlook Hbody.
  set (f0 := Build_sasm_frame [] 0 0 []).
  set (s0 := {| rt_values := nil;
                rt_frames := f0 :: nil;
                rt_memory := nil;
                rt_cycle_cnt := 0 |}).
  set (f1 := set_frame_pc f0 5).
  set (s1 := push_value (V_I32 n1)
             (replace_top_frame_noinc s0 f1)).
  set (f2 := set_frame_pc f1 10).
  set (s2 := push_value (V_I32 n2)
             (replace_top_frame_noinc s1 f2)).
  set (f3 := set_frame_pc f2
    (instr_size I32_ADD + instr_size (I32_CONST n2) + instr_size (I32_CONST n1))).
  exists (set_top_values_cycle s2 f3 [V_I32 (n1 + n2)]).
  split.
  - eapply multi_pc_step_trans.
    + eapply pc_i32_const_multi with (m := m) (s := s0) (f := f0)
        (rest := nil) (n := n1) (next := 5).
      * subst s0.
        reflexivity.
      * subst f0.
        apply fetch_frame_instr_head with (fn := fn) (i := I32_CONST n1)
          (rest := [I32_CONST n2; I32_ADD]).
        -- exact Hlook.
        -- exact Hbody.
        -- reflexivity.
    + eapply multi_pc_step_trans.
      * eapply pc_i32_const_multi with (m := m) (s := s1) (f := f1)
          (rest := nil) (n := n2) (next := 10).
        -- subst s1 s0.
           reflexivity.
        -- subst f2 f1 f0.
           apply fetch_frame_instr_second with (fn := fn)
             (i := I32_CONST n1) (j := I32_CONST n2) (rest := [I32_ADD]).
           ++ exact Hlook.
           ++ exact Hbody.
           ++ reflexivity.
      * eapply Multi_pc_step.
        -- subst s2 s1 s0 f3 f2 f1 f0.
           eapply Pc_i32_add.
           ++ reflexivity.
           ++ unfold fetch_frame_instr.
              simpl.
              rewrite Hlook.
              rewrite Hbody.
              reflexivity.
           ++ reflexivity.
        -- apply Multi_pc_refl.
  - split.
    + subst f3 s2 s1 s0 f2 f1 f0.
      reflexivity.
    + unfold pc_final_entry.
      exists f3.
      split.
      * subst f3 s2 s1 s0 f2 f1 f0.
        reflexivity.
      * unfold pc_at_body_end.
        subst f3 s2 s1 s0 f2 f1 f0.
        simpl.
        rewrite Hlook.
        rewrite Hbody.
        simpl.
        split; reflexivity.
Qed.

Lemma compile_int_add_assign_local0_pc :
  forall (m : sasm_module) (fn : sasm_function) (n1 n2 old : Z),
    lookup_function m 0 = Some fn ->
    fn.(sasm_body) =
      [I32_CONST n1; I32_CONST n2; I32_ADD; LOCAL_SET 0] ->
    exists (s' : runtime_state),
      multi_pc_step m
        {| rt_values := nil;
           rt_frames :=
             Build_sasm_frame [V_I32 old] 0 0 [] :: nil;
           rt_memory := nil;
           rt_cycle_cnt := 0 |}
        s' /\
      (match s'.(rt_frames) with
       | f :: _ =>
           List.nth_error f.(frame_locals) 0 = Some (V_I32 (n1 + n2))
       | nil => False
       end) /\
      pc_final_entry m s'.
Proof.
  intros m fn n1 n2 old Hlook Hbody.
  set (f0 := Build_sasm_frame [V_I32 old] 0 0 []).
  set (s0 := {| rt_values := nil;
                rt_frames := f0 :: nil;
                rt_memory := nil;
                rt_cycle_cnt := 0 |}).
  set (f1 := set_frame_pc f0 5).
  set (s1 := push_value (V_I32 n1)
             (replace_top_frame_noinc s0 f1)).
  set (f2 := set_frame_pc f1 10).
  set (s2 := push_value (V_I32 n2)
             (replace_top_frame_noinc s1 f2)).
  set (f3 :=
    {| frame_locals := list_set f2.(frame_locals) 0 (V_I32 (n1 + n2));
       frame_func_idx := f2.(frame_func_idx);
       frame_pc := 16;
       frame_block_stack := f2.(frame_block_stack) |}).
  exists
    (set_top_values_cycle
       (set_top_values_cycle s2 (set_frame_pc f2 11) [V_I32 (n1 + n2)])
       f3 nil).
  split.
  - eapply multi_pc_step_trans.
    + eapply pc_i32_const_multi with (m := m) (s := s0) (f := f0)
        (rest := nil) (n := n1) (next := 5).
      * subst s0.
        reflexivity.
      * subst f0.
        apply fetch_frame_instr_head with (fn := fn) (i := I32_CONST n1)
          (rest := [I32_CONST n2; I32_ADD; LOCAL_SET 0]).
        -- exact Hlook.
        -- exact Hbody.
        -- reflexivity.
    + eapply multi_pc_step_trans.
      * eapply pc_i32_const_multi with (m := m) (s := s1) (f := f1)
          (rest := nil) (n := n2) (next := 10).
        -- subst s1 s0.
           reflexivity.
        -- subst f2 f1 f0.
           apply fetch_frame_instr_second with (fn := fn)
             (i := I32_CONST n1) (j := I32_CONST n2)
             (rest := [I32_ADD; LOCAL_SET 0]).
           ++ exact Hlook.
           ++ exact Hbody.
           ++ reflexivity.
      * eapply pc_i32_add_then_local_set_multi with
          (m := m) (s := s2) (f := f2) (rest := nil)
          (v1 := n1) (v2 := n2) (vs := nil)
          (idx := 0) (next1 := 11) (next2 := 16).
        -- subst s2 s1 s0.
           reflexivity.
        -- subst f2 f1 f0.
           unfold fetch_frame_instr.
           simpl.
           rewrite Hlook.
           rewrite Hbody.
           vm_compute.
           reflexivity.
        -- subst s2 s1 s0.
           reflexivity.
        -- subst f2 f1 f0.
           unfold fetch_frame_instr.
           simpl.
           rewrite Hlook.
           rewrite Hbody.
           vm_compute.
           reflexivity.
  - split.
    + subst f3 s2 s1 s0 f2 f1 f0.
      reflexivity.
    + unfold pc_final_entry.
      exists f3.
      split.
      * subst f3 s2 s1 s0 f2 f1 f0.
        reflexivity.
      * unfold pc_at_body_end.
        subst f3 s2 s1 s0 f2 f1 f0.
        simpl.
        rewrite Hlook.
        rewrite Hbody.
        simpl.
        split; reflexivity.
Qed.

Theorem compile_add_assign_program_pc :
  forall (n1 n2 old : Z),
    let m := compile_program (add_assign_program n1 n2) in
    exists (s' : runtime_state),
      multi_pc_step m
        {| rt_values := nil;
           rt_frames :=
             Build_sasm_frame [V_I32 old] 0 0 [] :: nil;
           rt_memory := nil;
           rt_cycle_cnt := 0 |}
        s' /\
      (match s'.(rt_frames) with
       | f :: _ =>
           List.nth_error f.(frame_locals) 0 = Some (V_I32 (n1 + n2))
       | nil => False
       end) /\
      pc_final_entry m s'.
Proof.
  intros n1 n2 old.
  set (fn0 := {| sasm_func_type_idx := 0;
                 sasm_locals := [I32];
                 sasm_body :=
                   [I32_CONST n1; I32_CONST n2; I32_ADD; LOCAL_SET 0];
                 sasm_stack_depth :=
                   instr_seq_size
                     [I32_CONST n1; I32_CONST n2; I32_ADD; LOCAL_SET 0];
                 sasm_cycle_budget := 1000000 |}).
  pose proof (compile_add_assign_function_body n1 n2) as Hfn.
  assert (Hlook :
    lookup_function (compile_program (add_assign_program n1 n2)) 0
      = Some fn0).
  { subst fn0.
    unfold lookup_function.
    rewrite Hfn.
    simpl.
    reflexivity. }
  assert (Hbody : fn0.(sasm_body)
                  = [I32_CONST n1; I32_CONST n2; I32_ADD; LOCAL_SET 0]).
  { subst fn0.
    reflexivity. }
  destruct (compile_int_add_assign_local0_pc
              (compile_program (add_assign_program n1 n2))
              fn0 n1 n2 old Hlook Hbody)
    as [s' [Hmulti [Hlocal Hfinal]]].
  exists s'.
  repeat split; assumption.
Qed.

(* ================================================================
   第 10 部分：编译确定性
   ================================================================ *)

Theorem codegen_deterministic :
  forall (p : corest_program) (m1 m2 : sasm_module),
    compile_program p = m1 ->
    compile_program p = m2 ->
    m1 = m2.
Proof.
  intros p m1 m2 H1 H2.
  rewrite H1 in H2. subst. reflexivity.
Qed.
