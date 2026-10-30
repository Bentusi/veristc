/**
 * sim/force.h
 * 激励与强制 —— 让仿真里的某个值来自程序之外（spec/simulation-spec.md §5，v0.3）
 *
 * 两个入口，一张表：
 *   --force name=value,...   立即强制，自周期 1 起生效并保持
 *   --script FILE            周期脚本，一行一条 (cycle, name, value)
 *
 * 落点只有一条规则（协议 §5.3），由符号地址与映射方向决定，上位工具无从猜：
 *   I/O 绑定且方向 INPUT  -> 被控对象通道状态（raw），在 io_mapping_read_all() 之前写
 *   其余（中间量/实例字段/OUTPUT 绑定） -> 段 7 的全局槽位，在 vm_run() 之后、
 *                                        io_mapping_write_all() 之前写
 * 于是"引脚显示什么，下游本周期就读到什么"：激活期间每周期重新钉住目标，
 * 程序算出的结果被丢弃 —— 只写一次的话，下一周期就被同一块的算法改回去了。
 *
 *   1  cycle PV 250          # 自第 1 周期起把 PV 的通道钉在 raw 250
 *   5  rs1#Q FALSE            # 第 5 周期起把该实例输出强制为 FALSE
 *
 * 安全约束：禁止动态内存（静态表）、所有访问带边界检查、任何不符即拒绝启动
 * （协议 §5.5 的十类拒绝），不留「符号不存在」与「值为 0」的歧义。
 */

#ifndef SIM_FORCE_H
#define SIM_FORCE_H

#include <stdint.h>

#include "../core/vm.h"
#include "../io/io_mapping.h"
#include "plant.h"
#include "watch.h"

#ifdef __cplusplus
extern "C" {
#endif

#define FORCE_MAX_TARGETS 64U   /* 去重后的名字数，与 WATCH_MAX_NAMES 同量级 */
#define FORCE_MAX_RECORDS 64U   /* 协议 §5.4 */
#define FORCE_FIELDS      3U
#define FORCE_LINE_MAX    PLANT_LINE_MAX

typedef struct {
    char     name[WATCH_NAME_MAX];
    uint32_t addr;              /* 段 7 给出的全局槽位地址 */
    uint8_t  cls;               /* watch 的类型类：I32 / U32 / F32 */
    uint8_t  from_cli;          /* 来源：--force（否则 = 脚本） */
    int32_t  channel;           /* >=0：注入该 INPUT 通道；-1：写全局槽位 */
    uint32_t rec_first;         /* records[] 中本名字的起点（排序后连续） */
    uint32_t rec_count;
    uint32_t rec_taken;         /* 已被周期越过的记录数 */
    int32_t  active;            /* 当前生效的记录下标，-1 = 尚未生效 */
} ForceTarget;

typedef struct {
    uint32_t cycle;             /* 生效周期，从 1 开始 */
    int32_t  target;            /* ForceTable.targets[] 下标 */
    uint32_t bits;              /* 内存落点：按 §5.1 编码好的 4 字节 */
    int32_t  raw;               /* 物理落点：通道 raw 整数值 */
} ForceRecord;

typedef struct {
    ForceTarget targets[FORCE_MAX_TARGETS];
    uint32_t    target_count;
    ForceRecord records[FORCE_MAX_RECORDS];
    uint32_t    record_count;
    uint8_t     active_count;   /* >0 表示这张表真的会动状态 */
} ForceTable;

/**
 * force_build - 解析并校验全部激励，按段 7 与对象表定好落点
 * @param table      [out] 激励表（无激励时 target_count = 0）
 * @param csv        --force 的 name=value 列表，可为 NULL
 * @param script     --script 的脚本路径，可为 NULL
 * @param cycles     -n 的周期数，用于校验记录不越过末尾
 * @param buf/len    .sasm 镜像，名字解析走段 7
 * @param iomap      已初始化的映射表，用于判定方向与取通道号
 * @param vm         已初始化的 VM，用于槽位地址边界校验
 * @param plant      已加载的被控对象表，注入落点与量程校验
 * @return 0 = 成功, -1 = 拒绝启动（stderr 给出名字与原因）
 */
int force_build(ForceTable *table, const char *csv, const char *script,
                uint32_t cycles, const uint8_t *buf, uint32_t len,
                const IOMappingTable *iomap, const VM *vm,
                const PlantTable *plant);

/**
 * force_begin_cycle - 把每个名字的激活记录推进到本周期
 * 每周期调用一次，且只调用一次：两个 apply 只读结果。
 */
void force_begin_cycle(ForceTable *table, uint32_t cycle);

/**
 * force_apply_plant - 把生效中的注入写到被控对象通道（周期起点，读入之前）
 */
void force_apply_plant(const ForceTable *table, PlantTable *plant);

/**
 * force_apply_memory - 把生效中的强制写到全局槽位（vm_run 之后，写回之前）
 */
void force_apply_memory(const ForceTable *table, VM *vm);

/**
 * force_is_forced - 本周期该符号是否被激励覆盖（帧上的 forced 标记）
 * @return 1 = 是, 0 = 否或表为空
 */
int force_is_forced(const ForceTable *table, const char *name);

#ifdef __cplusplus
}
#endif

#endif /* SIM_FORCE_H */
