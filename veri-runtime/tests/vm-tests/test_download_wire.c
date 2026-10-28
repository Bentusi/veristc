/**
 * tests/vm-tests/test_download_wire.c
 * 下装帧协议 + HMAC-SHA256 单元测试
 *
 * 两件事必须各自有证据：
 *   1. 密码原语正确 —— RFC 4231 / FIPS 180-4 官方向量，不是"我们自己算的数"
 *   2. 状态机把每一类畸形帧拒在正确的那一步，并且拒绝码与 spec 表一致
 * 构造畸形帧时用到的"重算 MAC"只出现在测试里，实现侧没有任何绕过路径。
 */

#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

#include "../../hotstandby/hmac_sha256.h"
#include "../../hotstandby/download_wire.h"

#define KEY_LEN SHA256_DIGEST_LEN

static uint8_t g_key[KEY_LEN];

/* ---------------- 内存流后端（G0 的 pair 替身） ---------------- */

typedef struct {
    const uint8_t *buf;
    uint32_t len;
    uint32_t pos;
    uint32_t chunk;      /* 每次最多喂出多少字节；1 = 逐字节喂 */
} MemIn;

typedef struct {
    uint8_t *buf;
    uint32_t len;        /* 已写入 */
    uint32_t cap;
} MemOut;

static int mem_feed(void *ctx, uint8_t *out, uint32_t cap, uint32_t *got)
{
    MemIn *m = (MemIn *)ctx;
    uint32_t avail = m->len - m->pos;
    uint32_t n = (avail < cap) ? avail : cap;

    if ((m->chunk > 0U) && (n > m->chunk)) { n = m->chunk; }
    if (n > 0U) { (void)memcpy(out, m->buf + m->pos, n); }
    m->pos += n;
    *got = n;
    return 0;
}

static int mem_drain(void *ctx, const uint8_t *buf, uint32_t len)
{
    MemOut *o = (MemOut *)ctx;

    if ((o->len + len) > o->cap) { return -1; }
    (void)memcpy(o->buf + o->len, buf, len);
    o->len += len;
    return 0;
}

/* ---------------- 参考摘要（python3 hashlib/hmac 生成） ---------------- */

static int hex_to_bytes(const char *hex, uint8_t *out, uint32_t cap)
{
    uint32_t i;
    uint32_t n = (uint32_t)strlen(hex) / 2U;

    if (n > cap) { return -1; }
    for (i = 0U; i < n; i++) {
        char b[3];
        b[0] = hex[i * 2U]; b[1] = hex[(i * 2U) + 1U]; b[2] = '\0';
        out[i] = (uint8_t)strtol(b, NULL, 16);
    }
    return (int)n;
}

static void t_sha256_vectors(void)
{
    struct { const char *msg_label; const uint8_t *msg; uint32_t len;
             const char *want; } v[4];
    static uint8_t million[1000000];
    uint8_t got[SHA256_DIGEST_LEN];
    uint8_t want[SHA256_DIGEST_LEN];
    uint32_t i;

    (void)memset(million, 'a', sizeof(million));

    v[0].msg_label = "abc";   v[0].msg = (const uint8_t *)"abc"; v[0].len = 3U;
    v[0].want = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
    v[1].msg_label = "empty"; v[1].msg = NULL; v[1].len = 0U;
    v[1].want = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
    v[2].msg_label = "448-bit"; v[2].msg =
        (const uint8_t *)"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq";
    v[2].len = 56U;
    v[2].want = "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1";
    v[3].msg_label = "1e6 x 'a'"; v[3].msg = million; v[3].len = 1000000U;
    v[3].want = "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0";

    for (i = 0U; i < 4U; i++) {
        assert(hex_to_bytes(v[i].want, want, sizeof(want)) == 32);
        sha256_buf(v[i].msg, v[i].len, got);
        if (memcmp(got, want, SHA256_DIGEST_LEN) != 0) {
            (void)printf("  SHA-256 vector %s ... FAIL\n", v[i].msg_label);
            assert(0);
        }
    }
    /* 跨分块边界的一组长度：55/56/57/63/64/65 覆盖填充的两条分支 */
    {
        uint8_t buf[72];
        uint8_t ref[SHA256_DIGEST_LEN];
        Sha256Ctx c;
        uint32_t lens[6] = { 55U, 56U, 57U, 63U, 64U, 65U };
        uint32_t k;
        for (k = 0U; k < 6U; k++) {
            (void)memset(buf, 0x5AU, sizeof(buf));
            sha256_buf(buf, lens[k], got);
            /* 分两次喂必须与一次喂等价（缓冲边界不吞字节） */
            sha256_init(&c);
            sha256_update(&c, buf, lens[k] / 2U);
            sha256_update(&c, buf + (lens[k] / 2U), lens[k] - (lens[k] / 2U));
            sha256_final(&c, ref);
            assert(memcmp(got, ref, SHA256_DIGEST_LEN) == 0);
        }
    }
    (void)printf("  [PASS] sha256 matches FIPS vectors and block boundaries\n");
}

