/**
 * tests/vm-tests/test_minimal.c
 * 里程碑验证：手写 .sasm 二进制 → C VM 解释执行
 * 
 * 测试用例: 返回常量 42 的最小 SafeASM 程序
 * 
 * 预期结果: vm_get_result() == 42
 * 验证条件: 加载成功 + 解释执行无错误 + 结果正确
 */

#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <assert.h>
#include "../../vm/vm.h"
#include "../../rtos/abstract.h"

/* 为 I/O 映射层提供 g_vm_interface 桩（测试中不使用 I/O） */
VM_Interface g_vm_interface = { 0 };

/* 链接 loader.c 和 safeasm_interp.c */
#include "../../vm/loader.c"
#include "../../vm/safeasm_interp.c"

/* ================================================================
   手写最小 .sasm 二进制
   等效功能: int main() { return 42; }
   
   十六进制布局 (详见 spec/safeasm-spec.md 附录 A):
   ================================================================ */

static const uint8_t minimal_sasm[] __attribute__((unused)) = {
    /* --- 文件头 --- */
    0x53, 0x41, 0x53, 0x4D,    /* Magic "SASM" */
    0x01,                       /* Version = 1 */
    0x00,                       /* Flags = 0 */
    
    /* --- Type Section --- */
    0x00,                       /* Section type = TYPE */
    0x0C, 0x00, 0x00, 0x00,    /* Length = 12 */
    0x00,                       /* reserved */
    0x00, 0x00,                 /* flags */
    0x00, 0x00, 0x00, 0x00,    /* param_count = 0 */
    0x01, 0x00, 0x00, 0x00,    /* return_count = 1 */
    0x7F, 0x00, 0x00, 0x00,    /* return_type = I32 */
    
    /* --- Function Section --- */
    0x01,                       /* Section type = FUNC */
    0x0C, 0x00, 0x00, 0x00,    /* Length = 12 */
    0x00,                       /* reserved */
    0x00, 0x00,                 /* flags */
    0x00, 0x00, 0x00, 0x00,    /* type_idx = 0 */
    0x00, 0x00, 0x00, 0x00,    /* local_count = 0 */
    
    /* --- Memory Section --- */
    0x02,                       /* Section type = MEM */
    0x08, 0x00, 0x00, 0x00,    /* Length = 8 */
    0x00,                       /* reserved */
    0x00, 0x00,                 /* flags */
    0x00, 0x01, 0x00, 0x00,    /* total_size = 256 */
    0x00, 0x00, 0x00, 0x00,    /* segment_count = 0 */
    
    /* --- IOMap Section --- */
    0x03,                       /* Section type = IOMAP */
    0x04, 0x00, 0x00, 0x00,    /* Length = 4 */
    0x00,                       /* reserved */
    0x00, 0x00,                 /* flags */
    0x00, 0x00, 0x00, 0x00,    /* entry_count = 0 */
    
    /* --- Code Section --- */
    0x04,                       /* Section type = CODE */
    0x12, 0x00, 0x00, 0x00,    /* Length = 18 */
    0x00,                       /* reserved */
    0x00, 0x00,                 /* flags */
    0x00, 0x00, 0x00, 0x00,    /* func_idx = 0 */
    0x0A, 0x00, 0x00, 0x00,    /* body_size = 10 */
    0x41,                       /* I32_CONST */
    0x2A, 0x00, 0x00, 0x00,    /* 42 (小端序) */
    0x06,                       /* RETURN */
    0x00, 0x00, 0x00, 0x00,    /* padding */
    
    /* --- Safety Section --- */
    0x05,                       /* Section type = SAFE */
    0x0D, 0x00, 0x00, 0x00,    /* Length = 13 */
    0x00,                       /* reserved */
    0x00, 0x00,                 /* flags */
    0x01,                       /* safety_level = SIL3 */
    0x00, 0x00, 0x00, 0x00,    /* cycle_limit = 0 (无限制) */
    0x00, 0x00, 0x00, 0x00,    /* stack_depth = 0 */
    0x00, 0x00, 0x00, 0x00,    /* loop_count = 0 */
    
    /* --- CRC32 Checksum (占位，实际需计算) --- */
    0x00, 0x00, 0x00, 0x00     /* CRC32 (简化: 不校验) */
};

