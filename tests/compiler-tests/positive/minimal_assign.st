(* Positive test: minimal valid program. *)

PROGRAM minimal_assign
VAR
  x : DINT;
END_VAR
  x := 42;
  PRINT('x=', x, '\n');
END_PROGRAM
