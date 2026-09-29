(* Full stateless FUNCTION support:
   - local variables
   - IF/ELSIF/ELSE control flow
   - nested FUNCTION calls
   - real CALL/RETURN code generation *)

FUNCTION AddOne : DINT
VAR_INPUT
  x : DINT;
END_VAR
  AddOne := x + 1;
END_FUNCTION

FUNCTION Clamp : DINT
VAR_INPUT
  x  : DINT;
  lo : DINT;
  hi : DINT;
END_VAR
VAR
  r : DINT;
END_VAR
  IF x < lo THEN
    r := lo;
  ELSIF x > hi THEN
    r := hi;
  ELSE
    r := x;
  END_IF;
  Clamp := r;
END_FUNCTION

PROGRAM MAIN
VAR
  tick : DINT;
  y    : DINT;
END_VAR
  tick := CycleCounter();
  y := Clamp(AddOne(tick), 2, 5);
  PRINT('tick=', tick, ' y=', y, '\n');
END_PROGRAM