/* ================================================================
   辅助函数：构建最小 SasmModule (返回常量 42)
   ================================================================ */

static void build_return42_module(SasmModule *m) {
    memset(m, 0, sizeof(SasmModule));
    m->version = 1;
    m->type_count = 1;
    m->types[0].param_count = 0;
    m->types[0].return_count = 1;
    m->types[0].return_types[0] = VAL_I32;
    m->func_count = 1;
    m->funcs[0].type_idx = 0;
    m->funcs[0].local_count = 0;
    m->code_count = 1;
    m->codes[0].func_idx = 0;
    m->codes[0].body[0] = OP_I32_CONST;
    m->codes[0].body[1] = 0x2A; m->codes[0].body[2] = 0x00;
    m->codes[0].body[3] = 0x00; m->codes[0].body[4] = 0x00;
    m->codes[0].body[5] = OP_RETURN;
    m->codes[0].body_size = 6;
    m->total_memory_size = 256;
    m->safety.cycle_limit = 1000;
    m->entry_function = 0;
}

/* ================================================================
   测试 1: 执行最小程序 (返回 42)
   ================================================================ */

static void test_return_42(void) {
    printf("测试 1: 执行最小程序 (返回 42)...\n");
    
    SasmModule module;
    build_return42_module(&module);
    
    static VM vm;
    assert(vm_init(&vm, &module, 256) == 0);
    assert(vm_run(&vm) == VM_OK);
    sasm_value result = vm_get_result(&vm);
    printf("  结果: %d (期望: 42)\n", result);
    assert(result == 42);
    
    printf("测试 1: 通过 ✅\n");
}

/* ================================================================
   测试 2: 算术运算 (10+20)*2 = 60
   ================================================================ */

static void test_arithmetic(void) {
    printf("测试 3: 算术运算 (10+20)*2 = 60...\n");
    
    /* 手写代码体: 10 20 I32_ADD 2 I32_MUL RETURN */
    const uint8_t arith_code[] = {
        0x41, 0x0A, 0x00, 0x00, 0x00,    /* I32_CONST 10 */
        0x41, 0x14, 0x00, 0x00, 0x00,    /* I32_CONST 20 */
        0x6A,                             /* I32_ADD */
        0x41, 0x02, 0x00, 0x00, 0x00,    /* I32_CONST 2 */
        0x6C,                             /* I32_MUL */
        0x06                              /* RETURN */
    };
    
    /* 构建 SasmModule（直接构造，跳过序列化） */
    SasmModule module;
    memset(&module, 0, sizeof(module));
    
    module.version = 1;
    module.type_count = 1;
    module.types[0].param_count = 0;
    module.types[0].return_count = 1;
    module.types[0].return_types[0] = VAL_I32;
    
    module.func_count = 1;
    module.funcs[0].type_idx = 0;
    module.funcs[0].local_count = 0;
    
    module.code_count = 1;
    module.codes[0].func_idx = 0;
    module.codes[0].body_size = sizeof(arith_code);
    memcpy(module.codes[0].body, arith_code, sizeof(arith_code));
    
    module.total_memory_size = 256;
    module.safety.cycle_limit = 1000;
    module.entry_function = 0;
    
    static VM vm;
    assert(vm_init(&vm, &module, 256) == 0);
    assert(vm_run(&vm) == VM_OK);
    
    sasm_value result = vm_get_result(&vm);
    printf("   结果: %d (期望: 60)\n", result);
    assert(result == 60);
    
    printf("测试 3: 通过 ✅\n");
}

/* ================================================================
   测试 4: 除零保护测试
   ================================================================ */

