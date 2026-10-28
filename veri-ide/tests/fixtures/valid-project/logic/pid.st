FUNCTION_BLOCK pid
VAR_INPUT
    setpoint : DINT;
    process_value : DINT;
END_VAR

VAR_OUTPUT
    control_output : DINT;
END_VAR

VAR
    error : DINT;
    kp : DINT := 10;
END_VAR

error := setpoint - process_value;
control_output := error * kp;

END_FUNCTION_BLOCK
