(* Positive test: FUNCTION local initializers are lowered to entry assignments.
   Each call re-initializes r before executing the body. *)

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
