/**
 * tests/vm-tests/test_download_switch.c
 * 全量镜像下装链路 — 收帧 → 装槽 → 周期边界重绑 → 回滚
 *
 * 与 test_download_wire.c 的分工：那里验协议字节层（组帧/校验/拒绝码），
 * 这里验「协议交出来的字节，下装层能不能真的跑起来」——
 * 两层用的必须是同一批字节，否则协议测试就是自欺。
 *
 * 输入是两个真实 .sasm 制品（黄金用例），因为下装的意义就是换一份
 * 编译器真产出的程序；手搓的最小镜像只能证明加载器没崩。
 *
 *   usage: test_download_switch <imageA.sasm> <imageB.sasm>
 */

#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

#include "../../core/vm.h"
#include "../../hotstandby/hotstandby.h"
#include "../../hotstandby/download_wire.h"
#include "../../hotstandby/hmac_sha256.h"

/* 直接把实现拉进来：与 test_hotstandby.c 同样的做法，避免链接整个 libvm_hs */
#include "../../core/loader.c"
#include "../../core/safeasm_interp.c"
#include "../../hotstandby/download.c"
#include "../../hotstandby/download_wire.c"
#include "../../hotstandby/hmac_sha256.c"

#define KEY_LEN SHA256_DIGEST_LEN

static uint8_t g_key[KEY_LEN];
static uint8_t g_raw_a[DL_MAX_IMAGE];
static uint8_t g_raw_b[DL_MAX_IMAGE];
static uint8_t g_work[DL_MAX_IMAGE];
static uint32_t g_len_a;
static uint32_t g_len_b;

static DlReceiver g_rx;
static uint8_t g_stream[DL_FRAME_BUF * 64];

/* ---------- 文件读取 ---------- */

static uint32_t read_file(const char *path, uint8_t *buf, uint32_t cap)
{
    FILE *f = fopen(path, "rb");
    size_t got;

    assert(f != NULL);
    got = fread(buf, 1U, cap, f);
    (void)fclose(f);
    assert((uint32_t)got > 0U);
    assert((uint32_t)got < cap);      /* 恰好读满说明缓冲小了 */
    return (uint32_t)got;
}

/* ---------- 进程内流后端 ---------- */

typedef struct {
    const uint8_t *data;
    uint32_t len;
    uint32_t pos;
    uint32_t chunk;               /* 每次最多喂这么多字节，模拟分片到达 */
} MemIn;

static int mem_feed(void *ctx, uint8_t *buf, uint32_t cap, uint32_t *got)
{
    MemIn *in = (MemIn *)ctx;
    uint32_t n = in->len - in->pos;

    if (n > in->chunk) { n = in->chunk; }
    if (n > cap)       { n = cap; }
    if (n == 0U)       { *got = 0U; return 0; }

    (void)memcpy(buf, in->data + in->pos, n);
    in->pos += n;
    *got = n;
    return 0;
}

static uint32_t g_out_len;

static int mem_drain(void *ctx, const uint8_t *buf, uint32_t len)
{
    (void)ctx;
    assert((g_out_len + len) <= (uint32_t)sizeof(g_stream));
    (void)memcpy(g_stream + g_out_len, buf, len);
    g_out_len += len;
    return 0;
}

/* ---------- 用例 ---------- */

static void t_cold_load_and_run(VM *vm)
{
    assert(dl_manager_load_image(g_raw_a, g_len_a) == DL_RC_OK);
    assert(dl_active_version() == 0U);
    assert(dl_get_active_module() != NULL);
    assert(dl_pending_version() == 0U);

    assert(vm_init(vm, dl_get_active_module(), MEMORY_SIZE) == 0);
    assert(vm_run(vm) == 0);
    assert(vm_run(vm) == 0);
    (void)printf("  [PASS] cold load: version 0 runs two cycles\n");
}

