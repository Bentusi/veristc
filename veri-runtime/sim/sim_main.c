/**
 * sim/sim_main.c
 * 仿真主程序 —— 让编译产物在合成被控对象的闭环里跑起来
 *
 *   sim [options] <file.sasm> <plant-file>
 *     -n CYCLES     扫描周期数（默认 10）
 *     -t MS         周期时长，虚拟毫秒（默认 100）
 *     -q            只打印汇总，不打印逐周期时间线
 *     --watch NAMES 每周期输出一行 JSONL watch 帧（逗号分隔符号名，含派生名 实例#字段）
 *     -h            帮助
 *
 * 每周期走完整 I/O 扫描路径：
 *   io_mapping_read_all()（被控对象 -> VM 内存）-> vm_run() ->
 *   io_mapping_write_all()（VM 内存 -> 执行器）-> plant_step()
 * 这是 svm 从不经过的分支：svm 只执行 VM，I/O 与热备在它那里是缺席的。
 *
 * --watch 时 stdout 只走帧（配置回显改道 stderr），帧协议见 sim/watch.h。
 *
 * 退出码：0 成功；2 参数/配置错误；3 加载失败；4 执行期错误。
 */

#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../core/vm.h"
#include "../io/io_mapping.h"
#include "../rtos/abstract.h"
#include "plant.h"
#include "sim_io.h"
#include "watch.h"

#define SIM_MAX_FILE_SIZE (2U * 1024U * 1024U)
#define SIM_MAX_CYCLES    100000U

static SasmModule s_module;
static VM s_vm;
static IOMappingTable s_iomap;
static PlantTable s_plant;
static WatchSet s_watch;
static uint8_t s_file_data[SIM_MAX_FILE_SIZE];
static uint32_t s_file_len;

static void usage(const char *prog)
{
    (void)fprintf(stderr,
        "usage: %s [options] <file.sasm> <plant-file>\n"
        "  -n CYCLES   scan cycles to run (default 10)\n"
        "  -t MS       virtual cycle period in ms (default 100)\n"
        "  -q          summary only, no per-cycle timeline\n"
        "  --watch N   per-cycle JSONL watch frames for comma-separated\n"
        "              symbol names (e.g. --watch pv,mv,pid1#U)\n"
        "  -h          show this help\n",
        prog);
}

static int parse_u32(const char *text, uint32_t *value)
{
    char *end = NULL;
    errno = 0;
    unsigned long parsed = strtoul(text, &end, 10);
    if ((errno != 0) || (end == text) || (*end != '\0') ||
        (parsed > (unsigned long)UINT32_MAX)) {
        return -1;
    }
    *value = (uint32_t)parsed;
    return 0;
}

static int load_module(const char *path)
{
    FILE *fp = fopen(path, "rb");
    if (fp == NULL) {
        perror("fopen");
        return -1;
    }

    size_t len = fread(s_file_data, 1, sizeof(s_file_data), fp);
    (void)fclose(fp);
    if ((len == 0U) || (len >= sizeof(s_file_data))) {
        (void)fprintf(stderr, "invalid module size\n");
        return -1;
    }
    s_file_len = (uint32_t)len;

    int ret = sasm_load(s_file_data, (uint32_t)len, &s_module);
    if (ret != 0) {
        (void)fprintf(stderr, "sasm_load failed: %d\n", ret);
        return -1;
    }
    if (!sasm_validate(&s_module)) {
        (void)fprintf(stderr, "sasm_validate failed\n");
        return -1;
    }
    if (vm_init(&s_vm, &s_module, 0) != 0) {
        (void)fprintf(stderr, "vm_init failed\n");
        return -1;
    }
    return 0;
}

/* 配置一致性：映射表里每个通道都得在被控对象表里有对应方向的状态。
   否则仿真不会报错，只会一路把不存在的通道读成故障、写成故障。 */
static int check_plant_matches(const IOMappingTable *iomap, const PlantTable *plant)
{
    int bad = 0;

    for (uint32_t i = 0U; i < iomap->count; i++) {
        const IOMapEntryRuntime *e = &iomap->entries[i];
        const PlantChannel *ch = plant_find(plant, e->channel_id);

        if (ch == NULL) {
            (void)fprintf(stderr,
                          "plant has no channel %u mapped by the program\n",
                          e->channel_id);
            bad++;
            continue;
        }
        if (ch->direction != e->direction) {
            (void)fprintf(stderr,
                          "channel %u is %s in the program but %s in the plant\n",
                          e->channel_id,
                          (e->direction == IO_DIR_INPUT) ? "INPUT" : "OUTPUT",
                          (ch->direction == IO_DIR_INPUT) ? "INPUT" : "OUTPUT");
            bad++;
        }
    }
    return (bad == 0) ? 0 : -1;
}

static const char *kind_name(uint8_t kind)
{
    switch (kind) {
    case PLANT_KIND_CONST:    return "CONST";
    case PLANT_KIND_LAG:      return "LAG";
    case PLANT_KIND_RAMP:     return "RAMP";
    case PLANT_KIND_ACTUATOR: return "ACTUATOR";
    default:                  return "?";
    }
}