static void t_hmac_rfc4231(void)
{
    struct { const uint8_t *key; uint32_t klen; const uint8_t *data;
             uint32_t dlen; const char *want; } tc[5];
    static const uint8_t k1[20] = {
        0x0b,0x0b,0x0b,0x0b,0x0b,0x0b,0x0b,0x0b,0x0b,0x0b,
        0x0b,0x0b,0x0b,0x0b,0x0b,0x0b,0x0b,0x0b,0x0b,0x0b };
    static const uint8_t k3[20] = {
        0xaa,0xaa,0xaa,0xaa,0xaa,0xaa,0xaa,0xaa,0xaa,0xaa,
        0xaa,0xaa,0xaa,0xaa,0xaa,0xaa,0xaa,0xaa,0xaa,0xaa };
    static const uint8_t k4[25] = {
        0x01,0x02,0x03,0x04,0x05,0x06,0x07,0x08,0x09,0x0a,
        0x0b,0x0c,0x0d,0x0e,0x0f,0x10,0x11,0x12,0x13,0x14,
        0x15,0x16,0x17,0x18,0x19 };
    static uint8_t dd[50], cd[50];
    static uint8_t k6[131];
    uint8_t got[SHA256_DIGEST_LEN], want[SHA256_DIGEST_LEN];
    uint32_t i;

    (void)memset(dd, 0xdd, sizeof(dd));
    (void)memset(cd, 0xcd, sizeof(cd));
    (void)memset(k6, 0xaa, sizeof(k6));

    tc[0].key = k1; tc[0].klen = 20U;
    tc[0].data = (const uint8_t *)"Hi There"; tc[0].dlen = 8U;
    tc[0].want = "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7";
    tc[1].key = (const uint8_t *)"Jefe"; tc[1].klen = 4U;
    tc[1].data = (const uint8_t *)"what do ya want for nothing?"; tc[1].dlen = 28U;
    tc[1].want = "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843";
    tc[2].key = k3; tc[2].klen = 20U;
    tc[2].data = dd; tc[2].dlen = 50U;
    tc[2].want = "773ea91e36800e46854db8ebd09181a72959098b3ef8c122d9635514ced565fe";
    tc[3].key = k4; tc[3].klen = 25U;
    tc[3].data = cd; tc[3].dlen = 50U;
    /* RFC 4231 TC4：key = 0x01..0x19（不是 25 个 0x01） */
    tc[3].want = "82558a389a443c0ea4cc819899f2083a85f0faa3e578f8077a2e3ff46729665b";
    tc[4].key = k6; tc[4].klen = 131U;
    tc[4].data = (const uint8_t *)
        "Test Using Larger Than Block-Size Key - Hash Key First";
    tc[4].dlen = 54U;
    tc[4].want = "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54";

    for (i = 0U; i < 5U; i++) {
        assert(hex_to_bytes(tc[i].want, want, sizeof(want)) == 32);
        assert(hmac_sha256(tc[i].key, tc[i].klen, tc[i].data, tc[i].dlen,
                           got) == 0);
        if (memcmp(got, want, SHA256_DIGEST_LEN) != 0) {
            (void)printf("  HMAC vector TC%u ... FAIL\n", i + 1U);
            (void)printf("    got  ");
            for (uint32_t j = 0U; j < SHA256_DIGEST_LEN; j++) {
                (void)printf("%02x", got[j]);
            }
            (void)printf("\n    want %s\n", tc[i].want);
            (void)fflush(stdout);
            assert(0);
        }
    }
    /* 空密钥不是"密钥长度为 0 的 HMAC"，而是配置缺失 —— 必须拒绝 */
    assert(hmac_sha256(g_key, 0U, (const uint8_t *)"x", 1U, got) == -1);
    (void)printf("  [PASS] hmac-sha256 matches RFC 4231 TC1-4/TC6, empty key refused\n");
}

