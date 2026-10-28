(* ================================================================
   sim_closed_loop.st -- closed-loop demo for the simulation backend

   An integral controller against a first-order-lag plant. Three signals
   cross the I/O boundary:

     pv : AI ch0 -- the controlled quantity, produced by the plant
     mv : AO ch1 -- the manipulated value, written by the controller
     sp : AI ch2 -- the setpoint, a constant source in the plant

   The controller is deliberately written with DINT only (decision D1: the
   REAL chain is not usable yet), so units are integer counts over 0..1000
   and the loop is closed by the simulator, not by ST.

   Anti-windup: the accumulator integrates only while inside its bounds and
   is clamped afterwards, since integrator + saturated actuator otherwise
   winds up and the loop never recovers.

   Golden timeline (12 cycles, period 100 ms, plant gain 1/8), recorded from
   build/bin/sim and diffed by integration/run_sim_e2e.sh. The values shown
   are the ones the channel carried at the start of that cycle:
     cycle  sp   pv   mv
         1 500    0  500
         2 500   62  938
         3 500  171 1000
         4 500  274 1000
         5 500  364 1000
         6 500  443 1000
         7 500  512  988
         8 500  571  917
         9 500  614  803
        10 500  637  666
        11 500  640  526
        12 500  625  401
   The actuator saturates for four cycles, the accumulator stops winding up
   there, and the controlled quantity turns back toward the setpoint on its
   own: a closed loop with no operator and no wall clock.

   `cnt` exists for the watch layer only (G0 deliverable 4): a FUNCTION_BLOCK
   instance whose fields land in the symbol table as derived names
   `cnt#N` / `cnt#ACC`, so integration/run_sim_e2e.sh can prove that watching
   an instance field resolves through section 7 to a live slot. It is called
   once per cycle with STEP := 1 and touches none of the loop signals, which
   is why the timeline above is unchanged by adding it.
   ================================================================ *)

VAR_GLOBAL
  sp    : DINT;
  pv    : DINT;
  mv    : DINT;
  err   : DINT;
  integ : DINT;
  cnt   : COUNTER_FB;
END_VAR
IOMAP
  pv, 0, INPUT, DINT;
  mv, 1, OUTPUT, DINT;
  sp, 2, INPUT, DINT;
END_IOMAP
(* 每周期 +STEP，N 是对外可见的累计值，ACC 是实例内部状态 *)
FUNCTION_BLOCK COUNTER_FB
VAR_INPUT
  STEP : DINT;
END_VAR
VAR_OUTPUT
  N : DINT;
END_VAR
VAR
  ACC : DINT;
END_VAR
  ACC := ACC + STEP;
  N := ACC;
END_FUNCTION_BLOCK
PROGRAM MAIN
  err := sp - pv;
  cnt(STEP := 1);

  IF (err > 0) AND (integ < 1000) THEN
    integ := integ + err;
  END_IF;

  IF (err < 0) AND (integ > 0) THEN
    integ := integ + err;
  END_IF;

  IF integ > 1000 THEN
    integ := 1000;
  END_IF;

  IF integ < 0 THEN
    integ := 0;
  END_IF;

  mv := integ;
END_PROGRAM
