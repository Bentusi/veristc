(* Negative test: a REAL literal whose exponent leaves the exactness premises
   of the decimal-to-binary64 fast path.

   lexer.v scales a literal by a single power of ten that must itself be exactly
   representable: `E+n` needs significant digits + n <= 15, `E-n` needs fraction
   digits + n <= 22. 1.0e30 would require 10^30 (> 2^53), so it is refused
   (exit 21) rather than rounded twice. *)

PROGRAM real_literal_exponent
VAR
  x : REAL;
END_VAR
  x := 1.0e30;
END_PROGRAM
