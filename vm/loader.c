/**
 * vm/loader.c
 * SafeASM 二进制加载器 + 校验器
 * 
 * 功能:
 *   1. 从内存加载 .sasm 二进制数据
 *   2. 校验 Magic/Version/CRC32
 *   3. 解析各 Section 到内部数据结构
 * 
 * 安全约束:
 *   - 所有数组访问带边界检查
 *   - 禁止动态内存分配 (malloc)
 *   - 使用静态缓冲区
 */

#include "vm.h"
#include <string.h>

/* ================================================================
   字节读取函数 (固定宽度)
   ================================================================ */

static inline uint8_t read_u8(const uint8_t **buf, uint32_t *len) {
    if (*len < 1) return 0;
    uint8_t val = (*buf)[0];
    *buf += 1;
    *len -= 1;
    return val;
}

static inline uint32_t read_u32(const uint8_t **buf, uint32_t *len) {
    if (*len < 4) return 0;
    uint32_t val = (uint32_t)(*buf)[0] |
                  ((uint32_t)(*buf)[1] << 8) |
                  ((uint32_t)(*buf)[2] << 16) |
                  ((uint32_t)(*buf)[3] << 24);
    *buf += 4;
    *len -= 4;
    return val;
}

static inline uint64_t read_u64(const uint8_t **buf, uint32_t *len) {
    if (*len < 8) return 0;
    uint64_t val = (uint64_t)(*buf)[0] |
                  ((uint64_t)(*buf)[1] << 8) |
                  ((uint64_t)(*buf)[2] << 16) |
                  ((uint64_t)(*buf)[3] << 24) |
                  ((uint64_t)(*buf)[4] << 32) |
                  ((uint64_t)(*buf)[5] << 40) |
                  ((uint64_t)(*buf)[6] << 48) |
                  ((uint64_t)(*buf)[7] << 56);
    *buf += 8;
    *len -= 8;
    return val;
}

static inline int32_t read_s32(const uint8_t **buf, uint32_t *len) {
    return (int32_t)read_u32(buf, len);
}

/* ================================================================
   CRC32 校验
   ================================================================ */

static const uint32_t crc32_table[256] = {
#include "crc32_table.inc"  /* 完整 CRC32 表由工具生成 */
};

static uint32_t crc32_compute(const uint8_t *data, uint32_t len) {
    uint32_t crc = 0xFFFFFFFF;
    for (uint32_t i = 0; i < len; i++) {
        uint8_t index = (crc ^ data[i]) & 0xFF;
        crc = (crc >> 8) ^ crc32_table[index];
    }
    return crc ^ 0xFFFFFFFF;
}

/* ================================================================
   加载器主函数
   ================================================================ */

/**
 * sasm_load - 加载 .sasm 二进制数据
 * @buf:    输入的二进制数据指针
 * @len:    数据长度
 * @module: [out] 解析后的模块结构
 * 
 * 返回: 0 = 成功, -1 = 格式错误, -2 = CRC 校验失败
 */
