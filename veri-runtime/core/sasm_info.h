#ifndef SASM_INFO_H
#define SASM_INFO_H

#include <stdbool.h>
#include <stdint.h>

int sasm_info_file(const char *path);

/* Parse the Debug (section 7) symbol table of a .sasm file.
 * name == NULL: list every symbol; otherwise print only exact matches.
 * Returns 0 on success (all matches printed / listing complete),
 * 1 when the module or the requested symbol cannot be used. */
int sasm_sym_file(const char *path, const char *name);

/* One Debug-section symbol, resolved by name. */
typedef struct {
    uint32_t    addr;       /* linear memory offset of the variable slot */
    uint8_t     type_tag;   /* section 7 type tag (spec 4.8) */
    uint8_t     size;       /* slot width in bytes */
    const char *type_name;  /* static string owned by sasm_info.c */
} SasmSymInfo;

/* Resolve one symbol by exact name inside an image already in memory, so a
 * tool that read the file for another reason does not read it twice.
 * Returns 0 = found, 1 = name absent, -1 = no Debug section / malformed. */
int sasm_sym_resolve(const uint8_t *buf, uint32_t fsize, const char *name,
                     SasmSymInfo *out);

#endif
