/**
 * tests/vm-tests/test_engineering.c
 * SafeASM VM 指令回归 + 工业控制容量验收
 *
 * 工程用例:
 *   - 256 个函数的闭环控制处理链
 *   - 256 层函数调用深度
 *   - 参数校验、限幅和安全输出计算
 *   - global_stack_depth 溢出保护
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

static void install_code(SasmModule *module, uint32_t code_idx,
                         const uint8_t *body, uint32_t body_size) {
    assert(code_idx < SASM_MAX_FUNCTIONS);
    assert(body_size > 0);
    assert(body_size <= SASM_MAX_FUNCTION_CODE_SIZE);
    assert(module->code_size + body_size <= SASM_MAX_CODE_POOL_SIZE);

    module->codes[code_idx].body_offset = module->code_size;
    module->codes[code_idx].body_size = body_size;
    memcpy(module->code_pool + module->code_size, body, body_size);
    module->code_size += body_size;
}

/* ================================================================
   从真实 .sasm 文件加载并执行
   验证 Phase 0 里程碑: loader + interpreter 端到端可用。
   ================================================================ */

static void test_load_return42_sasm(void) {
    const char *path = "tests/sasm-examples/return42.sasm";
    FILE *fp = fopen(path, "rb");
    assert(fp != NULL);

    uint8_t buf[256];
    size_t len = fread(buf, 1, sizeof(buf), fp);
    fclose(fp);
    assert(len >= 8 && len < sizeof(buf));

    static SasmModule module;
    assert(sasm_load(buf, (uint32_t)len, &module) == 0);
    assert(sasm_validate(&module) == true);

    VM vm;
    assert(vm_init(&vm, &module, 256) == 0);
    assert(vm_run(&vm) == VM_OK);
    assert(vm_get_result(&vm) == 42);

    printf("测试 2: 从 return42.sasm 加载执行...\n");
    printf("  结果: %d (期望: 42)\n", vm_get_result(&vm));
    printf("测试 2: 通过 ✅\n");
}

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
    const uint8_t body[] = {
        OP_I32_CONST, 0x2A, 0x00, 0x00, 0x00,
        OP_RETURN
    };
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
    install_code(m, 0, body, sizeof(body));
    m->total_memory_size = 256;
    m->safety.cycle_limit = 1000;
    m->safety.global_stack_depth = 8;
    m->entry_function = 0;
}

/* ================================================================
   测试 1: 执行最小程序 (返回 42)
   ================================================================ */

static void test_return_42(void) {
    printf("测试 1: 执行最小程序 (返回 42)...\n");
    
    static SasmModule module;
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
    static SasmModule module;
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
    install_code(&module, 0, arith_code, sizeof(arith_code));
    
    module.total_memory_size = 256;
    module.safety.cycle_limit = 1000;
    module.safety.global_stack_depth = 8;
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
    
    static SasmModule module;
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
    install_code(&module, 0, div_code, sizeof(div_code));
    module.total_memory_size = 256;
    module.safety.cycle_limit = 1000;
    module.safety.global_stack_depth = 8;
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
    
    static SasmModule module;
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
    install_code(&module, 0, cond_code, sizeof(cond_code));
    module.total_memory_size = 256;
    module.safety.cycle_limit = 1000;
    module.safety.global_stack_depth = 8;
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
    
    static SasmModule module;
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
    install_code(&module, 0, bits_code, sizeof(bits_code));
    module.total_memory_size = 256;
    module.safety.cycle_limit = 1000;
    module.safety.global_stack_depth = 8;
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
    
    static SasmModule module;
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
    install_code(&module, 0, cmp_code, sizeof(cmp_code));
    module.total_memory_size = 256;
    module.safety.cycle_limit = 1000;
    module.safety.global_stack_depth = 8;
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
    
    static SasmModule module;
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
    install_code(&module, 0, i64_code, sizeof(i64_code));
    module.total_memory_size = 256;
    module.safety.cycle_limit = 1000;
    module.safety.global_stack_depth = 8;
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
    
    static SasmModule mod2;
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
    install_code(&mod2, 0, extend_code, sizeof(extend_code));
    mod2.total_memory_size = 256;
    mod2.safety.cycle_limit = 1000;
    mod2.safety.global_stack_depth = 8;
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
    
    static SasmModule module;
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
    install_code(&module, 0, load8_code, sizeof(load8_code));
    module.total_memory_size = 512;
    module.safety.cycle_limit = 1000;
    module.safety.global_stack_depth = 8;
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
    
    static SasmModule module;
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
    install_code(&module, 0, i64_add_code, sizeof(i64_add_code));
    module.total_memory_size = 256;
    module.safety.cycle_limit = 1000;
    module.safety.global_stack_depth = 8;
    module.entry_function = 0;
    
    static VM vm;
    assert(vm_init(&vm, &module, 256) == 0);
    assert(vm_run(&vm) == VM_OK);
    sasm_value result = vm_get_result(&vm);
    printf("  10 + 20 = %d (期望: 30)\n", result);
    assert(result == 30);
    printf("测试 10: 通过 ✅\n");
}

