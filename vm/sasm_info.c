/**
 * vm/sasm_info.c
 * SafeASM binary information display (invoked by svm -i)
 * 
 * Displays summary information about a .sasm file:
 *   - File header (Magic/Version/Flags)
 *   - Safety level (SIL2/SIL3)
 *   - WCET (Worst-Case Execution Time) per function and total
 *   - Function/type count
 *   - Memory layout summary
 *   - I/O map summary
 *   - Code size
 *   - CRC32 verification
 *   - Stack depth
 *   - Loop bounds
 */

#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <stdlib.h>
#include "vm.h"
#include "sasm_info.h"

static const uint32_t info_crc32_table[256] = {
#include "crc32_table.inc"
};

static uint32_t info_crc32_compute(const uint8_t *data, uint32_t len)
{
    uint32_t crc = 0xFFFFFFFF;
    for (uint32_t i = 0; i < len; i++) {
        uint8_t index = (crc ^ data[i]) & 0xFF;
        crc = (crc >> 8) ^ info_crc32_table[index];
    }
    return crc ^ 0xFFFFFFFF;
}

/* ================================================================
   Read functions (same as loader.c)
   ================================================================ */

static inline uint8_t  r8(const uint8_t **p, uint32_t *len) {
    if (*len < 1) { return 0; }
    uint8_t v = (*p)[0]; *p += 1; *len -= 1; return v;
}

static inline uint32_t r32(const uint8_t **p, uint32_t *len) {
    if (*len < 4) { return 0; }
    uint32_t v = (uint32_t)(*p)[0] | ((uint32_t)(*p)[1]<<8) |
                 ((uint32_t)(*p)[2]<<16) | ((uint32_t)(*p)[3]<<24);
    *p += 4; *len -= 4; return v;
}

static inline uint16_t r16(const uint8_t **p, uint32_t *len) {
    if (*len < 2) { return 0; }
    uint16_t v = (uint16_t)(*p)[0] | ((uint16_t)(*p)[1]<<8);
    *p += 2; *len -= 2; return v;
}

/* ================================================================
   Parse and display .sasm file info
   ================================================================ */

