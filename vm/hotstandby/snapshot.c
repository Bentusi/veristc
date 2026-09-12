/**
 * vm/hotstandby/snapshot.c
 * 状态快照引擎 — VM 状态序列化/反序列化
 *
 * 将 VM 完整状态（值栈、帧栈、线性内存）序列化为字节流，
 * 带 CRC32 校验，支持脏页优化（仅序列化变更页面）。
 */

#include "hotstandby.h"
#include <string.h>

/* ================================================================
   CRC32 (简化实现，生产环境应使用硬件 CRC)
   ================================================================ */

static const uint32_t s_crc32_table[256] = {
    0x00000000, 0x77073096, 0xEE0E612C, 0x990951BA,
    0x076DC419, 0x706AF48F, 0xE963A535, 0x9E6495A3,
    0x0EDB8832, 0x79DCB8A4, 0xE0D5E91E, 0x97D2D988,
    0x09B64C2B, 0x7EB17CBD, 0xE7B82D07, 0x90BF1D91,
    0x1DB71064, 0x6AB020F2, 0xF3B97148, 0x84BE41DE,
    0x1ADAD47D, 0x6DDDE4EB, 0xF4D4B551, 0x83D385C7,
    0x136C9856, 0x646BA8C0, 0xFD62F97A, 0x8A65C9EC,
    0x14015C4F, 0x63066CD9, 0xFA0F3D63, 0x8D080DF5,
    0x3B6E20C8, 0x4C69105E, 0xD56041E4, 0xA2677172,
    0x3C03E4D1, 0x4B04D447, 0xD20D85FD, 0xA50AB56B,
    0x35B5A8FA, 0x42B2986C, 0xDBBBC9D6, 0xACBCF940,
    0x32D86CE3, 0x45DF5C75, 0xDCD60DCF, 0xABD13D59,
    0x26D930AC, 0x51DE003A, 0xC8D75180, 0xBFD06116,
    0x21B4F4B5, 0x56B3C423, 0xCFBA9599, 0xB8BDA50F,
    0x2802B89E, 0x5F058808, 0xC60CD9B2, 0xB10BE924,
    0x2F6F7C87, 0x58684C11, 0xC1611DAB, 0xB6662D3D,
    0x76DC4190, 0x01DB7106, 0x98D220BC, 0xEFD5102A,
    0x71B18589, 0x06B6B51F, 0x9FBFE4A5, 0xE8B8D433,
    0x7807C9A2, 0x0F00F934, 0x9609A88E, 0xE10E9818,
    0x7F6A0DBB, 0x086D3D2D, 0x91646C97, 0xE6635C01,
    0x6B6B51F4, 0x1C6C6162, 0x856530D8, 0xF262004E,
    0x6C0695ED, 0x1B01A57B, 0x8208F4C1, 0xF50FC457,
    0x65B0D9C6, 0x12B7E950, 0x8BBEB8EA, 0xFCB9887C,
    0x62DD1DDF, 0x15DA2D49, 0x8CD37CF3, 0xFBD44C65,
    0x4DB26158, 0x3AB551CE, 0xA3BC0074, 0xD4BB30E2,
    0x4ADFA541, 0x3DD895D7, 0xA4D1C46D, 0xD3D6F4FB,
    0x4369E96A, 0x346ED9FC, 0xAD678846, 0xDA60B8D0,
    0x44042D73, 0x33031DE5, 0xAA0A4C5F, 0xDD0D7CC9,
    0x5005713C, 0x270241AA, 0xBE0B1010, 0xC90C2086,
    0x5768B525, 0x206F85B3, 0xB966D409, 0xCE61E49F,
    0x5EDEF90E, 0x29D9C998, 0xB0D09822, 0xC7D7A8B4,
    0x59B33D17, 0x2EB40D81, 0xB7BD5C3B, 0xC0BA6CAD,
    0xEDB88320, 0x9ABFB3B6, 0x03B6E20C, 0x74B1D29A,
    0xEAD54739, 0x9DD277AF, 0x04DB2615, 0x73DC1683,
    0xE3630B12, 0x94643B84, 0x0D6D6A3E, 0x7A6A5AA8,
    0xE40ECF0B, 0x9309FF9D, 0x0A00AE27, 0x7D079EB1,
    0xF00F9344, 0x8708A3D2, 0x1E01F268, 0x6906C2FE,
    0xF762575D, 0x806567CB, 0x196C3671, 0x6E6B06E7,
    0xFED41B76, 0x89D32BE0, 0x10DA7A5A, 0x67DD4ACC,
    0xF9B9DF6F, 0x8EBEEFF9, 0x17B7BE43, 0x60B08ED5,
    0xD6D6A3E8, 0xA1D1937E, 0x38D8C2C4, 0x4FDFF252,
    0xD1BB67F1, 0xA6BC5767, 0x3FB506DD, 0x48B2364B,
    0xD80D2BDA, 0xAF0A1B4C, 0x36034AF6, 0x41047A60,
    0xDF60EFC3, 0xA867DF55, 0x316E8EEF, 0x4669BE79,
    0xCB61B38C, 0xBC66831A, 0x256FD2A0, 0x5268E236,
    0xCC0C7795, 0xBB0B4703, 0x220216B9, 0x5505262F,
    0xC5BA3BBE, 0xB2BD0B28, 0x2BB45A92, 0x5CB36A04,
    0xC2D7FFA7, 0xB5D0CF31, 0x2CD99E8B, 0x5BDEAE1D,
    0x9B64C2B0, 0xEC63F226, 0x756AA39C, 0x026D930A,
    0x9C0906A9, 0xEB0E363F, 0x72076785, 0x05005713,
    0x95BF4A82, 0xE2B87A14, 0x7BB12BAE, 0x0CB61B38,
    0x92D28E9B, 0xE5D5BE0D, 0x7CDCEFB7, 0x0BDBDF21,
    0x86D3D2D4, 0xF1D4E242, 0x68DDB3F8, 0x1FDA836E,
    0x81BE16CD, 0xF6B9265B, 0x6FB077E1, 0x18B74777,
    0x88085AE6, 0xFF0F6A70, 0x66063BCA, 0x11010B5C,
    0x8F659EFF, 0xF862AE69, 0x616BFFD3, 0x166CCF45,
    0xA00AE278, 0xD70DD2EE, 0x4E048354, 0x3903B3C2,
    0xA7672661, 0xD06016F7, 0x4969474D, 0x3E6E77DB,
    0xAED16A4A, 0xD9D65ADC, 0x40DF0B66, 0x37D83BF0,
    0xA9BCAE53, 0xDEBB9EC5, 0x47B2CF7F, 0x30B5FFE9,
    0xBDBDF21C, 0xCABAC28A, 0x53B39330, 0x24B4A3A6,
    0xBAD03605, 0xCDD70693, 0x54DE5729, 0x23D967BF,
    0xB3667A2E, 0xC4614AB8, 0x5D681B02, 0x2A6F2B94,
    0xB40BBE37, 0xC30C8EA1, 0x5A05DF1B, 0x2D02EF8D,
};

