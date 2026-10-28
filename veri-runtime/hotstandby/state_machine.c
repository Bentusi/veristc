/**
 * vm/hotstandby/state_machine.c
 * 主备状态机 — 故障检测 + 角色切换
 *
 * 状态迁移图:
 *
 *                      ┌───────────┐
 *            init      │           │
 *   ┌────────────────→ │  UNINIT   │
 *   │                  │           │
 *   │                  └─────┬─────┘
 *   │                        │ hs_init()
 *   │                        ▼
 *   │               ┌─────────────────┐
 *   │   故障修复     │                 │
 *   ├────────────── │    ACTIVE       │ ◄──── 主站
 *   │   或          │   (主站)        │
 *   │   备→主升级   │                 │
 *   │               └────────┬────────┘
 *   │                        │ 故障检测
 *   │                        ▼
 *   │               ┌─────────────────┐
 *   │               │                 │
 *   │               │    FAILED       │
 *   │               │   (故障)        │
 *   │               │                 │
 *   │               └────────┬────────┘
 *   │                        │ 备站切换
 *   │                        ▼
 *   │               ┌─────────────────┐
 *   │      ┌────── │   SWITCHING     │
 *   │      │       │  (切换中)        │
 *   │      │       └────────┬────────┘
 *   │      │                │ 切换完成
 *   │      │                ▼
 *   │      │       ┌─────────────────┐
 *   │      │       │                 │
 *   │      └────── │    STANDBY      │ ◄──── 备站
 *   │              │   (备站)        │
 *   │              │                 │
 *   │              └─────────────────┘
 *   │
 *   └──── 备站同步 ──→  ACTIVE (备→主升级)
 *
 * 状态定义:
 *   UNINIT    — 未初始化, 初始状态
 *   ACTIVE    — 主站正常运行, 执行扫描周期+发送同步
 *   STANDBY   — 备站热备, 接收同步+准备切换
 *   FAILED    — 故障, 停止执行, 等待修复或切换
 *   SWITCHING — 切换中, 角色交接过渡状态
 */

#include "hotstandby.h"
#include <string.h>

/* ================================================================
   状态名映射
   ================================================================ */

const char *hs_state_name(HS_State state)
{
    switch (state) {
    case HS_STATE_UNINIT:    return "UNINIT";
    case HS_STATE_ACTIVE:    return "ACTIVE";
    case HS_STATE_STANDBY:   return "STANDBY";
    case HS_STATE_FAILED:    return "FAILED";
    case HS_STATE_SWITCHING: return "SWITCHING";
    default:                 return "UNKNOWN";
    }
}

HS_State hs_get_state(const HotStandbySystem *hs)
{
    return (hs != NULL) ? hs->state : HS_STATE_UNINIT;
}

/* ================================================================
   状态转换
   ================================================================ */

static void set_state(HotStandbySystem *hs, HS_State new_state)
{
    if (!hs) { return; }
    HS_State old = hs->state;
    hs->prev_state = old;
    hs->state = new_state;
    hs->state_enter_tick = 0;  /* 由外部填充 */

    if (hs->on_state_change != NULL) {
        hs->on_state_change(old, new_state);
    }
}

/* ================================================================
   事件处理 — 核心状态机逻辑
   ================================================================ */

