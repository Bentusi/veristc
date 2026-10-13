/*
 * tests/fuzz/sasm_fuzzer.c — .sasm 加载器模糊测试
 * 
 * P2 改进：验证 sasm_load() 对畸形输入的鲁棒性
 * 
 * 构建方式:
 *   1. 独立模式 (ASan/UBSan): make build-fuzzer
 *   2. libFuzzer 模式 (如可用): 见下方 #ifdef
 * 
 * 用法:
 *   ./sasm_fuzzer [corpus_dir] [max_iterations]
 *   - corpus_dir: 种子语料目录 (默认 tests/fuzz/corpus)
 *   - max_iterations: 最大迭代次数 (默认 100000)
 */

#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <sys/stat.h>

/* ── 内联 loader 源码 (与 test_vm.c 一致) ── */
#include "../../vm/vm.h"
#include "../../vm/loader.c"

/* ── 最大输入大小 ── */
#define MAX_INPUT_SIZE  (256 * 1024)  /* 256 KB */
#define MIN_INPUT_SIZE  8             /* Magic + Version 最小头部 */

/* ── 随机数生成 ── */
static uint32_t xorshift32(uint32_t *state) {
    uint32_t x = *state;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    *state = x;
    return x;
}

/* ── 从文件加载种子 ── */
static uint8_t *load_file(const char *path, uint32_t *out_size) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (sz <= 0 || sz > MAX_INPUT_SIZE) {
        fclose(f);
        return NULL;
    }
    uint8_t *buf = (uint8_t *)malloc((size_t)sz);
    if (!buf) { fclose(f); return NULL; }
    if (fread(buf, 1, (size_t)sz, f) != (size_t)sz) {
        free(buf);
        fclose(f);
        return NULL;
    }
    fclose(f);
    *out_size = (uint32_t)sz;
    return buf;
}

/* ── 变异策略 ── */
typedef enum {
    MUTATE_FLIP_BIT,
    MUTATE_SET_BYTE,
    MUTATE_INSERT_BYTE,
    MUTATE_DELETE_BYTE,
    MUTATE_OVERWRITE_4BYTES,
    MUTATE_TRUNCATE,
    MUTATE_COUNT
} mutate_strategy_t;

static void mutate(uint8_t *data, uint32_t *size, uint32_t *rng_state) {
    if (*size < MIN_INPUT_SIZE) {
        /* 太小，只插入 */
        if (*size < MAX_INPUT_SIZE) {
            uint32_t pos = xorshift32(rng_state) % (*size + 1);
            memmove(data + pos + 1, data + pos, *size - pos);
            data[pos] = (uint8_t)(xorshift32(rng_state) & 0xFF);
            (*size)++;
        }
        return;
    }

    mutate_strategy_t strategy = (mutate_strategy_t)(xorshift32(rng_state) % MUTATE_COUNT);

    switch (strategy) {
    case MUTATE_FLIP_BIT: {
        uint32_t pos = xorshift32(rng_state) % *size;
        uint8_t bit = 1 << (xorshift32(rng_state) % 8);
        data[pos] ^= bit;
        break;
    }
    case MUTATE_SET_BYTE: {
        uint32_t pos = xorshift32(rng_state) % *size;
        data[pos] = (uint8_t)(xorshift32(rng_state) & 0xFF);
        break;
    }
    case MUTATE_INSERT_BYTE: {
        if (*size >= MAX_INPUT_SIZE) break;
        uint32_t pos = xorshift32(rng_state) % (*size + 1);
        memmove(data + pos + 1, data + pos, *size - pos);
        data[pos] = (uint8_t)(xorshift32(rng_state) & 0xFF);
        (*size)++;
        break;
    }
    case MUTATE_DELETE_BYTE: {
        uint32_t pos = xorshift32(rng_state) % *size;
        memmove(data + pos, data + pos + 1, *size - pos - 1);
        (*size)--;
        break;
    }
    case MUTATE_OVERWRITE_4BYTES: {
        if (*size < 4) break;
        uint32_t pos = xorshift32(rng_state) % (*size - 3);
        uint32_t val = xorshift32(rng_state);
        memcpy(data + pos, &val, 4);
        break;
    }
    case MUTATE_TRUNCATE: {
        uint32_t new_size = MIN_INPUT_SIZE + 
            (xorshift32(rng_state) % (*size - MIN_INPUT_SIZE + 1));
        *size = new_size;
        break;
    }
    default:
        break;
    }
}

