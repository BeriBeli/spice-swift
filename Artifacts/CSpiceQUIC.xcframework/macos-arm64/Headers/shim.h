#ifndef SPICE_SWIFT_QUIC_SHIM_H
#define SPICE_SWIFT_QUIC_SHIM_H

#include <setjmp.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

typedef void *SpiceSwiftQuicContext;

typedef enum {
    SPICE_SWIFT_QUIC_INVALID = 0,
    SPICE_SWIFT_QUIC_GRAY = 1,
    SPICE_SWIFT_QUIC_RGB16 = 2,
    SPICE_SWIFT_QUIC_RGB24 = 3,
    SPICE_SWIFT_QUIC_RGB32 = 4,
    SPICE_SWIFT_QUIC_RGBA = 5,
} SpiceSwiftQuicImageType;

typedef struct SpiceSwiftQuicUsrContext SpiceSwiftQuicUsrContext;
struct SpiceSwiftQuicUsrContext {
    void (*error)(SpiceSwiftQuicUsrContext *usr, const char *format, ...);
    void (*warn)(SpiceSwiftQuicUsrContext *usr, const char *format, ...);
    void (*info)(SpiceSwiftQuicUsrContext *usr, const char *format, ...);
    void *(*malloc)(SpiceSwiftQuicUsrContext *usr, int size);
    void (*free)(SpiceSwiftQuicUsrContext *usr, void *ptr);
    int (*more_space)(SpiceSwiftQuicUsrContext *usr, uint32_t **io_ptr, int rows_completed);
    int (*more_lines)(SpiceSwiftQuicUsrContext *usr, uint8_t **lines);
};

int quic_decode_begin(SpiceSwiftQuicContext *quic, uint32_t *io_ptr,
                      unsigned int num_io_words, SpiceSwiftQuicImageType *type,
                      int *width, int *height);
int quic_decode(SpiceSwiftQuicContext *quic, SpiceSwiftQuicImageType type,
                uint8_t *buf, int stride);
SpiceSwiftQuicContext *quic_create(SpiceSwiftQuicUsrContext *usr);
void quic_destroy(SpiceSwiftQuicContext *quic);

typedef enum {
    SPICE_SWIFT_QUIC_OK = 0,
    SPICE_SWIFT_QUIC_BAD_INPUT = 1,
    SPICE_SWIFT_QUIC_DIMENSION_MISMATCH = 2,
    SPICE_SWIFT_QUIC_UNSUPPORTED_TYPE = 3,
    SPICE_SWIFT_QUIC_ALLOCATION_FAILED = 4,
} SpiceSwiftQuicStatus;

typedef struct {
    SpiceSwiftQuicUsrContext usr;
    jmp_buf jump;
    int warned;
} SpiceSwiftQuicBridge;

static inline void spice_swift_quic_error(
    SpiceSwiftQuicUsrContext *usr,
    const char *format,
    ...
) {
    (void)format;
    SpiceSwiftQuicBridge *bridge = (SpiceSwiftQuicBridge *)usr;
    longjmp(bridge->jump, 1);
}

static inline void spice_swift_quic_warn(
    SpiceSwiftQuicUsrContext *usr,
    const char *format,
    ...
) {
    (void)format;
    SpiceSwiftQuicBridge *bridge = (SpiceSwiftQuicBridge *)usr;
    bridge->warned = 1;
}

static inline void spice_swift_quic_info(
    SpiceSwiftQuicUsrContext *usr,
    const char *format,
    ...
) {
    (void)usr;
    (void)format;
}

static inline void *spice_swift_quic_malloc(
    SpiceSwiftQuicUsrContext *usr,
    int size
) {
    (void)usr;
    if (size <= 0) return NULL;
    return malloc((size_t)size);
}

static inline void spice_swift_quic_free(
    SpiceSwiftQuicUsrContext *usr,
    void *ptr
) {
    (void)usr;
    free(ptr);
}

static inline int spice_swift_quic_more_space(
    SpiceSwiftQuicUsrContext *usr,
    uint32_t **io_ptr,
    int rows_completed
) {
    (void)usr;
    (void)rows_completed;
    *io_ptr = NULL;
    return 0;
}

static inline int spice_swift_quic_more_lines(
    SpiceSwiftQuicUsrContext *usr,
    uint8_t **lines
) {
    (void)usr;
    *lines = NULL;
    return 0;
}

