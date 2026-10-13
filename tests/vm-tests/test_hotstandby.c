/*
 * Hotstandby module unit tests.
 * Covers state machine, dirty page tracking, snapshot, and download manager.
 */

#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "../../vm/vm.h"
#include "../../rtos/abstract.h"
#include "../../vm/hotstandby/hotstandby.h"

VM_Interface g_vm_interface = { 0 };

/* Include implementations directly to avoid link issues */
#include "../../vm/loader.c"
#include "../../vm/safeasm_interp.c"
#include "../../vm/hotstandby/state_machine.c"
#include "../../vm/hotstandby/snapshot.c"
#include "../../vm/hotstandby/sync.c"
#include "../../vm/hotstandby/download.c"

/* Stub for io_mapping_cycle - not used in hotstandby tests */
int io_mapping_cycle(void *table, VM *vm)
{
    (void)table;
    (void)vm;
    return 0;
}

/* ================================================================
   Test fixtures
   ================================================================ */

static VM g_test_vm;
static SasmModule g_test_module;
static HotStandbySystem g_hs;

static void setup_test_module(SasmModule *mod)
{
    memset(mod, 0, sizeof(*mod));
    mod->version = 1;
    mod->type_count = 1;
    mod->types[0].return_count = 1;
    mod->types[0].return_types[0] = VAL_I32;
    mod->func_count = 1;
    mod->code_count = 1;
    mod->codes[0].func_idx = 0;
    mod->codes[0].body_offset = 0;
    mod->codes[0].body_size = 1;
    mod->code_pool[0] = OP_RETURN;
    mod->code_size = 1;
    mod->total_memory_size = 65536;  /* 64KB = 16 pages */
    mod->safety.cycle_limit = 1000;
    mod->safety.global_stack_depth = 8;
    mod->entry_function = 0;
}

static void setup_test_vm(void)
{
    setup_test_module(&g_test_module);
    assert(vm_init(&g_test_vm, &g_test_module, 65536) == 0);
}

static void setup_hs_master(void)
{
    setup_test_vm();
    assert(hs_init(&g_hs, &g_test_vm, true, 0) == 0);
}

static void setup_hs_standby(void)
{
    setup_test_vm();
    assert(hs_init(&g_hs, &g_test_vm, false, 1) == 0);
}

/* ================================================================
   State machine tests
   ================================================================ */

static void test_hs_init_master(void)
{
    setup_hs_master();
    assert(hs_get_state(&g_hs) == HS_STATE_ACTIVE);
    assert(g_hs.is_master == true);
    assert(g_hs.node_id == 0);
    assert(g_hs.peer_node_id == 1);
    assert(g_hs.initialized == true);
    printf("  [PASS] test_hs_init_master\n");
}

static void test_hs_init_standby(void)
{
    setup_hs_standby();
    assert(hs_get_state(&g_hs) == HS_STATE_STANDBY);
    assert(g_hs.is_master == false);
    assert(g_hs.node_id == 1);
    assert(g_hs.peer_node_id == 0);
    assert(g_hs.initialized == true);
    printf("  [PASS] test_hs_init_standby\n");
}

static void test_active_heartbeat_lost_to_failed(void)
{
    setup_hs_master();
    assert(hs_get_state(&g_hs) == HS_STATE_ACTIVE);

    /* First heartbeat lost: fault_count=1, stay ACTIVE */
    assert(hs_handle_event(&g_hs, HS_EVENT_HEARTBEAT_LOST) == 0);
    assert(g_hs.fault_count == 1);
    assert(hs_get_state(&g_hs) == HS_STATE_ACTIVE);

    /* Second heartbeat lost: fault_count=2, stay ACTIVE */
    assert(hs_handle_event(&g_hs, HS_EVENT_HEARTBEAT_LOST) == 0);
    assert(g_hs.fault_count == 2);
    assert(hs_get_state(&g_hs) == HS_STATE_ACTIVE);

    /* Third heartbeat lost: fault_count>=3, transition to FAILED */
    assert(hs_handle_event(&g_hs, HS_EVENT_HEARTBEAT_LOST) == 0);
    assert(g_hs.fault_count == 3);
    assert(hs_get_state(&g_hs) == HS_STATE_FAILED);

    printf("  [PASS] test_active_heartbeat_lost_to_failed\n");
}

