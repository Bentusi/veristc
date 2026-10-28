/**
 * sim/watch.c
 * watch 帧的构造与输出 —— 帧契约见 watch.h 与 spec/simulation-spec.md §4
 *
 * 类型解码按 spec/safeasm-spec.md §4.8 的 type_tag 枚举下标分类；
 * run_sim_e2e.sh 断言帧里的类型名与 `svm -l` 逐字一致，分类表若与段 7 漂移即失败。
 */

#include <float.h>
#include <stdio.h>
#include <string.h>

#include "watch.h"

#define WATCH_TYPE_TAGS 25U

#define CL_I32 0U
#define CL_U32 1U
#define CL_I64 2U
#define CL_F32 3U
#define CL_F64 4U
#define CL_NOVAL 5U   /* ARRAY / FB：没有「一个值」可读 */

static const uint8_t watch_class_of_tag[WATCH_TYPE_TAGS] = {
    /* BOOL   INT    DINT   REAL   LINT   LREAL  TIME   QUALITY */
    CL_U32,  CL_I32,  CL_I32,  CL_F32,  CL_I64,  CL_F64,  CL_I32,  CL_I32,
    /* BYTE   WORD   DWORD  SINT */
    CL_U32,  CL_U32,  CL_U32,  CL_I32,
    /* QBOOL  QBYTE  QWORD  QDWORD QSINT  QINT   QDINT  QLINT */
    CL_U32,  CL_U32,  CL_U32,  CL_U32,  CL_I32,  CL_I32,  CL_I32,  CL_I64,
    /* QREAL  QLREAL QTIME */
    CL_F32,  CL_F64,  CL_I32,
    /* ARRAY  FB */
    CL_NOVAL, CL_NOVAL
};

static uint8_t watch_class(uint8_t tag)
{
    if (tag >= WATCH_TYPE_TAGS) { return CL_NOVAL; }
    return watch_class_of_tag[tag];
}

static uint32_t watch_le32(const uint8_t *b)
{
    return (uint32_t)b[0] | ((uint32_t)b[1] << 8) |
           ((uint32_t)b[2] << 16) | ((uint32_t)b[3] << 24);
}

static int watch_finite(double v)
{
    return (v >= -DBL_MAX) && (v <= DBL_MAX);
}

/* JSON 字符串：符号名按构造只含标识符字符与 '#'，仍按转义写，
   因为这个名字最终来自文件字节，不该假设它干净。 */
static void watch_json_string(const char *s, uint32_t len)
{
    uint32_t i;

    (void)putchar('"');
    for (i = 0U; i < len; i++) {
        unsigned char c = (unsigned char)s[i];
        if ((c == '"') || (c == '\\')) {
            (void)printf("\\%c", (char)c);
        } else if (c < 0x20U) {
            (void)printf("\\u%04X", (unsigned int)c);
        } else {
            (void)putchar((int)c);
        }
    }
    (void)putchar('"');
}

/* 一个全局槽恒是 4 字节单字（global_codegen 的 assign_global_offsets 每个声明
   +4），所以 64 位量根本没有「第二个槽」可读 —— 直说，不做半吊子解码。 */
#define WATCH_SLOT_BYTES 4U

/* ------------------------------------------------------------------
   启动期：拆分名字表 + 解析地址 + 绑定通道
   ------------------------------------------------------------------ */

static int watch_bind_one(WatchVar *var, const uint8_t *buf, uint32_t len,
                         const IOMappingTable *iomap, const VM *vm)
{
    SasmSymInfo info;
    uint8_t cls;
    int rc = sasm_sym_resolve(buf, len, var->name, &info);

    if (rc == 1) {
        (void)fprintf(stderr, "watch: no such symbol: %s\n", var->name);
        return -1;
    }
    if (rc == -1) {
        (void)fprintf(stderr,
                      "watch: symbol table unusable (missing or malformed "
                      "Debug section) while resolving %s\n", var->name);
        return -1;
    }
    cls = watch_class(info.type_tag);
    if (cls == CL_NOVAL) {
        (void)fprintf(stderr, "watch: %s is %s, not a scalar variable\n",
                      var->name, info.type_name);
        return -1;
    }
    if ((cls == CL_I64) || (cls == CL_F64)) {
        (void)fprintf(stderr,
                      "watch: %s is %s; one global slot is one int32 word, "
                      "so 64-bit values have no storage to read\n",
                      var->name, info.type_name);
        return -1;
    }
    if ((info.addr > vm->memory_size) ||
        (WATCH_SLOT_BYTES > vm->memory_size - info.addr)) {
        (void)fprintf(stderr,
                      "watch: %s at 0x%08X is outside the %u byte memory image\n",
                      var->name, info.addr, vm->memory_size);
        return -1;
    }

    var->addr = info.addr;
    var->type_tag = info.type_tag;
    var->size = info.size;
    var->type_name = info.type_name;
    var->entry = -1;

    /* 地址与映射表同源（缺口 C 修复后 mem_offset 就是全局槽位地址），
       所以按地址相等即可判定这个符号是不是某个 I/O 通道。 */
    for (uint32_t i = 0U; i < iomap->count; i++) {
        if (iomap->entries[i].mem_offset == info.addr) {
            var->entry = (int32_t)i;
            break;
        }
    }
    return 0;
}

