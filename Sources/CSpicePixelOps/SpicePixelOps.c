#include "CSpicePixelOps.h"

#if !defined(__arm64__)
#error "SwiftSpice supports Apple Silicon (arm64) only."
#endif

#include <arm_neon.h>

static inline uint8x16_t spice_bgra_alpha_mask(void)
{
    return vreinterpretq_u8_u32(vdupq_n_u32(UINT32_C(0xff000000)));
}

static void spice_copy_bgra_alpha_nonoverlapping(
    const uint8_t *source,
    uint8_t *destination,
    size_t pixel_count
)
{
    const uint8x16_t alpha_mask = spice_bgra_alpha_mask();
    while (pixel_count >= 16) {
        const uint8x16x4_t source_pixels = vld1q_u8_x4(source);
        uint8x16x4_t destination_pixels = vld1q_u8_x4(destination);
        destination_pixels.val[0] = vbslq_u8(
            alpha_mask,
            source_pixels.val[0],
            destination_pixels.val[0]
        );
        destination_pixels.val[1] = vbslq_u8(
            alpha_mask,
            source_pixels.val[1],
            destination_pixels.val[1]
        );
        destination_pixels.val[2] = vbslq_u8(
            alpha_mask,
            source_pixels.val[2],
            destination_pixels.val[2]
        );
        destination_pixels.val[3] = vbslq_u8(
            alpha_mask,
            source_pixels.val[3],
            destination_pixels.val[3]
        );
        vst1q_u8_x4(destination, destination_pixels);
        source += 16 * 4;
        destination += 16 * 4;
        pixel_count -= 16;
    }
    while (pixel_count >= 4) {
        const uint8x16_t source_pixels = vld1q_u8(source);
        const uint8x16_t destination_pixels = vld1q_u8(destination);
        vst1q_u8(
            destination,
            vbslq_u8(alpha_mask, source_pixels, destination_pixels)
        );
        source += 4 * 4;
        destination += 4 * 4;
        pixel_count -= 4;
    }
    while (pixel_count != 0) {
        destination[3] = source[3];
        source += 4;
        destination += 4;
        pixel_count -= 1;
    }
}

void spice_copy_bgra_opaque(
    const uint8_t *source,
    uint8_t *destination,
    size_t pixel_count
)
{
    if (source == NULL || destination == NULL) {
        return;
    }

    const uint8x16_t alpha_mask = spice_bgra_alpha_mask();
    while (pixel_count >= 16) {
        uint8x16x4_t pixels = vld1q_u8_x4(source);
        pixels.val[0] = vorrq_u8(pixels.val[0], alpha_mask);
        pixels.val[1] = vorrq_u8(pixels.val[1], alpha_mask);
        pixels.val[2] = vorrq_u8(pixels.val[2], alpha_mask);
        pixels.val[3] = vorrq_u8(pixels.val[3], alpha_mask);
        vst1q_u8_x4(destination, pixels);
        source += 16 * 4;
        destination += 16 * 4;
        pixel_count -= 16;
    }
    while (pixel_count >= 4) {
        vst1q_u8(destination, vorrq_u8(vld1q_u8(source), alpha_mask));
        source += 4 * 4;
        destination += 4 * 4;
        pixel_count -= 4;
    }
    while (pixel_count != 0) {
        destination[0] = source[0];
        destination[1] = source[1];
        destination[2] = source[2];
        destination[3] = UINT8_C(0xff);
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
