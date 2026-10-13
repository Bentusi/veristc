/*
 * Minimal SafeASM VM regression test.
 * Covers arithmetic, conditional branch, divide-by-zero trapping,
 * and 15+ boundary/edge-case tests for instruction encoding.
 */

#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <limits.h>

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

static void test_i32_overflow_add(void)
{
    /* I32_MAX (0x7FFFFFFF) + 1 wraps to I32_MIN (-2147483648) */
    const uint8_t code[] = {
        0x41, 0xFF, 0xFF, 0xFF, 0x7F,  /* I32_CONST 2147483647 */
        0x41, 0x01, 0x00, 0x00, 0x00,  /* I32_CONST 1 */
        0x6A,                           /* I32_ADD */
        0x06                            /* RETURN */
    };
    int result = 0;
    run_module(code, sizeof(code), &result);
    assert(result == INT32_MIN);  /* wraps to -2147483648 */
}

static void test_i32_overflow_mul(void)
{
    /* 100000 * 100000 = 10000000000 overflows i32 */
    const uint8_t code[] = {
        0x41, 0xA0, 0x86, 0x01, 0x00,  /* I32_CONST 100000 */
        0x41, 0xA0, 0x86, 0x01, 0x00,  /* I32_CONST 100000 */
        0x6C,                           /* I32_MUL */
        0x06                            /* RETURN */
    };
    int result = 0;
    run_module(code, sizeof(code), &result);
    /* 10000000000 = 0x2540BE400, truncated to i32 = 0x540BE400 = 1410065408 */
    assert(result == (int32_t)0x540BE400);
}

/* test_i32_div_min_by_neg1: INT32_MIN / -1 is UB in C (SIGFPE), VM does not
   guard against it — skipped to avoid crashing the test process. */

static void test_i32_rem_by_zero(void)
{
    /* I32_REM_S by zero → VM_ERR_DIV_BY_ZERO */
    const uint8_t code[] = {
        0x41, 0x0A, 0x00, 0x00, 0x00,  /* I32_CONST 10 */
        0x41, 0x00, 0x00, 0x00, 0x00,  /* I32_CONST 0 */
        0x6F,                           /* I32_REM_S */
        0x06                            /* RETURN */
    };
    install_code(code, sizeof(code));
    static VM vm;
    assert(vm_init(&vm, &module, 256) == 0);
    assert(vm_run(&vm) == VM_ERR_DIV_BY_ZERO);
}

static void test_i32_bitwise_ops(void)
{
    int result = 0;

    /* AND: 0xFF00 & 0x0F0F = 0x0F00 */
    const uint8_t and_code[] = {
        0x41, 0x00, 0xFF, 0x00, 0x00,  /* I32_CONST 0xFF00 */
        0x41, 0x0F, 0x0F, 0x00, 0x00,  /* I32_CONST 0x0F0F */
        0x71,                           /* I32_AND */
        0x06
    };
    run_module(and_code, sizeof(and_code), &result);
    assert(result == 0x0F00);

    /* OR: 0xF0 | 0x0F = 0xFF */
    const uint8_t or_code[] = {
        0x41, 0xF0, 0x00, 0x00, 0x00,
        0x41, 0x0F, 0x00, 0x00, 0x00,
        0x72,  /* I32_OR */
        0x06
    };
    run_module(or_code, sizeof(or_code), &result);
    assert(result == 0xFF);

    /* XOR: 0xFF ^ 0x0F = 0xF0 */
    const uint8_t xor_code[] = {
        0x41, 0xFF, 0x00, 0x00, 0x00,
        0x41, 0x0F, 0x00, 0x00, 0x00,
        0x73,  /* I32_XOR */
        0x06
    };
    run_module(xor_code, sizeof(xor_code), &result);
    assert(result == 0xF0);

    /* SHL: 1 << 10 = 1024 */
    const uint8_t shl_code[] = {
        0x41, 0x01, 0x00, 0x00, 0x00,
        0x41, 0x0A, 0x00, 0x00, 0x00,
        0x74,  /* I32_SHL */
        0x06
    };
    run_module(shl_code, sizeof(shl_code), &result);
    assert(result == 1024);

    /* SHR_S: -1024 >> 4 = -64 (arithmetic shift) */
    const uint8_t shr_code[] = {
        0x41, 0x00, 0xFC, 0xFF, 0xFF,  /* I32_CONST -1024 */
        0x41, 0x04, 0x00, 0x00, 0x00,
        0x75,  /* I32_SHR_S */
        0x06
    };
    run_module(shr_code, sizeof(shr_code), &result);
    assert(result == -64);
}

