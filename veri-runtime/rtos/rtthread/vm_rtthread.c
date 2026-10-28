/**
 * rtos/rtthread/vm_rtthread.c
 * RT-Thread 适配层实现
 *
 * 实现 VM_Interface 抽象接口，将 SafeASM VM 作为 RT-Thread 应用程序运行。
 *
 * 线程架构:
 *   ┌──────────────────────────────────────────────────┐
 *   │  I/O 驱动线程 (高优先级)                          │
 *   │  循环: io_mapping_read_all() → 发信号给 VM       │
 *   └───────────────┬──────────────────────────────────┘
 *                   │ 信号量 (io_sem)
 *                   ▼
 *   ┌──────────────────────────────────────────────────┐
 *   │  VM 主线程 (中优先级)                             │
 *   │  等待信号 → vm_run() → 发信号给 I/O              │
 *   └───────────────┬──────────────────────────────────┘
 *                   │ 信号量 (vm_sem)
 *                   ▼
 *   ┌──────────────────────────────────────────────────┐
 *   │  I/O 驱动线程 (续)                               │
 *   │  io_mapping_write_all() → 睡眠至下一周期          │
 *   └──────────────────────────────────────────────────┘
 *
 *   看门狗线程独立运行，周期检查 VM 健康状态。
 */

#include "vm_rtthread.h"
#include "../../core/vm.h"
#include "../../core/loader.h"
#include "../../io/io_mapping.h"
#include "../../rtos/abstract.h"

#include <rtthread.h>
#include <string.h>

/* ================================================================
   RTOS 抽象接口实现 (VM_Interface)
   ================================================================ */

static int rtthread_init(void *config)
{
    /* RT-Thread 的 BSP 初始化由 startup 完成，此处仅做应用层初始化 */
    (void)config;
    return 0;
}

static void rtthread_deinit(void)
{
    /* RT-Thread 应用中通常不需要反初始化 */
}

static void *rtthread_create_thread(const char *name,
                                     void (*entry)(void *arg),
                                     void *arg,
                                     uint32_t stack_size,
                                     uint32_t priority,
                                     uint32_t tick)
{
    rt_thread_t thread = rt_thread_create(name,
                                          entry,
                                          arg,
                                          stack_size,
                                          priority,
                                          tick);
    if (thread) {
        rt_thread_startup(thread);
    }
    return (void *)thread;
}

static void rtthread_sleep(uint32_t ticks)
{
    rt_thread_delay(ticks);
}

static void *rtthread_sem_create(const char *name, uint32_t init)
{
    return (void *)rt_sem_create(name, init, RT_IPC_FLAG_FIFO);
}

static int rtthread_sem_take(void *sem, uint32_t timeout)
{
    rt_err_t ret = rt_sem_take((rt_sem_t)sem, timeout);
    return (ret == RT_EOK) ? 0 : -1;
}

static int rtthread_sem_release(void *sem)
{
    rt_err_t ret = rt_sem_release((rt_sem_t)sem);
    return (ret == RT_EOK) ? 0 : -1;
}

static void rtthread_sem_delete(void *sem)
{
    rt_sem_delete((rt_sem_t)sem);
}

static void *rtthread_mutex_create(const char *name)
{
    return (void *)rt_mutex_create(name, RT_IPC_FLAG_FIFO);
}

static int rtthread_mutex_lock(void *mutex, uint32_t timeout)
{
    rt_err_t ret = rt_mutex_take((rt_mutex_t)mutex, timeout);
    return (ret == RT_EOK) ? 0 : -1;
}

static int rtthread_mutex_unlock(void *mutex)
{
    rt_err_t ret = rt_mutex_release((rt_mutex_t)mutex);
    return (ret == RT_EOK) ? 0 : -1;
}

static void rtthread_mutex_delete(void *mutex)
{
    rt_mutex_delete((rt_mutex_t)mutex);
}

/* I/O 设备操作 — 使用 RT-Thread 设备框架 */

static int rtthread_io_read(uint32_t channel_id, int32_t *value)
{
    char dev_name[16];
    rt_snprintf(dev_name, sizeof(dev_name), "io_chn%d", channel_id);

    rt_device_t dev = rt_device_find(dev_name);
    if (!dev) return -1;

    rt_size_t ret = rt_device_read(dev, 0, value, sizeof(int32_t));
    return (ret == sizeof(int32_t)) ? 0 : -1;
}

