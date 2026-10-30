/**
 * sim/force.c
 * 激励与强制 —— 协议见 force.h 与 spec/simulation-spec.md §5
 *
 * 三段：启动期把每条记录定好落点并编码，推进期按周期号取生效记录，
 * 写回期把生效记录分别钉到物理侧与全局槽位。任何一步含糊都在启动期判死，
 * 一个周期都不跑 —— 静默降级出来的曲线比不跑更危险（协议 §5.5）。
 */

#include "force.h"

#include <errno.h>
#include <float.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../core/sasm_info.h"
#include "../rtos/abstract.h"

#define FORCE_SLOT_BYTES  WATCH_SLOT_BYTES

/* ================================================================
   值语法（协议 §5.1）：与帧解码同一张类型表
   ================================================================ */

static int force_finite(double v)
{
    return (v >= (-DBL_MAX)) && (v <= DBL_MAX);
}

static int force_i32(const char *text, int32_t *out)
{
    char *end = NULL;
    errno = 0;
    long v = strtol(text, &end, 10);
    if ((errno != 0) || (text[0] == '\0') || (*end != '\0') ||
        (v < (long)INT32_MIN) || (v > (long)INT32_MAX)) {
        return -1;
    }
    *out = (int32_t)v;
    return 0;
}

/**
 * force_encode - 把 value 文本编成该类型类下的落地位模式与整数
 * @return 0 = 成功, -1 = 语法与该类不符（调用方带上类型名报错）
 */
static int force_encode(const char *text, uint8_t cls, uint32_t *bits, int32_t *raw)
{
    if (cls != WATCH_CL_F32) {
        if (strcmp(text, "TRUE") == 0) {
            *bits = 1U;
            *raw = 1;
            return 0;
        }
        if (strcmp(text, "FALSE") == 0) {
            *bits = 0U;
            *raw = 0;
            return 0;
        }
    }

    if (cls == WATCH_CL_F32) {
        char *end = NULL;
        errno = 0;
        double v = strtod(text, &end);
        if ((errno != 0) || (text[0] == '\0') || (*end != '\0') || (!force_finite(v))) {
            return -1;
        }
        float f = (float)v;
        uint32_t word = 0U;
        (void)memcpy(&word, &f, sizeof word);
        *bits = word;
        /* 物理侧只有整数：向零截断，与对象表读出的 (int32_t) 同方向 */
        *raw = (int32_t)f;
        return 0;
    }

    int32_t value = 0;
    if (force_i32(text, &value) != 0) {
        return -1;
    }
    *bits = (uint32_t)value;
    *raw = value;
    return 0;
}

/* ================================================================
   启动期：定落点
   ================================================================ */

static void force_le32_write(uint8_t *dst, uint32_t word)
{
    dst[0] = (uint8_t)(word & 0xFFU);
    dst[1] = (uint8_t)((word >> 8) & 0xFFU);
    dst[2] = (uint8_t)((word >> 16) & 0xFFU);
    dst[3] = (uint8_t)((word >> 24) & 0xFFU);
}

static ForceTarget *force_find_target(ForceTable *table, const char *name)
{
    for (uint32_t i = 0U; i < table->target_count; i++) {
        if (strcmp(table->targets[i].name, name) == 0) {
            return &table->targets[i];
        }
    }
    return NULL;
}

/**
 * force_resolve - 新名字进表：段 7 定地址与类型，映射表与对象表定落点
 *
 * 与 watch_bind_one 走同一个 sasm_sym_resolve，因此"强制写的地址"与
 * "帧里读的地址"必然相同 —— 写进去却读不到，比拒绝启动更糟。
 */