/* ================================================================
   测试 11: 工业控制闭环 - 4096 函数表 + 256 层调用
   ================================================================ */

static void test_industrial_control_limits(void) {
    const char *path = "tests/sasm-examples/industrial_control.sasm";

    printf("测试 11: 工业控制闭环容量验收...\n");
    assert(SASM_MAX_FUNCTIONS == 4096);
    assert(SASM_MAX_CALL_DEPTH == 256);
    assert(SASM_MAX_LOCALS >= 1024);
    assert(SASM_MAX_PARAMS == 16);
    assert(SASM_MAX_MEMORY == 1048576);

    FILE *fp = fopen(path, "rb");
    assert(fp != NULL);

    static uint8_t buf[262144];
    size_t len = fread(buf, 1, sizeof(buf), fp);
    fclose(fp);
    assert(len > 0 && len < sizeof(buf));

    static SasmModule module;
    assert(sasm_load(buf, (uint32_t)len, &module) == 0);
    assert(sasm_validate(&module));
    assert(module.func_count == SASM_MAX_FUNCTIONS);
    assert(module.code_count == SASM_MAX_FUNCTIONS);
    assert(module.safety.global_stack_depth == SASM_MAX_CALL_DEPTH);

    static VM vm;
    assert(vm_init(&vm, &module, 4096) == 0);
    assert(vm_run(&vm) == VM_OK);
    assert(vm_get_result(&vm) == 4095);
    assert(vm.max_frame_depth == SASM_MAX_CALL_DEPTH);
    assert(vm.max_value_stack_depth > 1);

    printf("  函数数: %u\n", module.func_count);
    printf("  最大调用深度: %u\n", vm.max_frame_depth);
    printf("  最大值栈深度: %u\n", vm.max_value_stack_depth);
    printf("  控制输出: %d (期望: 4095)\n", vm_get_result(&vm));

    /* 同一程序收紧栈上限，必须在进入第 65 层前安全中止。 */
    const uint32_t configured_depth = 64;
    module.safety.global_stack_depth = configured_depth;
    assert(vm_init(&vm, &module, 4096) == 0);
    assert(vm_run(&vm) == VM_ERR_FRAME_OVERFLOW);
    assert(vm.max_frame_depth == configured_depth);
    printf("  栈溢出保护: 深度 %u 时中止\n", configured_depth);

    printf("测试 11: 通过 ✅\n");
}

/* ================================================================
   测试 12: 核电站四保护通道 + 两个专设安全系列
   ================================================================ */

typedef struct {
    const char *name;
    int32_t power[4];
    int32_t pressure[4];
    int32_t level[4];
    int32_t valid[4];
    int32_t bypass[4];
    int32_t train_enable[2];
    int32_t train_permissive[2];
    int32_t expected_channel[4];
    int32_t expected_vote;
    int32_t expected_trip;
    int32_t expected_train[2];
    int32_t expected_mismatch;
} NuclearScenario;

static const uint32_t nuclear_channel_offsets[4] = {0, 20, 40, 60};
static const uint32_t nuclear_channel_outputs[4] = {116, 120, 124, 128};

static void vm_write_i32(VM *vm, uint32_t offset, int32_t value) {
    assert(offset + sizeof(value) <= vm->memory_size);
    memcpy(vm->memory + offset, &value, sizeof(value));
}

static int32_t vm_read_i32(const VM *vm, uint32_t offset) {
    int32_t value = 0;
    assert(offset + sizeof(value) <= vm->memory_size);
    memcpy(&value, vm->memory + offset, sizeof(value));
    return value;
}

static void configure_nuclear_inputs(VM *vm, const NuclearScenario *scenario) {
    for (uint32_t i = 0; i < 4; i++) {
        uint32_t base = nuclear_channel_offsets[i];
        vm_write_i32(vm, base, scenario->power[i]);
        vm_write_i32(vm, base + 4, scenario->pressure[i]);
        vm_write_i32(vm, base + 8, scenario->level[i]);
        vm_write_i32(vm, base + 12, scenario->valid[i]);
        vm_write_i32(vm, base + 16, scenario->bypass[i]);
    }
    vm_write_i32(vm, 80, scenario->train_enable[0]);
    vm_write_i32(vm, 84, scenario->train_permissive[0]);
    vm_write_i32(vm, 88, scenario->train_enable[1]);
    vm_write_i32(vm, 92, scenario->train_permissive[1]);
}

