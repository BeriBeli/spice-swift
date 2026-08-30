#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum {
    MARKER_MAGIC = 0xA5C3,
    MARKER_CELL_SIZE = 4,
    MARKER_COLUMNS = 88,
    MARKER_ROWS = 2,
    MARKER_PAYLOAD_BYTES = 22,
    MARKER_BITS = MARKER_COLUMNS * MARKER_ROWS,
    MARKER_WIDTH = MARKER_COLUMNS * MARKER_CELL_SIZE,
    MARKER_HEIGHT = MARKER_ROWS * MARKER_CELL_SIZE,
};

static int hex_nibble(char value, uint8_t *result) {
    if (value >= '0' && value <= '9') {
        *result = (uint8_t)(value - '0');
        return 0;
    }
    if (value >= 'a' && value <= 'f') {
        *result = (uint8_t)(value - 'a' + 10);
        return 0;
    }
    return -1;
}

static int parse_hex(const char *text, size_t count, uint8_t *output) {
    if (strlen(text) != count * 2) {
        return -1;
    }
    for (size_t index = 0; index < count; index += 1) {
        uint8_t high = 0;
        uint8_t low = 0;
        if (hex_nibble(text[index * 2], &high) != 0
            || hex_nibble(text[index * 2 + 1], &low) != 0) {
            return -1;
        }
        output[index] = (uint8_t)((high << 4) | low);
    }
    return 0;
}

static int encode_payload(
    const char *token,
    const char *revision_text,
    const char *checksum,
    uint8_t payload[MARKER_PAYLOAD_BYTES]
) {
    char *revision_end = NULL;
    errno = 0;
    uintmax_t parsed_revision = strtoumax(revision_text, &revision_end, 10);
    uint64_t revision = (uint64_t)parsed_revision;
    if (errno != 0 || revision_end == revision_text || *revision_end != '\0'
        || (uintmax_t)revision != parsed_revision) {
        return -1;
    }
    char canonical_revision[32];
    int length = snprintf(
        canonical_revision,
        sizeof(canonical_revision),
        "%" PRIu64,
        revision
    );
    if (length <= 0 || (size_t)length >= sizeof(canonical_revision)
        || strcmp(canonical_revision, revision_text) != 0) {
        return -1;
    }

    payload[0] = (uint8_t)(MARKER_MAGIC >> 8);
    payload[1] = (uint8_t)(MARKER_MAGIC & 0xFF);
    if (parse_hex(token, 8, payload + 2) != 0) {
        return -1;
    }
    for (size_t index = 0; index < 8; index += 1) {
        payload[10 + index] = (uint8_t)(revision >> ((7 - index) * 8));
    }
    if (parse_hex(checksum, 4, payload + 18) != 0) {
        return -1;
    }
    return 0;
}

static int payload_bit(const uint8_t payload[MARKER_PAYLOAD_BYTES], int index) {
    return (payload[index / 8] >> (7 - (index % 8))) & 1;
}

static int encode_bgra(const uint8_t payload[MARKER_PAYLOAD_BYTES]) {
    uint8_t pixels[MARKER_WIDTH * MARKER_HEIGHT * 4];
    for (int row = 0; row < MARKER_ROWS; row += 1) {
        for (int column = 0; column < MARKER_COLUMNS; column += 1) {
            int bit_index = row * MARKER_COLUMNS + column;
            uint8_t component = payload_bit(payload, bit_index) ? 0 : 255;
            for (int y = 0; y < MARKER_CELL_SIZE; y += 1) {
                for (int x = 0; x < MARKER_CELL_SIZE; x += 1) {
                    size_t pixel_index = (size_t)(
                        ((row * MARKER_CELL_SIZE + y) * MARKER_WIDTH
                            + column * MARKER_CELL_SIZE + x) * 4
                    );
                    pixels[pixel_index] = component;
                    pixels[pixel_index + 1] = component;
                    pixels[pixel_index + 2] = component;
                    pixels[pixel_index + 3] = 255;
                }
            }
        }
    }
    return fwrite(pixels, sizeof(pixels), 1, stdout) == 1 && fflush(stdout) == 0
        ? 0
        : 1;
}

int main(int argc, char **argv) {
    if (argc != 5
        || (strcmp(argv[1], "--draw") != 0
            && strcmp(argv[1], "--encode-bgra") != 0)) {
        fprintf(
            stderr,
            "usage: %s --draw|--encode-bgra TOKEN REVISION CHECKSUM\n",
            argv[0]
        );
        return 2;
    }
    uint8_t payload[MARKER_PAYLOAD_BYTES];
    if (encode_payload(argv[2], argv[3], argv[4], payload) != 0) {
        fputs("binary-grid-marker: invalid marker payload\n", stderr);
        return 2;
    }
    if (strcmp(argv[1], "--encode-bgra") == 0) {
        return encode_bgra(payload);
    }
    fputs("binary-grid-marker: draw support unavailable\n", stderr);
    return 1;
}
