/**
 * hotstandby/download_wire.c
 * 下装帧协议实现 —— 契约见 download_wire.h 与 spec/download-spec.md
 *
 * 发送侧组帧、接收侧状态机都是纯计算 + 一对回调，不含任何 socket 调用：
 * 这样协议逻辑可以在普通主机测试里跑完整状态机，而 MISRA 敏感的链路 API
 * 留在 agent 主程序那一层（plan §6.2 的解耦理由）。
 */

#include <string.h>

#include "download_wire.h"

/* CRC32 与 .sasm 尾部用的是同一张表（同一个真值，不另立多项式） */
static const uint32_t dl_crc32_table[256] = {
#include "../core/crc32_table.inc"
};

static uint32_t dl_crc32(const uint8_t *data, uint32_t len)
{
    uint32_t crc = 0xFFFFFFFFU;
    uint32_t i;

    for (i = 0U; i < len; i++) {
        uint8_t index = (uint8_t)((crc ^ data[i]) & 0xFFU);
        crc = (crc >> 8) ^ dl_crc32_table[index];
    }
    return crc ^ 0xFFFFFFFFU;
}

static void dl_put_u32(uint8_t *b, uint32_t v)
{
    b[0] = (uint8_t)(v & 0xFFU);
    b[1] = (uint8_t)((v >> 8) & 0xFFU);
    b[2] = (uint8_t)((v >> 16) & 0xFFU);
    b[3] = (uint8_t)((v >> 24) & 0xFFU);
}

static uint32_t dl_get_u32(const uint8_t *b)
{
    return (uint32_t)b[0] | ((uint32_t)b[1] << 8) |
           ((uint32_t)b[2] << 16) | ((uint32_t)b[3] << 24);
}

static void dl_put_u16(uint8_t *b, uint16_t v)
{
    b[0] = (uint8_t)(v & 0xFFU);
    b[1] = (uint8_t)((v >> 8) & 0xFFU);
}

static uint16_t dl_get_u16(const uint8_t *b)
{
    return (uint16_t)((uint16_t)b[0] | ((uint16_t)b[1] << 8));
}

/* ================================================================
   组帧
   ================================================================ */

int dl_frame_build(uint8_t *out, uint32_t cap, uint8_t kind, uint16_t flags,
                   uint32_t image_len, uint32_t seq,
                   const uint8_t *payload, uint32_t payload_len,
                   const uint8_t key[SHA256_DIGEST_LEN])
{
    uint32_t frame_len;

    if ((out == NULL) || (key == NULL)) { return -1; }
    if (payload_len > DL_MAX_PAYLOAD) { return -2; }
    if ((payload_len > 0U) && (payload == NULL)) { return -3; }
    frame_len = DL_HEADER_LEN + payload_len + SHA256_DIGEST_LEN;
    if (cap < frame_len) { return -4; }

    dl_put_u32(out + 0U, DL_MAGIC);
    out[4] = (uint8_t)DL_VER;
    out[5] = kind;
    dl_put_u16(out + 6U, flags);
    dl_put_u32(out + 8U, image_len);
    dl_put_u32(out + 12U, seq);
    dl_put_u32(out + 16U, payload_len);
    dl_put_u32(out + 20U,
               (payload_len > 0U) ? dl_crc32(payload, payload_len) : 0U);
    if (payload_len > 0U) {
        (void)memcpy(out + DL_HEADER_LEN, payload, payload_len);
    }
    /* MAC 覆盖 ver..payload：magic 只是分帧提示，不进鉴权范围 */
    if (hmac_sha256(key, SHA256_DIGEST_LEN, out + 4U,
                    (uint32_t)(DL_HEADER_LEN - 4U) + payload_len,
                    out + DL_HEADER_LEN + payload_len) != 0) {
        return -5;
    }
    return (int)frame_len;
}

