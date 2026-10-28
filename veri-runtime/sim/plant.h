/**
 * sim/plant.h
 * 被控对象（plant）模型 — 仿真后端的物理侧
 *
 * `.plant` 文件契约（G0 产出物 3，唯一运行契约；工程源 YAML 属 G1）：
 *
 *   一行一个通道，9 个空白分隔字段，字段顺序固定：
 *     channel  dir  kind  gain  offset  min  max  init  drive
 *   '#' 开头为注释行，空行忽略；不允许行续写。
 *
 *   channel : 通道 ID，0 .. IO_MAX_CHANNELS-1，表内唯一
 *   dir     : INPUT | OUTPUT
 *   kind    : CONST | LAG | RAMP | ACTUATOR
 *   gain    : 小数。LAG 为离散步进系数 (0,1]；RAMP 为每周期增量
 *   offset  : 小数。LAG 的附加目标偏置；其余 kind 忽略
 *   min/max : 整数物理上下限（raw 单位），min <= max
 *   init    : 整数初值，必须落在 [min,max]
 *   drive   : 驱动本通道的 OUTPUT 通道 ID，或 -1（无驱动）；只有 LAG 可用
 *
 *   数值一律是 raw 单位 —— 即 io_read/io_write 交换的那一层。IOMAP 段
 *   的 scale/bias 由映射层负责 raw <-> 工程值，两者互不重复。
 *
 * 动态模型（每个扫描周期调用一次 plant_step，先读后写顺序由映射层固定）：
 *   CONST    状态恒为 init（无驱动、无动态，用作设定值/开关量）
 *   RAMP     state += gain
 *   LAG      target = (drive >= 0 ? 驱动通道状态 : 0)
 *            state += gain * (target + offset - state)
 *   ACTUATOR dir=OUTPUT 专用：io_write 记录执行器位置，无自主动态
 *   三种输入模型步进后统一钳位到 [min,max]。
 *
 * 确定性：步进只读执行器（OUTPUT）状态与自身上一周期状态，输入通道之间
 * 无耦合 —— 因此行序、通道序都不影响结果，黄金时间线可比对。
 *
 * 安全约束：禁止动态内存（静态表）、所有访问带边界检查、解析失败即拒绝启动。
 */

#ifndef SIM_PLANT_H
#define SIM_PLANT_H

#include <stdint.h>
#include <stddef.h>

#include "../io/io_mapping.h"

#ifdef __cplusplus
extern "C" {
#endif

#define PLANT_MAX_CHANNELS  IO_MAX_CHANNELS  /* 64，与映射层容量对齐 */
#define PLANT_LINE_MAX      128U
#define PLANT_FIELDS        9U

/* kind 编码 */
#define PLANT_KIND_CONST     0U
#define PLANT_KIND_LAG       1U
#define PLANT_KIND_RAMP      2U
#define PLANT_KIND_ACTUATOR  3U

#define PLANT_NO_DRIVE       (-1)

typedef struct {
    uint32_t channel_id;
    uint8_t  direction;     /* IO_DIR_INPUT / IO_DIR_OUTPUT */
    uint8_t  kind;          /* PLANT_KIND_* */
    double   gain;
    double   offset;
    int32_t  min_value;
    int32_t  max_value;
    int32_t  init_value;
    double   state;         /* 当前 raw 值（双精度累加，读出时截断） */
    int32_t  drive;         /* 驱动通道 ID，PLANT_NO_DRIVE = 无 */
} PlantChannel;

typedef struct {
    PlantChannel channels[PLANT_MAX_CHANNELS];
    uint32_t     count;
} PlantTable;

/**
 * plant_load - 解析并校验 .plant 文件
 * @param table [out] 被控对象表
 * @param path  文件路径
 * @return 0 = 成功, -1 = 失败（stderr 给出行号与原因）
 */
int plant_load(PlantTable *table, const char *path);

/**
 * plant_step - 全部输入通道向前推进一个扫描周期
 * @param table 被控对象表
 */
void plant_step(PlantTable *table);

/**
 * plant_find - 按通道 ID 查找表项
 * @return 指向 PlantChannel 的指针, NULL = 未找到
 */
PlantChannel *plant_find(const PlantTable *table, uint32_t channel_id);

/**
 * plant_read_raw - 读取通道当前 raw 值（传感器输出）
 * @return 0 = 成功, -1 = 通道不存在
 */
int plant_read_raw(const PlantTable *table, uint32_t channel_id, int32_t *value);

/**
 * plant_write_raw - 记录执行器收到的 raw 值（actuator 状态）
 * @return 0 = 成功, -1 = 通道不存在或方向不是 OUTPUT
 */
int plant_write_raw(PlantTable *table, uint32_t channel_id, int32_t value);

#ifdef __cplusplus
}
#endif

#endif /* SIM_PLANT_H */
