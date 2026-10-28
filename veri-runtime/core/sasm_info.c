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
 *   - Debug section symbol count (spec 4.8; svm -s/-l resolve names)
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
   Debug section (7) symbol table — spec/safeasm-spec.md §4.8
   ================================================================ */

#define SYM_TAG_COUNT 25

static const char *const sym_type_names[SYM_TAG_COUNT] = {
    "BOOL", "INT", "DINT", "REAL", "LINT", "LREAL", "TIME", "QUALITY",
    "BYTE", "WORD", "DWORD", "SINT",
    "QBOOL", "QBYTE", "QWORD", "QDWORD", "QSINT", "QINT", "QDINT",
    "QLINT", "QREAL", "QLREAL", "QTIME",
    "ARRAY", "FB"
};

static const char *sym_type_name(uint8_t tag)
{
    if (tag < SYM_TAG_COUNT) { return sym_type_names[tag]; }
    return "UNKNOWN";
}

/* Locate the Debug section body; returns NULL when absent. */
static const uint8_t *sym_find_body(const uint8_t *buf, uint32_t fsize,
                                   uint32_t *body_len)
{
    const uint8_t *p = buf + 6;
    uint32_t remaining = fsize - 6;

    while (remaining > 4) {
        uint8_t sec_type;
        uint32_t sec_len;
        if (remaining < 8) { return NULL; }
        sec_type = r8(&p, &remaining);
        sec_len = r32(&p, &remaining);
        (void)r8(&p, &remaining);
        (void)r16(&p, &remaining);
        if (sec_len > remaining) { return NULL; }
        if (sec_type == SEC_DEBUG) {
            if (body_len != NULL) { *body_len = sec_len; }
            return p;
        }
        p += sec_len;
        remaining -= sec_len;
    }
    return NULL;
}

/* Validate the Debug section layout and expose its two blocks.
 * STRPOOL : u32 count | { u32 len | byte[len] }*
 * SYMTAB  : u32 count | { u32 name_off | u32 addr | u8 tag | u8 size | u16 flags }*
 * Returns 0 on success, -1 when the section is malformed. */
static int sym_parse(const uint8_t *body, uint32_t body_len,
                     const uint8_t **pool, uint32_t *pool_bytes,
                     const uint8_t **tab, uint32_t *tab_count)
{
    uint32_t remaining = body_len;
    const uint8_t *p = body;
    const uint8_t *pool_start;
    uint32_t pool_count;
    uint32_t i;

    pool_count = r32(&p, &remaining);
    if (pool_count > (1U << 20)) { return -1; }
    pool_start = p;
    for (i = 0; i < pool_count; i++) {
        uint32_t slen = r32(&p, &remaining);
        if (slen > remaining) { return -1; }
        p += slen;
        remaining -= slen;
    }

    *tab_count = r32(&p, &remaining);
    if ((*tab_count > (1U << 20)) || (remaining < *tab_count * 12U)) {
        return -1;
    }

    if (pool != NULL) { *pool = pool_start; }
    if (pool_bytes != NULL) { *pool_bytes = (uint32_t)(p - pool_start); }
    if (tab != NULL) { *tab = p; }
    return 0;
}

/* Decode one 12-byte SYMTAB row and resolve its name against STRPOOL.
 * `row`/`left` advance past the row on success. Returns 0, or -1 when the row
 * is truncated or points outside the pool. */
static int sym_row_read(const uint8_t **row, uint32_t *left,
                        const uint8_t *pool, uint32_t pool_bytes,
                        const char **name, uint32_t *name_len,
                        uint32_t *addr, uint8_t *type_tag, uint8_t *size)
{
    uint32_t name_off;
    uint32_t slen;
    const uint8_t *rp;
    uint32_t rl;

    if (*left < 12U) { return -1; }
    name_off = r32(row, left);
    *addr = r32(row, left);
    *type_tag = r8(row, left);
    *size = r8(row, left);
    (void)r16(row, left);          /* flags: no reader consumes them yet */

    /* name_off is relative to the first STRPOOL entry, and each entry is
     * length-prefixed, so it addresses the u32 length field directly. */
    if ((name_off > pool_bytes) || (pool_bytes - name_off < 4U)) { return -1; }
    rp = pool + name_off;
    rl = pool_bytes - name_off;
    slen = r32(&rp, &rl);
    if ((slen == 0U) || (slen > rl)) { return -1; }

    *name = (const char *)rp;
    *name_len = slen;
    return 0;
}

/* Print one row per matching symbol. want == NULL lists all.
 * Returns the number of rows printed, or -1 on a malformed section. */
