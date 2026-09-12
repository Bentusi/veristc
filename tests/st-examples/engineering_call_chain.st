PROGRAM P
VAR
    x : DINT;
END_VAR
x := Stage1(1);
END_PROGRAM

FUNCTION Stage1 : DINT
VAR_INPUT
    value : DINT;
END_VAR
Stage1 := Stage2(value);
END_FUNCTION

FUNCTION Stage2 : DINT
VAR_INPUT
    value : DINT;
END_VAR
Stage2 := Stage3(value);
END_FUNCTION

FUNCTION Stage3 : DINT
VAR_INPUT
    value : DINT;
END_VAR
Stage3 := Stage4(value);
END_FUNCTION

FUNCTION Stage4 : DINT
VAR_INPUT
    value : DINT;
END_VAR
Stage4 := Stage5(value);
END_FUNCTION

FUNCTION Stage5 : DINT
VAR_INPUT
    value : DINT;
END_VAR
Stage5 := value;
END_FUNCTION
