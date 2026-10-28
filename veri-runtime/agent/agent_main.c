/*
 * veri-runtime/agent/agent_main.c
 * veristc-agent — target-side runtime agent (G0 scope)
 *
 * Responsibilities (plan/phase6-g0-technical-plan.md 6.5):
 *   1. load a .sasm image and run it scan cycle by scan cycle
 *   2. serve one full-image download over a byte stream (frames per
 *      spec/download-spec.md) and switch at the cycle boundary
 *   3. health-check the new image, roll back if it fails
 *   4. report status as JSONL frames on stdout
 *
 * Deliberately out of scope for G0:
 *   - master/standby transport (hotstandby/sync.c stays shared-memory)
 *   - incremental patch download (download.c keeps it unwired)
 *   - real signing (decision D5: HMAC with a statically configured key)
 *   - I/O hardware: like svm this runs the VM only; the closed-loop software
 *     I/O path belongs to sim
 *
 * Memory: everything static -- no malloc, no recursion.
 */

#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include "../core/vm.h"
#include "../hotstandby/hotstandby.h"
#include "../hotstandby/download_wire.h"
#include "../hotstandby/hmac_sha256.h"

#define AG_KEY_HEX_LEN     (SHA256_DIGEST_LEN * 2U)
#define AG_PUMP_LIMIT      65536U
#define AG_DEFAULT_CYCLES  10U
#define AG_DEFAULT_HEALTH  3U

/* Exit codes (spec/download-spec.md 6) */
#define AG_EX_OK        0
#define AG_EX_USAGE     2
#define AG_EX_IMAGE     3
#define AG_EX_KEY       4
#define AG_EX_CYCLE     5
#define AG_EX_STREAM    6

static VM         g_vm;
static DlReceiver g_rx;
static uint8_t    g_image[DL_MAX_IMAGE];
static uint8_t    g_key[SHA256_DIGEST_LEN];
static uint32_t   g_image_len;
static uint32_t   g_cycle_reported;
static const char *g_role = "active";
static uint32_t   g_node_id;
static int        g_pending_switch;
static int        g_service_open;
static volatile sig_atomic_t g_stop;

typedef struct {
    const char *image_path;
    const char *dl_path;        /* NULL = download service off */
    uint32_t    max_cycles;
    uint32_t    period_ms;
    uint32_t    download_at;    /* stage the preloaded stream at this cycle */
    uint32_t    health_cycles;
} Config;

static void on_signal(int signum)
{
    (void)signum;
    g_stop = 1;
}

static void usage(const char *prog)
{
    (void)fprintf(stderr,
        "usage: %s [options] <image.sasm>\n"
        "options:\n"
        "  --key HEX          32-byte HMAC-SHA256 key, %d hex chars\n"
        "                     (required with --download-from)\n"
        "  --download-from P  download frame stream: file, pipe or FIFO,\n"
        "                     \"-\" = stdin\n"
        "  --download-at N    stage the received image at cycle N (default 1)\n"
        "                     (the stream itself is read to EOF before the\n"
        "                      first cycle -- G0 has no retransmit or timeout)\n"
        "  --health-cycles N  cycles the new image must survive (default %u)\n"
        "  --cycles N         scan cycles, 0 = until SIGINT/SIGTERM (default %u)\n"
        "  --period-ms MS     scan period, 0 = free run (default 0)\n"
        "  --role NAME        role in status frames (default active)\n"
        "  --node-id N        node id in status frames (default 0)\n"
        "  -h, --help         show this help\n",
        prog, (int)AG_KEY_HEX_LEN,
        (unsigned)AG_DEFAULT_HEALTH, (unsigned)AG_DEFAULT_CYCLES);
}

/* Status frames all start with this prefix, so a consumer can tell them apart
 * from the program's own PRINT on the same stdout -- the same rule the watch
 * frames follow (spec/simulation-spec.md 4). */
static void status(const char *event, const char *extra)
{
    (void)printf("{\"frame\":\"status\",\"event\":\"%s\""
                 ",\"role\":\"%s\",\"node\":%u,\"version\":%u,\"cycle\":%u",
                 event, g_role, (unsigned)g_node_id,
                 (unsigned)dl_active_version(), (unsigned)g_cycle_reported);
    if (extra != NULL) {
        (void)printf(",%s", extra);
    }
    (void)printf("}\n");
    (void)fflush(stdout);
}

static int parse_u32(const char *text, uint32_t *value)
{
    char *end = NULL;
    unsigned long v;

    if ((text == NULL) || (*text == '\0')) { return -1; }
    v = strtoul(text, &end, 10);
    if ((end == NULL) || (*end != '\0') || (v > 0xFFFFFFFFUL)) { return -1; }
    *value = (uint32_t)v;
    return 0;
}