static uint32_t crc32_compute(const uint8_t *data, uint32_t len)
{
    uint32_t crc = 0xFFFFFFFF;
    for (uint32_t i = 0; i < len; i++) {
        uint8_t index = (crc ^ data[i]) & 0xFF;
        crc = (crc >> 8) ^ s_crc32_table[index];
    }
    return crc ^ 0xFFFFFFFF;
}

bool hs_snapshot_verify_crc(const uint8_t *data, uint32_t size)
{
    if (!data || size < sizeof(SnapshotHeader) + 4) return false;

    const SnapshotHeader *hdr = (const SnapshotHeader *)data;
    uint32_t stored_crc = hdr->crc32;

    /* 将 CRC 字段置零后重新计算 */
    SnapshotHeader tmp;
    memcpy(&tmp, data, sizeof(SnapshotHeader));
    tmp.crc32 = 0;
    memcpy((void *)data, &tmp, sizeof(SnapshotHeader));

    uint32_t computed = crc32_compute(data, size);
    memcpy((void *)data, &tmp, sizeof(SnapshotHeader));
    /* 恢复原 CRC */
    ((SnapshotHeader *)data)->crc32 = stored_crc;

    return stored_crc == computed;
}

/* ================================================================
   脏页追踪实现
   ================================================================ */

void hs_dirty_init(DirtyPageTracker *tracker, uint32_t memory_size)
{
    if (!tracker) return;
    memset(tracker, 0, sizeof(DirtyPageTracker));
    tracker->page_size = HS_PAGE_SIZE;
    tracker->page_count = (memory_size + HS_PAGE_SIZE - 1) / HS_PAGE_SIZE;
    if (tracker->page_count > HS_MAX_PAGES) {
        tracker->page_count = HS_MAX_PAGES;
    }
}

