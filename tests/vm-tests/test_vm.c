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

static void test_call_with_params_and_locals(void)
{
    const uint8_t entry_code[] = {
        0x41, 0x05, 0x00, 0x00, 0x00, /* I32_CONST 5 */
        0x41, 0x07, 0x00, 0x00, 0x00, /* I32_CONST 7 */
        0x10, 0x01, 0x00, 0x00, 0x00, /* CALL 1 */
        0x06                          /* RETURN */
    };
    const uint8_t add_code[] = {
        0x20, 0x00, 0x00, 0x00, 0x00, /* LOCAL_GET 0 */
        0x20, 0x01, 0x00, 0x00, 0x00, /* LOCAL_GET 1 */
        0x6A,                         /* I32_ADD */
        0x06                          /* RETURN */
    };

    memset(&module, 0, sizeof(module));
    module.version = 1;

    module.type_count = 2;
    module.types[0].param_count = 0;
    module.types[0].return_count = 1;
    module.types[0].return_types[0] = VAL_I32;
    module.types[1].param_count = 2;
    module.types[1].param_types[0] = VAL_I32;
    module.types[1].param_types[1] = VAL_I32;
    module.types[1].return_count = 1;
    module.types[1].return_types[0] = VAL_I32;

    module.func_count = 2;
    module.funcs[0].type_idx = 0;
    module.funcs[0].local_count = 0;
    module.funcs[1].type_idx = 1;
    module.funcs[1].local_count = 2;
    module.funcs[1].local_types[0] = VAL_I32;
    module.funcs[1].local_types[1] = VAL_I32;

    module.code_count = 2;
    module.codes[0].func_idx = 0;
    module.codes[0].body_offset = 0;
    module.codes[0].body_size = sizeof(entry_code);
    memcpy(&module.code_pool[0], entry_code, sizeof(entry_code));
    module.codes[1].func_idx = 1;
    module.codes[1].body_offset = sizeof(entry_code);
    module.codes[1].body_size = sizeof(add_code);
    memcpy(&module.code_pool[sizeof(entry_code)], add_code, sizeof(add_code));
    module.code_size = sizeof(entry_code) + sizeof(add_code);

    module.total_memory_size = 256;
    module.safety.cycle_limit = 1000;
    module.safety.global_stack_depth = 8;
    module.entry_function = 0;

    static VM vm;
    assert(vm_init(&vm, &module, 256) == 0);
    assert(vm_run(&vm) == VM_OK);
    assert(vm_get_result(&vm) == 12);
}

int main(void)
{
    test_arithmetic();
    test_conditional();
    test_divide_by_zero();
    test_call_with_params_and_locals();
    puts("minimal VM tests passed");
    return 0;
}
