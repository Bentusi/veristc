(* Negative test: a REAL literal with more significant digits than the
   decimal-to-binary64 fast path can produce exactly.

   lexer.v builds a real literal as mant / 10^k with both terms exactly
   representable, which needs at most 15 significant digits. A longer literal
   would need a second rounding step, so it is refused as a lexical failure
   (exit 21) instead of being silently double-rounded. *)

PROGRAM real_literal_precision
VAR
  x : REAL;
END_VAR
  x := 0.1234567890123456;
END_PROGRAM
