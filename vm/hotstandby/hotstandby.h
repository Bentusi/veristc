/**
 * vm/hotstandby/hotstandby.h
 * 双机热备系统 — 公共头文件
 *
 * 实现安全级系统必需的双机冗余机制:
 *   1. 状态快照引擎 — 序列化 VM 完整状态
 *   2. 脏页追踪 — 仅同步变更的内存页
 *   3. 同步通信协议 — 主备间状态传输
 *   4. 主备状态机 — 故障检测 + 角色切换
 *   5. 增量下装 — 周期边界原子切换 + 回滚
 *   6. 无扰切换 — 输出值平滑过渡
 *
 * 安全约束:
 *   - 禁止动态内存分配
 *   - 所有数组访问带边界检查
 *   - 快照带 CRC32 校验
 */

#ifndef HOTSTANDBY_H
#define HOTSTANDBY_H

#include "../vm.h"
#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ================================================================
   常量
   ================================================================ */

#define HS_PAGE_SIZE          4096     /* 内存页大小 (4KB) */
#define HS_MAX_PAGES          256      /* 最大页数 (1MB / 4KB) */
#define HS_MAX_SNAPSHOT_SIZE  131072   /* 快照最大字节数 */
#define HS_SNAPSHOT_MAGIC     0x48534E50  /* "HSNP" */
#define HS_SYNC_CHANNELS      2        /* 同步通道数 (主→备 + 备→主) */

/* 脏页追踪 */
#define HS_DIRTY_BITMAP_SIZE  ((HS_MAX_PAGES + 63) / 64)  /* uint64 位图 */

/* 同步协议 */
#define HS_SYNC_RETRY_MAX     3        /* 最大重传次数 */
#define HS_SYNC_TIMEOUT_MS    50       /* 同步超时 (毫秒) */
#define HS_HEARTBEAT_INTERVAL_MS 100   /* 心跳间隔 (毫秒) */
#define HS_HEARTBEAT_TIMEOUT_MS 500    /* 心跳超时判定 (毫秒) */

/* ================================================================
   主备状态机
   ================================================================ */

typedef enum {
    HS_STATE_UNINIT    = 0,   /* 未初始化 */
    HS_STATE_ACTIVE    = 1,   /* 主站 (ACTIVE) — 正常运行 */
    HS_STATE_STANDBY   = 2,   /* 备站 (STANDBY) — 热备同步 */
    HS_STATE_FAILED    = 3,   /* 故障 (FAILED) — 异常停止 */
    HS_STATE_SWITCHING = 4,   /* 切换中 (SWITCHING) — 角色交接 */
} HS_State;

typedef enum {
    HS_EVENT_NONE          = 0,
    HS_EVENT_HEARTBEAT_OK  = 1,   /* 心跳正常 */
    HS_EVENT_HEARTBEAT_LOST = 2,  /* 心跳丢失 */
    HS_EVENT_SYNC_SUCCESS  = 3,   /* 状态同步成功 */
    HS_EVENT_SYNC_FAILED   = 4,   /* 状态同步失败 */
    HS_EVENT_FAULT_DETECTED = 5,  /* 检测到故障 */
    HS_EVENT_SWITCH_REQUEST = 6,  /* 切换请求 (手动/自动) */
    HS_EVENT_DOWNLOAD_DONE  = 7,  /* 增量下装完成 */
} HS_Event;

/* ================================================================
   脏页追踪
   ================================================================ */

typedef struct {
    uint64_t bitmap[HS_DIRTY_BITMAP_SIZE];  /* 脏页位图 */
    uint32_t page_count;                     /* 总页数 */
    uint32_t page_size;                      /* 页大小 (4KB) */
} DirtyPageTracker;

/* ================================================================
   状态快照
   ================================================================ */

typedef struct __attribute__((packed)) {
    uint32_t magic;              /* HS_SNAPSHOT_MAGIC */
    uint32_t sequence;           /* 序列号 (递增) */
    uint32_t timestamp;          /* 时间戳 (tick) */

    /* VM 状态 */
    uint32_t val_stack_ptr;      /* 值栈指针 */
    uint32_t frame_stack_ptr;    /* 帧栈指针 */
    uint32_t cycle_count;        /* 周期计数 */
    int32_t  last_error;         /* 末次错误码 */
    uint32_t max_frame_depth;    /* 本周期最大调用深度 */
    uint32_t max_value_stack_depth; /* 本周期最大值栈深度 */

    /* 内存快照 (压缩: 仅含脏页) */
    uint32_t dirty_page_count;   /* 脏页数量 */
    uint32_t dirty_page_indices[HS_MAX_PAGES]; /* 脏页索引列表 */
    uint32_t dirty_data_size;    /* 脏页数据总大小 */

    /* CRC32 校验 (覆盖整个快照) */
    uint32_t crc32;
} SnapshotHeader;

/* ================================================================
   同步通道
   ================================================================ */

typedef enum {
    HS_CHAN_SHARED_MEM = 0,   /* 共享内存 (同机箱) */
    HS_CHAN_TCP        = 1,   /* TCP/IP 网络 (远距离) */
    HS_CHAN_CUSTOM     = 2,   /* 自定义通道 */
} HS_ChannelType;

