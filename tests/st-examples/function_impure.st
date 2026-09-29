(* Negative test: FUNCTION must remain stateless.
   It may not assign to VAR_INPUT or VAR_GLOBAL. *)

VAR_GLOBAL
  g : DINT;
END_VAR

FUNCTION Bad : DINT
VAR_INPUT
  x : DINT;
END_VAR
  x := 1;
  g := 2;
  Bad := x;
END_FUNCTION

PROGRAM MAIN
VAR
  y : DINT;
END_VAR
  y := Bad(0);
  PRINT('y=', y, '\n');
END_PROGRAM
