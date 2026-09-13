/*
 * Engineering-scale four-channel/two-train RPS and ESFAS test.
 *
 * The generated ST source is compiled by VeriSTC; this test loads that exact
 * .sasm module, injects independent channel inputs, executes the C VM, and
 * checks the voted trip masks and train-level actuations.
 */

#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <assert.h>

#include "../../vm/vm.h"
#include "../../rtos/abstract.h"
#include "../../vm/hotstandby/hotstandby.h"

#define NFULL_INITIATORS 128
#define NFULL_MASK_GROUPS 16
#define NFULL_LOCAL_COUNT 588
#define NFULL_INPUT_COUNT 525
#define NFULL_IN_TRAIN_A_RESET 3
#define NFULL_IN_TRAIN_B_RESET 4
#define NFULL_IN_QUALITY_A 5
#define NFULL_IN_BYPASS_A 6
#define NFULL_IN_QUALITY_B 7
#define NFULL_IN_BYPASS_B 8
#define NFULL_IN_QUALITY_C 9
#define NFULL_IN_BYPASS_C 10
#define NFULL_IN_QUALITY_D 11
#define NFULL_IN_BYPASS_D 12
#define NFULL_IN_RAW_BASE 13
#define NFULL_RAW_INDEX(initiator, channel) \
    (NFULL_IN_RAW_BASE + ((initiator) * 4) + (channel))

#define NFULL_OUT_MASK_A_BASE NFULL_INPUT_COUNT
#define NFULL_OUT_MASK_B_BASE (NFULL_OUT_MASK_A_BASE + NFULL_MASK_GROUPS)
#define NFULL_OUT_TRIP_A (NFULL_OUT_MASK_B_BASE + NFULL_MASK_GROUPS)
#define NFULL_OUT_SCRAM_A (NFULL_OUT_TRIP_A + 1)
#define NFULL_OUT_BREAKER_A (NFULL_OUT_TRIP_A + 2)
#define NFULL_OUT_SI_A (NFULL_OUT_TRIP_A + 3)
#define NFULL_OUT_ALARM_A (NFULL_OUT_TRIP_A + 7)
#define NFULL_OUT_TRIP_B (NFULL_OUT_TRIP_A + 8)
#define NFULL_OUT_SCRAM_B (NFULL_OUT_TRIP_B + 1)
#define NFULL_OUT_BREAKER_B (NFULL_OUT_TRIP_B + 2)
#define NFULL_OUT_SI_B (NFULL_OUT_TRIP_B + 3)
#define NFULL_OUT_ALARM_B (NFULL_OUT_TRIP_B + 7)
#define NFULL_OUT_FAULT_A (NFULL_OUT_TRIP_B + 8)
#define NFULL_OUT_FAULT_B (NFULL_OUT_FAULT_A + 1)
#define NFULL_OUT_FAULT_C (NFULL_OUT_FAULT_A + 2)
#define NFULL_OUT_FAULT_D (NFULL_OUT_FAULT_A + 3)

#define NFULL_GLOBAL_BASE 4096
#define NFULL_G_CYCLE_COUNTER (NFULL_GLOBAL_BASE + 0)
#define NFULL_G_STATE_A (NFULL_GLOBAL_BASE + 4)
#define NFULL_G_STATE_B (NFULL_GLOBAL_BASE + 8)
#define NFULL_G_TRIP_COUNTER_A (NFULL_GLOBAL_BASE + 12)
#define NFULL_G_TRIP_COUNTER_B (NFULL_GLOBAL_BASE + 16)
#define NFULL_G_FILTER_SAMPLE_COUNT (NFULL_GLOBAL_BASE + 20)
#define NFULL_G_FILTER_ACCUM_A (NFULL_GLOBAL_BASE + 24)
#define NFULL_G_LATCH_A_000 (NFULL_GLOBAL_BASE + 44)
#define NFULL_G_LATCH_B_000 (NFULL_GLOBAL_BASE + 48)

#define NFULL_TRIP_THRESHOLD(initiator) (100 + ((initiator) % 40))
#define NFULL_MASK_GROUP(initiator) ((initiator) / 8)
#define NFULL_MASK_BIT(initiator) (1 << ((initiator) % 8))

