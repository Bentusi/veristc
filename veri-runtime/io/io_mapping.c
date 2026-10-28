/**
 * vm/io/io_mapping.c
 * I/O 映射层实现
 *
 * 实现 io_mapping.h 中声明的所有函数。
 * 使用 RTOS 抽象层 (g_vm_interface) 进行物理 I/O 操作。
 */

#include "io_mapping.h"
#include <string.h>

/* ================================================================
   内部辅助
   ================================================================ */

/**
 * parse_var_name - 从调试段解析 ST 变量名
 * @param dbg_buf  调试段数据缓冲区
 * @param dbg_len  缓冲区长度
 * @param offset   变量名偏移
 * @param name     [out] 解析出的变量名
 * @param name_len name 缓冲区大小
 */
static void parse_var_name(const uint8_t *dbg_buf, uint32_t dbg_len,
                           uint32_t offset, char *name, uint32_t name_len)
{
    if ((!dbg_buf) || (!name) || (name_len == 0u)) { return; }

    name[0] = '\0';

    if (offset >= dbg_len) { return; }

    uint32_t max_copy = dbg_len - offset;
    if (max_copy > (name_len - 1u)) { max_copy = name_len - 1u; }

    for (uint32_t i = 0; i < max_copy; i++) {
        char c = (char)dbg_buf[offset + i];
        if (c == '\0') { break; }
        name[i] = c;
        if ((i + 1u) < name_len) { name[i + 1] = '\0'; }
    }
}

/* ================================================================
   工程值 ↔ 原始值 转换
   ================================================================ */

int32_t io_mapping_raw_to_eng(const IOMapEntryRuntime *entry, int32_t raw_val)
{
    if (!entry) { return raw_val; }
    /* eng = raw * scale + bias */
    double result = ((double)raw_val * entry->scale_factor) + entry->bias;
    /* 饱和到 int32_t 范围 */
    if (result > (double)INT32_MAX) { return INT32_MAX; }
    if (result < (double)INT32_MIN) { return INT32_MIN; }
    return (int32_t)result;
}

int32_t io_mapping_eng_to_raw(const IOMapEntryRuntime *entry, int32_t eng_val)
{
    if (!entry) { return eng_val; }
    /* raw = (eng - bias) / scale, 防止除零 */
    if (entry->scale_factor == 0.0) { return eng_val; }
    double result = ((double)eng_val - entry->bias) / entry->scale_factor;
    if (result > (double)INT32_MAX) { return INT32_MAX; }
    if (result < (double)INT32_MIN) { return INT32_MIN; }
    return (int32_t)result;
}

/* ================================================================
   安全限值检查
   ================================================================ */

bool io_mapping_safety_check(const IOMapEntryRuntime *entry, int32_t value)
{
    if (!entry) { return false; }
    /* safety_limit_low > safety_limit_high 表示不限值 */
    if (entry->safety_limit_low > entry->safety_limit_high) { return true; }
    return ((value >= entry->safety_limit_low) && (value <= entry->safety_limit_high));
}

/* ================================================================
   映射表初始化
   ================================================================ */

int io_mapping_init(IOMappingTable *table,
                    const SasmModule *module,
                    const uint8_t *dbg_buf,
                    uint32_t dbg_len)
{
    if (!table || !module) { return -1; }

    (void)memset(table, 0, sizeof(IOMappingTable));

    if (module->iomap_count == 0) {
        table->state = IOMAP_STATE_READY;
        return 0;
    }

    uint32_t count = module->iomap_count;
    if (count > IO_MAX_CHANNELS) { count = IO_MAX_CHANNELS; }

    for (uint32_t i = 0; i < count; i++) {
        IOMapEntryRuntime *rt = &table->entries[i];
        const IOMapEntry *src = &module->iomap[i];

        rt->st_var_name_offset = src->st_var_name_offset;
        rt->mem_offset         = src->mem_offset;
        rt->channel_id         = src->channel_id;
        rt->direction          = src->direction;
        rt->io_type            = src->io_type;
        rt->bit_width          = src->bit_width;
        rt->scale_factor       = src->scale_factor;
        rt->bias               = src->bias;
        rt->safety_limit_low   = src->safety_limit_low;
        rt->safety_limit_high  = src->safety_limit_high;
        rt->raw_value          = 0;
        rt->eng_value          = 0;
        rt->fault              = false;

        /* 解析 ST 变量名 */
        parse_var_name(dbg_buf, dbg_len, src->st_var_name_offset,
                       rt->var_name, IO_NAME_MAX);

        if (src->direction == IO_DIR_INPUT) {
            table->input_count++;
        } else {
            table->output_count++;
        }
    }

    table->count = count;
    table->state = IOMAP_STATE_READY;
    return 0;
}

/* ================================================================
   批量读取输入
   ================================================================ */

