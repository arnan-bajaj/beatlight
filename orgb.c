// orgb.c — minimal OpenRGB SDK client. See orgb.h.
//
// Protocol: https://gitlab.com/CalcProgrammer1/OpenRGB/-/blob/master/Documentation/OpenRGBSDK.md
// We negotiate protocol version 3 (OpenRGB 0.7+) at most, which keeps the controller
// data format simple, and use index-based device IDs (protocol < 6).
//
// One worker thread owns the socket. It connects (and reconnects), switches devices
// to Direct mode, sends the latest color whenever one is pending, and on disable
// restores each device's original mode and colors before closing.

#include "orgb.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

#ifndef MSG_NOSIGNAL
#define MSG_NOSIGNAL 0          // macOS: SO_NOSIGPIPE is set on the socket instead
#endif

enum {
    PKT_REQUEST_CONTROLLER_COUNT = 0,
    PKT_REQUEST_CONTROLLER_DATA  = 1,
    PKT_REQUEST_PROTOCOL_VERSION = 40,
    PKT_SET_CLIENT_NAME          = 50,
    PKT_DEVICE_LIST_UPDATED      = 100,
    PKT_UPDATELEDS               = 1050,
    PKT_SETCUSTOMMODE            = 1100,
    PKT_UPDATEMODE               = 1101,
};

#define CLIENT_PROTOCOL  3u
#define MAX_DEVICES      64
#define NAME_LEN         96
#define LOC_LEN          256
#define KEY_LEN          (NAME_LEN + LOC_LEN + 2)
#define RETRY_MS         3000
#define IO_TIMEOUT_S     2
#define MAX_PACKET       (16u * 1024u * 1024u)

typedef struct {
    uint32_t index;              // controller index on the server
    char     name[NAME_LEN];
    char     key[KEY_LEN];       // name + location: identifies a device across reconnects
    uint16_t num_colors;
} Device;

typedef struct {                 // how a device looked before beatlight took it over
    char     key[KEY_LEN];
    uint32_t version;            // protocol version the mode bytes are encoded in
    int32_t  active_mode;
    uint8_t *mode_bytes;         // raw Mode Data block of the active mode
    uint32_t mode_len;
    uint8_t *colors;             // its LED colors, 4 bytes each
    uint16_t num_colors;
} Saved;

// ---- worker-thread-only state ----
static int      g_fd = -1;
static uint32_t g_version;
static Device   g_dev[MAX_DEVICES];
static int      g_ndev;
static Saved    g_saved[MAX_DEVICES];
static int      g_nsaved;
static uint64_t g_next_try;

// ---- shared state ----
static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t  g_cv = PTHREAD_COND_INITIALIZER;
static bool      g_started;                 // caller thread only
static bool      g_wanted;                  // g_mu
static uint16_t  g_port = ORGB_DEFAULT_PORT; // g_mu
static unsigned  g_disable_req, g_disable_done;   // g_mu
static char      g_names[MAX_DEVICES][NAME_LEN];  // g_mu
static int       g_nnames;                  // g_mu
static int       g_wake[2] = { -1, -1 };    // self-pipe that wakes the worker
static atomic_uint g_pending;               // 0x01RRGGBB when a color is waiting, 0 if none
static atomic_bool g_connected;

static uint64_t now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000u + (uint64_t)ts.tv_nsec / 1000000u;
}

static void wake_worker(void) {
    if (g_wake[1] >= 0) { char c = 1; ssize_t n = write(g_wake[1], &c, 1); (void)n; }
}

// ---------------------------------------------------------------- socket I/O

static bool write_all(int fd, const void *buf, size_t len) {
    const uint8_t *p = buf;
    while (len) {
        ssize_t n = send(fd, p, len, MSG_NOSIGNAL);
        if (n < 0) { if (errno == EINTR) continue; return false; }
        p += n;
        len -= (size_t)n;
    }
    return true;
}

static bool read_all(int fd, void *buf, size_t len) {
    uint8_t *p = buf;
    while (len) {
        ssize_t n = recv(fd, p, len, 0);
        if (n == 0) return false;
        if (n < 0) { if (errno == EINTR) continue; return false; }
        p += n;
        len -= (size_t)n;
    }
    return true;
}

static bool send_packet(int fd, uint32_t dev, uint32_t id, const void *data, uint32_t size) {
    uint8_t h[16];
    memcpy(h, "ORGB", 4);
    memcpy(h + 4, &dev, 4);
    memcpy(h + 8, &id, 4);
    memcpy(h + 12, &size, 4);
    if (!write_all(fd, h, sizeof h)) return false;
    return size == 0 || write_all(fd, data, size);
}