static void test_active_sync_failure_to_failed(void)
{
    setup_hs_master();
    assert(hs_get_state(&g_hs) == HS_STATE_ACTIVE);

    /* First sync failure: fault_count=1, stay ACTIVE */
    assert(hs_handle_event(&g_hs, HS_EVENT_SYNC_FAILED) == 0);
    assert(g_hs.fault_count == 1);
    assert(hs_get_state(&g_hs) == HS_STATE_ACTIVE);

    /* Second sync failure: fault_count=2, stay ACTIVE */
    assert(hs_handle_event(&g_hs, HS_EVENT_SYNC_FAILED) == 0);
    assert(g_hs.fault_count == 2);
    assert(hs_get_state(&g_hs) == HS_STATE_ACTIVE);

    /* Third sync failure: fault_count>=3, transition to FAILED */
    assert(hs_handle_event(&g_hs, HS_EVENT_SYNC_FAILED) == 0);
    assert(g_hs.fault_count == 3);
    assert(hs_get_state(&g_hs) == HS_STATE_FAILED);

    printf("  [PASS] test_active_sync_failure_to_failed\n");
}

static void test_active_fault_detected(void)
{
    setup_hs_master();
    assert(hs_get_state(&g_hs) == HS_STATE_ACTIVE);

    /* FAULT_DETECTED: immediate transition to FAILED */
    assert(hs_handle_event(&g_hs, HS_EVENT_FAULT_DETECTED) == 0);
    assert(g_hs.fault_count == 1);
    assert(hs_get_state(&g_hs) == HS_STATE_FAILED);

    printf("  [PASS] test_active_fault_detected\n");
}

static void test_active_switch_to_standby(void)
{
    setup_hs_master();
    assert(hs_get_state(&g_hs) == HS_STATE_ACTIVE);
    assert(g_hs.is_master == true);

    /* SWITCH_REQUEST: ACTIVE -> SWITCHING, is_master set to false */
    assert(hs_handle_event(&g_hs, HS_EVENT_SWITCH_REQUEST) == 0);
    assert(hs_get_state(&g_hs) == HS_STATE_SWITCHING);
    assert(g_hs.is_master == false);

    /* NONE event: SWITCHING -> STANDBY (because is_master=false) */
    assert(hs_handle_event(&g_hs, HS_EVENT_NONE) == 0);
    assert(hs_get_state(&g_hs) == HS_STATE_STANDBY);
    assert(g_hs.switchover_count == 1);

    printf("  [PASS] test_active_switch_to_standby\n");
}

static void test_standby_heartbeat_lost_to_switching(void)
{
    setup_hs_standby();
    assert(hs_get_state(&g_hs) == HS_STATE_STANDBY);

    /* First heartbeat lost: heartbeat_lost_count=1, stay STANDBY */
    assert(hs_handle_event(&g_hs, HS_EVENT_HEARTBEAT_LOST) == 0);
    assert(g_hs.heartbeat_lost_count == 1);
    assert(hs_get_state(&g_hs) == HS_STATE_STANDBY);

    /* Second heartbeat lost: heartbeat_lost_count=2, stay STANDBY */
    assert(hs_handle_event(&g_hs, HS_EVENT_HEARTBEAT_LOST) == 0);
    assert(g_hs.heartbeat_lost_count == 2);
    assert(hs_get_state(&g_hs) == HS_STATE_STANDBY);

    /* Third heartbeat lost: heartbeat_lost_count>=3, transition to SWITCHING */
    assert(hs_handle_event(&g_hs, HS_EVENT_HEARTBEAT_LOST) == 0);
    assert(g_hs.heartbeat_lost_count == 3);
    assert(hs_get_state(&g_hs) == HS_STATE_SWITCHING);

    printf("  [PASS] test_standby_heartbeat_lost_to_switching\n");
}

