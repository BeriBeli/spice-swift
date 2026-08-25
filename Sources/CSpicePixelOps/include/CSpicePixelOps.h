#ifndef CSPICEPIXELOPS_H
#define CSPICEPIXELOPS_H

#include <stddef.h>
#include <stdint.h>

void spice_copy_bgra_alpha(
    const uint8_t *source,
    uint8_t *destination,
    size_t pixel_count
);

void spice_copy_bgra_alpha_overlap(
    uint8_t *pixels,
    size_t source_pixel,
    size_t destination_pixel,
    size_t pixel_count
);

#endif
