#ifndef COLLABTERM_H
#define COLLABTERM_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Writes a status string into buf. Returns bytes written, or -1 if buf too small. */
int ct_hello(unsigned char *buf, size_t len);

/* ABI version of libcollabterm. Bump on breaking changes. */
int ct_version(void);

/* Copies the most recent error message into `out` (NOT NUL-terminated) and
 * returns its length. Returns 0 if no error has been recorded. Populated by
 * C-ABI entry points that return NULL or -1 on failure. */
size_t ct_last_error(uint8_t *out, size_t cap);

/* ---- PTY ------------------------------------------------------------- */

/* Spawn argv[0] under a PTY. argv is NULL-terminated (execvp style).
 * cwd may be NULL. On success, writes master fd to *out_fd, child pid to
 * *out_pid, and returns 0. Returns -1 on error. The master fd is set to
 * O_NONBLOCK so reads return EAGAIN when empty. */
int ct_pty_spawn(const char *const *argv,
                 const char *cwd,
                 uint16_t cols,
                 uint16_t rows,
                 int *out_fd,
                 int *out_pid);

int ct_pty_resize(int fd, uint16_t cols, uint16_t rows);

/* Returns 1 if the PTY's slave-side termios is in raw mode
 * (ICANON cleared), 0 otherwise. */
int ct_pty_is_raw(int fd);

void ct_pty_kill(int pid);

/* ---- Terminal grid --------------------------------------------------- */

typedef struct ct_term ct_term;

typedef struct {
    uint32_t codepoint;
    uint32_t fg;       /* 0xRRGGBB */
    uint32_t bg;       /* 0xRRGGBB */
    uint16_t attrs;    /* bit 0 bold, 1 italic, 2 underline, 3 reverse, 4 dim */
    uint8_t  width;    /* 1 or 2 (CJK) */
    uint8_t  _pad;
} ct_cell;

ct_term *ct_term_new(uint16_t cols, uint16_t rows);
void     ct_term_free(ct_term *t);
void     ct_term_feed(ct_term *t, const uint8_t *bytes, size_t len);
int      ct_term_resize(ct_term *t, uint16_t cols, uint16_t rows);

/* Writes up to `capacity` cells (row-major) into `out`.
 * Returns the number of cells written. */
size_t   ct_term_snapshot(ct_term *t, ct_cell *out, size_t capacity);

void     ct_term_size(ct_term *t, uint16_t *out_cols, uint16_t *out_rows);
void     ct_term_cursor(ct_term *t, uint16_t *out_x, uint16_t *out_y);
int      ct_term_is_using_alt(ct_term *t);

/* Monotonic counter bumped on any grid mutation. Swift redraws when this changes. */
uint32_t ct_term_dirty_epoch(ct_term *t);

/* ---- Session (Phase 3) ----------------------------------------------- */

typedef struct ct_session ct_session;

/* Create a host session listening on `port`. Pass 0 to let the OS assign
 * (inspect via ct_session_port). Returns NULL on error. */
ct_session *ct_session_new_host(uint16_t port);

/* Connect to `host:port` as a peer. `host` is a NUL-terminated C string. */
ct_session *ct_session_new_peer(const char *host, uint16_t port);

void        ct_session_free(ct_session *s);
uint16_t    ct_session_port(ct_session *s);
uint32_t    ct_session_peer_count(ct_session *s);

/* Broadcast `len` bytes to all connected peers. Returns 0 on success. */
int ct_session_broadcast(ct_session *s, const uint8_t *bytes, size_t len);

/* Send `len` bytes to exactly one peer by its transport id. Returns 0 on
 * success, -1 if the peer id is unknown or the write failed — inspect
 * ct_last_error() for a human-readable reason. */
int ct_session_send_to(ct_session *s,
                       uint32_t peer_id,
                       const uint8_t *bytes, size_t len);

/* Pop the next inbound frame. Writes up to `cap` bytes into `out` and the
 * sending peer id into `*out_peer_id`. Returns the full frame length (which
 * may exceed `cap` — caller should grow its buffer and retry). Returns 0
 * when the queue is empty. */
ptrdiff_t ct_session_poll(ct_session *s,
                          uint8_t *out, size_t cap,
                          uint32_t *out_peer_id);

/* Pop the next lifecycle event. On success, writes kind (0 = connected,
 * 1 = disconnected) to *out_kind and the peer id to *out_peer_id, and
 * returns 1. Returns 0 if no events are pending. */
int ct_session_poll_event(ct_session *s,
                          uint8_t *out_kind,
                          uint32_t *out_peer_id);

/* ---- Bore supervisor ------------------------------------------------- */

typedef struct ct_bore ct_bore;

ct_bore *ct_bore_new(void);
void     ct_bore_free(ct_bore *b);

/* Spawn `bore local --to bore.pub <port>` using the binary at `bore_path`.
 * Returns 0 on success, -1 on spawn failure. */
int      ct_bore_start(ct_bore *b, const char *bore_path, uint16_t port);

/* Poll once. If the public URL is now available, writes up to `cap` bytes
 * (NOT NUL-terminated) into `out` and returns the URL length. Returns 0 if
 * not ready, -1 on error. */
ptrdiff_t ct_bore_pump(ct_bore *b, uint8_t *out, size_t cap);

/* Copy the bore stdout/stderr scratch buffer for diagnostics. Returns total
 * buffered length (may exceed cap). */
ptrdiff_t ct_bore_debug(ct_bore *b, uint8_t *out, size_t cap);

void      ct_bore_stop(ct_bore *b);

#ifdef __cplusplus
}
#endif

#endif
