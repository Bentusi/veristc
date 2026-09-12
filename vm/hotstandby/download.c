/**
 * vm/hotstandby/download.c
 * 增量下装模块 — 新旧 .sasm 差异计算 + 周期边界原子切换 + 回滚
 *
 * 功能:
 *   1. 计算新旧 .sasm 二进制差异 (基于简单 bsdiff 风格)
 *   2. 下装到备站 (通过同步通道)
 *   3. 周期边界原子切换 (新版本在周期开始生效)
 *   4. 失败自动回滚到旧版本
 *
 * 安全约束:
 *   - 切换仅在周期边界 (vm_run 完成后) 执行
 *   - 新版本加载后先验证再切换
 *   - 验证失败立即回滚
 */

#include "hotstandby.h"
#include <string.h>

/* ================================================================
   常量
   ================================================================ */

#define DL_MAX_SECTIONS     8
#define DL_PATCH_MAGIC      0x444C5043  /* "DLPC" */
#define DL_MAX_PATCH_SIZE   16384
#define DL_MAX_RAW_SIZE     262144
#define DL_VERSION_SLOTS    2           /* 保留 2 个版本 (当前+新) */

/* ================================================================
   补丁格式
   ================================================================ */

typedef struct __attribute__((packed)) {
    uint32_t magic;              /* DL_PATCH_MAGIC */
    uint32_t old_version_id;     /* 旧版本 ID */
    uint32_t new_version_id;     /* 新版本 ID */
    uint32_t old_total_size;     /* 旧模块总大小 */
    uint32_t new_total_size;     /* 新模块总大小 */

    /* 差异段描述 */
    uint32_t section_count;      /* 差异段数量 */
    /* 之后紧跟 DlSectionDiff 数组 */

    uint32_t crc32;              /* 补丁数据 CRC */
} DlPatchHeader;

typedef struct __attribute__((packed)) {
    uint8_t  section_type;       /* 段类型 (SEC_*) */
    uint32_t old_offset;         /* 在旧段中的偏移 */
    uint32_t new_offset;         /* 在新段中的偏移 */
    uint32_t length;             /* 差异数据长度 */
    /* 之后紧跟差异数据 */
} DlSectionDiff;

/* ================================================================
   版本管理
   ================================================================ */

typedef struct {
    SasmModule module;           /* 已加载的模块 */
    uint8_t    raw_data[DL_MAX_RAW_SIZE]; /* 原始二进制 */
    uint32_t   raw_size;
    uint32_t   version_id;
    bool       valid;
} VersionSlot;

typedef struct {
    VersionSlot slots[DL_VERSION_SLOTS];
    uint32_t    active_slot;        /* 当前生效的槽位索引 */
    uint32_t    pending_slot;       /* 待切换的槽位索引 */
    uint32_t    next_version_id;    /* 下一个版本 ID */

    /* 补丁缓冲区 */
    uint8_t     patch_buf[DL_MAX_PATCH_SIZE];
    uint32_t    patch_size;

    /* 下装状态 */
    bool        download_in_progress;
    uint32_t    download_progress;   /* 0-100 */
    int         last_error;

    /* 回调 */
    void (*on_download_start)(uint32_t new_version);
    void (*on_download_complete)(uint32_t new_version, bool success);
} DownloadManager;

/* ================================================================
   模块差异计算
   ================================================================
 *
 * 简单差分算法: 逐段对比两个 .sasm 模块的差异。
 * 对于每个段类型:
 *   - 如果段新旧完全一致 → 跳过 (无差异)
 *   - 如果段发生变化 → 记录差异范围
 *
 * 生产环境可使用 bsdiff/zstd 等压缩差分算法。
 */