// Reads one packet. On success *data is malloc'd (or NULL if empty); caller frees.
static bool read_packet(int fd, uint32_t *id, uint8_t **data, uint32_t *size) {
    uint8_t h[16];
    *data = NULL;
    *size = 0;
    if (!read_all(fd, h, sizeof h) || memcmp(h, "ORGB", 4) != 0) return false;
    memcpy(id, h + 8, 4);
    memcpy(size, h + 12, 4);
    if (*size > MAX_PACKET) return false;
    if (*size == 0) return true;
    *data = malloc(*size);
    if (!*data) return false;
    if (!read_all(fd, *data, *size)) { free(*data); *data = NULL; return false; }
    return true;
}

// Waits for the reply with packet id `want`, skipping anything else the server sends.
static uint8_t *await_reply(int fd, uint32_t want, uint32_t *size) {
    for (int i = 0; i < 64; i++) {
        uint32_t id;
        uint8_t *data;
        if (!read_packet(fd, &id, &data, size)) return NULL;
        if (id == want) {
            if (!data) data = malloc(1);   // non-NULL for "got an empty reply"
            return data;
        }
        free(data);
    }
    return NULL;
}

static int connect_local(uint16_t port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    int one = 1;
#ifdef SO_NOSIGPIPE
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
#endif
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);

    struct sockaddr_in a;
    memset(&a, 0, sizeof a);
#ifdef __APPLE__
    a.sin_len = sizeof a;
#endif
    a.sin_family = AF_INET;
    a.sin_port = htons(port);
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);

    int flags = fcntl(fd, F_GETFL);
    fcntl(fd, F_SETFL, flags | O_NONBLOCK);
    int rc = connect(fd, (struct sockaddr *)&a, sizeof a);
    if (rc < 0 && errno == EINPROGRESS) {
        struct pollfd p = { .fd = fd, .events = POLLOUT };
        rc = -1;
        if (poll(&p, 1, 500) == 1) {
            int err = 0;
            socklen_t len = sizeof err;
            if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len) == 0 && err == 0) rc = 0;
        }
    }
    if (rc < 0) { close(fd); return -1; }
    fcntl(fd, F_SETFL, flags);

    struct timeval tv = { .tv_sec = IO_TIMEOUT_S, .tv_usec = 0 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
    return fd;
}

// ---------------------------------------------------------------- controller data parsing

typedef struct { const uint8_t *p, *end; bool ok; } Reader;

static bool need(Reader *r, size_t n) {
    if (!r->ok || (size_t)(r->end - r->p) < n) { r->ok = false; return false; }
    return true;
}
static uint16_t rd16(Reader *r) { uint16_t v = 0; if (need(r, 2)) { memcpy(&v, r->p, 2); r->p += 2; } return v; }
static uint32_t rd32(Reader *r) { uint32_t v = 0; if (need(r, 4)) { memcpy(&v, r->p, 4); r->p += 4; } return v; }
static void skip(Reader *r, size_t n) { if (need(r, n)) r->p += n; }

// Reads a length-prefixed string into out (may be NULL to skip).
static void rd_str(Reader *r, char *out, size_t cap) {
    uint16_t len = rd16(r);
    if (!need(r, len)) return;
    if (out && cap) {
        size_t n = strnlen((const char *)r->p, len);
        if (n >= cap) n = cap - 1;
        memcpy(out, r->p, n);
        out[n] = '\0';
    }
    r->p += len;
}

typedef struct {
    char name[NAME_LEN];
    char location[LOC_LEN];
    int32_t active_mode;
    const uint8_t *mode_bytes;   // points into the packet
    uint32_t mode_len;
    const uint8_t *colors;       // points into the packet
    uint16_t num_colors;
} ControllerInfo;