static ForceTarget *force_resolve(ForceTable *table, const char *name,
                                  uint8_t from_cli, const uint8_t *buf,
                                  uint32_t len, const IOMappingTable *iomap,
                                  const VM *vm, const PlantTable *plant)
{
    SasmSymInfo info;
    ForceTarget *target;
    uint8_t cls;
    int rc = sasm_sym_resolve(buf, len, name, &info);

    if (rc == 1) {
        (void)fprintf(stderr, "force: no such symbol: %s\n", name);
        return NULL;
    }
    if (rc == -1) {
        (void)fprintf(stderr,
                      "force: symbol table unusable (missing or malformed "
                      "Debug section) while resolving %s\n", name);
        return NULL;
    }
    cls = watch_class_of(info.type_tag);
    if (cls == WATCH_CL_NOVAL) {
        (void)fprintf(stderr, "force: %s is %s, not a scalar variable\n",
                      name, info.type_name);
        return NULL;
    }
    if ((cls == WATCH_CL_I64) || (cls == WATCH_CL_F64)) {
        (void)fprintf(stderr,
                      "force: %s is %s; one global slot is one int32 word, "
                      "so 64-bit values have no storage to write\n",
                      name, info.type_name);
        return NULL;
    }
    if ((info.addr > vm->memory_size) ||
        (FORCE_SLOT_BYTES > vm->memory_size - info.addr)) {
        (void)fprintf(stderr,
                      "force: %s at 0x%08X is outside the %u byte memory image\n",
                      name, info.addr, vm->memory_size);
        return NULL;
    }
    if (table->target_count >= (uint32_t)FORCE_MAX_TARGETS) {
        (void)fprintf(stderr, "force: too many names (max %u)\n",
                      (unsigned int)FORCE_MAX_TARGETS);
        return NULL;
    }

    target = &table->targets[table->target_count];
    (void)memset(target, 0, sizeof(*target));
    (void)snprintf(target->name, (int)sizeof(target->name), "%s", name);
    target->addr = info.addr;
    target->cls = cls;
    target->from_cli = from_cli;
    target->channel = -1;
    target->active = -1;
    table->target_count++;

    /* 落点规则（§5.3）：地址命中映射条目且方向是 INPUT，就写在物理侧 */
    for (uint32_t i = 0U; i < iomap->count; i++) {
        const IOMapEntryRuntime *entry = &iomap->entries[i];

        if (entry->mem_offset != info.addr) { continue; }
        if (entry->direction != IO_DIR_INPUT) { break; }

        const PlantChannel *ch = plant_find(plant, entry->channel_id);
        if (ch == NULL) {
            (void)fprintf(stderr,
                          "force: %s is bound to input channel %u, which the "
                          "plant does not hold\n",
                          name, entry->channel_id);
            table->target_count--;
            return NULL;
        }
        if (ch->direction != IO_DIR_INPUT) {
            (void)fprintf(stderr,
                          "force: %s is bound to input channel %u, which the "
                          "plant holds as an output\n", name, entry->channel_id);
            table->target_count--;
            return NULL;
        }
        target->channel = (int32_t)entry->channel_id;
        break;
    }
    return target;
}

/* ================================================================
   启动期：加一条记录（语法 + 来源冲突 + 量程）
   ================================================================ */

