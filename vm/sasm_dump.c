/**
 * vm/sasm_dump.c
 * SafeASM 二进制可视化打印工具
 * 
 * 功能: 读取 .sasm 文件并打印可读的内容
 * 用法: ./sasm_dump <file.sasm>
 * 
 * 输出:
 *   - 文件头 (Magic/Version/Flags)
 *   - 所有 Section 类型和大小
 *   - Type Section: 函数签名
 *   - Memory Section: 内存布局
 *   - IOMap Section: I/O 映射表
 *   - Code Section: 反汇编 (指令助记符 + 立即数)
 *   - Safety Section: 安全注解
 *   - CRC32 校验和
 */

#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <stdlib.h>
#include "vm.h"

/* ================================================================
   指令助记符表
   ================================================================ */

static const char *opcode_name(uint8_t op) {
    switch (op) {
    case OP_UNREACHABLE: return "UNREACHABLE";
    case OP_NOP:         return "NOP";
    case OP_BLOCK:       return "BLOCK";
    case OP_LOOP:        return "LOOP";
    case OP_BR:          return "BR";
    case OP_BR_IF:       return "BR_IF";
    case OP_RETURN:      return "RETURN";
    case OP_CALL:        return "CALL";
    case OP_DROP:        return "DROP";
    case OP_SELECT:      return "SELECT";
    case OP_LOCAL_GET:   return "LOCAL_GET";
    case OP_LOCAL_SET:   return "LOCAL_SET";
    case OP_LOCAL_TEE:   return "LOCAL_TEE";
    case OP_I32_LOAD:    return "I32_LOAD";
    case OP_I32_STORE:   return "I32_STORE";
    case OP_I32_CONST:   return "I32_CONST";
    case OP_I64_CONST:   return "I64_CONST";
    case OP_I32_EQZ:     return "I32_EQZ";
    case OP_I32_EQ:      return "I32_EQ";
    case OP_I32_NE:      return "I32_NE";
    case OP_I32_LT_S:    return "I32_LT_S";
    case OP_I32_LE_S:    return "I32_LE_S";
    case OP_I32_GT_S:    return "I32_GT_S";
    case OP_I32_GE_S:    return "I32_GE_S";
    case OP_I32_ADD:     return "I32_ADD";
    case OP_I32_SUB:     return "I32_SUB";
    case OP_I32_MUL:     return "I32_MUL";
    case OP_I32_DIV_S:   return "I32_DIV_S";
    case OP_I32_REM_S:   return "I32_REM_S";
    case OP_I32_AND:     return "I32_AND";
    case OP_I32_OR:      return "I32_OR";
    case OP_I32_XOR:     return "I32_XOR";
    case OP_SAFE_ASSERT: return "SAFE_ASSERT";
    case OP_SAFE_BOUNDS: return "SAFE_BOUNDS_CHECK";
    case OP_I32_SHL:     return "I32_SHL";
    case OP_I32_SHR_S:   return "I32_SHR_S";
    case OP_I32_ROTL:    return "I32_ROTL";
    case OP_I32_ROTR:    return "I32_ROTR";
    case OP_I64_EQZ:     return "I64_EQZ";
    case OP_I64_EQ:      return "I64_EQ";
    case OP_I64_NE:      return "I64_NE";
    case OP_I64_LT_S:    return "I64_LT_S";
    case OP_I64_LE_S:    return "I64_LE_S";
    case OP_I64_GT_S:    return "I64_GT_S";
    case OP_I64_GE_S:    return "I64_GE_S";
    case OP_I64_ADD:     return "I64_ADD";
    case OP_I64_SUB:     return "I64_SUB";
    case OP_I64_MUL:     return "I64_MUL";
    case OP_I64_DIV_S:   return "I64_DIV_S";
    case OP_I64_REM_S:   return "I64_REM_S";
    case OP_I64_AND:     return "I64_AND";
    case OP_I64_OR:      return "I64_OR";
    case OP_I64_XOR:     return "I64_XOR";
    case OP_I64_SHL:     return "I64_SHL";
    case OP_I64_SHR_S:   return "I64_SHR_S";
    case OP_F32_CONST:   return "F32_CONST";
    case OP_F32_ADD:     return "F32_ADD";
    case OP_F32_SUB:     return "F32_SUB";
    case OP_F32_MUL:     return "F32_MUL";
    case OP_F32_DIV:     return "F32_DIV";
    case OP_F32_EQ:      return "F32_EQ";
    case OP_F32_NE:      return "F32_NE";
    case OP_F32_LT:      return "F32_LT";
    case OP_F32_LE:      return "F32_LE";
    case OP_F32_GT:      return "F32_GT";
    case OP_F32_GE:      return "F32_GE";
    case OP_F32_ABS:     return "F32_ABS";
    case OP_F32_NEG:     return "F32_NEG";
    case OP_F32_SQRT:    return "F32_SQRT";
    case OP_F64_CONST:   return "F64_CONST";
    case OP_F64_ADD:     return "F64_ADD";
    case OP_F64_SUB:     return "F64_SUB";
    case OP_F64_MUL:     return "F64_MUL";
    case OP_F64_DIV:     return "F64_DIV";
    case OP_F64_EQ:      return "F64_EQ";
    case OP_F64_NE:      return "F64_NE";
    case OP_F64_LT:      return "F64_LT";
    case OP_F64_LE:      return "F64_LE";
    case OP_F64_GT:      return "F64_GT";
    case OP_F64_GE:      return "F64_GE";
    case OP_F64_ABS:     return "F64_ABS";
    case OP_F64_NEG:     return "F64_NEG";
    case OP_F64_SQRT:    return "F64_SQRT";
    case OP_I32_LOAD8_U: return "I32_LOAD8_U";
    case OP_I32_STORE8:  return "I32_STORE8";
    case OP_I32_WRAP_I64: return "I32_WRAP_I64";
    case OP_I64_EXTEND_I32_S: return "I64_EXTEND_I32_S";
    case OP_I32_TRUNC_F32_S:  return "I32_TRUNC_F32_S";
    case OP_I32_TRUNC_F64_S:  return "I32_TRUNC_F64_S";
    case OP_F32_CONVERT_I32_S: return "F32_CONVERT_I32_S";
    case OP_F64_CONVERT_I32_S: return "F64_CONVERT_I32_S";
    default:             return "???";
    }
}

