/*
 * vm/svm.c
 * Unified SafeASM VM command line:
 *   svm [options] <file.sasm> [expected] [local_index]
 *
 * Modes:
 *   default: execute scan cycles every 1000 ms
 *   -d:      dump the module and exit
 */

#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "vm.h"
#include "sasm_dump.h"

#define SVM_MAX_FILE_SIZE (2U * 1024U * 1024U)

static SasmModule module;
static VM vm;
static uint8_t file_data[SVM_MAX_FILE_SIZE];
static volatile sig_atomic_t stop_requested = 0;

/* io_mapping_cycle is only referenced by the I/O scan path. */
int io_mapping_cycle(void *table, VM *scan_vm);
int io_mapping_cycle(void *table, VM *scan_vm)
{
    (void)table;
    return vm_run(scan_vm);
}

static void on_signal(int signum)
{
    (void)signum;
    stop_requested = 1;
}

static void usage(const char *prog)
{
    fprintf(stderr,
            "usage: %s [options] <file.sasm> [expected] [local_index]\n"
            "options:\n"
            "  -d           dump module and exit\n"
            "  -n CYCLES    execute CYCLES cycles (0 = continuous, default 0)\n"
            "  -p MS        cycle period in milliseconds (default 1000)\n"
            "  -h           show this help\n",
            prog);
}

static int parse_u32(const char *text, uint32_t *value)
{
    char *end = NULL;
    errno = 0;
    unsigned long parsed = strtoul(text, &end, 10);
    if (errno != 0 || end == text || *end != '\0' ||
        parsed > UINT32_MAX) {
        return -1;
    }
    *value = (uint32_t)parsed;
    return 0;
}

static int load_module(const char *path)
{
    FILE *fp = fopen(path, "rb");
    if (!fp) {
        perror("fopen");
        return -1;
    }

    size_t len = fread(file_data, 1, sizeof(file_data), fp);
    fclose(fp);
    if (len == 0 || len >= sizeof(file_data)) {
        fprintf(stderr, "invalid module size\n");
        return -1;
    }

    int ret = sasm_load(file_data, (uint32_t)len, &module);
    if (ret != 0) {
        fprintf(stderr, "sasm_load failed: %d\n", ret);
        return -1;
    }
    if (!sasm_validate(&module)) {
        fprintf(stderr, "sasm_validate failed\n");
        return -1;
    }
    if (vm_init(&vm, &module, 0) != 0) {
        fprintf(stderr, "vm_init failed\n");
        return -1;
    }
    return 0;
}

static sasm_value vm_result(void)
{
    if (vm.frame_stack_ptr > 0 &&
        vm.frame_stack[0].local_count > 0) {
        return vm.frame_stack[0].locals[0];
    }
    return vm_get_result(&vm);
}

static sasm_value vm_local(unsigned index)
{
    if (vm.frame_stack_ptr == 0 ||
        index >= vm.frame_stack[0].local_count) {
        return 0;
    }
    return vm.frame_stack[0].locals[index];
}

static void sleep_until(const struct timespec *deadline)
{
    while (!stop_requested) {
        int ret = clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, deadline, NULL);
        if (ret == 0) return;
        if (ret != EINTR) return;
    }
}

static void advance_deadline(struct timespec *deadline, uint32_t period_ms)
{
    deadline->tv_sec += period_ms / 1000U;
    deadline->tv_nsec += (long)(period_ms % 1000U) * 1000000L;
    if (deadline->tv_nsec >= 1000000000L) {
        deadline->tv_sec += 1;
        deadline->tv_nsec -= 1000000000L;
    }
}

int main(int argc, char **argv)
{
    int dump_mode = 0;
    uint32_t cycles = 0;
    uint32_t period_ms = 1000;
    const char *path = NULL;
    const char *expected_text = NULL;
    const char *local_text = NULL;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-d") == 0) {
            dump_mode = 1;
        } else if (strcmp(argv[i], "-n") == 0) {
            if (++i >= argc || parse_u32(argv[i], &cycles) != 0) {
                usage(argv[0]);
                return 2;
            }
        } else if (strcmp(argv[i], "-p") == 0) {
            if (++i >= argc || parse_u32(argv[i], &period_ms) != 0) {
                usage(argv[0]);
                return 2;
            }
        } else if (strcmp(argv[i], "-h") == 0) {
            usage(argv[0]);
            return 0;
        } else if (argv[i][0] == '-' && argv[i][1] != '\0') {
            usage(argv[0]);
            return 2;
        } else if (path == NULL) {
            path = argv[i];
        } else if (expected_text == NULL) {
            expected_text = argv[i];
        } else if (local_text == NULL) {
            local_text = argv[i];
        } else {
            usage(argv[0]);
            return 2;
        }
    }

    if (path == NULL) {
        usage(argv[0]);
        return 2;
    }

    if (dump_mode) {
        return sasm_dump_file(path);
    }

    uint32_t local_index = 0;
    if (local_text != NULL && parse_u32(local_text, &local_index) != 0) {
        usage(argv[0]);
        return 2;
    }

    if (load_module(path) != 0) {
        return 3;
    }

    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);

    struct timespec deadline;
    clock_gettime(CLOCK_MONOTONIC, &deadline);

    uint32_t executed = 0;
    while (!stop_requested && (cycles == 0 || executed < cycles)) {
        int rc = vm_run(&vm);
        if (rc != VM_OK) {
            fprintf(stderr, "vm_run failed: %d\n", rc);
            return 3;
        }

        sasm_value result = local_text != NULL ? vm_local(local_index) : vm_result();
        printf("%d\n", result);
        fflush(stdout);

        if (expected_text != NULL && atoi(expected_text) != result) {
            fprintf(stderr, "expected %s, got %d\n", expected_text, result);
            return 1;
        }

        executed++;
        if (cycles != 0 && executed >= cycles) break;

        advance_deadline(&deadline, period_ms);
        sleep_until(&deadline);
    }

    return 0;
}
