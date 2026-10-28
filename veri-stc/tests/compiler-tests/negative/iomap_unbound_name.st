(* ================================================================
   negative/iomap_unbound_name.st -- IOMAP must bind a declared global

   An IOMAP entry names a global variable and gives it a physical channel.
   The compiler resolves that name to the variable's real global slot
   (build_global_env); a name that is not a declared global has no slot, so
   the entry could never be filled by the runtime. Accepting it would
   silently produce a program whose I/O quietly goes nowhere.

   Rejection: KIND=declaration, VAR=<the bad name>. Only the unbound entry
   is reported -- the well-formed one passes untouched.
   ================================================================ *)

VAR_GLOBAL
  ao0 : DINT;
END_VAR
IOMAP
  ao0, 1, OUTPUT, DINT;
  ghost, 2, INPUT, DINT;
END_IOMAP
PROGRAM P
  ao0 := 5;
END_PROGRAM
