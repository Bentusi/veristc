/*
 * vm/sasm_run.c
 * CLI wrapper: load a .sasm file, run one cycle, print local 0.
 * Used by the end-to-end test so compiler output can be checked on the VM.
 */

#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include "vm.h"

/* io_mapping_cycle is only referenced by the I/O scan path. */
int io_mapping_cycle(void *table, VM *vm);
int io_mapping_cycle(void *table, VM *vm)
{
    (void)table;
    return vm_run(vm);
}

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr, "usage: %s <file.sasm> [expected] [local_index]\n", argv[0]);
        return 2;
    }

    FILE *fp = fopen(argv[1], "rb");
    if (!fp) {
        perror("fopen");
        return 2;
    }
    static uint8_t buf[262144];
    size_t len = fread(buf, 1, sizeof(buf), fp);
    fclose(fp);

    static SasmModule module;
    if (sasm_load(buf, (uint32_t)len, &module) != 0) {
        fprintf(stderr, "sasm_load failed\n");
        return 3;
    }
    if (!sasm_validate(&module)) {
        fprintf(stderr, "sasm_validate failed\n");
        return 3;
    }

    static VM vm;
    if (vm_init(&vm, &module, 256) != 0) {
        fprintf(stderr, "vm_init failed\n");
        return 3;
    }
    int rc = vm_run(&vm);
    if (rc != VM_OK) {
        fprintf(stderr, "vm_run failed: %d\n", rc);
        return 3;
    }

    sasm_value result;
    unsigned local_index = 0;
    if (argc >= 4 || (vm.frame_stack_ptr > 0 &&
                      vm.frame_stack[0].local_count > 0)) {
        local_index = argc >= 4 ? (unsigned)atoi(argv[3]) : 0u;
        if (vm.frame_stack_ptr == 0 ||
            local_index >= vm.frame_stack[0].local_count) {
            fprintf(stderr, "local index out of range\n");
            return 3;
        }
        result = vm.frame_stack[0].locals[local_index];
    } else {
        result = vm_get_result(&vm);
    }
    printf("%d\n", result);
    if (argc >= 3 && atoi(argv[2]) != result) {
        fprintf(stderr, "expected %s, got %d\n", argv[2], result);
        return 1;
    }
    return 0;
}
