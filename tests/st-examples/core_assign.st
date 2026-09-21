PROGRAM P
VAR
    x : DINT;
    counter : DINT;
END_VAR
counter := CycleCounter();
x := 42 + 0;
PRINT('counter=', counter, ' x=', x, '\n');
END_PROGRAM