// Parses a REQUEST_CONTROLLER_DATA reply in protocol version `ver` (1..3).
static bool parse_controller(const uint8_t *data, uint32_t size, uint32_t ver, ControllerInfo *out) {
    Reader r = { data, data + size, true };
    memset(out, 0, sizeof *out);
    rd32(&r);                                  // data_size
    rd32(&r);                                  // device type
    rd_str(&r, out->name, sizeof out->name);
    if (ver >= 1) rd_str(&r, NULL, 0);         // vendor
    rd_str(&r, NULL, 0);                       // description
    rd_str(&r, NULL, 0);                       // version
    rd_str(&r, NULL, 0);                       // serial
    rd_str(&r, out->location, sizeof out->location);

    uint16_t num_modes = rd16(&r);
    out->active_mode = (int32_t)rd32(&r);
    for (uint16_t m = 0; m < num_modes && r.ok; m++) {
        const uint8_t *start = r.p;
        rd_str(&r, NULL, 0);                   // mode name
        skip(&r, 4 * 4);                       // value, flags, speed_min, speed_max
        if (ver >= 3) skip(&r, 4 * 2);         // brightness_min, brightness_max
        skip(&r, 4 * 3);                       // colors_min, colors_max, speed
        if (ver >= 3) skip(&r, 4);             // brightness
        skip(&r, 4 * 2);                       // direction, color_mode
        uint16_t n = rd16(&r);
        skip(&r, 4u * n);                      // mode colors
        if (r.ok && (int32_t)m == out->active_mode) {
            out->mode_bytes = start;
            out->mode_len = (uint32_t)(r.p - start);
        }
    }

    uint16_t num_zones = rd16(&r);
    for (uint16_t z = 0; z < num_zones && r.ok; z++) {
        rd_str(&r, NULL, 0);                   // zone name
        skip(&r, 4 * 4);                       // type, leds_min, leds_max, leds_count
        uint16_t matrix_len = rd16(&r);
        skip(&r, matrix_len);                  // matrix map (height, width, data)
    }

    uint16_t num_leds = rd16(&r);
    for (uint16_t i = 0; i < num_leds && r.ok; i++) {
        rd_str(&r, NULL, 0);                   // LED name
        skip(&r, 4);                           // LED value
    }

    out->num_colors = rd16(&r);
    out->colors = r.p;
    skip(&r, 4u * out->num_colors);
    return r.ok;
}

// ---------------------------------------------------------------- devices

static Saved *find_saved(const char *key) {
    for (int i = 0; i < g_nsaved; i++)
        if (strcmp(g_saved[i].key, key) == 0) return &g_saved[i];
    return NULL;
}

static void clear_saved(void) {
    for (int i = 0; i < g_nsaved; i++) {
        free(g_saved[i].mode_bytes);
        free(g_saved[i].colors);
    }
    memset(g_saved, 0, sizeof g_saved);
    g_nsaved = 0;
}

// Remembers a device's original state the first time we see it this session.
static void remember(const char *key, const ControllerInfo *ci) {
    if (find_saved(key) || g_nsaved >= MAX_DEVICES) return;
    Saved *s = &g_saved[g_nsaved];
    memset(s, 0, sizeof *s);
    snprintf(s->key, sizeof s->key, "%s", key);
    s->version = g_version;
    s->active_mode = ci->active_mode;
    if (ci->mode_bytes && ci->mode_len) {
        s->mode_bytes = malloc(ci->mode_len);
        if (s->mode_bytes) { memcpy(s->mode_bytes, ci->mode_bytes, ci->mode_len); s->mode_len = ci->mode_len; }
    }
    if (ci->num_colors) {
        s->colors = malloc(4u * ci->num_colors);
        if (s->colors) { memcpy(s->colors, ci->colors, 4u * ci->num_colors); s->num_colors = ci->num_colors; }
    }
    g_nsaved++;
}

static void publish_names(void) {
    pthread_mutex_lock(&g_mu);
    g_nnames = g_ndev;
    for (int i = 0; i < g_ndev; i++) snprintf(g_names[i], NAME_LEN, "%s", g_dev[i].name);
    pthread_mutex_unlock(&g_mu);
}

static bool send_leds(int fd, const Device *d, const uint8_t *colors) {
    uint32_t size = 4 + 2 + 4u * d->num_colors;
    uint8_t *buf = malloc(size);
    if (!buf) return false;
    memcpy(buf, &size, 4);
    memcpy(buf + 4, &d->num_colors, 2);
    memcpy(buf + 6, colors, 4u * d->num_colors);
    bool ok = send_packet(fd, d->index, PKT_UPDATELEDS, buf, size);
    free(buf);
    return ok;
}

static bool send_mode(int fd, const Device *d, const Saved *s) {
    uint32_t size = 4 + 4 + s->mode_len;
    uint8_t *buf = malloc(size);
    if (!buf) return false;
    memcpy(buf, &size, 4);
    memcpy(buf + 4, &s->active_mode, 4);
    memcpy(buf + 8, s->mode_bytes, s->mode_len);
    bool ok = send_packet(fd, d->index, PKT_UPDATEMODE, buf, size);
    free(buf);
    return ok;
}

