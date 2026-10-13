/**
 * vm/hotstandby/sync.c
 * 同步通信协议 — 主备间状态传输 + 心跳
 *
 * 支持两种同步通道:
 *   1. 共享内存 (同机箱双机)
 *   2. TCP/IP (远距离)
 *
 * 同步策略:
 *   - 主站每周期结束时发送快照
 *   - 备站接收并 ACK
 *   - 超时重传 (最多 HS_SYNC_RETRY_MAX 次)
 */

#include "hotstandby.h"
#include <string.h>

/* ================================================================
   共享内存通道布局
   ================================================================
 *
 * 共享内存布局 (双机):
 *
 *   ┌───────────────────────┬──────────────────────┐
 *   │  Node 0 写区域         │  Node 1 写区域        │
 *   │  (Node 1 只读)         │  (Node 0 只读)        │
 *   ├───────────────────────┼──────────────────────┤
 *   │  header (8 bytes)     │  header (8 bytes)     │
 *   │  data (payload)       │  data (payload)       │
 *   └───────────────────────┴──────────────────────┘
 */

#define SHMEM_HEADER_SIZE    8  /* uint32 magic + uint32 size */

typedef struct {
    uint32_t magic;       /* HS_SNAPSHOT_MAGIC 或 0 (空) */
    uint32_t data_size;   /* 有效数据大小 */
    /* 之后紧跟 payload 数据 */
} __attribute__((packed)) ShmemHeader;

typedef struct {
    uint8_t  *base;               /* 共享内存基地址 */
    uint32_t  total_size;         /* 总大小 */
    uint32_t  half_size;          /* 单节点区域大小 */
    uint32_t  local_offset;       /* 本机写入偏移 */
    uint32_t  peer_offset;        /* 对端写入偏移 */
    uint32_t  last_activity_tick; /* 末次活动时间 */
} ShmemChannel;

/* ================================================================
   共享内存通道实现
   ================================================================ */

int hs_chan_shmem_init(SyncChannel *chan,
                       uint32_t local_buf_size,
                       uint32_t peer_buf_size)
{
    if (!chan) { return -1; }

    ShmemChannel *shmem = (ShmemChannel *)chan->channel_handle;
    if (!shmem) {
        /* 由上层分配 ShmemChannel 并填充 base */
        return -1;
    }

    uint32_t total = SHMEM_HEADER_SIZE + local_buf_size +
                     SHMEM_HEADER_SIZE + peer_buf_size;
    if (total > shmem->total_size) { return -1; }

    shmem->half_size = total / 2;
    shmem->local_offset = 0;  /* 假设本机是前半部分 */
    shmem->peer_offset  = shmem->half_size;

    chan->type = HS_CHAN_SHARED_MEM;
    chan->send = NULL;  /* 由上层调用 shmem_send/recv 包装 */
    chan->recv = NULL;
    chan->last_activity = NULL;

    return 0;
}

void hs_chan_shmem_deinit(SyncChannel *chan)
{
    (void)chan;
    /* 共享内存由上层管理释放 */
}

/* ================================================================
   共享内存发送
   ================================================================ */

static int shmem_send(ShmemChannel *shmem,
                      const uint8_t *data, uint32_t len,
                      uint32_t timeout_ms)
{
    (void)timeout_ms;
    if ((!shmem) || (!data) || (len == 0)) { return -1; }

    uint32_t max_payload = shmem->half_size - SHMEM_HEADER_SIZE;
    if (len > max_payload) { return -1; }

    uint8_t *write_area = shmem->base + shmem->local_offset;

    /* 写入头部 */
    ShmemHeader *hdr = (ShmemHeader *)write_area;
    hdr->magic     = HS_SNAPSHOT_MAGIC;
    hdr->data_size = len;

    /* 写入数据 */
    (void)memcpy(write_area + SHMEM_HEADER_SIZE, data, len);

    /* 写屏障 (嵌入式需使用 DSB 指令) */
    __sync_synchronize();

    shmem->last_activity_tick = 0;  /* 由调用方填充 */
    return 0;
}

