(* Negative test: type mismatch.
   Assigning a BOOL value to a DINT variable is not allowed. *)

PROGRAM type_mismatch
VAR
  x : DINT;
  b : BOOL;
END_VAR
  b := TRUE;
  x := b;
END_PROGRAM