static int rtthread_io_write(uint32_t channel_id, int32_t value)
{
    char dev_name[16];
    rt_snprintf(dev_name, sizeof(dev_name), "io_chn%d", channel_id);

    rt_device_t dev = rt_device_find(dev_name);
    if (!dev) return -1;

    rt_size_t ret = rt_device_write(dev, 0, &value, sizeof(int32_t));
    return (ret == sizeof(int32_t)) ? 0 : -1;
}

/* 批量 I/O — 逐个操作 (RT-Thread 设备框架未提供批量接口) */

static int rtthread_io_group_read(const uint32_t *channel_ids,
                                   int32_t *values, uint32_t count)
{
    if (!channel_ids || !values) return -1;

    for (uint32_t i = 0; i < count; i++) {
        if (rtthread_io_read(channel_ids[i], &values[i]) != 0) {
            return -1;
        }
    }
    return 0;
}

static int rtthread_io_group_write(const uint32_t *channel_ids,
                                    const int32_t *values, uint32_t count)
{
    if (!channel_ids || !values) return -1;

    for (uint32_t i = 0; i < count; i++) {
        if (rtthread_io_write(channel_ids[i], values[i]) != 0) {
            return -1;
        }
    }
    return 0;
}

/* 定时器 */

struct rtthread_timer_wrapper {
    void (*handler)(void *arg);
    void *arg;
};

static void rtthread_timer_callback(void *parameter)
{
    struct rtthread_timer_wrapper *wrapper =
        (struct rtthread_timer_wrapper *)parameter;
    if (wrapper && wrapper->handler) {
        wrapper->handler(wrapper->arg);
    }
}

static void *rtthread_timer_create(const char *name,
                                    uint32_t timeout,
                                    bool reload,
                                    void (*handler)(void *arg),
                                    void *arg)
{
    struct rtthread_timer_wrapper *wrapper =
        (struct rtthread_timer_wrapper *)
            rt_malloc(sizeof(struct rtthread_timer_wrapper));
    if (!wrapper) return NULL;

    wrapper->handler = handler;
    wrapper->arg = arg;

    rt_timer_t timer = rt_timer_create(name,
                                       rtthread_timer_callback,
                                       wrapper,
                                       timeout,
                                       reload ? RT_TIMER_FLAG_PERIODIC
                                              : RT_TIMER_FLAG_ONE_SHOT);
    if (!timer) {
        rt_free(wrapper);
        return NULL;
    }

    /* 将 wrapper 与计时器关联 (通过私有数据) */
    /* rt_timer 不提供用户数据指针，这里简化：使用全局数组管理 */
    return (void *)timer;
}

static int rtthread_timer_start(void *timer)
{
    rt_err_t ret = rt_timer_start((rt_timer_t)timer);
    return (ret == RT_EOK) ? 0 : -1;
}

static int rtthread_timer_stop(void *timer)
{
    rt_err_t ret = rt_timer_stop((rt_timer_t)timer);
    return (ret == RT_EOK) ? 0 : -1;
}

static void rtthread_timer_delete(void *timer)
{
    rt_timer_delete((rt_timer_t)timer);
}

static uint32_t rtthread_get_ticks(void)
{
    return rt_tick_get();
}

static uint32_t rtthread_ticks_to_ms(uint32_t ticks)
{
    return rt_tick_from_millisecond(ticks);
}

static uint32_t rtthread_ms_to_ticks(uint32_t ms)
{
    return rt_tick_from_millisecond(ms);
}

static uint32_t rtthread_enter_critical(void)
{
    rt_enter_critical();
    return 0;  /* RT-Thread 不支持嵌套临界区, 返回值无意义 */
}

static void rtthread_exit_critical(uint32_t level)
{
    (void)level;
    rt_exit_critical();
}

/* ================================================================
   全局 VM_Interface 实例
   ================================================================ */

