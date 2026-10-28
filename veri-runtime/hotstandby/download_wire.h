/**
 * hotstandby/download_wire.h
 * 下装帧协议 —— 工程站到运行站的全量镜像传输协议
 *
 * 协议唯一源见 spec/download-spec.md；这里是它的 C 侧实现（发送侧组帧 + 接收侧状态机）。
 *
 * 帧（定宽小端，非 LEB128）：
 *
 *   off  size  field
 *    0    4    magic   "DLF1"
 *    4    1    ver     = 1
 *    5    1    kind    0=DATA 1=ACK 2=ERR
 *    6    2    flags   bit0 = 本帧是镜像末帧
 *    8    4    image_len   整镜像字节数（每帧都带，用于锚定与越界判定）
 *   12    4    seq         帧序号，0 起
 *   16    4    payload_len
 *   20    4    crc32       覆盖 payload
 *   24    n    payload
 *  24+n   32   hmac        HMAC-SHA256，覆盖 [4, 24+n) 即 ver..payload
 *
 * 两道独立校验的理由：CRC32 挡意外损坏（截断、位翻转），HMAC 挡伪造与替换
 * —— 一个能算出正确 CRC32 的攻击者改得动镜像，改不动没有密钥的 MAC。
 *
 * G0 范围（决策 D5 + plan §6.2）：只做全量镜像与进程内流后端，
 * 不做分片重传/超时/断点续传，不做增量补丁（apply_patch 保留但不进链路）。
 *
 * 约束：无动态内存；所有缓冲静态；每个长度字段在 memcpy 前核对。
 */

#ifndef DOWNLOAD_WIRE_H
#define DOWNLOAD_WIRE_H

#include <stdint.h>
#include <stdbool.h>
#include "hmac_sha256.h"

#ifdef __cplusplus
extern "C" {
#endif

#define DL_MAGIC           0x31464C44U   /* 字节 'D' 'L' 'F' '1' 的小端读法 */
#define DL_VER             1U
#define DL_HEADER_LEN      24U
#define DL_TRAILER_LEN     SHA256_DIGEST_LEN
#define DL_MIN_FRAME_LEN   (DL_HEADER_LEN + SHA256_DIGEST_LEN)

#define DL_KIND_DATA       0U
#define DL_KIND_ACK        1U
#define DL_KIND_ERR        2U

#define DL_FLAG_LAST       0x0001U

/* 单帧载荷上限：4 KiB —— 一次读不满也只需两次补读，静态缓冲可控 */
#define DL_MAX_PAYLOAD     4096U
/* 整镜像上限：与 1 MiB 内存模型（vm.h MEMORY_SIZE）同量级。
 * 实测最大黄金制品 nuclear_rps_esfas_full.sasm = 196,738 B，262144 只余 33%，
 * 提到 1 MiB 后余量与内存模型一致；代价是版本槽与接收缓冲各 1 MiB 静态内存。 */
#define DL_MAX_IMAGE       1048576U
/* 接收侧单帧组装缓冲（头 + 最大载荷 + MAC） */
#define DL_FRAME_BUF       (DL_HEADER_LEN + DL_MAX_PAYLOAD + SHA256_DIGEST_LEN)

/* 拒绝码：进 spec 表，运行站与工程站两侧共用 */
typedef enum {
    DL_OK            = 0,   /* 帧完整且校验通过 */
    DL_E_TRUNC       = -1,  /* 字节不足，等待更多输入（不是错误） */
    DL_E_MAGIC       = -2,  /* magic/ver 不符 —— 非本协议 */
    DL_E_LEN         = -3,  /* 长度自相矛盾：payload_len 越界或帧长不符 */
    DL_E_IMAGE_LEN   = -4,  /* image_len 非法（0 或超 DL_MAX_IMAGE）或与已锚定值不符 */
    DL_E_SEQ         = -5,  /* 序号不连续（G0 不重传，出现即整镜像作废） */
    DL_E_CRC         = -6,  /* payload CRC32 不符 —— 意外损坏 */
    DL_E_HMAC        = -7,  /* MAC 不符 —— 伪造/替换/密钥不一致 */
    DL_E_OVER        = -8,  /* 累计字节超过 image_len —— 尾部有extra */
    DL_E_INCOMPLETE  = -9,  /* 流结束但镜像未收满或末帧未标记 */
    DL_E_STATE       = -10  /* 状态机用法错误（如未开始就提交） */
} DlResult;

/* ------------------------------------------------------------------
   传输抽象：把协议状态机与 socket API 解耦（plan §6.2）
   feed  = 从链路取最多 cap 字节，写入 buf，*got 回实际字节数；0 表示暂无数据
   drain = 把 len 字节推入链路
   两侧都返回 0 表示成功，非 0 表示链路故障。
   ------------------------------------------------------------------ */
typedef struct {
    int (*feed)(void *ctx, uint8_t *buf, uint32_t cap, uint32_t *got);
    int (*drain)(void *ctx, const uint8_t *buf, uint32_t len);
    void *ctx;
} DlStream;

/* ------------------------------------------------------------------
   发送侧
   ------------------------------------------------------------------ */

/* 组一帧写入 out（不含 hmac 前的组装由本函数完成）；返回帧长，<=0 为参数错 */
int dl_frame_build(uint8_t *out, uint32_t cap, uint8_t kind, uint16_t flags,
                   uint32_t image_len, uint32_t seq,
                   const uint8_t *payload, uint32_t payload_len,
                   const uint8_t key[SHA256_DIGEST_LEN]);

/* 把整镜像切成 DATA 帧发出，末帧带 DL_FLAG_LAST；返回发出的帧数或负错误码 */
int dl_tx_image(DlStream *io, const uint8_t key[SHA256_DIGEST_LEN],
                const uint8_t *image, uint32_t len);

/* ------------------------------------------------------------------
   接收侧状态机
   ------------------------------------------------------------------ */
typedef struct {
    uint8_t  image[DL_MAX_IMAGE];   /* 已收载荷 */
    uint8_t  scratch[DL_FRAME_BUF]; /* 半帧暂存 */
    uint32_t scratch_len;
    uint32_t received;
    uint32_t image_len;             /* 首帧锚定 */
    uint32_t next_seq;
    uint32_t frames;
    bool     last_seen;
    bool     failed;                /* 已判定作废：不再吸收任何帧 */
    int      last_error;            /* 作废原因，DL_E_* 之一 */
} DlReceiver;

void dl_rx_reset(DlReceiver *rx);

/* 从链路吸收帧。每收到一个合法 DATA 帧调用一次内部累积；
 * 返回值：
 *   DL_OK          本次调用后镜像已收满且校验通过（*complete 置 true）
 *   DL_E_TRUNC     链路暂无完整帧，调用方应继续喂数据（非错误）
 *   其他负值       该帧被拒；状态机随即作废（failed），调用方须丢弃整镜像
 * 拒绝码同时留在 rx 内部计数之外：返回值本身就是拒绝码，不做第二套状态。 */
int dl_rx_pump(DlReceiver *rx, DlStream *io,
               const uint8_t key[SHA256_DIGEST_LEN], bool *complete);

/* 校验已收镜像（长度/末帧），成功时 *len 回填镜像字节数 */
int dl_rx_finish(const DlReceiver *rx, const uint8_t **image, uint32_t *len);

uint32_t dl_rx_progress(const DlReceiver *rx);   /* 0-100 */

#ifdef __cplusplus
}
#endif

#endif /* DOWNLOAD_WIRE_H */