VM_Interface g_vm_interface = { 0 };

#include "../../vm/loader.c"
#include "../../vm/safeasm_interp.c"
#include "../../vm/hotstandby/snapshot.c"

#define MAX_CONDITIONS 8
#define MAX_EXPECTED 8

typedef struct {
    int initiator;
    int channel_mask;
} RawCondition;

typedef struct {
    const char *name;
    RawCondition conditions[MAX_CONDITIONS];
    int condition_count;
    int bad_quality_mask;
    int bypass_mask;
    int inhibit_mask;
    int expected_a[MAX_EXPECTED];
    int expected_a_count;
    int expected_b[MAX_EXPECTED];
    int expected_b_count;
    int expected_fault_a;
    int expected_fault_b;
    int expected_fault_c;
    int expected_fault_d;
} Scenario;

static const Scenario scenarios[] = {
    {
        "normal_no_inputs",
        {{0}}, 0, 0, 0, 0,
        {0}, 0, {0}, 0,
        0, 0, 0, 0
    },
    {
        "single_channel_no_trip",
        {{0, 0x1}}, 1, 0, 0, 0,
        {0}, 0, {0}, 0,
        0, 0, 0, 0
    },
    {
        "two_of_four_trip_si",
        {{0, 0x3}}, 1, 0, 0, 0,
        {0}, 1, {0}, 1,
        0, 0, 0, 0
    },
    {
        "three_of_four_trip_si",
        {{0, 0x7}}, 1, 0, 0, 0,
        {0}, 1, {0}, 1,
        0, 0, 0, 0
    },
    {
        "channel_a_bypass_blocks_vote",
        {{0, 0x3}}, 1, 0, 0x1, 0,
        {0}, 0, {0}, 0,
        1, 0, 0, 0
    },
    {
        "channel_a_bad_quality_blocks_vote",
        {{0, 0x3}}, 1, 0x1, 0, 0,
        {0}, 0, {0}, 0,
        1, 0, 0, 0
    },
    {
        "train_a_inhibit",
        {{0, 0x3}}, 1, 0, 0, 0x1,
        {0}, 0, {0}, 1,
        0, 0, 0, 0
    },
    {
        "four_actuation_categories",
        {{0, 0x3}, {1, 0x3}, {2, 0x3}, {3, 0x3}}, 4, 0, 0, 0,
        {0, 1, 2, 3}, 4, {0, 1, 2, 3}, 4,
        0, 0, 0, 0
    },
    {
        "exact_threshold_no_trip",
        {{4, 0x3}}, 1, 0, 0, 0,
        {0}, 0, {0}, 0,
        0, 0, 0, 0
    },
    {
        "one_count_above_threshold",
        {{4, 0x2}}, 1, 0, 0, 0,
        {0}, 0, {0}, 0,
        0, 0, 0, 0
    },
    {
        "invalid_range_isolated",
        {{5, 0x3}}, 1, 0, 0, 0,
        {0}, 0, {0}, 0,
        2, 2, 0, 0
    },
    {
        "independent_initiators_do_not_bleed",
        {{6, 0x3}, {7, 0x1}, {8, 0x0C}}, 3, 0, 0, 0,
        {6, 8}, 2, {6, 8}, 2,
        0, 0, 0, 0
    },
    {
        "filter_blocks_single_cycle",
        {{0, 0x3}}, 1, 0, 0, 0,
        {0}, 0, {0}, 0,
        1, 1, 0, 0
    },
    {
        "filter_settles_after_second_cycle",
        {{0, 0x3}}, 1, 0, 0, 0,
        {0}, 1, {0}, 1,
        0, 0, 0, 0
    },
    {
        "rs_latch_hold_after_trip",
        {{0, 0x3}}, 1, 0, 0, 0,
        {0}, 1, {0}, 1,
        0, 0, 0, 0
    },
    {
        "rs_reset_a_after_trip",
        {{0, 0x3}}, 1, 0, 0, 0,
        {0}, 0, {0}, 1,
        0, 0, 0, 0
    }
};

static SasmModule module;
static uint8_t sasm_buffer[2U * 1024U * 1024U];
static VM vm;
static VM standby_vm;