static void close_conn(void) {
    if (g_fd >= 0) close(g_fd);
    g_fd = -1;
    g_ndev = 0;
    atomic_store(&g_connected, false);
    publish_names();
}

// Puts each device back the way we found it: its colors first (while still in
// Direct mode), then its original mode.
static void restore_devices(void) {
    for (int i = 0; i < g_ndev && g_fd >= 0; i++) {
        const Device *d = &g_dev[i];
        const Saved *s = find_saved(d->key);
        if (!s || s->version != g_version) continue;
        if (s->colors && s->num_colors == d->num_colors) send_leds(g_fd, d, s->colors);
        if (s->mode_bytes) send_mode(g_fd, d, s);
    }
}

static bool handshake(int fd) {
    uint32_t want = CLIENT_PROTOCOL, size;
    if (!send_packet(fd, 0, PKT_REQUEST_PROTOCOL_VERSION, &want, 4)) return false;
    uint8_t *v = await_reply(fd, PKT_REQUEST_PROTOCOL_VERSION, &size);
    if (!v) return false;   // no reply: protocol 0 server (OpenRGB < 0.5), unsupported
    uint32_t server = 0;
    if (size >= 4) memcpy(&server, v, 4);
    free(v);
    if (server < 1) return false;
    g_version = server < CLIENT_PROTOCOL ? server : CLIENT_PROTOCOL;

    const char *client = "beatlight";
    if (!send_packet(fd, 0, PKT_SET_CLIENT_NAME, client, (uint32_t)strlen(client) + 1)) return false;

    if (!send_packet(fd, 0, PKT_REQUEST_CONTROLLER_COUNT, NULL, 0)) return false;
    uint8_t *c = await_reply(fd, PKT_REQUEST_CONTROLLER_COUNT, &size);
    if (!c) return false;
    uint32_t count = 0;
    if (size >= 4) memcpy(&count, c, 4);
    free(c);

    g_ndev = 0;
    for (uint32_t i = 0; i < count && g_ndev < MAX_DEVICES; i++) {
        if (!send_packet(fd, i, PKT_REQUEST_CONTROLLER_DATA, &g_version, 4)) return false;
        uint8_t *data = await_reply(fd, PKT_REQUEST_CONTROLLER_DATA, &size);
        if (!data) return false;
        ControllerInfo ci;
        bool ok = parse_controller(data, size, g_version, &ci);
        if (ok && ci.num_colors > 0) {
            Device *d = &g_dev[g_ndev++];
            d->index = i;
            d->num_colors = ci.num_colors;
            snprintf(d->name, sizeof d->name, "%s", ci.name);
            snprintf(d->key, sizeof d->key, "%s|%s", ci.name, ci.location);
            remember(d->key, &ci);
        }
        free(data);
    }
    return true;
}

static void try_connect(uint16_t port) {
    int fd = connect_local(port);
    if (fd < 0) return;
    if (!handshake(fd)) { close(fd); g_ndev = 0; return; }
    g_fd = fd;
    for (int i = 0; i < g_ndev; i++) send_packet(fd, g_dev[i].index, PKT_SETCUSTOMMODE, NULL, 0);
    atomic_store(&g_connected, true);
    publish_names();
}

static void send_color(uint32_t rgb) {
    // OpenRGB's RGBColor is 0x00BBGGRR, little-endian on the wire: bytes R, G, B, 0.
    uint8_t px[4] = { (uint8_t)(rgb >> 16), (uint8_t)(rgb >> 8), (uint8_t)rgb, 0 };
    for (int i = 0; i < g_ndev; i++) {
        const Device *d = &g_dev[i];
        uint8_t *colors = malloc(4u * d->num_colors);
        if (!colors) return;
        for (uint16_t k = 0; k < d->num_colors; k++) memcpy(colors + 4u * k, px, 4);
        bool ok = send_leds(g_fd, d, colors);
        free(colors);
        if (!ok) { close_conn(); g_next_try = now_ms() + RETRY_MS; return; }
    }
}

// Something arrived from the server: a device-list change (re-enumerate) or a hang-up.
static void handle_server_data(uint16_t port) {
    uint32_t id, size;
    uint8_t *data;
    if (!read_packet(g_fd, &id, &data, &size)) {
        close_conn();
        g_next_try = now_ms() + RETRY_MS;
        return;
    }
    free(data);
    if (id == PKT_DEVICE_LIST_UPDATED) {   // reconnect to pick up added or removed devices
        close_conn();
        try_connect(port);
        if (g_fd < 0) g_next_try = now_ms() + RETRY_MS;
    }
}

