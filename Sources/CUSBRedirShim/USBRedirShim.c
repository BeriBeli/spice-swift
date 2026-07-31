#include "CUSBRedirShim.h"

#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>

#include <usbredirhost.h>

struct SpiceUSBRedirHostContext {
    libusb_context *usb_context;
    struct usbredirhost *host;
    uint8_t *input;
    size_t input_size;
    size_t input_offset;
    uint8_t *output;
    size_t output_size;
    size_t maximum_buffered_bytes;
    int callback_error;
};

static void spice_usbredir_log(void *private_data, int level, const char *message)
{
    (void)private_data;
    (void)level;
    (void)message;
}

static int spice_usbredir_read(void *private_data, uint8_t *data, int count)
{
    SpiceUSBRedirHostContext *context = private_data;
    if (context == NULL || data == NULL || count < 0) {
        return -1;
    }
    const size_t remaining = context->input_size - context->input_offset;
    if (remaining == 0) {
        return 0;
    }
    const size_t requested = (size_t)count;
    const size_t copied = remaining < requested ? remaining : requested;
    memcpy(data, context->input + context->input_offset, copied);
    context->input_offset += copied;
    if (context->input_offset == context->input_size) {
        free(context->input);
        context->input = NULL;
        context->input_size = 0;
        context->input_offset = 0;
    }
    return (int)copied;
}

static int spice_usbredir_write(void *private_data, uint8_t *data, int count)
{
    SpiceUSBRedirHostContext *context = private_data;
    if (context == NULL || data == NULL || count < 0) {
        return -1;
    }
    const size_t added = (size_t)count;
    if (added > context->maximum_buffered_bytes - context->output_size) {
        context->callback_error = SPICE_USBREDIR_ERROR_OUTPUT_LIMIT;
        return -1;
    }
    uint8_t *expanded = realloc(context->output, context->output_size + added);
    if (expanded == NULL && added != 0) {
        context->callback_error = SPICE_USBREDIR_ERROR_ALLOCATION;
        return -1;
    }
    context->output = expanded;
    memcpy(context->output + context->output_size, data, added);
    context->output_size += added;
    return count;
}

static int spice_usbredir_flush(SpiceUSBRedirHostContext *context)
{
    while (usbredirhost_has_data_to_write(context->host) > 0) {
        if (usbredirhost_write_guest_data(context->host) != 0) {
            return context->callback_error != 0
                ? context->callback_error
                : SPICE_USBREDIR_ERROR_BACKEND;
        }
    }
    return context->callback_error;
}

SpiceUSBRedirHostContext *spice_usbredir_host_create(size_t maximum_buffered_bytes)
{
    if (maximum_buffered_bytes == 0) {
        return NULL;
    }
    SpiceUSBRedirHostContext *context = calloc(1, sizeof(*context));
    if (context == NULL) {
        return NULL;
    }
    context->maximum_buffered_bytes = maximum_buffered_bytes;
    if (libusb_init(&context->usb_context) != 0) {
        free(context);
        return NULL;
    }
    context->host = usbredirhost_open(
        context->usb_context,
        NULL,
        spice_usbredir_log,
        spice_usbredir_read,
        spice_usbredir_write,
        context,
        "spice-swift",
        0,
        0
    );
    if (context->host == NULL) {
        libusb_exit(context->usb_context);
        free(context);
        return NULL;
    }
    if (spice_usbredir_flush(context) != 0) {
        spice_usbredir_host_destroy(context);
        return NULL;
    }
    return context;
}

void spice_usbredir_host_destroy(SpiceUSBRedirHostContext *context)
{
    if (context == NULL) {
        return;
    }
    if (context->host != NULL) {
        usbredirhost_close(context->host);
    }
    if (context->usb_context != NULL) {
        libusb_exit(context->usb_context);
    }
    free(context->input);
    free(context->output);
    free(context);
}

