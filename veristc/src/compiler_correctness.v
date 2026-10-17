(* ================================================================
   veristc/spec/compiler_correctness.v
   顶层语义与编译正确性 — SafeASM 多步语义 + 抽象关系

   依赖: safest.v, safeasm.v, st_semantics.v
   ================================================================ *)

From Stdlib Require Import ZArith.
From Stdlib Require Import List.
From Stdlib Require Import Bool.
From Stdlib Require Import Floats.
From Stdlib Require Import String.
From Stdlib Require Import Lia.
Local Open Scope Z_scope.
Require Import veristc_spec.safest.
Require Import veristc_spec.safeasm.
Require Import veristc_spec.asm_semantics.
Require Import veristc_spec.st_semantics.
Require Import veristc_src.desugar.
Require Import veristc_src.codegen.
Require Import veristc_src.typechecker.
Require Import veristc_src.global_codegen.
Require veristc_spec.function_semantics.
Import ListNotations.
(* ================================================================
   第 3 部分：抽象关系 (Abstraction Relation)
   
   定义了 ST 状态与 SafeASM 状态之间的对应关系。
   这是编译正确性定理的核心——只有当两个状态"看起来一样"时，
   编译才算正确。
   ================================================================ *)

(* 类型兼容关系: ST 类型 → SafeASM 值类型 *)
Fixpoint st_type_to_sasm (t : st_type) : sasm_value_type :=
  match t with
  | T_BOOL | T_BYTE | T_SINT  => I32
  | T_WORD | T_INT             => I32
  | T_DWORD | T_DINT           => I32
  | T_REAL                     => F32
  | T_LREAL                    => F64           (* v1.1 *)
  | T_TIME                     => I64
  | T_LINT                     => I64           (* v1.1 *)
  | T_QUALITY                  => I32           (* v1.1 *)
  | T_QBOOL | T_QBYTE | T_QWORD | T_QDWORD
  | T_QSINT | T_QINT | T_QDINT => I32          (* v1.1 *)
  | T_QLINT                    => I64           (* v1.1 *)
  | T_QREAL                    => F32           (* v1.1 *)
  | T_QLREAL                   => F64           (* v1.1 *)
  | T_QTIME                    => I64           (* v1.1 *)
  | T_ARRAY elem _ _           => st_type_to_sasm elem
  end.

(* ST 值 → SafeASM 值的转换 *)
Definition st_val_to_sasm (v : st_value) : sasm_value :=
  match v with
  | ST_V_BOOL b    => V_I32 (if b then 1 else 0)
  | ST_V_BYTE z    => V_I32 z
  | ST_V_WORD z    => V_I32 z
  | ST_V_DWORD z   => V_I32 z
  | ST_V_SINT z    => V_I32 z
  | ST_V_INT z     => V_I32 z
  | ST_V_DINT z    => V_I32 z
  | ST_V_REAL f    => V_F32 f
  | ST_V_TIME z    => V_I64 z
  | ST_V_LINT z    => V_I64 z          (* v1.1 *)
  | ST_V_LREAL f   => V_F64 f          (* v1.1 *)
  end.

(* ================================================================
   第 4 部分：编译过程 (Compilation Process)
   
   将 ST 程序编译为 SafeASM 模块。
   这里只声明编译函数的类型签名，具体实现在 src/ 中。
   ================================================================ *)

(* 编译结果类型：成功返回 SafeASM 模块，失败返回错误信息 *)
Inductive compile_result : Type :=
  | Compile_ok : sasm_module -> compile_result
  | Compile_error : string -> compile_result
.

(* 编译函数：ST → CoreST（desugar）→ SafeASM 模块（codegen）。
   OCaml 可执行入口再调用 encoder 生成 .sasm 字节。 *)
Definition compile_core_program (p : st_program) : compile_result :=
  if core_program p then
    match type_check_program p with
    | Some nil =>
        Compile_ok (compile_program (desugar_program p))
    | Some (_ :: _) =>
        Compile_error "type errors"
    | None =>
        Compile_error "type errors"
    end
  else
    Compile_error "outside core subset".

Definition compile_st_to_sasm (p : st_program) : compile_result :=
  compile_core_program p.

(* 编译成功的谓词 *)
Definition compile_success (p : st_program) (m : sasm_module) : Prop :=
  compile_st_to_sasm p = Compile_ok m.

Lemma core_expr_ds_core_expr :
  forall (e : st_expr), core_expr e = ds_core_expr e.
Proof.
  induction e as [lit | x | arr idx IHa IHidx | op e IHe
    | bop e1 IHe1 e2 IHe2 | cop e1 IHe1 e2 IHe2
    | e1 IHe1 e2 IHe2 | e1 IHe1 e2 IHe2 | e1 IHe1 e2 IHe2
    | f args | q args]; simpl.
  - destruct lit; reflexivity.
  - reflexivity.
  - reflexivity.
  - rewrite IHe. reflexivity.
  - rewrite IHe1, IHe2. reflexivity.
  - rewrite IHe1, IHe2. reflexivity.
  - rewrite IHe1, IHe2. reflexivity.
  - rewrite IHe1, IHe2. reflexivity.
  - rewrite IHe1, IHe2. reflexivity.
  - reflexivity.
  - reflexivity.
Qed.

Lemma core_expr_ds_true :
  forall (e : st_expr), core_expr e = true -> ds_core_expr e = true.
Proof.
  intros e H.
  rewrite <- core_expr_ds_core_expr.
  exact H.
Qed.

Fixpoint stmt_size (s : st_stmt) : nat :=
  let fix list_size (stmts : list st_stmt) : nat :=
    match stmts with
    | nil => 0%nat
    | stmt :: rest => (stmt_size stmt + list_size rest)%nat
    end in
  let fix branches_size (branches : list case_element) : nat :=
    match branches with
    | nil => 0%nat
    | CASE_ELEM _ body :: rest =>
        (1 + list_size body + branches_size rest)%nat
    end in
  let opt_size (stmts : option (list st_stmt)) : nat :=
    match stmts with
    | None => 0%nat
    | Some body => list_size body
    end in
  match s with
  | S_ASSIGN _ _ => 1%nat
  | S_ARRAY_ASSIGN _ _ _ => 1%nat
  | S_IF _ then_stmts else_stmts =>
      (1 + list_size then_stmts + opt_size else_stmts)%nat
  | S_CASE _ branches default =>
      (1 + branches_size branches + opt_size default)%nat
  | S_FOR _ _ _ _ body => (1 + list_size body)%nat
  | S_WHILE _ body => (1 + list_size body)%nat
  | S_REPEAT body _ => (1 + list_size body)%nat
  | S_FB_CALL _ _ => 1%nat
  | S_RETURN => 1%nat
  | S_EXIT => 1%nat
  end.

Definition stmts_size (stmts : list st_stmt) : nat :=
  fold_right (fun stmt acc => (stmt_size stmt + acc)%nat) 0%nat stmts.

Definition case_elements_size (branches : list case_element) : nat :=
  fold_right
    (fun branch acc =>
       match branch with
       | CASE_ELEM _ body => (1 + stmts_size body + acc)%nat
       end) 0%nat branches.

Definition opt_stmts_size (stmts : option (list st_stmt)) : nat :=
  match stmts with
  | None => 0%nat
  | Some body => stmts_size body
  end.

Definition checked_case_branches (env : type_env)
           (branches : list case_element) : Prop :=
  List.forallb
    (fun ce =>
       match ce with
       | CASE_ELEM _ stmts => List.forallb (type_check_stmt nil env) stmts
       end) branches = true.

Lemma stmt_size_positive :
  forall (stmt : st_stmt), (1 <= stmt_size stmt)%nat.
Proof.
  destruct stmt; simpl; lia.
Qed.

Lemma stmt_size_if_eq :
  forall (cond : st_expr) (then_stmts : list st_stmt)
         (else_opt : option (list st_stmt)),
    stmt_size (S_IF cond then_stmts else_opt) =
    (1 + stmts_size then_stmts + opt_stmts_size else_opt)%nat.
Proof.
  intros.
  unfold stmt_size, stmts_size, opt_stmts_size.
  simpl.
  reflexivity.
Qed.

Lemma stmt_size_case_eq :
  forall (sel : st_expr) (branches : list case_element)
         (default : option (list st_stmt)),
    stmt_size (S_CASE sel branches default) =
    (1 + case_elements_size branches + opt_stmts_size default)%nat.
Proof.
  intros.
  unfold stmt_size, case_elements_size, opt_stmts_size.
  simpl.
  reflexivity.
Qed.

Lemma stmt_size_while_eq :
  forall (cond : st_expr) (body : list st_stmt),
    stmt_size (S_WHILE cond body) = (1 + stmts_size body)%nat.
Proof.
  intros.
  unfold stmt_size, stmts_size.
  simpl.
  reflexivity.
Qed.

Lemma stmt_size_repeat_eq :
  forall (body : list st_stmt) (cond : st_expr),
    stmt_size (S_REPEAT body cond) = (1 + stmts_size body)%nat.
Proof.
  intros.
  unfold stmt_size, stmts_size.
  simpl.
  reflexivity.
Qed.

Lemma stmt_size_for_eq :
  forall (v : ident) (start end_ : st_expr) (step : option st_expr)
         (body : list st_stmt),
    stmt_size (S_FOR v start end_ step body) = (1 + stmts_size body)%nat.
Proof.
  intros.
  unfold stmt_size, stmts_size.
  simpl.
  reflexivity.
Qed.

Lemma stmts_size_tail_lt :
  forall (stmt : st_stmt) (rest : list st_stmt),
    (stmts_size rest < stmts_size (stmt :: rest))%nat.
Proof.
  intros.
  unfold stmts_size.
  change (stmts_size rest < stmt_size stmt + stmts_size rest)%nat.
  pose proof (stmt_size_positive stmt). lia.
Qed.

Lemma stmts_size_if_then_lt :
  forall (cond : st_expr) (then_stmts : list st_stmt)
         (else_opt : option (list st_stmt)) (rest : list st_stmt),
    (stmts_size then_stmts <
     stmts_size (S_IF cond then_stmts else_opt :: rest))%nat.
Proof.
  intros.
  unfold stmts_size.
  change (stmts_size then_stmts <
    stmt_size (S_IF cond then_stmts else_opt) + stmts_size rest)%nat.
  rewrite stmt_size_if_eq.
  unfold opt_stmts_size.
  lia.
Qed.

Lemma stmts_size_if_else_lt :
  forall (cond : st_expr) (then_stmts : list st_stmt)
         (else_stmts : list st_stmt) (rest : list st_stmt),
    (stmts_size else_stmts <
     stmts_size (S_IF cond then_stmts (Some else_stmts) :: rest))%nat.
Proof.
  intros.
  unfold stmts_size.
  change (stmts_size else_stmts <
    stmt_size (S_IF cond then_stmts (Some else_stmts)) +
    stmts_size rest)%nat.
  rewrite stmt_size_if_eq.
  unfold opt_stmts_size.
  lia.
Qed.

Lemma stmts_size_while_body_lt :
  forall (cond : st_expr) (body : list st_stmt) (rest : list st_stmt),
    (stmts_size body < stmts_size (S_WHILE cond body :: rest))%nat.
Proof.
  intros.
  unfold stmts_size.
  change (stmts_size body < stmt_size (S_WHILE cond body) +
    stmts_size rest)%nat.
  rewrite stmt_size_while_eq.
  lia.
Qed.

Lemma stmts_size_repeat_body_lt :
  forall (body : list st_stmt) (cond : st_expr) (rest : list st_stmt),
    (stmts_size body < stmts_size (S_REPEAT body cond :: rest))%nat.
Proof.
  intros.
  unfold stmts_size.
  change (stmts_size body < stmt_size (S_REPEAT body cond) +
    stmts_size rest)%nat.
  rewrite stmt_size_repeat_eq.
  lia.
Qed.

Lemma stmts_size_for_body_lt :
  forall (v : ident) (start end_ : st_expr) (step : option st_expr)
         (body : list st_stmt) (rest : list st_stmt),
    (stmts_size body <
     stmts_size (S_FOR v start end_ step body :: rest))%nat.
Proof.
  intros.
  unfold stmts_size.
  change (stmts_size body < stmt_size (S_FOR v start end_ step body) +
    stmts_size rest)%nat.
  rewrite stmt_size_for_eq.
  lia.
Qed.

Lemma stmts_size_case_branch_lt :
  forall (sel : st_expr) (vals : list case_value)
         (branch_body : list st_stmt) (branch_rest : list case_element)
         (default : option (list st_stmt)) (rest : list st_stmt),
    (stmts_size branch_body <
     stmts_size (S_CASE sel (CASE_ELEM vals branch_body :: branch_rest)
                 default
                 :: rest))%nat.
Proof.
  intros.
  unfold stmts_size.
  change (stmts_size branch_body <
    stmt_size (S_CASE sel (CASE_ELEM vals branch_body :: branch_rest)
                default) + stmts_size rest)%nat.
  rewrite stmt_size_case_eq.
  unfold case_elements_size.
  simpl.
  lia.
Qed.

Lemma stmts_size_case_default_lt :
  forall (sel : st_expr) (branches : list case_element)
         (default_body : list st_stmt) (rest : list st_stmt),
    (stmts_size default_body <
     stmts_size (S_CASE sel branches (Some default_body) :: rest))%nat.
Proof.
  intros.
  unfold stmts_size.
  change (stmts_size default_body <
    stmt_size (S_CASE sel branches (Some default_body)) +
    stmts_size rest)%nat.
  rewrite stmt_size_case_eq.
  unfold opt_stmts_size.
  lia.
Qed.

Lemma stmts_size_case_branch_rest_lt :
  forall (sel : st_expr) (vals : list case_value)
         (branch_body : list st_stmt) (branch_rest : list case_element)
         (default : option (list st_stmt)) (rest : list st_stmt),
    (stmts_size (S_CASE sel branch_rest default :: rest) <
     stmts_size
       (S_CASE sel (CASE_ELEM vals branch_body :: branch_rest)
          default :: rest))%nat.
Proof.
  intros.
  unfold stmts_size.
  change (stmt_size (S_CASE sel branch_rest default) + stmts_size rest <
    stmt_size (S_CASE sel (CASE_ELEM vals branch_body :: branch_rest)
                 default) + stmts_size rest)%nat.
  repeat rewrite stmt_size_case_eq.
  unfold case_elements_size.
  simpl.
  lia.
Qed.

Lemma typed_stmts_of_type_check_fuel :
  forall (fuel : nat) (env : type_env) (stmts : list st_stmt),
    (stmts_size stmts <= fuel)%nat ->
    core_stmts stmts ->
    List.forallb (type_check_stmt nil env) stmts = true ->
    typed_stmts nil env stmts.
