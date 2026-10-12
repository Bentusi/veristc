(* Positive test: constant-bound FOR is allowed inside a stateless FUNCTION.
   WHILE/REPEAT remain rejected until loop-variant analysis is complete. *)

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
