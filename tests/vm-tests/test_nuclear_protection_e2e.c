/*
 * End-to-end test for the ST nuclear protection and ESFAS program.
 *
 * The .sasm input must be produced by:
 *   veristc compile tests/st-examples/nuclear_rps_esfas.st
 *
 * This test injects plant conditions into the entry frame, executes the
 * compiled bytecode on the real C VM, and checks every protection output.
 */

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>

#include "../../vm/vm.h"
#include "../../rtos/abstract.h"

VM_Interface g_vm_interface = { 0 };

#include "../../vm/loader.c"
#include "../../vm/safeasm_interp.c"

enum {
    IN_REACTOR_MODE = 0,
    IN_REACTOR_POWER_PCT,
    IN_PZR_PRESSURE,
    IN_PZR_LEVEL,
    IN_PZR_PRESS_A,
    IN_PZR_PRESS_B,
    IN_PZR_PRESS_C,
    IN_SG_A_LEVEL,
    IN_SG_B_LEVEL,
    IN_CONTAINMENT_PRESSURE,
    IN_CONTAINMENT_RADIATION,
    IN_MANUAL_TRIP,
    IN_TRIP_BREAKER_CLOSED,
    IN_ROD_DRIVE_AVAILABLE,
    OUT_REACTOR_TRIP,
    OUT_ROD_SCRAM,
    OUT_TURBINE_TRIP,
    OUT_TRIP_BREAKER_ENERGIZED,
    OUT_SAFETY_INJECTION,
    OUT_CONTAINMENT_ISOLATION,
    OUT_MAIN_FEEDWATER_ISOLATION,
    OUT_AUXILIARY_FEEDWATER,
    OUT_PROTECTION_ALARM,
    WORK_TRIP_VOTES,
    WORK_TRIP_REQUEST,
    WORK_HIGH_CONTAINMENT,
    WORK_LOW_SG_LEVEL,
    NUCLEAR_LOCAL_COUNT
};

typedef struct {
    const char *name;
    int32_t reactor_mode;
    int32_t reactor_power_pct;
    int32_t pzr_pressure;
    int32_t pzr_level;
    int32_t pzr_press_a;
    int32_t pzr_press_b;
    int32_t pzr_press_c;
    int32_t sg_a_level;
    int32_t sg_b_level;
    int32_t containment_pressure;
    int32_t containment_radiation;
    int32_t manual_trip;
    int32_t trip_breaker_closed;
    int32_t rod_drive_available;
    int32_t reactor_trip;
    int32_t rod_scram;
    int32_t turbine_trip;
    int32_t trip_breaker_energized;
    int32_t safety_injection;
    int32_t containment_isolation;
    int32_t main_feedwater_isolation;
    int32_t auxiliary_feedwater;
    int32_t protection_alarm;
} Scenario;

static const Scenario scenarios[] = {
    {
        "normal_power",
        2, 100, 15500, 50, 15500, 15500, 15500, 60, 60, 100, 100,
        0, 1, 1,
        0, 0, 0, 1, 0, 0, 0, 0, 0
    },
    {
        "manual_trip",
        0, 0, 15500, 50, 15500, 15500, 15500, 60, 60, 100, 100,
        1, 1, 1,
        1, 1, 1, 0, 0, 0, 0, 0, 1
    },
    {
        "pressure_2oo3_trip_and_si",
        2, 100, 12900, 50, 12999, 12999, 13000, 60, 60, 100, 100,
        0, 1, 1,
        1, 1, 1, 0, 1, 1, 1, 0, 1
    },
    {
        "pressure_1oo3_no_trip",
        2, 100, 12900, 50, 12999, 13000, 13000, 60, 60, 100, 100,
        0, 1, 1,
        0, 0, 0, 1, 0, 0, 0, 0, 0
    },
    {
        "high_pzr_level_trip",
        2, 100, 15500, 93, 15500, 15500, 15500, 60, 60, 100, 100,
        0, 1, 1,
        1, 1, 1, 0, 0, 0, 0, 0, 1
    },
    {
        "high_power_trip",
        2, 110, 15500, 50, 15500, 15500, 15500, 60, 60, 100, 100,
        0, 1, 1,
        1, 1, 1, 0, 0, 0, 0, 0, 1
    },
    {
        "turbine_trip_only",
        2, 106, 15500, 50, 15500, 15500, 15500, 60, 60, 100, 100,
        0, 1, 1,
        0, 0, 1, 1, 0, 0, 0, 0, 0
    },
    {
        "high_containment_pressure",
        2, 100, 15500, 50, 15500, 15500, 15500, 60, 60, 151, 100,
        0, 1, 1,
        0, 0, 0, 1, 0, 1, 0, 0, 1
    },
    {
        "high_containment_radiation",
        2, 100, 15500, 50, 15500, 15500, 15500, 60, 60, 100, 10001,
        0, 1, 1,
        0, 0, 0, 1, 0, 1, 0, 0, 1
    },
    {
        "low_sg_with_manual_trip",
        2, 100, 15500, 50, 15500, 15500, 15500, 24, 60, 100, 100,
        1, 1, 1,
        1, 1, 1, 0, 0, 0, 1, 1, 1
    },
    {
        "low_sg_without_trip",
        2, 100, 15500, 50, 15500, 15500, 15500, 24, 60, 100, 100,
        0, 1, 1,
        0, 0, 0, 1, 0, 0, 1, 0, 0
    },
    {
        "exact_thresholds_no_reactor_trip",
        2, 109, 15500, 92, 13000, 13000, 13000, 25, 25, 150, 10000,
        0, 1, 1,
        0, 0, 1, 1, 0, 0, 0, 0, 0
    }
};