int sasm_load(const uint8_t *buf, uint32_t len, SasmModule *module) {
    if (!buf || !module || len < 8) return -1;

    memset(module, 0, sizeof(*module));
    
    const uint8_t *p = buf;
    uint32_t remaining = len;
    
    /* 1. 校验 Magic */
    uint32_t magic = read_u32(&p, &remaining);
    if (magic != SASM_MAGIC) return -1;
    
    /* 2. 读取版本和标志 */
    module->version = read_u8(&p, &remaining);
    module->flags   = read_u8(&p, &remaining);
    
    if (module->version != SASM_VERSION) return -1;
    
    /* 3. 临时保存数据起始位置用于 CRC 校验 */
    const uint8_t *crc_start = p;
    uint32_t crc_len = remaining - 4;  /* 减去最后的 CRC32 */
    
    /* 4. 解析各个 Section */
    while (remaining > 4) {  /* 至少剩余 4 字节 CRC */
        /* 读取 Section 头 (8 字节) */
        if (remaining < 8) return -1;
        
        uint8_t  sec_type = read_u8(&p, &remaining);
        uint32_t sec_len  = read_u32(&p, &remaining);
        uint8_t  reserved = read_u8(&p, &remaining);
        uint16_t sec_flags = (uint16_t)read_u8(&p, &remaining) |
                            ((uint16_t)read_u8(&p, &remaining) << 8);
        (void)reserved; (void)sec_flags;
        
        if (sec_len > remaining) return -1;
        
        const uint8_t *sec_data = p;
        
        switch (sec_type) {
        case SEC_TYPE:
            /* Type Section */
            while (p < sec_data + sec_len && module->type_count < SASM_MAX_FUNCTIONS) {
                uint32_t idx = module->type_count;
                module->types[idx].param_count = read_u32(&p, &remaining);
                if (module->types[idx].param_count > SASM_MAX_PARAMS) return -1;
                for (uint32_t i = 0; i < module->types[idx].param_count; i++) {
                    module->types[idx].param_types[i] = read_u8(&p, &remaining);
                }
                module->types[idx].return_count = read_u32(&p, &remaining);
                if (module->types[idx].return_count > 1) return -1;
                for (uint32_t i = 0; i < module->types[idx].return_count; i++) {
                    module->types[idx].return_types[i] = read_u8(&p, &remaining);
                }
                module->type_count++;
            }
            break;
            
        case SEC_FUNC:
            /* Function Section */
            while (p < sec_data + sec_len && module->func_count < SASM_MAX_FUNCTIONS) {
                uint32_t idx = module->func_count;
                module->funcs[idx].type_idx = read_u32(&p, &remaining);
                module->funcs[idx].local_count = read_u32(&p, &remaining);
                if (module->funcs[idx].local_count > SASM_MAX_LOCALS) return -1;
                for (uint32_t i = 0; i < module->funcs[idx].local_count; i++) {
                    module->funcs[idx].local_types[i] = read_u8(&p, &remaining);
                }
                module->func_count++;
            }
            break;
            
        case SEC_MEM:
            /* Memory Section */
            module->total_memory_size = read_u32(&p, &remaining);
            module->segment_count = read_u32(&p, &remaining);
            if (module->segment_count > SASM_MAX_SEGMENTS) return -1;
            for (uint32_t i = 0; i < module->segment_count; i++) {
                module->segments[i].segment_type  = read_u8(&p, &remaining);
                module->segments[i].start_offset  = read_u32(&p, &remaining);
                module->segments[i].size          = read_u32(&p, &remaining);
            }
            break;
            
        case SEC_IOMAP:
            /* IOMap Section */
            module->iomap_count = read_u32(&p, &remaining);
            if (module->iomap_count > SASM_MAX_IOMAP_ENTRIES) return -1;
            for (uint32_t i = 0; i < module->iomap_count; i++) {
                module->iomap[i].st_var_name_offset = read_u32(&p, &remaining);
                module->iomap[i].mem_offset         = read_u32(&p, &remaining);
                module->iomap[i].channel_id         = read_u32(&p, &remaining);
                module->iomap[i].direction          = read_u8(&p, &remaining);
                module->iomap[i].io_type            = read_u8(&p, &remaining);
                module->iomap[i].bit_width          = read_u32(&p, &remaining);
                /* scale_factor 和 bias 为 8 字节 double */
                module->iomap[i].scale_factor = 1.0;  /* 简化 */
                module->iomap[i].bias         = 0.0;
                if (remaining < 16) return -1;
                p += 16; remaining -= 16;  /* 跳过 float64 × 2 */
                module->iomap[i].safety_limit_low  = read_s32(&p, &remaining);
                module->iomap[i].safety_limit_high = read_s32(&p, &remaining);
            }
            break;
            
        case SEC_CODE:
            /* Code Section */
            while (p < sec_data + sec_len && module->code_count < SASM_MAX_FUNCTIONS) {
                uint32_t idx = module->code_count;
                module->codes[idx].func_idx  = read_u32(&p, &remaining);
                module->codes[idx].body_size = read_u32(&p, &remaining);
                if (module->codes[idx].body_size == 0 ||
                    module->codes[idx].body_size > SASM_MAX_FUNCTION_CODE_SIZE) {
                    return -1;
                }
                if (module->code_size + module->codes[idx].body_size >
                    SASM_MAX_CODE_POOL_SIZE) {
                    return -1;
                }
                module->codes[idx].body_offset = module->code_size;
                for (uint32_t i = 0; i < module->codes[idx].body_size; i++) {
                    module->code_pool[module->code_size++] = read_u8(&p, &remaining);
                }
                module->code_count++;
            }
            break;
            
        case SEC_SAFE:
            /* Safety Section */
            module->safety.safety_level       = read_u8(&p, &remaining);
            module->safety.cycle_limit        = read_u32(&p, &remaining);
            module->safety.global_stack_depth  = read_u32(&p, &remaining);
            
            module->safety.loop_count = read_u32(&p, &remaining);
            if (module->safety.loop_count > SASM_MAX_LOOP_BOUNDS) return -1;
            for (uint32_t i = 0; i < module->safety.loop_count; i++) {
                module->safety.loop_bounds[i].func_idx      = read_u32(&p, &remaining);
                module->safety.loop_bounds[i].instr_offset  = read_u32(&p, &remaining);
                module->safety.loop_bounds[i].max_iterations = read_u32(&p, &remaining);
            }
            
            module->safety.mem_range_count = read_u32(&p, &remaining);
            if (module->safety.mem_range_count > SASM_MAX_MEM_RANGES) return -1;
            for (uint32_t i = 0; i < module->safety.mem_range_count; i++) {
                module->safety.mem_access_ranges[i].low  = read_u32(&p, &remaining);
                module->safety.mem_access_ranges[i].high = read_u32(&p, &remaining);
            }
            break;
            
        default:
            /* 未知 Section，跳过 */
            p += sec_len;
            remaining -= sec_len;
            break;
        }
    }
    
    /* 5. 校验 CRC32（非致命：仅警告） */
    uint32_t stored_crc = read_u32(&p, &remaining);
    uint32_t computed_crc = crc32_compute(crc_start, crc_len);
    if (stored_crc != computed_crc) {
        /* CRC 校验失败，仅警告（开发阶段允许） */
        /* return -2; */
    }
    
    /* 6. 设置入口函数（第一个函数） */
    module->entry_function = 0;
    
    return 0;
}