VM_Interface g_vm_interface = {
    .init             = rtthread_init,
    .deinit           = rtthread_deinit,
    .create_thread    = rtthread_create_thread,
    .sleep            = rtthread_sleep,
    .sem_create       = rtthread_sem_create,
    .sem_take         = rtthread_sem_take,
    .sem_release      = rtthread_sem_release,
    .sem_delete       = rtthread_sem_delete,
    .mutex_create     = rtthread_mutex_create,
    .mutex_lock       = rtthread_mutex_lock,
    .mutex_unlock     = rtthread_mutex_unlock,
    .mutex_delete     = rtthread_mutex_delete,
    .io_read          = rtthread_io_read,
    .io_write         = rtthread_io_write,
    .io_group_read    = rtthread_io_group_read,
    .io_group_write   = rtthread_io_group_write,
    .timer_create     = rtthread_timer_create,
    .timer_start      = rtthread_timer_start,
    .timer_stop       = rtthread_timer_stop,
    .timer_delete     = rtthread_timer_delete,
    .get_ticks        = rtthread_get_ticks,
    .ticks_to_ms      = rtthread_ticks_to_ms,
    .ms_to_ticks      = rtthread_ms_to_ticks,
    .enter_critical   = rtthread_enter_critical,
    .exit_critical    = rtthread_exit_critical,
};

/* ================================================================
   平台全局状态
   ================================================================ */

static struct {
    VM               vm;
    SasmModule       module;
    IOMappingTable   iomap;
    VMPlatformConfig config;

    /* 同步原语 */
    rt_sem_t         io_sem;     /* I/O → VM 信号量 */
    rt_sem_t         vm_sem;     /* VM → I/O 信号量 */
    rt_sem_t         start_sem;  /* 启动信号量 */
    rt_mutex_t       stats_mutex; /* 统计信息互斥 */

    /* 运行状态 */
    volatile bool    running;
    volatile bool    started;
    VMRunStats       stats;
} s_platform;

/* ================================================================
   线程入口函数
   ================================================================ */

/* I/O 驱动线程 */
static void io_driver_thread_entry(void *arg)
{
    (void)arg;

    /* 等待启动信号 */
    rt_sem_take(s_platform.start_sem, RT_WAITING_FOREVER);

    while (s_platform.running) {
        uint32_t tick_start = rt_tick_get();

        /* 1. 读取所有输入通道 → 写入 VM 内存 */
        int io_ret = io_mapping_read_all(&s_platform.iomap, &s_platform.vm);
        if (io_ret != 0) {
            s_platform.stats.io_read_errors++;
        }

        /* 2. 通知 VM 线程执行 */
        rt_sem_release(s_platform.io_sem);

        /* 3. 等待 VM 执行完成 */
        rt_sem_take(s_platform.vm_sem, RT_WAITING_FOREVER);

        /* 4. 从 VM 内存读取输出 → 写入物理通道 */
        io_ret = io_mapping_write_all(&s_platform.iomap, &s_platform.vm);
        if (io_ret != 0) {
            s_platform.stats.io_write_errors++;
        }

        /* 5. 计算周期耗时，睡眠至下一周期 */
        uint32_t elapsed = rt_tick_get() - tick_start;
        uint32_t elapsed_ms = rt_tick_from_millisecond(elapsed);
        uint32_t sleep_ms = (elapsed_ms < s_platform.config.scan_cycle_ms)
                            ? s_platform.config.scan_cycle_ms - elapsed_ms
                            : 0;

        /* 更新统计 */
        s_platform.stats.last_cycle_ticks = elapsed;
        if (elapsed > s_platform.stats.max_cycle_ticks) {
            s_platform.stats.max_cycle_ticks = elapsed;
        }
        s_platform.stats.cycle_count++;

        if (sleep_ms > 0) {
            rt_thread_delay(rt_tick_from_millisecond(sleep_ms));
        }
    }
}

/* VM 主线程 */
static void vm_main_thread_entry(void *arg)
{
    (void)arg;

    /* 等待启动信号 */
    rt_sem_take(s_platform.start_sem, RT_WAITING_FOREVER);

    while (s_platform.running) {
        /* 等待 I/O 线程发来信号 (输入已就绪) */
        rt_sem_take(s_platform.io_sem, RT_WAITING_FOREVER);

        /* 执行 VM 扫描周期 */
        int ret = vm_run(&s_platform.vm);

        /* 更新错误状态 */
        if (ret != VM_OK) {
            s_platform.stats.last_error = ret;
        }

        /* 通知 I/O 线程 (输出可以写入) */
        rt_sem_release(s_platform.vm_sem);
    }
}