int hs_handle_event(HotStandbySystem *hs, HS_Event event)
{
    if (!hs) { return -1; }

    switch (hs->state) {

    /* ========== UNINIT ========== */
    case HS_STATE_UNINIT:
        switch (event) {
        case HS_EVENT_NONE:
            return 0;
        default:
            return -1;  /* 未初始化时忽略所有事件 */
        }

    /* ========== ACTIVE (主站) ========== */
    case HS_STATE_ACTIVE:
        switch (event) {
        case HS_EVENT_HEARTBEAT_OK:
            /* 主站收到自己的心跳 OK — 忽略 */
            return 0;

        case HS_EVENT_HEARTBEAT_LOST:
            /* 心跳丢失 — 增加故障计数 */
            hs->fault_count++;
            if (hs->fault_count >= HS_SYNC_RETRY_MAX) {
                set_state(hs, HS_STATE_FAILED);
                if (hs->on_fault_detected != NULL) {
                    hs->on_fault_detected(1);  /* 心跳丢失故障 */
                }
            }
            return 0;

        case HS_EVENT_SYNC_SUCCESS:
            /* 同步成功 — 清除故障计数 */
            hs->fault_count = 0;
            return 0;

        case HS_EVENT_SYNC_FAILED:
            /* 同步失败 */
            hs->fault_count++;
            if (hs->fault_count >= HS_SYNC_RETRY_MAX) {
                set_state(hs, HS_STATE_FAILED);
                if (hs->on_fault_detected != NULL) {
                    hs->on_fault_detected(2);  /* 同步失败故障 */
                }
            }
            return 0;

        case HS_EVENT_FAULT_DETECTED:
            /* 检测到严重故障 — 立即切换到 FAILED */
            hs->fault_count++;
            set_state(hs, HS_STATE_FAILED);
            if (hs->on_fault_detected != NULL) {
                hs->on_fault_detected(3);
            }
            return 0;

        case HS_EVENT_SWITCH_REQUEST:
            /* 切换到 STANDBY (主动让位) */
            hs->is_master = false;
            set_state(hs, HS_STATE_SWITCHING);
            return 0;

        case HS_EVENT_DOWNLOAD_DONE:
            /* 下装完成 — 继续 ACTIVE */
            return 0;

        default:
            return -1;
        }

    /* ========== STANDBY (备站) ========== */
    case HS_STATE_STANDBY:
        switch (event) {
        case HS_EVENT_HEARTBEAT_OK:
            /* 备站收到主站心跳正常 */
            hs->heartbeat_lost_count = 0;
            return 0;

        case HS_EVENT_HEARTBEAT_LOST:
            /* 主站心跳丢失 */
            hs->heartbeat_lost_count++;
            if (hs->heartbeat_lost_count >= 3u) {
                /* 连续丢失 → 执行备→主切换 */
                set_state(hs, HS_STATE_SWITCHING);
            }
            return 0;

        case HS_EVENT_SYNC_SUCCESS:
            /* 成功接收主站快照 */
            hs->fault_count = 0;
            return 0;

        case HS_EVENT_SYNC_FAILED:
            /* 同步接收失败 (允许重试) */
            hs->fault_count++;
            return 0;

        case HS_EVENT_FAULT_DETECTED:
            set_state(hs, HS_STATE_FAILED);
            return 0;

        case HS_EVENT_SWITCH_REQUEST:
            /* 备→主切换请求 */
            set_state(hs, HS_STATE_SWITCHING);
            return 0;

        case HS_EVENT_DOWNLOAD_DONE:
            /* 下装完成 — 保持 STANDBY */
            return 0;

        default:
            return -1;
        }

    /* ========== FAILED ========== */
    case HS_STATE_FAILED:
        switch (event) {
        case HS_EVENT_HEARTBEAT_OK:
            /* 故障恢复: 如果心跳恢复, 转为 STANDBY */
            hs->fault_count = 0;
            set_state(hs, HS_STATE_STANDBY);
            return 0;

        case HS_EVENT_SWITCH_REQUEST:
            /* 强制切换 (人工干预) */
            set_state(hs, HS_STATE_SWITCHING);
            return 0;

        default:
            return -1;
        }

    /* ========== SWITCHING ========== */
    case HS_STATE_SWITCHING:
        switch (event) {
        case HS_EVENT_NONE:
            /* 切换完成 → 决定新角色 */
            if (hs->is_master) {
                set_state(hs, HS_STATE_ACTIVE);
            } else {
                set_state(hs, HS_STATE_STANDBY);
            }
            hs->switchover_count++;
            if (hs->on_switchover != NULL) {
                hs->on_switchover();
            }
            return 0;

        default:
            return -1;
        }

    default:
        return -1;
    }
}