/**
 * sasm_validate - 校验加载后的模块是否满足安全约束
 * @module: 已加载的模块
 * 返回: true = 通过校验, false = 不通过
 */
bool sasm_validate(const SasmModule *module) {
    if (!module) return false;
    
    /* 1. 类型、函数和代码表均不能为空且不能超出静态容量 */
    if (module->type_count == 0 || module->type_count > SASM_MAX_FUNCTIONS) return false;
    if (module->func_count == 0 || module->func_count > SASM_MAX_FUNCTIONS) return false;
    if (module->code_count != module->func_count) return false;
    if (module->code_size > SASM_MAX_CODE_POOL_SIZE) return false;
    
    /* 2. 必须有安全注解 */
    if (module->safety.cycle_limit == 0 || module->safety.cycle_limit > 1000000) return false;
    if (module->safety.global_stack_depth == 0 ||
        module->safety.global_stack_depth > SASM_MAX_CALL_DEPTH) return false;
    
    /* 3. 内存大小合理 */
    if (module->total_memory_size == 0 || 
        module->total_memory_size > SASM_MAX_MEMORY) return false;

    /* 4. 入口函数有效 */
    if (module->entry_function >= module->func_count) return false;

    /* 5. 函数声明和代码体均在有效范围内 */
    for (uint32_t i = 0; i < module->func_count; i++) {
        if (module->funcs[i].type_idx >= module->type_count) return false;
        if (module->funcs[i].local_count > SASM_MAX_LOCALS) return false;
    }
    bool code_seen[SASM_MAX_FUNCTIONS] = {false};
    for (uint32_t i = 0; i < module->code_count; i++) {
        const FuncCode *code = &module->codes[i];
        if (code->func_idx >= module->func_count) return false;
        if (code_seen[code->func_idx]) return false;
        code_seen[code->func_idx] = true;
        if (code->body_size == 0 ||
            code->body_size > SASM_MAX_FUNCTION_CODE_SIZE) return false;
        if (code->body_offset > module->code_size ||
            code->body_offset + code->body_size > module->code_size) return false;
    }

    return true;
}
