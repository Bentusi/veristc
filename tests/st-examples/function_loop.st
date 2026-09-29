(* Negative test: loops are not yet allowed inside FUNCTION bodies.
   They require bounded-loop analysis in a call frame and additional proofs. *)

FUNCTION SumTo : DINT
VAR_INPUT
  n : DINT;
END_VAR
VAR
  i : INT;
  s : DINT;
END_VAR
  FOR i := 0 TO 10 DO
    s := s + 1;
  END_FOR;
  SumTo := s;
END_FUNCTION

PROGRAM MAIN
VAR
  y : DINT;
END_VAR
  y := SumTo(3);
  PRINT('y=', y, '\n');
END_PROGRAM