static uint32_t raw_index(int initiator, int channel)
{
    return NFULL_RAW_INDEX(initiator, channel);
}

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
    assert(module.funcs[0].local_count == NFULL_LOCAL_COUNT);
    assert(module.safety.global_stack_depth == 1);
    assert(module.safety.safety_level == 1);
    assert(module.safety.wcet_func_count == 1);
    assert(module.safety.wcet_funcs[0].func_idx == 0);
    assert(module.safety.wcet_funcs[0].cycles > 0);
    assert(module.safety.wcet_funcs[0].ns ==
           module.safety.wcet_funcs[0].cycles * 10);
}

static void reset_entry_frame(void)
{
    assert(vm_init(&vm, &module, 0) == 0);
    assert(push_frame(&vm, module.entry_function));
    assert(vm.frame_stack_ptr == 1);
    assert(vm.frame_stack[0].local_count == NFULL_LOCAL_COUNT);

    for (uint32_t i = 0; i < vm.frame_stack[0].local_count; i++) {
        vm.frame_stack[0].locals[i] = 0;
    }

    vm.frame_stack[0].locals[NFULL_IN_QUALITY_A] = 1;
    vm.frame_stack[0].locals[NFULL_IN_QUALITY_B] = 1;
    vm.frame_stack[0].locals[NFULL_IN_QUALITY_C] = 1;
    vm.frame_stack[0].locals[NFULL_IN_QUALITY_D] = 1;
}

static void apply_scenario(const Scenario *scenario)
{
    Frame *frame = &vm.frame_stack[0];

    frame->locals[NFULL_IN_QUALITY_A] =
        (scenario->bad_quality_mask & 0x1) ? 0 : 1;
    frame->locals[NFULL_IN_QUALITY_B] =
        (scenario->bad_quality_mask & 0x2) ? 0 : 1;
    frame->locals[NFULL_IN_QUALITY_C] =
        (scenario->bad_quality_mask & 0x4) ? 0 : 1;
    frame->locals[NFULL_IN_QUALITY_D] =
        (scenario->bad_quality_mask & 0x8) ? 0 : 1;

    frame->locals[NFULL_IN_BYPASS_A] = (scenario->bypass_mask & 0x1) ? 1 : 0;
    frame->locals[NFULL_IN_BYPASS_B] = (scenario->bypass_mask & 0x2) ? 1 : 0;
    frame->locals[NFULL_IN_BYPASS_C] = (scenario->bypass_mask & 0x4) ? 1 : 0;
    frame->locals[NFULL_IN_BYPASS_D] = (scenario->bypass_mask & 0x8) ? 1 : 0;

    frame->locals[1] = (scenario->inhibit_mask & 0x1) ? 1 : 0;
    frame->locals[2] = (scenario->inhibit_mask & 0x2) ? 1 : 0;

    for (int i = 0; i < scenario->condition_count; i++) {
        const RawCondition *condition = &scenario->conditions[i];
        int limit = NFULL_TRIP_THRESHOLD(condition->initiator);
        int value = limit + 1;

        if (strstr(scenario->name, "exact_threshold") != NULL) {
            value = limit;
        }

        if (strstr(scenario->name, "invalid_range") != NULL) {
            value = 1001;
        }

        if (condition->initiator == 0 &&
            (strstr(scenario->name, "filter_blocks") != NULL ||
             strstr(scenario->name, "filter_settles") != NULL)) {
            value = 151;
        } else if (condition->initiator == 0 &&
                   strstr(scenario->name, "invalid_range") == NULL) {
            value *= 2;
        }

        for (int channel = 0; channel < 4; channel++) {
            if (condition->channel_mask & (1 << channel)) {
                frame->locals[raw_index(condition->initiator, channel)] = value;
            }
        }
    }
}

static int check_value(const Scenario *scenario, const char *signal,
                       int32_t actual, int32_t expected)
{
    if (actual == expected) {
        return 0;
    }

    fprintf(stderr, "FAIL %-36s %-24s expected=%d actual=%d\n",
            scenario->name, signal, expected, actual);
    return 1;
}

