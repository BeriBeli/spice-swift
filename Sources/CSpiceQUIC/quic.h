/* SPDX-License-Identifier: LGPL-2.1-or-later
 * Copyright (C) 2009 Red Hat, Inc.
 * Standalone declarations from spice-common QUIC in spice-gtk 0.42.
 * Only dependency macros/includes are replaced with standard C declarations.
 */
#ifndef SWIFTSPICE_STANDALONE_QUIC_H
#define SWIFTSPICE_STANDALONE_QUIC_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    QUIC_IMAGE_TYPE_INVALID,
    QUIC_IMAGE_TYPE_GRAY,
    QUIC_IMAGE_TYPE_RGB16,
    QUIC_IMAGE_TYPE_RGB24,
    QUIC_IMAGE_TYPE_RGB32,
    QUIC_IMAGE_TYPE_RGBA
} QuicImageType;
#define QUIC_ERROR -1
#define QUIC_OK 0
typedef void *QuicContext;
typedef struct QuicUsrContext QuicUsrContext;
struct QuicUsrContext {
    __attribute__((noreturn, format(printf, 2, 3)))
    void (*error)(QuicUsrContext *usr, const char *fmt, ...);
    __attribute__((format(printf, 2, 3)))
    void (*warn)(QuicUsrContext *usr, const char *fmt, ...);
    __attribute__((format(printf, 2, 3)))
    void (*info)(QuicUsrContext *usr, const char *fmt, ...);
    void *(*malloc)(QuicUsrContext *usr, int size);
    void (*free)(QuicUsrContext *usr, void *ptr);
    int (*more_space)(QuicUsrContext *usr, uint32_t **io_ptr, int rows_completed);
    int (*more_lines)(QuicUsrContext *usr, uint8_t **lines);
};
int quic_encode(QuicContext *, QuicImageType, int, int, uint8_t *, unsigned int,
                int, uint32_t *, unsigned int);
int quic_decode_begin(QuicContext *, uint32_t *, unsigned int, QuicImageType *, int *, int *);
int quic_decode(QuicContext *, QuicImageType, uint8_t *, int);
QuicContext *quic_create(QuicUsrContext *);
void quic_destroy(QuicContext *);
#ifdef __cplusplus
}
#endif
#endif
