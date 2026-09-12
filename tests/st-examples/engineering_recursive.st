PROGRAM P
VAR
    x : DINT;
END_VAR
x := RecursiveStage(1);
END_PROGRAM

FUNCTION RecursiveStage : DINT
VAR_INPUT
    value : DINT;
END_VAR
RecursiveStage := RecursiveStage(value);
END_FUNCTION