static int hex_nibble(char c, uint8_t *out)
{
    if ((c >= '0') && (c <= '9')) { *out = (uint8_t)(c - '0'); return 0; }
    if ((c >= 'a') && (c <= 'f')) { *out = (uint8_t)(c - (uint8_t)'a' + 10U); return 0; }
    if ((c >= 'A') && (c <= 'F')) { *out = (uint8_t)(c - (uint8_t)'A' + 10U); return 0; }
    return -1;
}

static int parse_key(const char *text, uint8_t *key)
{
    size_t n;
    size_t i;
    uint8_t hi;
    uint8_t lo;

    if (text == NULL) { return -1; }
    n = strlen(text);
    if (n != (size_t)AG_KEY_HEX_LEN) { return -1; }
    for (i = 0U; i < n; i += 2U) {
        if ((hex_nibble(text[i], &hi) != 0) ||
            (hex_nibble(text[i + 1U], &lo) != 0)) {
            return -1;
        }
        key[i / 2U] = (uint8_t)(((uint32_t)hi << 4U) | (uint32_t)lo);
    }
    return 0;
}

/* The role goes into a JSON string, so it must be a plain token. */
static int is_token(const char *s)
{
    size_t n = strlen(s);
    size_t i;

    if ((n == 0U) || (n > 32U)) { return -1; }
    for (i = 0U; i < n; i++) {
        char c = s[i];
        int ok = ((c >= 'a') && (c <= 'z')) || ((c >= 'A') && (c <= 'Z')) ||
                 ((c >= '0') && (c <= '9')) || (c == '.') || (c == '_') ||
                 (c == '-');
        if (ok == 0) { return -1; }
    }
    return 0;
}

static int load_file(const char *path, uint8_t *buf, uint32_t cap, uint32_t *len)
{
    FILE *f = fopen(path, "rb");
    size_t got;

    *len = 0U;
    if (f == NULL) { return -1; }
    got = fread(buf, 1U, cap, f);
    (void)fclose(f);
    if ((got == 0U) || ((uint32_t)got >= cap)) { return -1; }
    *len = (uint32_t)got;
    return 0;
}

/* ---------------- download stream backend ----------------
 * G0 stops at the DlStream abstraction (plan 6.2): the agent reads a file,
 * pipe or FIFO to EOF and feeds those bytes to the receiver. No socket calls,
 * no retransmit, no timeouts -- real UDS is G4. */

typedef struct {
    const uint8_t *data;
    uint32_t len;
    uint32_t pos;
    int      exhausted;
} StreamIn;

static StreamIn g_in;

static int stream_feed(void *ctx, uint8_t *buf, uint32_t cap, uint32_t *got)
{
    StreamIn *in = (StreamIn *)ctx;
    uint32_t n = in->len - in->pos;

    if (n > cap) { n = cap; }
    *got = n;
    if (n == 0U) {
        in->exhausted = 1;
        return 0;                   /* "no data yet" -- the pump decides what EOF means */
    }
    (void)memcpy(buf, in->data + in->pos, n);
    in->pos += n;
    return 0;
}

static int stream_drain(void *ctx, const uint8_t *buf, uint32_t len)
{
    (void)ctx;
    (void)buf;
    (void)len;
    return 0;                       /* the agent sends no frames in G0 */
}

static int stream_preload(const char *path)
{
    int fd;
    uint32_t total = 0U;
    ssize_t r;

    if (strcmp(path, "-") == 0) {
        fd = STDIN_FILENO;
    } else {
        fd = open(path, O_RDONLY);
        if (fd < 0) { return -1; }
    }
    for (;;) {
        r = read(fd, g_image + total, sizeof(g_image) - (size_t)total);
        if (r < 0) {
            if (errno == EINTR) { continue; }
            return -1;
        }
        if (r == 0) { break; }
        total += (uint32_t)r;
        if (total >= (uint32_t)sizeof(g_image)) { return -1; }
    }
    if (fd != STDIN_FILENO) { (void)close(fd); }

    g_in.data = g_image;            /* reuse: the initial image is already in a slot */
    g_in.len = total;
    g_in.pos = 0U;
    g_in.exhausted = 0;
    return (total > 0U) ? 0 : -1;
}

static void download_reject(const char *stage, int rc)
{
    char extra[96];

    (void)snprintf(extra, sizeof(extra),
                   "\"stage\":\"%s\",\"rc\":%d,\"loader\":%d,\"progress\":%u",
                   stage, rc, dl_last_error(), (unsigned)dl_rx_progress(&g_rx));
    status("download_rejected", extra);
}

/* Drain the stream to a complete image and hand it to the download manager.
 * Any refusal leaves the running image untouched. */