int dl_tx_image(DlStream *io, const uint8_t key[SHA256_DIGEST_LEN],
                const uint8_t *image, uint32_t len)
{
    uint8_t  frame[DL_FRAME_BUF];
    uint32_t off = 0U;
    uint32_t seq = 0U;
    int      sent = 0;

    if ((io == NULL) || (io->drain == NULL) || (key == NULL)) { return -1; }
    /* 空镜像不是程序：.sasm 至少要有文件头 + 段头 + CRC */
    if ((image == NULL) || (len == 0U) || (len > DL_MAX_IMAGE)) {
        return (int)DL_E_IMAGE_LEN;
    }

    while (off < len) {
        uint32_t n = len - off;
        uint16_t flags = 0U;
        int flen;

        if (n > DL_MAX_PAYLOAD) { n = DL_MAX_PAYLOAD; }
        if ((off + n) == len) { flags = DL_FLAG_LAST; }
        flen = dl_frame_build(frame, sizeof(frame), (uint8_t)DL_KIND_DATA,
                              flags, len, seq, image + off, n, key);
        if (flen <= 0) { return flen; }
        if (io->drain(io->ctx, frame, (uint32_t)flen) != 0) { return -2; }
        off = off + n;
        seq = seq + 1U;
        sent = sent + 1;
    }
    return sent;
}

/* ================================================================
   接收侧状态机
   ================================================================ */

void dl_rx_reset(DlReceiver *rx)
{
    if (rx == NULL) { return; }
    (void)memset(rx, 0, sizeof(*rx));
}

static void dl_fail(DlReceiver *rx, int code)
{
    rx->failed = true;
    rx->last_error = code;
}

/* 校验并吸收 scratch 里的一整帧；scratch_len 已 >= 帧长 */
static int dl_rx_absorb(DlReceiver *rx, const uint8_t key[SHA256_DIGEST_LEN])
{
    const uint8_t *f = rx->scratch;
    uint32_t payload_len = dl_get_u32(f + 16U);
    uint32_t image_len   = dl_get_u32(f + 8U);
    uint32_t seq         = dl_get_u32(f + 12U);
    uint32_t crc         = dl_get_u32(f + 20U);
    uint16_t flags       = dl_get_u16(f + 6U);
    uint8_t  kind        = f[5];
    uint32_t frame_len;
    uint8_t  mac[SHA256_DIGEST_LEN];

    if (dl_get_u32(f + 0U) != DL_MAGIC) { return (int)DL_E_MAGIC; }
    if (f[4] != (uint8_t)DL_VER) { return (int)DL_E_MAGIC; }
    if (payload_len > DL_MAX_PAYLOAD) { return (int)DL_E_LEN; }
    frame_len = DL_HEADER_LEN + payload_len + SHA256_DIGEST_LEN;
    if (rx->scratch_len != frame_len) { return (int)DL_E_LEN; }

    /* 先验 MAC 再验 CRC：MAC 不过说明这帧不属于本次下装，
       它的 CRC 字段同样不可信，按损坏处理会把鉴权失败误诊成线路噪声。 */
    if ((key == NULL) ||
        (hmac_sha256(key, SHA256_DIGEST_LEN, f + 4U,
                     (uint32_t)(DL_HEADER_LEN - 4U) + payload_len, mac) != 0) ||
        (hmac_equal(mac, f + DL_HEADER_LEN + payload_len) != 1)) {
        return (int)DL_E_HMAC;
    }
    if ((payload_len == 0U) ? (crc != 0U)
                            : (crc != dl_crc32(f + DL_HEADER_LEN, payload_len))) {
        return (int)DL_E_CRC;
    }

    if (seq != rx->next_seq) { return (int)DL_E_SEQ; }

    if (kind == (uint8_t)DL_KIND_DATA) {
        if ((image_len == 0U) || (image_len > DL_MAX_IMAGE)) {
            return (int)DL_E_IMAGE_LEN;
        }
        if (rx->next_seq == 0U) {
            rx->image_len = image_len;      /* 首帧锚定 */
        } else if (image_len != rx->image_len) {
            return (int)DL_E_IMAGE_LEN;     /* 中途改口 = 两侧不同源 */
        }
        if ((rx->received + payload_len) > rx->image_len) {
            return (int)DL_E_OVER;
        }
        if ((payload_len > 0U)) {
            (void)memcpy(rx->image + rx->received,
                         f + DL_HEADER_LEN, payload_len);
        }
        rx->received = rx->received + payload_len;
        if ((flags & DL_FLAG_LAST) != 0U) { rx->last_seen = true; }
    } else if (kind == (uint8_t)DL_KIND_ACK) {
        if (payload_len != 0U) { return (int)DL_E_LEN; }
    } else if (kind == (uint8_t)DL_KIND_ERR) {
        if (payload_len != 0U) { return (int)DL_E_LEN; }
        return (int)DL_E_STATE;      /* 对端显式作废本次下装 */
    } else {
        return (int)DL_E_MAGIC;      /* 未知 kind：不在本契约的词汇表里 */
    }

    rx->next_seq = rx->next_seq + 1U;
    rx->frames = rx->frames + 1U;
    return (int)DL_OK;
}

