/**
 * sim/plant.c
 * `.plant` 解析 + 逐周期确定性步进
 *
 * 见 plant.h 的列协议。解析器为定长缓冲 + 手写分词：无 malloc、无 strtok、
 * 行长溢出与字段数不符一律拒绝并报行号 —— 仿真配置错了不如不跑。
 */

#include "plant.h"

#include <errno.h>
#include <float.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ================================================================
   字段解析
   ================================================================ */

static int field_empty(const char *s)
{
    return (s[0] == '\0');
}

static int parse_u32_field(const char *text, uint32_t *out)
{
    char *end = NULL;
    errno = 0;
    long v = strtol(text, &end, 10);
    if ((errno != 0) || (field_empty(text)) || (*end != '\0') ||
        (v < 0) || (v > (long)UINT32_MAX)) {
        return -1;
    }
    *out = (uint32_t)v;
    return 0;
}

static int parse_i32_field(const char *text, int32_t *out)
{
    char *end = NULL;
    errno = 0;
    long v = strtol(text, &end, 10);
    if ((errno != 0) || (field_empty(text)) || (*end != '\0') ||
        (v < (long)INT32_MIN) || (v > (long)INT32_MAX)) {
        return -1;
    }
    *out = (int32_t)v;
    return 0;
}

static int finite_double(double v)
{
    /* NaN 的两个比较都为假，取非形式才能同时拒掉 ±Inf 与 NaN */
    return (v >= (-DBL_MAX)) && (v <= DBL_MAX);
}

static int parse_f64_field(const char *text, double *out)
{
    char *end = NULL;
    errno = 0;
    double v = strtod(text, &end);
    if ((errno != 0) || (field_empty(text)) || (*end != '\0') || (!finite_double(v))) {
        return -1;
    }
    *out = v;
    return 0;
}

static int parse_dir(const char *text, uint8_t *out)
{
    if (strcmp(text, "INPUT") == 0) {
        *out = IO_DIR_INPUT;
        return 0;
    }
    if (strcmp(text, "OUTPUT") == 0) {
        *out = IO_DIR_OUTPUT;
        return 0;
    }
    return -1;
}

static int parse_kind(const char *text, uint8_t *out)
{
    if (strcmp(text, "CONST") == 0) {
        *out = PLANT_KIND_CONST;
        return 0;
    }
    if (strcmp(text, "LAG") == 0) {
        *out = PLANT_KIND_LAG;
        return 0;
    }
    if (strcmp(text, "RAMP") == 0) {
        *out = PLANT_KIND_RAMP;
        return 0;
    }
    if (strcmp(text, "ACTUATOR") == 0) {
        *out = PLANT_KIND_ACTUATOR;
        return 0;
    }
    return -1;
}

/* ================================================================
   行分词
   ================================================================ */

/**
 * split_line - 按空白切分，最多 PLANT_FIELDS 个字段
 * @return 字段数；遇到第 PLANT_FIELDS+1 个字段时返回超限值以便判错
 */
static uint32_t split_line(char *line, char *fields[], uint32_t max_fields)
{
    uint32_t n = 0U;
    char *p = line;

    for (;;) {
        while ((*p == ' ') || (*p == '\t')) { p++; }
        if (*p == '\0') { break; }

        if (n < max_fields) {
            fields[n] = p;
        }
        n++;

        while ((*p != '\0') && (*p != ' ') && (*p != '\t')) { p++; }
        if (*p != '\0') {
            *p = '\0';
            p++;
        }
    }
    return n;
}

static int is_blank(const char *s)
{
    while ((*s == ' ') || (*s == '\t')) { s++; }
    return (*s == '\0');
}

/* ================================================================
   校验
   ================================================================ */

static void fail_line(uint32_t lineno, const char *reason)
{
    (void)fprintf(stderr, "plant: line %u: %s\n", lineno, reason);
}

