/**
 * rtos/abstract.h
 * RTOS 抽象层 — VM_Interface 结构体定义
 *
 * 定义 SafeASM 虚拟机与底层 RTOS 之间的标准接口。
 * 任何 RTOS 适配层（如 RT-Thread）需实现此接口中的所有函数指针。
 *
 * 设计原则:
 *   - 纯 C11 标准，无 RTOS 特定依赖
 *   - 所有接口返回 int，0 = 成功，负值 = 错误码
 *   - 禁止动态内存分配，所有缓冲区由上层提供
 *   - 支持双机热备所需的 snapshot/restore 接口
 */

#ifndef RTOS_ABSTRACT_H
#define RTOS_ABSTRACT_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ================================================================
   I/O 通道方向与类型常量
   ================================================================ */

#define IO_DIR_INPUT    0   /* 输入通道 */
#define IO_DIR_OUTPUT   1   /* 输出通道 */

#define IO_TYPE_AI      0   /* 模拟量输入 (Analog Input) */
#define IO_TYPE_AO      1   /* 模拟量输出 (Analog Output) */
#define IO_TYPE_DI      2   /* 数字量输入 (Digital Input) */
#define IO_TYPE_DO      3   /* 数字量输出 (Digital Output) */

/* ================================================================
   I/O 通道描述符
   ================================================================ */

typedef struct {
    uint32_t channel_id;         /* 物理通道 ID */
    uint8_t  direction;          /* IO_DIR_INPUT 或 IO_DIR_OUTPUT */
    uint8_t  io_type;            /* IO_TYPE_AI/AO/DI/DO */
    uint32_t bit_width;          /* 位宽 (8/16/32) */
    double   scale_factor;       /* 缩放因子 (用于工程值转换) */
    double   bias;               /* 偏置 */
    int32_t  safety_limit_low;   /* 安全下限 */
    int32_t  safety_limit_high;  /* 安全上限 */
    uint32_t mem_offset;         /* VM 线性内存中的偏移地址 */
    char     var_name[64];       /* ST 变量名 (调试用) */
} IOChannelDesc;

/* ================================================================
   VM 运行统计
   ================================================================ */

typedef struct {
    uint32_t cycle_count;        /* 已执行的扫描周期数 */
    uint32_t last_cycle_ticks;   /* 上一周期执行时间 (tick) */
    uint32_t max_cycle_ticks;    /* 最大周期执行时间 (tick) */
    uint32_t io_read_errors;     /* I/O 读错误计数 */
    uint32_t io_write_errors;    /* I/O 写错误计数 */
    int      last_error;         /* 末次错误码 */
    bool     is_running;         /* VM 是否正在运行 */
    bool     is_standby;         /* 是否处于备用状态 (热备) */
} VMRunStats;

/* ================================================================
   VM_Interface — RTOS 抽象接口
   ================================================================
 *
 * 每个函数指针代表一个 RTOS 原语操作。
 * 适配层需在系统初始化时填充此结构体实例。
 */