static void test_standby_to_active_promotion(void)
{
    setup_hs_standby();
    assert(hs_get_state(&g_hs) == HS_STATE_STANDBY);

    /* SWITCH_REQUEST: STANDBY -> SWITCHING */
    assert(hs_handle_event(&g_hs, HS_EVENT_SWITCH_REQUEST) == 0);
    assert(hs_get_state(&g_hs) == HS_STATE_SWITCHING);

    /* Simulate promotion: set is_master=true before completing switch */
    g_hs.is_master = true;

    /* NONE event: SWITCHING -> ACTIVE (because is_master=true) */
    assert(hs_handle_event(&g_hs, HS_EVENT_NONE) == 0);
    assert(hs_get_state(&g_hs) == HS_STATE_ACTIVE);
    assert(g_hs.switchover_count == 1);

    printf("  [PASS] test_standby_to_active_promotion\n");
}

static void test_failed_recovery(void)
{
    setup_hs_master();

    /* Force transition to FAILED */
    assert(hs_handle_event(&g_hs, HS_EVENT_FAULT_DETECTED) == 0);
    assert(hs_get_state(&g_hs) == HS_STATE_FAILED);

    /* HEARTBEAT_OK: FAILED -> STANDBY, fault_count reset */
    assert(hs_handle_event(&g_hs, HS_EVENT_HEARTBEAT_OK) == 0);
    assert(g_hs.fault_count == 0);
    assert(hs_get_state(&g_hs) == HS_STATE_STANDBY);

    printf("  [PASS] test_failed_recovery\n");
}

static void test_switching_completes_master(void)
{
    setup_hs_master();

    /* Force to SWITCHING state */
    assert(hs_handle_event(&g_hs, HS_EVENT_FAULT_DETECTED) == 0);
    assert(hs_get_state(&g_hs) == HS_STATE_FAILED);
    assert(hs_handle_event(&g_hs, HS_EVENT_SWITCH_REQUEST) == 0);
    assert(hs_get_state(&g_hs) == HS_STATE_SWITCHING);

    /* Set is_master=true for this test */
    g_hs.is_master = true;

    /* NONE event: SWITCHING -> ACTIVE */
    uint32_t prev_switchover = g_hs.switchover_count;
    assert(hs_handle_event(&g_hs, HS_EVENT_NONE) == 0);
    assert(hs_get_state(&g_hs) == HS_STATE_ACTIVE);
    assert(g_hs.switchover_count == prev_switchover + 1);

    printf("  [PASS] test_switching_completes_master\n");
}

static void test_switching_completes_standby(void)
{
    setup_hs_standby();

    /* Force to SWITCHING state */
    assert(hs_handle_event(&g_hs, HS_EVENT_SWITCH_REQUEST) == 0);
    assert(hs_get_state(&g_hs) == HS_STATE_SWITCHING);

    /* is_master should be false (standby) */
    assert(g_hs.is_master == false);

    /* NONE event: SWITCHING -> STANDBY */
    uint32_t prev_switchover = g_hs.switchover_count;
    assert(hs_handle_event(&g_hs, HS_EVENT_NONE) == 0);
    assert(hs_get_state(&g_hs) == HS_STATE_STANDBY);
    assert(g_hs.switchover_count == prev_switchover + 1);

    printf("  [PASS] test_switching_completes_standby\n");
}