static void print_config(FILE *out, const IOMappingTable *iomap,
                         const PlantTable *plant)
{
    (void)fprintf(out, "plant: %u channels\n", plant->count);
    for (uint32_t i = 0U; i < plant->count; i++) {
        const PlantChannel *ch = &plant->channels[i];
        (void)fprintf(out,
            "  ch=%-3u %-6s %-8s gain=%g offset=%g range=[%d,%d] init=%d drive=%d\n",
            ch->channel_id,
            (ch->direction == IO_DIR_INPUT) ? "INPUT" : "OUTPUT",
            kind_name(ch->kind), ch->gain, ch->offset,
            ch->min_value, ch->max_value, ch->init_value,
            (int)ch->drive);
    }

    (void)fprintf(out, "mapping: %u channels bound to VM memory\n", iomap->count);
    for (uint32_t i = 0U; i < iomap->count; i++) {
        const IOMapEntryRuntime *e = &iomap->entries[i];
        (void)fprintf(out, "  ch=%-3u %-6s mem=0x%08X scale=%g bias=%g\n",
            e->channel_id,
            (e->direction == IO_DIR_INPUT) ? "INPUT" : "OUTPUT",
            e->mem_offset, e->scale_factor, e->bias);
    }
}

static void print_cycle_line(const IOMappingTable *iomap, uint32_t cycle,
                             int status)
{
    (void)printf("  cycle=%-6u t=%-9u", cycle, sim_io_ticks());
    for (uint32_t i = 0U; i < iomap->count; i++) {
        const IOMapEntryRuntime *e = &iomap->entries[i];
        (void)printf(" ch%u=%d", e->channel_id, e->eng_value);
    }
    (void)printf(" status=%d\n", status);
}

int main(int argc, char **argv)
{
    uint32_t cycles = 10U;
    uint32_t period_ms = 100U;
    int quiet = 0;
    const char *watch_csv = NULL;
    const char *paths[2] = { NULL, NULL };
    uint32_t npaths = 0U;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-n") == 0) {
            if ((++i >= argc) || (parse_u32(argv[i], &cycles) != 0)) {
                usage(argv[0]);
                return 2;
            }
        } else if (strcmp(argv[i], "-t") == 0) {
            if ((++i >= argc) || (parse_u32(argv[i], &period_ms) != 0)) {
                usage(argv[0]);
                return 2;
            }
        } else if (strcmp(argv[i], "--watch") == 0) {
            if (++i >= argc) {
                usage(argv[0]);
                return 2;
            }
            watch_csv = argv[i];
        } else if (strcmp(argv[i], "-q") == 0) {
            quiet = 1;
        } else if (strcmp(argv[i], "-h") == 0) {
            usage(argv[0]);
            return 0;
        } else if ((argv[i][0] == '-') && (argv[i][1] != '\0')) {
            usage(argv[0]);
            return 2;
        } else if (npaths < 2U) {
            paths[npaths] = argv[i];
            npaths++;
        } else {
            usage(argv[0]);
            return 2;
        }
    }

    if ((npaths != 2U) || (cycles == 0U) || (cycles > SIM_MAX_CYCLES) ||
        (period_ms == 0U)) {
        usage(argv[0]);
        return 2;
    }

    if (plant_load(&s_plant, paths[1]) != 0) {
        (void)fprintf(stderr, "sim: plant configuration rejected\n");
        return 2;
    }

    if (load_module(paths[0]) != 0) {
        return 3;
    }

    if (io_mapping_init(&s_iomap, &s_module, NULL, 0U) != 0) {
        (void)fprintf(stderr, "sim: io_mapping_init failed\n");
        return 3;
    }
    if (s_iomap.count == 0U) {
        (void)fprintf(stderr, "sim: program declares no I/O mapping; use svm instead\n");
        return 2;
    }
    if (check_plant_matches(&s_iomap, &s_plant) != 0) {
        return 2;
    }
    if ((watch_csv != NULL) &&
        (watch_build(&s_watch, watch_csv, s_file_data, s_file_len,
                     &s_iomap, &s_vm) != 0)) {
        (void)fprintf(stderr, "sim: watch request rejected\n");
        return 2;
    }

    sim_io_install(&s_plant, period_ms);
    if (g_vm_interface.init(NULL) != 0) {
        (void)fprintf(stderr, "sim: backend init failed\n");
        return 2;
    }

    /* watch 模式独占 stdout：配置回显改道 stderr，人读时间线不再打印 */
    if (s_watch.count > 0U) {
        print_config(stderr, &s_iomap, &s_plant);
    } else if (quiet == 0) {
        print_config(stdout, &s_iomap, &s_plant);
    }

    for (uint32_t c = 0U; c < cycles; c++) {
        uint32_t t_ms = sim_io_ticks();
        int rc = io_mapping_cycle(&s_iomap, &s_vm);

        if (s_watch.count > 0U) {
            watch_cycle_frame(&s_watch, &s_vm, &s_iomap, c + 1U, t_ms, rc);
        } else if (quiet == 0) {
            print_cycle_line(&s_iomap, c + 1U, rc);
        }
        if (rc != VM_OK) {
            (void)fprintf(stderr, "sim: cycle %u failed: %d\n", c + 1U, rc);
            return 4;
        }
        sim_io_advance();
    }

    if (s_watch.count > 0U) {
        watch_done_frame(cycles, &s_iomap, sim_io_ticks());
    } else {
        (void)printf("done: %u cycles, %u virtual ms, violations=%u"
                     " read_errors=%u write_errors=%u\n",
                     cycles, sim_io_ticks(), s_iomap.safety_violations,
                     s_iomap.read_errors, s_iomap.write_errors);
    }

    g_vm_interface.deinit();
    return 0;
}
