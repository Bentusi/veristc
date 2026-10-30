(* Positive test: REAL decimal literals.

   Each literal is stored straight into its own REAL local, so the code
   section holds one F32_CONST + LOCAL_SET pair per row and nothing else.
   The expected single-precision bit patterns are checked byte by byte by
   step 3 of run_compiler_tests.sh (f32 immediates on the wire). *)

PROGRAM real_literals
VAR
  v00 : REAL;
  v01 : REAL;
  v02 : REAL;
  v03 : REAL;
  v04 : REAL;
  v05 : REAL;
  v06 : REAL;
  v07 : REAL;
  v08 : REAL;
  v09 : REAL;
  v10 : REAL;
  v11 : REAL;
  v12 : REAL;
  v13 : REAL;
END_VAR
  v00 := 1.5;
  v01 := 0.1;
  v02 := -0.1;
  v03 := 3.14159265;
  v04 := 16777217.0;
  v05 := 0.33333333333333;
  v06 := 1.0e6;
  v07 := 2.5e-1;
  v08 := -1.5;
  v09 := 0.0000001;
  v10 := 1.0e-9;
  v11 := 100.0;
  v12 := 0.0;
  v13 := -273.15;
END_PROGRAM