static void t_stage_and_switch(VM *vm)
{
    const SasmModule *mod_a = dl_get_active_module();

    assert(dl_stage_image(g_raw_b, g_len_b) == DL_RC_OK);
    assert(dl_pending_version() == 1U);
    assert(dl_is_download_in_progress());
    /* 提交前活动侧一律不许变：这是"原子"两个字的全部内容 */
    assert(dl_active_version() == 0U);
    assert(vm->module == mod_a);

    vm->memory[4096] = 0xAB;               /* 旧镜像的全局字节 */
    assert(dl_apply_switch(vm) == DL_RC_OK);

    assert(dl_active_version() == 1U);
    assert(!dl_is_download_in_progress());
    assert(vm->module == dl_get_active_module());
    assert(vm->module != mod_a);
    assert(vm->val_stack_ptr == 0U);
    assert(vm->frame_stack_ptr == 0U);
    assert(vm->memory[4096] == 0U);        /* 全量下装 = 冷启动语义 */
    assert(vm_run(vm) == 0);
    (void)printf("  [PASS] switch: new image takes effect at the cycle boundary\n");
}

static void t_rollback_one_level(VM *vm)
{
    const SasmModule *mod_b = dl_get_active_module();
    const SasmModule *back;

    back = dl_rollback(vm);
    assert(back != NULL);
    assert(back != mod_b);
    assert(vm->module == back);
    assert(dl_active_version() == 0U);
    assert(dl_rollback(vm) == NULL);       /* 两槽 ⇒ 只有一级深度 */
    assert(vm_run(vm) == 0);
    (void)printf("  [PASS] rollback returns to the previous slot, once\n");
}

static void t_rejects_bad_images(VM *vm)
{
    const SasmModule *mod = dl_get_active_module();
    uint32_t version = dl_active_version();
    uint32_t i;

    /* 载荷位翻转 ⇒ 加载器 CRC 拒绝（-2） */
    (void)memcpy(g_work, g_raw_b, g_len_b);
    g_work[g_len_b - 5U] = (uint8_t)(g_work[g_len_b - 5U] ^ 0xFFU);
    assert(dl_stage_image(g_work, g_len_b) == DL_RC_ELOAD);
    assert(dl_last_error() == -2);

    /* 未计算的（全零）校验和 ⇒ 同样拒绝，后门已关 */
    (void)memcpy(g_work, g_raw_b, g_len_b);
    for (i = 0U; i < 4U; i++) { g_work[g_len_b - 1U - i] = 0U; }
    assert(dl_stage_image(g_work, g_len_b) == DL_RC_ELOAD);
    assert(dl_last_error() == -2);

    /* 非 .sasm 字节 ⇒ 格式拒绝（-1） */
    (void)memset(g_work, 0x5A, 64U);
    assert(dl_stage_image(g_work, 64U) == DL_RC_ELOAD);
    assert(dl_last_error() == -1);

    /* 超上限与空输入 ⇒ 参数拒绝，memcpy 之前就拦下 */
    assert(dl_stage_image(g_work, DL_MAX_IMAGE + 1U) == DL_RC_EARG);
    assert(dl_stage_image(g_work, 0U) == DL_RC_EARG);
    assert(dl_stage_image(NULL, 10U) == DL_RC_EARG);

    /* 没有任何 pending ⇒ 提交必须拒绝，且 VM 仍在跑旧镜像 */
    assert(dl_apply_switch(vm) == DL_RC_ENOSWITCH);
    assert(dl_apply_switch(NULL) == DL_RC_ENOVMBIND);
    assert(dl_active_version() == version);
    assert(vm->module == mod);
    assert(vm_run(vm) == 0);
    (void)printf("  [PASS] bad images never touch the active slot\n");
}

