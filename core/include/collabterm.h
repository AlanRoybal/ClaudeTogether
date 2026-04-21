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

#ifdef __cplusplus
}
#endif

#endif
