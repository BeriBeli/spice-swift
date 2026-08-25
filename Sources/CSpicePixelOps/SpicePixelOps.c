#include "CSpicePixelOps.h"

#if !defined(__arm64__)
#error "SwiftSpice supports Apple Silicon (arm64) only."
#endif

#include <arm_neon.h>

static void spice_copy_bgra_alpha_nonoverlapping(
    const uint8_t *source,
    uint8_t *destination,
    size_t pixel_count
)
{
    while (pixel_count >= 16) {
        const uint8x16x4_t source_pixels = vld4q_u8(source);
        uint8x16x4_t destination_pixels = vld4q_u8(destination);
        destination_pixels.val[3] = source_pixels.val[3];
        vst4q_u8(destination, destination_pixels);
        source += 16 * 4;
        destination += 16 * 4;
        pixel_count -= 16;
    }
    while (pixel_count != 0) {
        destination[3] = source[3];
        source += 4;
        destination += 4;
        pixel_count -= 1;
    }
}

void spice_copy_bgra_alpha(
    const uint8_t *source,
    uint8_t *destination,
    size_t pixel_count
)
{
    if (source == NULL || destination == NULL) {
        return;
    }
    spice_copy_bgra_alpha_nonoverlapping(source, destination, pixel_count);
}

void spice_copy_bgra_alpha_overlap(
    uint8_t *pixels,
    size_t source_pixel,
    size_t destination_pixel,
    size_t pixel_count
)
{
    if (pixels == NULL || source_pixel >= destination_pixel || pixel_count == 0) {
        return;
    }

    const size_t distance = destination_pixel - source_pixel;
    const size_t initial_count = distance < pixel_count ? distance : pixel_count;
    uint8_t *destination = pixels + destination_pixel * 4;
    spice_copy_bgra_alpha_nonoverlapping(
        pixels + source_pixel * 4,
        destination,
        initial_count
    );

    size_t copied = initial_count;
    while (copied < pixel_count) {
        const size_t remaining = pixel_count - copied;
        const size_t chunk = copied < remaining ? copied : remaining;
        spice_copy_bgra_alpha_nonoverlapping(
            destination,
            destination + copied * 4,
            chunk
        );
        copied += chunk;
    }
}
