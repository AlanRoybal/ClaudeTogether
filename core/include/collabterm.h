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

/* Monotonic counter bumped on any grid mutation. Swift redraws when this changes. */
uint32_t ct_term_dirty_epoch(ct_term *t);

#ifdef __cplusplus
}
#endif

#endif