/* 指令是否带有 u32 立即数 */
static int op_has_u32_imm(uint8_t op) {
    switch (op) {
    case OP_BLOCK: case OP_LOOP: case OP_BR: case OP_BR_IF:
    case OP_CALL: case OP_LOCAL_GET: case OP_LOCAL_SET: case OP_LOCAL_TEE:
    case OP_I32_CONST:
        return 1;
    default:
        return 0;
    }
}

/* 指令是否带有 i64 立即数 (1 字节 opcode + 8 字节立即数) */
static int op_has_i64_imm(uint8_t op) {
    return (op == OP_I64_CONST);
}

/* 指令是否带有 f32 立即数 */
static int op_has_f32_imm(uint8_t op) {
    return (op == OP_F32_CONST);
}

/* 指令是否带有 f64 立即数 */
static int op_has_f64_imm(uint8_t op) {
    return (op == OP_F64_CONST);
}

/* 指令是否带有 memory_arg (align + offset, 4 bytes) */
static int op_has_mem_arg(uint8_t op) {
    switch (op) {
    case OP_I32_LOAD: case OP_I32_STORE:
    case OP_I32_LOAD8_U: case OP_I32_STORE8:
        return 1;
    default:
        return 0;
    }
}

/* 指令是否带有 u32 立即数 × 2 (SAFE_BOUNDS) */
static int op_has_u32_imm2(uint8_t op) {
    return (op == OP_SAFE_BOUNDS);
}

/* ================================================================
   值类型名称
   ================================================================ */

static const char *value_type_name(uint8_t vt) {
    switch (vt) {
    case 0x7F: return "I32";
    case 0x7E: return "I64";
    case 0x7D: return "F32";
    case 0x7C: return "F64";
    default:   return "???";
    }
}

/* ================================================================
   读取函数（与 loader.c 一致）
   ================================================================ */

static inline uint8_t  r8(const uint8_t **p, uint32_t *len) {
    if (*len < 1) return 0;
    uint8_t v = (*p)[0]; *p += 1; *len -= 1; return v;
}