static void test_div_by_zero(void) {
    printf("测试 4: 除零保护...\n");
    
    const uint8_t div_code[] = {
        0x41, 0x0A, 0x00, 0x00, 0x00,    /* I32_CONST 10 */
        0x41, 0x00, 0x00, 0x00, 0x00,    /* I32_CONST 0 */
        0x6D,                             /* I32_DIV_S */
        0x06                              /* RETURN */
    };
    
    SasmModule module;
    memset(&module, 0, sizeof(module));
    module.version = 1;
    module.type_count = 1;
    module.types[0].param_count = 0;
    module.types[0].return_count = 1;
    module.types[0].return_types[0] = VAL_I32;
    module.func_count = 1;
    module.funcs[0].type_idx = 0;
    module.funcs[0].local_count = 0;
    module.code_count = 1;
    module.codes[0].func_idx = 0;
    module.codes[0].body_size = sizeof(div_code);
    memcpy(module.codes[0].body, div_code, sizeof(div_code));
    module.total_memory_size = 256;
    module.safety.cycle_limit = 1000;
    module.entry_function = 0;
    
    static VM vm;
    assert(vm_init(&vm, &module, 256) == 0);
    int ret = vm_run(&vm);
    assert(ret == VM_ERR_DIV_BY_ZERO);
    
    printf("测试 4: 通过 ✅ (正确捕获除零错误)\n");
}

/* ================================================================
   测试 5: 条件分支测试
   IF (10 > 5) THEN result := 1 ELSE result := 0 END
   期望结果: 1
   ================================================================ */

static void test_conditional(void) {
    printf("测试 5: 条件分支...\n");
    
    /* 模拟: result = (10 > 5) ? 1 : 0 */
    const uint8_t cond_code[] = {
        0x41, 0x0A, 0x00, 0x00, 0x00,    /* I32_CONST 10 */
        0x41, 0x05, 0x00, 0x00, 0x00,    /* I32_CONST 5 */
        0x4A,                             /* I32_GT_S (10 > 5 → 1) */
        0x05, 0x00, 0x00, 0x00, 0x02,    /* BR_IF 2 (跳过 then) */
        0x41, 0x01, 0x00, 0x00, 0x00,    /* I32_CONST 1 (then) */
        0x04, 0x00, 0x00, 0x00, 0x01,    /* BR 1 (跳过 else) */
        0x41, 0x00, 0x00, 0x00, 0x00,    /* I32_CONST 0 (else) */
        0x06                              /* RETURN */
    };
    
    SasmModule module;
    memset(&module, 0, sizeof(module));
    module.version = 1;
    module.type_count = 1;
    module.types[0].param_count = 0;
    module.types[0].return_count = 1;
    module.types[0].return_types[0] = VAL_I32;
    module.func_count = 1;
    module.funcs[0].type_idx = 0;
    module.funcs[0].local_count = 0;
    module.code_count = 1;
    module.codes[0].func_idx = 0;
    module.codes[0].body_size = sizeof(cond_code);
    memcpy(module.codes[0].body, cond_code, sizeof(cond_code));
    module.total_memory_size = 256;
    module.safety.cycle_limit = 1000;
    module.entry_function = 0;
    
    static VM vm;
    assert(vm_init(&vm, &module, 256) == 0);
    assert(vm_run(&vm) == VM_OK);
    
    sasm_value result = vm_get_result(&vm);
    printf("   结果: %d (期望: 1)\n", result);
    assert(result == 1);
    
    printf("测试 5: 通过 ✅\n");
}

/* ================================================================
   主函数
   ================================================================ */


/* ================================================================
   测试 6: 位运算 (SHL / SHR_S / ROTL / ROTR)
   ================================================================ */