static int compute_diff(const SasmModule *old_mod,
                         const SasmModule *new_mod,
                         uint8_t *patch_buf, uint32_t *patch_size)
{
    if (!old_mod || !new_mod || !patch_buf || !patch_size) return -1;

    uint32_t offset = sizeof(DlPatchHeader);
    uint32_t section_count = 0;

    /* 对比各个段 */
    /* 注意: 这里简化实现, 仅对比关键段 */

    /* 对比 Type Section (通过 func_count 间接判断) */
    if (old_mod->type_count != new_mod->type_count ||
        old_mod->func_count != new_mod->func_count) {
        /* 记录整个模块需要替换 */
        DlSectionDiff *diff = (DlSectionDiff *)(patch_buf + offset);
        diff->section_type = 0xFF;  /* 全量替换标记 */
        diff->old_offset = 0;
        diff->new_offset = 0;
        diff->length = 0;
        section_count++;
        offset += sizeof(DlSectionDiff);
    } else {
        /* 逐函数对比 Code Section */
        for (uint32_t i = 0; i < new_mod->code_count; i++) {
            uint32_t old_size = (i < old_mod->code_count)
                                ? old_mod->codes[i].body_size : 0;
            uint32_t new_size = new_mod->codes[i].body_size;

            if (old_size != new_size) {
                DlSectionDiff *diff = (DlSectionDiff *)(patch_buf + offset);
                diff->section_type = SEC_CODE;
                diff->old_offset = i;
                diff->new_offset = i;
                diff->length = new_size;
                section_count++;
                offset += sizeof(DlSectionDiff);
                /* 复制新的 body 数据 */
                if (offset + new_size > DL_MAX_PATCH_SIZE) return -1;
                memcpy(patch_buf + offset,
                       new_mod->code_pool + new_mod->codes[i].body_offset,
                       new_size);
                offset += new_size;
            } else if (old_size > 0 &&
                       memcmp(old_mod->code_pool + old_mod->codes[i].body_offset,
                              new_mod->code_pool + new_mod->codes[i].body_offset,
                              old_size) != 0) {
                DlSectionDiff *diff = (DlSectionDiff *)(patch_buf + offset);
                diff->section_type = SEC_CODE;
                diff->old_offset = i;
                diff->new_offset = i;
                diff->length = new_size;
                section_count++;
                offset += sizeof(DlSectionDiff);
                if (offset + new_size > DL_MAX_PATCH_SIZE) return -1;
                memcpy(patch_buf + offset,
                       new_mod->code_pool + new_mod->codes[i].body_offset,
                       new_size);
                offset += new_size;
            }
        }

        /* 对比 Safety Section */
        if (memcmp(&old_mod->safety, &new_mod->safety,
                    sizeof(SafetyAnnotation)) != 0) {
            DlSectionDiff *diff = (DlSectionDiff *)(patch_buf + offset);
            diff->section_type = SEC_SAFE;
            diff->old_offset = 0;
            diff->new_offset = 0;
            diff->length = sizeof(SafetyAnnotation);
            section_count++;
            offset += sizeof(DlSectionDiff);
            if (offset + sizeof(SafetyAnnotation) > DL_MAX_PATCH_SIZE)
                return -1;
            memcpy(patch_buf + offset, &new_mod->safety,
                   sizeof(SafetyAnnotation));
            offset += sizeof(SafetyAnnotation);
        }
    }

    if (section_count == 0) {
        /* 无差异 */
        *patch_size = 0;
        return 0;
    }

    /* 写入补包头 */
    DlPatchHeader hdr;
    hdr.magic = DL_PATCH_MAGIC;
    hdr.old_version_id = 0;
    hdr.new_version_id = 0;
    hdr.old_total_size = sizeof(SasmModule);
    hdr.new_total_size = sizeof(SasmModule);
    hdr.section_count = section_count;
    hdr.crc32 = 0;

    memcpy(patch_buf, &hdr, sizeof(DlPatchHeader));
    *patch_size = offset;

    return 0;
}

/* ================================================================
   补丁应用
   ================================================================ */

static int apply_patch(const SasmModule *old_mod,
                        SasmModule *new_mod,
                        const uint8_t *patch, uint32_t patch_size)
{
    (void)old_mod;  /* 保留供未来扩展 */
    if (!old_mod || !new_mod || !patch) return -1;
    if (patch_size < sizeof(DlPatchHeader)) return -1;

    const DlPatchHeader *hdr = (const DlPatchHeader *)patch;
    if (hdr->magic != DL_PATCH_MAGIC) return -1;

    /* 先复制旧模块作为基础 */
    memcpy(new_mod, old_mod, sizeof(SasmModule));

    uint32_t offset = sizeof(DlPatchHeader);

    for (uint32_t i = 0; i < hdr->section_count; i++) {
        if (offset + sizeof(DlSectionDiff) > patch_size) return -1;
        const DlSectionDiff *diff =
            (const DlSectionDiff *)(patch + offset);
        offset += sizeof(DlSectionDiff);

        if (diff->section_type == 0xFF) {
            /* 全量替换标记 — 上层需提供完整新模块 */
            return -2;
        }

        if (diff->section_type == SEC_CODE) {
            uint32_t func_idx = diff->new_offset;
            if (func_idx >= SASM_MAX_FUNCTIONS) return -1;
            if (offset + diff->length > patch_size) return -1;
            if (diff->length > SASM_MAX_FUNCTION_CODE_SIZE) return -1;

            new_mod->codes[func_idx].body_size = diff->length;
            uint32_t body_offset = new_mod->codes[func_idx].body_offset;
            if (body_offset + diff->length > SASM_MAX_CODE_POOL_SIZE) return -1;
            memcpy(new_mod->code_pool + body_offset,
                   patch + offset, diff->length);
            offset += diff->length;
        } else if (diff->section_type == SEC_SAFE) {
            if (offset + diff->length > patch_size) return -1;
            if (diff->length > sizeof(SafetyAnnotation)) return -1;
            memcpy(&new_mod->safety, patch + offset, diff->length);
            offset += diff->length;
        }
    }

    return 0;
}

