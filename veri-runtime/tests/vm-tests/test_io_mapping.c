/*
 * I/O mapping layer unit tests.
 * Covers conversion, safety checks, mapping table operations, and mock I/O.
 */

#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <math.h>

#include "../../core/vm.h"
#include "../../rtos/abstract.h"
#include "../../io/io_mapping.h"

VM_Interface g_vm_interface = { 0 };

/* Mock I/O channels */
#define MOCK_CHANNELS 8
static int32_t mock_channel_values[MOCK_CHANNELS];
static int32_t mock_written_values[MOCK_CHANNELS];
static int mock_read_fail_channel = -1;

static int mock_io_read(uint32_t channel_id, int32_t *value)
{
    if ((int)channel_id == mock_read_fail_channel) return -1;
    if (channel_id >= MOCK_CHANNELS) return -1;
    *value = mock_channel_values[channel_id];
    return 0;
}

static int mock_io_write(uint32_t channel_id, int32_t value)
{
    if (channel_id >= MOCK_CHANNELS) return -1;
    mock_written_values[channel_id] = value;
    return 0;
}

static void setup_mocks(void)
{
    memset(mock_channel_values, 0, sizeof(mock_channel_values));
    memset(mock_written_values, 0, sizeof(mock_written_values));
    mock_read_fail_channel = -1;
    g_vm_interface.io_read = mock_io_read;
    g_vm_interface.io_write = mock_io_write;
}

/* Helper: create a test IOMapEntryRuntime */
static IOMapEntryRuntime make_entry(uint32_t ch_id, uint8_t dir, uint8_t io_type,
                                     double scale, double bias,
                                     int32_t low, int32_t high, uint32_t mem_off)
{
    IOMapEntryRuntime e;
    memset(&e, 0, sizeof(e));
    e.channel_id = ch_id;
    e.direction = dir;
    e.io_type = io_type;
    e.scale_factor = scale;
    e.bias = bias;
    e.safety_limit_low = low;
    e.safety_limit_high = high;
    e.mem_offset = mem_off;
    snprintf(e.var_name, sizeof(e.var_name), "ch%u", ch_id);
    return e;
}

/* ================================================================
   Conversion tests
   ================================================================ */

static void test_raw_to_eng_identity(void)
{
    IOMapEntryRuntime e = make_entry(0, IO_DIR_INPUT, IO_TYPE_AI, 1.0, 0.0, 0, 1000, 0);
    assert(io_mapping_raw_to_eng(&e, 100) == 100);
}

static void test_raw_to_eng_scale_bias(void)
{
    IOMapEntryRuntime e = make_entry(0, IO_DIR_INPUT, IO_TYPE_AI, 0.5, 10.0, 0, 1000, 0);
    assert(io_mapping_raw_to_eng(&e, 200) == 110);
}

static void test_raw_to_eng_overflow(void)
{
    IOMapEntryRuntime e = make_entry(0, IO_DIR_INPUT, IO_TYPE_AI, 100.0, 0.0, 0, 1000, 0);
    int32_t result = io_mapping_raw_to_eng(&e, INT32_MAX);
    assert(result == INT32_MAX);
}

static void test_raw_to_eng_underflow(void)
{
    IOMapEntryRuntime e = make_entry(0, IO_DIR_INPUT, IO_TYPE_AI, 100.0, 0.0, 0, 1000, 0);
    int32_t result = io_mapping_raw_to_eng(&e, INT32_MIN);
    assert(result == INT32_MIN);
}

static void test_eng_to_raw_identity(void)
{
    IOMapEntryRuntime e = make_entry(0, IO_DIR_OUTPUT, IO_TYPE_AO, 1.0, 0.0, 0, 1000, 0);
    assert(io_mapping_eng_to_raw(&e, 100) == 100);
}

static void test_eng_to_raw_zero_scale(void)
{
    IOMapEntryRuntime e = make_entry(0, IO_DIR_OUTPUT, IO_TYPE_AO, 0.0, 0.0, 0, 1000, 0);
    assert(io_mapping_eng_to_raw(&e, 42) == 42);
}

/* ================================================================
   Safety check tests
   ================================================================ */

static void test_safety_check_within(void)
{
    IOMapEntryRuntime e = make_entry(0, IO_DIR_INPUT, IO_TYPE_AI, 1.0, 0.0, 0, 100, 0);
    assert(io_mapping_safety_check(&e, 50) == true);
}

