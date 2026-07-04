/**
 * vm/vm.h
 * SafeASM 虚拟机公共头文件
 * 定义 SasmModule、VM 等核心类型
 */

#ifndef VM_H
#define VM_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ================================================================
   常量
   ================================================================ */

#define SASM_MAGIC         0x4D534153  /* "SASM" as little-endian uint32 */
#define SASM_VERSION       0x01
#define SASM_MAX_FUNCTIONS 8
#define SASM_MAX_MEMORY    1048576
#define SASM_MAX_CODE_SIZE 8192

#define VAL_I32 0x7F
#define VAL_I64 0x7E
#define VAL_F32 0x7D
#define VAL_F64 0x7C

/* 操作码 */
#define OP_UNREACHABLE   0x00
#define OP_NOP           0x01
#define OP_BLOCK         0x02
#define OP_LOOP          0x03
#define OP_BR            0x04
#define OP_BR_IF         0x05
#define OP_RETURN        0x06
#define OP_CALL          0x10
#define OP_DROP          0x1A
#define OP_SELECT        0x1B
#define OP_LOCAL_GET     0x20
#define OP_LOCAL_SET     0x21
#define OP_LOCAL_TEE     0x22
#define OP_I32_LOAD      0x28
#define OP_I32_STORE     0x36
#define OP_I32_CONST     0x41
#define OP_I64_CONST     0x50
#define OP_I32_EQZ       0x45
#define OP_I32_EQ        0x46
#define OP_I32_NE        0x47
#define OP_I32_LT_S      0x48
#define OP_I32_LE_S      0x49
#define OP_I32_GT_S      0x4A
#define OP_I32_GE_S      0x4B
#define OP_I32_ADD       0x6A
#define OP_I32_SUB       0x6B
#define OP_I32_MUL       0x6C
#define OP_I32_DIV_S     0x6D
#define OP_I32_REM_S     0x6F
#define OP_I32_AND       0x71
#define OP_I32_OR        0x72
#define OP_I32_XOR       0x73
#define OP_SAFE_ASSERT   0xFC
#define OP_SAFE_BOUNDS   0xFD

/* ===== I32 位运算 (v1.1 补全) ===== */
#define OP_I32_SHL       0x74
#define OP_I32_SHR_S     0x75
#define OP_I32_ROTL      0x76
#define OP_I32_ROTR      0x77

/* ===== I64 指令 (v1.1) ===== */
#define OP_I64_EQZ       0x53
#define OP_I64_EQ        0x54
#define OP_I64_NE        0x55
#define OP_I64_LT_S      0x56
#define OP_I64_LE_S      0x57
#define OP_I64_GT_S      0x58
#define OP_I64_GE_S      0x59
#define OP_I64_ADD       0x7C
#define OP_I64_SUB       0x7D
#define OP_I64_MUL       0x7E
#define OP_I64_DIV_S     0x7F
#define OP_I64_REM_S     0x80
#define OP_I64_AND       0x81
#define OP_I64_OR        0x82
#define OP_I64_XOR       0x83
#define OP_I64_SHL       0x84
#define OP_I64_SHR_S     0x85

/* ===== F32 指令 (v1.1) ===== */
#define OP_F32_CONST     0x43
#define OP_F32_ADD       0x92
#define OP_F32_SUB       0x93
#define OP_F32_MUL       0x94
#define OP_F32_DIV       0x95
#define OP_F32_EQ        0x9A
#define OP_F32_NE        0x9B
#define OP_F32_LT        0x9C
#define OP_F32_LE        0x9D
#define OP_F32_GT        0x9E
#define OP_F32_GE        0x9F
#define OP_F32_ABS       0xA0
#define OP_F32_NEG       0xA1
#define OP_F32_SQRT      0xA2

/* ===== F64 指令 (v1.1) ===== */
#define OP_F64_CONST     0x44
#define OP_F64_ADD       0xA3
#define OP_F64_SUB       0xA4
#define OP_F64_MUL       0xA5
#define OP_F64_DIV       0xA6
#define OP_F64_EQ        0xAA
#define OP_F64_NE        0xAB
#define OP_F64_LT        0xAC
#define OP_F64_LE        0xAD
#define OP_F64_GT        0xAE
#define OP_F64_GE        0xAF
#define OP_F64_ABS       0xB0
#define OP_F64_NEG       0xB1
#define OP_F64_SQRT      0xB2

/* ===== 字节内存操作 (v1.1) ===== */
#define OP_I32_LOAD8_U   0x2C
#define OP_I32_STORE8    0x3A

/* ===== 类型转换 (v1.1) ===== */
#define OP_I32_WRAP_I64         0xA7
#define OP_I64_EXTEND_I32_S     0xA8   /* 注: 原 encoder.v 误用 0xAE 与 F64_GT 冲突, 修正为 0xA8 */
#define OP_I32_TRUNC_F32_S      0xB3
#define OP_I32_TRUNC_F64_S      0xB4
#define OP_F32_CONVERT_I32_S    0xB7
#define OP_F64_CONVERT_I32_S    0xBB


