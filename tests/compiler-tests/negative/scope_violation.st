(* Negative test: undeclared variable.
   Variable 'y' is never declared, so this must be rejected. *)

PROGRAM scope_violation
VAR
  x : DINT;
END_VAR
  x := y;
END_PROGRAM