static void t_wire_handoff(VM *vm)
{
    DlStream tx = { NULL, mem_drain, NULL };
    MemIn in = { g_stream, 0U, 0U, 512U };
    DlStream rx = { mem_feed, NULL, &in };
    bool complete = false;
    const uint8_t *img = NULL;
    uint32_t len = 0U;
    uint32_t version = dl_active_version();
    uint32_t staged = 0U;
    int rc;
    int pumps = 0;

    g_out_len = 0U;
    assert(dl_tx_image(&tx, g_key, g_raw_a, g_len_a) > 0);
    in.len = g_out_len;

    dl_rx_reset(&g_rx);
    /* 512 字节的分片喂入：半帧必须能续上，这是流式接收的全部难度 */
    while (!complete && (pumps < 4096)) {
        rc = dl_rx_pump(&g_rx, &rx, g_key, &complete);
        pumps++;
        if (rc == (int)DL_E_TRUNC) { continue; }
        assert(rc >= 0);
    }
    assert(complete);
    assert(dl_rx_finish(&g_rx, &img, &len) == (int)DL_OK);
    assert(len == g_len_a);
    assert(img != NULL);
    assert(memcmp(img, g_raw_a, g_len_a) == 0);

    /* 交出来的字节直接下装：版本单调递增（回滚不回退版本号），程序能跑 */
    assert(dl_stage_image(img, len) == DL_RC_OK);
    staged = dl_pending_version();
    assert(staged > version);
    assert(dl_apply_switch(vm) == DL_RC_OK);
    assert(dl_active_version() == staged);
    assert(vm_run(vm) == 0);
    (void)printf("  [PASS] frames reassemble into an image the VM actually runs\n");
}

static void t_wire_handoff_rejects_tampering(VM *vm)
{
    DlStream tx = { NULL, mem_drain, NULL };
    MemIn in = { g_stream, 0U, 0U, 4096U };
    DlStream rx = { mem_feed, NULL, &in };
    bool complete = false;
    uint32_t version = dl_active_version();
    uint32_t tamper;
    int rc;

    g_out_len = 0U;
    assert(dl_tx_image(&tx, g_key, g_raw_b, g_len_b) > 0);
    in.len = g_out_len;
    /* 第一帧载荷中间一个字节：MAC 覆盖 ver..payload，必须当场作废 */
    assert((g_len_b / 2U) < DL_MAX_PAYLOAD);   /* 篡改点必须落在首帧载荷内 */
    tamper = DL_HEADER_LEN + (g_len_b / 2U);
    assert(tamper < in.len);
    g_stream[tamper] = (uint8_t)(g_stream[tamper] ^ 0x01U);

    dl_rx_reset(&g_rx);
    do {
        rc = dl_rx_pump(&g_rx, &rx, g_key, &complete);
    } while ((rc == (int)DL_E_TRUNC) && !complete);
    assert(rc == (int)DL_E_HMAC);
    assert(!complete);
    assert(g_rx.failed);

    /* 传输层拒绝 ⇒ 下装层根本不会被调用，活动版本不变 */
    assert(dl_active_version() == version);
    assert(!dl_is_download_in_progress());
    (void)vm;
    (void)printf("  [PASS] a tampered frame never reaches the download layer\n");
}

int main(int argc, char **argv)
{
    static VM vm;

    (void)setvbuf(stdout, NULL, _IONBF, 0);
    if (argc < 3) {
        (void)fprintf(stderr, "usage: %s <imageA.sasm> <imageB.sasm>\n", argv[0]);
        return 2;
    }
    g_len_a = read_file(argv[1], g_raw_a, (uint32_t)sizeof(g_raw_a));
    g_len_b = read_file(argv[2], g_raw_b, (uint32_t)sizeof(g_raw_b));

    for (uint32_t i = 0U; i < KEY_LEN; i++) { g_key[i] = (uint8_t)(i + 1U); }

    (void)printf("== full-image download switch tests ==\n");
    t_cold_load_and_run(&vm);
    t_stage_and_switch(&vm);
    t_rollback_one_level(&vm);
    t_rejects_bad_images(&vm);
    t_wire_handoff(&vm);
    t_wire_handoff_rejects_tampering(&vm);
    (void)printf("all download switch checks passed\n");
    return 0;
}