static int watch_take_name(WatchSet *set, const char *start, size_t raw_len)
{
    WatchVar *var;
    const char *b = start;
    const char *e = start + raw_len;
    size_t len;

    while ((e > b) && ((*b == ' ') || (*b == '\t'))) { b++; }
    while ((e > b) && ((e[-1] == ' ') || (e[-1] == '\t'))) { e--; }
    len = (size_t)(e - b);

    if (len == 0U) {
        (void)fprintf(stderr, "watch: empty name in --watch list\n");
        return -1;
    }
    if (len >= (size_t)WATCH_NAME_MAX) {
        (void)fprintf(stderr, "watch: name too long (max %d): %.*s\n",
                      WATCH_NAME_MAX - 1, (int)raw_len, start);
        return -1;
    }
    if (set->count >= WATCH_MAX_NAMES) {
        (void)fprintf(stderr, "watch: too many names (max %u)\n",
                      (unsigned int)WATCH_MAX_NAMES);
        return -1;
    }

    var = &set->vars[set->count];
    (void)memcpy(var->name, b, len);
    var->name[len] = '\0';

    for (uint32_t i = 0U; i < set->count; i++) {
        if (strcmp(set->vars[i].name, var->name) == 0) {
            (void)fprintf(stderr, "watch: duplicate name: %s\n", var->name);
            return -1;
        }
    }
    set->count++;
    return 0;
}

int watch_build(WatchSet *set, const char *csv, const uint8_t *buf,
                uint32_t len, const IOMappingTable *iomap, const VM *vm)
{
    const char *p = csv;

    set->count = 0U;
    if ((csv == NULL) || (csv[0] == '\0')) {
        (void)fprintf(stderr, "watch: empty --watch list\n");
        return -1;
    }

    for (;;) {
        const char *comma = strchr(p, ',');
        size_t piece_len = (comma != NULL) ? (size_t)(comma - p) : strlen(p);

        if (watch_take_name(set, p, piece_len) != 0) { return -1; }

        if (comma == NULL) { break; }
        p = comma + 1;
    }

    for (uint32_t i = 0U; i < set->count; i++) {
        if (watch_bind_one(&set->vars[i], buf, len, iomap, vm) != 0) {
            return -1;
        }
    }
    return 0;
}

/* ------------------------------------------------------------------
   运行期：按地址读槽位并按类型解码
   ------------------------------------------------------------------ */

static void watch_emit_value(const WatchVar *var, const VM *vm)
{
    uint8_t bytes[WATCH_SLOT_BYTES];
    uint8_t cls = watch_class(var->type_tag);

    if ((var->addr > vm->memory_size) ||
        (WATCH_SLOT_BYTES > vm->memory_size - var->addr)) {
        (void)printf("null");
        return;
    }
    (void)memcpy(bytes, vm->memory + var->addr, WATCH_SLOT_BYTES);

    switch (cls) {
    case CL_I32:
        (void)printf("%d", (int)watch_le32(bytes));
        break;
    case CL_U32:
        (void)printf("%u", (unsigned int)watch_le32(bytes));
        break;
    case CL_F32: {
        float f = 0.0f;
        uint32_t bits = watch_le32(bytes);
        (void)memcpy(&f, &bits, sizeof f);
        if (!watch_finite((double)f)) { (void)printf("null"); break; }
        (void)printf("%.8g", (double)f);
        break;
    }
    default:
        (void)printf("null");
        break;
    }
}

static void watch_emit_slot(const WatchVar *var, const VM *vm,
                            const IOMappingTable *iomap)
{
    (void)printf("{\"name\":");
    watch_json_string(var->name, (uint32_t)strlen(var->name));
    (void)printf(",\"addr\":%u,\"type\":", var->addr);
    watch_json_string(var->type_name, (uint32_t)strlen(var->type_name));
    (void)printf(",\"size\":%u,\"value\":", var->size);
    watch_emit_value(var, vm);

    if (var->entry < 0) {
        (void)printf(",\"channel\":null,\"raw\":null}");
        return;
    }
    /* raw 取映射层末次与物理侧交换的那一层：INPUT 是读入的原始值，
       OUTPUT 是按 scale/bias 逆变换后写出的原始值。 */
    (void)printf(",\"channel\":%u,\"raw\":%d}",
                 iomap->entries[var->entry].channel_id,
                 iomap->entries[var->entry].raw_value);
}

void watch_cycle_frame(const WatchSet *set, const VM *vm,
                       const IOMappingTable *iomap, uint32_t cycle,
                       uint32_t t_ms, int status)
{
    (void)printf("{\"frame\":\"cycle\",\"cycle\":%u,\"t_ms\":%u,"
                 "\"status\":%d,\"violations\":%u,\"values\":[",
                 cycle, t_ms, status, iomap->safety_violations);

    for (uint32_t i = 0U; i < set->count; i++) {
        if (i > 0U) { (void)putchar(','); }
        watch_emit_slot(&set->vars[i], vm, iomap);
    }
    (void)printf("]}\n");
}

void watch_done_frame(uint32_t cycles, const IOMappingTable *iomap,
                      uint32_t t_ms)
{
    (void)printf("{\"frame\":\"done\",\"cycles\":%u,\"t_ms\":%u,"
                 "\"violations\":%u,\"read_errors\":%u,\"write_errors\":%u}\n",
                 cycles, t_ms, iomap->safety_violations,
                 iomap->read_errors, iomap->write_errors);
    (void)fflush(stdout);
}
