(* IOMAP smoke: two mapped channels, one input and one output.
   The IOMAP block is the only place a channel number and direction are
   declared; scale/bias are emitted by the compiler as identity (1.0 / 0.0)
   and the loader must read them from the file instead of hardcoding them. *)
VAR_GLOBAL
    ai0 : DINT;
    ao0 : DINT;
END_VAR
IOMAP
    ai0, 0, INPUT, DINT;
    ao0, 1, OUTPUT, DINT;
END_IOMAP
PROGRAM P
    ao0 := ai0 + 1;
END_PROGRAM