static void serve_download(void)
{
    DlStream io;
    const uint8_t *img = NULL;
    uint32_t len = 0U;
    uint32_t pumps = 0U;
    bool complete = false;
    int rc;

    io.feed = stream_feed;
    io.drain = stream_drain;
    io.ctx = &g_in;

    dl_rx_reset(&g_rx);
    status("download_begin", NULL);

    while (pumps < AG_PUMP_LIMIT) {
        rc = dl_rx_pump(&g_rx, &io, g_key, &complete);
        pumps++;
        if (rc == (int)DL_E_TRUNC) {
            if (g_in.exhausted != 0) { break; }
            continue;
        }
        if (rc < 0) {
            download_reject("frame", rc);
            return;
        }
        if (complete) { break; }
    }

    rc = dl_rx_finish(&g_rx, &img, &len);
    if (rc != (int)DL_OK) {
        download_reject("reassemble", rc);
        return;
    }

    rc = dl_stage_image(img, len);
    if (rc != DL_RC_OK) {
        download_reject("stage", rc);
        return;
    }

    {
        char extra[64];
        (void)snprintf(extra, sizeof(extra), "\"staged\":%u,\"bytes\":%u",
                       (unsigned)dl_pending_version(), (unsigned)len);
        status("download_staged", extra);
    }
    g_pending_switch = 1;
}

/* ---------------- option parsing ---------------- */

static int next_value(int argc, char **argv, int *i, const char **out)
{
    if (*i + 1 >= argc) {
        (void)fprintf(stderr, "error: %s needs a value\n", argv[*i]);
        return -1;
    }
    *i = *i + 1;
    *out = argv[*i];
    return 0;
}

static int parse_args(int argc, char **argv, Config *cfg)
{
    int have_key = 0;
    const char *v = NULL;

    cfg->image_path = NULL;
    cfg->dl_path = NULL;
    cfg->max_cycles = AG_DEFAULT_CYCLES;
    cfg->period_ms = 0U;
    cfg->download_at = 1U;
    cfg->health_cycles = AG_DEFAULT_HEALTH;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-h") == 0) {
            usage(argv[0]);
            return 1;
        } else if (strcmp(argv[i], "--key") == 0) {
            if (next_value(argc, argv, &i, &v) != 0) { return -1; }
            if (parse_key(v, g_key) != 0) {
                (void)fprintf(stderr, "error: --key must be %u hex chars\n",
                              (unsigned)AG_KEY_HEX_LEN);
                return -2;
            }
            have_key = 1;
        } else if (strcmp(argv[i], "--download-from") == 0) {
            if (next_value(argc, argv, &i, &v) != 0) { return -1; }
            cfg->dl_path = v;
        } else if (strcmp(argv[i], "--role") == 0) {
            if (next_value(argc, argv, &i, &v) != 0) { return -1; }
            if (is_token(v) != 0) {
                (void)fprintf(stderr, "error: --role must be a plain token\n");
                return -2;
            }
            g_role = v;
        } else if (strcmp(argv[i], "--node-id") == 0) {
            if (next_value(argc, argv, &i, &v) != 0) { return -1; }
            if (parse_u32(v, &g_node_id) != 0) { return -1; }
        } else if (strcmp(argv[i], "--cycles") == 0) {
            if (next_value(argc, argv, &i, &v) != 0) { return -1; }
            if (parse_u32(v, &cfg->max_cycles) != 0) { return -1; }
        } else if (strcmp(argv[i], "--period-ms") == 0) {
            if (next_value(argc, argv, &i, &v) != 0) { return -1; }
            if (parse_u32(v, &cfg->period_ms) != 0) { return -1; }
        } else if (strcmp(argv[i], "--download-at") == 0) {
            if (next_value(argc, argv, &i, &v) != 0) { return -1; }
            if (parse_u32(v, &cfg->download_at) != 0) { return -1; }
        } else if (strcmp(argv[i], "--health-cycles") == 0) {
            if (next_value(argc, argv, &i, &v) != 0) { return -1; }
            if (parse_u32(v, &cfg->health_cycles) != 0) { return -1; }
        } else if (argv[i][0] == '-') {
            usage(argv[0]);
            return -1;
        } else if (cfg->image_path == NULL) {
            cfg->image_path = argv[i];
        } else {
            usage(argv[0]);
            return -1;
        }
    }

    if (cfg->image_path == NULL) {
        usage(argv[0]);
        return -1;
    }
    if ((cfg->dl_path != NULL) && (have_key == 0)) {
        (void)fprintf(stderr, "error: --download-from requires --key\n");
        return -2;
    }
    return 0;
}

/* ---------------- main ---------------- */