int io_mapping_read_all(IOMappingTable *table, VM *vm)
{
    if (!table || !vm) { return -1; }
    if (table->state != IOMAP_STATE_READY) { return -1; }

    int ret = 0;

    for (uint32_t i = 0; i < table->count; i++) {
        IOMapEntryRuntime *entry = &table->entries[i];

        if (entry->direction != IO_DIR_INPUT) { continue; }
        if (entry->fault) { continue; }

        /* 通过 RTOS 抽象层读取物理通道 */
        int32_t raw_val;
        if (g_vm_interface.io_read && 
            g_vm_interface.io_read(entry->channel_id, &raw_val) != 0) {
            entry->fault = true;
            table->read_errors++;
            ret = -1;
            continue;
        }

        entry->raw_value = raw_val;

        /* 转换为工程值 */
        int32_t eng_val = io_mapping_raw_to_eng(entry, raw_val);

        /* 安全限值检查 */
        if (!io_mapping_safety_check(entry, eng_val)) {
            /* 超出安全限值，使用限值饱和 */
            table->safety_violations++;
            if (eng_val < entry->safety_limit_low) {
                eng_val = entry->safety_limit_low;
            } else {
                eng_val = entry->safety_limit_high;
            }
        }

        entry->eng_value = eng_val;

        /* 写入 VM 线性内存 (固定 4 字节小端序) */
        uint32_t addr = entry->mem_offset;
        if ((addr + 4u) <= vm->memory_size) {
            vm->memory[addr]     = (uint8_t)(eng_val & 0xFF);
            vm->memory[addr + 1] = (uint8_t)((eng_val >> 8) & 0xFF);
            vm->memory[addr + 2] = (uint8_t)((eng_val >> 16) & 0xFF);
            vm->memory[addr + 3] = (uint8_t)((eng_val >> 24) & 0xFF);
        }
    }

    return ret;
}

/* ================================================================
   批量写入输出
   ================================================================ */

int io_mapping_write_all(IOMappingTable *table, const VM *vm)
{
    if (!table || !vm) { return -1; }
    if (table->state != IOMAP_STATE_READY) { return -1; }

    int ret = 0;

    for (uint32_t i = 0; i < table->count; i++) {
        IOMapEntryRuntime *entry = &table->entries[i];

        if (entry->direction != IO_DIR_OUTPUT) { continue; }
        if (entry->fault) { continue; }

        /* 从 VM 线性内存读取值 */
        uint32_t addr = entry->mem_offset;
        int32_t eng_val = 0;
        if ((addr + 4u) <= vm->memory_size) {
            eng_val = (int32_t)vm->memory[addr] |
                     ((int32_t)vm->memory[addr + 1] << 8) |
                     ((int32_t)vm->memory[addr + 2] << 16) |
                     ((int32_t)vm->memory[addr + 3] << 24);
        }

        /* 安全限值检查 */
        if (!io_mapping_safety_check(entry, eng_val)) {
            table->safety_violations++;
            if (eng_val < entry->safety_limit_low) {
                eng_val = entry->safety_limit_low;
            } else {
                eng_val = entry->safety_limit_high;
            }
        }

        entry->eng_value = eng_val;

        /* 转换为原始值 */
        int32_t raw_val = io_mapping_eng_to_raw(entry, eng_val);
        entry->raw_value = raw_val;

        /* 通过 RTOS 抽象层写入物理通道 */
        if (g_vm_interface.io_write && 
            g_vm_interface.io_write(entry->channel_id, raw_val) != 0) {
            entry->fault = true;
            table->write_errors++;
            ret = -1;
        }
    }

    return ret;
}

/* ================================================================
   完整 I/O 扫描周期
   ================================================================ */

int io_mapping_cycle(IOMappingTable *table, VM *vm)
{
    if (!table || !vm) { return -1; }

    /* 1. 读取所有输入 */
    int ret = io_mapping_read_all(table, vm);

    /* 2. 执行 VM 扫描 */
    int vm_ret = vm_run(vm);
    if (vm_ret != VM_OK) {
        /* VM 执行错误，仍尝试输出 */
        ret = vm_ret;
    }

    /* 3. 写入所有输出 */
    int io_ret = io_mapping_write_all(table, vm);
    if (io_ret != 0) { ret = io_ret; }

    return ret;
}

/* ================================================================
   通道查找
   ================================================================ */

IOMapEntryRuntime *io_mapping_get_channel(IOMappingTable *table,
                                           uint32_t channel_id)
{
    if (!table) { return NULL; }

    for (uint32_t i = 0; i < table->count; i++) {
        if (table->entries[i].channel_id == channel_id) {
            return &table->entries[i];
        }
    }
    return NULL;
}

IOMapEntryRuntime *io_mapping_get_by_name(IOMappingTable *table,
                                           const char *var_name)
{
    if (!table || !var_name) { return NULL; }

    for (uint32_t i = 0; i < table->count; i++) {
        if (strncmp(table->entries[i].var_name, var_name, IO_NAME_MAX) == 0) {
            return &table->entries[i];
        }
    }
    return NULL;
}

/* ================================================================
   重置
   ================================================================ */

void io_mapping_reset(IOMappingTable *table)
{
    if (!table) { return; }

    for (uint32_t i = 0; i < table->count; i++) {
        table->entries[i].raw_value  = 0;
        table->entries[i].eng_value  = 0;
        table->entries[i].fault      = false;
    }

    table->state            = IOMAP_STATE_READY;
    table->read_errors      = 0;
    table->write_errors     = 0;
    table->safety_violations = 0;
}