static int shmem_recv(ShmemChannel *shmem,
                      uint8_t *buf, uint32_t *len,
                      uint32_t timeout_ms)
{
    (void)timeout_ms;
    if ((!shmem) || (!buf) || (!len)) { return -1; }

    uint8_t *read_area = shmem->base + shmem->peer_offset;

    /* 读屏障 */
    __sync_synchronize();

    ShmemHeader *hdr = (ShmemHeader *)read_area;

    if ((hdr->magic != HS_SNAPSHOT_MAGIC) || (hdr->data_size == 0)) {
        *len = 0;
        return -1;  /* 无数据 */
    }

    uint32_t copy_size = hdr->data_size;
    if (copy_size > *len) { copy_size = *len; }

    (void)memcpy(buf, read_area + SHMEM_HEADER_SIZE, copy_size);
    *len = copy_size;

    /* 读取后清除头部 (标记已消费) */
    hdr->magic = 0;
    hdr->data_size = 0;

    __sync_synchronize();

    shmem->last_activity_tick = 0;
    return 0;
}

/* ================================================================
   心跳同步
   ================================================================ */

int hs_heartbeat_send(HotStandbySystem *hs)
{
    if (!hs) { return -1; }

    /* 通过同步通道发送心跳标记 (空数据 + 特定 magic) */
    ShmemChannel *shmem = (ShmemChannel *)hs->sync_chan.channel_handle;
    if (!shmem) { return -1; }

    uint8_t *write_area = shmem->base + shmem->local_offset;
    ShmemHeader *hdr = (ShmemHeader *)write_area;

    hdr->magic     = 0x48425400;  /* "HBT\0" */
    hdr->data_size = 0;

    __sync_synchronize();

    hs->last_heartbeat_tick = 0;  /* 由外部填充 tick */
    return 0;
}

int hs_heartbeat_check(HotStandbySystem *hs)
{
    if (!hs) { return -1; }

    ShmemChannel *shmem = (ShmemChannel *)hs->sync_chan.channel_handle;
    if (!shmem) { return -1; }

    uint8_t *read_area = shmem->base + shmem->peer_offset;
    __sync_synchronize();

    ShmemHeader *hdr = (ShmemHeader *)read_area;

    if (hdr->magic == 0x48425400) {
        /* 心跳正常 */
        hdr->magic = 0;  /* 消费心跳 */
        __sync_synchronize();
        return hs_handle_event(hs, HS_EVENT_HEARTBEAT_OK);
    }

    /* 心跳丢失 — 检查超时 */
    return hs_handle_event(hs, HS_EVENT_HEARTBEAT_LOST);
}

/* ================================================================
   同步收发
   ================================================================ */

int hs_sync_send(HotStandbySystem *hs)
{
    if (!hs) { return -1; }
    
    /* 1. 创建快照 */
    int ret = hs_snapshot_create(hs);
    if (ret != 0) { return ret; }
    
    /* 2. 通过共享内存发送 */
    ShmemChannel *shmem = (ShmemChannel *)hs->sync_chan.channel_handle;
    if (shmem != NULL) {
        ret = shmem_send(shmem, hs->snapshot_buf, hs->snapshot_size, 50);
    }

    if (ret == 0) {
        hs->sync_count++;
        hs->sync_retry_count = 0;
    } else {
        hs->sync_fail_count++;
        hs->sync_retry_count++;
    }

    return ret;
}

int hs_sync_receive(HotStandbySystem *hs, uint32_t timeout_ms)
{
    if (!hs) { return -1; }

    ShmemChannel *shmem = (ShmemChannel *)hs->sync_chan.channel_handle;
    if (!shmem) { return -1; }
    
    uint32_t len = sizeof(hs->snapshot_buf);
    int ret = shmem_recv(shmem, hs->snapshot_buf, &len, timeout_ms);
    
    if ((ret == 0) && (len > 0)) {
        /* 应用快照到本机 VM */
        ret = hs_snapshot_apply(hs, hs->snapshot_buf, len);
        if (ret == 0) {
            (void)hs_handle_event(hs, HS_EVENT_SYNC_SUCCESS);
        } else {
            (void)hs_handle_event(hs, HS_EVENT_SYNC_FAILED);
        }
    }

    return ret;
}

int hs_sync_cycle(HotStandbySystem *hs)
{
    if (!hs) { return -1; }

    if (hs->is_master) {
        /* 主站: 执行 → 发快照 */
        int ret = vm_run(hs->vm);
        if (ret != VM_OK) {
            (void)hs_handle_event(hs, HS_EVENT_FAULT_DETECTED);
            return ret;
        }
        return hs_sync_send(hs);
    } else {
        /* 备站: 收快照 → 应用到本机 */
        return hs_sync_receive(hs, HS_SYNC_TIMEOUT_MS);
    }
}
