(* Positive test: valid FUNCTION with local variable and IF control flow. *)

FUNCTION AddOne : DINT
VAR_INPUT
  val : DINT;
END_VAR
VAR
  r : DINT;
END_VAR
  IF val > 0 THEN
    r := val + 1;
  ELSE
    r := 0;
  END_IF;
  AddOne := r;
END_FUNCTION

PROGRAM function_basic
VAR
  result : DINT;
END_VAR
  result := AddOne(41);
  PRINT('result=', result, '\n');
END_PROGRAM