int spice_usbredir_host_feed_guest(
    SpiceUSBRedirHostContext *context,
    const uint8_t *data,
    size_t length
)
{
    if (context == NULL || data == NULL || length == 0) {
        return SPICE_USBREDIR_ERROR_ARGUMENT;
    }
    const size_t remaining = context->input_size - context->input_offset;
    if (length > context->maximum_buffered_bytes - remaining) {
        return SPICE_USBREDIR_ERROR_OUTPUT_LIMIT;
    }
    uint8_t *combined = malloc(remaining + length);
    if (combined == NULL) {
        return SPICE_USBREDIR_ERROR_ALLOCATION;
    }
    if (remaining != 0) {
        memcpy(combined, context->input + context->input_offset, remaining);
    }
    memcpy(combined + remaining, data, length);
    free(context->input);
    context->input = combined;
    context->input_size = remaining + length;
    context->input_offset = 0;

    const int result = usbredirhost_read_guest_data(context->host);
    if (result != 0) {
        return result;
    }
    return spice_usbredir_flush(context);
}

int spice_usbredir_host_attach(
    SpiceUSBRedirHostContext *context,
    uint8_t bus_number,
    uint8_t device_address
)
{
    if (context == NULL) {
        return SPICE_USBREDIR_ERROR_ARGUMENT;
    }
    libusb_device **devices = NULL;
    const ssize_t count = libusb_get_device_list(context->usb_context, &devices);
    if (count < 0) {
        return SPICE_USBREDIR_ERROR_BACKEND;
    }
    libusb_device *selected = NULL;
    for (ssize_t index = 0; index < count; index++) {
        if (libusb_get_bus_number(devices[index]) == bus_number
            && libusb_get_device_address(devices[index]) == device_address) {
            selected = devices[index];
            break;
        }
    }
    if (selected == NULL) {
        libusb_free_device_list(devices, 1);
        return SPICE_USBREDIR_ERROR_DEVICE_NOT_FOUND;
    }

    const struct usbredirfilter_rule *rules = NULL;
    int rules_count = 0;
    usbredirhost_get_guest_filter(context->host, &rules, &rules_count);
    if (rules_count > 0
        && usbredirhost_check_device_filter(rules, rules_count, selected, 0) != 0) {
        libusb_free_device_list(devices, 1);
        return SPICE_USBREDIR_ERROR_DEVICE_REJECTED;
    }

    libusb_device_handle *handle = NULL;
    if (libusb_open(selected, &handle) != 0) {
        libusb_free_device_list(devices, 1);
        return SPICE_USBREDIR_ERROR_BACKEND;
    }
    libusb_free_device_list(devices, 1);
    const int result = usbredirhost_set_device(context->host, handle);
    if (result != 0) {
        return result;
    }
    return spice_usbredir_flush(context);
}

int spice_usbredir_host_detach(SpiceUSBRedirHostContext *context)
{
    if (context == NULL) {
        return SPICE_USBREDIR_ERROR_ARGUMENT;
    }
    const int result = usbredirhost_set_device(context->host, NULL);
    if (result != 0) {
        return result;
    }
    return spice_usbredir_flush(context);
}

int spice_usbredir_host_pump(SpiceUSBRedirHostContext *context, uint32_t timeout_milliseconds)
{
    if (context == NULL) {
        return SPICE_USBREDIR_ERROR_ARGUMENT;
    }
    struct timeval timeout = {
        .tv_sec = (time_t)(timeout_milliseconds / 1000),
        .tv_usec = (suseconds_t)((timeout_milliseconds % 1000) * 1000),
    };
    if (libusb_handle_events_timeout_completed(
            context->usb_context,
            &timeout,
            NULL
        ) != 0) {
        return SPICE_USBREDIR_ERROR_BACKEND;
    }
    return spice_usbredir_flush(context);
}

size_t spice_usbredir_host_output_size(const SpiceUSBRedirHostContext *context)
{
    return context == NULL ? 0 : context->output_size;
}

size_t spice_usbredir_host_take_output(
    SpiceUSBRedirHostContext *context,
    uint8_t *destination,
    size_t capacity
)
{
    if (context == NULL || destination == NULL || capacity == 0) {
        return 0;
    }
    const size_t copied = context->output_size < capacity
        ? context->output_size
        : capacity;
    memcpy(destination, context->output, copied);
    context->output_size -= copied;
    if (context->output_size != 0) {
        memmove(context->output, context->output + copied, context->output_size);
    } else {
        free(context->output);
        context->output = NULL;
    }
    return copied;
}
