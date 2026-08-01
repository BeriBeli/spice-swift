#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

enum {
    stream_protocol = 1,
    stream_type_capabilities = 1,
    stream_type_format = 2,
    stream_type_data = 3,
    stream_type_start_stop = 4,
    stream_type_notify_error = 5,
    spice_codec_h264 = 3,
    spice_codec_h265 = 5,
    maximum_host_message = 4096,
};

struct stream_header {
    uint8_t protocol_version;
    uint8_t padding;
    uint16_t type;
    uint32_t size;
};

struct stream_format {
    uint32_t width;
    uint32_t height;
    uint8_t codec;
    uint8_t padding[3];
};

struct encoded_stream {
    const char *name;
    uint8_t codec;
    uint8_t *bytes;
    size_t size;
    size_t *access_units;
    size_t access_unit_count;
};

static volatile sig_atomic_t reset_requested;
static volatile sig_atomic_t pause_requested;
static volatile sig_atomic_t resume_requested;
static volatile sig_atomic_t terminate_requested;

static void handle_signal(int signal_number)
{
    switch (signal_number) {
    case SIGHUP:
        reset_requested = 1;
        break;
    case SIGUSR1:
        pause_requested = 1;
        break;
    case SIGUSR2:
        resume_requested = 1;
        break;
    default:
        terminate_requested = 1;
        break;
    }
}

static int read_full(int fd, void *buffer, size_t size)
{
    uint8_t *cursor = buffer;
    while (size != 0) {
        ssize_t count = read(fd, cursor, size);
        if (count < 0 && errno == EINTR) {
            continue;
        }
        if (count <= 0) {
            return -1;
        }
        cursor += (size_t)count;
        size -= (size_t)count;
    }
    return 0;
}

static int write_full(int fd, const void *buffer, size_t size)
{
    const uint8_t *cursor = buffer;
    while (size != 0) {
        ssize_t count = write(fd, cursor, size);
        if (count < 0 && errno == EINTR) {
            continue;
        }
        if (count <= 0) {
            return -1;
        }
        cursor += (size_t)count;
        size -= (size_t)count;
    }
    return 0;
}

static int send_message(int fd, uint16_t type, const void *payload, uint32_t size)
{
    const struct stream_header header = {
        .protocol_version = stream_protocol,
        .padding = 0,
        .type = type,
        .size = size,
    };
    if (write_full(fd, &header, sizeof(header)) != 0) {
        return -1;
    }
    return size == 0 || write_full(fd, payload, size) == 0 ? 0 : -1;
}

static uint8_t *load_file(const char *path, size_t *size)
{
    int fd = open(path, O_RDONLY);
    struct stat status;
    uint8_t *bytes;
    if (fd < 0 || fstat(fd, &status) != 0 || status.st_size <= 0) {
        perror("STREAM_AGENT load");
        exit(1);
    }
    *size = (size_t)status.st_size;
    bytes = malloc(*size);
    if (bytes == NULL || read_full(fd, bytes, *size) != 0) {
        perror("STREAM_AGENT read");
        exit(1);
    }
    close(fd);
    return bytes;
}

static size_t start_code_size(const uint8_t *bytes, size_t size, size_t offset)
{
    if (offset + 3 <= size && bytes[offset] == 0 && bytes[offset + 1] == 0
        && bytes[offset + 2] == 1) {
        return 3;
    }
    if (offset + 4 <= size && bytes[offset] == 0 && bytes[offset + 1] == 0
        && bytes[offset + 2] == 0 && bytes[offset + 3] == 1) {
        return 4;
    }
    return 0;
}

static unsigned int nal_type(uint8_t codec, uint8_t first_byte)
{
    return codec == spice_codec_h265
        ? (unsigned int)((first_byte >> 1) & 0x3f)
        : (unsigned int)(first_byte & 0x1f);
}

static size_t *find_access_units(
    const uint8_t *bytes,
    size_t size,
    uint8_t codec,
    size_t *count
)
{
    size_t capacity = 256;
    size_t *offsets = malloc((capacity + 1) * sizeof(*offsets));
    if (offsets == NULL) {
        exit(1);
    }
    *count = 0;
    for (size_t offset = 0; offset + 4 < size; ++offset) {
        size_t prefix = start_code_size(bytes, size, offset);
        unsigned int access_unit_delimiter = codec == spice_codec_h265 ? 35 : 9;
        if (prefix == 0
            || nal_type(codec, bytes[offset + prefix]) != access_unit_delimiter) {
            continue;
        }
        if (*count == capacity) {
            capacity *= 2;
            offsets = realloc(offsets, (capacity + 1) * sizeof(*offsets));
            if (offsets == NULL) {
                exit(1);
            }
        }
        offsets[(*count)++] = offset;
        offset += prefix;
    }
    if (*count == 0 || offsets[0] != 0) {
        fprintf(stderr, "STREAM_AGENT error=no_aud_at_start\n");
        exit(1);
    }
    offsets[*count] = size;
    return offsets;
}

static int open_stream_port(void)
{
    static const char path[] = "/dev/virtio-ports/org.spice-space.stream.0";
    for (unsigned attempt = 0; attempt < 60; ++attempt) {
        int fd = open(path, O_RDWR | O_CLOEXEC);
        if (fd >= 0) {
            return fd;
        }
        sleep(1);
    }
    perror("STREAM_AGENT open_port");
    return -1;
}