static uint32_t expected_mask(const int *expected, int count, int group)
{
    uint32_t mask = 0;

    for (int i = 0; i < count; i++) {
        int initiator = expected[i];
        if (NFULL_MASK_GROUP(initiator) == group) {
            mask |= (uint32_t)NFULL_MASK_BIT(initiator);
        }
    }
    return mask;
}

static int32_t read_global_i32_vm(const VM *target_vm, uint32_t addr)
{
    return (int32_t)((uint32_t)target_vm->memory[addr] |
                     ((uint32_t)target_vm->memory[addr + 1] << 8) |
                     ((uint32_t)target_vm->memory[addr + 2] << 16) |
                     ((uint32_t)target_vm->memory[addr + 3] << 24));
}

static int32_t read_global_i32(uint32_t addr)
{
    return read_global_i32_vm(&vm, addr);
}

static int expected_actuation(const int *expected, int count, int category)
{
    for (int i = 0; i < count; i++) {
        if ((expected[i] % 4) == category) {
            return 1;
        }
    }
    return 0;
}

static int run_scenario(const Scenario *scenario)
{
    reset_entry_frame();
    apply_scenario(scenario);

    Frame *frame = &vm.frame_stack[0];
    int filter_settle = strstr(scenario->name, "filter_settles") != NULL;
    int latch_hold = strstr(scenario->name, "latch_hold") != NULL;
    int reset_a = strstr(scenario->name, "reset_a") != NULL;
    int expected_cycles = reset_a ? 4 : ((filter_settle || latch_hold) ? 2 : 1);
    int32_t initial_raw_a = frame->locals[raw_index(0, 0)];

    assert(vm_execute_cycle(&vm) == VM_OK);
    assert(vm.val_stack_ptr == 0);

    if (filter_settle) {
        frame->pc = 0;
        frame->block_depth = 0;
        vm.val_stack_ptr = 0;
        vm.cycle_count = 0;
        assert(vm_execute_cycle(&vm) == VM_OK);
        assert(vm.val_stack_ptr == 0);
    }

    if (latch_hold || reset_a) {
        for (uint32_t i = NFULL_IN_RAW_BASE;
             i < NFULL_IN_RAW_BASE + NFULL_INITIATORS * 4; i++) {
            frame->locals[i] = 0;
        }
        frame->pc = 0;
        frame->block_depth = 0;
        vm.val_stack_ptr = 0;
        vm.cycle_count = 0;
        assert(vm_execute_cycle(&vm) == VM_OK);
        assert(vm.val_stack_ptr == 0);
    }

    if (reset_a) {
        frame->locals[NFULL_IN_TRAIN_A_RESET] = 1;
        frame->pc = 0;
        frame->block_depth = 0;
        vm.val_stack_ptr = 0;
        vm.cycle_count = 0;
        assert(vm_execute_cycle(&vm) == VM_OK);
        assert(vm.val_stack_ptr == 0);

        frame->locals[NFULL_IN_TRAIN_A_RESET] = 0;
        frame->pc = 0;
        frame->block_depth = 0;
        vm.val_stack_ptr = 0;
        vm.cycle_count = 0;
        assert(vm_execute_cycle(&vm) == VM_OK);
        assert(vm.val_stack_ptr == 0);
    }

    int failures = 0;

    for (int group = 0; group < NFULL_MASK_GROUPS; group++) {
        uint32_t mask_a = (uint32_t)frame->locals[NFULL_OUT_MASK_A_BASE + group];
        uint32_t mask_b = (uint32_t)frame->locals[NFULL_OUT_MASK_B_BASE + group];
        uint32_t want_a = expected_mask(scenario->expected_a,
                                        scenario->expected_a_count, group);
        uint32_t want_b = expected_mask(scenario->expected_b,
                                        scenario->expected_b_count, group);

        if (mask_a != want_a || mask_b != want_b) {
            fprintf(stderr,
                    "FAIL %-36s mask_group=%02d A=%08x/%08x B=%08x/%08x\n",
                    scenario->name, group, mask_a, want_a, mask_b, want_b);
            failures++;
        }
    }

    int trip_a = scenario->expected_a_count > 0;
    int trip_b = scenario->expected_b_count > 0;
    failures += check_value(scenario, "trip_a",
                            frame->locals[NFULL_OUT_TRIP_A], trip_a);
    failures += check_value(scenario, "trip_b",
                            frame->locals[NFULL_OUT_TRIP_B], trip_b);
    failures += check_value(scenario, "scram_a",
                            frame->locals[NFULL_OUT_SCRAM_A], trip_a);
    failures += check_value(scenario, "scram_b",
                            frame->locals[NFULL_OUT_SCRAM_B], trip_b);
    failures += check_value(scenario, "breaker_a",
                            frame->locals[NFULL_OUT_BREAKER_A], !trip_a);
    failures += check_value(scenario, "breaker_b",
                            frame->locals[NFULL_OUT_BREAKER_B], !trip_b);

    for (int category = 0; category < 4; category++) {
        int want_a = expected_actuation(scenario->expected_a,
                                        scenario->expected_a_count, category);
        int want_b = expected_actuation(scenario->expected_b,
                                        scenario->expected_b_count, category);

        failures += check_value(scenario, "actuation_a",
                                frame->locals[NFULL_OUT_SI_A + category],
                                want_a);
        failures += check_value(scenario, "actuation_b",
                                frame->locals[NFULL_OUT_SI_B + category],
                                want_b);
    }
    failures += check_value(scenario, "alarm_a",
                            frame->locals[NFULL_OUT_ALARM_A], trip_a);
    failures += check_value(scenario, "alarm_b",
                            frame->locals[NFULL_OUT_ALARM_B], trip_b);

    failures += check_value(scenario, "channel_fault_a",
                            frame->locals[NFULL_OUT_FAULT_A],
                            scenario->expected_fault_a);
    failures += check_value(scenario, "channel_fault_b",
                            frame->locals[NFULL_OUT_FAULT_B],
                            scenario->expected_fault_b);
    failures += check_value(scenario, "channel_fault_c",
                            frame->locals[NFULL_OUT_FAULT_C],
                            scenario->expected_fault_c);
    failures += check_value(scenario, "channel_fault_d",
                            frame->locals[NFULL_OUT_FAULT_D],
                            scenario->expected_fault_d);

    int final_trip_a = scenario->expected_a_count > 0;
    int final_trip_b = scenario->expected_b_count > 0;
    int expected_trip_counter_a =
        reset_a ? 2 :
        (filter_settle ? 1 : (final_trip_a ? expected_cycles : 0));
    int expected_trip_counter_b =
        filter_settle ? 1 : (final_trip_b ? expected_cycles : 0);
    int expected_accum_a =
        initial_raw_a * (filter_settle ? expected_cycles : 1);

    failures += check_value(scenario, "cycle_counter",
                            read_global_i32(NFULL_G_CYCLE_COUNTER),
                            expected_cycles);
    failures += check_value(scenario, "filter_sample_count",
                            read_global_i32(NFULL_G_FILTER_SAMPLE_COUNT),
                            expected_cycles);
    failures += check_value(scenario, "filter_accum_a",
                            read_global_i32(NFULL_G_FILTER_ACCUM_A),
                            expected_accum_a);
    failures += check_value(scenario, "state_a",
                            read_global_i32(NFULL_G_STATE_A),
                            final_trip_a ? 2 : 1);
    failures += check_value(scenario, "state_b",
                            read_global_i32(NFULL_G_STATE_B),
                            final_trip_b ? 2 : 1);
    failures += check_value(scenario, "trip_counter_a",
                            read_global_i32(NFULL_G_TRIP_COUNTER_A),
                            expected_trip_counter_a);
    failures += check_value(scenario, "trip_counter_b",
                            read_global_i32(NFULL_G_TRIP_COUNTER_B),
                            expected_trip_counter_b);

    return failures;
}

