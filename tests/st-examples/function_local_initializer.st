(* Negative test: FUNCTION local initializers are not yet implemented.
   The compiler rejects them instead of silently zero-initializing. *)

FUNCTION Next : DINT
VAR_INPUT
  x : DINT;
END_VAR
VAR
  r : DINT := 10;
END_VAR
  r := r + x;
  Next := r;
END_FUNCTION

PROGRAM MAIN
VAR
  y : DINT;
END_VAR
  y := Next(1);
  PRINT('y=', y, '\n');
END_PROGRAM
