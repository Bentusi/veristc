/**
 * hotstandby/hmac_sha256.c
 * SHA-256 + HMAC-SHA256 —— 自含实现，无外部依赖
 *
 * 正确性由 tests/vm-tests/test_download_wire.c 用 RFC 4231 官方向量钉住；
 * 本机没有可信的第三方实现可参照，所以"能跑"不构成证据，向量才是。
 */

#include <string.h>

#include "hmac_sha256.h"

#define DL_ROTATE(x, n) (((x) >> (n)) | ((x) << (32U - (n))))

static const uint32_t sha256_k[64] = {
    0x428a2f98U, 0x71374491U, 0xb5c0fbcfU, 0xe9b5dba5U,
    0x3956c25bU, 0x59f111f1U, 0x923f82a4U, 0xab1c5ed5U,
    0xd807aa98U, 0x12835b01U, 0x243185beU, 0x550c7dc3U,
    0x72be5d74U, 0x80deb1feU, 0x9bdc06a7U, 0xc19bf174U,
    0xe49b69c1U, 0xefbe4786U, 0x0fc19dc6U, 0x240ca1ccU,
    0x2de92c6fU, 0x4a7484aaU, 0x5cb0a9dcU, 0x76f988daU,
    0x983e5152U, 0xa831c66dU, 0xb00327c8U, 0xbf597fc7U,
    0xc6e00bf3U, 0xd5a79147U, 0x06ca6351U, 0x14292967U,
    0x27b70a85U, 0x2e1b2138U, 0x4d2c6dfcU, 0x53380d13U,
    0x650a7354U, 0x766a0abbU, 0x81c2c92eU, 0x92722c85U,
    0xa2bfe8a1U, 0xa81a664bU, 0xc24b8b70U, 0xc76c51a3U,
    0xd192e819U, 0xd6990624U, 0xf40e3585U, 0x106aa070U,
    0x19a4c116U, 0x1e376c08U, 0x2748774cU, 0x34b0bcb5U,
    0x391c0cb3U, 0x4ed8aa4aU, 0x5b9cca4fU, 0x682e6ff3U,
    0x748f82eeU, 0x78a5636fU, 0x84c87814U, 0x8cc70208U,
    0x90befffaU, 0xa4506cebU, 0xbef9a3f7U, 0xc67178f2U
};

static const uint32_t sha256_h0[8] = {
    0x6a09e667U, 0xbb67ae85U, 0x3c6ef372U, 0xa54ff53aU,
    0x510e527fU, 0x9b05688cU, 0x1f83d9abU, 0x5be0cd19U
};

static void sha256_compress(Sha256Ctx *ctx, const uint8_t *p)
{
    uint32_t w[64];
    uint32_t a, b, c, d, e, f, g, h;
    uint32_t i;

    for (i = 0U; i < 16U; i++) {
        const uint8_t *q = p + (i * 4U);
        w[i] = ((uint32_t)q[0] << 24) | ((uint32_t)q[1] << 16) |
               ((uint32_t)q[2] << 8) | (uint32_t)q[3];
    }
    for (i = 16U; i < 64U; i++) {
        uint32_t s0 = DL_ROTATE(w[i - 15U], 7U) ^ DL_ROTATE(w[i - 15U], 18U) ^
                      (w[i - 15U] >> 3U);
        uint32_t s1 = DL_ROTATE(w[i - 2U], 17U) ^ DL_ROTATE(w[i - 2U], 19U) ^
                      (w[i - 2U] >> 10U);
        w[i] = w[i - 16U] + s0 + w[i - 7U] + s1;
    }

    a = ctx->h[0]; b = ctx->h[1]; c = ctx->h[2]; d = ctx->h[3];
    e = ctx->h[4]; f = ctx->h[5]; g = ctx->h[6]; h = ctx->h[7];

    for (i = 0U; i < 64U; i++) {
        uint32_t S1 = DL_ROTATE(e, 6U) ^ DL_ROTATE(e, 11U) ^ DL_ROTATE(e, 25U);
        uint32_t ch = (e & f) ^ ((~e) & g);
        uint32_t t1 = h + S1 + ch + sha256_k[i] + w[i];
        uint32_t S0 = DL_ROTATE(a, 2U) ^ DL_ROTATE(a, 13U) ^ DL_ROTATE(a, 22U);
        uint32_t maj = (a & b) ^ (a & c) ^ (b & c);
        uint32_t t2 = S0 + maj;

        h = g; g = f; f = e; e = d + t1;
        d = c; c = b; b = a; a = t1 + t2;
    }

    ctx->h[0] += a; ctx->h[1] += b; ctx->h[2] += c; ctx->h[3] += d;
    ctx->h[4] += e; ctx->h[5] += f; ctx->h[6] += g; ctx->h[7] += h;
}

void sha256_init(Sha256Ctx *ctx)
{
    uint32_t i;

    if (ctx == NULL) { return; }
    for (i = 0U; i < 8U; i++) { ctx->h[i] = sha256_h0[i]; }
    ctx->bits = 0ULL;
    ctx->buflen = 0U;
}

