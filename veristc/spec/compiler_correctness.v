(* ================================================================
   veristc/spec/compiler_correctness.v
   顶层语义模块 — 从 st_semantics 导入并导出

   本文件保留项目顶层文件名与文档引用兼容性。
   源语言语义和正确性定义统一由 st_semantics.v 提供。
   ================================================================ *)

From Stdlib Require Import List.
Require Import veristc_spec.safest.
Require Import veristc_spec.safeasm.
Require Import veristc_spec.st_semantics.
Export veristc_spec.st_semantics.