static void *worker(void *arg) {
    (void)arg;
    for (;;) {
        pthread_mutex_lock(&g_mu);
        bool wanted = g_wanted;
        unsigned req = g_disable_req;
        uint16_t port = g_port;
        pthread_mutex_unlock(&g_mu);

        if (!wanted) {
            if (g_fd >= 0) restore_devices();
            close_conn();
            clear_saved();
            atomic_store(&g_pending, 0);
            pthread_mutex_lock(&g_mu);
            g_disable_done = req;
            pthread_cond_broadcast(&g_cv);
            while (!g_wanted) pthread_cond_wait(&g_cv, &g_mu);
            pthread_mutex_unlock(&g_mu);
            g_next_try = 0;
            continue;
        }

        if (g_fd < 0 && now_ms() >= g_next_try) {
            try_connect(port);
            if (g_fd < 0) g_next_try = now_ms() + RETRY_MS;
        }

        struct pollfd p[2] = { { .fd = g_wake[0], .events = POLLIN }, { .fd = g_fd, .events = POLLIN } };
        int np = g_fd >= 0 ? 2 : 1;
        int timeout = -1;
        if (g_fd < 0) {
            uint64_t now = now_ms();
            timeout = g_next_try > now ? (int)(g_next_try - now) : 0;
        }
        poll(p, (nfds_t)np, timeout);
        if (p[0].revents & POLLIN) {
            char buf[64];
            while (read(g_wake[0], buf, sizeof buf) > 0) {}
        }
        if (np == 2 && (p[1].revents & (POLLIN | POLLHUP | POLLERR))) handle_server_data(port);

        uint32_t c = atomic_exchange(&g_pending, 0);
        if (c && g_fd >= 0) send_color(c & 0xFFFFFFu);
    }
    return NULL;
}

// ---------------------------------------------------------------- public API

void ORGBSetEnabled(bool enabled, uint16_t port) {
    if (enabled) {
        if (!g_started) {
            if (pipe(g_wake) != 0) return;
            fcntl(g_wake[0], F_SETFL, O_NONBLOCK);
            fcntl(g_wake[1], F_SETFL, O_NONBLOCK);
            pthread_t t;
            if (pthread_create(&t, NULL, worker, NULL) != 0) return;
            pthread_detach(t);
            g_started = true;
        }
        pthread_mutex_lock(&g_mu);
        g_port = port ? port : ORGB_DEFAULT_PORT;
        g_wanted = true;
        pthread_cond_broadcast(&g_cv);
        pthread_mutex_unlock(&g_mu);
        wake_worker();
        return;
    }

    if (!g_started) return;
    pthread_mutex_lock(&g_mu);
    if (!g_wanted) { pthread_mutex_unlock(&g_mu); return; }
    g_wanted = false;
    unsigned req = ++g_disable_req;
    pthread_mutex_unlock(&g_mu);
    wake_worker();

    // Wait for the worker to restore the devices and disconnect.
    struct timespec deadline;
    clock_gettime(CLOCK_REALTIME, &deadline);
    deadline.tv_sec += 3;
    pthread_mutex_lock(&g_mu);
    while (g_disable_done != req)
        if (pthread_cond_timedwait(&g_cv, &g_mu, &deadline) == ETIMEDOUT) break;
    pthread_mutex_unlock(&g_mu);
}

void ORGBSetColor(uint8_t r, uint8_t g, uint8_t b) {
    if (!atomic_load(&g_connected)) return;
    atomic_store(&g_pending, 0x1000000u | ((uint32_t)r << 16) | ((uint32_t)g << 8) | b);
    wake_worker();
}

bool ORGBIsConnected(void) { return atomic_load(&g_connected); }

int ORGBDeviceCount(void) {
    pthread_mutex_lock(&g_mu);
    int n = g_nnames;
    pthread_mutex_unlock(&g_mu);
    return n;
}

bool ORGBDeviceName(int i, char *buf, size_t len) {
    bool ok = false;
    pthread_mutex_lock(&g_mu);
    if (i >= 0 && i < g_nnames && buf && len) {
        snprintf(buf, len, "%s", g_names[i]);
        ok = true;
    }
    pthread_mutex_unlock(&g_mu);
    return ok;
}