static int force_add(ForceTable *table, const char *name, const char *text,
                     uint32_t cycle, uint8_t from_cli, const uint8_t *buf,
                     uint32_t len, const IOMappingTable *iomap, const VM *vm,
                     const PlantTable *plant)
{
    ForceTarget *target = force_find_target(table, name);
    uint32_t bits = 0U;
    int32_t raw = 0;

    if (target == NULL) {
        target = force_resolve(table, name, from_cli, buf, len, iomap, vm, plant);
        if (target == NULL) { return -1; }
    } else if (target->from_cli != from_cli) {
        (void)fprintf(stderr,
                      "force: %s is declared by both --force and the script; "
                      "which one wins is not a question the runner should answer\n",
                      name);
        return -1;
    } else if (from_cli != 0U) {
        (void)fprintf(stderr, "force: duplicate --force name: %s\n", name);
        return -1;
    }

    if (force_encode(text, target->cls, &bits, &raw) != 0) {
        (void)fprintf(stderr, "force: %s takes a value of its own type, got: %s\n",
                      name, text);
        return -1;
    }

    if (target->channel >= 0) {
        const PlantChannel *ch = plant_find(plant, (uint32_t)target->channel);

        if ((ch != NULL) && ((raw < ch->min_value) || (raw > ch->max_value))) {
            (void)fprintf(stderr,
                          "force: %s injects %d into channel %d, outside its "
                          "physical range [%d,%d]\n",
                          name, (int)raw, (int)target->channel,
                          (int)ch->min_value, (int)ch->max_value);
            return -1;
        }
    }

    if (cycle < 1U) {
        (void)fprintf(stderr, "force: cycle numbers start at 1\n");
        return -1;
    }
    if (table->record_count >= (uint32_t)FORCE_MAX_RECORDS) {
        (void)fprintf(stderr, "force: too many records (max %u)\n",
                      (unsigned int)FORCE_MAX_RECORDS);
        return -1;
    }
    for (uint32_t i = 0U; i < table->record_count; i++) {
        if ((table->records[i].target == (target - table->targets)) &&
            (table->records[i].cycle == cycle)) {
            (void)fprintf(stderr,
                          "force: %s already has a record for cycle %u\n",
                          name, cycle);
            return -1;
        }
    }

    table->records[table->record_count].cycle = cycle;
    table->records[table->record_count].target = (int32_t)(target - table->targets);
    table->records[table->record_count].bits = bits;
    table->records[table->record_count].raw = raw;
    table->record_count++;
    return 0;
}

/* ================================================================
   启动期：--force 列表
   ================================================================ */

static int force_take_pair(ForceTable *table, const char *start, size_t raw_len,
                           const uint8_t *buf, uint32_t len,
                           const IOMappingTable *iomap, const VM *vm,
                           const PlantTable *plant)
{
    char name[WATCH_NAME_MAX];
    const char *eq;
    size_t span = raw_len;
    size_t name_len;
    const char *value;
    size_t value_len;

    while ((span > 0U) && ((start[0] == ' ') || (start[0] == '\t'))) {
        start++; span--;
    }
    while ((span > 0U) && ((start[span - 1U] == ' ') || (start[span - 1U] == '\t'))) {
        span--;
    }
    eq = (span > 0U) ? (const char *)memchr(start, '=', span) : NULL;
    if (eq == NULL) {
        (void)fprintf(stderr, "force: --force items are name=value: %.*s\n",
                      (int)raw_len, start);
        return -1;
    }

    name_len = (size_t)(eq - start);
    value = eq + 1;
    value_len = span - name_len - 1U;
    while ((value_len > 0U) && ((value[0] == ' ') || (value[0] == '\t'))) {
        value++; value_len--;
    }
    while ((value_len > 0U) && ((value[value_len - 1U] == ' ') ||
                                (value[value_len - 1U] == '\t'))) {
        value_len--;
    }
    if ((name_len == 0U) || (value_len == 0U)) {
        (void)fprintf(stderr, "force: empty name or value in --force list\n");
        return -1;
    }
    if (name_len >= (size_t)WATCH_NAME_MAX) {
        (void)fprintf(stderr, "force: name too long (max %d): %.*s\n",
                      WATCH_NAME_MAX - 1, (int)name_len, start);
        return -1;
    }

    (void)memcpy(name, start, name_len);
    name[name_len] = '\0';

    {
        char text[WATCH_NAME_MAX];
        if (value_len >= (size_t)WATCH_NAME_MAX) {
            (void)fprintf(stderr, "force: value too long for %s\n", name);
            return -1;
        }
        (void)memcpy(text, value, value_len);
        text[value_len] = '\0';
        return force_add(table, name, text, 1U, 1U, buf, len, iomap, vm, plant);
    }
}

static int force_load_cli(ForceTable *table, const char *csv, const uint8_t *buf,
                          uint32_t len, const IOMappingTable *iomap, const VM *vm,
                          const PlantTable *plant)
{
    const char *p = csv;

    for (;;) {
        const char *comma = strchr(p, ',');
        size_t piece = (comma != NULL) ? (size_t)(comma - p) : strlen(p);

        if (force_take_pair(table, p, piece, buf, len, iomap, vm, plant) != 0) {
            return -1;
        }
        if (comma == NULL) { break; }
        p = comma + 1;
    }
    return 0;
}