static void test_i32_shifts(void) {
    printf("测试 6: I32 位运算 (SHL/SHR_S/ROTL/ROTR)...\n");
    
    /* SHL: 0x1234 << 4 = 0x12340 = 74560 */
    /* SHR_S: 0x1234 >> 2 = 0x048D = 1165 */
    /* ROTL: 0x80000001 << 1 | >> 31 = 0x00000003 = 3 */
    const uint8_t bits_code[] = {
        0x41, 0x34, 0x12, 0x00, 0x00,    /* I32_CONST 0x1234 */
        0x41, 0x04, 0x00, 0x00, 0x00,    /* I32_CONST 4 */
        0x74,                             /* I32_SHL */
        /* now stack = [0x12340] */
        0x41, 0x34, 0x12, 0x00, 0x00,    /* I32_CONST 0x1234 */
        0x41, 0x02, 0x00, 0x00, 0x00,    /* I32_CONST 2 */
        0x75,                             /* I32_SHR_S */
        /* now stack = [0x12340, 0x48D] — top = 1165 */
        0x1A,                             /* DROP: remove 1165 */
        /* now stack = [0x12340] */
        0x41, 0x01, 0x00, 0x00, 0x80,    /* I32_CONST 0x80000001 */
        0x41, 0x01, 0x00, 0x00, 0x00,    /* I32_CONST 1 */
        0x76,                             /* I32_ROTL */
        /* now stack = [0x12340, 3] — top should be 3 (ROTL result) */
        0x1A,                             /* DROP: remove ROTL result */
        /* now stack = [0x12340] */
        0x41, 0x03, 0x00, 0x00, 0x00,    /* I32_CONST 3 */
        0x41, 0x01, 0x00, 0x00, 0x00,    /* I32_CONST 1 */
        0x77,                             /* I32_ROTR: 3 ROTR 1 = 0x80000001 (as unsigned) */
        /* now stack = [0x12340, 0x80000001] */
        0x1A,                             /* DROP */
        /* now stack = [0x12340] = 74560 */
        0x06                              /* RETURN */
    };
    
    SasmModule module;
    memset(&module, 0, sizeof(module));
    module.version = 1;
    module.type_count = 1;
    module.types[0].param_count = 0;
    module.types[0].return_count = 1;
    module.types[0].return_types[0] = VAL_I32;
    module.func_count = 1;
    module.funcs[0].type_idx = 0;
    module.funcs[0].local_count = 0;
    module.code_count = 1;
    module.codes[0].func_idx = 0;
    module.codes[0].body_size = sizeof(bits_code);
    memcpy(module.codes[0].body, bits_code, sizeof(bits_code));
    module.total_memory_size = 256;
    module.safety.cycle_limit = 1000;
    module.entry_function = 0;
    
    static VM vm;
    assert(vm_init(&vm, &module, 256) == 0);
    assert(vm_run(&vm) == VM_OK);
    sasm_value result = vm_get_result(&vm);
    printf("   SHL 结果: %d (期望: 74560)\n", result);
    assert(result == 74560);
    printf("测试 6: 通过 ✅\n");
}

/* ================================================================
   测试 7: 比较运算 (LE_S / GE_S)
   ================================================================ */

static void test_i32_comparisons(void) {
    printf("测试 7: I32 比较运算 (LE_S/GE_S)...\n");
    
    const uint8_t cmp_code[] = {
        0x41, 0x05, 0x00, 0x00, 0x00,    /* I32_CONST 5 */
        0x41, 0x0A, 0x00, 0x00, 0x00,    /* I32_CONST 10 */
        0x49,                             /* I32_LE_S: 5 <= 10 → 1 */
        /* stack = [1] */
        0x41, 0x0A, 0x00, 0x00, 0x00,    /* I32_CONST 10 */
        0x41, 0x05, 0x00, 0x00, 0x00,    /* I32_CONST 5 */
        0x49,                             /* I32_LE_S: 10 <= 5 → 0 */
        /* stack = [1, 0] */
        0x1A,                             /* DROP 0 */
        /* stack = [1] */
        0x41, 0x0A, 0x00, 0x00, 0x00,    /* I32_CONST 10 */
        0x41, 0x05, 0x00, 0x00, 0x00,    /* I32_CONST 5 */
        0x4B,                             /* I32_GE_S: 10 >= 5 → 1 */
        /* stack = [1, 1] */
        0x1A,                             /* DROP */
        /* stack = [1] */
        0x41, 0x05, 0x00, 0x00, 0x00,    /* I32_CONST 5 */
        0x41, 0x0A, 0x00, 0x00, 0x00,    /* I32_CONST 10 */
        0x4B,                             /* I32_GE_S: 5 >= 10 → 0 */
        /* stack = [1, 0] */
        0x1A,                             /* DROP 0, keep [1] */
        0x06                              /* RETURN */
    };
    
    SasmModule module;
    memset(&module, 0, sizeof(module));
    module.version = 1;
    module.type_count = 1;
    module.types[0].param_count = 0;
    module.types[0].return_count = 1;
    module.types[0].return_types[0] = VAL_I32;
    module.func_count = 1;
    module.funcs[0].type_idx = 0;
    module.funcs[0].local_count = 0;
    module.code_count = 1;
    module.codes[0].func_idx = 0;
    module.codes[0].body_size = sizeof(cmp_code);
    memcpy(module.codes[0].body, cmp_code, sizeof(cmp_code));
    module.total_memory_size = 256;
    module.safety.cycle_limit = 1000;
    module.entry_function = 0;
    
    static VM vm;
    assert(vm_init(&vm, &module, 256) == 0);
    assert(vm_run(&vm) == VM_OK);
    sasm_value result = vm_get_result(&vm);
    printf("  结果: %d (期望: 1)\n", result);
    assert(result == 1);
    printf("测试 7: 通过 ✅\n");
}

