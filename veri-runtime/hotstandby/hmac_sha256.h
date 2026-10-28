/**
 * hotstandby/hmac_sha256.h
 * SHA-256 (FIPS 180-4) + HMAC-SHA256 (RFC 2104) —— 下装帧完整性与鉴权的原语
 *
 * 契约见 spec/download-spec.md §3。自含实现：目标机是 RTOS，安全核不链接外部密码库。
 * 无动态内存、无递归、输入长度以 uint32 为界（帧载荷上限远小于 2^32 字节）。
 */

#ifndef HMAC_SHA256_H
#define HMAC_SHA256_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define SHA256_DIGEST_LEN 32U
#define SHA256_BLOCK_LEN  64U
#define HMAC_MAX_KEY_LEN  1024U  /* 密钥长于分块(64)则先哈希；此上限只挡配置错误，
                                    不是标准限制（RFC 4231 TC6 用 131 字节密钥） */

typedef struct {
    uint32_t h[8];
    uint64_t bits;               /* 已吸收的比特数 */
    uint8_t  buf[SHA256_BLOCK_LEN];
    uint32_t buflen;
} Sha256Ctx;

void sha256_init(Sha256Ctx *ctx);
void sha256_update(Sha256Ctx *ctx, const uint8_t *data, uint32_t len);
void sha256_final(Sha256Ctx *ctx, uint8_t out[SHA256_DIGEST_LEN]);

/* 一次性接口 */
void sha256_buf(const uint8_t *data, uint32_t len, uint8_t out[SHA256_DIGEST_LEN]);

/*
 * hmac_sha256 —— 定长 32 字节摘要写入 out。
 * key_len 超过 HMAC_MAX_KEY_LEN 即不计算（返回 -1），因为密钥长度属于配置而非数据，
 * 静默截断会让两侧算出不同的 MAC。
 * 返回 0 = 成功，-1 = 参数无效。
 */
int hmac_sha256(const uint8_t *key, uint32_t key_len,
                const uint8_t *msg, uint32_t msg_len,
                uint8_t out[SHA256_DIGEST_LEN]);

/* 定长比较：不随内容快慢不同而提前返回，避免把 MAC 比较做成计时侧信道。 */
int hmac_equal(const uint8_t a[SHA256_DIGEST_LEN],
               const uint8_t b[SHA256_DIGEST_LEN]);

#ifdef __cplusplus
}
#endif

#endif /* HMAC_SHA256_H */