/* ================================================================
   启动期：.script 文件
   ================================================================ */

static uint32_t force_split(char *line, char *fields[], uint32_t max_fields)
{
    uint32_t n = 0U;
    char *p = line;

    for (;;) {
        while ((*p == ' ') || (*p == '\t')) { p++; }
        if (*p == '\0') { break; }
        if (n < max_fields) { fields[n] = p; }
        n++;
        while ((*p != '\0') && (*p != ' ') && (*p != '\t')) { p++; }
        if (*p != '\0') {
            *p = '\0';
            p++;
        }
    }
    return n;
}

static int force_load_script(ForceTable *table, const char *path, uint32_t cycles,
                             const uint8_t *buf, uint32_t len,
                             const IOMappingTable *iomap, const VM *vm,
                             const PlantTable *plant)
{
    char line[FORCE_LINE_MAX];
    char *fields[FORCE_FIELDS + 1U];
    FILE *fp = fopen(path, "r");
    uint32_t lineno = 0U;
    int truncated = 0;

    if (fp == NULL) {
        perror("force: fopen");
        return -1;
    }

    while (fgets(line, (int)sizeof(line), fp) != NULL) {
        size_t n;

        lineno++;
        n = strlen(line);
        if ((n == 0U) || (line[n - 1U] != '\n')) {
            if (!feof(fp)) {
                truncated = 1;
                break;
            }
        }
        if (n > 0U) {
            line[strcspn(line, "\r\n")] = '\0';
        }
        n = strlen(line);
        while ((n > 0U) && ((line[0] == ' ') || (line[0] == '\t'))) {
            (void)memmove(line, line + 1, n);
            line[n - 1U] = '\0';
            n--;
        }
        if ((n == 0U) || (line[0] == '#')) { continue; }

        uint32_t count = force_split(line, fields, FORCE_FIELDS);
        if (count != FORCE_FIELDS) {
            (void)fprintf(stderr, "script: line %u: expected 3 whitespace-"
                          "separated fields: cycle name value\n", lineno);
            (void)fclose(fp);
            return -1;
        }

        int32_t cycle_value = 0;
        if (force_i32(fields[0], &cycle_value) != 0) {
            (void)fprintf(stderr, "script: line %u: cycle is not an integer: %s\n",
                          lineno, fields[0]);
            (void)fclose(fp);
            return -1;
        }
        if ((cycle_value < 1) || ((uint32_t)cycle_value > cycles)) {
            (void)fprintf(stderr,
                          "script: line %u: cycle %d outside the run of %u "
                          "cycles\n", lineno, (int)cycle_value, cycles);
            (void)fclose(fp);
            return -1;
        }
        if (strlen(fields[1]) >= (size_t)WATCH_NAME_MAX) {
            (void)fprintf(stderr, "script: line %u: name too long (max %d)\n",
                          lineno, WATCH_NAME_MAX - 1);
            (void)fclose(fp);
            return -1;
        }
        if (strlen(fields[2]) >= (size_t)WATCH_NAME_MAX) {
            (void)fprintf(stderr, "script: line %u: value too long\n", lineno);
            (void)fclose(fp);
            return -1;
        }
        if (force_add(table, fields[1], fields[2], (uint32_t)cycle_value, 0U,
                      buf, len, iomap, vm, plant) != 0) {
            (void)fprintf(stderr, "script: line %u rejected\n", lineno);
            (void)fclose(fp);
            return -1;
        }
    }

    (void)fclose(fp);
    if (truncated != 0) {
        (void)fprintf(stderr, "script: line %u longer than %u bytes\n",
                      lineno, (unsigned int)FORCE_LINE_MAX);
        return -1;
    }
    return 0;
}

/* ================================================================
   启动期收尾：把记录排成"同名一段、周期递增"
   ================================================================ */