/* ── 扫描语料目录 ── */
static int scan_corpus_dir(const char *dir, uint8_t **seeds, uint32_t *sizes,
                           int max_seeds) {
    struct stat st;
    if (stat(dir, &st) != 0 || !S_ISDIR(st.st_mode)) return 0;

    /* 简单扫描: 尝试 .sasm 文件 */
    int count = 0;
    (void)dir;  /* 预留：未来可扩展为递归扫描 */
    
    /* 扫描常见测试文件 */
    const char *test_files[] = {
        "tests/veristc-tests/out/core_assign.sasm",
        "tests/veristc-tests/out/function_control_flow.sasm",
        NULL
    };

    for (int i = 0; test_files[i] && count < max_seeds; i++) {
        uint32_t sz;
        uint8_t *data = load_file(test_files[i], &sz);
        if (data) {
            seeds[count] = data;
            sizes[count] = sz;
            count++;
        }
    }

    return count;
}

/* ── 主测试循环 ── */
static int fuzz_iteration(const uint8_t *data, uint32_t size) {
    SasmModule module;
    /* 调用 loader，不关心返回值，只关心是否崩溃 */
    (void)sasm_load(data, size, &module);
    return 0;
}

/* ── libFuzzer 接口 (可选) ── */
#ifdef USE_LIBFUZZER
int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    if (size > MAX_INPUT_SIZE || size < MIN_INPUT_SIZE) return 0;
    fuzz_iteration(data, (uint32_t)size);
    return 0;
}
#endif

/* ── 独立运行模式 ── */
#ifndef USE_LIBFUZZER
int main(int argc, char **argv) {
    const char *corpus_dir = "tests/fuzz/corpus";
    uint32_t max_iterations = 100000;

    if (argc > 1) corpus_dir = argv[1];
    if (argc > 2) max_iterations = (uint32_t)atoi(argv[2]);

    printf("=== .sasm Loader Fuzzer ===\n");
    printf("Corpus: %s\n", corpus_dir);
    printf("Iterations: %u\n", max_iterations);
    printf("Max input size: %d bytes\n\n", MAX_INPUT_SIZE);

    /* 加载种子语料 */
    uint8_t *seeds[16];
    uint32_t seed_sizes[16];
    int seed_count = scan_corpus_dir(corpus_dir, seeds, seed_sizes, 16);
    
    if (seed_count == 0) {
        printf("WARNING: No seed corpus found, using minimal .sasm header\n");
        /* 创建最小有效头部 */
        seeds[0] = malloc(8);
        if (!seeds[0]) return 1;
        /* SASM Magic: 0x4D534153 (little-endian "SASM") */
        seeds[0][0] = 0x53; seeds[0][1] = 0x41;
        seeds[0][2] = 0x53; seeds[0][3] = 0x4D;
        seeds[0][4] = 0x01; /* version */
        seeds[0][5] = 0x00; seeds[0][6] = 0x00; seeds[0][7] = 0x00;
        seed_sizes[0] = 8;
        seed_count = 1;
    }

    printf("Loaded %d seed(s)\n\n", seed_count);

    /* 初始化 RNG */
    uint32_t rng_state = (uint32_t)time(NULL) ^ 0xDEADBEEF;

    /* 分配工作缓冲区 */
    uint8_t *work = (uint8_t *)malloc(MAX_INPUT_SIZE);
    if (!work) {
        fprintf(stderr, "ERROR: malloc failed\n");
        return 1;
    }

    uint32_t crashes = 0;
    uint32_t total = 0;

    printf("Starting fuzzing...\n");
    
    for (uint32_t i = 0; i < max_iterations; i++) {
        /* 选择种子 */
        int seed_idx = xorshift32(&rng_state) % seed_count;
        uint32_t size = seed_sizes[seed_idx];
        
        if (size > MAX_INPUT_SIZE) size = MAX_INPUT_SIZE;
        memcpy(work, seeds[seed_idx], size);

        /* 随机变异 1-3 次 */
        int mutations = 1 + (xorshift32(&rng_state) % 3);
        for (int m = 0; m < mutations; m++) {
            mutate(work, &size, &rng_state);
        }

        /* 执行测试 */
        fuzz_iteration(work, size);
        total++;

        /* 进度报告 */
        if ((i + 1) % 10000 == 0) {
            printf("  [%u/%u] iterations, %u crashes\n", i + 1, max_iterations, crashes);
        }
    }

    printf("\n=== Fuzzing Complete ===\n");
    printf("Total iterations: %u\n", total);
    printf("Crashes detected: %u\n", crashes);

    /* 清理 */
    free(work);
    for (int i = 0; i < seed_count; i++) {
        free(seeds[i]);
    }

    return crashes > 0 ? 1 : 0;
}
#endif /* !USE_LIBFUZZER */