/* ---------------- 帧级测试 ---------------- */

static DlReceiver g_rx;

/* 测试专用：改完字节后重算 MAC，用来单独钉住 CRC 那一道闸门。
   实现侧没有任何"重算"入口，所以真实伪造者做不到这一步。 */
static void resign(uint8_t *frame)
{
    uint32_t payload_len = (uint32_t)frame[16] | ((uint32_t)frame[17] << 8) |
                           ((uint32_t)frame[18] << 16) | ((uint32_t)frame[19] << 24);
    (void)hmac_sha256(g_key, KEY_LEN, frame + 4U,
                      (uint32_t)DL_HEADER_LEN - 4U + payload_len,
                      frame + DL_HEADER_LEN + payload_len);
}

static void put_u32_le(uint8_t *b, uint32_t v)
{
    b[0] = (uint8_t)(v & 0xFFU); b[1] = (uint8_t)((v >> 8) & 0xFFU);
    b[2] = (uint8_t)((v >> 16) & 0xFFU); b[3] = (uint8_t)((v >> 24) & 0xFFU);
}

/* 把整个镜像发出并被接收侧收下；返回最后一个状态码 */
static int run_stream(const uint8_t *stream, uint32_t len, uint32_t chunk,
                      const uint8_t key[KEY_LEN], bool *complete,
                      const uint8_t **image, uint32_t *img_len)
{
    MemIn in = { stream, len, 0U, chunk };
    DlStream io;
    int last = (int)DL_E_INCOMPLETE;
    int guard = 0;

    io.feed = mem_feed; io.drain = NULL; io.ctx = &in;
    dl_rx_reset(&g_rx);
    *complete = false;
    while ((in.pos < in.len) && (guard < 10000)) {
        bool done = false;
        int rc = dl_rx_pump(&g_rx, &io, key, &done);
        guard++;
        if ((rc != (int)DL_OK) && (rc != (int)DL_E_TRUNC)) { return rc; }
        if (done) { *complete = true; }
        last = rc;
    }
    {
        int fin = dl_rx_finish(&g_rx, image, img_len);
        if (fin != (int)DL_OK) { return fin; }
    }
    return last;
}

static void t_frame_roundtrip(void)
{
    static uint8_t stream[DL_FRAME_BUF * 4];
    static uint8_t image[10000];
    MemOut out = { stream, 0U, sizeof(stream) };
    DlStream io = { NULL, mem_drain, &out };
    const uint8_t *got_img = NULL;
    uint32_t got_len = 0U;
    bool complete = false;
    uint32_t i;
    int frames;

    for (i = 0U; i < sizeof(image); i++) { image[i] = (uint8_t)(i & 0xFFU); }
    frames = dl_tx_image(&io, g_key, image, (uint32_t)sizeof(image));
    /* 10000 = 4096 + 4096 + 1808 ⇒ 3 帧 */
    assert(frames == 3);

    {
        int rc = run_stream(stream, out.len, 0U, g_key, &complete,
                            &got_img, &got_len);
        assert(rc == (int)DL_OK);
    }
    assert(complete);
    assert(got_len == (uint32_t)sizeof(image));
    assert(memcmp(got_img, image, sizeof(image)) == 0);

    /* 逐字节喂（半帧跨 read 边界）必须得到同一结果 */
    {
        int rc = run_stream(stream, out.len, 1U, g_key, &complete,
                            &got_img, &got_len);
        assert(rc == (int)DL_OK);
        assert(complete && (got_len == (uint32_t)sizeof(image)));
        assert(memcmp(got_img, image, sizeof(image)) == 0);
    }
    assert(dl_rx_progress(&g_rx) == 100U);
    (void)printf("  [PASS] multi-frame image reassembles, byte-drip too\n");
}

