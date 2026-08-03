#include <CoreFoundation/CoreFoundation.h>
#include <IOSurface/IOSurface.h>
#include <glib.h>
#include <spice-client.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define ACTIVITY_BUCKET_COUNT 10u

typedef struct {
    GMainLoop *loop;
    GArray *interframe_ms;
    gint64 connect_start_us;
    gint64 observe_start_us;
    gint64 previous_frame_us;
    gint64 first_frame_us;
    gint64 last_frame_us;
    gint64 observe_end_us;
    guint16 active_bucket_mask;
    guint duration_seconds;
    guint frames;
    guint invalidations;
    const guint8 *primary_pixels;
    gint primary_stride;
    gsize primary_row_bytes;
    guint primary_height;
    IOSurfaceRef published_surface;
    gsize published_byte_count;
    guint64 frame_bytes;
    gint64 frame_copy_us;
    double observe_cpu_start_seconds;
    double observe_cpu_seconds;
    guint8 frame_copy_checksum;
    gboolean dirty;
    gboolean failed;
} BenchState;

static double process_cpu_seconds(void)
{
    struct timespec value;
    if (clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value) != 0) {
        return -1.0;
    }
    return (double)value.tv_sec + (double)value.tv_nsec / 1000000000.0;
}

static void dictionary_set_int(
    CFMutableDictionaryRef dictionary,
    CFStringRef key,
    int64_t value)
{
    CFNumberRef number = CFNumberCreate(
        kCFAllocatorDefault,
        kCFNumberSInt64Type,
        &value);
    CFDictionarySetValue(dictionary, key, number);
    CFRelease(number);
}

static IOSurfaceRef create_published_surface(gint width, gint height)
{
    CFMutableDictionaryRef properties = CFDictionaryCreateMutable(
        kCFAllocatorDefault,
        0,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks);
    dictionary_set_int(properties, kIOSurfaceWidth, width);
    dictionary_set_int(properties, kIOSurfaceHeight, height);
    dictionary_set_int(properties, kIOSurfaceBytesPerElement, 4);
    IOSurfaceRef surface = IOSurfaceCreate(properties);
    CFRelease(properties);
    return surface;
}

static gboolean stop_observation(gpointer opaque)
{
    BenchState *state = opaque;
    state->observe_end_us = g_get_monotonic_time();
    state->observe_cpu_seconds =
        process_cpu_seconds() - state->observe_cpu_start_seconds;
    g_main_loop_quit(state->loop);
    return G_SOURCE_REMOVE;
}

static gboolean connect_timeout(gpointer opaque)
{
    BenchState *state = opaque;
    if (state->observe_start_us == 0) {
        state->failed = TRUE;
        g_main_loop_quit(state->loop);
    }
    return G_SOURCE_REMOVE;
}

static gboolean publish_tick(gpointer opaque)
{
    BenchState *state = opaque;
    if (state->observe_start_us == 0 || !state->dirty) {
        return G_SOURCE_CONTINUE;
    }
    if (state->primary_pixels == NULL || state->published_surface == NULL) {
        state->failed = TRUE;
        g_main_loop_quit(state->loop);
        return G_SOURCE_REMOVE;
    }

    const gint64 copy_start_us = g_get_monotonic_time();
    uint32_t seed = 0;
    if (IOSurfaceLock(state->published_surface, 0, &seed) != kIOReturnSuccess) {
        state->failed = TRUE;
        g_main_loop_quit(state->loop);
        return G_SOURCE_REMOVE;
    }
    guint8 *published_pixels = IOSurfaceGetBaseAddress(state->published_surface);
    const gsize published_stride = IOSurfaceGetBytesPerRow(state->published_surface);
    if ((gsize)state->primary_stride == state->primary_row_bytes
        && published_stride == state->primary_row_bytes) {
        memcpy(
            published_pixels,
            state->primary_pixels,
            state->published_byte_count);
    } else {
        memset(
            published_pixels,
            0,
            published_stride * state->primary_height);
        for (guint row = 0; row < state->primary_height; row++) {
            memcpy(
                published_pixels + row * published_stride,
                state->primary_pixels + row * (gsize)state->primary_stride,
                state->primary_row_bytes);
        }
    }
    state->frame_copy_checksum ^= published_pixels[0];
    state->frame_copy_checksum ^=
        published_pixels[(state->primary_height - 1) * published_stride
            + state->primary_row_bytes - 1];
    IOSurfaceUnlock(state->published_surface, 0, &seed);
    state->frame_copy_us += g_get_monotonic_time() - copy_start_us;
    state->frame_bytes += state->published_byte_count;

    const gint64 now = g_get_monotonic_time();
    state->dirty = FALSE;
    state->frames++;
    if (state->first_frame_us == 0) {
        state->first_frame_us = now;
    }
    if (state->previous_frame_us != 0) {
        const double interval = (double)(now - state->previous_frame_us) / 1000.0;
        g_array_append_val(state->interframe_ms, interval);
    }
    state->previous_frame_us = now;
    state->last_frame_us = now;
    const gint64 elapsed_us = now - state->observe_start_us;
    const gint64 duration_us = (gint64)state->duration_seconds * G_USEC_PER_SEC;
    guint bucket = (guint)(elapsed_us * ACTIVITY_BUCKET_COUNT / duration_us);
    if (bucket >= ACTIVITY_BUCKET_COUNT) {
        bucket = ACTIVITY_BUCKET_COUNT - 1;
    }
    state->active_bucket_mask |= (guint16)(1u << bucket);
    return G_SOURCE_CONTINUE;
}