static inline uint32_t r32(const uint8_t **p, uint32_t *len) {
    if (*len < 4) return 0;
    uint32_t v = (uint32_t)(*p)[0] | ((uint32_t)(*p)[1]<<8) |
                 ((uint32_t)(*p)[2]<<16) | ((uint32_t)(*p)[3]<<24);
    *p += 4; *len -= 4; return v;
}

static inline uint16_t r16(const uint8_t **p, uint32_t *len) {
    if (*len < 2) return 0;
    uint16_t v = (uint16_t)(*p)[0] | ((uint16_t)(*p)[1]<<8);
    *p += 2; *len -= 2; return v;
}

/* ================================================================
   反汇编函数
   ================================================================ */

static void disasm_code(const uint8_t *body, uint32_t body_size, int indent) {
    const uint8_t *p = body;
    uint32_t remaining = body_size;
    
    while (remaining > 0) {
        uint32_t offset = (uint32_t)(p - body);
        uint8_t op = r8(&p, &remaining);
        
        printf("%*s  [%4u] ", indent, "", offset);
        
        /* 打印操作码十六进制 */
        printf("%02X ", op);
        
        if (op_has_u32_imm(op)) {
            uint32_t imm = r32(&p, &remaining);
            printf("          %-20s %u (0x%X)\n", opcode_name(op), imm, imm);
        } else if (op_has_i64_imm(op)) {
            uint32_t lo = r32(&p, &remaining);
            uint32_t hi = r32(&p, &remaining);
            uint64_t imm = (uint64_t)lo | ((uint64_t)hi << 32);
            printf("     %-20s %llu (0x%llX)\n", opcode_name(op),
                   (unsigned long long)imm, (unsigned long long)imm);
        } else if (op_has_f32_imm(op)) {
            uint32_t bits = r32(&p, &remaining);
            float f;
            memcpy(&f, &bits, sizeof(f));
            printf("     %-20s %g\n", opcode_name(op), f);
        } else if (op_has_f64_imm(op)) {
            uint32_t lo = r32(&p, &remaining);
            uint32_t hi = r32(&p, &remaining);
            uint64_t bits = (uint64_t)lo | ((uint64_t)hi << 32);
            double d;
            memcpy(&d, &bits, sizeof(d));
            printf("     %-20s %g\n", opcode_name(op), d);
        } else if (op_has_mem_arg(op)) {
            uint16_t align  = r16(&p, &remaining);
            uint16_t offset2 = r16(&p, &remaining);
            printf("     %-20s align=%u offset=%u\n", opcode_name(op), align, offset2);
        } else if (op_has_u32_imm2(op)) {
            uint32_t low  = r32(&p, &remaining);
            uint32_t high = r32(&p, &remaining);
            printf("     %-20s [%u, %u)\n", opcode_name(op), low, high);
        } else if (op == OP_SAFE_ASSERT) {
            uint8_t atype = r8(&p, &remaining);
            uint32_t alim = r32(&p, &remaining);
            printf("     %-20s type=%u limit=%u\n", opcode_name(op), atype, alim);
        } else {
            printf("          %-20s\n", opcode_name(op));
        }
    }
}