static void t_rejections(void)
{
    static uint8_t stream[DL_FRAME_BUF * 4];
    static uint8_t bad[DL_FRAME_BUF * 4];
    static uint8_t image[5000];
    MemOut out = { stream, 0U, sizeof(stream) };
    DlStream io = { NULL, mem_drain, &out };
    const uint8_t *got_img = NULL;
    uint32_t got_len = 0U;
    bool complete = false;
    uint32_t i;
    int rc;
    uint8_t other_key[KEY_LEN];

    for (i = 0U; i < sizeof(image); i++) { image[i] = (uint8_t)(i * 3U); }
    assert(dl_tx_image(&io, g_key, image, (uint32_t)sizeof(image)) == 2);

    /* 1) 载荷被改一个字节 ⇒ MAC 不过（不是 CRC，因为先验 MAC） */
    (void)memcpy(bad, stream, out.len);
    bad[DL_HEADER_LEN + 10U] ^= 0x01U;
    rc = run_stream(bad, out.len, 0U, g_key, &complete, &got_img, &got_len);
    assert(rc == (int)DL_E_HMAC);

    /* 2) 密钥不同 ⇒ 同一帧流整体作废 */
    (void)memset(other_key, 0x5c, sizeof(other_key));
    rc = run_stream(stream, out.len, 0U, other_key, &complete,
                    &got_img, &got_len);
    assert(rc == (int)DL_E_HMAC);

    /* 3) 头字段被改（image_len）⇒ MAC 不过：鉴权覆盖整个语义头 */
    (void)memcpy(bad, stream, out.len);
    put_u32_le(bad + 8U, 4999U);
    rc = run_stream(bad, out.len, 0U, g_key, &complete, &got_img, &got_len);
    assert(rc == (int)DL_E_HMAC);

    /* 4) CRC 字段单独造假且重算 MAC ⇒ 只能被 CRC 这一道拦住 */
    (void)memcpy(bad, stream, out.len);
    put_u32_le(bad + 20U, 0xDEADBEEFU);
    resign(bad);
    rc = run_stream(bad, out.len, 0U, g_key, &complete, &got_img, &got_len);
    assert(rc == (int)DL_E_CRC);

    /* 5) 丢掉首帧、只喂第二帧 ⇒ 序号断裂（G0 不重传，出现即整镜像作废） */
    {
        uint32_t frame0_len = DL_HEADER_LEN + 4096U + SHA256_DIGEST_LEN;

        assert(out.len > frame0_len);
        rc = run_stream(stream + frame0_len, out.len - frame0_len, 0U, g_key,
                        &complete, &got_img, &got_len);
        assert(rc == (int)DL_E_SEQ);
    }

    /* 6) image_len 超过上限或为 0：发送侧直接拒绝 */
    {
        MemOut h = { stream, 0U, sizeof(stream) };
        DlStream hio = { NULL, mem_drain, &h };
        assert(dl_tx_image(&hio, g_key, image, DL_MAX_IMAGE + 1U)
               == (int)DL_E_IMAGE_LEN);
        assert(dl_tx_image(&hio, g_key, image, 0U) == (int)DL_E_IMAGE_LEN);
        assert(dl_tx_image(&hio, g_key, NULL, 10U) == (int)DL_E_IMAGE_LEN);
    }

    /* 7) 接收侧自造的越界头：MAC 合法但 image_len 超限 */
    {
        static uint8_t f[DL_FRAME_BUF];
        MemOut h = { stream, 0U, sizeof(stream) };
        DlStream hio = { NULL, mem_drain, &h };
        int flen = dl_frame_build(f, sizeof(f), (uint8_t)DL_KIND_DATA,
                                  DL_FLAG_LAST, DL_MAX_IMAGE + 1U, 0U,
                                  image, 16U, g_key);
        assert(flen > 0);
        (void)hio;
        rc = run_stream(f, (uint32_t)flen, 0U, g_key, &complete,
                        &got_img, &got_len);
        assert(rc == (int)DL_E_IMAGE_LEN);
    }

    /* 8) 声明 image_len=100 只发 50 ⇒ 未完成 */
    {
        static uint8_t f[DL_FRAME_BUF];
        int flen = dl_frame_build(f, sizeof(f), (uint8_t)DL_KIND_DATA,
                                  0U, 100U, 0U, image, 50U, g_key);
        assert(flen > 0);
        rc = run_stream(f, (uint32_t)flen, 0U, g_key, &complete,
                        &got_img, &got_len);
        assert(rc == (int)DL_E_INCOMPLETE);
        assert(!complete);
    }

    /* 9) 载荷超出 image_len ⇒ 越界 */
    {
        static uint8_t f[DL_FRAME_BUF];
        static uint8_t f2[DL_FRAME_BUF];
        uint8_t both[DL_FRAME_BUF * 2];
        int flen, flen2;

        flen = dl_frame_build(f, sizeof(f), (uint8_t)DL_KIND_DATA, 0U,
                              10U, 0U, image, 8U, g_key);
        flen2 = dl_frame_build(f2, sizeof(f2), (uint8_t)DL_KIND_DATA,
                               DL_FLAG_LAST, 10U, 1U, image, 8U, g_key);
        assert((flen > 0) && (flen2 > 0));
        (void)memcpy(both, f, (size_t)flen);
        (void)memcpy(both + flen, f2, (size_t)flen2);
        rc = run_stream(both, (uint32_t)(flen + flen2), 0U, g_key, &complete,
                        &got_img, &got_len);
        assert(rc == (int)DL_E_OVER);
    }

    /* 10) 非本协议：magic 与版本各自可辨 */
    {
        static uint8_t f[DL_FRAME_BUF];
        int flen = dl_frame_build(f, sizeof(f), (uint8_t)DL_KIND_DATA,
                                  DL_FLAG_LAST, 4U, 0U, image, 4U, g_key);
        assert(flen > 0);
        f[0] ^= 0x01U;
        rc = run_stream(f, (uint32_t)flen, 0U, g_key, &complete,
                        &got_img, &got_len);
        assert(rc == (int)DL_E_MAGIC);
        flen = dl_frame_build(f, sizeof(f), (uint8_t)DL_KIND_DATA,
                              DL_FLAG_LAST, 4U, 0U, image, 4U, g_key);
        assert(flen > 0);
        f[4] = 2U;
        rc = run_stream(f, (uint32_t)flen, 0U, g_key, &complete,
                        &got_img, &got_len);
        assert(rc == (int)DL_E_MAGIC);
    }

    /* 11) 作废是粘性的：拒绝之后同一 rx 不会吸收后续任何帧 */
    {
        int again = dl_rx_pump(&g_rx, &io, g_key, &complete);
        assert(again == rc || again == (int)DL_E_STATE || again < 0);
        assert(g_rx.failed);
    }
    (void)printf("  [PASS] every malformed frame class is refused at the right step\n");
}