int main(int argc, char **argv)
{
    Config cfg;
    uint32_t cycle;
    uint32_t health_left = 0U;
    uint32_t ran = 0U;
    uint32_t switches = 0U;
    uint32_t rollbacks = 0U;
    uint32_t from_version;
    int failed = 0;
    char extra[128];
    int pr;
    int rc;

    (void)setvbuf(stdout, NULL, _IONBF, 0);

    pr = parse_args(argc, argv, &cfg);
    if (pr == 1) { return AG_EX_OK; }
    if (pr == -2) { return AG_EX_KEY; }
    if (pr != 0) { return AG_EX_USAGE; }

    /* Version 0 goes through the download manager, not straight into the VM:
     * that is what gives a later rollback somewhere to land. */
    if (load_file(cfg.image_path, g_image, (uint32_t)sizeof(g_image),
                  &g_image_len) != 0) {
        (void)fprintf(stderr, "error: cannot read image %s\n", cfg.image_path);
        return AG_EX_IMAGE;
    }
    rc = dl_manager_load_image(g_image, g_image_len);
    if (rc != DL_RC_OK) {
        (void)fprintf(stderr, "error: image rejected (rc=%d, loader=%d)\n",
                      rc, dl_last_error());
        return AG_EX_IMAGE;
    }
    if (vm_init(&g_vm, dl_get_active_module(), MEMORY_SIZE) != 0) {
        (void)fprintf(stderr, "error: vm_init failed\n");
        return AG_EX_IMAGE;
    }

    if (cfg.dl_path != NULL) {
        if (stream_preload(cfg.dl_path) != 0) {
            (void)fprintf(stderr, "error: cannot read stream %s\n", cfg.dl_path);
            return AG_EX_STREAM;
        }
        g_service_open = 1;
    }

    (void)signal(SIGINT, on_signal);
    (void)signal(SIGTERM, on_signal);

    (void)snprintf(extra, sizeof(extra),
                   "\"image\":\"%s\",\"download\":%s,\"planned\":%u",
                   cfg.image_path, (cfg.dl_path != NULL) ? "true" : "false",
                   (unsigned)cfg.max_cycles);
    status("start", extra);

    for (cycle = 1U;
         (cfg.max_cycles == 0U) || (cycle <= cfg.max_cycles);
         cycle++) {
        if (g_stop != 0) { break; }

        /* The switch lands here: vm_run has returned, the next scan has not
         * started. That is the whole content of "atomic at the cycle
         * boundary" -- nothing else may rebind a running VM. */
        if (g_pending_switch != 0) {
            g_pending_switch = 0;
            from_version = dl_active_version();
            if (dl_apply_switch(&g_vm) == DL_RC_OK) {
                (void)snprintf(extra, sizeof(extra), "\"from\":%u,\"to\":%u",
                               (unsigned)from_version,
                               (unsigned)dl_active_version());
                status("switch", extra);
                switches++;
                health_left = cfg.health_cycles;
            } else {
                status("switch_failed", NULL);
            }
        }

        g_cycle_reported = cycle;
        rc = vm_run(&g_vm);
        ran++;
        if (rc != 0) {
            if (health_left > 0U) {
                if (dl_rollback(&g_vm) != NULL) {
                    (void)snprintf(extra, sizeof(extra),
                                   "\"rc\":%d,\"rolled_back_to\":%u",
                                   rc, (unsigned)dl_active_version());
                    status("rollback", extra);
                    rollbacks++;
                    health_left = 0U;
                } else {
                    (void)snprintf(extra, sizeof(extra),
                                   "\"rc\":%d,\"rollback_failed\":true", rc);
                    status("cycle_error", extra);
                    failed = 1;
                    break;
                }
            } else {
                (void)snprintf(extra, sizeof(extra), "\"rc\":%d", rc);
                status("cycle_error", extra);
                failed = 1;
                break;
            }
        }

        if (health_left > 0U) {
            health_left--;
            if (health_left == 0U) { status("health_ok", NULL); }
        }

        if ((g_service_open != 0) && (cycle >= cfg.download_at)) {
            g_service_open = 0;
            serve_download();
        }

        if (cfg.period_ms > 0U) {
            struct timespec ts;
            ts.tv_sec = (time_t)(cfg.period_ms / 1000U);
            ts.tv_nsec = (long)(cfg.period_ms % 1000U) * 1000000L;
            (void)nanosleep(&ts, NULL);
        }
    }

    (void)snprintf(extra, sizeof(extra),
                   "\"ran\":%u,\"switches\":%u,\"rollbacks\":%u",
                   (unsigned)ran, (unsigned)switches, (unsigned)rollbacks);
    status("end", extra);

    return (failed != 0) ? AG_EX_CYCLE : AG_EX_OK;
}
