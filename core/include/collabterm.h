#ifndef COLLABTERM_H
#define COLLABTERM_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Writes a status string into buf. Returns bytes written, or -1 if buf too small. */
int ct_hello(unsigned char *buf, size_t len);

/* ABI version of libcollabterm. Bump on breaking changes. */
int ct_version(void);

#ifdef __cplusplus
}
#endif

#endif
