(* Negative test: FUNCTION modifies VAR_INPUT (purity violation).
   A FUNCTION must not assign to its input parameters. *)

FUNCTION Bad : DINT
VAR_INPUT
  x : DINT;
END_VAR
  x := 1;
  Bad := x;
END_FUNCTION

PROGRAM dup_main
VAR
  y : DINT;
END_VAR
  y := Bad(0);
END_PROGRAM
