/**
 * rtos/rtthread/vm_rtthread.h
 * RT-Thread 适配层 — 公共头文件
 *
 * 将 SafeASM VM 作为 RT-Thread 应用程序运行。
 * 提供系统初始化和线程创建接口。
 */

#ifndef VM_RTTHREAD_H
#define VM_RTTHREAD_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ================================================================
   线程优先级定义
   ================================================================
 * RT-Thread 优先级范围: 0 (最高) ~ RT_THREAD_PRIORITY_MAX-1 (最低)
 * 以下值基于默认 RT_THREAD_PRIORITY_MAX = 32
 */

#define VM_THREAD_PRIO_IO        8   /* I/O 驱动线程 (高优先级) */
#define VM_THREAD_PRIO_MAIN     16   /* VM 主线程 (中优先级) */
#define VM_THREAD_PRIO_WATCHDOG 24   /* 看门狗线程 (低优先级) */

/* ================================================================
   栈大小定义
   ================================================================ */

#define VM_THREAD_STACK_IO       2048  /* I/O 线程栈 */
#define VM_THREAD_STACK_MAIN     4096  /* VM 主线程栈 */
#define VM_THREAD_STACK_WATCHDOG 1024  /* 看门狗线程栈 */

/* ================================================================
   扫描周期配置
   ================================================================ */

#define VM_SCAN_CYCLE_MS         100   /* 默认扫描周期 100ms */
#define VM_WATCHDOG_TIMEOUT_MS   1000  /* 看门狗超时 1000ms */
#define VM_WATCHDOG_CHECK_MS     200   /* 看门狗检查间隔 200ms */

/* ================================================================
   VM 平台配置结构体
   ================================================================ */

typedef struct {
    /* 线程配置 */
    uint32_t io_thread_priority;
    uint32_t io_thread_stack_size;
    uint32_t vm_thread_priority;
    uint32_t vm_thread_stack_size;
    uint32_t wdt_thread_priority;
    uint32_t wdt_thread_stack_size;

    /* 周期配置 */
    uint32_t scan_cycle_ms;          /* VM 扫描周期 (毫秒) */
    uint32_t watchdog_timeout_ms;    /* 看门狗超时 (毫秒) */
    uint32_t watchdog_check_ms;      /* 看门狗检查间隔 (毫秒) */

    /* I/O 配置 */
    uint32_t io_input_count;         /* 输入通道数 */
    uint32_t io_output_count;        /* 输出通道数 */
    const uint32_t *io_channel_ids;  /* 通道 ID 列表 (可选) */

    /* .sasm 模块数据 (由加载器填充) */
    const uint8_t *sasm_data;        /* .sasm 二进制数据指针 */
    uint32_t       sasm_len;         /* .sasm 数据长度 */
} VMPlatformConfig;

/* ================================================================
   默认配置
   ================================================================ */

#define VM_PLATFORM_CONFIG_DEFAULT { \
    .io_thread_priority    = VM_THREAD_PRIO_IO, \
    .io_thread_stack_size  = VM_THREAD_STACK_IO, \
    .vm_thread_priority    = VM_THREAD_PRIO_MAIN, \
    .vm_thread_stack_size  = VM_THREAD_STACK_MAIN, \
    .wdt_thread_priority   = VM_THREAD_PRIO_WATCHDOG, \
    .wdt_thread_stack_size = VM_THREAD_STACK_WATCHDOG, \
    .scan_cycle_ms         = VM_SCAN_CYCLE_MS, \
    .watchdog_timeout_ms   = VM_WATCHDOG_TIMEOUT_MS, \
    .watchdog_check_ms     = VM_WATCHDOG_CHECK_MS, \
    .io_input_count        = 0, \
    .io_output_count       = 0, \
    .io_channel_ids        = NULL, \
    .sasm_data             = NULL, \
    .sasm_len              = 0, \
}

/* ================================================================
   函数接口
   ================================================================ */

/**
 * vm_rtthread_init - 初始化 RT-Thread 适配层
 * @param config 平台配置 (传 NULL 使用默认配置)
 * @return 0 = 成功, -1 = 失败
 *
 * 执行以下操作:
 *   1. 填充 g_vm_interface 函数指针表
 *   2. 加载并验证 .sasm 模块
 *   3. 初始化 I/O 映射表
 *   4. 创建 I/O 驱动线程 / VM 主线程 / 看门狗线程
 *   5. 启动 RT-Thread 调度
 */
int vm_rtthread_init(const VMPlatformConfig *config);

/**
 * vm_rtthread_start - 启动 VM 扫描周期
 * @return 0 = 成功, -1 = 失败
 *
 * 发出启动信号量，三个线程开始按周期运行。
 */
int vm_rtthread_start(void);

/**
 * vm_rtthread_stop - 停止 VM 扫描周期
 * @return 0 = 成功, -1 = 失败
 */
int vm_rtthread_stop(void);

/**
 * vm_rtthread_get_stats - 获取 VM 运行统计
 * @return 指向 VMRunStats 的指针
 */
const VMRunStats *vm_rtthread_get_stats(void);

#ifdef __cplusplus
}
#endif

#endif /* VM_RTTHREAD_H */