static int check_row(const PlantChannel *ch, uint32_t lineno)
{
    if (ch->min_value > ch->max_value) {
        fail_line(lineno, "min greater than max");
        return -1;
    }
    if ((ch->init_value < ch->min_value) || (ch->init_value > ch->max_value)) {
        fail_line(lineno, "init outside [min,max]");
        return -1;
    }
    if (ch->channel_id >= (uint32_t)PLANT_MAX_CHANNELS) {
        fail_line(lineno, "channel id beyond IO_MAX_CHANNELS");
        return -1;
    }

    if (ch->direction == IO_DIR_OUTPUT) {
        if (ch->kind != PLANT_KIND_ACTUATOR) {
            fail_line(lineno, "OUTPUT channel must be ACTUATOR");
            return -1;
        }
        if (ch->drive != PLANT_NO_DRIVE) {
            fail_line(lineno, "ACTUATOR channel must not declare a driver");
            return -1;
        }
        return 0;
    }

    if (ch->kind == PLANT_KIND_ACTUATOR) {
        fail_line(lineno, "ACTUATOR kind requires dir OUTPUT");
        return -1;
    }
    if ((ch->kind == PLANT_KIND_CONST) || (ch->kind == PLANT_KIND_RAMP)) {
        if (ch->drive != PLANT_NO_DRIVE) {
            fail_line(lineno, "only LAG can declare a driver");
            return -1;
        }
    }
    if ((ch->kind == PLANT_KIND_LAG) && ((ch->gain <= 0.0) || (ch->gain > 1.0))) {
        fail_line(lineno, "LAG gain must be in (0,1]");
        return -1;
    }
    return 0;
}

/* drive 引用的通道必须存在且是 OUTPUT；在整表读完后再查 */
static int check_drives(const PlantTable *table)
{
    for (uint32_t i = 0U; i < table->count; i++) {
        const PlantChannel *ch = &table->channels[i];
        if (ch->drive == PLANT_NO_DRIVE) { continue; }

        const PlantChannel *drv = plant_find(table, (uint32_t)ch->drive);
        if (drv == NULL) {
            (void)fprintf(stderr, "plant: channel %u drives unknown channel %d\n",
                          ch->channel_id, (int)ch->drive);
            return -1;
        }
        if (drv->direction != IO_DIR_OUTPUT) {
            (void)fprintf(stderr, "plant: channel %u drives channel %d, which is not an output\n",
                          ch->channel_id, (int)ch->drive);
            return -1;
        }
    }
    return 0;
}

/* ================================================================
   加载
   ================================================================ */

int plant_load(PlantTable *table, const char *path)
{
    if ((table == NULL) || (path == NULL)) { return -1; }

    FILE *fp = fopen(path, "r");
    if (fp == NULL) {
        perror("plant: fopen");
        return -1;
    }

    (void)memset(table, 0, sizeof(PlantTable));

    char line[PLANT_LINE_MAX];
    char *fields[PLANT_FIELDS + 1U];
    uint32_t lineno = 0U;
    int truncated = 0;

    while (fgets(line, (int)sizeof(line), fp) != NULL) {
        lineno++;

        size_t len = strlen(line);
        if ((len == 0U) || (line[len - 1U] != '\n')) {
            /* 无换行的超长行：要么到 EOF（可接受），要么缓冲区塞不下 */
            if (!feof(fp)) {
                truncated = 1;
                break;
            }
        }
        if (len > 0U) {
            line[strcspn(line, "\r\n")] = '\0';
        }

        if (is_blank(line) || (line[strspn(line, " \t")] == '#')) { continue; }

        if (table->count >= (uint32_t)PLANT_MAX_CHANNELS) {
            fail_line(lineno, "more channels than the table holds");
            (void)fclose(fp);
            return -1;
        }

        uint32_t n = split_line(line, fields, PLANT_FIELDS);
        if (n != PLANT_FIELDS) {
            fail_line(lineno, "expected 9 whitespace-separated fields");
            (void)fclose(fp);
            return -1;
        }

        PlantChannel ch;
        (void)memset(&ch, 0, sizeof(ch));
        ch.drive = PLANT_NO_DRIVE;

        if ((parse_u32_field(fields[0], &ch.channel_id) != 0) ||
            (parse_dir(fields[1], &ch.direction) != 0) ||
            (parse_kind(fields[2], &ch.kind) != 0) ||
            (parse_f64_field(fields[3], &ch.gain) != 0) ||
            (parse_f64_field(fields[4], &ch.offset) != 0) ||
            (parse_i32_field(fields[5], &ch.min_value) != 0) ||
            (parse_i32_field(fields[6], &ch.max_value) != 0) ||
            (parse_i32_field(fields[7], &ch.init_value) != 0) ||
            (parse_i32_field(fields[8], &ch.drive) != 0)) {
            fail_line(lineno, "malformed field");
            (void)fclose(fp);
            return -1;
        }
        if (ch.drive < PLANT_NO_DRIVE) {
            fail_line(lineno, "drive must be a channel id or -1");
            (void)fclose(fp);
            return -1;
        }

        if (check_row(&ch, lineno) != 0) {
            (void)fclose(fp);
            return -1;
        }
        if (plant_find(table, ch.channel_id) != NULL) {
            fail_line(lineno, "duplicate channel id");
            (void)fclose(fp);
            return -1;
        }

        ch.state = (double)ch.init_value;
        table->channels[table->count] = ch;
        table->count++;
    }

    (void)fclose(fp);

    if (truncated != 0) {
        fail_line(lineno, "line longer than PLANT_LINE_MAX");
        return -1;
    }
    if (table->count == 0U) {
        (void)fprintf(stderr, "plant: no channels in %s\n", path);
        return -1;
    }
    return check_drives(table);
}

