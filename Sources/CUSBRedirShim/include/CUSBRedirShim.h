#ifndef CUSBREDIRSHIM_H
#define CUSBREDIRSHIM_H

#include <stddef.h>
#include <stdint.h>

typedef struct SpiceUSBRedirHostContext SpiceUSBRedirHostContext;

enum {
    SPICE_USBREDIR_OK = 0,
    SPICE_USBREDIR_ERROR_ARGUMENT = -100,
    SPICE_USBREDIR_ERROR_ALLOCATION = -101,
    SPICE_USBREDIR_ERROR_BACKEND = -102,
    SPICE_USBREDIR_ERROR_OUTPUT_LIMIT = -103,
    SPICE_USBREDIR_ERROR_DEVICE_NOT_FOUND = -104,
    SPICE_USBREDIR_ERROR_DEVICE_REJECTED = -105,
};

SpiceUSBRedirHostContext *spice_usbredir_host_create(size_t maximum_buffered_bytes);
void spice_usbredir_host_destroy(SpiceUSBRedirHostContext *context);

int spice_usbredir_host_feed_guest(
    SpiceUSBRedirHostContext *context,
    const uint8_t *data,
    size_t length
);
int spice_usbredir_host_attach(
    SpiceUSBRedirHostContext *context,
    uint8_t bus_number,
    uint8_t device_address
);
int spice_usbredir_host_detach(SpiceUSBRedirHostContext *context);
int spice_usbredir_host_pump(SpiceUSBRedirHostContext *context, uint32_t timeout_milliseconds);

size_t spice_usbredir_host_output_size(const SpiceUSBRedirHostContext *context);
size_t spice_usbredir_host_take_output(
    SpiceUSBRedirHostContext *context,
    uint8_t *destination,
    size_t capacity
);

#endif