static void test_safety_check_below(void)
{
    IOMapEntryRuntime e = make_entry(0, IO_DIR_INPUT, IO_TYPE_AI, 1.0, 0.0, 0, 100, 0);
    assert(io_mapping_safety_check(&e, -1) == false);
}

static void test_safety_check_above(void)
{
    IOMapEntryRuntime e = make_entry(0, IO_DIR_INPUT, IO_TYPE_AI, 1.0, 0.0, 0, 100, 0);
    assert(io_mapping_safety_check(&e, 101) == false);
}

static void test_safety_check_no_limits(void)
{
    /* low > high means no limits */
    IOMapEntryRuntime e = make_entry(0, IO_DIR_INPUT, IO_TYPE_AI, 1.0, 0.0, 100, 0, 0);
    assert(io_mapping_safety_check(&e, 999999) == true);
    assert(io_mapping_safety_check(&e, -999999) == true);
}

/* ================================================================
   Mapping table tests
   ================================================================ */

static void test_mapping_init(void)
{
    setup_mocks();

    /* Build a minimal SasmModule with 2 iomap entries */
    SasmModule module;
    memset(&module, 0, sizeof(module));
    module.version = 1;
    module.iomap_count = 2;

    module.iomap[0].channel_id = 0;
    module.iomap[0].direction = IO_DIR_INPUT;
    module.iomap[0].io_type = IO_TYPE_AI;
    module.iomap[0].scale_factor = 1.0;
    module.iomap[0].bias = 0.0;
    module.iomap[0].safety_limit_low = -1000;
    module.iomap[0].safety_limit_high = 1000;
    module.iomap[0].mem_offset = 0;
    module.iomap[0].st_var_name_offset = 0;

    module.iomap[1].channel_id = 1;
    module.iomap[1].direction = IO_DIR_OUTPUT;
    module.iomap[1].io_type = IO_TYPE_AO;
    module.iomap[1].scale_factor = 1.0;
    module.iomap[1].bias = 0.0;
    module.iomap[1].safety_limit_low = -1000;
    module.iomap[1].safety_limit_high = 1000;
    module.iomap[1].mem_offset = 4;
    module.iomap[1].st_var_name_offset = 12; /* after "Temperature\0" */

    /* Debug buffer with two variable names */
    const uint8_t dbg[] = "Temperature\0Pressure\0";

    IOMappingTable table;
    int rc = io_mapping_init(&table, &module, dbg, sizeof(dbg));
    assert(rc == 0);
    assert(table.count == 2);
    assert(table.input_count == 1);
    assert(table.output_count == 1);
    assert(table.state == IOMAP_STATE_READY);
    assert(strcmp(table.entries[0].var_name, "Temperature") == 0);
    assert(strcmp(table.entries[1].var_name, "Pressure") == 0);
}

static void test_mapping_read_all_ai(void)
{
    setup_mocks();

    IOMappingTable table;
    memset(&table, 0, sizeof(table));
    table.state = IOMAP_STATE_READY;
    table.count = 1;
    table.input_count = 1;
    table.entries[0] = make_entry(0, IO_DIR_INPUT, IO_TYPE_AI, 2.0, 0.0, -1000, 1000, 100);

    mock_channel_values[0] = 50;  /* raw value */

    static VM vm;
    memset(&vm, 0, sizeof(vm));
    vm.memory_size = 256;

    int rc = io_mapping_read_all(&table, &vm);
    assert(rc == 0);
    assert(table.entries[0].raw_value == 50);
    assert(table.entries[0].eng_value == 100);  /* 50 * 2.0 + 0 */
    /* Check VM memory at offset 100 (little-endian) */
    int32_t mem_val = (int32_t)vm.memory[100]
                    | ((int32_t)vm.memory[101] << 8)
                    | ((int32_t)vm.memory[102] << 16)
                    | ((int32_t)vm.memory[103] << 24);
    assert(mem_val == 100);
}