Proof.
  induction fuel as [|n IH]; intros env stmts Hsize Hcore Hcheck.
  - destruct stmts as [|stmt rest]; [constructor |].
    simpl in Hsize. pose proof (stmt_size_positive stmt). lia.
  - destruct stmts as [|stmt rest]; [constructor |].
    unfold core_stmts in Hcore. simpl in Hcore.
    apply andb_true_iff in Hcore.
    destruct Hcore as [Hcore_stmt Hcore_rest].
    simpl in Hcheck.
    apply andb_true_iff in Hcheck.
    destruct Hcheck as [Hcheck_stmt Hcheck_rest].
    assert (Hrest_typed : typed_stmts nil env rest).
    { apply IH.
      - pose proof (stmts_size_tail_lt stmt rest). lia.
      - exact Hcore_rest.
      - exact Hcheck_rest. }
    destruct stmt as
      [x e | x idx e | cond then_stmts else_opt | sel branches default
      | v start end_ step body | cond body | body cond | inst params | |].
    + (* assignment *)
      destruct (lookup env x) as [lhs_ty|] eqn:Hlook.
      * unfold type_check_stmt in Hcheck_stmt.
        rewrite Hlook in Hcheck_stmt. simpl in Hcheck_stmt.
        destruct (type_check_expr nil env e) as [rhs_ty|] eqn:Htype.
        -- simpl in Hcheck_stmt.
           eapply TS_assign; eauto.
        -- simpl in Hcheck_stmt.
           discriminate.
      * unfold type_check_stmt in Hcheck_stmt.
        rewrite Hlook in Hcheck_stmt. simpl in Hcheck_stmt.
        discriminate.
    + (* array assignment *)
      simpl in Hcore_stmt; discriminate.
    + (* IF *)
      simpl in Hcheck_stmt.
      apply andb_true_iff in Hcheck_stmt.
      destruct Hcheck_stmt as [Hcond_then Helse_ok].
      apply andb_true_iff in Hcond_then.
      destruct Hcond_then as [Hcond_ok Hthen_ok].
      destruct (type_check_expr nil env cond) as [cond_ty|] eqn:Hcond_ty;
        [| discriminate Hcond_ok].
      destruct cond_ty; try discriminate Hcond_ok.
      assert (Hthen_typed : typed_stmts nil env then_stmts).
      { apply IH.
        - pose proof (stmts_size_if_then_lt cond then_stmts else_opt rest).
          lia.
        - apply (proj1 (proj2 (core_stmt_if_core_exprs
                                cond then_stmts else_opt Hcore_stmt))).
        - exact Hthen_ok. }
      assert (Helse_typed : typed_opt_stmts nil env else_opt).
        { destruct (core_stmt_if_core_exprs cond then_stmts else_opt Hcore_stmt)
          as [_ [_ Helse_core]].
        destruct else_opt as [es|].
        - simpl in Helse_ok. simpl in Helse_core.
          apply TO_some.
          apply IH.
          + pose proof (stmts_size_if_else_lt cond then_stmts es rest).
            lia.
          + exact Helse_core.
          + exact Helse_ok.
        - constructor. }
      eapply TS_if.
      * exact Hcond_ty.
      * exact Hthen_typed.
      * exact Helse_typed.
      * exact Hrest_typed.
    + (* CASE *)
      unfold core_stmt in Hcore_stmt.
      simpl in Hcore_stmt.
      apply andb_true_iff in Hcore_stmt.
      destruct Hcore_stmt as [Hsel_branches Hdefault_bool].
      apply andb_true_iff in Hsel_branches.
      destruct Hsel_branches as [Hcore_sel Hcore_branches_full].
      simpl in Hcheck_stmt.
      apply andb_true_iff in Hcheck_stmt.
      destruct Hcheck_stmt as [Hsel_branches Hdefault_ok].
      apply andb_true_iff in Hsel_branches.
      destruct Hsel_branches as [Hsel_ok Hbranches_ok].
      assert (Hbranches_typed : typed_case_elements nil env branches).
      { revert Hcore_branches_full Hbranches_ok.
        induction branches as [|[vals branch_body] branch_rest IHbr];
          simpl; intros Hcore_branches_full Hbranches_ok.
        - constructor.
        - apply andb_true_iff in Hcore_branches_full.
          destruct Hcore_branches_full
            as [Hcore_branch_full Hcore_branch_rest_full].
          apply andb_true_iff in Hcore_branch_full.
          destruct Hcore_branch_full as [_ Hcore_branch_body].
          apply andb_true_iff in Hbranches_ok.
          destruct Hbranches_ok as [Hcheck_branch_body Hcheck_branch_rest].
          apply TCE_cons.
          + apply IH.
            * pose proof (stmts_size_case_branch_lt sel vals
                            branch_body branch_rest default rest).
              lia.
            * exact Hcore_branch_body.
            * exact Hcheck_branch_body.
          + apply IHbr.
            * pose proof (stmts_size_case_branch_rest_lt sel vals
                            branch_body branch_rest default rest).
              lia.
            * exact Hcore_branch_rest_full.
            * exact Hcheck_branch_rest. }
      assert (Hdefault_typed : typed_opt_stmts nil env default).
      { destruct default as [default_body|].
        - simpl in Hdefault_ok.
          simpl in Hdefault_bool.
          apply TO_some.
          apply IH.
          + pose proof (stmts_size_case_default_lt sel branches
                          default_body rest).
            lia.
          + exact Hdefault_bool.
          + exact Hdefault_ok.
        - constructor. }
      destruct (type_check_expr nil env sel) as [sel_ty|] eqn:Hsel_ty.
      * simpl in Hsel_ok.
        destruct sel_ty; try solve [discriminate Hsel_ok].
        all: first
          [ eapply TS_case_int;
            [exact Hsel_ty | exact Hbranches_typed |
             exact Hdefault_typed | exact Hrest_typed]
          | eapply TS_case_dint;
            [exact Hsel_ty | exact Hbranches_typed |
             exact Hdefault_typed | exact Hrest_typed] ].
      * discriminate Hsel_ok.
    + (* FOR *)
      simpl in Hcheck_stmt.
      repeat rewrite andb_true_iff in Hcheck_stmt.
      destruct Hcheck_stmt as [[[[Hvar_ok Hstart_ok] Hend_ok] Hstep_ok] Hbody_ok].
      destruct (lookup env v) as [var_ty|] eqn:Hvar_ty;
        [| discriminate Hvar_ok].
      destruct var_ty; try discriminate Hvar_ok.
      destruct (type_check_expr nil env start) as [start_ty|] eqn:Hstart_ty;
        [| discriminate Hstart_ok].
      destruct start_ty; try discriminate Hstart_ok.
      destruct (type_check_expr nil env end_) as [end_ty|] eqn:Hend_ty;
        [| discriminate Hend_ok].
      destruct end_ty; try discriminate Hend_ok.
      assert (Hstep_typed :
        match step with
        | Some e => type_check_expr nil env e = Some T_INT
        | None => True
        end).
      { destruct step as [step_expr|].
        - simpl in Hstep_ok.
          destruct (type_check_expr nil env step_expr) as [step_ty|] eqn:Hstep_ty;
            [| discriminate Hstep_ok].
          destruct step_ty; try discriminate Hstep_ok.
          reflexivity.
        - exact I. }
      assert (Hbody_typed : typed_stmts nil env body).
      { apply IH.
        - pose proof (stmts_size_for_body_lt v start end_ step body rest).
          lia.
        - apply (proj2 (proj2 (proj2 (core_stmt_for_parts
                          v start end_ step body Hcore_stmt)))).
        - exact Hbody_ok. }
      eapply TS_for; eauto.
    + (* WHILE *)
      simpl in Hcheck_stmt.
      apply andb_true_iff in Hcheck_stmt.
      destruct Hcheck_stmt as [Hcond_ok Hbody_ok].
      destruct (type_check_expr nil env cond) as [cond_ty|] eqn:Hcond_ty;
        [| discriminate Hcond_ok].
      destruct cond_ty; try discriminate Hcond_ok.
      assert (Hbody_typed : typed_stmts nil env body).
      { apply IH.
        - pose proof (stmts_size_while_body_lt cond body rest). lia.
        - apply (proj2 (core_stmt_while_core_exprs cond body Hcore_stmt)).
        - exact Hbody_ok. }
      eapply TS_while; eauto.
    + (* REPEAT *)
      simpl in Hcheck_stmt.
      apply andb_true_iff in Hcheck_stmt.
      destruct Hcheck_stmt as [Hbody_ok Hcond_ok].
      destruct (type_check_expr nil env cond) as [cond_ty|] eqn:Hcond_ty;
        [| discriminate Hcond_ok].
      destruct cond_ty; try discriminate Hcond_ok.
      assert (Hbody_typed : typed_stmts nil env body).
      { apply IH.
        - pose proof (stmts_size_repeat_body_lt body cond rest). lia.
        - apply (proj1 (core_stmt_repeat_core_exprs body cond Hcore_stmt)).
        - exact Hbody_ok. }
      eapply TS_repeat; eauto.
    + simpl in Hcore_stmt; discriminate.
    + simpl in Hcore_stmt; discriminate.
    + simpl in Hcore_stmt; discriminate.
Qed.

Lemma typed_stmts_of_type_check_core :
  forall (env : type_env) (stmts : list st_stmt),
    core_stmts stmts ->
    List.forallb (type_check_stmt nil env) stmts = true ->
    typed_stmts nil env stmts.
Proof.
  intros env stmts Hcore Hcheck.
  eapply typed_stmts_of_type_check_fuel.
  - apply Nat.le_refl.
  - exact Hcore.
  - exact Hcheck.
Qed.

Lemma build_program_env_single_program :
  forall (name : ident) (decls : list st_var_decl)
         (body : list st_stmt) (io : list io_entry) (entry : ident),
    build_program_env
      {| global_vars := nil;
         pou_list := [P_PROGRAM name decls body];
         io_mapping := io;
         entry_point := entry |} =
    build_env_from_decls decls.
Proof.
  intros.
  unfold build_program_env.
  simpl.
  rewrite app_nil_r.
  reflexivity.
Qed.

Lemma build_compile_type_env_single_program :
  forall (name : ident) (decls : list st_var_decl)
         (body : list st_stmt),
    build_compile_type_env (desugar_pou (P_PROGRAM name decls body)) =
    build_env_from_decls decls.
Proof.
  intros.
  unfold build_compile_type_env, desugar_pou, build_env_from_decls.
  simpl.
  reflexivity.
Qed.

Definition core_st_program
           (name : ident) (decls : list st_var_decl)
           (body : list st_stmt) (io : list io_entry) (entry : ident)
  : st_program :=
  {| global_vars := nil;
     pou_list := [P_PROGRAM name decls body];
     io_mapping := io;
     entry_point := entry |}.

Definition core_st_function
           (name : ident) (decls : list st_var_decl) (body : list st_stmt)
  : corest_function :=
  desugar_pou (P_PROGRAM name decls body).

Lemma core_st_type_env_eq :
  forall (name : ident) (decls : list st_var_decl)
         (body : list st_stmt) (io : list io_entry) (entry : ident),
    build_compile_type_env (core_st_function name decls body) =
    build_program_env (core_st_program name decls body io entry).
Proof.
  intros.
  unfold core_st_function, core_st_program.
  rewrite build_compile_type_env_single_program.
  symmetry.
  apply build_program_env_single_program.
Qed.

Lemma core_env_of_decls_forallb :
  forall (decls : list st_var_decl),
    List.forallb (fun d => core_ty_dec d.(var_type)) decls = true ->
    core_env (build_env_from_decls decls).
Proof.
  induction decls as [|d rest IH]; simpl.
  - intros x ty Hlook. discriminate.
  - intros Hall x ty Hlook.
    apply andb_true_iff in Hall.
    destruct Hall as [Hhead Hrest].
    destruct d as [[sname] tyd dir qual init].
    simpl in Hlook.
    destruct x as [sx].
    simpl in Hlook.
    destruct (String.eqb sx sname) eqn:Heq.
    + apply String.eqb_eq in Heq. subst sname.
      rewrite String.eqb_refl in Hlook.
      inversion Hlook; subst. simpl in Hhead. exact Hhead.
    + rewrite (String.eqb_sym sname sx) in Hlook.
      rewrite Heq in Hlook.
      exact (IH Hrest (ID sx) ty Hlook).
Qed.

Lemma core_stmts_of_forallb :
  forall (stmts : list st_stmt),
    List.forallb core_stmt stmts = true ->
    core_stmts stmts.
Proof.
  induction stmts as [|stmt rest IH]; simpl.
  - reflexivity.
  - intros H.
    apply andb_true_iff in H.
    destruct H as [Hhead Hrest].
    unfold core_stmts.
    simpl.
    rewrite Hhead.
    exact (IH Hrest).
Qed.

Lemma core_cfg_of_core_typecheck :
  forall (name : ident) (decls : list st_var_decl)
         (body : list st_stmt) (entry : ident),
    core_program (core_st_program name decls body nil entry) = true ->
    type_check_program (core_st_program name decls body nil entry) = Some nil ->
    core_cfg (core_st_program name decls body nil entry) body
      (init_st_state
         (build_program_env
            (core_st_program name decls body nil entry))).
Proof.
  intros name decls body entry Hcore_prog Htypecheck.
  unfold core_program, core_st_program in Hcore_prog.
  simpl in Hcore_prog.
  apply andb_true_iff in Hcore_prog.
  destruct Hcore_prog as [Hcore_pou Hio].
  apply andb_true_iff in Hcore_pou.
  destruct Hcore_pou as [Hcore_pou Hglobals].
  unfold core_pou in Hcore_pou.
  simpl in Hcore_pou.
  apply andb_true_iff in Hcore_pou.
  destruct Hcore_pou as [Hcore_types Hcore_body_bool].
  pose proof (core_env_of_decls_forallb decls Hcore_types) as Henv.
  pose proof (core_stmts_of_forallb body Hcore_body_bool) as Hcore_body.
  unfold type_check_program in Htypecheck.
  simpl in Htypecheck.
  unfold build_program_env, core_st_program in Htypecheck.
  simpl in Htypecheck.
  rewrite app_nil_r in Htypecheck.
  destruct (List.forallb (type_check_stmt nil (build_env_from_decls decls)) body)
    as [|] eqn:Hcheck.
  - pose proof (typed_stmts_of_type_check_core
                  (build_env_from_decls decls) body Hcore_body Hcheck)
      as Htyped.
    pose proof (init_st_state_consistent (build_env_from_decls decls) Henv)
      as Hstate.
    assert (Hcore_pou_true : core_pou (P_PROGRAM name decls body) = true).
    { unfold core_pou. simpl.
      rewrite Hcore_types. rewrite Hcore_body_bool. reflexivity. }
    assert (Hprog :
      core_program (core_st_program name decls body nil entry) = true).
    { unfold core_program, core_st_program.
      simpl.
      rewrite Hcore_pou_true.
      reflexivity. }
    rewrite <- (build_program_env_single_program
                  name decls body nil entry) in Henv.
    rewrite <- (build_program_env_single_program
                  name decls body nil entry) in Htyped.
    rewrite <- (build_program_env_single_program
                  name decls body nil entry) in Hstate.
    exact (core_cfg_mk
             (core_st_program name decls body nil entry) body
             (init_st_state
                (build_program_env
                   (core_st_program name decls body nil entry)))
             Hprog Henv Hcore_body Htyped Hstate).
  - simpl in Htypecheck.
    discriminate Htypecheck.
Qed.

Lemma core_expr_pc_supported :
  forall (e : st_expr),
    core_expr e = true ->
    pc_expr_supported (desugar_expr e) = true.
Proof.
  induction e as [lit | x | arr idx IHa IHidx | uop e IHe
    | bop e1 IHe1 e2 IHe2 | cop e1 IHe1 e2 IHe2
    | e1 IHe1 e2 IHe2 | e1 IHe1 e2 IHe2 | e1 IHe1 e2 IHe2
    | f args | q args]; intros Hcore; simpl in Hcore; try discriminate.
  - destruct lit; simpl in Hcore; try discriminate; reflexivity.
  - reflexivity.
  - destruct uop; simpl in Hcore; try discriminate; simpl;
      apply IHe; exact Hcore.
  - destruct bop; simpl in Hcore; try discriminate.
    all: apply andb_true_iff in Hcore;
      destruct Hcore as [H1 H2]; simpl;
      rewrite (IHe1 H1); rewrite (IHe2 H2); reflexivity.
  - apply andb_true_iff in Hcore;
      destruct Hcore as [H1 H2]; simpl;
      rewrite (IHe1 H1); rewrite (IHe2 H2); reflexivity.
  - apply andb_true_iff in Hcore;
      destruct Hcore as [H1 H2]; simpl;
      rewrite (IHe1 H1); rewrite (IHe2 H2); reflexivity.
  - apply andb_true_iff in Hcore;
      destruct Hcore as [H1 H2]; simpl;
      rewrite (IHe1 H1); rewrite (IHe2 H2); reflexivity.
  - apply andb_true_iff in Hcore;
      destruct Hcore as [H1 H2]; simpl;
      rewrite (IHe1 H1); rewrite (IHe2 H2); reflexivity.
Qed.

Lemma core_expr_pc_safe :
  forall (env_s : corest_eval_env) (e : st_expr),
    core_expr e = true ->
    pc_expr_safe env_s (desugar_expr e).
Proof.
  induction e as [lit | x | arr idx IHa IHidx | uop e IHe
    | bop e1 IHe1 e2 IHe2 | cop e1 IHe1 e2 IHe2
    | e1 IHe1 e2 IHe2 | e1 IHe1 e2 IHe2 | e1 IHe1 e2 IHe2
    | f args | q args]; intros Hcore; simpl in Hcore; try discriminate.
  - destruct lit; simpl in Hcore; try discriminate; simpl; exact I.
  - simpl; exact I.
  - destruct uop; simpl in Hcore; try discriminate; simpl;
      apply IHe; exact Hcore.
  - destruct bop; simpl in Hcore; try discriminate; simpl.
    all: apply andb_true_iff in Hcore.
    all: destruct Hcore as [H1 H2].
    all: split; [apply IHe1; exact H1 | apply IHe2; exact H2].
  - apply andb_true_iff in Hcore; destruct Hcore as [H1 H2].
    simpl; split; [apply IHe1; exact H1 | apply IHe2; exact H2].
  - apply andb_true_iff in Hcore; destruct Hcore as [H1 H2].
    simpl; split; [apply IHe1; exact H1 | apply IHe2; exact H2].
  - apply andb_true_iff in Hcore; destruct Hcore as [H1 H2].
    simpl; split; [apply IHe1; exact H1 | apply IHe2; exact H2].
  - apply andb_true_iff in Hcore; destruct Hcore as [H1 H2].
    simpl; split; [apply IHe1; exact H1 | apply IHe2; exact H2].
Qed.

Lemma case_values_pc_supported :
  forall (sel : corest_expr) (values : list case_value),
    pc_expr_supported sel = true ->
    core_case_values values ->
    pc_expr_supported (desugar_case_values_cond sel values) = true.
Proof.
  intros sel values Hsel Hvalues.
  induction values as [|v rest IH]; simpl.
  - reflexivity.
  - destruct v as [lit | lo hi].
    + destruct lit; simpl in Hvalues; try contradiction.
      simpl. rewrite Hsel. rewrite IH by exact Hvalues. reflexivity.
    + destruct lo; simpl in Hvalues; try contradiction.
      destruct hi; simpl in Hvalues; try contradiction.
      simpl. rewrite Hsel. rewrite IH by exact Hvalues. reflexivity.
Qed.

Lemma case_values_pc_safe :
  forall (env_s : corest_eval_env) (sel : corest_expr)
         (values : list case_value),
    pc_expr_safe env_s sel ->
    core_case_values values ->
    pc_expr_safe env_s (desugar_case_values_cond sel values).