/* 已知帧长时把 scratch 补满；返回 DL_OK 表示已够，DL_E_TRUNC 表示链路暂无数据 */
static int dl_rx_fill(DlReceiver *rx, DlStream *io, uint32_t want)
{
    uint32_t got = 1U;
    int rc;

    while (rx->scratch_len < want) {
        if (io->feed == NULL) { return (int)DL_E_STATE; }
        got = 0U;
        rc = io->feed(io->ctx, rx->scratch + rx->scratch_len,
                      want - rx->scratch_len, &got);
        if (rc != 0) { return (int)DL_E_STATE; }
        if (got == 0U) { return (int)DL_E_TRUNC; }
        rx->scratch_len = rx->scratch_len + got;
    }
    return (int)DL_OK;
}

int dl_rx_pump(DlReceiver *rx, DlStream *io,
               const uint8_t key[SHA256_DIGEST_LEN], bool *complete)
{
    int rc;

    if ((rx == NULL) || (io == NULL) || (complete == NULL)) {
        return (int)DL_E_STATE;
    }
    *complete = false;
    if (rx->failed) { return rx->last_error; }

    rc = dl_rx_fill(rx, io, DL_HEADER_LEN);
    if (rc != (int)DL_OK) { return rc; }
    {
        uint32_t payload_len = dl_get_u32(rx->scratch + 16U);
        uint32_t frame_len;

        if (payload_len > DL_MAX_PAYLOAD) {
            dl_fail(rx, (int)DL_E_LEN);
            return rx->last_error;
        }
        frame_len = DL_HEADER_LEN + payload_len + SHA256_DIGEST_LEN;
        rc = dl_rx_fill(rx, io, frame_len);
        if (rc != (int)DL_OK) { return rc; }
    }

    rc = dl_rx_absorb(rx, key);
    if (rc != (int)DL_OK) {
        dl_fail(rx, rc);
        rx->scratch_len = 0U;
        return rc;
    }
    rx->scratch_len = 0U;

    if ((rx->image_len > 0U) && (rx->received == rx->image_len) &&
        rx->last_seen) {
        *complete = true;
    }
    return (int)DL_OK;
}

int dl_rx_finish(const DlReceiver *rx, const uint8_t **image, uint32_t *len)
{
    if (rx == NULL) { return (int)DL_E_STATE; }
    if (rx->failed) { return rx->last_error; }
    if ((rx->image_len == 0U) || (rx->received != rx->image_len) ||
        (!rx->last_seen)) {
        return (int)DL_E_INCOMPLETE;
    }
    if ((image != NULL)) { *image = rx->image; }
    if (len != NULL) { *len = rx->image_len; }
    return (int)DL_OK;
}

uint32_t dl_rx_progress(const DlReceiver *rx)
{
    if ((rx == NULL) || (rx->image_len == 0U)) { return 0U; }
    if (rx->received >= rx->image_len) { return 100U; }
    return (uint32_t)((rx->received * 100U) / rx->image_len);
}
