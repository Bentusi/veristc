(* ================================================================
   veristc/spec/asm_semantics.v
   SafeASM 运行时语义 — 多步执行与终态

   依赖: safeasm.v
   ================================================================ *)

From Stdlib Require Import List.
Require Import veristc_spec.safeasm.
Import ListNotations.

(* ================================================================
   第 2 部分：SafeASM 的操作语义（从 safeasm.v 导入 step）
   ================================================================ *)

(* SafeASM 多步执行 *)
Inductive multi_step_sasm : sasm_module -> runtime_state -> runtime_state -> Prop :=
  | Multi_sasm_refl : forall m s, multi_step_sasm m s s
  | Multi_sasm_step : forall m s1 s2 s3,
      step m s1 s2 ->
      multi_step_sasm m s2 s3 ->
      multi_step_sasm m s1 s3
.

Lemma multi_step_sasm_trans : forall m s1 s2 s3,
    multi_step_sasm m s1 s2 ->
    multi_step_sasm m s2 s3 ->
    multi_step_sasm m s1 s3.
Proof.
  intros m s1 s2 s3 H12. revert s3.
  induction H12 as [| ? ? mid ? Hstep Hrest IH]; intros s_fin H23.
  - exact H23.
  - eapply Multi_sasm_step; [exact Hstep | exact (IH s_fin H23)].
Qed.

(* SafeASM 的最终状态（当前为占位，Phase 1 中将定义为 rt_frames = nil） *)
Definition is_final_sasm (s : runtime_state) : Prop :=
  s.(rt_frames) = nil.
