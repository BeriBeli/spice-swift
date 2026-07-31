#include <stddef.h>
#include <stdint.h>
#include <limits.h>
#include <zlib.h>

enum {
    SPICE_SWIFT_ZLIB_OK = 0,
    SPICE_SWIFT_ZLIB_INVALID_ARGUMENT = 1,
    SPICE_SWIFT_ZLIB_INITIALIZATION_FAILED = 2,
    SPICE_SWIFT_ZLIB_INFLATE_FAILED = 3,
    SPICE_SWIFT_ZLIB_SIZE_MISMATCH = 4,
    SPICE_SWIFT_ZLIB_TRAILING_INPUT = 5,
};

static inline int spice_swift_zlib_inflate_exact(
    const uint8_t *source,
    size_t source_size,
    uint8_t *destination,
    size_t destination_size,
    size_t *source_consumed,
    size_t *destination_written
) {
    if (!source || !destination || !source_consumed || !destination_written ||
        source_size > UINT_MAX || destination_size > UINT_MAX) {
        return SPICE_SWIFT_ZLIB_INVALID_ARGUMENT;
    }

    z_stream stream = {0};
    int status = inflateInit(&stream);
    if (status != Z_OK) {
        return SPICE_SWIFT_ZLIB_INITIALIZATION_FAILED;
    }

    stream.next_in = (Bytef *)source;
    stream.avail_in = (uInt)source_size;
    stream.next_out = destination;
    stream.avail_out = (uInt)destination_size;
    status = inflate(&stream, Z_FINISH);
    *source_consumed = (size_t)stream.total_in;
    *destination_written = (size_t)stream.total_out;
    inflateEnd(&stream);

    if (status != Z_STREAM_END) {
        return SPICE_SWIFT_ZLIB_INFLATE_FAILED;
    }
    if (*destination_written != destination_size) {
        return SPICE_SWIFT_ZLIB_SIZE_MISMATCH;
    }
    if (*source_consumed != source_size) {
        return SPICE_SWIFT_ZLIB_TRAILING_INPUT;
    }
    return SPICE_SWIFT_ZLIB_OK;
}