/* 看门狗线程 */
static void watchdog_thread_entry(void *arg)
{
    (void)arg;

    rt_sem_take(s_platform.start_sem, RT_WAITING_FOREVER);

    uint32_t last_cycle_count = 0;

    while (s_platform.running) {
        rt_thread_delay(rt_tick_from_millisecond(
            s_platform.config.watchdog_check_ms));

        /* 检查 VM 是否在推进周期 */
        if (s_platform.stats.cycle_count == last_cycle_count) {
            /* 周期未推进 — 可能死锁或挂起 */
            if (s_platform.stats.last_error != VM_OK) {
                /* VM 已处于错误状态，尝试恢复 */
                vm_init(&s_platform.vm,
                        &s_platform.module,
                        s_platform.module.total_memory_size);
                s_platform.stats.last_error = VM_OK;
            }
        }

        last_cycle_count = s_platform.stats.cycle_count;

        /* 更新运行状态 */
        s_platform.stats.is_running = s_platform.running;
    }
}

/* ================================================================
   公开接口实现
   ================================================================ */

int vm_rtthread_init(const VMPlatformConfig *config)
{
    memset(&s_platform, 0, sizeof(s_platform));

    /* 1. 使用默认配置或用户配置 */
    if (config) {
        s_platform.config = *config;
    } else {
        s_platform.config = (VMPlatformConfig)VM_PLATFORM_CONFIG_DEFAULT;
    }

    /* 2. 加载 .sasm 模块 */
    int ret = 0;
    if (s_platform.config.sasm_data && s_platform.config.sasm_len > 0) {
        ret = sasm_load(s_platform.config.sasm_data,
                            s_platform.config.sasm_len,
                            &s_platform.module);
        if (ret != 0) return -1;

        if (!sasm_validate(&s_platform.module)) return -1;
    }

    /* 3. 初始化 VM */
    ret = vm_init(&s_platform.vm,
                  &s_platform.module,
                  s_platform.module.total_memory_size);
    if (ret != 0) return -1;

    /* 4. 初始化 I/O 映射表 */
    ret = io_mapping_init(&s_platform.iomap,
                          &s_platform.module,
                          NULL, 0);  /* 无调试段 */
    if (ret != 0) return -1;

    /* 5. 创建同步原语 */
    s_platform.io_sem    = rt_sem_create("io_sem", 0, RT_IPC_FLAG_FIFO);
    s_platform.vm_sem    = rt_sem_create("vm_sem", 0, RT_IPC_FLAG_FIFO);
    s_platform.start_sem = rt_sem_create("start_sem", 0, RT_IPC_FLAG_FIFO);
    s_platform.stats_mutex = rt_mutex_create("stats_mutex", RT_IPC_FLAG_FIFO);

    if (!s_platform.io_sem || !s_platform.vm_sem ||
        !s_platform.start_sem || !s_platform.stats_mutex) {
        return -1;
    }

    /* 6. 创建线程 */
    s_platform.running = true;
    s_platform.stats.is_running = false;
    s_platform.stats.is_standby = false;

    rt_thread_t io_thread = rt_thread_create("io_drv",
                                              io_driver_thread_entry,
                                              NULL,
                                              s_platform.config.io_thread_stack_size,
                                              s_platform.config.io_thread_priority,
                                              10);
    if (io_thread) rt_thread_startup(io_thread);

    rt_thread_t vm_thread = rt_thread_create("vm_main",
                                              vm_main_thread_entry,
                                              NULL,
                                              s_platform.config.vm_thread_stack_size,
                                              s_platform.config.vm_thread_priority,
                                              10);
    if (vm_thread) rt_thread_startup(vm_thread);

    rt_thread_t wdt_thread = rt_thread_create("vm_wdt",
                                               watchdog_thread_entry,
                                               NULL,
                                               s_platform.config.wdt_thread_stack_size,
                                               s_platform.config.wdt_thread_priority,
                                              10);
    if (wdt_thread) rt_thread_startup(wdt_thread);

    return 0;
}

int vm_rtthread_start(void)
{
    if (s_platform.started) return 0;

    s_platform.running = true;
    s_platform.started = true;
    s_platform.stats.is_running = true;

    /* 释放所有启动信号量 (三个线程各一个) */
    rt_sem_release(s_platform.start_sem);
    rt_sem_release(s_platform.start_sem);
    rt_sem_release(s_platform.start_sem);

    return 0;
}

int vm_rtthread_stop(void)
{
    s_platform.running = false;
    s_platform.started = false;
    s_platform.stats.is_running = false;
    return 0;
}

const VMRunStats *vm_rtthread_get_stats(void)
{
    return &s_platform.stats;
}
