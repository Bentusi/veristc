(* ================================================================
   rs_multi_entity.st
   Multi-entity pattern: ONE function entity (RS bistable) called
   multiple times, each call passing the caller's own variables
   plus its previous state; the single return value is the new
   state, written back by the caller.

     q1 := RS(q1, s1, r1);   (* entity 1: own vars + own state *)
     q2 := RS(q2, s2, r2);   (* entity 2: same code, other vars *)

   Key rules under current VeriSTC/VM semantics:
   1. FUNCTION bodies must be a single expression; the compiler
      inlines them at each call site (inline.v). Multi-statement
      bodies must be expanded by the upstream preprocessor.
   2. State variables (q1, q2) MUST be VAR_GLOBAL: the VM
      re-initializes PROGRAM frame locals to 0 every scan cycle,
      so locals cannot carry state across cycles. Globals live in
      the persistent MEM section.
   3. VAR_GLOBAL blocks must appear before the POU list.
   4. Multiple outputs: one return value per call. A second
      output is either derived at the call site (Q1 := NOT q) or
      provided by a sibling function sharing the same inputs.
   ================================================================ *)

VAR_GLOBAL
  q1 : BOOL;   (* RS entity 1 state/output *)
  q2 : BOOL;   (* RS entity 2 state/output *)
END_VAR

(* RS bistable: Q := S OR (Q_old AND NOT R); R has priority *)
FUNCTION RS : BOOL
VAR_INPUT
  Q_old : BOOL;
  S : BOOL;
  R : BOOL;
END_VAR
  RS := S OR (Q_old AND NOT R); 
END_FUNCTION

PROGRAM MAIN
VAR
  s1 : BOOL;
  r1 : BOOL;
  s2 : BOOL;
  r2 : BOOL;
  tick : DINT;
END_VAR
  tick := CycleCounter();

  (* stimuli: entity 1 set@2 reset@6, entity 2 set@4 reset@8 *)
  s1 := tick = 2;
  r1 := tick = 6;
  s2 := tick = 4;
  r2 := tick = 8;

  (* multi-entity calls: original vars + previous state in,
     new state out via the single return value *)
  q1 := RS(q1, s1, r1);
  q2 := RS(q2, s2, r2);

  PRINT(tick, q1, q2);
END_PROGRAM
