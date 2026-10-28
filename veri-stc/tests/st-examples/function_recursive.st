(* Negative test: direct recursion is rejected before code generation. *)

FUNCTION Fact : DINT
VAR_INPUT
  n : DINT;
END_VAR
  Fact := n * Fact(n - 1);
END_FUNCTION

PROGRAM MAIN
VAR
  y : DINT;
END_VAR
  y := Fact(3);
  PRINT('y=', y, '\n');
END_PROGRAM