static void force_sort(ForceTable *table)
{
    for (uint32_t i = 1U; i < table->record_count; i++) {
        ForceRecord key = table->records[i];
        uint32_t j = i;

        while ((j > 0U) &&
               (((uint32_t)table->records[j - 1U].target > (uint32_t)key.target) ||
                (((uint32_t)table->records[j - 1U].target == (uint32_t)key.target) &&
                 (table->records[j - 1U].cycle > key.cycle)))) {
            table->records[j] = table->records[j - 1U];
            j--;
        }
        table->records[j] = key;
    }

    for (uint32_t t = 0U; t < table->target_count; t++) {
        table->targets[t].rec_first = 0U;
        table->targets[t].rec_count = 0U;
    }
    for (uint32_t i = 0U; i < table->record_count; i++) {
        ForceTarget *target = &table->targets[(uint32_t)table->records[i].target];

        if (target->rec_count == 0U) { target->rec_first = i; }
        target->rec_count++;
    }
}

int force_build(ForceTable *table, const char *csv, const char *script,
                uint32_t cycles, const uint8_t *buf, uint32_t len,
                const IOMappingTable *iomap, const VM *vm,
                const PlantTable *plant)
{
    if (table == NULL) { return -1; }

    (void)memset(table, 0, sizeof(*table));

    if ((csv == NULL) && (script == NULL)) { return 0; }
    if ((csv != NULL) && (csv[0] == '\0')) {
        (void)fprintf(stderr, "force: empty --force list\n");
        return -1;
    }

    if ((csv != NULL) &&
        (force_load_cli(table, csv, buf, len, iomap, vm, plant) != 0)) {
        return -1;
    }
    if ((script != NULL) &&
        (force_load_script(table, script, cycles, buf, len, iomap, vm, plant) != 0)) {
        return -1;
    }

    force_sort(table);
    table->active_count = (table->target_count > 0U) ? 1U : 0U;
    return 0;
}

/* ================================================================
   运行期
   ================================================================ */

void force_begin_cycle(ForceTable *table, uint32_t cycle)
{
    if ((table == NULL) || (table->active_count == 0U)) { return; }

    for (uint32_t t = 0U; t < table->target_count; t++) {
        ForceTarget *target = &table->targets[t];

        while (target->rec_taken < target->rec_count) {
            uint32_t index = target->rec_first + target->rec_taken;

            if (table->records[index].cycle > cycle) { break; }
            target->active = (int32_t)index;
            target->rec_taken++;
        }
    }
}

void force_apply_plant(const ForceTable *table, PlantTable *plant)
{
    if ((table == NULL) || (table->active_count == 0U) || (plant == NULL)) { return; }

    for (uint32_t t = 0U; t < table->target_count; t++) {
        const ForceTarget *target = &table->targets[t];

        if ((target->channel < 0) || (target->active < 0)) { continue; }
        (void)plant_inject(plant, (uint32_t)target->channel,
                           table->records[(uint32_t)target->active].raw);
    }
}

void force_apply_memory(const ForceTable *table, VM *vm)
{
    if ((table == NULL) || (table->active_count == 0U) || (vm == NULL)) { return; }

    for (uint32_t t = 0U; t < table->target_count; t++) {
        const ForceTarget *target = &table->targets[t];
        uint32_t word;

        if ((target->channel >= 0) || (target->active < 0)) { continue; }
        if ((target->addr > vm->memory_size) ||
            (FORCE_SLOT_BYTES > vm->memory_size - target->addr)) { continue; }

        word = table->records[(uint32_t)target->active].bits;
        force_le32_write(vm->memory + target->addr, word);
    }
}

int force_is_forced(const ForceTable *table, const char *name)
{
    if ((table == NULL) || (table->active_count == 0U) || (name == NULL)) { return 0; }

    for (uint32_t t = 0U; t < table->target_count; t++) {
        if ((table->targets[t].active >= 0) &&
            (strcmp(table->targets[t].name, name) == 0)) {
            return 1;
        }
    }
    return 0;
}