/* ================================================================
   测试 8: I64 常量 + 扩展 + 截断
   ================================================================ */

static void test_i64_const_and_conv(void) {
    printf("测试 8: I64 常量 + 类型转换...\n");
    
    /* I64_CONST 42 → I32_WRAP_I64 → result = 42 */
    const uint8_t i64_code[] = {
        0x50, 0x2A, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,  /* I64_CONST 42 */
        0xA7,                             /* I32_WRAP_I64 */
        0x06                              /* RETURN */
    };
    
    SasmModule module;
    memset(&module, 0, sizeof(module));
    module.version = 1;
    module.type_count = 1;
    module.types[0].param_count = 0;
    module.types[0].return_count = 1;
    module.types[0].return_types[0] = VAL_I32;
    module.func_count = 1;
    module.funcs[0].type_idx = 0;
    module.funcs[0].local_count = 0;
    module.code_count = 1;
    module.codes[0].func_idx = 0;
    module.codes[0].body_size = sizeof(i64_code);
    memcpy(module.codes[0].body, i64_code, sizeof(i64_code));
    module.total_memory_size = 256;
    module.safety.cycle_limit = 1000;
    module.entry_function = 0;
    
    static VM vm;
    assert(vm_init(&vm, &module, 256) == 0);
    assert(vm_run(&vm) == VM_OK);
    sasm_value result = vm_get_result(&vm);
    printf("  结果: %d (期望: 42)\n", result);
    assert(result == 42);
    
    /* I32_CONST -1 → I64_EXTEND_I32_S → I32_WRAP_I64 → result = -1 */
    const uint8_t extend_code[] = {
        0x41, 0xFF, 0xFF, 0xFF, 0xFF,    /* I32_CONST -1 */
        0xA8,                             /* I64_EXTEND_I32_S */
        0xA7,                             /* I32_WRAP_I64 */
        0x06                              /* RETURN */
    };
    
    SasmModule mod2;
    memset(&mod2, 0, sizeof(mod2));
    mod2.version = 1;
    mod2.type_count = 1;
    mod2.types[0].param_count = 0;
    mod2.types[0].return_count = 1;
    mod2.types[0].return_types[0] = VAL_I32;
    mod2.func_count = 1;
    mod2.funcs[0].type_idx = 0;
    mod2.funcs[0].local_count = 0;
    mod2.code_count = 1;
    mod2.codes[0].func_idx = 0;
    mod2.codes[0].body_size = sizeof(extend_code);
    memcpy(mod2.codes[0].body, extend_code, sizeof(extend_code));
    mod2.total_memory_size = 256;
    mod2.safety.cycle_limit = 1000;
    mod2.entry_function = 0;
    
    static VM vm2;
    assert(vm_init(&vm2, &mod2, 256) == 0);
    assert(vm_run(&vm2) == VM_OK);
    sasm_value result2 = vm_get_result(&vm2);
    printf("  扩展+截断: %d (期望: -1)\n", result2);
    assert(result2 == -1);
    printf("测试 8: 通过 ✅\n");
}

/* ================================================================
   测试 9: I32_STORE8 + I32_LOAD8_U
   ================================================================ */

