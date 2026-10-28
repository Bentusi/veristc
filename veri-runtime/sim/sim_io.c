/**
 * sim/sim_io.c
 * 软件 I/O + 虚拟时钟：把 VM_Interface 的调用落到被控对象表上
 *
 * 未安装后端或通道不在表内一律返回 -1 —— 映射层据此把通道标记故障并累加
 * read_errors/write_errors，仿真因此不会静默地"读到 0"。
 */

#include "sim_io.h"

#include "../rtos/abstract.h"

static PlantTable *s_plant;
static uint32_t s_period_ms;
static uint32_t s_ticks;

static int sim_init(void *config)
{
    (void)config;
    return (s_plant != NULL) ? 0 : -1;
}

static void sim_deinit(void)
{
    s_ticks = 0U;
}

static uint32_t sim_get_ticks(void)
{
    return s_ticks;
}

/* 虚拟时间：不触碰真实时钟，周期由主程序显式推进 */
static void sim_sleep(uint32_t ticks)
{
    (void)ticks;
}

static uint32_t sim_ms_to_ticks(uint32_t ms)
{
    return ms;
}

static uint32_t sim_ticks_to_ms(uint32_t ticks)
{
    return ticks;
}

static int sim_io_read(uint32_t channel_id, int32_t *value)
{
    if ((s_plant == NULL) || (value == NULL)) { return -1; }
    return plant_read_raw(s_plant, channel_id, value);
}

static int sim_io_write(uint32_t channel_id, int32_t value)
{
    if (s_plant == NULL) { return -1; }
    return plant_write_raw(s_plant, channel_id, value);
}

/* 由仿真主程序定义，映射层通过 abstract.h 的 extern 取用 */
VM_Interface g_vm_interface = { 0 };

void sim_io_install(PlantTable *table, uint32_t period_ms)
{
    s_plant = table;
    s_period_ms = period_ms;
    s_ticks = 0U;

    g_vm_interface.init = sim_init;
    g_vm_interface.deinit = sim_deinit;
    g_vm_interface.get_ticks = sim_get_ticks;
    g_vm_interface.sleep = sim_sleep;
    g_vm_interface.ms_to_ticks = sim_ms_to_ticks;
    g_vm_interface.ticks_to_ms = sim_ticks_to_ms;
    g_vm_interface.io_read = sim_io_read;
    g_vm_interface.io_write = sim_io_write;
}

void sim_io_advance(void)
{
    plant_step(s_plant);
    s_ticks += s_period_ms;
}

uint32_t sim_io_ticks(void)
{
    return s_ticks;
}