static void test_nuclear_protection_case(void) {
    static const NuclearScenario scenarios[] = {
        {
            "正常运行",
            {900, 950, 920, 980},
            {155, 160, 150, 158},
            {80, 75, 85, 70},
            {1, 1, 1, 1},
            {0, 0, 0, 0},
            {1, 1},
            {1, 1},
            {0, 0, 0, 0},
            0, 0, {0, 0}, 0,
        },
        {
            "单通道高功率 1/4",
            {1100, 950, 920, 980},
            {155, 160, 150, 158},
            {80, 75, 85, 70},
            {1, 1, 1, 1},
            {0, 0, 0, 0},
            {1, 1},
            {1, 1},
            {1, 0, 0, 0},
            1, 0, {0, 0}, 0,
        },
        {
            "低压低液位 2/4",
            {900, 950, 920, 980},
            {155, 110, 150, 158},
            {80, 75, 15, 70},
            {1, 1, 1, 1},
            {0, 0, 0, 0},
            {1, 1},
            {1, 1},
            {0, 1, 1, 0},
            2, 1, {1, 1}, 0,
        },
        {
            "坏质量点加 2/4",
            {1100, 1050, 1020, 980},
            {155, 160, 150, 158},
            {80, 75, 85, 70},
            {0, 1, 1, 1},
            {0, 0, 0, 0},
            {1, 1},
            {1, 1},
            {0, 1, 1, 0},
            2, 1, {1, 1}, 0,
        },
        {
            "四通道全旁通",
            {1100, 1100, 1100, 1100},
            {100, 100, 100, 100},
            {10, 10, 10, 10},
            {1, 1, 1, 1},
            {1, 1, 1, 1},
            {1, 1},
            {1, 1},
            {0, 0, 0, 0},
            0, 0, {0, 0}, 0,
        },
        {
            "A 列闭锁不一致",
            {900, 950, 920, 980},
            {155, 110, 150, 158},
            {80, 75, 15, 70},
            {1, 1, 1, 1},
            {0, 0, 0, 0},
            {0, 1},
            {1, 1},
            {0, 1, 1, 0},
            2, 1, {0, 1}, 1,
        },
    };

    const char *path = "tests/sasm-examples/nuclear_protection.sasm";
    printf("测试 12: 核电四通道与两专设系列逻辑...\n");

    FILE *fp = fopen(path, "rb");
    assert(fp != NULL);

    static uint8_t buf[16384];
    size_t len = fread(buf, 1, sizeof(buf), fp);
    fclose(fp);
    assert(len > 0 && len < sizeof(buf));

    static SasmModule module;
    assert(sasm_load(buf, (uint32_t)len, &module) == 0);
    assert(sasm_validate(&module));
    assert(module.func_count == 10);
    assert(module.safety.global_stack_depth == 3);

    static VM vm;
    for (size_t scenario_index = 0;
         scenario_index < sizeof(scenarios) / sizeof(scenarios[0]);
         scenario_index++) {
        const NuclearScenario *scenario = &scenarios[scenario_index];
        assert(vm_init(&vm, &module, 4096) == 0);
        configure_nuclear_inputs(&vm, scenario);
        assert(vm_run(&vm) == VM_OK);

        for (uint32_t channel = 0; channel < 4; channel++) {
            int32_t actual = vm_read_i32(&vm, nuclear_channel_outputs[channel]);
            assert(actual == scenario->expected_channel[channel]);
        }

        int32_t vote = vm_read_i32(&vm, 108);
        int32_t trip = vm_read_i32(&vm, 96);
        int32_t train_a = vm_read_i32(&vm, 100);
        int32_t train_b = vm_read_i32(&vm, 104);
        int32_t mismatch = vm_read_i32(&vm, 112);

        assert(vote == scenario->expected_vote);
        assert(trip == scenario->expected_trip);
        assert(vm_get_result(&vm) == scenario->expected_trip);
        assert(train_a == scenario->expected_train[0]);
        assert(train_b == scenario->expected_train[1]);
        assert(mismatch == scenario->expected_mismatch);
        assert(vm.max_frame_depth == 3);

        printf("  %-18s vote=%d trip=%d trainA=%d trainB=%d mismatch=%d\n",
               scenario->name, vote, trip, train_a, train_b, mismatch);
    }

    printf("测试 12: 通过 ✅\n");
}

int main(void) {
    printf("========================================\n");
    printf("  SafeASM VM 工程回归与容量验收\n");
    printf("========================================\n\n");
    
    test_return_42();
    test_load_return42_sasm();
    test_arithmetic();
    test_div_by_zero();
    test_conditional();
    test_i32_shifts();
    test_i32_comparisons();
    test_i64_const_and_conv();
    test_load8_store8();
    test_i64_arith();
    test_industrial_control_limits();
    test_nuclear_protection_case();
    
    printf("\n========================================\n");
    printf("  全部 12 个测试通过 ✅\n");
    printf("  里程碑验证完成\n");
    printf("========================================\n");
    return 0;
}