/* ================================================================
   表操作
   ================================================================ */

/* 表以 const 传入，好让只读调用方（配置核对、打印）复用同一函数；
   步进与 io_write 需要可变表项，因此返回非 const —— 转换是刻意的，
   调用方拿到的指针始终属于它自己传入的那张表。 */
PlantChannel *plant_find(const PlantTable *table, uint32_t channel_id)
{
    if (table == NULL) { return NULL; }

    for (uint32_t i = 0U; i < table->count; i++) {
        if (table->channels[i].channel_id == channel_id) {
            return (PlantChannel *)&table->channels[i];
        }
    }
    return NULL;
}

static int32_t clamp_state(const PlantChannel *ch, double value)
{
    double limited = value;

    if (limited < (double)ch->min_value) { limited = (double)ch->min_value; }
    if (limited > (double)ch->max_value) { limited = (double)ch->max_value; }
    /* 向零截断：与映射层 raw <-> eng 的 (int32_t) 转换一致 */
    return (int32_t)limited;
}

int plant_read_raw(const PlantTable *table, uint32_t channel_id, int32_t *value)
{
    if ((table == NULL) || (value == NULL)) { return -1; }

    const PlantChannel *ch = plant_find(table, channel_id);
    if (ch == NULL) { return -1; }

    *value = clamp_state(ch, ch->state);
    return 0;
}

int plant_write_raw(PlantTable *table, uint32_t channel_id, int32_t value)
{
    if (table == NULL) { return -1; }

    PlantChannel *ch = plant_find(table, channel_id);
    if ((ch == NULL) || (ch->direction != IO_DIR_OUTPUT)) { return -1; }

    ch->state = (double)clamp_state(ch, (double)value);
    return 0;
}

void plant_step(PlantTable *table)
{
    if (table == NULL) { return; }

    for (uint32_t i = 0U; i < table->count; i++) {
        PlantChannel *ch = &table->channels[i];
        double next = ch->state;

        if (ch->direction != IO_DIR_INPUT) { continue; }

        switch (ch->kind) {
        case PLANT_KIND_CONST:
            break;
        case PLANT_KIND_RAMP:
            next = ch->state + ch->gain;
            break;
        case PLANT_KIND_LAG: {
            double target = 0.0;
            if (ch->drive != PLANT_NO_DRIVE) {
                const PlantChannel *drv = plant_find(table, (uint32_t)ch->drive);
                if (drv != NULL) {
                    target = (double)clamp_state(drv, drv->state);
                }
            }
            next = ch->state + (ch->gain * ((target + ch->offset) - ch->state));
            break;
        }
        default:
            break;
        }

        ch->state = (double)clamp_state(ch, next);
    }
}
