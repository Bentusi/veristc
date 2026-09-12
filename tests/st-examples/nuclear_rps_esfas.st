PROGRAM NuclearRpsEsfas
VAR_INPUT
    reactor_mode : DINT;
    reactor_power_pct : DINT;
    pzr_pressure : DINT;
    pzr_level : DINT;
    pzr_press_a : DINT;
    pzr_press_b : DINT;
    pzr_press_c : DINT;
    sg_a_level : DINT;
    sg_b_level : DINT;
    containment_pressure : DINT;
    containment_radiation : DINT;
    manual_trip : BOOL;
    trip_breaker_closed : BOOL;
    rod_drive_available : BOOL;
END_VAR
VAR_OUTPUT
    reactor_trip : BOOL;
    rod_scram : BOOL;
    turbine_trip : BOOL;
    trip_breaker_energized : BOOL;
    safety_injection : BOOL;
    containment_isolation : BOOL;
    main_feedwater_isolation : BOOL;
    auxiliary_feedwater : BOOL;
    protection_alarm : BOOL;
END_VAR
VAR
    trip_votes : DINT;
    trip_request : BOOL;
    high_containment : BOOL;
    low_sg_level : BOOL;
END_VAR

reactor_trip := 0 > 1;
rod_scram := 0 > 1;
turbine_trip := 0 > 1;
trip_breaker_energized := 0 > 1;
safety_injection := 0 > 1;
containment_isolation := 0 > 1;
main_feedwater_isolation := 0 > 1;
auxiliary_feedwater := 0 > 1;
protection_alarm := 0 > 1;
high_containment := 0 > 1;
low_sg_level := 0 > 1;
trip_votes := 0 + 0;

IF pzr_press_a < 13000 THEN
    trip_votes := trip_votes + 1;
END_IF;
IF pzr_press_b < 13000 THEN
    trip_votes := trip_votes + 1;
END_IF;
IF pzr_press_c < 13000 THEN
    trip_votes := trip_votes + 1;
END_IF;

trip_request := manual_trip OR
    ((reactor_mode >= 2) AND
     ((reactor_power_pct > 109) OR
      (pzr_level > 92) OR
      (trip_votes >= 2)));

reactor_trip := trip_request;
rod_scram := reactor_trip AND trip_breaker_closed AND rod_drive_available;
turbine_trip := reactor_trip OR (reactor_power_pct > 105);
trip_breaker_energized := trip_breaker_closed AND (NOT reactor_trip);

high_containment := (containment_pressure > 150) OR
                    (containment_radiation > 10000);
safety_injection := (trip_votes >= 2) OR
                    (trip_request AND (pzr_pressure < 13000));
containment_isolation := high_containment OR safety_injection;

low_sg_level := (sg_a_level < 25) OR (sg_b_level < 25);
main_feedwater_isolation := safety_injection OR low_sg_level;
auxiliary_feedwater := reactor_trip AND low_sg_level;
protection_alarm := reactor_trip OR safety_injection OR high_containment;

END_PROGRAM