static struct encoded_stream load_stream(
    const char *name,
    uint8_t codec,
    const char *path
)
{
    struct encoded_stream stream = {
        .name = name,
        .codec = codec,
    };
    stream.bytes = load_file(path, &stream.size);
    stream.access_units = find_access_units(
        stream.bytes,
        stream.size,
        stream.codec,
        &stream.access_unit_count
    );
    return stream;
}

static void free_stream(struct encoded_stream *stream)
{
    free(stream->access_units);
    free(stream->bytes);
}

int main(int argc, char **argv)
{
    if (argc != 3) {
        fprintf(stderr, "usage: %s STREAM.h264 STREAM.h265\n", argv[0]);
        return 2;
    }
    setvbuf(stderr, NULL, _IONBF, 0);
    signal(SIGHUP, handle_signal);
    signal(SIGUSR1, handle_signal);
    signal(SIGUSR2, handle_signal);
    signal(SIGINT, handle_signal);
    signal(SIGTERM, handle_signal);

    struct encoded_stream h264 = load_stream("h264", spice_codec_h264, argv[1]);
    struct encoded_stream h265 = load_stream("h265", spice_codec_h265, argv[2]);
    struct encoded_stream *current_stream = NULL;
    int fd = open_stream_port();
    if (fd < 0) {
        return 1;
    }

    int streaming = 0;
    int paused = 1;
    size_t frame = 0;
    fprintf(stderr,
            "STREAM_AGENT ready codecs=h264,h265 pix_fmt=yuv420p resolution=1280x720 h264_frames=%zu h265_frames=%zu paused=1\n",
            h264.access_unit_count,
            h265.access_unit_count);

    while (!terminate_requested) {
        if (pause_requested) {
            pause_requested = 0;
            paused = 1;
            fprintf(stderr, "STREAM_AGENT state=paused\n");
        }
        if (resume_requested) {
            resume_requested = 0;
            paused = 0;
            fprintf(stderr, "STREAM_AGENT state=running\n");
        }
        if (reset_requested) {
            reset_requested = 0;
            frame = 0;
            fprintf(stderr, "STREAM_AGENT reset_frame=0\n");
        }

        struct pollfd poll_fd = { .fd = fd, .events = POLLIN };
        int result = poll(
            &poll_fd,
            1,
            streaming && !paused && current_stream != NULL ? 33 : -1
        );
        if (result < 0) {
            if (errno == EINTR) {
                continue;
            }
            perror("STREAM_AGENT poll");
            break;
        }
        if (result == 0) {
            size_t begin = current_stream->access_units[frame];
            size_t end = current_stream->access_units[frame + 1];
            if (send_message(fd, stream_type_data, current_stream->bytes + begin,
                             (uint32_t)(end - begin)) != 0) {
                perror("STREAM_AGENT send_frame");
                break;
            }
            frame = (frame + 1) % current_stream->access_unit_count;
            continue;
        }

        struct stream_header header;
        uint8_t payload[maximum_host_message];
        if (read_full(fd, &header, sizeof(header)) != 0) {
            perror("STREAM_AGENT read_header");
            break;
        }
        if (header.protocol_version != stream_protocol
            || header.size > sizeof(payload)
            || read_full(fd, payload, header.size) != 0) {
            fprintf(stderr, "STREAM_AGENT error=invalid_host_message type=%u size=%u\n",
                    header.type, header.size);
            break;
        }

        if (header.type == stream_type_capabilities) {
            if (send_message(fd, stream_type_capabilities, NULL, 0) != 0) {
                break;
            }
            fprintf(stderr, "STREAM_AGENT capabilities=acknowledged\n");
        } else if (header.type == stream_type_start_stop) {
            int supports_h264 = 0;
            int supports_h265 = 0;
            uint8_t codec_count = header.size == 0 ? 0 : payload[0];
            if ((uint32_t)codec_count + 1 > header.size) {
                fprintf(stderr, "STREAM_AGENT error=invalid_codec_list\n");
                break;
            }
            for (uint8_t index = 0; index < codec_count; ++index) {
                supports_h264 |= payload[index + 1] == spice_codec_h264;
                supports_h265 |= payload[index + 1] == spice_codec_h265;
            }
            current_stream = supports_h265 ? &h265 : supports_h264 ? &h264 : NULL;
            streaming = current_stream != NULL;
            frame = 0;
            if (streaming) {
                const struct stream_format format = {
                    .width = 1280,
                    .height = 720,
                    .codec = current_stream->codec,
                    .padding = { 0, 0, 0 },
                };
                if (send_message(fd, stream_type_format, &format, sizeof(format)) != 0) {
                    break;
                }
            }
            fprintf(stderr,
                    "STREAM_AGENT client_codecs=%u h264=%d h265=%d selected=%s streaming=%d\n",
                    codec_count,
                    supports_h264,
                    supports_h265,
                    current_stream == NULL ? "none" : current_stream->name,
                    streaming);
        } else if (header.type == stream_type_notify_error) {
            fprintf(stderr, "STREAM_AGENT server_error size=%u\n", header.size);
            break;
        } else {
            fprintf(stderr, "STREAM_AGENT ignored_host_type=%u size=%u\n",
                    header.type, header.size);
        }
    }

    close(fd);
    free_stream(&h265);
    free_stream(&h264);
    return terminate_requested ? 0 : 1;
}
