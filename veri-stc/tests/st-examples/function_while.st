(* Negative test: WHILE is not yet allowed inside FUNCTION bodies.
   It requires loop-variant analysis in a call frame and additional proofs. *)

FUNCTION WaitPositive : DINT
VAR_INPUT
  n : DINT;
END_VAR
VAR
  y : DINT;
END_VAR
  WHILE y < n DO
    y := y + 1;
  END_WHILE;
  WaitPositive := y;
END_FUNCTION

PROGRAM MAIN
VAR
  y : DINT;
END_VAR
  y := WaitPositive(3);
  PRINT('y=', y, '\n');
END_PROGRAM