/* ================================================================
   下装管理器 (静态实例)
   ================================================================ */

static DownloadManager s_dl_mgr;

/* ================================================================
   公开接口
   ================================================================ */

/**
 * dl_manager_init - 初始化下装管理器
 * @initial_module: 初始模块 (版本 0)
 */
void dl_manager_init(const SasmModule *initial_module)
{
    memset(&s_dl_mgr, 0, sizeof(s_dl_mgr));

    /* 将初始模块存入槽 0 */
    memcpy(&s_dl_mgr.slots[0].module, initial_module, sizeof(SasmModule));
    s_dl_mgr.slots[0].version_id = 0;
    s_dl_mgr.slots[0].valid = true;
    s_dl_mgr.active_slot = 0;
    s_dl_mgr.pending_slot = 1;
    s_dl_mgr.next_version_id = 1;
    s_dl_mgr.download_in_progress = false;
}

/**
 * dl_prepare_download - 准备新版本下装
 * @new_module: 新模块
 * @return 0 = 成功, -1 = 失败
 *
 * 计算新旧差异, 生成补丁。
 */
int dl_prepare_download(const SasmModule *new_module)
{
    VersionSlot *active = &s_dl_mgr.slots[s_dl_mgr.active_slot];
    if (!active->valid) return -1;

    uint32_t patch_size;
    int ret = compute_diff(&active->module, new_module,
                            s_dl_mgr.patch_buf, &patch_size);
    if (ret != 0) return ret;

    s_dl_mgr.patch_size = patch_size;

    /* 将新模块存入待切换槽 */
    VersionSlot *pending = &s_dl_mgr.slots[s_dl_mgr.pending_slot];
    memcpy(&pending->module, new_module, sizeof(SasmModule));
    pending->version_id = s_dl_mgr.next_version_id++;
    pending->valid = false;  /* 尚未验证 */

    s_dl_mgr.download_in_progress = true;
    s_dl_mgr.download_progress = 50;

    if (s_dl_mgr.on_download_start) {
        s_dl_mgr.on_download_start(pending->version_id);
    }

    return 0;
}

/**
 * dl_commit_switch - 原子切换: 使新版本生效
 * @return 0 = 成功, -1 = 失败 (自动回滚)
 *
 * 在周期边界调用, 先验证新模块再切换。
 */
int dl_commit_switch(void)
{
    if (!s_dl_mgr.download_in_progress) return -1;

    VersionSlot *pending = &s_dl_mgr.slots[s_dl_mgr.pending_slot];

    /* 验证新模块 */
    if (!sasm_validate(&pending->module)) {
        s_dl_mgr.last_error = -1;
        if (s_dl_mgr.on_download_complete) {
            s_dl_mgr.on_download_complete(pending->version_id, false);
        }
        s_dl_mgr.download_in_progress = false;
        return -1;  /* 验证失败, 自动回滚 */
    }

    /* 切换: 将 pending 变为 active */
    uint32_t new_active = s_dl_mgr.pending_slot;
    uint32_t new_pending = s_dl_mgr.active_slot;

    pending->valid = true;
    s_dl_mgr.active_slot = new_active;
    s_dl_mgr.pending_slot = new_pending;
    s_dl_mgr.download_progress = 100;
    s_dl_mgr.download_in_progress = false;

    if (s_dl_mgr.on_download_complete) {
        s_dl_mgr.on_download_complete(pending->version_id, true);
    }

    return 0;
}

/**
 * dl_get_active_module - 获取当前生效的模块指针
 */
const SasmModule *dl_get_active_module(void)
{
    if (!s_dl_mgr.slots[s_dl_mgr.active_slot].valid) return NULL;
    return &s_dl_mgr.slots[s_dl_mgr.active_slot].module;
}

/**
 * dl_get_pending_module - 获取待切换模块指针
 */
const SasmModule *dl_get_pending_module(void)
{
    if (!s_dl_mgr.download_in_progress) return NULL;
    return &s_dl_mgr.slots[s_dl_mgr.pending_slot].module;
}

/**
 * dl_is_download_in_progress - 是否有下装正在进行
 */
bool dl_is_download_in_progress(void)
{
    return s_dl_mgr.download_in_progress;
}

/**
 * dl_get_progress - 获取下装进度 (0-100)
 */
uint32_t dl_get_progress(void)
{
    return s_dl_mgr.download_progress;
}

/**
 * dl_set_callbacks - 设置下装回调
 */
void dl_set_callbacks(void (*on_start)(uint32_t),
                       void (*on_complete)(uint32_t, bool))
{
    s_dl_mgr.on_download_start    = on_start;
    s_dl_mgr.on_download_complete = on_complete;
}