/* 同步通道接口 */
typedef struct {
    HS_ChannelType type;
    void          *channel_handle;  /* 通道句柄 (实现特定) */

    /* 发送数据 */
    int (*send)(void *handle, const uint8_t *data, uint32_t len, uint32_t timeout_ms);
    /* 接收数据 */
    int (*recv)(void *handle, uint8_t *buf, uint32_t *len, uint32_t timeout_ms);
    /* 获取末次活动时间戳 */
    uint32_t (*last_activity)(void *handle);
} SyncChannel;

/* ================================================================
   热备系统主结构体
   ================================================================ */

typedef struct {
    /* 状态机 */
    HS_State  state;             /* 当前状态 */
    HS_State  prev_state;        /* 前一状态 */
    uint32_t  state_enter_tick;  /* 进入当前状态的时间戳 */
    uint32_t  fault_count;       /* 连续故障计数 */

    /* 本机角色配置 */
    bool      is_master;         /* 是否配置为主站 */
    uint32_t  node_id;           /* 本机节点 ID (0/1) */
    uint32_t  peer_node_id;      /* 对端节点 ID */

    /* VM 实例 (本机) */
    VM       *vm;                /* 本机 VM 实例指针 */

    /* 脏页追踪 */
    DirtyPageTracker dirty_tracker;
    bool             dirty_tracking_enabled;

    /* 同步通道 */
    SyncChannel sync_chan;       /* 主同步通道 */
    uint32_t    sync_sequence;   /* 同步序列号 */
    uint32_t    sync_retry_count; /* 当前重试计数 */

    /* 心跳 */
    uint32_t    last_heartbeat_tick;  /* 末次心跳时间 */
    uint32_t    heartbeat_interval;    /* 心跳间隔 (tick) */
    uint32_t    heartbeat_timeout;     /* 心跳超时 (tick) */

    /* 快照缓冲区 */
    uint8_t     snapshot_buf[HS_MAX_SNAPSHOT_SIZE];
    uint32_t    snapshot_size;

    /* 回调 */
    void (*on_state_change)(HS_State old_state, HS_State new_state);
    void (*on_fault_detected)(uint32_t fault_code);
    void (*on_switchover)(void);

    /* 统计 */
    uint32_t    switchover_count;    /* 切换次数 */
    uint32_t    sync_count;          /* 成功同步次数 */
    uint32_t    sync_fail_count;     /* 同步失败次数 */
    uint32_t    heartbeat_lost_count; /* 心跳丢失计数 */

    /* 运行标志 */
    bool        initialized;
    bool        running;
} HotStandbySystem;

/* ================================================================
   函数接口
   ================================================================ */

/* ---------- 生命周期 ---------- */

int  hs_init(HotStandbySystem *hs, VM *vm, bool is_master, uint32_t node_id);
void hs_deinit(HotStandbySystem *hs);

/* ---------- 状态机 ---------- */

HS_State hs_get_state(const HotStandbySystem *hs);
const char *hs_state_name(HS_State state);
int  hs_handle_event(HotStandbySystem *hs, HS_Event event);
int  hs_request_switch(HotStandbySystem *hs);

/* ---------- 脏页追踪 ---------- */

void hs_dirty_init(DirtyPageTracker *tracker, uint32_t memory_size);
void hs_dirty_mark(DirtyPageTracker *tracker, uint32_t addr, uint32_t size);
void hs_dirty_clear(DirtyPageTracker *tracker);
bool hs_dirty_is_page_dirty(const DirtyPageTracker *tracker, uint32_t page_idx);
uint32_t hs_dirty_get_count(const DirtyPageTracker *tracker);
uint32_t hs_dirty_get_pages(const DirtyPageTracker *tracker,
                             uint32_t *indices, uint32_t max_count);

/* ---------- 状态快照 ---------- */

int  hs_snapshot_create(HotStandbySystem *hs);
int  hs_snapshot_apply(HotStandbySystem *hs, const uint8_t *snap_data,
                        uint32_t snap_size);
bool hs_snapshot_verify_crc(const uint8_t *data, uint32_t size);

/* ---------- 同步 ---------- */

int  hs_sync_send(HotStandbySystem *hs);
int  hs_sync_receive(HotStandbySystem *hs, uint32_t timeout_ms);
int  hs_sync_cycle(HotStandbySystem *hs);

/* ---------- 心跳 ---------- */

int  hs_heartbeat_send(HotStandbySystem *hs);
int  hs_heartbeat_check(HotStandbySystem *hs);

/* ---------- 主循环 ---------- */

int  hs_master_cycle(HotStandbySystem *hs);
int  hs_standby_cycle(HotStandbySystem *hs);
int  hs_run_cycle(HotStandbySystem *hs);

/* ---------- 共享内存同步通道 (默认实现) ---------- */

int  hs_chan_shmem_init(SyncChannel *chan,
                        uint32_t local_buf_size,
                        uint32_t peer_buf_size);
void hs_chan_shmem_deinit(SyncChannel *chan);

#ifdef __cplusplus
}
#endif

#endif /* HOTSTANDBY_H */
