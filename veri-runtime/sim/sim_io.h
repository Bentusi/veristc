/**
 * sim/sim_io.h
 * 仿真后端的 RTOS 抽象实现 —— VM_Interface 的软件替身
 *
 * 只填生产代码真正调用的 8 个指针（io_read / io_write / get_ticks / sleep /
 * ms_to_ticks / ticks_to_ms / init / deinit），其余留 NULL。理由见
 * plan/phase6-g0-technical-plan.md §4.1：io_group_* 零调用点，任务/同步原语
 * 只有 RT-Thread 移植需要，为未被调用的接口写代码属过度实现。
 *
 * 时间轴是**虚拟的**：sleep 不阻塞真实时钟，get_ticks 由仿真主程序在每个
 * 扫描周期后推进 period_ms。这样同一 (sasm, plant, 周期数) 必然产生同一
 * 时间线，黄金比对才有意义。
 */

#ifndef SIM_SIM_IO_H
#define SIM_SIM_IO_H

#include <stdint.h>

#include "plant.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * sim_io_install - 把软件 I/O 后端挂到 g_vm_interface 上
 * @param table      已加载的被控对象表
 * @param period_ms  一个扫描周期的仿真时长（tick 与毫秒 1:1）
 */
void sim_io_install(PlantTable *table, uint32_t period_ms);

/**
 * sim_io_advance - 推进一个扫描周期：被控对象动态 + 虚拟时钟
 */
void sim_io_advance(void);

/**
 * sim_io_ticks - 当前虚拟 tick 计数
 */
uint32_t sim_io_ticks(void);

#ifdef __cplusplus
}
#endif

#endif /* SIM_SIM_IO_H */