static SasmModule module;
static uint8_t sasm_buffer[262144];

static void load_compiled_module(const char *path)
{
    FILE *fp = fopen(path, "rb");
    assert(fp != NULL);

    size_t len = fread(sasm_buffer, 1, sizeof(sasm_buffer), fp);
    fclose(fp);

    assert(len > 0);
    assert(len < sizeof(sasm_buffer));
    assert(sasm_load(sasm_buffer, (uint32_t)len, &module) == 0);
    assert(sasm_validate(&module));
    assert(module.func_count == 1);
    assert(module.code_count == 1);
    assert(module.funcs[0].local_count == NUCLEAR_LOCAL_COUNT);
    assert(module.safety.global_stack_depth == 1);
}

static int check_output(const Scenario *scenario, const char *name,
                        int32_t actual, int32_t expected)
{
    if (actual == expected) {
        return 0;
    }

    fprintf(stderr,
            "FAIL %-36s %-28s expected=%d actual=%d\n",
            scenario->name, name, expected, actual);
    return 1;
}

static int run_scenario(const Scenario *scenario)
{
    VM vm;
    assert(vm_init(&vm, &module, 0) == 0);
    assert(push_frame(&vm, module.entry_function));
    assert(vm.frame_stack_ptr == 1);

    Frame *frame = &vm.frame_stack[0];
    assert(frame->local_count == NUCLEAR_LOCAL_COUNT);

    for (uint32_t i = 0; i < frame->local_count; i++) {
        frame->locals[i] = 0;
    }

    frame->locals[IN_REACTOR_MODE] = scenario->reactor_mode;
    frame->locals[IN_REACTOR_POWER_PCT] = scenario->reactor_power_pct;
    frame->locals[IN_PZR_PRESSURE] = scenario->pzr_pressure;
    frame->locals[IN_PZR_LEVEL] = scenario->pzr_level;
    frame->locals[IN_PZR_PRESS_A] = scenario->pzr_press_a;
    frame->locals[IN_PZR_PRESS_B] = scenario->pzr_press_b;
    frame->locals[IN_PZR_PRESS_C] = scenario->pzr_press_c;
    frame->locals[IN_SG_A_LEVEL] = scenario->sg_a_level;
    frame->locals[IN_SG_B_LEVEL] = scenario->sg_b_level;
    frame->locals[IN_CONTAINMENT_PRESSURE] = scenario->containment_pressure;
    frame->locals[IN_CONTAINMENT_RADIATION] = scenario->containment_radiation;
    frame->locals[IN_MANUAL_TRIP] = scenario->manual_trip;
    frame->locals[IN_TRIP_BREAKER_CLOSED] = scenario->trip_breaker_closed;
    frame->locals[IN_ROD_DRIVE_AVAILABLE] = scenario->rod_drive_available;

    assert(vm_execute_cycle(&vm) == VM_OK);
    assert(vm.val_stack_ptr == 0);

    int failures = 0;
    failures += check_output(scenario, "reactor_trip",
                             frame->locals[OUT_REACTOR_TRIP],
                             scenario->reactor_trip);
    failures += check_output(scenario, "rod_scram",
                             frame->locals[OUT_ROD_SCRAM],
                             scenario->rod_scram);
    failures += check_output(scenario, "turbine_trip",
                             frame->locals[OUT_TURBINE_TRIP],
                             scenario->turbine_trip);
    failures += check_output(scenario, "trip_breaker_energized",
                             frame->locals[OUT_TRIP_BREAKER_ENERGIZED],
                             scenario->trip_breaker_energized);
    failures += check_output(scenario, "safety_injection",
                             frame->locals[OUT_SAFETY_INJECTION],
                             scenario->safety_injection);
    failures += check_output(scenario, "containment_isolation",
                             frame->locals[OUT_CONTAINMENT_ISOLATION],
                             scenario->containment_isolation);
    failures += check_output(scenario, "main_feedwater_isolation",
                             frame->locals[OUT_MAIN_FEEDWATER_ISOLATION],
                             scenario->main_feedwater_isolation);
    failures += check_output(scenario, "auxiliary_feedwater",
                             frame->locals[OUT_AUXILIARY_FEEDWATER],
                             scenario->auxiliary_feedwater);
    failures += check_output(scenario, "protection_alarm",
                             frame->locals[OUT_PROTECTION_ALARM],
                             scenario->protection_alarm);

    return failures;
}

int main(int argc, char **argv)
{
    const char *path = argc > 1
        ? argv[1]
        : "tests/veristc-tests/out/nuclear_rps_esfas.sasm";

    load_compiled_module(path);

    int failures = 0;
    size_t count = sizeof(scenarios) / sizeof(scenarios[0]);
    for (size_t i = 0; i < count; i++) {
        failures += run_scenario(&scenarios[i]);
    }

    if (failures != 0) {
        fprintf(stderr, "%d nuclear protection expectation(s) failed\n",
                failures);
        return 1;
    }

    printf("nuclear RPS/ESFAS ST -> SASM -> VM: %zu scenarios passed\n",
           count);
    return 0;
}