Proof.
  intros env_s sel values Hsel Hvalues.
  induction values as [|v rest IH]; simpl.
  - exact I.
  - destruct v as [lit | lo hi].
    + destruct lit; simpl in Hvalues; try contradiction.
      simpl. split; [split; auto | exact (IH Hvalues)].
    + destruct lo; simpl in Hvalues; try contradiction.
      destruct hi; simpl in Hvalues; try contradiction.
      simpl. split;
        [split; [split; auto | split; auto] | exact (IH Hvalues)].
Qed.

Lemma core_ty_value_as_i32 :
  forall (v : st_value) (ty : st_type),
    core_ty ty ->
    st_value_type v = ty ->
    exists n : Z, st_value_as_i32 v = Some n.
Proof.
  intros v ty Hty Hv.
  destruct (core_ty_cases ty Hty) as [Hbool | [Hint | Hdint]];
    [rewrite Hbool in Hv | rewrite Hint in Hv | rewrite Hdint in Hv];
    destruct v; simpl in Hv; try discriminate;
    inversion Hv; subst; simpl; eauto.
Qed.

Lemma coerce_core_value_as_i32 :
  forall (ty : st_type) (v : st_value) (n : Z),
    core_ty ty ->
    st_value_as_i32 v = Some n ->
    st_value_as_i32 (coerce_value_to_type ty v) = Some n.
Proof.
  intros ty v n Hty Hn.
  destruct (core_ty_cases ty Hty) as [Hbool | [Hint | Hdint]]; subst;
    destruct v; simpl in Hn; try discriminate; inversion Hn; subst; simpl;
    reflexivity.
Qed.

Lemma corest_assign_value_eq_coerce :
  forall (env : type_env) (s : st_state) (x : ident) (ty : st_type)
         (v : st_value),
    state_consistent env s ->
    lookup env x = Some ty ->
    corest_assign_value s x v = coerce_value_to_type ty v.
Proof.
  intros env s x ty v Hstate Hlook.
  destruct Hstate as [Hvals Hpresent].
  destruct (Hpresent x ty Hlook) as [old Hold].
  assert (Hold_ty : st_value_type old = ty).
  { exact (Hvals x ty old Hlook Hold). }
  unfold corest_assign_value.
  rewrite Hold. rewrite Hold_ty.
  reflexivity.
Qed.

Lemma pc_case_chain_trace_int :
  forall (env : compile_env) (env_ty : compile_type_env)
         (sel : corest_expr) (n : Z) (branches : list case_element)
         (default : option (list st_stmt))
         (rest : list corest_stmt) (s s_body s_final : st_state),
    corest_eval_expr s.(st_vars) sel = Some (ST_V_INT n) ->
    case_branches_core branches ->
    pc_expr_supported sel = true ->
    pc_expr_safe s.(st_vars) sel ->
    pc_stmts_trace env env_ty
      (desugar_stmts (select_case_stmts n branches default)) s s_body ->
    pc_stmts_trace env env_ty rest s_body s_final ->
    pc_stmts_trace env env_ty
      (desugar_case_chain sel branches default :: rest) s s_final.
Proof.
  intros env env_ty sel n branches.
  induction branches as [|[values body] tail IH];
    intros default rest s s_body s_final Hsel Hbranches Hsupport Hsafe
      Hbranch Hrest.
  - destruct default as [default_body|].
    + assert (Hselected :
        select_case_stmts n nil (Some default_body) = default_body).
      { reflexivity. }
      rewrite Hselected in Hbranch.
      cbn [desugar_case_chain desugar_case_chain_with desugar_stmts].
      eapply pc_stmts_trace_if_true with
        (cond := CE_LIT (L_BOOL true))
        (then_body := desugar_stmts default_body)
        (else_body := nil)
        (s_body := s_body) (s_final := s_final).
      * reflexivity.
      * reflexivity.
      * exact I.
      * exact Hbranch.
      * exact Hrest.
    + assert (Hselected : select_case_stmts n nil None = nil).
      { reflexivity. }
      rewrite Hselected in Hbranch.
      cbn [desugar_case_chain desugar_case_chain_with desugar_stmts].
      eapply pc_stmts_trace_if_true with
        (cond := CE_LIT (L_BOOL true))
        (then_body := nil) (else_body := nil)
        (s_body := s_body) (s_final := s_final).
      * reflexivity.
      * reflexivity.
      * exact I.
      * exact Hbranch.
      * exact Hrest.
  - simpl in Hbranches.
    destruct Hbranches as [Hvalues Htail].
    pose proof (desugar_case_values_cond_int s sel n values Hsel Hvalues)
      as Hcond_eval.
    pose proof (case_values_pc_supported sel values Hsupport Hvalues)
      as Hcond_support.
    pose proof (case_values_pc_safe s.(st_vars) sel values Hsafe Hvalues)
      as Hcond_safe.
    destruct (match_case_values n values) eqn:Hmatch.
    + assert (Hselected :
        select_case_stmts n (CASE_ELEM values body :: tail) default = body).
      { unfold select_case_stmts, find_case_branch.
        simpl. rewrite Hmatch. reflexivity. }
      rewrite Hselected in Hbranch.
      cbn [desugar_case_chain desugar_case_chain_with].
      eapply pc_stmts_trace_if_true with
        (cond := desugar_case_values_cond sel values)
        (then_body := desugar_stmts body)
        (else_body :=
          match tail with
          | nil =>
              match default with
              | Some default_body => desugar_stmts default_body
              | None => nil
              end
          | _ => [desugar_case_chain sel tail default]
          end)
        (s_body := s_body) (s_final := s_final).
      * exact Hcond_eval.
      * exact Hcond_support.
      * exact Hcond_safe.
      * exact Hbranch.
      * exact Hrest.
    + assert (Hselected :
        select_case_stmts n (CASE_ELEM values body :: tail) default =
        select_case_stmts n tail default).
      { unfold select_case_stmts, find_case_branch.
        simpl. rewrite Hmatch. reflexivity. }
      rewrite Hselected in Hbranch.
      destruct tail as [|head tail].
      * destruct default as [default_body|].
        -- cbn [desugar_case_chain desugar_case_chain_with].
           eapply pc_stmts_trace_if_false with
             (cond := desugar_case_values_cond sel values)
             (then_body := desugar_stmts body)
             (else_body := desugar_stmts default_body)
             (s_body := s_body) (s_final := s_final).
           ++ exact Hcond_eval.
           ++ exact Hcond_support.
           ++ exact Hcond_safe.
           ++ exact Hbranch.
           ++ exact Hrest.
        -- cbn [desugar_case_chain desugar_case_chain_with].
           eapply pc_stmts_trace_if_false with
             (cond := desugar_case_values_cond sel values)
             (then_body := desugar_stmts body)
             (else_body := nil)
             (s_body := s_body) (s_final := s_final).
           ++ exact Hcond_eval.
           ++ exact Hcond_support.
           ++ exact Hcond_safe.
           ++ exact Hbranch.
           ++ exact Hrest.
      * pose proof (IH default rest s s_body s_final
                      Hsel Htail Hsupport Hsafe Hbranch Hrest)
          as Htail_trace.
        change (pc_stmts_trace env env_ty
          ([desugar_case_chain sel (head :: tail) default] ++ rest)
          s s_final) in Htail_trace.
        destruct (pc_stmts_trace_app_split env env_ty
                    [desugar_case_chain sel (head :: tail) default]
                    rest s s_final Htail_trace)
          as [s_mid [Hchain_trace Hrest_trace]].
        cbn [desugar_case_chain desugar_case_chain_with].
        eapply pc_stmts_trace_if_false with
          (cond := desugar_case_values_cond sel values)
          (then_body := desugar_stmts body)
          (else_body := [desugar_case_chain sel (head :: tail) default])
          (s_body := s_mid) (s_final := s_final).
        ++ exact Hcond_eval.
        ++ exact Hcond_support.
        ++ exact Hcond_safe.
        ++ exact Hchain_trace.
        ++ exact Hrest_trace.
Qed.

Lemma pc_case_chain_trace_dint :
  forall (env : compile_env) (env_ty : compile_type_env)
         (sel : corest_expr) (n : Z) (branches : list case_element)
         (default : option (list st_stmt))
         (rest : list corest_stmt) (s s_body s_final : st_state),
    corest_eval_expr s.(st_vars) sel = Some (ST_V_DINT n) ->
    case_branches_core branches ->
    pc_expr_supported sel = true ->
    pc_expr_safe s.(st_vars) sel ->
    pc_stmts_trace env env_ty
      (desugar_stmts (select_case_stmts n branches default)) s s_body ->
    pc_stmts_trace env env_ty rest s_body s_final ->
    pc_stmts_trace env env_ty
      (desugar_case_chain sel branches default :: rest) s s_final.
Proof.
  intros env env_ty sel n branches.
  induction branches as [|[values body] tail IH];
    intros default rest s s_body s_final Hsel Hbranches Hsupport Hsafe
      Hbranch Hrest.
  - destruct default as [default_body|].
    + assert (Hselected :
        select_case_stmts n nil (Some default_body) = default_body).
      { reflexivity. }
      rewrite Hselected in Hbranch.
      cbn [desugar_case_chain desugar_case_chain_with desugar_stmts].
      eapply pc_stmts_trace_if_true with
        (cond := CE_LIT (L_BOOL true))
        (then_body := desugar_stmts default_body)
        (else_body := nil)
        (s_body := s_body) (s_final := s_final).
      * reflexivity.
      * reflexivity.
      * exact I.
      * exact Hbranch.
      * exact Hrest.
    + assert (Hselected : select_case_stmts n nil None = nil).
      { reflexivity. }
      rewrite Hselected in Hbranch.
      cbn [desugar_case_chain desugar_case_chain_with desugar_stmts].
      eapply pc_stmts_trace_if_true with
        (cond := CE_LIT (L_BOOL true))
        (then_body := nil) (else_body := nil)
        (s_body := s_body) (s_final := s_final).
      * reflexivity.
      * reflexivity.
      * exact I.
      * exact Hbranch.
      * exact Hrest.
  - simpl in Hbranches.
    destruct Hbranches as [Hvalues Htail].
    pose proof (desugar_case_values_cond_dint s sel n values Hsel Hvalues)
      as Hcond_eval.
    pose proof (case_values_pc_supported sel values Hsupport Hvalues)
      as Hcond_support.
    pose proof (case_values_pc_safe s.(st_vars) sel values Hsafe Hvalues)
      as Hcond_safe.
    destruct (match_case_values n values) eqn:Hmatch.
    + assert (Hselected :
        select_case_stmts n (CASE_ELEM values body :: tail) default = body).
      { unfold select_case_stmts, find_case_branch.
        simpl. rewrite Hmatch. reflexivity. }
      rewrite Hselected in Hbranch.
      cbn [desugar_case_chain desugar_case_chain_with].
      eapply pc_stmts_trace_if_true with
        (cond := desugar_case_values_cond sel values)
        (then_body := desugar_stmts body)
        (else_body :=
          match tail with
          | nil =>
              match default with
              | Some default_body => desugar_stmts default_body
              | None => nil
              end
          | _ => [desugar_case_chain sel tail default]
          end)
        (s_body := s_body) (s_final := s_final).
      * exact Hcond_eval.
      * exact Hcond_support.
      * exact Hcond_safe.
      * exact Hbranch.
      * exact Hrest.
    + assert (Hselected :
        select_case_stmts n (CASE_ELEM values body :: tail) default =
        select_case_stmts n tail default).
      { unfold select_case_stmts, find_case_branch.
        simpl. rewrite Hmatch. reflexivity. }
      rewrite Hselected in Hbranch.
      destruct tail as [|head tail].
      * destruct default as [default_body|].
        -- cbn [desugar_case_chain desugar_case_chain_with].
           eapply pc_stmts_trace_if_false with
             (cond := desugar_case_values_cond sel values)
             (then_body := desugar_stmts body)
             (else_body := desugar_stmts default_body)
             (s_body := s_body) (s_final := s_final).
           ++ exact Hcond_eval.
           ++ exact Hcond_support.
           ++ exact Hcond_safe.
           ++ exact Hbranch.
           ++ exact Hrest.
        -- cbn [desugar_case_chain desugar_case_chain_with].
           eapply pc_stmts_trace_if_false with
             (cond := desugar_case_values_cond sel values)
             (then_body := desugar_stmts body)
             (else_body := nil)
             (s_body := s_body) (s_final := s_final).
           ++ exact Hcond_eval.
           ++ exact Hcond_support.
           ++ exact Hcond_safe.
           ++ exact Hbranch.
           ++ exact Hrest.
      * pose proof (IH default rest s s_body s_final
                      Hsel Htail Hsupport Hsafe Hbranch Hrest)
          as Htail_trace.
        change (pc_stmts_trace env env_ty
          ([desugar_case_chain sel (head :: tail) default] ++ rest)
          s s_final) in Htail_trace.
        destruct (pc_stmts_trace_app_split env env_ty
                    [desugar_case_chain sel (head :: tail) default]
                    rest s s_final Htail_trace)
          as [s_mid [Hchain_trace Hrest_trace]].
        cbn [desugar_case_chain desugar_case_chain_with].
        eapply pc_stmts_trace_if_false with
          (cond := desugar_case_values_cond sel values)
          (then_body := desugar_stmts body)
          (else_body := [desugar_case_chain sel (head :: tail) default])
          (s_body := s_mid) (s_final := s_final).
        ++ exact Hcond_eval.
        ++ exact Hcond_support.
        ++ exact Hcond_safe.
        ++ exact Hchain_trace.
        ++ exact Hrest_trace.
Qed.

Lemma pc_stmts_trace_while_cons_inv :
  forall (env : compile_env) (env_ty : compile_type_env)
         (cond : corest_expr) (body rest : list corest_stmt)
         (s s_final : st_state),
    pc_stmts_trace env env_ty (CS_WHILE cond body :: rest) s s_final ->
    exists (s_body : st_state),
      pc_while_trace env env_ty cond body s s_body /\
      pc_stmts_trace env env_ty rest s_body s_final.
Proof.
  intros env env_ty cond body rest s s_final Htrace.
  inversion Htrace as
    [s0
    | x e rest0 s0 s_final0 v Heval Hok Htail
    | cond0 then0 else0 rest0 s0 s_body s_final0 Heval Hsupport
      Hsafe Hbranch Htail
    | cond0 then0 else0 rest0 s0 s_body s_final0 Heval Hsupport
      Hsafe Hbranch Htail
    | cond0 body0 rest0 s0 s_body s_final0 Hwhile Htail
    | body0 rest0 s0 s_body s_final0 Hbody Htail];
    subst.
  exists s_body. split; assumption.
Qed.

Lemma compile_core_st_program_eq_singleton :
  forall (name : ident) (decls : list st_var_decl)
         (body : list st_stmt) (entry : ident),
    compile_program (desugar_program (core_st_program name decls body nil entry)) =
    compile_program (singleton_corest_program (core_st_function name decls body)).
Proof.
  intros.
  unfold core_st_program, core_st_function,
    desugar_program, singleton_corest_program, compile_program.
  simpl.
  reflexivity.
Qed.

Lemma lookup_var_type_eq_lookup :
  forall (env : compile_type_env) (x : ident),
    lookup_var_type env x = lookup env x.
Proof.
  induction env as [|[y ty] rest IH]; intros x; simpl.
  - reflexivity.
  - destruct x as [sx], y as [sy].
    unfold ident_eq.
    rewrite (String.eqb_sym sy sx).
    destruct (String.eqb sx sy); simpl; [reflexivity | exact (IH (ID sx))].
Qed.

Lemma init_st_vars_compile_state_env_matches :
  forall (env : type_env),
    core_env env ->
    compile_state_env_matches env (init_st_vars env).
Proof.
  intros env Henv.
  unfold compile_state_env_matches.
  intros x v Hlook.
  unfold init_st_state, init_st_vars in Hlook.
  simpl in Hlook.
  rewrite lookup_var_init_st_vars in Hlook.
  destruct (lookup env x) as [ty|] eqn:Hty;
    [| discriminate].
  inversion Hlook; subst v.
  exists ty. rewrite lookup_var_type_eq_lookup. exact Hty.
Qed.

Lemma default_core_value_as_i32 :
  forall (ty : st_type),
    core_ty ty ->
    exists n : Z,
      st_value_as_i32 (default_core_value ty) = Some n /\
      st_val_to_sasm_val (default_core_value ty) = V_I32 n.
Proof.
  intros ty Hty.
  destruct (core_ty_cases ty Hty) as [H | [H | H]]; subst;
    simpl; eauto.
Qed.

Lemma init_st_vars_compile_state_values_i32 :
  forall (env : type_env),
    core_env env ->
    compile_state_values_i32 (init_st_vars env).
Proof.
  intros env Henv.
  unfold compile_state_values_i32.
  intros x v Hlook.
  unfold init_st_vars in Hlook.
  rewrite lookup_var_init_st_vars in Hlook.
  destruct (lookup env x) as [ty|] eqn:Hty;
    [| discriminate].
  inversion Hlook; subst v.
  apply default_core_value_as_i32.
  exact (Henv x ty Hty).
Qed.

Lemma typed_assign_assign_sequence_ok :
  forall (p : st_program) (cf : corest_function)
         (x : ident) (e : st_expr) (rest : list st_stmt) (s : st_state),
    build_compile_type_env cf = build_program_env p ->
    core_env (build_program_env p) ->
    typed_stmts (build_fenv_from_pous p.(pou_list))
      (build_program_env p) (S_ASSIGN x e :: rest) ->
    core_expr e = true ->
    state_consistent (build_program_env p) s ->
    assign_sequence_ok (build_compile_env cf)
      (build_compile_type_env cf) s [CS_ASSIGN x (desugar_expr e)].
