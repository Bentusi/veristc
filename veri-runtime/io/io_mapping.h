/**
 * vm/io/io_mapping.h
 * I/O 映射层 — 将 SafeASM 线性内存地址映射到物理 I/O 通道
 *
 * 功能:
 *   1. 解析加载后的 SasmModule 中的 IOMap 段
 *   2. 在扫描周期中同步 VM 内存 ↔ 物理 I/O 通道
 *   3. 应用缩放因子/偏置 (工程值转换)
 *   4. 安全限值检查 (safety_limit_low/high)
 *
 * 安全约束:
 *   - 所有数组访问带边界检查
 *   - 禁止动态内存分配
 *   - 所有通道操作带超时保护
 */

#ifndef IO_MAPPING_H
#define IO_MAPPING_H

#include "../core/vm.h"
#include "../rtos/abstract.h"

#ifdef __cplusplus
extern "C" {
#endif

/* ================================================================
   常量
   ================================================================ */

#define IO_MAX_CHANNELS  64    /* 最大 I/O 通道数 (匹配 SasmModule.iomap[64]) */
#define IO_NAME_MAX      64    /* 变量名最大长度 */

/* I/O 映射表状态 */
#define IOMAP_STATE_UNINIT  0   /* 未初始化 */
#define IOMAP_STATE_READY   1   /* 已就绪 */
#define IOMAP_STATE_ERROR   2   /* 错误状态 */

/* ================================================================
   I/O 映射条目 (运行时扩展)
   ================================================================ */

typedef struct {
    /* 来自 SasmModule.iomap[] 的静态信息 */
    uint32_t st_var_name_offset;  /* ST 变量名在调试段的偏移 */
    uint32_t mem_offset;          /* VM 线性内存偏移地址 */
    uint32_t channel_id;          /* 物理通道 ID */
    uint8_t  direction;           /* IO_DIR_INPUT / IO_DIR_OUTPUT */
    uint8_t  io_type;             /* IO_TYPE_AI/AO/DI/DO */
    uint32_t bit_width;           /* 位宽 */
    double   scale_factor;        /* 缩放因子 */
    double   bias;                /* 偏置 */
    int32_t  safety_limit_low;    /* 安全下限 */
    int32_t  safety_limit_high;   /* 安全上限 */

    /* 运行时状态 */
    int32_t  raw_value;           /* 末次原始值 */
    int32_t  eng_value;           /* 末次工程值 */
    bool     fault;               /* 该通道是否故障 */
    char     var_name[IO_NAME_MAX]; /* 变量名 (从调试段解析) */
} IOMapEntryRuntime;

/* ================================================================
   I/O 映射表
   ================================================================ */

typedef struct {
    IOMapEntryRuntime entries[IO_MAX_CHANNELS];
    uint32_t          count;            /* 有效条目数 */
    uint32_t          input_count;      /* 输入通道数 */
    uint32_t          output_count;     /* 输出通道数 */
    uint8_t           state;            /* IOMAP_STATE_* */

    /* 统计信息 */
    uint32_t          read_errors;
    uint32_t          write_errors;
    uint32_t          safety_violations;
} IOMappingTable;

/* ================================================================
   函数接口
   ================================================================ */

/**
 * io_mapping_init - 从 SasmModule 初始化 I/O 映射表
 * @param table  [out] I/O 映射表
 * @param module 已加载的 SasmModule (含 IOMap 段)
 * @param dbg_buf 调试段数据缓冲区 (用于解析变量名, 可为 NULL)
 * @param dbg_len 调试段数据长度
 * @return 0 = 成功, -1 = 失败
 */
int io_mapping_init(IOMappingTable *table,
                    const SasmModule *module,
                    const uint8_t *dbg_buf,
                    uint32_t dbg_len);

/**
 * io_mapping_read_all - 从物理通道读取所有输入
 * @param table I/O 映射表
 * @param vm    VM 实例 (用于写入内存)
 * @return 0 = 全部成功, 负值 = 存在故障
 *
 * 遍历所有 INPUT 通道，调用 g_vm_interface.io_read() 读取原始值，
 * 应用缩放/偏置后进行安全限值检查，最后写入 VM 线性内存。
 */
int io_mapping_read_all(IOMappingTable *table, VM *vm);

/**
 * io_mapping_write_all - 将所有输出写入物理通道
 * @param table I/O 映射表
 * @param vm    VM 实例 (用于读取内存)
 * @return 0 = 全部成功, 负值 = 存在故障
 *
 * 遍历所有 OUTPUT 通道，从 VM 线性内存读取值，
 * 应用逆缩放后进行安全限值检查，最后调用 g_vm_interface.io_write()。
 */
int io_mapping_write_all(IOMappingTable *table, const VM *vm);

/**
 * io_mapping_cycle - 执行完整 I/O 扫描周期
 * @param table I/O 映射表
 * @param vm    VM 实例
 * @return 0 = 成功, 负值 = 错误
 *
 * 等效于依次调用 io_mapping_read_all() → vm_run() → io_mapping_write_all()。
 */
int io_mapping_cycle(IOMappingTable *table, VM *vm);

/**
 * io_mapping_get_channel - 按通道 ID 查找映射条目
 * @param table      I/O 映射表
 * @param channel_id 物理通道 ID
 * @return 指向 IOMapEntryRuntime 的指针, NULL = 未找到
 */
IOMapEntryRuntime *io_mapping_get_channel(IOMappingTable *table,
                                           uint32_t channel_id);

/**
 * io_mapping_get_by_name - 按 ST 变量名查找映射条目
 * @param table    I/O 映射表
 * @param var_name ST 变量名
 * @return 指向 IOMapEntryRuntime 的指针, NULL = 未找到
 */
IOMapEntryRuntime *io_mapping_get_by_name(IOMappingTable *table,
                                           const char *var_name);

/**
 * io_mapping_safety_check - 安全限值检查
 * @param entry I/O 映射条目
 * @param value 待检查的工程值
 * @return true = 通过检查, false = 超出限值
 */
bool io_mapping_safety_check(const IOMapEntryRuntime *entry, int32_t value);

/**
 * io_mapping_eng_to_raw - 工程值转原始值
 * @param entry   I/O 映射条目
 * @param eng_val 工程值
 * @return 原始值
 */
int32_t io_mapping_eng_to_raw(const IOMapEntryRuntime *entry, int32_t eng_val);

/**
 * io_mapping_raw_to_eng - 原始值转工程值
 * @param entry    I/O 映射条目
 * @param raw_val  原始值
 * @return 工程值
 */
int32_t io_mapping_raw_to_eng(const IOMapEntryRuntime *entry, int32_t raw_val);

/**
 * io_mapping_reset - 重置 I/O 映射表状态
 * @param table I/O 映射表
 */
void io_mapping_reset(IOMappingTable *table);

#ifdef __cplusplus
}
#endif

#endif /* IO_MAPPING_H */