static void t_tx_too_big_for_receiver(void)
{
    static uint8_t big[DL_MAX_IMAGE];
    static uint8_t stream[DL_FRAME_BUF];   /* 故意只够一帧：验证 drain 失败被上报 */
    MemOut out = { stream, 0U, sizeof(stream) };
    DlStream io = { NULL, mem_drain, &out };
    uint32_t i;

    for (i = 0U; i < sizeof(big); i++) { big[i] = (uint8_t)i; }
    /* 链路写满 ⇒ dl_tx_image 必须上报失败，而不是丢帧继续（发送侧静默截断
       会让接收侧永远等不到末帧） */
    assert(dl_tx_image(&io, g_key, big, DL_MAX_IMAGE) < 0);
    (void)printf("  [PASS] sender reports transport failure instead of dropping frames\n");
}

int main(void)
{
    uint32_t i;

    /* 断言失败会 abort：行缓冲的输出会整批丢失，先关缓冲再跑 */
    (void)setvbuf(stdout, NULL, _IONBF, 0);

    for (i = 0U; i < KEY_LEN; i++) { g_key[i] = (uint8_t)(i + 1U); }

    (void)printf("== download wire protocol tests ==\n");
    t_sha256_vectors();
    t_hmac_rfc4231();
    t_frame_roundtrip();
    t_rejections();
    t_tx_too_big_for_receiver();
    (void)printf("all download wire checks passed\n");
    return 0;
}