void hs_dirty_mark(DirtyPageTracker *tracker, uint32_t addr, uint32_t size)
{
    if (!tracker) return;

    uint32_t start_page = addr / tracker->page_size;
    uint32_t end_page = (addr + size - 1) / tracker->page_size;

    if (end_page >= tracker->page_count) {
        end_page = tracker->page_count - 1;
    }

    for (uint32_t p = start_page; p <= end_page; p++) {
        uint32_t idx = p / 64;
        uint32_t bit = p % 64;
        if (idx < HS_DIRTY_BITMAP_SIZE) {
            tracker->bitmap[idx] |= (1ULL << bit);
        }
    }
}

void hs_dirty_clear(DirtyPageTracker *tracker)
{
    if (!tracker) return;
    memset(tracker->bitmap, 0, sizeof(tracker->bitmap));
}

bool hs_dirty_is_page_dirty(const DirtyPageTracker *tracker, uint32_t page_idx)
{
    if (!tracker) return false;
    uint32_t idx = page_idx / 64;
    uint32_t bit = page_idx % 64;
    if (idx >= HS_DIRTY_BITMAP_SIZE) return false;
    return (tracker->bitmap[idx] & (1ULL << bit)) != 0;
}

uint32_t hs_dirty_get_count(const DirtyPageTracker *tracker)
{
    if (!tracker) return 0;
    uint32_t count = 0;
    for (uint32_t i = 0; i < HS_DIRTY_BITMAP_SIZE; i++) {
        count += __builtin_popcountll(tracker->bitmap[i]);
    }
    return count;
}

uint32_t hs_dirty_get_pages(const DirtyPageTracker *tracker,
                             uint32_t *indices, uint32_t max_count)
{
    if (!tracker || !indices) return 0;

    uint32_t count = 0;
    for (uint32_t p = 0; p < tracker->page_count && count < max_count; p++) {
        if (hs_dirty_is_page_dirty(tracker, p)) {
            indices[count++] = p;
        }
    }
    return count;
}

/* ================================================================
   快照创建
   ================================================================ */

int hs_snapshot_create(HotStandbySystem *hs)
{
    if (!hs || !hs->vm) return -1;

    VM *vm = hs->vm;
    uint8_t *buf = hs->snapshot_buf;
    uint32_t buf_size = sizeof(hs->snapshot_buf);
    uint32_t offset = 0;

    /* 1. 填充快包头 */
    SnapshotHeader hdr;
    memset(&hdr, 0, sizeof(hdr));
    hdr.magic           = HS_SNAPSHOT_MAGIC;
    hdr.sequence        = hs->sync_sequence++;
    hdr.timestamp       = 0;  /* 由调用方填充 */
    hdr.val_stack_ptr   = vm->val_stack_ptr;
    hdr.frame_stack_ptr = vm->frame_stack_ptr;
    hdr.cycle_count     = vm->cycle_count;
    hdr.last_error      = vm->last_error;
    hdr.max_frame_depth = vm->max_frame_depth;
    hdr.max_value_stack_depth = vm->max_value_stack_depth;

    /* 2. 收集脏页 */
    uint32_t page_indices[HS_MAX_PAGES];
    uint32_t dirty_count = hs_dirty_get_pages(&hs->dirty_tracker, page_indices,
                                               HS_MAX_PAGES);
    hdr.dirty_page_count = dirty_count;
    memcpy(hdr.dirty_page_indices, page_indices,
           dirty_count * sizeof(uint32_t));
    hdr.dirty_data_size = dirty_count * HS_PAGE_SIZE;

    /* 3. 计算总快照大小 */
    uint32_t total_size = sizeof(SnapshotHeader) +
                          hdr.dirty_data_size +
                          vm->val_stack_ptr * sizeof(sasm_value) +
                          vm->frame_stack_ptr * sizeof(Frame);

    if (total_size > buf_size) {
        return -1;  /* 缓冲区不足 */
    }

    /* 4. 写入包头 */
    if (offset + sizeof(SnapshotHeader) > buf_size) return -1;
    memcpy(buf + offset, &hdr, sizeof(SnapshotHeader));
    offset += sizeof(SnapshotHeader);

    /* 5. 写入脏页数据 */
    for (uint32_t i = 0; i < dirty_count; i++) {
        uint32_t page_idx = page_indices[i];
        uint32_t page_addr = page_idx * HS_PAGE_SIZE;
        uint32_t copy_size = HS_PAGE_SIZE;
        if (page_addr + copy_size > vm->memory_size) {
            copy_size = vm->memory_size - page_addr;
        }
        if (offset + copy_size > buf_size) return -1;
        memcpy(buf + offset, vm->memory + page_addr, copy_size);
        offset += copy_size;
    }

    /* 6. 写入值栈 */
    uint32_t stack_bytes = vm->val_stack_ptr * sizeof(sasm_value);
    if (offset + stack_bytes > buf_size) return -1;
    memcpy(buf + offset, vm->val_stack, stack_bytes);
    offset += stack_bytes;

    /* 7. 写入帧栈 */
    uint32_t frame_bytes = vm->frame_stack_ptr * sizeof(Frame);
    if (offset + frame_bytes > buf_size) return -1;
    memcpy(buf + offset, vm->frame_stack, frame_bytes);
    offset += frame_bytes;

    /* 8. 计算并写入 CRC32 */
    hdr.crc32 = 0;
    memcpy(buf, &hdr, sizeof(SnapshotHeader));
    uint32_t crc = crc32_compute(buf, offset);
    /* 将 CRC 写回包头 */
    SnapshotHeader *hdr_in_buf = (SnapshotHeader *)buf;
    hdr_in_buf->crc32 = crc;

    hs->snapshot_size = offset;

    /* 9. 创建成功后清除脏页标记 */
    hs_dirty_clear(&hs->dirty_tracker);

    return 0;
}

