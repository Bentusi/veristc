PROGRAM main
VAR
    counter : DINT;
    status : DINT;
END_VAR

counter := counter + 1;
IF counter > 100 THEN
    counter := 0;
    status := 1;
END_IF;

END_PROGRAM