static void display_primary_create(
    SpiceChannel *channel,
    gint format,
    gint width,
    gint height,
    gint stride,
    gint shmid,
    gpointer pixels,
    gpointer opaque)
{
    (void)channel;
    (void)format;
    (void)shmid;
    BenchState *state = opaque;
    if (pixels == NULL || width <= 0 || height <= 0 || stride <= 0) {
        state->failed = TRUE;
        g_main_loop_quit(state->loop);
        return;
    }
    const gsize row_bytes = (gsize)width * 4u;
    if (row_bytes / 4u != (gsize)width
        || row_bytes > (gsize)stride
        || (gsize)height > G_MAXSIZE / row_bytes) {
        state->failed = TRUE;
        g_main_loop_quit(state->loop);
        return;
    }
    const gsize byte_count = row_bytes * (gsize)height;
    IOSurfaceRef published_surface = create_published_surface(width, height);
    if (published_surface == NULL) {
        state->failed = TRUE;
        g_main_loop_quit(state->loop);
        return;
    }
    if (state->published_surface != NULL) {
        CFRelease(state->published_surface);
    }
    state->primary_pixels = pixels;
    state->primary_stride = stride;
    state->primary_row_bytes = row_bytes;
    state->primary_height = (guint)height;
    state->published_surface = published_surface;
    state->published_byte_count = byte_count;
    if (state->observe_start_us == 0) {
        state->observe_start_us = g_get_monotonic_time();
        state->observe_cpu_start_seconds = process_cpu_seconds();
        g_timeout_add(16, publish_tick, state);
        g_timeout_add(state->duration_seconds * 1000u, stop_observation, state);
    }
    state->dirty = TRUE;
}

static void display_primary_destroy(SpiceChannel *channel, gpointer opaque)
{
    (void)channel;
    BenchState *state = opaque;
    state->primary_pixels = NULL;
    state->primary_stride = 0;
    state->primary_row_bytes = 0;
    state->primary_height = 0;
    if (state->published_surface != NULL) {
        CFRelease(state->published_surface);
        state->published_surface = NULL;
    }
    state->published_byte_count = 0;
}

static void display_invalidate(
    SpiceChannel *channel,
    gint x,
    gint y,
    gint width,
    gint height,
    gpointer opaque)
{
    (void)channel;
    (void)x;
    (void)y;
    (void)width;
    (void)height;
    BenchState *state = opaque;
    state->invalidations++;
    state->dirty = TRUE;
}

static void channel_event(SpiceChannel *channel, SpiceChannelEvent event, gpointer opaque)
{
    (void)channel;
    BenchState *state = opaque;
    if (event == SPICE_CHANNEL_ERROR_CONNECT
        || event == SPICE_CHANNEL_ERROR_TLS
        || event == SPICE_CHANNEL_ERROR_LINK
        || event == SPICE_CHANNEL_ERROR_AUTH
        || event == SPICE_CHANNEL_ERROR_IO) {
        state->failed = TRUE;
        g_main_loop_quit(state->loop);
    }
}

static void channel_new(SpiceSession *session, SpiceChannel *channel, gpointer opaque)
{
    (void)session;
    BenchState *state = opaque;
    g_signal_connect(channel, "channel-event", G_CALLBACK(channel_event), opaque);
    if (SPICE_IS_DISPLAY_CHANNEL(channel)) {
        g_signal_connect(
            channel,
            "display-primary-create",
            G_CALLBACK(display_primary_create),
            opaque);
        g_signal_connect(
            channel,
            "display-invalidate",
            G_CALLBACK(display_invalidate),
            opaque);
        g_signal_connect(
            channel,
            "display-primary-destroy",
            G_CALLBACK(display_primary_destroy),
            opaque);
    }
    if (!spice_channel_connect(channel)) {
        state->failed = TRUE;
        g_main_loop_quit(state->loop);
    }
}