/* ================================================================
   快照应用
   ================================================================ */

int hs_snapshot_apply(HotStandbySystem *hs, const uint8_t *snap_data,
                       uint32_t snap_size)
{
    if (!hs || !hs->vm || !snap_data) return -1;
    if (snap_size < sizeof(SnapshotHeader)) return -1;

    /* 1. 校验 CRC */
    if (!hs_snapshot_verify_crc(snap_data, snap_size)) {
        return -2;  /* CRC 校验失败 */
    }

    const SnapshotHeader *hdr = (const SnapshotHeader *)snap_data;
    if (hdr->magic != HS_SNAPSHOT_MAGIC) return -3;
    if (hdr->val_stack_ptr > VALUE_STACK_SIZE ||
        hdr->frame_stack_ptr > FRAME_STACK_SIZE) return -4;

    VM *vm = hs->vm;
    uint32_t offset = sizeof(SnapshotHeader);

    /* 2. 还原线性内存 (脏页) */
    for (uint32_t i = 0; i < hdr->dirty_page_count; i++) {
        uint32_t page_idx = hdr->dirty_page_indices[i];
        uint32_t page_addr = page_idx * HS_PAGE_SIZE;
        uint32_t copy_size = HS_PAGE_SIZE;
        if (page_addr + copy_size > vm->memory_size) {
            copy_size = vm->memory_size - page_addr;
        }
        if (offset + copy_size > snap_size) return -4;
        memcpy(vm->memory + page_addr, snap_data + offset, copy_size);
        offset += copy_size;
    }

    /* 3. 还原值栈 */
    vm->val_stack_ptr = hdr->val_stack_ptr;
    uint32_t stack_bytes = hdr->val_stack_ptr * sizeof(sasm_value);
    if (offset + stack_bytes > snap_size) return -4;
    memcpy(vm->val_stack, snap_data + offset, stack_bytes);
    offset += stack_bytes;

    /* 4. 还原帧栈 */
    vm->frame_stack_ptr = hdr->frame_stack_ptr;
    uint32_t frame_bytes = hdr->frame_stack_ptr * sizeof(Frame);
    if (offset + frame_bytes > snap_size) return -4;
    memcpy(vm->frame_stack, snap_data + offset, frame_bytes);
    offset += frame_bytes;

    /* 5. 还原其他状态 */
    vm->cycle_count = hdr->cycle_count;
    vm->last_error  = hdr->last_error;
    vm->max_frame_depth = hdr->max_frame_depth;
    vm->max_value_stack_depth = hdr->max_value_stack_depth;

    return 0;
}