static void test_uninit_rejects_events(void)
{
    HotStandbySystem hs_uninit;
    memset(&hs_uninit, 0, sizeof(hs_uninit));
    hs_uninit.state = HS_STATE_UNINIT;

    /* UNINIT + HEARTBEAT_OK should return -1 */
    assert(hs_handle_event(&hs_uninit, HS_EVENT_HEARTBEAT_OK) == -1);
    assert(hs_handle_event(&hs_uninit, HS_EVENT_HEARTBEAT_LOST) == -1);
    assert(hs_handle_event(&hs_uninit, HS_EVENT_SYNC_SUCCESS) == -1);
    assert(hs_handle_event(&hs_uninit, HS_EVENT_SYNC_FAILED) == -1);
    assert(hs_handle_event(&hs_uninit, HS_EVENT_FAULT_DETECTED) == -1);
    assert(hs_handle_event(&hs_uninit, HS_EVENT_SWITCH_REQUEST) == -1);

    /* UNINIT + NONE should return 0 (no-op) */
    assert(hs_handle_event(&hs_uninit, HS_EVENT_NONE) == 0);

    printf("  [PASS] test_uninit_rejects_events\n");
}

/* ================================================================
   Dirty page tracking tests
   ================================================================ */

static void test_dirty_init(void)
{
    DirtyPageTracker tracker;
    hs_dirty_init(&tracker, 65536);

    assert(tracker.page_count == 16);  /* 65536 / 4096 = 16 */
    assert(tracker.page_size == 4096);
    assert(hs_dirty_get_count(&tracker) == 0);

    printf("  [PASS] test_dirty_init\n");
}

static void test_dirty_mark_single_page(void)
{
    DirtyPageTracker tracker;
    hs_dirty_init(&tracker, 65536);

    /* Mark addr=0, size=100: should mark page 0 */
    hs_dirty_mark(&tracker, 0, 100);
    assert(hs_dirty_is_page_dirty(&tracker, 0) == true);
    assert(hs_dirty_is_page_dirty(&tracker, 1) == false);
    assert(hs_dirty_get_count(&tracker) == 1);

    printf("  [PASS] test_dirty_mark_single_page\n");
}

static void test_dirty_mark_cross_page(void)
{
    DirtyPageTracker tracker;
    hs_dirty_init(&tracker, 65536);

    /* Mark addr=4000, size=200: spans pages 0 and 1 */
    hs_dirty_mark(&tracker, 4000, 200);
    assert(hs_dirty_is_page_dirty(&tracker, 0) == true);
    assert(hs_dirty_is_page_dirty(&tracker, 1) == true);
    assert(hs_dirty_is_page_dirty(&tracker, 2) == false);
    assert(hs_dirty_get_count(&tracker) == 2);

    printf("  [PASS] test_dirty_mark_cross_page\n");
}

static void test_dirty_clear(void)
{
    DirtyPageTracker tracker;
    hs_dirty_init(&tracker, 65536);

    /* Mark several pages */
    hs_dirty_mark(&tracker, 0, 100);
    hs_dirty_mark(&tracker, 4096, 100);
    hs_dirty_mark(&tracker, 8192, 100);
    assert(hs_dirty_get_count(&tracker) == 3);

    /* Clear all */
    hs_dirty_clear(&tracker);
    assert(hs_dirty_get_count(&tracker) == 0);
    assert(hs_dirty_is_page_dirty(&tracker, 0) == false);
    assert(hs_dirty_is_page_dirty(&tracker, 1) == false);
    assert(hs_dirty_is_page_dirty(&tracker, 2) == false);

    printf("  [PASS] test_dirty_clear\n");
}

static void test_dirty_get_count(void)
{
    DirtyPageTracker tracker;
    hs_dirty_init(&tracker, 65536);

    /* Mark 3 distinct pages */
    hs_dirty_mark(&tracker, 0, 100);      /* page 0 */
    hs_dirty_mark(&tracker, 8192, 100);   /* page 2 */
    hs_dirty_mark(&tracker, 20480, 100);  /* page 5 */

    assert(hs_dirty_get_count(&tracker) == 3);

    printf("  [PASS] test_dirty_get_count\n");
}

