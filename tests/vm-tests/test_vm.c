/*
 * Minimal SafeASM VM regression test.
 * Covers arithmetic, conditional branch and divide-by-zero trapping.
 */

#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "../../vm/vm.h"
#include "../../rtos/abstract.h"

VM_Interface g_vm_interface = { 0 };

#include "../../vm/loader.c"
#include "../../vm/safeasm_interp.c"

static SasmModule module;

static void install_code(const uint8_t *body, uint32_t body_size)
{
    assert(body_size <= SASM_MAX_FUNCTION_CODE_SIZE);
    memset(&module, 0, sizeof(module));
    module.version = 1;
    module.type_count = 1;
    module.types[0].return_count = 1;
    module.types[0].return_types[0] = VAL_I32;
    module.func_count = 1;
    module.code_count = 1;
    module.codes[0].func_idx = 0;
    module.codes[0].body_offset = 0;
    module.codes[0].body_size = body_size;
    memcpy(module.code_pool, body, body_size);
    module.code_size = body_size;
    module.total_memory_size = 256;
    module.safety.cycle_limit = 1000;
    module.safety.global_stack_depth = 8;
    module.entry_function = 0;
}

static void run_module(const uint8_t *body, uint32_t body_size, int *result)
{
    install_code(body, body_size);
    static VM vm;
    assert(vm_init(&vm, &module, 256) == 0);
    int rc = vm_run(&vm);
    assert(result != NULL ? rc == VM_OK : rc != VM_OK);
    if (result != NULL) {
        *result = vm_get_result(&vm);
    }
}

static void test_arithmetic(void)
{
    const uint8_t code[] = {
        0x41, 0x0A, 0x00, 0x00, 0x00,
        0x41, 0x14, 0x00, 0x00, 0x00,
        0x6A,
        0x41, 0x02, 0x00, 0x00, 0x00,
        0x6C,
        0x06
    };
    int result = 0;
    run_module(code, sizeof(code), &result);
    assert(result == 60);
}

static void test_conditional(void)
{
    const uint8_t code[] = {
        0x41, 0x0A, 0x00, 0x00, 0x00,
        0x41, 0x05, 0x00, 0x00, 0x00,
        0x4A,
        0x05, 0x00, 0x00, 0x00, 0x02,
        0x41, 0x01, 0x00, 0x00, 0x00,
        0x04, 0x00, 0x00, 0x00, 0x01,
        0x41, 0x00, 0x00, 0x00, 0x00,
        0x06
    };
    int result = 0;
    run_module(code, sizeof(code), &result);
    assert(result == 1);
}

static void test_divide_by_zero(void)
{
    const uint8_t code[] = {
        0x41, 0x0A, 0x00, 0x00, 0x00,
        0x41, 0x00, 0x00, 0x00, 0x00,
        0x6D,
        0x06
    };
    install_code(code, sizeof(code));
    static VM vm;
    assert(vm_init(&vm, &module, 256) == 0);
    assert(vm_run(&vm) == VM_ERR_DIV_BY_ZERO);
}

int main(void)
{
    test_arithmetic();
    test_conditional();
    test_divide_by_zero();
    puts("minimal VM tests passed");
    return 0;
}