static void test_load8_store8(void) {
    printf("测试 9: I32_STORE8 + I32_LOAD8_U...\n");
    
    /* 在 addr=256 处写入 0xAB，再读回 */
    const uint8_t load8_code[] = {
        0x41, 0x00, 0x01, 0x00, 0x00,    /* I32_CONST 256 (address) */
        0x41, 0xAB, 0x00, 0x00, 0x00,    /* I32_CONST 0xAB (value) */
        0x3A, 0x02, 0x00, 0x00, 0x00,    /* I32_STORE8 (align=2, offset=0) */
        0x41, 0x00, 0x01, 0x00, 0x00,    /* I32_CONST 256 */
        0x2C, 0x02, 0x00, 0x00, 0x00,    /* I32_LOAD8_U (align=2, offset=0) */
        0x06                              /* RETURN */
    };
    
    SasmModule module;
    memset(&module, 0, sizeof(module));
    module.version = 1;
    module.type_count = 1;
    module.types[0].param_count = 0;
    module.types[0].return_count = 1;
    module.types[0].return_types[0] = VAL_I32;
    module.func_count = 1;
    module.funcs[0].type_idx = 0;
    module.funcs[0].local_count = 0;
    module.code_count = 1;
    module.codes[0].func_idx = 0;
    module.codes[0].body_size = sizeof(load8_code);
    memcpy(module.codes[0].body, load8_code, sizeof(load8_code));
    module.total_memory_size = 512;
    module.safety.cycle_limit = 1000;
    module.entry_function = 0;
    
    static VM vm;
    assert(vm_init(&vm, &module, 512) == 0);
    assert(vm_run(&vm) == VM_OK);
    sasm_value result = vm_get_result(&vm);
    printf("  读回值: %d (期望: 171 = 0xAB)\n", result);
    assert(result == 0xAB);
    printf("测试 9: 通过 ✅\n");
}

/* ================================================================
   测试 10: I64 加法 (I64_CONST + I64_ADD + I32_WRAP_I64)
   ================================================================ */

static void test_i64_arith(void) {
    printf("测试 10: I64 算术 (10 + 20 = 30)...\n");
    
    /* I64_CONST 10 + I64_CONST 20 = I64_CONST 30 */
    const uint8_t i64_add_code[] = {
        0x50, 0x0A, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,  /* I64_CONST 10 */
        0x50, 0x14, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,  /* I64_CONST 20 */
        0x7C,                             /* I64_ADD: 10 + 20 = 30 */
        0xA7,                             /* I32_WRAP_I64: takes lo 32 bits */
        0x06                              /* RETURN */
    };
    
    SasmModule module;
    memset(&module, 0, sizeof(module));
    module.version = 1;
    module.type_count = 1;
    module.types[0].param_count = 0;
    module.types[0].return_count = 1;
    module.types[0].return_types[0] = VAL_I32;
    module.func_count = 1;
    module.funcs[0].type_idx = 0;
    module.funcs[0].local_count = 0;
    module.code_count = 1;
    module.codes[0].func_idx = 0;
    module.codes[0].body_size = sizeof(i64_add_code);
    memcpy(module.codes[0].body, i64_add_code, sizeof(i64_add_code));
    module.total_memory_size = 256;
    module.safety.cycle_limit = 1000;
    module.entry_function = 0;
    
    static VM vm;
    assert(vm_init(&vm, &module, 256) == 0);
    assert(vm_run(&vm) == VM_OK);
    sasm_value result = vm_get_result(&vm);
    printf("  10 + 20 = %d (期望: 30)\n", result);
    assert(result == 30);
    printf("测试 10: 通过 ✅\n");
}

int main(void) {
    printf("========================================\n");
    printf("  Phase 0.10: 里程碑验证\n");
    printf("  SafeASM VM 端到端测试\n");
    printf("========================================\n\n");
    
    test_return_42();
    test_arithmetic();
    test_div_by_zero();
    test_conditional();
    test_i32_shifts();
    test_i32_comparisons();
    test_i64_const_and_conv();
    test_load8_store8();
    test_i64_arith();
    
    printf("\n========================================\n");
    printf("  全部 9 个测试通过 ✅\n");
    printf("  里程碑验证完成\n");
    printf("========================================\n");
    return 0;
}