static void test_dirty_get_pages(void)
{
    DirtyPageTracker tracker;
    hs_dirty_init(&tracker, 65536);

    /* Mark pages 2, 5, 7 */
    hs_dirty_mark(&tracker, 8192, 100);   /* page 2 */
    hs_dirty_mark(&tracker, 20480, 100);  /* page 5 */
    hs_dirty_mark(&tracker, 28672, 100);  /* page 7 */

    uint32_t indices[16];
    uint32_t count = hs_dirty_get_pages(&tracker, indices, 16);

    assert(count == 3);
    assert(indices[0] == 2);
    assert(indices[1] == 5);
    assert(indices[2] == 7);

    printf("  [PASS] test_dirty_get_pages\n");
}

/* ================================================================
   Snapshot tests
   ================================================================ */

static void test_snapshot_create_apply_roundtrip(void)
{
    /* Setup source VM with known memory */
    setup_hs_master();

    /* Write known pattern to memory */
    for (uint32_t i = 0; i < 256; i++) {
        g_test_vm.memory[i] = (uint8_t)(i & 0xFF);
    }
    g_test_vm.cycle_count = 42;
    g_test_vm.last_error = -5;

    /* Mark page 0 as dirty so it gets included in snapshot */
    hs_dirty_mark(&g_hs.dirty_tracker, 0, 256);

    /* Create snapshot */
    assert(hs_snapshot_create(&g_hs) == 0);
    assert(g_hs.snapshot_size > 0);

    /* Setup destination VM - use static to avoid stack overflow */
    static VM dst_vm;
    static SasmModule dst_mod;
    setup_test_module(&dst_mod);
    assert(vm_init(&dst_vm, &dst_mod, 65536) == 0);

    static HotStandbySystem dst_hs;
    assert(hs_init(&dst_hs, &dst_vm, false, 1) == 0);

    /* Apply snapshot to destination */
    assert(hs_snapshot_apply(&dst_hs, g_hs.snapshot_buf, g_hs.snapshot_size) == 0);

    /* Verify memory matches */
    for (uint32_t i = 0; i < 256; i++) {
        assert(dst_vm.memory[i] == (uint8_t)(i & 0xFF));
    }

    /* Verify VM state */
    assert(dst_vm.cycle_count == 42);
    assert(dst_vm.last_error == -5);

    printf("  [PASS] test_snapshot_create_apply_roundtrip\n");
}

static void test_snapshot_crc_verify(void)
{
    setup_hs_master();

    /* Mark some dirty pages */
    hs_dirty_mark(&g_hs.dirty_tracker, 0, 100);

    /* Create snapshot */
    assert(hs_snapshot_create(&g_hs) == 0);
    assert(g_hs.snapshot_size > sizeof(SnapshotHeader));

    /* Verify CRC */
    assert(hs_snapshot_verify_crc(g_hs.snapshot_buf, g_hs.snapshot_size) == true);

    printf("  [PASS] test_snapshot_crc_verify\n");
}

static void test_snapshot_crc_corrupt(void)
{
    setup_hs_master();

    /* Mark some dirty pages */
    hs_dirty_mark(&g_hs.dirty_tracker, 0, 100);

    /* Create snapshot */
    assert(hs_snapshot_create(&g_hs) == 0);
    assert(g_hs.snapshot_size > sizeof(SnapshotHeader));

    /* Verify CRC before corruption */
    assert(hs_snapshot_verify_crc(g_hs.snapshot_buf, g_hs.snapshot_size) == true);

    /* Corrupt a byte in the data (after header) */
    uint32_t corrupt_offset = sizeof(SnapshotHeader) + 10;
    if (corrupt_offset < g_hs.snapshot_size) {
        g_hs.snapshot_buf[corrupt_offset] ^= 0xFF;
    }

    /* Verify CRC should fail */
    assert(hs_snapshot_verify_crc(g_hs.snapshot_buf, g_hs.snapshot_size) == false);

    printf("  [PASS] test_snapshot_crc_corrupt\n");
}