int sasm_info_file(const char *path) {
    if (!path) { return 1; }

    /* Read file */
    FILE *fp = fopen(path, "rb");
    if (!fp) {
        perror("Failed to open file");
        return 1;
    }
    
    (void)fseek(fp, 0, SEEK_END);
    long fsize = ftell(fp);
    (void)fseek(fp, 0, SEEK_SET);
    
    if (fsize < 10) {
        (void)fprintf(stderr, "File too small\n");
        (void)fclose(fp);
        return 1;
    }
    
    uint8_t *buf = (uint8_t *)malloc(fsize);
    if (!buf) {
        (void)fprintf(stderr, "Memory allocation failed\n");
        (void)fclose(fp);
        return 1;
    }
    
    if (fread(buf, 1, fsize, fp) != (size_t)fsize) {
        perror("Read failed");
        free(buf);
        (void)fclose(fp);
        return 1;
    }
    (void)fclose(fp);
    
    /* ============================================================
       Parse and display
       ============================================================ */
    
    const uint8_t *p = buf;
    uint32_t len = (uint32_t)fsize;
    
    (void)printf("╔══════════════════════════════════════════════════════════╗\n");
    (void)printf("║  SafeASM Module Info: %-37s ║\n", path);
    (void)printf("╚══════════════════════════════════════════════════════════╝\n\n");
    
    /* --- File header --- */
    uint32_t magic = r32(&p, &len);
    uint8_t  ver   = r8(&p, &len);
    uint8_t  flags = r8(&p, &len);
    
    (void)printf("[File Header]\n");
    (void)printf("  Magic:      0x%08X (\"%c%c%c%c\")\n", magic,
           (magic>>0)&0xFF, (magic>>8)&0xFF, (magic>>16)&0xFF, (magic>>24)&0xFF);
    (void)printf("  Version:    %u", ver);
    if (ver != 1) { (void)printf(" (warning: expected 1)"); }
    (void)printf("\n");
    (void)printf("  Flags:      0x%02X\n", flags);
    (void)printf("  File size:  %ld bytes\n", fsize);
    
    /* Statistics */
    uint32_t type_count = 0;
    uint32_t func_count = 0;
    uint32_t code_size = 0;
    uint32_t total_memory = 0;
    uint32_t segment_count = 0;
    uint32_t iomap_count = 0;
    uint32_t safety_level = 0;
    uint32_t cycle_limit = 0;
    uint32_t stack_depth = 0;
    uint32_t loop_count = 0;
    uint32_t wcet_count = 0;
    uint32_t total_wcet_cycles = 0;
    uint32_t total_wcet_ns = 0;
    
    (void)printf("\n[Sections]\n");
    
    int section_num = 0;
    while (len > 4) {
        uint8_t  sec_type = r8(&p, &len);
        uint32_t sec_len  = r32(&p, &len);
        (void)r8(&p, &len);  /* reserved */
        (void)r16(&p, &len); /* flags */
        
        if (sec_len > len) {
            (void)printf("  Warning: Section %d length %u exceeds remaining data %u\n",
                   section_num, sec_len, len);
            break;
        }
        
        const char *sec_name = "";
        switch (sec_type) {
        case 0: sec_name = "TYPE";  break;
        case 1: sec_name = "FUNC";  break;
        case 2: sec_name = "MEM";   break;
        case 3: sec_name = "IOMAP"; break;
        case 4: sec_name = "CODE";  break;
        case 5: sec_name = "SAFE";  break;
        case 6: sec_name = "WCET";  break;
        case 7: sec_name = "DEBUG"; break;
        default: sec_name = "UNKNOWN"; break;
        }
        
        (void)printf("  [%d] %-8s  size=%-6u bytes\n",
               section_num, sec_name, sec_len);
        
        const uint8_t *sec_data_start = p;
        const uint8_t *sec_data = p;
        uint32_t sec_remaining = sec_len;
        
        /* --- TYPE Section --- */
        if (sec_type == 0) {
            while ((sec_remaining > 0) && (type_count < SASM_MAX_FUNCTIONS)) {
                uint32_t pc = r32(&sec_data, &sec_remaining);
                sec_data += pc; sec_remaining -= (pc > sec_remaining) ? sec_remaining : pc;
                uint32_t rc = r32(&sec_data, &sec_remaining);
                sec_data += rc; sec_remaining -= (rc > sec_remaining) ? sec_remaining : rc;
                type_count++;
            }
            (void)printf("             %u function signatures\n", type_count);
        }
        
        /* --- FUNC Section --- */
        else if (sec_type == 1) {
            while ((sec_remaining > 0) && (func_count < SASM_MAX_FUNCTIONS)) {
                (void)r32(&sec_data, &sec_remaining); /* type_idx */
                uint32_t lc = r32(&sec_data, &sec_remaining);
                sec_data += lc; sec_remaining -= (lc > sec_remaining) ? sec_remaining : lc;
                func_count++;
            }
            (void)printf("             %u function declarations\n", func_count);
        }
        
        /* --- MEM Section --- */
        else if (sec_type == 2) {
            total_memory = r32(&sec_data, &sec_remaining);
            segment_count = r32(&sec_data, &sec_remaining);
            (void)printf("             total memory: %u bytes, %u segments\n",
                   total_memory, segment_count);
        }
        
        /* --- IOMAP Section --- */
        else if (sec_type == 3) {
            iomap_count = r32(&sec_data, &sec_remaining);
            (void)printf("             %u I/O mapping entries\n", iomap_count);
        }
        
        /* --- CODE Section --- */
        else if (sec_type == 4) {
            while (sec_remaining > 0) {
                (void)r32(&sec_data, &sec_remaining); /* func_idx */
                uint32_t bs = r32(&sec_data, &sec_remaining);
                code_size += bs;
                sec_data += bs;
                sec_remaining -= (bs > sec_remaining) ? sec_remaining : bs;
            }
            (void)printf("             total code size: %u bytes\n", code_size);
        }
        
        /* --- SAFE Section --- */
        else if (sec_type == 5) {
            safety_level = r8(&sec_data, &sec_remaining);
            cycle_limit = r32(&sec_data, &sec_remaining);
            stack_depth = r32(&sec_data, &sec_remaining);
            
            loop_count = r32(&sec_data, &sec_remaining);
            sec_data += loop_count * 12;
            sec_remaining -= (loop_count * 12 > sec_remaining) ? sec_remaining : loop_count * 12;
            
            uint32_t mem_range_count = r32(&sec_data, &sec_remaining);
            sec_data += mem_range_count * 8;
            sec_remaining -= (mem_range_count * 8 > sec_remaining) ? sec_remaining : mem_range_count * 8;
            
            if (sec_remaining >= 4) {
                wcet_count = r32(&sec_data, &sec_remaining);
                for (uint32_t i = 0; (i < wcet_count) && (sec_remaining >= 12); i++) {
                    (void)r32(&sec_data, &sec_remaining); /* func_idx */
                    uint32_t cy = r32(&sec_data, &sec_remaining);
                    uint32_t ns = r32(&sec_data, &sec_remaining);
                    total_wcet_cycles += cy;
                    total_wcet_ns += ns;
                    sec_remaining -= 12;
                }
            }
        }

        /* --- WCET Section --- */
        else if (sec_type == 6) {
            wcet_count = r32(&sec_data, &sec_remaining);
            for (uint32_t i = 0; (i < wcet_count) && (sec_remaining >= 12); i++) {
                (void)r32(&sec_data, &sec_remaining); /* func_idx */
                uint32_t cy = r32(&sec_data, &sec_remaining);
                uint32_t ns = r32(&sec_data, &sec_remaining);
                total_wcet_cycles += cy;
                total_wcet_ns += ns;
                sec_remaining -= 12;
            }
            (void)printf("             %u WCET entries\n", wcet_count);
        }
        
        /* Skip to next section */
        p = sec_data_start + sec_len;
        len = (uint32_t)((buf + fsize) - p);
        section_num++;
    }
    
    /* --- Summary --- */
    (void)printf("\n[Summary]\n");
    (void)printf("  Functions:       %u types, %u declarations\n", type_count, func_count);
    (void)printf("  Code size:       %u bytes\n", code_size);
    (void)printf("  Memory:          %u bytes total\n", total_memory);
    (void)printf("  I/O mappings:    %u channels\n", iomap_count);
    
    (void)printf("\n[Safety]\n");
    (void)printf("  Safety level:    %s (SIL%d)\n", 
           safety_level ? "SIL3" : "SIL2", safety_level ? 3 : 2);
    (void)printf("  Cycle limit:     %u instructions\n", cycle_limit);
    (void)printf("  Stack depth:     %u levels\n", stack_depth);
    (void)printf("  Loop bounds:     %u entries\n", loop_count);
    
    if (wcet_count > 0) {
        (void)printf("\n[WCET - Worst-Case Execution Time]\n");
        (void)printf("  Total WCET:      %u cycles, %u ns (%.3f us)\n",
               total_wcet_cycles, total_wcet_ns, total_wcet_ns / 1000.0);
        (void)printf("  Functions:       %u with timing info\n", wcet_count);
    }
    
    /* --- CRC32 --- */
    (void)printf("\n[Integrity]\n");
    if (len >= 4) {
        uint32_t stored_crc = r32(&p, &len);
        uint32_t computed_crc = info_crc32_compute(buf + 6, (uint32_t)fsize - 10);
        (void)printf("  CRC32 stored:    0x%08X\n", stored_crc);
        (void)printf("  CRC32 computed:  0x%08X\n", computed_crc);
        (void)printf("  Status:          %s\n",
               (stored_crc == 0) ? "(not computed)" :
               ((stored_crc == computed_crc) ? "OK" : "MISMATCH"));
    }
    
    free(buf);
    return 0;
}