static int sym_dump_rows(const uint8_t *body, uint32_t body_len,
                         const char *want)
{
    const uint8_t *pool;
    const uint8_t *row;
    uint32_t pool_bytes;
    uint32_t tab_count;
    uint32_t i;
    int printed = 0;

    if (sym_parse(body, body_len, &pool, &pool_bytes, &row, &tab_count) != 0) {
        return -1;
    }

    for (i = 0; i < tab_count; i++) {
        uint32_t left = body_len - (uint32_t)(row - body);
        const char *name;
        uint32_t name_len;
        uint32_t mem_addr;
        uint8_t type_tag;
        uint8_t size;

        if (sym_row_read(&row, &left, pool, pool_bytes, &name, &name_len,
                         &mem_addr, &type_tag, &size) != 0) {
            return -1;
        }
        if ((want == NULL) ||
            ((name_len == (uint32_t)strlen(want)) &&
             (memcmp(name, want, (size_t)name_len) == 0))) {
            (void)printf("%.*s 0x%08X %s size=%u\n",
                         (int)name_len, name, mem_addr,
                         sym_type_name(type_tag), (unsigned)size);
            printed++;
        }
    }
    return printed;
}

static uint8_t *read_whole_file(const char *path, long *size_out)
{
    FILE *fp;
    long fsize;
    uint8_t *buf;

    if ((path == NULL) || (size_out == NULL)) { return NULL; }
    fp = fopen(path, "rb");
    if (!fp) {
        perror("Failed to open file");
        return NULL;
    }

    (void)fseek(fp, 0, SEEK_END);
    fsize = ftell(fp);
    (void)fseek(fp, 0, SEEK_SET);

    if (fsize < 10) {
        (void)fprintf(stderr, "File too small\n");
        (void)fclose(fp);
        return NULL;
    }

    buf = (uint8_t *)malloc((size_t)fsize);
    if (!buf) {
        (void)fprintf(stderr, "Memory allocation failed\n");
        (void)fclose(fp);
        return NULL;
    }

    if (fread(buf, 1, (size_t)fsize, fp) != (size_t)fsize) {
        perror("Read failed");
        free(buf);
        (void)fclose(fp);
        return NULL;
    }
    (void)fclose(fp);
    *size_out = fsize;
    return buf;
}

/* ================================================================
   Symbol lookup entry point (svm -s / svm -l)
   ================================================================ */

int sasm_sym_file(const char *path, const char *name)
{
    long fsize = 0;
    uint8_t *buf = read_whole_file(path, &fsize);
    uint32_t body_len = 0;
    const uint8_t *body;
    int rows;

    if (!buf) { return 1; }

    body = sym_find_body(buf, (uint32_t)fsize, &body_len);
    if (body == NULL) {
        (void)fprintf(stderr,
                      "no symbol table (Debug section) in %s\n", path);
        free(buf);
        return 1;
    }

    rows = sym_dump_rows(body, body_len, name);
    free(buf);
    if (rows < 0) {
        (void)fprintf(stderr, "malformed Debug section in %s\n", path);
        return 1;
    }
    if ((name != NULL) && (rows == 0)) {
        (void)fprintf(stderr, "symbol not found: %s\n", name);
        return 1;
    }
    return 0;
}

/* ================================================================
   Symbol resolution against an in-memory image (sim --watch)
   ================================================================ */

int sasm_sym_resolve(const uint8_t *buf, uint32_t fsize, const char *name,
                     SasmSymInfo *out)
{
    const uint8_t *body;
    const uint8_t *pool;
    const uint8_t *row;
    uint32_t body_len = 0U;
    uint32_t pool_bytes;
    uint32_t tab_count;
    uint32_t i;
    size_t want_len;

    if ((buf == NULL) || (name == NULL) || (out == NULL) || (fsize < 10U)) {
        return -1;
    }
    body = sym_find_body(buf, fsize, &body_len);
    if (body == NULL) { return -1; }
    if (sym_parse(body, body_len, &pool, &pool_bytes, &row, &tab_count) != 0) {
        return -1;
    }

    want_len = strlen(name);
    for (i = 0U; i < tab_count; i++) {
        uint32_t left = body_len - (uint32_t)(row - body);
        const char *sym_name;
        uint32_t sym_len;
        uint8_t type_tag;
        uint8_t size;
        uint32_t addr;

        if (sym_row_read(&row, &left, pool, pool_bytes, &sym_name, &sym_len,
                         &addr, &type_tag, &size) != 0) {
            return -1;
        }
        if ((sym_len == (uint32_t)want_len) &&
            (memcmp(sym_name, name, want_len) == 0)) {
            out->addr = addr;
            out->type_tag = type_tag;
            out->size = size;
            out->type_name = sym_type_name(type_tag);
            return 0;
        }
    }
    return 1;
}

/* ================================================================
   Parse and display .sasm file info
   ================================================================ */

int sasm_info_file(const char *path) {
    if (!path) { return 1; }

    /* Read file */
    long fsize = 0;
    uint8_t *buf = read_whole_file(path, &fsize);
    if (!buf) { return 1; }
    
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
    uint32_t sym_count = 0;
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

        /* --- DEBUG Section (symbol table, spec 4.8) --- */
        else if (sec_type == 7) {
            uint32_t tab_count = 0;
            if (sym_parse(sec_data, sec_remaining, NULL, NULL, NULL,
                          &tab_count) != 0) {
                (void)printf("             symbol table malformed\n");
            } else {
                sym_count = tab_count;
                (void)printf("             %u symbols "
                             "(svm -s NAME / svm -l to resolve)\n", tab_count);
            }
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
    (void)printf("  Symbols:         %u\n", sym_count);
    
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