static void test_mapping_write_all_ao(void)
{
    setup_mocks();

    IOMappingTable table;
    memset(&table, 0, sizeof(table));
    table.state = IOMAP_STATE_READY;
    table.count = 1;
    table.output_count = 1;
    /* scale=2.0, bias=0: raw = eng / 2 */
    table.entries[0] = make_entry(1, IO_DIR_OUTPUT, IO_TYPE_AO, 2.0, 0.0, -1000, 1000, 200);

    static VM vm;
    memset(&vm, 0, sizeof(vm));
    vm.memory_size = 512;

    /* Write eng_value = 80 to VM memory at offset 200 (little-endian) */
    int32_t eng_val = 80;
    vm.memory[200] = (uint8_t)(eng_val & 0xFF);
    vm.memory[201] = (uint8_t)((eng_val >> 8) & 0xFF);
    vm.memory[202] = (uint8_t)((eng_val >> 16) & 0xFF);
    vm.memory[203] = (uint8_t)((eng_val >> 24) & 0xFF);

    int rc = io_mapping_write_all(&table, &vm);
    assert(rc == 0);
    assert(table.entries[0].eng_value == 80);
    /* raw = (80 - 0) / 2.0 = 40 */
    assert(table.entries[0].raw_value == 40);
    assert(mock_written_values[1] == 40);
}

static void test_mapping_digital_io(void)
{
    setup_mocks();

    IOMappingTable table;
    memset(&table, 0, sizeof(table));
    table.state = IOMAP_STATE_READY;
    table.count = 2;
    table.input_count = 1;
    table.output_count = 1;

    /* DI channel */
    table.entries[0] = make_entry(2, IO_DIR_INPUT, IO_TYPE_DI, 1.0, 0.0, 0, 1, 300);
    /* DO channel */
    table.entries[1] = make_entry(3, IO_DIR_OUTPUT, IO_TYPE_DO, 1.0, 0.0, 0, 1, 304);

    mock_channel_values[2] = 1;  /* DI raw = 1 */

    static VM vm;
    memset(&vm, 0, sizeof(vm));
    vm.memory_size = 512;

    /* Read DI */
    int rc = io_mapping_read_all(&table, &vm);
    assert(rc == 0);
    assert(table.entries[0].raw_value == 1);
    assert(table.entries[0].eng_value == 1);

    /* Write DO: put value 1 in VM memory at offset 304 */
    vm.memory[304] = 1;
    vm.memory[305] = 0;
    vm.memory[306] = 0;
    vm.memory[307] = 0;

    rc = io_mapping_write_all(&table, &vm);
    assert(rc == 0);
    assert(mock_written_values[3] == 1);
}

static void test_mapping_safety_clamp(void)
{
    setup_mocks();

    IOMappingTable table;
    memset(&table, 0, sizeof(table));
    table.state = IOMAP_STATE_READY;
    table.count = 1;
    table.input_count = 1;
    /* safety limits: 0..100 */
    table.entries[0] = make_entry(0, IO_DIR_INPUT, IO_TYPE_AI, 1.0, 0.0, 0, 100, 0);

    mock_channel_values[0] = 200;  /* raw=200, eng=200, exceeds high=100 */

    static VM vm;
    memset(&vm, 0, sizeof(vm));
    vm.memory_size = 256;

    int rc = io_mapping_read_all(&table, &vm);
    assert(rc == 0);
    /* Should be clamped to safety_limit_high = 100 */
    assert(table.entries[0].eng_value == 100);
    assert(table.safety_violations == 1);

    /* Check VM memory has clamped value */
    int32_t mem_val = (int32_t)vm.memory[0]
                    | ((int32_t)vm.memory[1] << 8)
                    | ((int32_t)vm.memory[2] << 16)
                    | ((int32_t)vm.memory[3] << 24);
    assert(mem_val == 100);
}

static void test_mapping_get_channel(void)
{
    IOMappingTable table;
    memset(&table, 0, sizeof(table));
    table.count = 2;
    table.entries[0] = make_entry(5, IO_DIR_INPUT, IO_TYPE_AI, 1.0, 0.0, 0, 100, 0);
    table.entries[1] = make_entry(7, IO_DIR_OUTPUT, IO_TYPE_AO, 1.0, 0.0, 0, 100, 4);

    IOMapEntryRuntime *found = io_mapping_get_channel(&table, 5);
    assert(found != NULL);
    assert(found->channel_id == 5);

    found = io_mapping_get_channel(&table, 7);
    assert(found != NULL);
    assert(found->channel_id == 7);

    found = io_mapping_get_channel(&table, 99);
    assert(found == NULL);
}

