/**
 * sim/watch.h
 * watch 帧 —— G0 产出物 4：把「某个变量此刻是多少」送到 stdout
 *
 * 帧协议（唯一源 spec/simulation-spec.md §4；决策 D4：stdout JSONL，不上 socket）：
 *
 *   周期帧（一周期一行）：
 *     {"frame":"cycle","cycle":12,"t_ms":1100,"status":0,"violations":0,
 *      "values":[{"name":"pv","addr":4100,"type":"DINT","size":4,
 *                 "value":625,"channel":0,"raw":625}, ...]}
 *   收尾帧（流末恰好一行，消费者据此判定正常结束）：
 *     {"frame":"done","cycles":12,"t_ms":1200,"violations":0,
 *      "read_errors":0,"write_errors":0}
 *
 *   行序 = 命令行 --watch 的书写顺序，逐周期不变 ⇒ 前端可按列下标取数。
 *   每个 values 元素固定 8 个键（v0.3 起）：
 *     name     : 符号名原文（含派生名 实例#字段，来自段 7）
 *     addr     : 十进制线性内存偏移 —— 与 `svm -l` 报的同一个地址
 *     type     : 段 7 类型名（DINT / BOOL / REAL ...）
 *     size     : 槽位字节数；单字布局下恒为 4
 *     value    : 该地址处按类型解码后的内存内容，即**程序看到的量**
 *     channel  : 绑定的 I/O 通道号；非 I/O 绑定为 null
 *     raw      : 该通道上一周期与物理侧交换的原始值；非 I/O 绑定为 null
 *     forced   : 本周期该符号被激励/强制覆盖（sim/force.h，协议 §5）
 *
 *   value 与 raw 的分工：映射层写进内存的是工程值，读走的是原始值，
 *   所以 I/O 绑定符号的 value 是工程量、raw 是物理量；scale/bias 为 1/0 时两者相等。
 *   未绑定的符号（中间量、实例字段）没有通道概念，channel/raw 恒为 null。
 *   非标量（ARRAY / FB）与 64 位类型（一个全局槽只有一个 int32 单字）在启动时拒绝。
 *
 *   stdout 在 watch 模式下是复用的：程序自身的 PRINT 端口输出也会落在 stdout。
 *   帧行一律以 {"frame": 起始 ⇒ 消费者按该前缀过滤，非帧行属于被编译程序的跟踪输出，
 *   不在帧协议之内。
 *
 * 顶层键 cycle/t_ms/status/violations：
 *   status     : 本周期 io_mapping_cycle() 返回值（0 = 成功）
 *   violations : 越限钳位累计次数（映射层只钳位不跳闸，此处透给上位工具）
 *
 * 安全约束：只读 —— 不写 vm->memory；地址一律带 memory_size 边界检查；
 * 未知/非标量符号名在启动时即拒绝，不留「符号不存在」与「值为 0」的歧义。
 * 写入不在这里发生：激励与强制见 sim/force.h 与 spec/simulation-spec.md §5。
 */

#ifndef SIM_WATCH_H
#define SIM_WATCH_H

#include <stdint.h>

#include "../core/sasm_info.h"
#include "../core/vm.h"
#include "../io/io_mapping.h"

#ifdef __cplusplus
extern "C" {
#endif

#define WATCH_MAX_NAMES 16U
#define WATCH_NAME_MAX  IO_NAME_MAX   /* 64，与映射层的名字容量对齐 */

/* 一个全局槽恒是 4 字节单字（global_codegen 的 assign_global_offsets 每个声明
   +4），帧的读与激励的写共用这个宽度。 */
#define WATCH_SLOT_BYTES 4U

/* 段 7 type_tag 的解码类 —— 读（帧）与写（激励）必须走同一张表，
   否则「按类型写进去的」与「按类型读出来的」会各自解释一遍。 */
#define WATCH_CL_I32   0U   /* 有符号 32 位 */
#define WATCH_CL_U32   1U   /* 无符号 32 位（BOOL 亦在此） */
#define WATCH_CL_I64   2U   /* 单字槽装不下：启动即拒 */
#define WATCH_CL_F32   3U   /* 单精度 */
#define WATCH_CL_F64   4U   /* 同上，启动即拒 */
#define WATCH_CL_NOVAL 5U   /* ARRAY / FB：没有「一个值」可读 */

/**
 * watch_class_of - 段 7 type_tag -> 解码类（未知 tag 归入 NOVAL）
 */
uint8_t watch_class_of(uint8_t type_tag);

typedef struct {
    char     name[WATCH_NAME_MAX];
    uint32_t addr;
    uint8_t  type_tag;
    uint8_t  size;
    const char *type_name;
    int32_t  entry;        /* 映射表条目下标；-1 = 非 I/O 绑定 */
} WatchVar;

typedef struct {
    WatchVar vars[WATCH_MAX_NAMES];
    uint32_t count;
} WatchSet;

/**
 * watch_build - 拆分名字表并按段 7 解析地址，顺带绑定 I/O 通道
 * @param set   [out] 监视集合
 * @param csv   逗号分隔的符号名（派生名写法与 svm -s 一致）
 * @param buf   .sasm 镜像（已读入内存）
 * @param len   镜像长度
 * @param iomap 已初始化的映射表，用于回填 channel
 * @param vm    已初始化的 VM，用于槽位地址的内存边界校验
 * @return 0 = 成功, -1 = 拒绝启动（stderr 给出名字与原因）
 */
int watch_build(WatchSet *set, const char *csv, const uint8_t *buf,
                uint32_t len, const IOMappingTable *iomap, const VM *vm);

/**
 * watch_cycle_frame - 打印一帧周期数据
 * @param status io_mapping_cycle() 的返回值
 * @param forced 每列一个字节，非 0 即本周期被激励覆盖（协议 §5.6）；可为 NULL
 */
void watch_cycle_frame(const WatchSet *set, const VM *vm,
                       const IOMappingTable *iomap, const uint8_t *forced,
                       uint32_t cycle, uint32_t t_ms, int status);

/**
 * watch_done_frame - 打印收尾帧
 */
void watch_done_frame(uint32_t cycles, const IOMappingTable *iomap,
                      uint32_t t_ms);

#ifdef __cplusplus
}
#endif

#endif /* SIM_WATCH_H */
