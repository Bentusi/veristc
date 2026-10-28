(* Negative test: syntax error.
   Missing END_VAR causes a parse failure. *)

PROGRAM syntax_error
VAR
  x : DINT;
  x := 1;
END_PROGRAM