/* ================================================================
   切换请求
   ================================================================ */

int hs_request_switch(HotStandbySystem *hs)
{
    if (!hs) { return -1; }
    return hs_handle_event(hs, HS_EVENT_SWITCH_REQUEST);
}

/* ================================================================
   生命周期
   ================================================================ */

int hs_init(HotStandbySystem *hs, VM *vm, bool is_master, uint32_t node_id)
{
    if (!hs || !vm) { return -1; }

    (void)memset(hs, 0, sizeof(HotStandbySystem));

    hs->vm        = vm;
    hs->is_master = is_master;
    hs->node_id   = node_id;
    hs->peer_node_id = (node_id == 0u) ? 1u : 0u;

    hs->state            = HS_STATE_UNINIT;
    hs->prev_state       = HS_STATE_UNINIT;
    hs->fault_count      = 0;

    hs->sync_sequence    = 0;
    hs->sync_retry_count = 0;

    hs->heartbeat_interval = 100;   /* 默认 100ms */
    hs->heartbeat_timeout   = 500;  /* 默认 500ms */

    hs->switchover_count  = 0;
    hs->sync_count        = 0;
    hs->sync_fail_count   = 0;
    hs->heartbeat_lost_count = 0;

    /* 初始化脏页追踪 */
    hs_dirty_init(&hs->dirty_tracker, vm->memory_size);
    hs->dirty_tracking_enabled = true;

    /* 初始状态: 主→ACTIVE, 备→STANDBY */
    if (is_master) {
        set_state(hs, HS_STATE_ACTIVE);
    } else {
        set_state(hs, HS_STATE_STANDBY);
    }

    hs->initialized = true;
    hs->running = true;

    return 0;
}

void hs_deinit(HotStandbySystem *hs)
{
    if (!hs) { return; }
    hs->running = false;
    hs->initialized = false;
    hs->state = HS_STATE_UNINIT;
}

/* ================================================================
   主备周期运行
   ================================================================ */

int hs_master_cycle(HotStandbySystem *hs)
{
    if ((!hs) || (hs->state != HS_STATE_ACTIVE)) { return -1; }

    VM *vm = hs->vm;

    /* 1. 执行 VM 扫描周期 */
    int ret = vm_run(vm);
    if (ret != VM_OK) {
        (void)hs_handle_event(hs, HS_EVENT_FAULT_DETECTED);
        return ret;
    }

    /* 2. 记录脏页 (vm_run 期间修改的内存) */
    /* 脏页由 vm_run 中的 STORE 指令触发标记 */
    /* 此处无需额外操作 */

    /* 3. 发送状态快照到备站 */
    ret = hs_sync_send(hs);
    if (ret != 0) {
        (void)hs_handle_event(hs, HS_EVENT_SYNC_FAILED);
    } else {
        (void)hs_handle_event(hs, HS_EVENT_SYNC_SUCCESS);
    }

    /* 4. 发送心跳 */
    (void)hs_heartbeat_send(hs);

    return ret;
}

int hs_standby_cycle(HotStandbySystem *hs)
{
    if ((!hs) || (hs->state != HS_STATE_STANDBY)) { return -1; }

    /* 1. 检查心跳 */
    (void)hs_heartbeat_check(hs);

    /* 2. 接收主站快照 */
    int ret = hs_sync_receive(hs, HS_SYNC_TIMEOUT_MS);

    /* 3. 如果接收成功, 应用快照已在 hs_sync_receive 中完成 */
    return ret;
}

int hs_run_cycle(HotStandbySystem *hs)
{
    if (!hs || !hs->running) { return -1; }

    if (hs->state == HS_STATE_ACTIVE) {
        return hs_master_cycle(hs);
    }
    if (hs->state == HS_STATE_STANDBY) {
        return hs_standby_cycle(hs);
    }
    if (hs->state == HS_STATE_SWITCHING) {
        /* 切换完成 */
        (void)hs_handle_event(hs, HS_EVENT_NONE);
        return 0;
    }

    return -1;
}