static const Scenario *find_scenario(const char *name)
{
    size_t count = sizeof(scenarios) / sizeof(scenarios[0]);
    for (size_t i = 0; i < count; i++) {
        if (strcmp(scenarios[i].name, name) == 0) {
            return &scenarios[i];
        }
    }
    return NULL;
}

static int test_global_snapshot_sync(void)
{
    const Scenario *scenario = find_scenario("rs_latch_hold_after_trip");
    assert(scenario != NULL);

    reset_entry_frame();
    apply_scenario(scenario);
    assert(vm_execute_cycle(&vm) == VM_OK);
    assert(vm.val_stack_ptr == 0);
    assert(read_global_i32(NFULL_G_LATCH_A_000) == 1);
    assert(read_global_i32(NFULL_G_LATCH_B_000) == 1);

    HotStandbySystem active;
    HotStandbySystem standby;
    memset(&active, 0, sizeof(active));
    memset(&standby, 0, sizeof(standby));
    active.vm = &vm;
    standby.vm = &standby_vm;
    assert(vm_init(&standby_vm, &module, 0) == 0);
    hs_dirty_init(&active.dirty_tracker, vm.memory_size);
    hs_dirty_init(&standby.dirty_tracker, standby_vm.memory_size);

    assert(hs_snapshot_create(&active) == 0);
    const SnapshotHeader *snapshot =
        (const SnapshotHeader *)active.snapshot_buf;
    assert(snapshot->dirty_page_count == 1);
    assert(snapshot->dirty_page_indices[0] ==
           NFULL_GLOBAL_BASE / HS_PAGE_SIZE);
    assert(hs_snapshot_apply(&standby, active.snapshot_buf,
                             active.snapshot_size) == 0);
    assert(standby_vm.frame_stack_ptr == 1);

    assert(read_global_i32_vm(&standby_vm, NFULL_G_LATCH_A_000) == 1);
    assert(read_global_i32_vm(&standby_vm, NFULL_G_LATCH_B_000) == 1);
    assert(read_global_i32_vm(&standby_vm, NFULL_G_STATE_A) == 2);
    assert(read_global_i32_vm(&standby_vm, NFULL_G_STATE_B) == 2);
    assert(read_global_i32_vm(&standby_vm, NFULL_G_TRIP_COUNTER_A) == 1);
    assert(read_global_i32_vm(&standby_vm, NFULL_G_TRIP_COUNTER_B) == 1);

    Frame *backup_frame = &standby_vm.frame_stack[0];
    for (uint32_t i = NFULL_IN_RAW_BASE;
         i < NFULL_IN_RAW_BASE + NFULL_INITIATORS * 4; i++) {
        backup_frame->locals[i] = 0;
    }
    backup_frame->pc = 0;
    backup_frame->block_depth = 0;
    standby_vm.val_stack_ptr = 0;
    standby_vm.cycle_count = 0;
    assert(vm_execute_cycle(&standby_vm) == VM_OK);
    assert(standby_vm.val_stack_ptr == 0);

    int failures = 0;
    failures += check_value(scenario, "snapshot_trip_a",
                            backup_frame->locals[NFULL_OUT_TRIP_A], 1);
    failures += check_value(scenario, "snapshot_trip_b",
                            backup_frame->locals[NFULL_OUT_TRIP_B], 1);
    failures += check_value(scenario, "snapshot_cycle_counter",
                            read_global_i32_vm(&standby_vm,
                                               NFULL_G_CYCLE_COUNTER), 2);
    failures += check_value(scenario, "snapshot_trip_counter_a",
                            read_global_i32_vm(&standby_vm,
                                               NFULL_G_TRIP_COUNTER_A), 2);
    failures += check_value(scenario, "snapshot_trip_counter_b",
                            read_global_i32_vm(&standby_vm,
                                               NFULL_G_TRIP_COUNTER_B), 2);
    return failures;
}

int main(int argc, char **argv)
{
    const char *path = argc > 1
        ? argv[1]
        : "tests/veristc-tests/out/nuclear_rps_esfas_full.sasm";

    load_compiled_module(path);

    int failures = 0;
    size_t count = sizeof(scenarios) / sizeof(scenarios[0]);
    for (size_t i = 0; i < count; i++) {
        failures += run_scenario(&scenarios[i]);
    }
    failures += test_global_snapshot_sync();

    if (failures != 0) {
        fprintf(stderr, "%d full-scale nuclear expectation(s) failed\n",
                failures);
        return 1;
    }

    printf("full nuclear RPS/ESFAS ST -> SASM -> VM: "
           "%zu scenarios and global snapshot sync passed, "
           "%d initiators, 4 channels, 2 trains\n",
           count, NFULL_INITIATORS);
    return 0;
}