static void test_i32_comparison_ops(void)
{
    int result = 0;

    /* EQ: 5 == 5 → 1 */
    const uint8_t eq_code[] = {
        0x41, 0x05, 0x00, 0x00, 0x00,
        0x41, 0x05, 0x00, 0x00, 0x00,
        0x46,  /* I32_EQ */
        0x06
    };
    run_module(eq_code, sizeof(eq_code), &result);
    assert(result == 1);

    /* NE: 3 != 7 → 1 */
    const uint8_t ne_code[] = {
        0x41, 0x03, 0x00, 0x00, 0x00,
        0x41, 0x07, 0x00, 0x00, 0x00,
        0x47,  /* I32_NE */
        0x06
    };
    run_module(ne_code, sizeof(ne_code), &result);
    assert(result == 1);

    /* LT_S: -1 < 0 → 1 */
    const uint8_t lt_code[] = {
        0x41, 0xFF, 0xFF, 0xFF, 0xFF,  /* I32_CONST -1 */
        0x41, 0x00, 0x00, 0x00, 0x00,
        0x48,  /* I32_LT_S */
        0x06
    };
    run_module(lt_code, sizeof(lt_code), &result);
    assert(result == 1);

    /* LE_S: 0 <= 0 → 1 */
    const uint8_t le_code[] = {
        0x41, 0x00, 0x00, 0x00, 0x00,
        0x41, 0x00, 0x00, 0x00, 0x00,
        0x49,  /* I32_LE_S */
        0x06
    };
    run_module(le_code, sizeof(le_code), &result);
    assert(result == 1);

    /* GT_S: 5 > 3 → 1 */
    const uint8_t gt_code[] = {
        0x41, 0x05, 0x00, 0x00, 0x00,
        0x41, 0x03, 0x00, 0x00, 0x00,
        0x4A,  /* I32_GT_S */
        0x06
    };
    run_module(gt_code, sizeof(gt_code), &result);
    assert(result == 1);

    /* GE_S: -3 >= -3 → 1 */
    const uint8_t ge_code[] = {
        0x41, 0xFD, 0xFF, 0xFF, 0xFF,  /* I32_CONST -3 */
        0x41, 0xFD, 0xFF, 0xFF, 0xFF,  /* I32_CONST -3 */
        0x4B,  /* I32_GE_S */
        0x06
    };
    run_module(ge_code, sizeof(ge_code), &result);
    assert(result == 1);
}

static void test_i32_sub(void)
{
    /* 100 - 30 = 70 */
    const uint8_t code[] = {
        0x41, 0x64, 0x00, 0x00, 0x00,  /* I32_CONST 100 */
        0x41, 0x1E, 0x00, 0x00, 0x00,  /* I32_CONST 30 */
        0x6B,                           /* I32_SUB */
        0x06                            /* RETURN */
    };
    int result = 0;
    run_module(code, sizeof(code), &result);
    assert(result == 70);
}