typedef struct {

    /* ---------- 生命周期管理 ---------- */

    /**
     * init - RTOS 及硬件初始化
     * @param config 指向平台特定配置数据的指针 (可为 NULL)
     * @return 0 = 成功, -1 = 失败
     */
    int (*init)(void *config);

    /**
     * deinit - 去初始化，释放所有 RTOS 资源
     */
    void (*deinit)(void);

    /* ---------- 线程/任务管理 ---------- */

    /**
     * create_thread - 创建 RTOS 线程
     * @param name       线程名称
     * @param entry      线程入口函数
     * @param arg        传递给入口函数的参数
     * @param stack_size 栈大小 (字节)
     * @param priority   优先级 (平台相关)
     * @param tick       时间片 (tick，0 为默认)
     * @return 线程句柄 (void*), NULL = 失败
     */
    void *(*create_thread)(const char *name,
                           void (*entry)(void *arg),
                           void *arg,
                           uint32_t stack_size,
                           uint32_t priority,
                           uint32_t tick);

    /**
     * sleep - 当前线程睡眠指定 tick
     * @param ticks 休眠时长 (tick)
     */
    void (*sleep)(uint32_t ticks);

    /* ---------- 同步原语 ---------- */

    /**
     * sem_create - 创建二值信号量
     * @param name 信号量名称
     * @param init 初始值 (0 = 不可用, 1 = 可用)
     * @return 信号量句柄 (void*), NULL = 失败
     */
    void *(*sem_create)(const char *name, uint32_t init);

    /**
     * sem_take - 获取信号量 (阻塞)
     * @param sem    信号量句柄
     * @param timeout 超时时间 (tick, 0xFFFFFFFF = 永远等待)
     * @return 0 = 成功, -1 = 超时
     */
    int (*sem_take)(void *sem, uint32_t timeout);

    /**
     * sem_release - 释放信号量
     * @param sem 信号量句柄
     * @return 0 = 成功, -1 = 失败
     */
    int (*sem_release)(void *sem);

    /**
     * sem_delete - 删除信号量
     * @param sem 信号量句柄
     */
    void (*sem_delete)(void *sem);

    /**
     * mutex_create - 创建互斥锁
     * @param name 互斥锁名称
     * @return 互斥锁句柄 (void*), NULL = 失败
     */
    void *(*mutex_create)(const char *name);

    /**
     * mutex_lock - 获取互斥锁 (阻塞)
     * @param mutex 互斥锁句柄
     * @param timeout 超时时间 (tick)
     * @return 0 = 成功, -1 = 超时
     */
    int (*mutex_lock)(void *mutex, uint32_t timeout);

    /**
     * mutex_unlock - 释放互斥锁
     * @param mutex 互斥锁句柄
     * @return 0 = 成功, -1 = 失败
     */
    int (*mutex_unlock)(void *mutex);

    /**
     * mutex_delete - 删除互斥锁
     * @param mutex 互斥锁句柄
     */
    void (*mutex_delete)(void *mutex);

    /* ---------- I/O 设备操作 ---------- */

    /**
     * io_read - 从物理 I/O 通道读取原始值
     * @param channel_id 物理通道 ID
     * @param value      [out] 读取到的原始值
     * @return 0 = 成功, -1 = 失败
     */
    int (*io_read)(uint32_t channel_id, int32_t *value);

    /**
     * io_write - 向物理 I/O 通道写入原始值
     * @param channel_id 物理通道 ID
     * @param value      要写入的原始值
     * @return 0 = 成功, -1 = 失败
     */
    int (*io_write)(uint32_t channel_id, int32_t value);

    /**
     * io_group_read - 批量读取一组 I/O 通道
     * @param channel_ids 通道 ID 数组
     * @param values      [out] 读取到的值数组
     * @param count       通道数量
     * @return 0 = 全部成功, 负值 = 错误码 (部分失败时停止)
     */
    int (*io_group_read)(const uint32_t *channel_ids,
                         int32_t *values, uint32_t count);

    /**
     * io_group_write - 批量写入一组 I/O 通道
     * @param channel_ids 通道 ID 数组
     * @param values      要写入的值数组
     * @param count       通道数量
     * @return 0 = 全部成功, 负值 = 错误码
     */
    int (*io_group_write)(const uint32_t *channel_ids,
                          const int32_t *values, uint32_t count);

    /* ---------- 定时器 ---------- */

    /**
     * timer_create - 创建周期定时器
     * @param name    定时器名称
     * @param timeout 超时时间 (tick)
     * @param reload  是否自动重载
     * @param handler 超时回调函数
     * @param arg     传递给回调的参数
     * @return 定时器句柄 (void*), NULL = 失败
     */
    void *(*timer_create)(const char *name,
                          uint32_t timeout,
                          bool reload,
                          void (*handler)(void *arg),
                          void *arg);

    /**
     * timer_start - 启动定时器
     * @param timer 定时器句柄
     * @return 0 = 成功, -1 = 失败
     */
    int (*timer_start)(void *timer);

    /**
     * timer_stop - 停止定时器
     * @param timer 定时器句柄
     * @return 0 = 成功, -1 = 失败
     */
    int (*timer_stop)(void *timer);

    /**
     * timer_delete - 删除定时器
     * @param timer 定时器句柄
     */
    void (*timer_delete)(void *timer);

    /**
     * get_ticks - 获取当前系统 tick 计数值
     * @return 当前 tick 计数
     */
    uint32_t (*get_ticks)(void);

    /* ---------- 时间相关 ---------- */

    /**
     * ticks_to_ms - 将 tick 转换为毫秒
     * @param ticks tick 数
     * @return 对应的毫秒数
     */
    uint32_t (*ticks_to_ms)(uint32_t ticks);

    /**
     * ms_to_ticks - 将毫秒转换为 tick
     * @param ms 毫秒数
     * @return 对应的 tick 数
     */
    uint32_t (*ms_to_ticks)(uint32_t ms);

    /* ---------- 临界区保护 ---------- */

    /**
     * enter_critical - 进入临界区 (禁止调度)
     * @return 先前的中断状态 (用于匹配 exit_critical)
     */
    uint32_t (*enter_critical)(void);

    /**
     * exit_critical - 退出临界区 (恢复调度)
     * @param level 由 enter_critical 返回的中断状态
     */
    void (*exit_critical)(uint32_t level);

} VM_Interface;

/* ================================================================
   全局 VM_Interface 实例 (由适配层在初始化时赋值)
   ================================================================ */

extern VM_Interface g_vm_interface;

#ifdef __cplusplus
}
#endif

#endif /* RTOS_ABSTRACT_H */