/* ================================================================
   主函数：解析并打印 .sasm 文件
   ================================================================ */

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "用法: %s <file.sasm>\n", argv[0]);
        return 1;
    }
    
    /* 读取文件 */
    FILE *fp = fopen(argv[1], "rb");
    if (!fp) {
        perror("打开文件失败");
        return 1;
    }
    
    fseek(fp, 0, SEEK_END);
    long fsize = ftell(fp);
    fseek(fp, 0, SEEK_SET);
    
    if (fsize < 8) {
        fprintf(stderr, "文件太小\n");
        fclose(fp);
        return 1;
    }
    
    uint8_t *buf = (uint8_t *)malloc(fsize);
    if (!buf) {
        fprintf(stderr, "内存分配失败\n");
        fclose(fp);
        return 1;
    }
    
    if (fread(buf, 1, fsize, fp) != (size_t)fsize) {
        perror("读取失败");
        free(buf);
        fclose(fp);
        return 1;
    }
    fclose(fp);
    
    /* ============================================================
       解析并打印
       ============================================================ */
    
    const uint8_t *p = buf;
    uint32_t len = (uint32_t)fsize;
    
    printf("╔══════════════════════════════════════════════════════╗\n");
    printf("║  SafeASM Dump: %-40s ║\n", argv[1]);
    printf("╚══════════════════════════════════════════════════════╝\n\n");
    
    /* --- 文件头 --- */
    uint32_t magic = r32(&p, &len);
    uint8_t  ver   = r8(&p, &len);
    uint8_t  flags = r8(&p, &len);
    
    printf("[Header]\n");
    printf("  Magic:   0x%08X (%c%c%c%c)\n", magic,
           (magic>>0)&0xFF, (magic>>8)&0xFF, (magic>>16)&0xFF, (magic>>24)&0xFF);
    printf("  Version: %u", ver);
    if (ver != 1) printf(" ⚠ expected 1");
    printf("\n");
    printf("  Flags:   0x%02X\n", flags);
    
    printf("\n[Sections]\n");
    
    int section_num = 0;
    while (len > 4) {
        uint8_t  sec_type = r8(&p, &len);
        uint32_t sec_len  = r32(&p, &len);
        r8(&p, &len);  /* reserved */
        r16(&p, &len); /* flags */
        
        if (sec_len > len) {
            printf("  ⚠ Section %d 长度 %u 超出剩余数据 %u\n",
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
        
        printf("  [%d] %-6s 长度=%-5u 偏移=%lu\n",
               section_num, sec_name, sec_len,
               (unsigned long)(p - buf - 8));
        
        const uint8_t *sec_data_start = p;  /* section 数据起始（用于跳过） */
        const uint8_t *sec_data = p;
        uint32_t sec_remaining = sec_len;
        
        /* --- TYPE Section --- */
        if (sec_type == 0) {
            int type_idx = 0;
            while (sec_remaining > 0 && type_idx < 8) {
                uint32_t pc = r32(&sec_data, &sec_remaining);
                printf("        类型[%d]: params=%u [", type_idx, pc);
                for (uint32_t i = 0; i < pc && sec_remaining > 0; i++) {
                    uint8_t vt = r8(&sec_data, &sec_remaining);
                    printf("%s%s", value_type_name(vt), i+1<pc?",":"");
                }
                printf("] → ");
                uint32_t rc = r32(&sec_data, &sec_remaining);
                printf("returns=%u [", rc);
                for (uint32_t i = 0; i < rc && sec_remaining > 0; i++) {
                    uint8_t vt = r8(&sec_data, &sec_remaining);
                    printf("%s%s", value_type_name(vt), i+1<rc?",":"");
                }
                printf("]\n");
                type_idx++;
            }
        }
        
        /* --- FUNC Section --- */
        else if (sec_type == 1) {
            int func_idx = 0;
            while (sec_remaining > 0 && func_idx < 8) {
                uint32_t ti = r32(&sec_data, &sec_remaining);
                uint32_t lc = r32(&sec_data, &sec_remaining);
                printf("        函数[%d]: type_idx=%u, locals=%u [", func_idx, ti, lc);
                for (uint32_t i = 0; i < lc && sec_remaining > 0; i++) {
                    uint8_t vt = r8(&sec_data, &sec_remaining);
                    printf("%s%s", value_type_name(vt), i+1<lc?",":"");
                }
                printf("]\n");
                func_idx++;
            }
        }
        
        /* --- MEM Section --- */
        else if (sec_type == 2) {
            uint32_t total = r32(&sec_data, &sec_remaining);
            uint32_t scnt  = r32(&sec_data, &sec_remaining);
            printf("        总内存: %u bytes\n", total);
            printf("        段数: %u\n", scnt);
            for (uint32_t i = 0; i < scnt && sec_remaining >= 9; i++) {
                uint8_t  st = r8(&sec_data, &sec_remaining);
                uint32_t so = r32(&sec_data, &sec_remaining);
                uint32_t ss = r32(&sec_data, &sec_remaining);
                const char *sn = "";
                switch (st) {
                case 0: sn = "IO_INPUT";  break;
                case 1: sn = "IO_OUTPUT"; break;
                case 2: sn = "GLOBAL";    break;
                case 3: sn = "FB_DATA";   break;
                case 4: sn = "STACK";     break;
                case 5: sn = "CONST";     break;
                default: sn = "?";        break;
                }
                printf("          %-12s offset=%u size=%u\n", sn, so, ss);
            }
        }
        
        /* --- IOMAP Section --- */
        else if (sec_type == 3) {
            uint32_t ecnt = r32(&sec_data, &sec_remaining);
            printf("        I/O 条目数: %u\n", ecnt);
            for (uint32_t i = 0; i < ecnt && sec_remaining >= 40; i++) {
                uint32_t no = r32(&sec_data, &sec_remaining); (void)no;
                uint32_t mo = r32(&sec_data, &sec_remaining);
                uint32_t ci = r32(&sec_data, &sec_remaining);
                uint8_t  di = r8(&sec_data, &sec_remaining);
                uint8_t  it = r8(&sec_data, &sec_remaining);
                uint32_t bw = r32(&sec_data, &sec_remaining);
                sec_data += 16; sec_remaining -= 16; /* float64 × 2 */
                int32_t  sl = (int32_t)r32(&sec_data, &sec_remaining);
                int32_t  sh = (int32_t)r32(&sec_data, &sec_remaining);
                printf("          ch=%u mem=%u dir=%s type=%s bits=%u [%d, %d]\n",
                       ci, mo, di?"OUT":"IN",
                       it==0?"AI":it==1?"AO":it==2?"DI":"DO",
                       bw, sl, sh);
            }
        }
        
        /* --- CODE Section --- */
        else if (sec_type == 4) {
            while (sec_remaining > 0) {
                uint32_t fi = r32(&sec_data, &sec_remaining);
                uint32_t bs = r32(&sec_data, &sec_remaining);
                printf("        函数[%u] 代码体大小=%u:\n", fi, bs);
                disasm_code(sec_data, bs > sec_remaining ? sec_remaining : bs, 10);
                sec_data += bs;
                sec_remaining -= (bs > sec_remaining) ? sec_remaining : bs;
            }
        }
        
        /* --- SAFE Section --- */
        else if (sec_type == 5) {
            uint8_t  sl = r8(&sec_data, &sec_remaining);
            uint32_t cl = r32(&sec_data, &sec_remaining);
            uint32_t sd = r32(&sec_data, &sec_remaining);
            printf("        安全等级: %s (SIL%d)\n", sl?"SIL3":"SIL2", sl?3:2);
            printf("        周期指令上限: %u\n", cl);
            printf("        栈深度上限: %u\n", sd);
            
            uint32_t lcnt = r32(&sec_data, &sec_remaining);
            printf("        循环上限条目: %u\n", lcnt);
            for (uint32_t i = 0; i < lcnt && sec_remaining >= 12; i++) {
                uint32_t fi = r32(&sec_data, &sec_remaining);
                uint32_t io = r32(&sec_data, &sec_remaining);
                uint32_t mi = r32(&sec_data, &sec_remaining);
                printf("          函数[%u] offset=%u max=%u\n", fi, io, mi);
            }
            
            uint32_t mcnt = r32(&sec_data, &sec_remaining);
            printf("        内存访问范围: %u\n", mcnt);
            for (uint32_t i = 0; i < mcnt && sec_remaining >= 8; i++) {
                uint32_t lo = r32(&sec_data, &sec_remaining);
                uint32_t hi = r32(&sec_data, &sec_remaining);
                printf("          [%u, %u)\n", lo, hi);
            }
        }
        
        /* --- 跳过未解析的 Section 数据 --- */
        else {
            /* 什么都不做 */
        }
        
        /* 跳过整个 section 数据到下一个 section */
        p = sec_data_start + sec_len;
        len = (uint32_t)((buf + fsize) - p);
        section_num++;
    }
    
    /* --- CRC32 --- */
    printf("\n[CRC32]\n");
    if (len >= 4) {
        uint32_t stored_crc = r32(&p, &len);
        /* 简单 CRC 校验（仅显示，不做校验） */
        printf("  存储值: 0x%08X\n", stored_crc);
        printf("  状态:   %s\n", stored_crc == 0 ? "(未计算)" : "(待验证)");
    }
    
    free(buf);
    return 0;
}