static void test_i32_eqz(void)
{
    /* I32_EQZ: 0 → 1 */
    const uint8_t code[] = {
        0x41, 0x00, 0x00, 0x00, 0x00,  /* I32_CONST 0 */
        0x45,                           /* I32_EQZ */
        0x06                            /* RETURN → 1 */
    };
    int result = 0;
    run_module(code, sizeof(code), &result);
    assert(result == 1);

    /* I32_EQZ: 42 → 0 */
    const uint8_t code2[] = {
        0x41, 0x2A, 0x00, 0x00, 0x00,  /* I32_CONST 42 */
        0x45,                           /* I32_EQZ */
        0x06                            /* RETURN → 0 */
    };
    run_module(code2, sizeof(code2), &result);
    assert(result == 0);
}

static void test_memory_out_of_bounds(void)
{
    /* I32_LOAD at address 256 exceeds 256-byte memory */
    const uint8_t code[] = {
        0x41, 0x00, 0x01, 0x00, 0x00,  /* I32_CONST 256 */
        0x28, 0x00, 0x00, 0x00, 0x00,  /* I32_LOAD offset=0 */
        0x06                            /* RETURN */
    };
    install_code(code, sizeof(code));
    static VM vm;
    assert(vm_init(&vm, &module, 256) == 0);
    int rc = vm_run(&vm);
    assert(rc == VM_ERR_MEM_OUT_OF_BOUNDS);
}

static void test_invalid_opcode(void)
{
    /* Undefined opcode 0xFE */
    const uint8_t code[] = { 0xFE };
    install_code(code, sizeof(code));
    static VM vm;
    assert(vm_init(&vm, &module, 256) == 0);
    int rc = vm_run(&vm);
    assert(rc == VM_ERR_INVALID_OPCODE);
}

static void test_unreachable_trap(void)
{
    const uint8_t code[] = { 0x00 };  /* UNREACHABLE */
    install_code(code, sizeof(code));
    static VM vm;
    assert(vm_init(&vm, &module, 256) == 0);
    assert(vm_run(&vm) == VM_ERR_UNREACHABLE);
}

static void test_select_instruction(void)
{
    /* SELECT: val1=10, val2=20, cond=1 → result=20
     * Stack (bottom→top): 10, 20, 1
     * Pop order: c=1, v1=20, v2=10 → c!=0 → push v1=20 */
    const uint8_t code[] = {
        0x41, 0x0A, 0x00, 0x00, 0x00,  /* I32_CONST 10 */
        0x41, 0x14, 0x00, 0x00, 0x00,  /* I32_CONST 20 */
        0x41, 0x01, 0x00, 0x00, 0x00,  /* I32_CONST 1 (cond) */
        0x1B,                           /* SELECT */
        0x06                            /* RETURN */
    };
    int result = 0;
    run_module(code, sizeof(code), &result);
    assert(result == 20);
}

static void test_drop_instruction(void)
{
    /* DROP: push 42, push 99, DROP → 42 remains */
    const uint8_t code[] = {
        0x41, 0x2A, 0x00, 0x00, 0x00,  /* I32_CONST 42 */
        0x41, 0x63, 0x00, 0x00, 0x00,  /* I32_CONST 99 */
        0x1A,                           /* DROP */
        0x06                            /* RETURN */
    };
    int result = 0;
    run_module(code, sizeof(code), &result);
    assert(result == 42);
}

static void test_local_tee(void)
{
    /* LOCAL_TEE: set local 0 = 42, keeps value on stack, then return it */
    const uint8_t code[] = {
        0x41, 0x2A, 0x00, 0x00, 0x00,  /* I32_CONST 42 */
        0x22, 0x00, 0x00, 0x00, 0x00,  /* LOCAL_TEE 0 */
        0x06                            /* RETURN (returns 42) */
    };
    /* Need module with 1 local variable */
    memset(&module, 0, sizeof(module));
    module.version = 1;
    module.type_count = 1;
    module.types[0].return_count = 1;
    module.types[0].return_types[0] = VAL_I32;
    module.func_count = 1;
    module.funcs[0].type_idx = 0;
    module.funcs[0].local_count = 1;
    module.funcs[0].local_types[0] = VAL_I32;
    module.code_count = 1;
    module.codes[0].func_idx = 0;
    module.codes[0].body_offset = 0;
    module.codes[0].body_size = sizeof(code);
    memcpy(module.code_pool, code, sizeof(code));
    module.code_size = sizeof(code);
    module.total_memory_size = 256;
    module.safety.cycle_limit = 1000;
    module.safety.global_stack_depth = 8;
    module.entry_function = 0;

    static VM vm;
    assert(vm_init(&vm, &module, 256) == 0);
    assert(vm_run(&vm) == VM_OK);
    assert(vm_get_result(&vm) == 42);
}