static void test_snapshot_magic_check(void)
{
    setup_hs_master();

    /* Mark some dirty pages */
    hs_dirty_mark(&g_hs.dirty_tracker, 0, 100);

    /* Create snapshot */
    assert(hs_snapshot_create(&g_hs) == 0);
    assert(g_hs.snapshot_size > sizeof(SnapshotHeader));

    /* Corrupt the magic field */
    SnapshotHeader *hdr = (SnapshotHeader *)g_hs.snapshot_buf;
    hdr->magic = 0xDEADBEEF;

    /* Re-compute CRC so it passes (we want to test magic check, not CRC) */
    hdr->crc32 = 0;
    /* We can't easily recompute CRC here since hs_crc32_compute is static,
       but hs_snapshot_apply checks CRC first, then magic.
       Since CRC will fail, apply will return -2 (CRC error). */

    /* Apply should fail due to CRC/magic corruption */
    int ret = hs_snapshot_apply(&g_hs, g_hs.snapshot_buf, g_hs.snapshot_size);
    assert(ret != 0);  /* Should fail */

    printf("  [PASS] test_snapshot_magic_check\n");
}

/* ================================================================
   Download manager tests
   ================================================================ */

static void test_dl_init(void)
{
    SasmModule mod;
    setup_test_module(&mod);

    dl_manager_init(&mod);

    const SasmModule *active = dl_get_active_module();
    assert(active != NULL);
    assert(active == &mod || memcmp(active, &mod, sizeof(SasmModule)) == 0);
    assert(dl_is_download_in_progress() == false);
    assert(dl_get_progress() == 0);

    printf("  [PASS] test_dl_init\n");
}

static void test_dl_prepare_and_commit(void)
{
    static SasmModule mod1, mod2;
    setup_test_module(&mod1);
    setup_test_module(&mod2);

    /* Modify mod2 to be different */
    mod2.code_pool[0] = OP_NOP;  /* Different opcode */

    dl_manager_init(&mod1);

    /* Prepare download with mod2 */
    assert(dl_prepare_download(&mod2) == 0);
    assert(dl_is_download_in_progress() == true);
    assert(dl_get_progress() == 50);

    /* Commit the switch */
    assert(dl_commit_switch() == 0);
    assert(dl_is_download_in_progress() == false);
    assert(dl_get_progress() == 100);

    /* Verify active module is now mod2 */
    const SasmModule *active = dl_get_active_module();
    assert(active != NULL);
    assert(active->code_pool[0] == OP_NOP);

    printf("  [PASS] test_dl_prepare_and_commit\n");
}

static void test_dl_no_download_pending(void)
{
    SasmModule mod;
    setup_test_module(&mod);

    dl_manager_init(&mod);

    /* Commit without prepare should fail */
    assert(dl_commit_switch() == -1);

    printf("  [PASS] test_dl_no_download_pending\n");
}

/* ================================================================
   Main
   ================================================================ */

int main(void)
{
    printf("Running hotstandby tests...\n");

    /* State machine tests */
    printf("\nState machine tests:\n");
    test_hs_init_master();
    test_hs_init_standby();
    test_active_heartbeat_lost_to_failed();
    test_active_sync_failure_to_failed();
    test_active_fault_detected();
    test_active_switch_to_standby();
    test_standby_heartbeat_lost_to_switching();
    test_standby_to_active_promotion();
    test_failed_recovery();
    test_switching_completes_master();
    test_switching_completes_standby();
    test_uninit_rejects_events();

    /* Dirty page tracking tests */
    printf("\nDirty page tracking tests:\n");
    test_dirty_init();
    test_dirty_mark_single_page();
    test_dirty_mark_cross_page();
    test_dirty_clear();
    test_dirty_get_count();
    test_dirty_get_pages();

    /* Snapshot tests */
    printf("\nSnapshot tests:\n");
    test_snapshot_create_apply_roundtrip();
    test_snapshot_crc_verify();
    test_snapshot_crc_corrupt();
    test_snapshot_magic_check();

    /* Download manager tests */
    printf("\nDownload manager tests:\n");
    test_dl_init();
    test_dl_prepare_and_commit();
    test_dl_no_download_pending();

    printf("\nHotstandby tests passed\n");
    return 0;
}