void sha256_update(Sha256Ctx *ctx, const uint8_t *data, uint32_t len)
{
    if ((ctx == NULL) || ((data == NULL) && (len > 0U))) { return; }

    ctx->bits += (uint64_t)len * 8ULL;
    while (len > 0U) {
        uint32_t take = SHA256_BLOCK_LEN - ctx->buflen;
        if (take > len) { take = len; }
        (void)memcpy(ctx->buf + ctx->buflen, data, take);
        ctx->buflen += take;
        data += take;
        len -= take;
        if (ctx->buflen == SHA256_BLOCK_LEN) {
            sha256_compress(ctx, ctx->buf);
            ctx->buflen = 0U;
        }
    }
}

void sha256_final(Sha256Ctx *ctx, uint8_t out[SHA256_DIGEST_LEN])
{
    /* 填充 = 0x80 + 零 + 8 字节大端长度；长度字段可能与填充跨出同一个分块，
       所以 pad 需要 block + 8 字节 */
    uint8_t pad[SHA256_BLOCK_LEN + 8U];
    uint64_t bits;
    uint32_t pad_len;
    uint32_t i;

    if ((ctx == NULL) || (out == NULL)) { return; }

    bits = ctx->bits;
    pad_len = (ctx->buflen < 56U) ? (56U - ctx->buflen)
                                  : (120U - ctx->buflen);
    pad[0] = 0x80U;
    for (i = 1U; i < pad_len; i++) { pad[i] = 0x00U; }
    for (i = 0U; i < 8U; i++) {
        pad[pad_len + i] = (uint8_t)((bits >> (56U - (i * 8U))) & 0xFFULL);
    }
    sha256_update(ctx, pad, pad_len + 8U);

    for (i = 0U; i < 8U; i++) {
        out[i * 4U]        = (uint8_t)((ctx->h[i] >> 24) & 0xFFU);
        out[(i * 4U) + 1U] = (uint8_t)((ctx->h[i] >> 16) & 0xFFU);
        out[(i * 4U) + 2U] = (uint8_t)((ctx->h[i] >> 8) & 0xFFU);
        out[(i * 4U) + 3U] = (uint8_t)(ctx->h[i] & 0xFFU);
    }
    (void)memset(ctx, 0, sizeof(*ctx));
}

void sha256_buf(const uint8_t *data, uint32_t len, uint8_t out[SHA256_DIGEST_LEN])
{
    Sha256Ctx ctx;

    sha256_init(&ctx);
    sha256_update(&ctx, data, len);
    sha256_final(&ctx, out);
}

/* 把密钥整理成一个 64 字节分块：过长先哈希，过短零填充 */
static int hmac_prepare_key(const uint8_t *key, uint32_t key_len,
                            uint8_t block[SHA256_BLOCK_LEN])
{
    if ((key == NULL) || (key_len == 0U)) { return -1; }
    (void)memset(block, 0, SHA256_BLOCK_LEN);
    if (key_len > SHA256_BLOCK_LEN) {
        if (key_len > HMAC_MAX_KEY_LEN) { return -1; }
        sha256_buf(key, key_len, block);   /* 32 < 64，其余保持零 */
    } else {
        (void)memcpy(block, key, key_len);
    }
    return 0;
}

int hmac_sha256(const uint8_t *key, uint32_t key_len,
               const uint8_t *msg, uint32_t msg_len,
               uint8_t out[SHA256_DIGEST_LEN])
{
    uint8_t block[SHA256_BLOCK_LEN];
    Sha256Ctx ctx;
    uint8_t inner[SHA256_DIGEST_LEN];
    uint32_t i;

    if ((msg == NULL) && (msg_len > 0U)) { return -1; }
    if (out == NULL) { return -1; }
    if (hmac_prepare_key(key, key_len, block) != 0) { return -1; }

    for (i = 0U; i < SHA256_BLOCK_LEN; i++) { block[i] ^= 0x36U; }
    sha256_init(&ctx);
    sha256_update(&ctx, block, SHA256_BLOCK_LEN);
    sha256_update(&ctx, msg, msg_len);
    sha256_final(&ctx, inner);

    for (i = 0U; i < SHA256_BLOCK_LEN; i++) { block[i] ^= (0x36U ^ 0x5CU); }
    sha256_init(&ctx);
    sha256_update(&ctx, block, SHA256_BLOCK_LEN);
    sha256_update(&ctx, inner, SHA256_DIGEST_LEN);
    sha256_final(&ctx, out);

    (void)memset(block, 0, sizeof(block));
    (void)memset(inner, 0, sizeof(inner));
    return 0;
}

int hmac_equal(const uint8_t a[SHA256_DIGEST_LEN],
               const uint8_t b[SHA256_DIGEST_LEN])
{
    uint8_t diff = 0U;
    uint32_t i;

    if ((a == NULL) || (b == NULL)) { return 0; }
    for (i = 0U; i < SHA256_DIGEST_LEN; i++) {
        diff |= (uint8_t)(a[i] ^ b[i]);
    }
    return (diff == 0U) ? 1 : 0;
}