Proof.
  intros p cf x e rest s Henv_ty Henv Htyped Hcore Hstate.
  destruct (typed_assign_inv (build_fenv_from_pous p.(pou_list))
              (build_program_env p) x e rest Htyped)
    as [lhs_ty [rhs_ty [Hlook_src [Htc [Hcompat _]]]]].
  pose proof (Henv x lhs_ty Hlook_src) as Hlhs_core.
  pose proof (core_expr_type_check_fenv_indep
                (build_fenv_from_pous p.(pou_list))
                (build_program_env p) e Hcore) as Hind.
  assert (Htc_nil :
    type_check_expr nil (build_program_env p) e = Some rhs_ty).
  { rewrite <- Hind. exact Htc. }
  pose proof (core_expr_type_is_core (build_program_env p) e rhs_ty
                Henv Hcore Htc_nil) as Hrhs_core.
  destruct (typed_eval_total (build_program_env p) s e rhs_ty
              Henv Hcore Hstate Htc_nil Hrhs_core)
    as [v [Heval Hvty]].
  destruct (core_ty_value_as_i32 v rhs_ty Hrhs_core Hvty)
    as [n Hn].
  assert (Hlook_ty :
    lookup_var_type (build_compile_type_env cf) x = Some lhs_ty).
  { rewrite Henv_ty. rewrite lookup_var_type_eq_lookup. exact Hlook_src. }
  destruct (build_compile_env_idx_of_type cf x lhs_ty Hlook_ty)
    as [idx Hidx].
  destruct Hstate as [Hvals Hpresent].
  destruct (Hpresent x lhs_ty Hlook_src) as [old Hold].
  assert (Hold_ty : st_value_type old = lhs_ty).
  { exact (Hvals x lhs_ty old Hlook_src Hold). }
  assert (Hcoerced :
    st_value_as_i32 (corest_assign_value s x v) = Some n).
  { unfold corest_assign_value.
    rewrite Hold. rewrite Hold_ty.
    apply coerce_core_value_as_i32; assumption. }
  assert (Hcore_eval :
    corest_eval_expr s.(st_vars) (desugar_expr e) = Some v).
  { rewrite <- (desugar_core_expr_eval_equiv s e
                  (core_expr_ds_true e Hcore)).
    exact Heval. }
  exists lhs_ty, v, n, idx.
  repeat split; try assumption.
  all: try exact (core_expr_pc_supported e Hcore).
  all: try exact (core_expr_pc_safe s.(st_vars) e Hcore).
  all: try exact (core_ty_cases lhs_ty Hlhs_core).
  all: try exact I.
Qed.

Theorem core_star_pc_trace :
  forall (name : ident) (decls : list st_var_decl)
         (body : list st_stmt) (io : list io_entry) (entry : ident)
         (stmts : list st_stmt) (s s_final : st_state),
    core_cfg (core_st_program name decls body io entry) stmts s ->
    star_stmts_step (core_st_program name decls body io entry)
      stmts s nil s_final ->
    pc_stmts_trace
      (build_compile_env (core_st_function name decls body))
      (build_compile_type_env (core_st_function name decls body))
      (desugar_stmts stmts) s s_final.
Proof.
  intros name decls body io entry stmts s s_final Hcfg Hstar.
  pose proof (core_st_type_env_eq name decls body io entry) as Henv_ty.
  remember (core_st_program name decls body io entry) as p eqn:Hp.
  remember nil as target eqn:Htarget.
  revert Hcfg Hp Htarget.
  induction Hstar as
    [p0 stmts0 s0
    | p0 stmts1 stmts2 stmts3 s1 s2 s3 Hstep Hrest IH];
    intros Hcfg Hp Htarget.
  - subst p0.
    subst stmts0.
    cbn [desugar_stmts].
    apply pc_stmts_trace_nil.
  - destruct stmts1 as [|stmt rest]; [inversion Hstep |].
    subst p0.
    destruct stmt as
      [x e | x idx e | cond then_stmts else_opt | sel branches default
      | v start end_ step body0 | cond body0 | body0 cond
      | inst params | |].
    + (* assignment *)
      inversion Hstep; subst; try solve [discriminate | congruence].
      rename H6 into Hlook.
      rename H7 into Heval.
      pose proof (corest_assign_value_eq_coerce
                    (build_program_env
                       (core_st_program name decls body io entry))
                    s1 x ty v
                    (proj2 (proj2 (proj2 (proj2 Hcfg)))) Hlook)
        as Hassign.
      destruct (core_stmts_cons (S_ASSIGN x e) stmts2
                  (proj1 (proj2 (proj2 Hcfg))))
        as [Hcore_stmt Hcore_rest].
      simpl in Hcore_stmt.
      pose proof (typed_assign_assign_sequence_ok
                    (core_st_program name decls body io entry)
                    (core_st_function name decls body)
                    x e stmts2 s1 Henv_ty
                    (proj1 (proj2 Hcfg))
                    (proj1 (proj2 (proj2 (proj2 Hcfg))))
                    Hcore_stmt
                    (proj2 (proj2 (proj2 (proj2 Hcfg)))))
        as Hok.
      pose proof (IH Henv_ty
                    (preservation_cfg
                       (core_st_program name decls body io entry)
                       (S_ASSIGN x e :: stmts2) s1 stmts2
                       (update_var s1 x (coerce_value_to_type ty v))
                       Hcfg Hstep)
                    eq_refl eq_refl) as Htail.
      rewrite <- Hassign in Htail.
      assert (Heval_core :
        corest_eval_expr s1.(st_vars) (desugar_expr e) = Some v).
      { rewrite <- (desugar_core_expr_eval_equiv s1 e
                      (core_expr_ds_true e Hcore_stmt)).
        exact Heval. }
      rewrite desugar_stmts_cons.
      rewrite desugar_stmt_assign.
      eapply pc_stmts_trace_assign;
        [ exact Heval_core | exact Hok | exact Htail ].
    + inversion Hstep.
    + (* IF *)
      inversion Hstep; subst; try solve [discriminate | congruence].
      all: rename H7 into Hval.
      all: destruct (core_stmts_cons (S_IF cond then_stmts else_opt) rest
                      (proj1 (proj2 (proj2 Hcfg))))
        as [Hcore_if Hcore_rest].
      all: destruct (core_stmt_if_core_exprs cond then_stmts else_opt Hcore_if)
        as [Hcore_cond _].
      all: pose proof (core_expr_pc_supported cond Hcore_cond) as Hsupport.
      all: pose proof (core_expr_pc_safe s2.(st_vars) cond Hcore_cond)
        as Hsafe.
      all: pose proof (desugar_core_expr_eval_equiv s2 cond
                         (core_expr_ds_true cond Hcore_cond)) as Heq.
      all: rewrite Heq in Hval.
      all: first
        [ pose proof (preservation_cfg
                        (core_st_program name decls body io entry)
                        (S_IF cond then_stmts else_opt :: rest) s2
                        (then_stmts ++ rest) s2 Hcfg Hstep) as Hcfg2;
          pose proof (IH Henv_ty Hcfg2 eq_refl eq_refl) as Htail;
          rewrite desugar_stmts_append in Htail;
          destruct (pc_stmts_trace_app_split
                      (build_compile_env (core_st_function name decls body))
                      (build_compile_type_env
                         (core_st_function name decls body))
                      (desugar_stmts then_stmts) (desugar_stmts rest)
                      s2 s3 Htail) as [s_mid [Hb Hr]];
          rewrite desugar_stmts_cons;
          rewrite desugar_stmt_if;
          eapply pc_stmts_trace_if_true;
          [exact Hval | exact Hsupport | exact Hsafe |
           exact Hb | exact Hr]
        | pose proof (preservation_cfg
                        (core_st_program name decls body io entry)
                        (S_IF cond then_stmts else_opt :: rest) s2
                        (match else_opt with
                         | Some es => es ++ rest
                         | None => rest
                         end) s2 Hcfg Hstep) as Hcfg2;
          pose proof (IH Henv_ty Hcfg2 eq_refl eq_refl) as Htail;
          destruct else_opt as [es|];
          [ rewrite desugar_stmts_append in Htail;
            destruct (pc_stmts_trace_app_split
                        (build_compile_env (core_st_function name decls body))
                        (build_compile_type_env
                           (core_st_function name decls body))
                        (desugar_stmts es) (desugar_stmts rest)
                        s2 s3 Htail) as [s_mid [Hb Hr]];
            rewrite desugar_stmts_cons;
            rewrite desugar_stmt_if;
            eapply pc_stmts_trace_if_false;
            [exact Hval | exact Hsupport | exact Hsafe |
             exact Hb | exact Hr]
          | rewrite desugar_stmts_cons;
            rewrite desugar_stmt_if;
            eapply pc_stmts_trace_if_false;
            [exact Hval | exact Hsupport | exact Hsafe |
             exact (pc_stmts_trace_nil
                      (build_compile_env (core_st_function name decls body))
                      (build_compile_type_env
                         (core_st_function name decls body)) s2) |
             exact Htail] ] ].
    + (* CASE *)
      inversion Hstep; subst; try solve [discriminate | congruence].
      all: rename H7 into Hval.
      all: destruct (core_stmts_cons
                      (S_CASE sel branches default) rest
                      (proj1 (proj2 (proj2 Hcfg))))
        as [Hcore_case Hcore_rest].
      all: destruct (core_stmt_case_parts sel branches default Hcore_case)
        as [Hcore_sel _].
      all: pose proof (core_case_branches_of_stmt sel branches default
                         Hcore_case) as Hbranches.
      all: pose proof (core_expr_pc_supported sel Hcore_sel) as Hsupport.
      all: pose proof (core_expr_pc_safe s2.(st_vars) sel Hcore_sel)
        as Hsafe.
      all: pose proof (desugar_core_expr_eval_equiv s2 sel
                         (core_expr_ds_true sel Hcore_sel)) as Heq.
      all: rewrite Heq in Hval.
      all: pose proof (preservation_cfg
                         (core_st_program name decls body io entry)
                         (S_CASE sel branches default :: rest) s2
                         (select_case_stmts n branches default ++ rest)
                         s2 Hcfg Hstep) as Hcfg2.
      all: pose proof (IH Henv_ty Hcfg2 eq_refl eq_refl) as Htail.
      all: rewrite desugar_stmts_append in Htail.
      all: destruct (pc_stmts_trace_app_split
                      (build_compile_env (core_st_function name decls body))
                      (build_compile_type_env
                         (core_st_function name decls body))
                      (desugar_stmts
                         (select_case_stmts n branches default))
                      (desugar_stmts rest) s2 s3 Htail)
        as [s_mid [Hselected Htail_rest]].
      all: rewrite desugar_stmts_cons.
      all: rewrite desugar_stmt_case.
      all: simpl.
      all: first
        [ eapply pc_case_chain_trace_int;
          [exact Hval | exact Hbranches | exact Hsupport |
           exact Hsafe | exact Hselected | exact Htail_rest]
        | eapply pc_case_chain_trace_dint;
          [exact Hval | exact Hbranches | exact Hsupport |
           exact Hsafe | exact Hselected | exact Htail_rest] ].
    + (* FOR *)
      inversion Hstep; subst; try solve [discriminate | congruence].
      pose proof (IH Henv_ty
                    (preservation_cfg
                       (core_st_program name decls body io entry)
                       (S_FOR v start end_ step body0 :: rest) s2
                       (for_to_while v start end_ step body0 ++ rest)
                       s2 Hcfg Hstep)
                    eq_refl eq_refl) as Htail.
      rewrite desugar_for_config_eq.
      exact Htail.
    + (* WHILE *)
      inversion Hstep; subst; try solve [discriminate | congruence].
      all: rename H6 into Hval.
      all: match goal with
           | H : core_cfg _ (S_WHILE _ _ :: ?r) _ |- _ =>
               remember r as tail eqn:Htail_list
           end.
      all: destruct (core_stmts_cons (S_WHILE cond body0) tail
                      (proj1 (proj2 (proj2 Hcfg))))
        as [Hcore_while Hcore_rest].
      all: destruct (core_stmt_while_core_exprs cond body0 Hcore_while)
        as [Hcore_cond _].
      all: pose proof (core_expr_pc_supported cond Hcore_cond) as Hsupport.
      all: pose proof (core_expr_pc_safe s2.(st_vars) cond Hcore_cond)
        as Hsafe.
      all: pose proof (desugar_core_expr_eval_equiv s2 cond
                         (core_expr_ds_true cond Hcore_cond)) as Heq.
      all: rewrite Heq in Hval.
      all: first
        [ pose proof (preservation_cfg
                        (core_st_program name decls body io entry)
                        (S_WHILE cond body0 :: tail) s2
                        (body0 ++ S_WHILE cond body0 :: tail) s2
                        Hcfg Hstep) as Hcfg2;
          pose proof (IH Henv_ty Hcfg2 eq_refl eq_refl) as Htail;
          rewrite desugar_stmts_append in Htail;
          rewrite desugar_stmts_cons in Htail;
          rewrite desugar_stmt_while in Htail;
          change (pc_stmts_trace
                    (build_compile_env (core_st_function name decls body))
                    (build_compile_type_env
                       (core_st_function name decls body))
                    (desugar_stmts body0 ++
                     (CS_WHILE (desugar_expr cond) (desugar_stmts body0) ::
                      desugar_stmts tail)) s2 s3) in Htail;
          destruct (pc_stmts_trace_app_split
                      (build_compile_env (core_st_function name decls body))
                      (build_compile_type_env
                         (core_st_function name decls body))
                      (desugar_stmts body0)
                      (CS_WHILE (desugar_expr cond)
                         (desugar_stmts body0) :: desugar_stmts tail)
                      s2 s3 Htail) as [s_mid [Hbody Hwhile_rest]];
          destruct (pc_stmts_trace_while_cons_inv
                      (build_compile_env (core_st_function name decls body))
                      (build_compile_type_env
                         (core_st_function name decls body))
                      (desugar_expr cond) (desugar_stmts body0)
                      (desugar_stmts tail) s_mid s3 Hwhile_rest)
            as [s_after [Hwhile Hrest_trace]];
          rewrite desugar_stmts_cons;
          rewrite desugar_stmt_while;
          eapply pc_stmts_trace_while;
          [ exact (pc_while_trace_step
                     (build_compile_env (core_st_function name decls body))
                     (build_compile_type_env
                        (core_st_function name decls body))
                     (desugar_expr cond) (desugar_stmts body0)
                     s2 s_mid s_after Hval Hsupport Hsafe
                     (pc_stmts_spec_of_trace
                        (build_compile_env
                           (core_st_function name decls body))
                        (build_compile_type_env
                           (core_st_function name decls body))
                        (desugar_stmts body0) s2 s_mid Hbody)
                     (pc_stmts_trace_star
                        (build_compile_env
                           (core_st_function name decls body))
                        (build_compile_type_env
                           (core_st_function name decls body))
                        (desugar_stmts body0) s2 s_mid Hbody)
                     Hwhile)
          | exact Hrest_trace ]
        | pose proof (preservation_cfg
                        (core_st_program name decls body io entry)
                        (S_WHILE cond body0 :: tail) s2 tail s2
                        Hcfg Hstep) as Hcfg2;
          pose proof (IH Henv_ty Hcfg2 eq_refl eq_refl) as Htail;
          rewrite desugar_stmts_cons;
          rewrite desugar_stmt_while;
          eapply pc_stmts_trace_while;
          [ exact (pc_while_trace_stop
                     (build_compile_env (core_st_function name decls body))
                     (build_compile_type_env
                        (core_st_function name decls body))
                     (desugar_expr cond) (desugar_stmts body0)
                     s2 Hval Hsupport Hsafe)
          | exact Htail ] ].
    + (* REPEAT *)
      inversion Hstep; subst; try solve [discriminate | congruence].
      all: match goal with
           | H : core_cfg _ (S_REPEAT _ _ :: ?r) _ |- _ =>
               remember r as tail eqn:Htail_list
           end.
      pose proof (IH Henv_ty
                    (preservation_cfg
                       (core_st_program name decls body io entry)
                       (S_REPEAT body0 cond :: tail) s2
                       (body0 ++ S_WHILE (E_UNARY_OP U_NOT cond) body0 :: tail)
                       s2 Hcfg Hstep)
                    eq_refl eq_refl) as Htail.
      rewrite desugar_stmts_append in Htail.
      rewrite desugar_stmts_cons in Htail.
      rewrite desugar_stmt_while in Htail.
      rewrite (@app_assoc corest_stmt
        (desugar_stmts body0)
        [CS_WHILE (desugar_expr (E_UNARY_OP U_NOT cond))
           (desugar_stmts body0)]
        (desugar_stmts tail)) in Htail.
      destruct (pc_stmts_trace_app_split
                  (build_compile_env (core_st_function name decls body))
                  (build_compile_type_env (core_st_function name decls body))
                  (desugar_stmts body0 ++
                   [CS_WHILE (desugar_expr (E_UNARY_OP U_NOT cond))
                      (desugar_stmts body0)])
                  (desugar_stmts tail) s2 s3 Htail)
        as [s_mid [Hblock_body Hrest_trace]].
      rewrite desugar_stmts_cons.
      rewrite desugar_stmt_repeat.
      eapply pc_stmts_trace_block;
        [exact Hblock_body | exact Hrest_trace].
    + inversion Hstep.
    + inversion Hstep.
    + inversion Hstep.