/* Section 类型 */
#define SEC_TYPE  0
#define SEC_FUNC  1
#define SEC_MEM   2
#define SEC_IOMAP 3
#define SEC_CODE  4
#define SEC_SAFE  5
#define SEC_WCET  6
#define SEC_DEBUG 7

/* 错误码 */
#define VM_OK                   0
#define VM_ERR_STACK_OVERFLOW   -1
#define VM_ERR_STACK_UNDERFLOW  -2
#define VM_ERR_DIV_BY_ZERO      -3
#define VM_ERR_UNREACHABLE      -4
#define VM_ERR_CYCLE_LIMIT      -5
#define VM_ERR_MEM_OUT_OF_BOUNDS -6
#define VM_ERR_INVALID_OPCODE   -7
#define VM_ERR_FRAME_OVERFLOW   -8

/* I/O 方向与类型 (匹配 rtos/abstract.h) */
#define IO_DIR_INPUT    0
#define IO_DIR_OUTPUT   1

#define IO_TYPE_AI      0
#define IO_TYPE_AO      1
#define IO_TYPE_DI      2
#define IO_TYPE_DO      3

/* ================================================================
   类型定义
   ================================================================ */

typedef int32_t sasm_value;

typedef struct {
    uint32_t param_count;
    uint8_t  param_types[16];
    uint32_t return_count;
    uint8_t  return_types[1];
} FuncType;

typedef struct {
    uint32_t type_idx;
    uint32_t local_count;
    uint8_t  local_types[32];
} FuncDecl;

typedef struct {
    uint8_t  segment_type;
    uint32_t start_offset;
    uint32_t size;
} MemSegment;

typedef struct {
    uint32_t st_var_name_offset;
    uint32_t mem_offset;
    uint32_t channel_id;
    uint8_t  direction;
    uint8_t  io_type;
    uint32_t bit_width;
    double   scale_factor;
    double   bias;
    int32_t  safety_limit_low;
    int32_t  safety_limit_high;
} IOMapEntry;

typedef struct {
    uint32_t func_idx;
    uint32_t instr_offset;
    uint32_t max_iterations;
} LoopBound;

typedef struct {
    uint32_t low;
    uint32_t high;
} MemAccessRange;

typedef struct {
    uint8_t  safety_level;
    uint32_t cycle_limit;
    uint32_t global_stack_depth;
    uint32_t loop_count;
    LoopBound loop_bounds[8];
    uint32_t mem_range_count;
    MemAccessRange mem_access_ranges[8];
} SafetyAnnotation;

typedef struct {
    uint32_t func_idx;
    uint32_t body_size;
    uint8_t  body[SASM_MAX_CODE_SIZE];
} FuncCode;

typedef struct {
    uint8_t  version;
    uint8_t  flags;
    uint32_t type_count;
    FuncType types[SASM_MAX_FUNCTIONS];
    uint32_t func_count;
    FuncDecl funcs[SASM_MAX_FUNCTIONS];
    uint32_t segment_count;
    MemSegment segments[8];
    uint32_t total_memory_size;
    uint32_t iomap_count;
    IOMapEntry iomap[64];
    uint32_t code_count;
    FuncCode  codes[SASM_MAX_FUNCTIONS];
    SafetyAnnotation safety;
    uint32_t entry_function;
} SasmModule;

/* 帧 */
typedef struct {
    uint32_t func_idx;
    uint32_t pc;
    sasm_value locals[32];
    uint32_t local_count;
    const uint8_t *body;
    uint32_t body_size;
    uint32_t block_stack[16];
    uint32_t block_depth;
} Frame;

/* VM */
#define VALUE_STACK_SIZE  1024
#define FRAME_STACK_SIZE  64
#define MEMORY_SIZE       1048576

typedef struct {
    const SasmModule *module;
    sasm_value val_stack[VALUE_STACK_SIZE];
    uint32_t   val_stack_ptr;
    Frame frame_stack[FRAME_STACK_SIZE];
    uint32_t frame_stack_ptr;
    uint8_t memory[MEMORY_SIZE];
    uint32_t memory_size;
    uint32_t cycle_count;
    int last_error;
} VM;

/* ================================================================
   函数声明
   ================================================================ */

/* loader.c */
int  sasm_load(const uint8_t *buf, uint32_t len, SasmModule *module);
bool sasm_validate(const SasmModule *module);

/* safeasm_interp.c */
int  vm_init(VM *vm, const SasmModule *module, uint32_t memory_size);
int  vm_run(VM *vm);
int  vm_execute_cycle(VM *vm);

/* ================================================================
   I/O 映射层集成接口
   ================================================================ */

/**
 * vm_scan_cycle - 执行完整 I/O + VM 扫描周期
 * @param vm    VM 实例
 * @param iomap I/O 映射表 (可为 NULL, 此时仅执行 vm_run)
 * @return 0 = 成功, 负值 = 错误码
 *
 * 此函数供 RTOS 适配层或裸机主循环调用。
 * 执行顺序: 读输入 → VM执行 → 写输出
 */
int vm_scan_cycle(VM *vm, void *iomap);
sasm_value vm_get_result(const VM *vm);

#ifdef __cplusplus
}
#endif

#endif /* VM_H */