static gint compare_double(gconstpointer lhs, gconstpointer rhs)
{
    const double a = *(const double *)lhs;
    const double b = *(const double *)rhs;
    return (a > b) - (a < b);
}

static double percentile95(GArray *values)
{
    if (values->len == 0) {
        return -1.0;
    }
    g_array_sort(values, compare_double);
    const guint index = (guint)((double)(values->len - 1) * 0.95 + 0.999999);
    return g_array_index(values, double, index);
}

int main(int argc, char **argv)
{
    if (argc != 4) {
        fprintf(stderr, "usage: %s HOST PORT OBSERVE_SECONDS\n", argv[0]);
        return EXIT_FAILURE;
    }

    char *end = NULL;
    const unsigned long duration = strtoul(argv[3], &end, 10);
    if (end == argv[3] || *end != '\0' || duration == 0 || duration > 3600) {
        fprintf(stderr, "invalid OBSERVE_SECONDS\n");
        return EXIT_FAILURE;
    }

    BenchState state = {
        .loop = g_main_loop_new(NULL, FALSE),
        .interframe_ms = g_array_new(FALSE, FALSE, sizeof(double)),
        .connect_start_us = g_get_monotonic_time(),
        .duration_seconds = (guint)duration,
    };
    SpiceSession *session = spice_session_new();
    const char *password = g_getenv("SPICE_PASSWORD");
    g_object_set(
        session,
        "host", argv[1],
        "port", argv[2],
        "password", password != NULL ? password : "",
        "enable-audio", FALSE,
        NULL);
    g_signal_connect(session, "channel-new", G_CALLBACK(channel_new), &state);

    g_timeout_add_seconds(15, connect_timeout, &state);
    if (!spice_session_connect(session)) {
        fprintf(stderr, "spice_session_connect rejected the configuration\n");
        state.failed = TRUE;
    } else {
        g_main_loop_run(state.loop);
    }

    const double connect_ms = state.observe_start_us == 0
        ? -1.0
        : (double)(state.observe_start_us - state.connect_start_us) / 1000.0;
    const double first_frame_ms = state.first_frame_us == 0
        ? -1.0
        : (double)(state.first_frame_us - state.observe_start_us) / 1000.0;
    const double ready_frame_ms = state.first_frame_us == 0
        ? -1.0
        : (double)(state.first_frame_us - state.connect_start_us) / 1000.0;
    const double p95_interframe_ms = percentile95(state.interframe_ms);
    const double active_span_ms = state.first_frame_us == 0
        ? -1.0
        : (double)(state.last_frame_us - state.first_frame_us) / 1000.0;
    const double last_frame_age_ms = state.last_frame_us == 0
        ? -1.0
        : (double)(state.observe_end_us - state.last_frame_us) / 1000.0;
    const guint active_time_buckets = (guint)__builtin_popcount(
        state.active_bucket_mask);
    const double fps = (double)state.frames / (double)state.duration_seconds;

    if (!state.failed && state.frames > 0) {
        printf(
            "{\"client\":\"spice-client-glib2\",\"connect_ms\":%.3f,"
            "\"observe_seconds\":%u,\"frames\":%u,\"fps\":%.6f,"
            "\"first_frame_ms\":%.3f,\"ready_frame_ms\":%.3f,"
            "\"p95_interframe_ms\":%.3f,"
            "\"active_span_ms\":%.3f,\"last_frame_age_ms\":%.3f,"
            "\"active_time_buckets\":%u,\"expected_time_buckets\":%u,"
            "\"invalidations\":%u,\"frame_bytes\":%" G_GUINT64_FORMAT ","
            "\"frame_copy_ms\":%.3f,\"observe_cpu_seconds\":%.6f,"
            "\"frame_copy_checksum\":%u}\n",
            connect_ms,
            state.duration_seconds,
            state.frames,
            fps,
            first_frame_ms,
            ready_frame_ms,
            p95_interframe_ms,
            active_span_ms,
            last_frame_age_ms,
            active_time_buckets,
            ACTIVITY_BUCKET_COUNT,
            state.invalidations,
            state.frame_bytes,
            (double)state.frame_copy_us / 1000.0,
            state.observe_cpu_seconds,
            state.frame_copy_checksum);
    }

    spice_session_disconnect(session);
    g_object_unref(session);
    if (state.published_surface != NULL) {
        CFRelease(state.published_surface);
    }
    g_array_unref(state.interframe_ms);
    g_main_loop_unref(state.loop);
    return state.failed || state.frames == 0 ? EXIT_FAILURE : EXIT_SUCCESS;
}