static void test_mapping_get_by_name(void)
{
    IOMappingTable table;
    memset(&table, 0, sizeof(table));
    table.count = 2;
    table.entries[0] = make_entry(0, IO_DIR_INPUT, IO_TYPE_AI, 1.0, 0.0, 0, 100, 0);
    snprintf(table.entries[0].var_name, sizeof(table.entries[0].var_name), "Temp");
    table.entries[1] = make_entry(1, IO_DIR_OUTPUT, IO_TYPE_AO, 1.0, 0.0, 0, 100, 4);
    snprintf(table.entries[1].var_name, sizeof(table.entries[1].var_name), "Pressure");

    IOMapEntryRuntime *found = io_mapping_get_by_name(&table, "Temp");
    assert(found != NULL);
    assert(found->channel_id == 0);

    found = io_mapping_get_by_name(&table, "Pressure");
    assert(found != NULL);
    assert(found->channel_id == 1);

    found = io_mapping_get_by_name(&table, "NonExistent");
    assert(found == NULL);
}

static void test_mapping_reset(void)
{
    IOMappingTable table;
    memset(&table, 0, sizeof(table));
    table.state = IOMAP_STATE_ERROR;
    table.count = 2;
    table.read_errors = 5;
    table.write_errors = 3;
    table.safety_violations = 2;
    table.entries[0] = make_entry(0, IO_DIR_INPUT, IO_TYPE_AI, 1.0, 0.0, 0, 100, 0);
    table.entries[0].raw_value = 42;
    table.entries[0].eng_value = 42;
    table.entries[0].fault = true;
    table.entries[1] = make_entry(1, IO_DIR_OUTPUT, IO_TYPE_AO, 1.0, 0.0, 0, 100, 4);
    table.entries[1].raw_value = 10;
    table.entries[1].eng_value = 10;
    table.entries[1].fault = true;

    io_mapping_reset(&table);

    assert(table.state == IOMAP_STATE_READY);
    assert(table.read_errors == 0);
    assert(table.write_errors == 0);
    assert(table.safety_violations == 0);
    assert(table.entries[0].raw_value == 0);
    assert(table.entries[0].eng_value == 0);
    assert(table.entries[0].fault == false);
    assert(table.entries[1].raw_value == 0);
    assert(table.entries[1].eng_value == 0);
    assert(table.entries[1].fault == false);
}

static void test_mapping_null_safety(void)
{
    /* NULL table should not crash */
    assert(io_mapping_get_channel(NULL, 0) == NULL);
    assert(io_mapping_get_by_name(NULL, "x") == NULL);
    assert(io_mapping_get_by_name(NULL, NULL) == NULL);

    /* NULL entry for conversion functions returns the input value */
    assert(io_mapping_raw_to_eng(NULL, 42) == 42);
    assert(io_mapping_eng_to_raw(NULL, 42) == 42);

    /* NULL entry for safety check returns false */
    assert(io_mapping_safety_check(NULL, 50) == false);

    /* NULL table/vm for read/write should return -1 */
    IOMappingTable table;
    memset(&table, 0, sizeof(table));
    table.state = IOMAP_STATE_READY;
    assert(io_mapping_read_all(NULL, NULL) == -1);
    assert(io_mapping_read_all(&table, NULL) == -1);
    assert(io_mapping_write_all(NULL, NULL) == -1);
    assert(io_mapping_write_all(&table, NULL) == -1);

    /* io_mapping_init with NULL */
    assert(io_mapping_init(NULL, NULL, NULL, 0) == -1);

    /* io_mapping_reset with NULL should not crash */
    io_mapping_reset(NULL);

    /* io_mapping_cycle with NULL */
    assert(io_mapping_cycle(NULL, NULL) == -1);
}

int main(void)
{
    /* Conversion tests */
    test_raw_to_eng_identity();
    test_raw_to_eng_scale_bias();
    test_raw_to_eng_overflow();
    test_raw_to_eng_underflow();
    test_eng_to_raw_identity();
    test_eng_to_raw_zero_scale();

    /* Safety check tests */
    test_safety_check_within();
    test_safety_check_below();
    test_safety_check_above();
    test_safety_check_no_limits();

    /* Mapping table tests (need mocks) */
    setup_mocks();
    test_mapping_init();
    test_mapping_read_all_ai();
    test_mapping_write_all_ao();
    test_mapping_digital_io();
    test_mapping_safety_clamp();
    test_mapping_get_channel();
    test_mapping_get_by_name();
    test_mapping_reset();
    test_mapping_null_safety();

    puts("I/O mapping tests passed");
    return 0;
}