static inline SpiceSwiftQuicStatus spice_swift_quic_decode(
    const uint8_t *encoded,
    size_t encoded_size,
    int expected_width,
    int expected_height,
    uint8_t *output_bgra,
    size_t output_size,
    int *decoded_type,
    int *decoded_width,
    int *decoded_height
) {
    if (!encoded || !output_bgra || !decoded_type || !decoded_width ||
        !decoded_height || encoded_size == 0 ||
        encoded_size % sizeof(uint32_t) != 0 ||
        expected_width <= 0 || expected_height <= 0) {
        return SPICE_SWIFT_QUIC_BAD_INPUT;
    }
    size_t pixel_count = (size_t)expected_width * (size_t)expected_height;
    if (pixel_count > SIZE_MAX / 4 || output_size != pixel_count * 4) {
        return SPICE_SWIFT_QUIC_BAD_INPUT;
    }

    uint32_t *aligned_input = malloc(encoded_size);
    if (!aligned_input) return SPICE_SWIFT_QUIC_ALLOCATION_FAILED;
    memcpy(aligned_input, encoded, encoded_size);

    SpiceSwiftQuicBridge bridge;
    memset(&bridge, 0, sizeof(bridge));
    bridge.usr.error = spice_swift_quic_error;
    bridge.usr.warn = spice_swift_quic_warn;
    bridge.usr.info = spice_swift_quic_info;
    bridge.usr.malloc = spice_swift_quic_malloc;
    bridge.usr.free = spice_swift_quic_free;
    bridge.usr.more_space = spice_swift_quic_more_space;
    bridge.usr.more_lines = spice_swift_quic_more_lines;

    SpiceSwiftQuicContext *context = quic_create(&bridge.usr);
    if (!context) {
        free(aligned_input);
        return SPICE_SWIFT_QUIC_ALLOCATION_FAILED;
    }
    if (setjmp(bridge.jump) != 0) {
        quic_destroy(context);
        free(aligned_input);
        return SPICE_SWIFT_QUIC_BAD_INPUT;
    }

    SpiceSwiftQuicImageType type = SPICE_SWIFT_QUIC_INVALID;
    int width = 0;
    int height = 0;
    int begin_result = quic_decode_begin(
        context,
        aligned_input,
        (unsigned int)(encoded_size / sizeof(uint32_t)),
        &type,
        &width,
        &height
    );
    if (begin_result != 0 || bridge.warned) {
        quic_destroy(context);
        free(aligned_input);
        return SPICE_SWIFT_QUIC_BAD_INPUT;
    }
    *decoded_type = (int)type;
    *decoded_width = width;
    *decoded_height = height;
    if (width != expected_width || height != expected_height) {
        quic_destroy(context);
        free(aligned_input);
        return SPICE_SWIFT_QUIC_DIMENSION_MISMATCH;
    }

    int decode_result = -1;
    if (type == SPICE_SWIFT_QUIC_RGB16 ||
        type == SPICE_SWIFT_QUIC_RGB24 ||
        type == SPICE_SWIFT_QUIC_RGB32) {
        decode_result = quic_decode(
            context,
            SPICE_SWIFT_QUIC_RGB32,
            output_bgra,
            expected_width * 4
        );
    } else if (type == SPICE_SWIFT_QUIC_RGBA) {
        decode_result = quic_decode(
            context,
            SPICE_SWIFT_QUIC_RGBA,
            output_bgra,
            expected_width * 4
        );
    } else if (type == SPICE_SWIFT_QUIC_GRAY) {
        uint8_t *gray = malloc(pixel_count);
        if (!gray) {
            quic_destroy(context);
            free(aligned_input);
            return SPICE_SWIFT_QUIC_ALLOCATION_FAILED;
        }
        decode_result = quic_decode(
            context,
            SPICE_SWIFT_QUIC_GRAY,
            gray,
            expected_width
        );
        if (decode_result == 0 && !bridge.warned) {
            for (size_t index = 0; index < pixel_count; index++) {
                output_bgra[index * 4] = gray[index];
                output_bgra[index * 4 + 1] = gray[index];
                output_bgra[index * 4 + 2] = gray[index];
                output_bgra[index * 4 + 3] = 0;
            }
        }
        free(gray);
    } else {
        quic_destroy(context);
        free(aligned_input);
        return SPICE_SWIFT_QUIC_UNSUPPORTED_TYPE;
    }

    SpiceSwiftQuicStatus status = decode_result == 0 && !bridge.warned
        ? SPICE_SWIFT_QUIC_OK
        : SPICE_SWIFT_QUIC_BAD_INPUT;
    quic_destroy(context);
    free(aligned_input);
    return status;
}

#endif