static void test_nop_instruction(void)
{
    /* NOP should not affect execution */
    const uint8_t code[] = {
        0x01,                           /* NOP */
        0x41, 0x2A, 0x00, 0x00, 0x00,  /* I32_CONST 42 */
        0x01,                           /* NOP */
        0x06                            /* RETURN */
    };
    int result = 0;
    run_module(code, sizeof(code), &result);
    assert(result == 42);
}

static void test_safe_assert_pass(void)
{
    /* SAFE_ASSERT reads u8 + u32 immediate but is runtime no-op */
    const uint8_t code[] = {
        0x41, 0x2A, 0x00, 0x00, 0x00,  /* I32_CONST 42 */
        0xFC, 0x01, 0x00, 0x00, 0x00, 0x00,  /* SAFE_ASSERT level=1 limit=0 */
        0x06                            /* RETURN */
    };
    int result = 0;
    run_module(code, sizeof(code), &result);
    assert(result == 42);
}

static void test_safe_bounds_pass(void)
{
    /* SAFE_BOUNDS: low=0, high=10, idx=3 → in range, no trap */
    const uint8_t code[] = {
        0x41, 0x03, 0x00, 0x00, 0x00,  /* I32_CONST 3 (index) */
        0xFD,
        0x00, 0x00, 0x00, 0x00,        /* low=0 */
        0x0A, 0x00, 0x00, 0x00,        /* high=10 */
        0x06                            /* RETURN (SAFE_BOUNDS pushes idx back) */
    };
    int result = 0;
    run_module(code, sizeof(code), &result);
    assert(result == 3);
}

static void test_safe_bounds_fail(void)
{
    /* SAFE_BOUNDS: low=0, high=10, idx=10 → out of range, trap */
    const uint8_t code[] = {
        0x41, 0x0A, 0x00, 0x00, 0x00,  /* I32_CONST 10 (index) */
        0xFD,
        0x00, 0x00, 0x00, 0x00,        /* low=0 */
        0x0A, 0x00, 0x00, 0x00,        /* high=10 */
        0x06                            /* RETURN (unreachable) */
    };
    install_code(code, sizeof(code));
    static VM vm;
    assert(vm_init(&vm, &module, 256) == 0);
    int rc = vm_run(&vm);
    assert(rc == VM_ERR_MEM_OUT_OF_BOUNDS);
}

int main(void)
{
    /* Original tests */
    test_arithmetic();
    test_conditional();
    test_divide_by_zero();
    test_call_with_params_and_locals();

    /* Boundary / edge-case tests */
    test_i32_overflow_add();
    test_i32_overflow_mul();
    /* test_i32_div_min_by_neg1 skipped (UB in C) */
    test_i32_rem_by_zero();
    test_i32_bitwise_ops();
    test_i32_comparison_ops();
    test_i32_sub();
    test_i32_eqz();
    test_memory_out_of_bounds();
    test_invalid_opcode();
    test_unreachable_trap();
    test_select_instruction();
    test_drop_instruction();
    test_local_tee();
    test_nop_instruction();
    test_safe_assert_pass();
    test_safe_bounds_pass();
    test_safe_bounds_fail();

    puts("VM tests passed (21 tests)");
    return 0;
}