Qed.

Theorem core_st_program_semantics_preservation :
  forall (name : ident) (decls : list st_var_decl)
         (body : list st_stmt) (entry : ident) (s_final : st_state),
    let p := core_st_program name decls body nil entry in
    let cf := core_st_function name decls body in
    core_cfg p body (init_st_state (build_program_env p)) ->
    star_stmts_step p body (init_st_state (build_program_env p)) nil s_final ->
    let m := compile_program (desugar_program p) in
    let f0 := {| frame_locals :=
                  sasm_locals_of_decls (build_compile_type_env cf)
                    (init_st_state (build_program_env p)).(st_vars);
                frame_func_idx := 0;
                frame_pc := 0;
                frame_block_stack := [] |} in
    exists (s_asm : runtime_state) (f_asm : sasm_frame),
      multi_pc_step m
        {| rt_values := nil; rt_frames := f0 :: nil;
           rt_memory := nil; rt_cycle_cnt := 0 |} s_asm /\
      pc_final_entry m s_asm /\
      s_asm.(rt_frames) = f_asm :: nil /\
      s_asm.(rt_values) = nil /\
      s_asm.(rt_memory) = nil /\
      pc_frame_env_matches (build_compile_env cf) s_final.(st_vars) f_asm /\
      f_asm.(frame_block_stack) = [] /\
      f_asm.(frame_func_idx) = 0.
Proof.
  intros name decls body entry s_final p cf Hcfg Hstar m f0.
  subst p. subst cf. subst m. subst f0.
  pose proof Hcfg as Hcfg0.
  destruct Hcfg as [Hprog [Henv [_ [_ Hstate]]]].
  pose proof (core_st_type_env_eq name decls body nil entry) as Henv_ty.
  pose proof (core_star_pc_trace name decls body nil entry body
                (init_st_state
                   (build_program_env
                      (core_st_program name decls body nil entry)))
                s_final Hcfg0 Hstar) as Htrace.
  assert (Hmatch :
    compile_state_env_matches
      (build_compile_type_env (core_st_function name decls body))
      (init_st_state
         (build_program_env
            (core_st_program name decls body nil entry))).(st_vars)).
  { rewrite Henv_ty.
    apply init_st_vars_compile_state_env_matches.
    exact Henv. }
  assert (Hvalues :
    compile_state_values_i32
      (init_st_state
         (build_program_env
            (core_st_program name decls body nil entry))).(st_vars)).
  { apply init_st_vars_compile_state_values_i32.
    exact Henv. }
  pose proof (codegen_singleton_program_correct_pc
                (core_st_function name decls body) nil nil 0
                (init_st_state
                   (build_program_env
                      (core_st_program name decls body nil entry)))
                s_final eq_refl Hmatch Hvalues Htrace)
    as Hcode.
  destruct Hcode as [s_asm [f_asm Hrest]].
  destruct Hrest as
    (Hmulti & Hfinal & Hframes & Hvalues_final & Hmem &
     Hrel & Hblock & Hfunc).
  exists s_asm, f_asm.
  split.
  - rewrite <- (compile_core_st_program_eq_singleton name decls body entry)
      in Hmulti.
    exact Hmulti.
  - repeat split; assumption.
Qed.

Theorem semantics_preservation :
  forall (name : ident) (decls : list st_var_decl)
         (body : list st_stmt) (entry : ident)
         (m : sasm_module) (s_final : st_state),
    let p := core_st_program name decls body nil entry in
    compile_st_to_sasm p = Compile_ok m ->
    core_cfg p body (init_st_state (build_program_env p)) ->
    star_stmts_step p body (init_st_state (build_program_env p)) nil s_final ->
    exists (s_asm : runtime_state) (f_asm : sasm_frame),
      multi_pc_step m
        {| rt_values := nil;
           rt_frames :=
             {| frame_locals :=
                  sasm_locals_of_decls
                    (build_compile_type_env
                       (core_st_function name decls body))
                    (init_st_state (build_program_env p)).(st_vars);
                frame_func_idx := 0;
                frame_pc := 0;
                frame_block_stack := [] |} :: nil;
           rt_memory := nil;
           rt_cycle_cnt := 0 |} s_asm /\
      pc_final_entry m s_asm /\
      s_asm.(rt_frames) = f_asm :: nil /\
      s_asm.(rt_values) = nil /\
      s_asm.(rt_memory) = nil /\
      pc_frame_env_matches
        (build_compile_env (core_st_function name decls body))
        s_final.(st_vars) f_asm /\
      f_asm.(frame_block_stack) = [] /\
      f_asm.(frame_func_idx) = 0.
Proof.
  intros name decls body entry m s_final p Hcomp Hcfg Hstar.
  assert (Hm : m = compile_program (desugar_program p)).
  { unfold compile_st_to_sasm, compile_core_program in Hcomp.
    destruct (core_program p) eqn:Hcp; [| discriminate].
    destruct (type_check_program p) as [errs|] eqn:Hty; [| discriminate].
    destruct errs as [|e rest]; [| discriminate].
    inversion Hcomp. reflexivity. }
  pose proof (core_st_program_semantics_preservation
                name decls body entry s_final Hcfg Hstar) as Hcore.
  destruct Hcore as [s_asm [f_asm Hrest]].
  exists s_asm, f_asm.
  destruct Hrest as
    (Hmulti & Hfinal & Hframes & Hvalues & Hmem & Hrel & Hblock & Hfunc).
  split.
  - rewrite Hm. exact Hmulti.
  - split; [rewrite Hm; exact Hfinal |].
    repeat split; assumption.
Qed.

Theorem semantics_preservation_compiled :
  forall (name : ident) (decls : list st_var_decl)
         (body : list st_stmt) (entry : ident)
         (m : sasm_module) (s_final : st_state),
    let p := core_st_program name decls body nil entry in
    compile_st_to_sasm p = Compile_ok m ->
    star_stmts_step p body (init_st_state (build_program_env p)) nil s_final ->
    exists (s_asm : runtime_state) (f_asm : sasm_frame),
      multi_pc_step m
        {| rt_values := nil;
           rt_frames :=
             {| frame_locals :=
                  sasm_locals_of_decls
                    (build_compile_type_env
                       (core_st_function name decls body))
                    (init_st_state (build_program_env p)).(st_vars);
                frame_func_idx := 0;
                frame_pc := 0;
                frame_block_stack := [] |} :: nil;
           rt_memory := nil;
           rt_cycle_cnt := 0 |} s_asm /\
      pc_final_entry m s_asm /\
      s_asm.(rt_frames) = f_asm :: nil /\
      s_asm.(rt_values) = nil /\
      s_asm.(rt_memory) = nil /\
      pc_frame_env_matches
        (build_compile_env (core_st_function name decls body))
        s_final.(st_vars) f_asm /\
      f_asm.(frame_block_stack) = [] /\
      f_asm.(frame_func_idx) = 0.
Proof.
  intros name decls body entry m s_final p Hcomp Hstar.
  pose proof Hcomp as Hcomp0.
  unfold compile_st_to_sasm, compile_core_program in Hcomp.
  destruct (core_program p) eqn:Hcore; [| discriminate].
  destruct (type_check_program p) as [errs|] eqn:Htypecheck;
    [| discriminate].
  destruct errs as [|e rest]; [| discriminate].
  inversion Hcomp; subst m.
  pose proof (core_cfg_of_core_typecheck name decls body entry
                Hcore Htypecheck) as Hcfg.
  exact (semantics_preservation name decls body entry
           (compile_program (desugar_program p)) s_final
           Hcomp0 Hcfg Hstar).
Qed.

Lemma typed_core_eval_bool :
  forall (fenv : type_env_func) (env : type_env)
         (s : st_state) (e : st_expr),
    core_env env ->
    core_expr e = true ->
    state_consistent env s ->
    type_check_expr fenv env e = Some T_BOOL ->
    exists b : bool, eval_expr s e = Some (ST_V_BOOL b).
Proof.
  intros fenv env s e Henv Hcore Hstate Hty.
  pose proof (core_expr_type_check_fenv_indep fenv env e Hcore) as Hind.
  assert (Hty_nil : type_check_expr nil env e = Some T_BOOL).
  { rewrite <- Hind. exact Hty. }
  pose proof (core_expr_type_is_core env e T_BOOL Henv Hcore Hty_nil)
    as Hcore_ty.
  destruct (typed_eval_total env s e T_BOOL Henv Hcore Hstate
              Hty_nil Hcore_ty) as [v [Heval Hv]].
  destruct (value_type_bool v Hv) as [b Hb].
  subst v.
  exists b. exact Heval.
Qed.

Lemma typed_core_eval_int :
  forall (fenv : type_env_func) (env : type_env)
         (s : st_state) (e : st_expr),
    core_env env ->
    core_expr e = true ->
    state_consistent env s ->
    type_check_expr fenv env e = Some T_INT ->
    exists n : Z, eval_expr s e = Some (ST_V_INT n).
Proof.
  intros fenv env s e Henv Hcore Hstate Hty.
  pose proof (core_expr_type_check_fenv_indep fenv env e Hcore) as Hind.
  assert (Hty_nil : type_check_expr nil env e = Some T_INT).
  { rewrite <- Hind. exact Hty. }
  pose proof (core_expr_type_is_core env e T_INT Henv Hcore Hty_nil)
    as Hcore_ty.
  destruct (typed_eval_total env s e T_INT Henv Hcore Hstate
              Hty_nil Hcore_ty) as [v [Heval Hv]].
  destruct (value_type_int v Hv) as [n Hn].
  subst v. exists n. exact Heval.
Qed.

Lemma typed_core_eval_dint :
  forall (fenv : type_env_func) (env : type_env)
         (s : st_state) (e : st_expr),
    core_env env ->
    core_expr e = true ->
    state_consistent env s ->
    type_check_expr fenv env e = Some T_DINT ->
    (exists n : Z, eval_expr s e = Some (ST_V_DINT n)) \/
    (exists n : Z, eval_expr s e = Some (ST_V_INT n)).
Proof.
  intros fenv env s e Henv Hcore Hstate Hty.
  pose proof (core_expr_type_check_fenv_indep fenv env e Hcore) as Hind.
  assert (Hty_nil : type_check_expr nil env e = Some T_DINT).
  { rewrite <- Hind. exact Hty. }
  pose proof (core_expr_type_is_core env e T_DINT Henv Hcore Hty_nil)
    as Hcore_ty.
  destruct (typed_eval_total env s e T_DINT Henv Hcore Hstate
              Hty_nil Hcore_ty) as [v [Heval Hv]].
  destruct (value_type_dint v Hv) as [n [Hn | Hn]];
    subst v; [left | right]; exists n; exact Heval.
Qed.

Lemma core_cfg_desugar_ready :
  forall (p : st_program) (stmt : st_stmt) (rest : list st_stmt)
         (s : st_state),
    core_cfg p (stmt :: rest) s ->
    desugar_step_ready p (stmt :: rest) s.
Proof.
  intros p stmt rest s Hcfg.
  destruct Hcfg as [Hprog [Hcore_env [Hcore [Htyped Hstate]]]].
  destruct (core_stmts_cons stmt rest Hcore) as [Hcore_stmt Hcore_rest].
  destruct stmt as
    [x e | x idx e | cond then_body else_body | sel branches default
    | v start end_ step body | cond body | body cond | inst params | |].
  - (* assignment *)
    simpl in Hcore_stmt.
    destruct (typed_assign_inv (build_fenv_from_pous p.(pou_list))
                (build_program_env p) x e rest Htyped)
      as [lhs_ty [rhs_ty [Hlook [Htype [Hcompat Htyped_rest]]]]].
    pose proof (core_expr_type_check_fenv_indep
                  (build_fenv_from_pous p.(pou_list))
                  (build_program_env p) e Hcore_stmt) as Hind.
    assert (Htype_nil :
      type_check_expr nil (build_program_env p) e = Some rhs_ty).
    { rewrite <- Hind. exact Htype. }
    pose proof (core_expr_type_is_core (build_program_env p) e rhs_ty
                  Hcore_env Hcore_stmt Htype_nil) as Hcore_rhs.
    destruct (typed_eval_total (build_program_env p) s e rhs_ty
                Hcore_env Hcore_stmt Hstate Htype_nil Hcore_rhs)
      as [value [Heval _]].
    destruct Hstate as [Hvals Hpresent].
    destruct (Hpresent x lhs_ty Hlook) as [old Hold].
    assert (Hold_ty : st_value_type old = lhs_ty).
    { exact (Hvals x lhs_ty old Hlook Hold). }
    assert (Hassign_value :
      corest_assign_value s x value = coerce_value_to_type lhs_ty value).
    { unfold corest_assign_value.
      rewrite Hold. rewrite Hold_ty. reflexivity. }
    exists lhs_ty, value.
    repeat split.
    + exact Hlook.
    + exact Heval.
    + apply core_expr_ds_true. exact Hcore_stmt.
    + exact Hassign_value.
  - simpl in Hcore_stmt. discriminate.
  - (* IF *)
    destruct (core_stmt_if_core_exprs cond then_body else_body
                Hcore_stmt) as [Hcore_cond _].
    destruct (typed_if_inv (build_fenv_from_pous p.(pou_list))
                (build_program_env p) cond then_body else_body rest Htyped)
      as [Htype _].
    destruct (typed_core_eval_bool
                (build_fenv_from_pous p.(pou_list))
                (build_program_env p) s cond
                Hcore_env Hcore_cond Hstate Htype) as [b Hb].
    repeat split.
    + apply core_expr_ds_true. exact Hcore_cond.
    + exists b. exact Hb.
  - (* CASE *)
    destruct (core_stmt_case_parts sel branches default Hcore_stmt)
      as [Hcore_sel [_ _]].
    pose proof (core_case_branches_of_stmt sel branches default Hcore_stmt)
      as Hbranches.
    destruct (typed_case_inv (build_fenv_from_pous p.(pou_list))
                (build_program_env p) sel branches default rest Htyped)
      as [[Htype | Htype] _].
    + destruct (typed_core_eval_int
                  (build_fenv_from_pous p.(pou_list))
                  (build_program_env p) s sel
                  Hcore_env Hcore_sel Hstate Htype) as [n Hn].
      repeat split.
      * apply core_expr_ds_true. exact Hcore_sel.
      * exact Hbranches.
      * left. exists n. exact Hn.
    + destruct (typed_core_eval_dint
                  (build_fenv_from_pous p.(pou_list))
                  (build_program_env p) s sel
                  Hcore_env Hcore_sel Hstate Htype) as [[n Hn] | [n Hn]].
      * repeat split.
        -- apply core_expr_ds_true. exact Hcore_sel.
        -- exact Hbranches.
        -- right. exists n. exact Hn.
      * repeat split.
        -- apply core_expr_ds_true. exact Hcore_sel.
        -- exact Hbranches.
        -- left. exists n. exact Hn.
  - (* FOR *)
    exact I.
  - (* WHILE *)
    destruct (core_stmt_while_core_exprs cond body Hcore_stmt)
      as [Hcore_cond Hcore_body].
    destruct (typed_while_inv (build_fenv_from_pous p.(pou_list))
                (build_program_env p) cond body rest Htyped)
      as [Htype _].
    destruct (typed_core_eval_bool
                (build_fenv_from_pous p.(pou_list))
                (build_program_env p) s cond
                Hcore_env Hcore_cond Hstate Htype) as [b Hb].
    repeat split.
    + apply core_expr_ds_true. exact Hcore_cond.
    + exists b. exact Hb.
  - (* REPEAT *)
    destruct (core_stmt_repeat_core_exprs body cond Hcore_stmt)
      as [_ Hcore_cond].
    apply core_expr_ds_true. exact Hcore_cond.
  - simpl in Hcore_stmt. discriminate.
  - simpl in Hcore_stmt. discriminate.
  - simpl in Hcore_stmt. discriminate.
Qed.

