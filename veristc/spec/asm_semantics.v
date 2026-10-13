(* ================================================================
   veristc/spec/asm_semantics.v
   SafeASM 运行时语义 — 多步执行与终态

   依赖: safeasm.v

   说明（WS-B.2 收拢）：
   语义保持定理实际使用基于 frame_pc 的 pc_step / multi_pc_step
   （见 safeasm.v），它们是唯一理解 CALL/RETURN 的执行关系。
   早期基于平面 `step`（无调用规则）的 multi_step_sasm 已废弃，
   本文件把"规范执行语义"直接指向 multi_pc_step。
   ================================================================ *)

From Stdlib Require Import List.
Require Import veristc_spec.safeasm.
Import ListNotations.

(* ================================================================
   规范多步执行语义：以 multi_pc_step 为唯一执行关系
   ================================================================ *)

(* 历史名 multi_step_sasm 现在是 multi_pc_step 的别名，确保全项目只有
   一套执行语义（含 CALL/RETURN），不再依赖平面 step。 *)
Definition multi_step_sasm :
    sasm_module -> runtime_state -> runtime_state -> Prop :=
  multi_pc_step.

(* 反射与单步作为便捷构造子重新暴露。 *)
Definition Multi_sasm_refl :
    forall (m : sasm_module) (s : runtime_state), multi_step_sasm m s s :=
  Multi_pc_refl.

Definition Multi_sasm_step :
    forall (m : sasm_module) (s1 s2 s3 : runtime_state),
      pc_step m s1 s2 ->
      multi_step_sasm m s2 s3 ->
      multi_step_sasm m s1 s3 :=
  Multi_pc_step.

Lemma multi_step_sasm_trans : forall m s1 s2 s3,
    multi_step_sasm m s1 s2 ->
    multi_step_sasm m s2 s3 ->
    multi_step_sasm m s1 s3.
Proof.
  exact multi_pc_step_trans.
Qed.

(* ================================================================
   终态定义（WS-B.2 推广）

   早期把"终态"定义为单帧且 rt_frames = nil，只适用于无调用的平面
   程序。 含函数调用的模块在运行期会有多帧进出，终态应是"入口帧的
   pc 走到函数体末尾且块栈清空"。 复用 safeasm.v 的 pc_final_entry。
   ================================================================ *)

Definition is_final_sasm (m : sasm_module) (s : runtime_state) : Prop :=
  pc_final_entry m s.

(* 兼容旧写法：仅关心"帧栈收缩到入口单帧"这一结构特征。 *)
Definition is_final_frames_sasm (s : runtime_state) : Prop :=
  match s.(rt_frames) with
  | _ :: nil => True
  | _ => False
  end.