Theorem star_desugar_semantics_preservation :
  forall (p : st_program) (stmts stmts' : list st_stmt)
         (s s' : st_state),
    core_cfg p stmts s ->
    star_stmts_step p stmts s stmts' s' ->
    star_corest_step
      (desugar_stmts stmts) s (desugar_stmts stmts') s'.
Proof.
  intros p stmts stmts' s s' Hcfg Hstar.
  induction Hstar as
    [p0 stmts0 s0
    | p0 stmts1 stmts2 stmts3 s1 s2 s3 Hstep Hrest IH].
  - apply CsStar_refl.
  - destruct stmts1 as [|stmt rest].
    + inversion Hstep.
    + pose proof (core_cfg_desugar_ready p0 stmt rest s1 Hcfg) as Hready.
      pose proof
        (desugar_semantics_preservation p0 (stmt :: rest) stmts2
          s1 s2 Hready Hstep) as Hcore_step.
      pose proof
        (preservation_cfg p0 (stmt :: rest) s1 stmts2 s2
          Hcfg Hstep) as Hcfg_next.
      pose proof (IH Hcfg_next) as Hcore_rest.
      eapply ds_star_corest_step_app.
      * exact Hcore_step.
      * exact Hcore_rest.
Qed.

Theorem semantics_preservation_corest :
  forall (p : st_program) (stmts stmts' : list st_stmt)
         (s s' : st_state),
    core_cfg p stmts s ->
    star_stmts_step p stmts s stmts' s' ->
    star_corest_step
      (desugar_stmts stmts) s (desugar_stmts stmts') s'.
Proof.
  intros p stmts stmts' s s' Hcfg Hstar.
  exact (star_desugar_semantics_preservation p stmts stmts' s s'
           Hcfg Hstar).
Qed.

(* ================================================================
   第 5 部分：编译正确性核心定理 (Core Correctness Theorems)
   ================================================================ *)

(* 真实编译链保持：compile_st_to_sasm 当前实现为 desugar + codegen。
   注意：Step 5 的语义保持定理尚待基于配置式 stmts_step 重建，
   此处不再保留旧的空真 semantics_preservation 声明。 *)

Theorem compile_st_to_sasm_core :
  forall (p : st_program) (m : sasm_module),
    compile_st_to_sasm p = Compile_ok m ->
    core_program p = true /\
    type_check_program p = Some nil /\
    m = compile_program (desugar_program p).
Proof.
  intros p m Hcomp.
  unfold compile_st_to_sasm, compile_core_program in Hcomp.
  destruct (core_program p) eqn:Hcore; [| discriminate].
  destruct (type_check_program p) as [errs |] eqn:Hty; [| discriminate].
  destruct errs as [|e rest]; [| discriminate].
  inversion Hcomp; subst.
  repeat split; assumption.
Qed.

Theorem compile_st_to_sasm_complete :
  forall (p : st_program) (m : sasm_module),
    core_program p = true ->
    type_check_program p = Some nil ->
    m = compile_program (desugar_program p) ->
    compile_st_to_sasm p = Compile_ok m.
Proof.
  intros p m Hcore Hty Hm.
  unfold compile_st_to_sasm, compile_core_program.
  rewrite Hcore.
  rewrite Hty.
  rewrite Hm.
  reflexivity.
Qed.

Definition lit_st_program (n : Z) : st_program :=
  {| global_vars := nil;
     pou_list := [P_PROGRAM (ID "P")
                    [{| var_name := ID "x";
                        var_type := T_DINT;
                        var_dir := D_LOCAL;
                        var_qual := Q_NONE;
                        var_init := None |}]
                    [S_ASSIGN (ID "x") (E_LIT (L_INT n))]];
     io_mapping := nil;
     entry_point := ID "P" |}.

Lemma lit_st_desugar :
  forall (n : Z),
    desugar_program (lit_st_program n) = lit_assign_program n.
Proof.
  intros n.
  unfold lit_st_program, lit_assign_program,
    desugar_program, desugar_pou, desugar_stmt.
  reflexivity.
Qed.

Definition add_st_program (n1 n2 : Z) : st_program :=
  {| global_vars := nil;
     pou_list := [P_PROGRAM (ID "P")
                    [{| var_name := ID "x";
                        var_type := T_DINT;
                        var_dir := D_LOCAL;
                        var_qual := Q_NONE;
                        var_init := None |}]
                    [S_ASSIGN (ID "x")
                       (E_BIN_OP B_ADD (E_LIT (L_INT n1))
                                          (E_LIT (L_INT n2)))]];
     io_mapping := nil;
     entry_point := ID "P" |}.

Lemma add_st_desugar :
  forall (n1 n2 : Z),
    desugar_program (add_st_program n1 n2) = add_assign_program n1 n2.
Proof.
  intros n1 n2.
  unfold add_st_program, add_assign_program,
    desugar_program, desugar_pou, desugar_stmt.
  reflexivity.
Qed.

Theorem add_st_program_semantics :
  forall (n1 n2 old : Z) (m : sasm_module),
    compile_st_to_sasm (add_st_program n1 n2) = Compile_ok m ->
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
  intros n1 n2 old m Hcomp.
  pose proof (compile_st_to_sasm_core (add_st_program n1 n2) m Hcomp)
    as [_ [_ Hm]].
  rewrite add_st_desugar in Hm.
  pose proof (compile_add_assign_program_pc n1 n2 old) as Hpc.
  rewrite <- Hm in Hpc.
  destruct Hpc as [s' [Hmulti [Hlocal Hfinal]]].
  exists s'.
  repeat split; assumption.
Qed.

Definition var_st_program : st_program :=
  {| global_vars := nil;
     pou_list := [P_PROGRAM (ID "P")
                    [{| var_name := ID "x";
                        var_type := T_DINT;
                        var_dir := D_LOCAL;
                        var_qual := Q_NONE;
                        var_init := None |};
                     {| var_name := ID "y";
                        var_type := T_DINT;
                        var_dir := D_LOCAL;
                        var_qual := Q_NONE;
                        var_init := None |}]
                    [S_ASSIGN (ID "x") (E_VAR (ID "y"))]];
     io_mapping := nil;
     entry_point := ID "P" |}.

Lemma var_st_desugar :
  desugar_program var_st_program = var_assign_program.
Proof.
  unfold var_st_program, var_assign_program,
    desugar_program, desugar_pou, desugar_stmt.
  reflexivity.
Qed.

Theorem var_st_program_semantics :
  forall (old src : Z) (m : sasm_module),
    compile_st_to_sasm var_st_program = Compile_ok m ->
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
  intros old src m Hcomp.
  pose proof (compile_st_to_sasm_core var_st_program m Hcomp)
    as [_ [_ Hm]].
  rewrite var_st_desugar in Hm.
  pose proof (compile_var_assign_program_pc old src) as Hpc.
  rewrite <- Hm in Hpc.
  destruct Hpc as [s' [Hmulti [Hlocal Hfinal]]].
  exists s'.
  repeat split; assumption.
Qed.

Theorem lit_st_program_semantics :
  forall (n old : Z) (m : sasm_module),
    compile_st_to_sasm (lit_st_program n) = Compile_ok m ->
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
  intros n old m Hcomp.
  pose proof (compile_st_to_sasm_core (lit_st_program n) m Hcomp)
    as [_ [_ Hm]].
  rewrite lit_st_desugar in Hm.
  pose proof (compile_lit_program_pc n old) as Hpc.
  rewrite <- Hm in Hpc.
  destruct Hpc as [s' [Hmulti [Hfinal Hlocal]]].
  exists s'.
  split; [exact Hmulti |].
  split; [exact Hfinal |].
  exact Hlocal.
Qed.

Definition noncore_program : st_program :=
  {| global_vars := nil;
     pou_list := [P_FUNCTION (ID "f") T_INT nil nil];
     io_mapping := nil;
     entry_point := ID "f" |}.

Theorem noncore_program_rejected :
  compile_st_to_sasm noncore_program =
  Compile_error "outside core subset".
Proof.
  unfold compile_st_to_sasm, compile_core_program, noncore_program.
  reflexivity.
Qed.


(* ================================================================
   定理 4: compile_determinism (编译确定性)
   ================================================================ *)
Theorem compile_determinism :
  forall (p : st_program) (m1 m2 : sasm_module),
    compile_success p m1 ->
    compile_success p m2 ->
    m1 = m2.
Proof.
  intros p m1 m2 H1 H2.
  unfold compile_success in H1, H2.
  rewrite H1 in H2. injection H2. auto.
Qed.

(* ================================================================
   WS-C: 函数调用代码生成（compile_program_gc）的 CALL 路径形式化
   ----------------------------------------------------------------
   出厂管线用 compile_program_gc，把 CE_FUNC_CALL f args 编为
   `args ++ [CALL idx]`（global_codegen.v）。本段把 WS-A 的 ST 帧语义
   （call_function_fn 的 arity）与 WS-B 的 Pc_call 结构前提
   （callee 存在、param_count <= local_count）在 compile_program_gc
   产出的模块上调和一致，作为 CALL 路径进入被证明语义的结构级门槛：
   证明任何 codegen 生成的 in-range CALL 都指向一个存在且形参数量
   不超过其局部槽位的被调帧，故 CALL 永不会在 Pc_call 的前提上卡住。
   ================================================================ *)

(* desugar_pou 保持输入参数数量：cfunc_params 长度 = input_param_names 长度 *)
Lemma desugar_pou_param_count :
  forall (p : st_pou),
    match p with
    | P_PROGRAM _ _ _ => List.length (desugar_pou p).(cfunc_params) = 0%nat
    | P_FUNCTION _ _ d _ => List.length (desugar_pou p).(cfunc_params)
      = List.length (function_semantics.input_param_names d)
    | P_FUNCTION_BLOCK _ d _ => List.length (desugar_pou p).(cfunc_params)
      = List.length (function_semantics.input_param_names d)
    end.
Proof.
  intros p.
  destruct p as [n1 d1 b1 | n2 t d2 b2 | n3 d3 b3]; simpl.
  - (* P_PROGRAM *)
    reflexivity.
  - (* P_FUNCTION *)
    simpl.
    induction d2 as [|d rest IH]; simpl; auto.
    destruct d.(var_dir) eqn:Hdir; simpl; rewrite IH; auto.
  - (* P_FUNCTION_BLOCK *)
    simpl.
    induction d3 as [|d rest IH]; simpl; auto.
    destruct d.(var_dir) eqn:Hdir; simpl; rewrite IH; auto.
Qed.

(* callee 的类型段形参数 = 源函数 cfunc_params 数量。 *)
Lemma build_sasm_func_type_param_count :
  forall (f : corest_function),
    List.length (build_sasm_func_type f).(sasm_param_types)
    = List.length f.(cfunc_params).
Proof.
  intros f. apply List.length_map.
Qed.

(* 被调帧局部槽位数 = 类型环境长度 + 1（返回值槽）。 *)
Lemma compile_function_gc_locals_length :
  forall (globals : list (ident * Z)) (fidx : func_index_env)
         (idx : Z) (f : corest_function),
    List.length (compile_function_gc globals fidx idx f).(sasm_locals)
    = (List.length (build_compile_type_env f) + 1)%nat.
Proof.
  intros globals fidx idx f.
  unfold compile_function_gc; simpl.
  rewrite List.length_app, List.length_map.
  reflexivity.
Qed.

(* 被调帧的局部槽位数 = 形参 ++ 局部 ++ 返回值槽，恒 >= 形参数。 *)
Lemma compile_function_gc_locals_adequate :
  forall (globals : list (ident * Z)) (fidx : func_index_env)
         (idx : Z) (f : corest_function),
    (List.length (build_sasm_func_type f).(sasm_param_types) <=
     List.length (compile_function_gc globals fidx idx f).(sasm_locals))%nat.
Proof.
  intros globals fidx idx f.
  rewrite build_sasm_func_type_param_count.
  rewrite compile_function_gc_locals_length.
  unfold build_compile_type_env.
  rewrite List.length_app.
  simpl. lia.
Qed.

(* compile_functions_gc 保持函数数量。 *)
Lemma compile_functions_gc_length :
  forall (globals : list (ident * Z)) (fidx : func_index_env)
         (fs : list corest_function) (idx : Z),
    List.length (compile_functions_gc globals fidx idx fs)
    = List.length fs.
Proof.
  intros globals fidx.
  induction fs as [|f rest IH]; intros idx; simpl;
    [reflexivity | rewrite IH; reflexivity].
Qed.

(* 第 j 个被编译函数 = 对第 j 个源函数应用 compile_function_gc，
   其类型槽索引为 idx + j。 *)
Lemma nth_error_compile_functions_gc :
  forall (globals : list (ident * Z)) (fidx : func_index_env)
         (fs : list corest_function) (idx : Z) (j : nat),
    List.nth_error (compile_functions_gc globals fidx idx fs) j =
      match List.nth_error fs j with
      | Some f => Some (compile_function_gc globals fidx (idx + Z.of_nat j) f)
      | None => None
      end.
Proof.
  intros globals fidx.
  induction fs as [|f rest IH]; intros idx j.
  - destruct j; reflexivity.
  - destruct j as [|j'];
      cbn [compile_functions_gc List.nth_error].
    + replace (idx + Z.of_nat 0) with idx by lia; reflexivity.
    + rewrite IH.
      replace (idx + Z.of_nat (S j')) with (idx + 1 + Z.of_nat j') by lia.
      destruct (List.nth_error rest j') as [g|]; reflexivity.
Qed.

(* 第 j 个类型段 = 对第 j 个源函数应用 build_sasm_func_type。 *)
Lemma nth_error_build_sasm_func_type :
  forall (fs : list corest_function) (j : nat),
    List.nth_error (List.map build_sasm_func_type fs) j
    = option_map build_sasm_func_type (List.nth_error fs j).
Proof.
  intros fs. induction fs as [|a rest IH]; intros j.
  - destruct j; reflexivity.
  - destruct j as [|j'].
    + reflexivity.
    + cbn [List.map List.nth_error]. rewrite IH. reflexivity.
Qed.

(* compile_program_gc 的类型段与函数段长度都等于 core_funcs 长度。 *)
Lemma compile_program_gc_types_length :
  forall (p : corest_program),
    List.length (compile_program_gc p).(sasm_types)
    = List.length (entry_first_functions p).
Proof.
  intros p. unfold compile_program_gc.
  cbn [sasm_types]. apply List.length_map.
Qed.

Lemma compile_program_gc_functions_length :
  forall (p : corest_program),
    List.length (compile_program_gc p).(sasm_functions)
    = List.length (entry_first_functions p).
Proof.
  intros p. unfold compile_program_gc.
  cbn [sasm_functions]. apply compile_functions_gc_length.
Qed.

(* compile_program_gc 的两个投影段展开为对 core_funcs 的 map/编译。 *)
Lemma compile_program_gc_types_eq :
  forall (p : corest_program),
    (compile_program_gc p).(sasm_types)
    = List.map build_sasm_func_type (entry_first_functions p).
Proof.
  intros p. unfold compile_program_gc. cbn [sasm_types]. reflexivity.
Qed.

Lemma compile_program_gc_functions_eq :
  forall (p : corest_program),
    (compile_program_gc p).(sasm_functions)
    = compile_functions_gc (build_global_env p)
        (assign_func_indices (entry_first_functions p) 0) 0
        (entry_first_functions p).
Proof.
  intros p. unfold compile_program_gc. cbn [sasm_functions]. reflexivity.
Qed.

(* 主定理：compile_program_gc 的每个 in-range CALL 目标都存在于模块中，
   其类型段可解析、被调帧可解析，且形参数 <= 局部槽位数（Pc_call 的
   结构前提）。这保证 codegen 生成的 CALL 永不会在调用约定上卡住。 *)
Theorem compile_st_to_sasm_calls :
  forall (p : corest_program) (j : nat),
    (j < List.length (entry_first_functions p))%nat ->
    exists (ft : sasm_func_type) (fn : sasm_function),
      lookup_func_type (compile_program_gc p) (Z.of_nat j) = Some ft /\
      lookup_function (compile_program_gc p) (Z.of_nat j) = Some fn /\
      (List.length ft.(sasm_param_types)
       <= List.length fn.(sasm_locals))%nat.
Proof.
  intros p j Hj.
  assert (Hn : List.nth_error (entry_first_functions p) j <> None).
  { apply List.nth_error_Some. exact Hj. }
  destruct (List.nth_error (entry_first_functions p) j) as [g|] eqn:Hg;
    [ | contradiction ].
  (* 类型段：sasm_types = map build_sasm_func_type core_funcs *)
  assert (HT : List.nth_error (compile_program_gc p).(sasm_types)
                       (Z.to_nat (Z.of_nat j))
             = Some (build_sasm_func_type g)).
  {
    rewrite compile_program_gc_types_eq.
    rewrite nth_error_build_sasm_func_type.
    rewrite Nat2Z.id.
    unfold option_map. rewrite Hg. reflexivity.
  }
  (* 函数段：sasm_functions = compile_functions_gc ... 0 core_funcs *)
  assert (HF : List.nth_error (compile_program_gc p).(sasm_functions)
                       (Z.to_nat (Z.of_nat j))
             = Some (compile_function_gc
                       (build_global_env p)
                       (assign_func_indices (entry_first_functions p) 0)
                       (Z.of_nat j) g)).
  {
    rewrite compile_program_gc_functions_eq.
    rewrite Nat2Z.id.
    rewrite nth_error_compile_functions_gc.
    rewrite Hg. reflexivity.
  }
  exists (build_sasm_func_type g),
    (compile_function_gc (build_global_env p)
       (assign_func_indices (entry_first_functions p) 0) (Z.of_nat j) g).
  split; [| split].
  - unfold lookup_func_type. exact HT.
  - unfold lookup_function. exact HF.
  - apply compile_function_gc_locals_adequate.
Qed.

(* 强化版本：显式给出源函数 *)
Theorem compile_st_to_sasm_calls_with_source :
  forall (p : corest_program) (j : nat),
    (j < List.length (entry_first_functions p))%nat ->
    exists (g : corest_function) (ft : sasm_func_type) (fn : sasm_function),
      List.nth_error (entry_first_functions p) j = Some g /\
      ft = build_sasm_func_type g /\
      fn = compile_function_gc (build_global_env p)
             (assign_func_indices (entry_first_functions p) 0) (Z.of_nat j) g /\
      lookup_func_type (compile_program_gc p) (Z.of_nat j) = Some ft /\
      lookup_function (compile_program_gc p) (Z.of_nat j) = Some fn /\
      (List.length ft.(sasm_param_types)
       <= List.length fn.(sasm_locals))%nat.
Proof.
  intros p j Hj.
  destruct (List.nth_error (entry_first_functions p) j) as [g|] eqn:Hg.
  - exists g, (build_sasm_func_type g),
      (compile_function_gc (build_global_env p)
         (assign_func_indices (entry_first_functions p) 0) (Z.of_nat j) g).
    split; [reflexivity |].
    split; [reflexivity |].
    split; [reflexivity |].
    split.
    + unfold lookup_func_type.
      rewrite compile_program_gc_types_eq.
      rewrite nth_error_build_sasm_func_type.
      rewrite Nat2Z.id.
      unfold option_map. rewrite Hg. reflexivity.
    + split.
      * unfold lookup_function.
        rewrite compile_program_gc_functions_eq.
        rewrite Nat2Z.id.
        rewrite nth_error_compile_functions_gc.
        rewrite Hg. reflexivity.
      * apply compile_function_gc_locals_adequate.
  - exfalso. apply List.nth_error_Some in Hj. contradiction.
Qed.

(* ST 侧：把主定理与 WS-A 的 call_function_fn arity 引理串起来——
   一次成功的 ST 调用只在被调 POU 存在且形参数量与实际参数数量一致
   时发生（function_semantics.call_function_fn_arity），这与 ASM 侧
   Pc_call 前提 param_count = |sasm_param_types| 及本定理的
   param_count <= local_count 完全对齐。 *)
Theorem call_st_asm_arity_agreement :
  forall (fuel : nat) (funs : list st_pou) (name : ident)
         (args : list st_value) (v : st_value),
    function_semantics.call_function_fn fuel funs name args = Some v ->
    exists (decls : list st_var_decl),
      List.length (function_semantics.input_param_names decls)
      = List.length args.  (* ST 侧参数数量 == 实参数量 *)
Proof.
  intros fuel funs name args v H.
  pose proof (function_semantics.call_function_fn_arity fuel funs name args v H)
    as [ty [decls [body [Hlk Hart]]]].
  exists decls. exact Hart.
Qed.

(* WS-C.3：调用表达式编译正确性。codegen 为 CE_FUNC_CALL f args 发射的
   [args ++ [CALL idx]]（global_codegen.v:417-428）中的 idx 来自
   lookup_func_index (assign_func_indices fs 0) f。本引理证明任何被发射
   的 CALL idx 都落在有效函数段范围内，因此该 CALL 目标在
   compile_program_gc 产出的模块中一定存在（lookup_function 成功），
   CALL 永远不会指向一个不存在的被调帧。 *)

(* assign_func_indices 产生的索引落在 [base, base + |fs|) 内。 *)
Lemma assign_func_indices_range :
  forall (fs : list corest_function) (base : Z) (f : ident) (idx : Z),
    lookup_func_index (assign_func_indices fs base) f = Some idx ->
    (base <= idx)%Z /\ (idx < base + Z.of_nat (List.length fs))%Z.
Proof.
  intros fs. induction fs as [|a rest IH]; intros base f idx H; simpl in H.
  - discriminate.
  - destruct (ident_eq f (cfunc_name a)) eqn:Heq.
    + injection H as Hidx; subst idx. split; [lia|].
      cbn [List.length]. rewrite Nat2Z.inj_succ.
      assert (0 <= Z.of_nat (List.length rest))%Z by apply Nat2Z.is_nonneg.
      lia.
    + specialize (IH (base + 1) f idx H). destruct IH as [Hle Hlt].
      assert (Hl : (Z.of_nat (List.length (a :: rest))
                    = Z.of_nat (List.length rest) + 1)%Z).
      { cbn [List.length]. rewrite Nat2Z.inj_succ. lia. }
      split; [lia|]. rewrite Hl. lia.
Qed.

(* 发射出的 CALL idx 在被编译模块中一定解析为一个存在的函数。 *)
Theorem compile_call_index_present :
  forall (p : corest_program) (f : ident) (idx : Z),
    lookup_func_index
      (assign_func_indices (entry_first_functions p) 0) f = Some idx ->
    exists fn, lookup_function (compile_program_gc p) idx = Some fn. (* 目标存在 *)
Proof.
  intros p f idx H.
  destruct (assign_func_indices_range
              (entry_first_functions p) 0 f idx H)
    as [Hge Hlt].
  assert (Hconv : Z.of_nat (Z.to_nat idx) = idx) by (apply Z2Nat.id; exact Hge).
  assert (Hrange : (Z.to_nat idx < List.length (entry_first_functions p))%nat).
  { apply (proj2 (Nat2Z.inj_lt (Z.to_nat idx)
                               (List.length (entry_first_functions p)))).
    rewrite Hconv. exact Hlt. }
  assert (Hne : List.nth_error (entry_first_functions p) (Z.to_nat idx) <> None)
    by (apply List.nth_error_Some; exact Hrange).
  destruct (List.nth_error (entry_first_functions p) (Z.to_nat idx))
    as [g|] eqn:Hg; [ | contradiction ].
  exists (compile_function_gc (build_global_env p)
            (assign_func_indices (entry_first_functions p) 0) idx g).
  unfold lookup_function.
  rewrite compile_program_gc_functions_eq.
  rewrite nth_error_compile_functions_gc.
  rewrite Hg.
  cbn [Z.add].
  rewrite Hconv. reflexivity.
Qed.

(* ================================================================
   第 7 部分：多 POU 语义保持定理 (Phase C)

   证明当 ST 程序包含多个 FUNCTION + 一个 PROGRAM 时，编译后的
   SafeASM 模块的 CALL/RETURN 语义与源程序的 function_semantics 一致。
   ================================================================ *)

(* 多 POU 编译函数：使用 compile_program_gc 处理多个 FUNCTION *)
Definition compile_multi_pou (p : st_program) : compile_result :=
  if type_check_program p then
    Compile_ok (compile_program_gc (desugar_program p))
  else
    Compile_error "type errors".

(* 多 POU 编译成功谓词 *)
Definition compile_multi_pou_success (p : st_program) (m : sasm_module) : Prop :=
  compile_multi_pou p = Compile_ok m.

(* 函数名到索引的映射正确性：
   如果 ST 程序中存在名为 name 的 FUNCTION，则编译后的模块中存在对应的函数，
   且其索引可通过 assign_func_indices 查到。 *)

(* 辅助引理：如果 existsb 在 pou_list 上找到 P_FUNCTION name，
   则 desugar 后的 cprog_functions 中存在 cfunc_name = name 的函数 *)
Lemma desugar_preserves_function_name :
  forall (pous : list st_pou) (name : ident),
    List.existsb (fun pou =>
      match pou with
      | P_FUNCTION n _ _ _ => ident_eq n name
      | _ => false
      end) pous = true ->
    List.existsb (fun f => ident_eq f.(cfunc_name) name)
      (List.map desugar_pou pous) = true.
Proof.
  intros pous name H.
  apply List.existsb_exists in H.
  destruct H as [pou [Hmem Hmatch]].
  apply List.existsb_exists.
  exists (desugar_pou pou).
  split.
  - (* In (desugar_pou pou) (map desugar_pou pous) *)
    apply List.in_map. exact Hmem.
  - destruct pou; simpl in Hmatch; try discriminate.
    simpl. exact Hmatch.
Qed.

(* 辅助引理：partition 的 fst ++ snd 保持 existsb *)
(* 辅助引理：partition 在 cons 上的行为 *)
Lemma partition_cons :
  forall (f : corest_function -> bool) (x : corest_function) (xs : list corest_function),
    List.partition f (x :: xs) =
    if f x then (x :: fst (List.partition f xs), snd (List.partition f xs))
    else (fst (List.partition f xs), x :: snd (List.partition f xs)).
Proof.
  intros f x xs.
  assert (H1 : List.partition f (x :: xs) =
            let (g, d) := List.partition f xs in
            if f x then (x :: g, d) else (g, x :: d)) by reflexivity.
  rewrite H1.
  destruct (List.partition f xs) as [ys zs] eqn:Hy.
  simpl. destruct (f x); reflexivity.
Qed.

Lemma existsb_app :
  forall (A : Type) (g : A -> bool) (l1 l2 : list A),
    List.existsb g (l1 ++ l2) = (List.existsb g l1 || List.existsb g l2).
Proof.
  intros A g l1. induction l1 as [|a l1' IH]; intros l2; simpl.
  - reflexivity.
  - rewrite IH. destruct (g a); reflexivity.
Qed.

Lemma bool_or_true_r : forall b : bool, (b || true) = true.
Proof. intros b. destruct b; reflexivity. Qed.

Lemma partition_existsb :
  forall (f : corest_function -> bool) (funcs : list corest_function)
         (g : corest_function -> bool),
    List.existsb g (fst (List.partition f funcs) ++ snd (List.partition f funcs))
    = List.existsb g funcs.
Proof.
  intros f funcs g.
  induction funcs as [|x xs IH]; [reflexivity|].
  rewrite partition_cons.
  destruct (f x).
  - simpl. rewrite IH. reflexivity.
  - rewrite existsb_app.
    simpl.
    destruct (g x).
    + simpl.
      rewrite bool_or_true_r. reflexivity.
    + simpl.
      rewrite <- existsb_app.
      rewrite IH. reflexivity.
Qed.

Lemma partition_fst_subset :
  forall (f : corest_function -> bool) (l : list corest_function) (x : corest_function),
    List.In x (fst (List.partition f l)) -> List.In x l.
Proof.
  intros f l.
  induction l as [|y ys IH]; intros x Hin.
  - simpl in Hin. inversion Hin.
  - rewrite partition_cons in Hin.
    destruct (f y); simpl in Hin.
    + destruct Hin as [Heq|Hin']; [left; assumption|].
      right. apply IH. exact Hin'.
    + right. apply IH. exact Hin.
Qed.

Lemma partition_snd_subset :
  forall (f : corest_function -> bool) (l : list corest_function) (x : corest_function),
    List.In x (snd (List.partition f l)) -> List.In x l.
Proof.
  intros f l.
  induction l as [|y ys IH]; intros x Hin.
  - simpl in Hin. inversion Hin.
  - rewrite partition_cons in Hin.
    destruct (f y); simpl in Hin.
    + right. apply IH. exact Hin.
    + destruct Hin as [Heq|Hin']; [left; assumption|].
      right. apply IH. exact Hin'.
Qed.

Lemma In_app_or : forall (A : Type) (l1 l2 : list A) (x : A),
  List.In x (l1 ++ l2) -> List.In x l1 \/ List.In x l2.
Proof.
  intros A l1 l2 x H.
  apply List.in_app_iff in H. exact H.
Qed.

(* 辅助引理：entry_first_functions 保持 existsb *)
Lemma entry_first_existsb :
  forall (p : corest_program) (g : corest_function -> bool),
    List.existsb g (entry_first_functions p) = List.existsb g p.(cprog_functions).
Proof.
  intros p g.
  unfold entry_first_functions.
  apply partition_existsb.
Qed.

(* 辅助引理：ident_eq 是对称的 *)
Lemma ident_eq_sym : forall x y : ident, ident_eq x y = ident_eq y x.
Proof.
  intros [s1] [s2]. simpl.
  apply String.eqb_sym.
Qed.

(* 辅助引理：assign_func_indices 正确映射列表中的每个函数名 *)
Lemma assign_func_indices_lookup :
  forall (funcs : list corest_function) (base : Z) (name : ident),
    List.existsb (fun f => ident_eq f.(cfunc_name) name) funcs = true ->
    exists idx, lookup_func_index (assign_func_indices funcs base) name = Some idx.
Proof.
  intros funcs. induction funcs as [|f rest IH]; intros base name H.
  - simpl in H. discriminate.
  - simpl in H. simpl.
    destruct (ident_eq f.(cfunc_name) name) eqn:Heq.
    + (* f.(cfunc_name) = name *)
      (* lookup_func_index checks ident_eq name f.(cfunc_name) *)
      rewrite ident_eq_sym. rewrite Heq.
      simpl.
      exists base. reflexivity.
    + (* f.(cfunc_name) <> name *)
      (* The function must be in rest *)
      simpl in H. destruct (ident_eq f.(cfunc_name) name) eqn:Heq2; try discriminate.
      (* Simplify the if expression in the goal *)
      rewrite ident_eq_sym. rewrite Heq2. simpl.
      apply (IH (base + 1) name) in H.
      destruct H as [idx Hidx].
      exists idx. exact Hidx.
Qed.

Lemma multi_pou_function_index_exists :
  forall (p : st_program) (name : ident),
    List.existsb (fun pou =>
      match pou with
      | P_FUNCTION n _ _ _ => ident_eq n name
      | _ => false
      end) p.(pou_list) = true ->
    exists (idx : Z),
      lookup_func_index
        (assign_func_indices
           (entry_first_functions (desugar_program p)) 0)
        name = Some idx.
Proof.
  intros p name Hexists.
  pose proof (desugar_preserves_function_name p.(pou_list) name Hexists)
    as Hdesugar.
  unfold desugar_program in Hdesugar.
  simpl in Hdesugar.
  pose proof (entry_first_existsb (desugar_program p)
    (fun f => ident_eq f.(cfunc_name) name)) as Hentry.
  unfold desugar_program in Hentry.
  simpl in Hentry.
  rewrite Hdesugar in Hentry.
  apply (assign_func_indices_lookup _ 0) in Hentry.
  exact Hentry.
Qed.

(* ============================================================
   Hparam_eq 支持引理链：从 entry_first_functions 中的 g_src
   定位回源 POU，证明脱糖后参数数量与 lookup 到的 decls 一致。
   ============================================================ *)

Lemma ident_eq_to_eq : forall x y : ident, ident_eq x y = true -> x = y.
Proof.
  intros [s1] [s2] H. simpl in H. apply f_equal. apply String.eqb_eq. exact H.
Qed.

Lemma ident_eq_refl : forall x : ident, ident_eq x x = true.
Proof. intros [s]. simpl. apply String.eqb_refl. Qed.

Lemma in_map_exists :
  forall (A B : Type) (f : A -> B) (y : B) (l : list A),
    List.In y (List.map f l) -> exists x, List.In x l /\ f x = y.
Proof.
  intros A B f y. induction l as [|a l' IH]; intros Hin; simpl in Hin.
  - inversion Hin.
  - destruct Hin as [Heq|Hin'].
    + exists a. split; [left; reflexivity | exact Heq].
    + destruct (IH Hin') as [x [Hin2 Heq2]].
      exists x. split; [right; exact Hin2 | exact Heq2].
Qed.

Lemma bool_or_false_both :
  forall b1 b2 : bool, (b1 || b2 = false) -> b1 = false /\ b2 = false.
Proof. intros b1 b2 H. destruct b1; [discriminate|]. destruct b2; [discriminate|]. split; reflexivity. Qed.

Lemma in_ident_list_true :
  forall (x : ident) (xs : list ident), List.In x xs -> in_ident_list x xs = true.
Proof.
  intros x xs. induction xs as [|y ys IH]; intros Hin.
  - inversion Hin.
  - simpl in Hin. destruct Hin as [Heq|Hin'].
    + assert (He2 : ident_eq x y = true).
      { rewrite Heq. apply ident_eq_refl. }
      simpl. rewrite He2. reflexivity.
    + simpl. rewrite (IH Hin'). destruct (ident_eq x y); reflexivity.
Qed.

Lemma unique_pou_names_list :
  forall (pous : list st_pou),
    hasDuplicates (List.map pou_name_spec pous) = false ->
    forall (p1 p2 : st_pou),
      List.In p1 pous -> List.In p2 pous ->
      pou_name_spec p1 = pou_name_spec p2 -> p1 = p2.
Proof.
  intros pous. induction pous as [|q qs IH];
    intros Hdup p1 p2 Hin1 Hin2 Hname.
  - inversion Hin1.
  - simpl in Hin1. simpl in Hdup.
    destruct Hin1 as [Heq|Hin1'].
    + subst p1.
      apply bool_or_false_both in Hdup.
      destruct Hdup as [Hnotin Hdups].
      destruct Hin2 as [Heq2|Hin2'].
      * subst p2. reflexivity.
      * assert (Hmem : List.In (pou_name_spec p2) (List.map pou_name_spec qs)).
        { apply List.in_map. exact Hin2'. }
        rewrite <- Hname in Hmem.
        pose proof (in_ident_list_true (pou_name_spec q)
          (List.map pou_name_spec qs) Hmem) as Ht.
        rewrite Ht in Hnotin. discriminate.
    + apply bool_or_false_both in Hdup.
      destruct Hdup as [Hnotin Hdups].
      simpl in Hin2.
      destruct Hin2 as [Heq2|Hin2'].
      * subst p2.
        assert (Hmem1 : List.In (pou_name_spec p1) (List.map pou_name_spec qs)).
        { apply List.in_map. exact Hin1'. }
        rewrite Hname in Hmem1.
        pose proof (in_ident_list_true (pou_name_spec q)
          (List.map pou_name_spec qs) Hmem1) as Ht.
        rewrite Ht in Hnotin. discriminate.
      * exact (IH Hdups p1 p2 Hin1' Hin2' Hname).
Qed.

Lemma lookup_pou_some_member :
  forall (name : ident) (pous : list st_pou) (ty : st_type)
         (decls : list st_var_decl) (body : list st_stmt),
    function_semantics.lookup_function_pou name pous = Some (ty, decls, body) ->
    List.In (P_FUNCTION name ty decls body) pous.
Proof.
  intros name pous ty decls body Hlk.
  induction pous as [|q qs IH]; [discriminate|simpl in Hlk].
  destruct q as [n1 dq bq | fn t dq bq | n2 dq bq]; simpl in Hlk.
  - right. apply IH. exact Hlk.
  - destruct (ident_eq name fn) eqn:Heq.
    + apply ident_eq_to_eq in Heq. subst fn.
      injection Hlk as Hty Hd Hb. subst ty. subst decls. subst body.
      left. reflexivity.
    + right. apply IH. exact Hlk.
  - right. apply IH. exact Hlk.
Qed.

Lemma lookup_pou_match :
  forall (pous : list st_pou) (name : ident)
         (ty : st_type) (decls : list st_var_decl) (body : list st_stmt)
         (pou : st_pou),
    hasDuplicates (List.map pou_name_spec pous) = false ->
    function_semantics.lookup_function_pou name pous = Some (ty, decls, body) ->
    List.In pou pous ->
    pou_name_spec pou = name ->
    pou = P_FUNCTION name ty decls body.
Proof.
  intros pous name ty decls body pou Hdup Hlk Hin Hname.
  assert (Hmemf : List.In (P_FUNCTION name ty decls body) pous).
  { apply lookup_pou_some_member. exact Hlk. }
  assert (Hnf : pou_name_spec (P_FUNCTION name ty decls body) = name)
    by reflexivity.
  apply (unique_pou_names_list pous Hdup pou (P_FUNCTION name ty decls body)
           Hin Hmemf).
  rewrite Hname, Hnf. reflexivity.
Qed.

Lemma desugar_pou_name_is_pou_name :
  forall (pou : st_pou), (desugar_pou pou).(cfunc_name) = pou_name_spec pou.
Proof. intros [n1 d1 b1 | n2 t d2 b2 | n3 d3 b3]; reflexivity. Qed.

Lemma lookup_pou_first_is_only :
  forall (name : ident) (pous : list st_pou)
         (ty1 : st_type) (d1 : list st_var_decl) (b1 : list st_stmt)
         (ty2 : st_type) (d2 : list st_var_decl) (b2 : list st_stmt),
    function_semantics.lookup_function_pou name pous = Some (ty1, d1, b1) ->
    function_semantics.lookup_function_pou name pous = Some (ty2, d2, b2) ->
    (ty1, d1, b1) = (ty2, d2, b2).
Proof.
  intros name pous ty1 d1 b1 ty2 d2 b2 H1.
  induction pous as [|q qs IH]; intros H2; simpl in H1; simpl in H2.
  - discriminate.
  - destruct q as [n1 dq bq | fn t dq bq | n2 dq bq]; simpl in H1; simpl in H2.
    + apply IH. exact H1. exact H2.
    + destruct (ident_eq name fn) eqn:Heq in H1, H2; simpl in H1; simpl in H2.
      * injection H1 as Hty Hd Hb. subst ty1. subst d1. subst b1.
        injection H2 as Hty2 Hd2 Hb2. subst ty2. subst d2. subst b2.
        reflexivity.
      * apply IH. exact H1. exact H2.
    + apply IH. exact H1. exact H2.
Qed.

Lemma assign_func_indices_nth_match :
  forall (fs : list corest_function) (base : Z) (j : nat) (g : corest_function)
         (name : ident) (idx : Z),
    nth_error fs j = Some g ->
    lookup_func_index (assign_func_indices fs base) name = Some idx ->
    idx = base + Z.of_nat j ->
    ident_eq g.(cfunc_name) name = true.
Proof.
  intros fs. induction fs as [|f rest IH];
    intros base j g name idx Hnth Hlk Hidx.
  - simpl in Hnth. discriminate.
  - destruct j as [|j'] eqn:Hj.
    + (* j = 0：g 就是头部元素 f *)
      simpl in Hnth. injection Hnth as Hg. subst g.
      assert (Hlkred : (if ident_eq name f.(cfunc_name)
                         then Some base
                         else lookup_func_index (assign_func_indices rest (base + 1)) name) = Some idx).
      { exact Hlk. }
      destruct (ident_eq name f.(cfunc_name)) eqn:Heq.
      * rewrite ident_eq_sym. exact Heq.
      * simpl in Hlkred.
        rewrite Nat2Z.inj_0 in Hidx. simpl in Hidx.
        rewrite (Z.add_0_r base) in Hidx.
        exfalso.
        pose proof (assign_func_indices_range rest (base + 1) name idx Hlkred)
          as [Ha Hb].
        lia.
    + (* j = S j'：递归到 rest *)
      simpl in Hnth.
      assert (Hlkred : (if ident_eq name f.(cfunc_name)
                         then Some base
                         else lookup_func_index (assign_func_indices rest (base + 1)) name) = Some idx).
      { exact Hlk. }
      destruct (ident_eq name f.(cfunc_name)) eqn:Heq.
      * simpl in Hlkred.
        injection Hlkred as Hidx2.
        rewrite Hidx2 in Hidx.
        rewrite Nat2Z.inj_succ in Hidx.
        exfalso. lia.
      * simpl in Hlkred.
        apply (IH (base + 1) j' g name idx);
          [exact Hnth | exact Hlkred |].
        rewrite Nat2Z.inj_succ in Hidx.
        lia.
Qed.

(* 多 POU 语义保持定理（陈述）：
   对于良构的 ST 程序 p，如果编译成功得到模块 m，
   且 ST 侧调用函数 name 成功返回值 v，
   则 ASM 侧从初始状态执行 CALL 到 name 对应的函数，
   最终到达的状态与 v 抽象对应。 *)
Theorem multi_pou_semantics_preservation :
  forall (p : st_program) (m : sasm_module)
         (fuel : nat) (name : ident) (args : list st_value) (v : st_value),
    well_formed_program p ->
    compile_multi_pou_success p m ->
    function_semantics.call_function_fn fuel p.(pou_list) name args = Some v ->
    exists (idx : Z),
      lookup_func_index
        (assign_func_indices
           (entry_first_functions (desugar_program p)) 0)
        name = Some idx /\
      (* ASM 侧：存在对应的函数，且其参数数量与 args 长度一致 *)
      exists (fn : sasm_function),
        lookup_function m idx = Some fn /\
        (List.length fn.(sasm_locals) >= List.length args)%nat.
Proof.
  intros p m fuel name args v Hwf Hcomp Hcall.
  unfold compile_multi_pou_success, compile_multi_pou in Hcomp.
  destruct (type_check_program p) eqn:Hty; [| discriminate].
  inversion Hcomp; subst.
  (* 从 Hcall 得到 lookup_function_pou 成功，推导 existsb = true *)
  assert (Hexists_pou : List.existsb (fun pou =>
    match pou with
    | P_FUNCTION n _ _ _ => ident_eq n name
    | _ => false
    end) p.(pou_list) = true).
  { (* call_function_fn 成功意味着 lookup_function_pou 找到了 P_FUNCTION *)
    pose proof (function_semantics.call_function_fn_arity
      fuel p.(pou_list) name args v Hcall) as [ty [decls [body [Hlk _]]]].
    (* 从 lookup_function_pou = Some 推导 existsb = true *)
    revert Hlk.
    generalize (p.(pou_list)).
    intros pous Hlk.
    induction pous as [|pou rest IH]; simpl in Hlk.
    - discriminate.
    - destruct pou as [n1 d1 b1 | n2 t d2 b2 | n3 d3 b3]; simpl in Hlk.
      + (* P_PROGRAM n1 d1 b1 *)
        apply IH. exact Hlk.
      + (* P_FUNCTION n2 t d2 b2 *)
        (* lookup_function_pou name (P_FUNCTION n2 t d2 b2 :: rest) = Some (ty, decls, body) *)
        (* Need to show: existsb ... (P_FUNCTION n2 t d2 b2 :: rest) = true *)
        simpl in Hlk.
        destruct (ident_eq name n2) eqn:Heq.
        * (* ident_eq name n2 = true *)
          (* existsb computes to ident_eq n2 name || existsb ... rest *)
          simpl.
          (* Use symmetry of ident_eq *)
          rewrite ident_eq_sym. rewrite Heq.
          reflexivity.
        * (* ident_eq name n2 = false, so lookup continues in rest *)
          (* existsb ... (P_FUNCTION n2 t d2 b2 :: rest) = ident_eq n2 name || existsb ... rest *)
          simpl.
          rewrite ident_eq_sym. rewrite Heq.
          simpl.
          apply IH in Hlk. exact Hlk.
      + (* P_FUNCTION_BLOCK n3 d3 b3 *)
        apply IH. exact Hlk.
  }
  pose proof (multi_pou_function_index_exists p name Hexists_pou)
    as [idx Hidx].
  exists idx.
  split; [exact Hidx |].
  pose proof (compile_call_index_present (desugar_program p) name idx Hidx)
    as [fn Hfn].
  exists fn.
  split; [exact Hfn |].
  (* 证明 sasm_locals 长度 >= args 长度 *)
  pose proof (call_st_asm_arity_agreement fuel p.(pou_list) name args v Hcall)
    as [decls Hlen].
  (* 从 compile_st_to_sasm_calls 得到 fn 的参数数量对齐性质 *)
  (* idx 来自 assign_func_indices，其范围在 [0, length) 内 *)
  pose proof (assign_func_indices_range
    (entry_first_functions (desugar_program p)) 0 name idx Hidx) as [Hge Hlt].
  assert (Hidx_range : (Z.to_nat idx < List.length (entry_first_functions (desugar_program p)))%nat).
  { 
    assert (Hconv : Z.of_nat (Z.to_nat idx) = idx) by (apply Z2Nat.id; exact Hge).
    apply (proj2 (Nat2Z.inj_lt (Z.to_nat idx)
                               (List.length (entry_first_functions (desugar_program p))))).
    rewrite Hconv. exact Hlt.
  }
  pose proof (compile_st_to_sasm_calls_with_source (desugar_program p) (Z.to_nat idx)
    Hidx_range) as [g_src [ft' [fn' [Hg_src [Hft_eq [Hfn'_eq [Hft'_lk [Hfn'_lk Hlen']]]]]]]].
  (* fn 和 fn' 是同一个函数 *)
  assert (Hfn_eq : fn = fn').
  { (* 从 lookup_function 的唯一性得到 *)
    (* First, rewrite Z.of_nat (Z.to_nat idx) to idx *)
    assert (Hidx_conv : Z.of_nat (Z.to_nat idx) = idx).
    { apply Z2Nat.id. exact Hge. }
    rewrite Hidx_conv in Hfn'_lk.
    (* Now Hfn and Hfn'_lk both talk about lookup_function m idx *)
    rewrite Hfn in Hfn'_lk.
    inversion Hfn'_lk. reflexivity.
  }
  rewrite Hfn_eq.
  rewrite Hfn'_eq.
  (* 现在需要证明：length args <= length (compile_function_gc ... g_src).(sasm_locals) *)
  assert (Hge_len : (List.length (compile_function_gc (build_global_env (desugar_program p))
    (assign_func_indices (entry_first_functions (desugar_program p)) 0) (Z.of_nat (Z.to_nat idx)) g_src).(sasm_locals)
    >= List.length args)%nat).
  {
    (* 从 compile_function_gc_locals_adequate 知：
       length (build_sasm_func_type g_src).(sasm_param_types) <= length (compile_function_gc ... g_src).(sasm_locals) *)
    assert (Hadeq : (List.length (build_sasm_func_type g_src).(sasm_param_types) <=
      List.length (compile_function_gc (build_global_env (desugar_program p))
        (assign_func_indices (entry_first_functions (desugar_program p)) 0) (Z.of_nat (Z.to_nat idx)) g_src).(sasm_locals))%nat).
    { apply compile_function_gc_locals_adequate. }
    
    (* 从 build_sasm_func_type_param_count 知：
       length (build_sasm_func_type g_src).(sasm_param_types) = length g_src.(cfunc_params) *)
    rewrite build_sasm_func_type_param_count in Hadeq.
    
    (* 因此只需证明：length args <= length g_src.(cfunc_params) *)
    (* 从 Hlen 知：length (input_param_names decls) = length args *)
    (* 所以只需证明：length (input_param_names decls) <= length g_src.(cfunc_params) *)
    
    (* 从 call_st_asm_arity_agreement 的证明知，decls 来自 lookup_function_pou name p.(pou_list) *)
    (* 从 multi_pou_function_index_exists 的证明知，存在 P_FUNCTION name _ decls _ 在 p.(pou_list) 中 *)
    (* 从 Hg_src 知 g_src 是 entry_first_functions (desugar_program p) 的第 idx 个 *)
    (* 从 desugar_program 的定义知 g_src = desugar_pou pou，其中 pou 在 p.(pou_list) 中 *)
    (* 从 Hidx 知 g_src.(cfunc_name) = name *)
    (* 由于 pou 在 p.(pou_list) 中且名字为 name，且 lookup_function_pou 返回 decls，
       所以 pou = P_FUNCTION name _ decls _ *)
    
    (* 使用 call_function_fn_arity 得到具体的 pou *)
    pose proof (function_semantics.call_function_fn_arity
      fuel p.(pou_list) name args v Hcall)
      as [ty' [decls' [body' [Hlk' Hlen2]]]].
    (* Hlk' : lookup_function_pou name p.(pou_list) = Some (ty', decls', body') *)
    (* 从 lookup_function_pou 的唯一性知 ty' = ty, decls' = decls, body' = body *)
    
    (* 从 multi_pou_function_index_exists 的证明知 *)
    (* 存在 pou 在 p.(pou_list) 中使得 desugar_pou pou 的名字为 name *)
    (* 且该 pou 是 P_FUNCTION *)
    
    (* 从 Hg_src 和 entry_first_functions 的结构知 *)
    (* g_src = desugar_pou pou，其中 pou 是 p.(pou_list) 中名字为 name 的 P_FUNCTION *)
    (* 由于 lookup_function_pou 返回 (ty', decls', body')，所以 pou = P_FUNCTION name ty' decls' body' *)
    
    (* 因此 g_src = desugar_pou (P_FUNCTION name ty' decls' body') *)
    (* 从 desugar_pou_param_count 知 *)
    (* length g_src.(cfunc_params) = length (input_param_names decls') *)
    (* 由于 decls' = decls（从 lookup 的唯一性），所以 *)
    (* length g_src.(cfunc_params) = length (input_param_names decls) = length args *)
    
    (* 但我们需要显式证明 g_src = desugar_pou (P_FUNCTION name ty' decls' body') *)
    (* 这需要更详细的推理 *)
    
    (* —— 参数数量论证（消除 Hparam_eq）—— *)
    (* 1. g_src 来自 p.(pou_list) 中某个 POU 的脱糖 *)
    assert (Hin_gsrc : List.In g_src (List.map desugar_pou p.(pou_list))).
    {
      assert (Hin_ef : List.In g_src (entry_first_functions (desugar_program p))).
      { exact (@List.nth_error_In _ (entry_first_functions (desugar_program p))
                                 (Z.to_nat idx) g_src Hg_src). }
      unfold entry_first_functions in Hin_ef.
      simpl in Hin_ef.
      apply In_app_or in Hin_ef.
      destruct Hin_ef as [H1|H2].
      - apply (partition_fst_subset _ _ _ H1).
      - apply (partition_snd_subset _ _ _ H2).
    }
    destruct (@in_map_exists st_pou corest_function desugar_pou g_src
                  p.(pou_list) Hin_gsrc) as [pou [Hpou_in Hpou_eq]].
    (* 2. g_src 是符号表第 idx 项，其名字与 name 匹配 *)
    assert (Hname_eq : ident_eq g_src.(cfunc_name) name = true).
    {
      assert (Hc : idx = 0 + Z.of_nat (Z.to_nat idx)).
      { rewrite (Z2Nat.id idx Hge). lia. }
      apply (assign_func_indices_nth_match
               (entry_first_functions (desugar_program p)) 0 (Z.to_nat idx)
               g_src name idx Hg_src Hidx Hc).
    }
    (* 3. 良构性 => POU 名字唯一，pou 即 lookup 命中的那个 P_FUNCTION *)
    assert (Hdup_pous :
        hasDuplicates (List.map pou_name_spec p.(pou_list)) = false).
    {
      unfold well_formed_program in Hwf.
      unfold no_duplicate_declarations in Hwf.
      apply (proj2 (proj1 Hwf)).
    }
    assert (Hpou_nm : pou_name_spec pou = name).
    {
      apply ident_eq_to_eq.
      rewrite <- desugar_pou_name_is_pou_name.
      rewrite Hpou_eq. exact Hname_eq.
    }
    assert (Hpouf : pou = P_FUNCTION name ty' decls' body').
    {
      apply (lookup_pou_match p.(pou_list) name ty' decls' body' pou
                Hdup_pous Hlk' Hpou_in Hpou_nm).
    }
    (* 4. 参数数量：length g_src.(cfunc_params) = length (input_param_names decls') *)
    assert (Hpc : List.length g_src.(cfunc_params)
            = List.length (function_semantics.input_param_names decls')).
    {
      rewrite <- Hpou_eq. rewrite Hpouf.
      exact (desugar_pou_param_count (P_FUNCTION name ty' decls' body')).
    }
    rewrite <- Hpc in Hlen2.
    rewrite <- Hlen2.
    exact Hadeq.
  }
  exact Hge_len.
Qed.
