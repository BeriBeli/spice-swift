// Isolated codec check/benchmark, never linked into SwiftSpice.
#include <turbojpeg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static void require(int condition, const char *message) {
    if (!condition) { fprintf(stderr, "%s: %s\n", message, tjGetErrorStr2(NULL)); exit(1); }
}

static int number(const char *value) {
    char *end;
    long result = strtol(value, &end, 10);
    require(*value && !*end && result > 0 && result <= 8192, "invalid argument");
    return (int)result;
}

static void save(const char *path, const unsigned char *bytes, size_t count) {
    FILE *file = fopen(path, "wb");
    require(file != NULL, "open output");
    require(fwrite(bytes, 1, count, file) == count, "write output");
    require(fclose(file) == 0, "close output");
}

static double seconds(clockid_t clock) {
    struct timespec value;
    require(clock_gettime(clock, &value) == 0, "clock_gettime");
    return (double)value.tv_sec + (double)value.tv_nsec / 1e9;
}

int main(int argc, char **argv) {
    require(argc >= 2, "missing mode");
    if (!strcmp(argv[1], "generate")) {
        require(argc == 8, "generate PATH WIDTH HEIGHT SUBSAMP QUALITY PROGRESSIVE");
        int width = number(argv[3]), height = number(argv[4]);
        int subsamp = atoi(argv[5]), quality = number(argv[6]);
        size_t count = (size_t)width * (size_t)height * 3;
        unsigned char *rgb = malloc(count), *jpeg = NULL;
        unsigned long jpegSize = 0;
        require(rgb != NULL, "allocate RGB");
        // Reproducible sharp coloured edges, ramps, fine lines and textured tiles.
        // The same encoded bytes are used by both decoders in every timed run.
        for (int y = 0; y < height; y++) for (int x = 0; x < width; x++) {
            size_t offset = ((size_t)y * (size_t)width + (size_t)x) * 3;
            unsigned int noise = ((unsigned int)x * 1664525u) ^ ((unsigned int)y * 1013904223u);
            int edge = (x % 23 < 2 || y % 19 < 2) ? 255 : 0;
            rgb[offset] = (unsigned char)(edge ^ (x * 255 / width));
            rgb[offset + 1] = (unsigned char)(edge ^ (y * 255 / height));
            rgb[offset + 2] = (unsigned char)(((x / 64 + y / 64) & 1) ? noise >> 24 : x + y);
        }
        tjhandle handle = tjInitCompress();
        require(handle != NULL, "create compressor");
        int flags = TJFLAG_ACCURATEDCT | (atoi(argv[7]) ? TJFLAG_PROGRESSIVE : 0);
        require(tjCompress2(handle, rgb, width, 0, height, TJPF_RGB, &jpeg, &jpegSize,
                            subsamp, quality, flags) == 0, "compress");
        save(argv[2], jpeg, jpegSize);
        tjFree(jpeg); free(rgb); tjDestroy(handle);
        return 0;
    }

    require(argc == 5 && !strcmp(argv[1], "decode"), "decode JPEG OUTPUT ITERATIONS");
    FILE *file = fopen(argv[2], "rb");
    require(file != NULL, "open JPEG");
    require(fseek(file, 0, SEEK_END) == 0, "seek JPEG");
    long length = ftell(file);
    require(length > 0, "JPEG length");
    require(fseek(file, 0, SEEK_SET) == 0, "rewind JPEG");
    unsigned char *jpeg = malloc((size_t)length);
    require(jpeg != NULL, "allocate JPEG");
    require(fread(jpeg, 1, (size_t)length, file) == (size_t)length, "read JPEG");
    require(fclose(file) == 0, "close JPEG");
    tjhandle handle = tjInitDecompress();
    require(handle != NULL, "create decoder");
    int width, height, subsamp, color;
    require(tjDecompressHeader3(handle, jpeg, (unsigned long)length, &width, &height,
                                &subsamp, &color) == 0, "read header");
    require(width > 0 && width <= 8192 && height > 0 && height <= 8192, "geometry");
    int stride = (width * 4 + 63) & ~63;
    size_t count = (size_t)stride * (size_t)height;
    unsigned char *allocation = malloc(count + 128);
    require(allocation != NULL, "allocate BGRA");
    memset(allocation, 0xA5, count + 128);
    unsigned char *bgra = allocation + 64;
    int iterations = number(argv[4]);
    // Match TurboJPEGInterop: persistent handle, Header3 per frame, full-size
    // BGRA, STOPONWARNING only. Neither FASTDCT nor FASTUPSAMPLE is enabled.
    for (int i = 0; i < 5; i++)
        require(tjDecompress2(handle, jpeg, (unsigned long)length, bgra, width, stride,
                              height, TJPF_BGRA, TJFLAG_STOPONWARNING) == 0, "warmup");
    double wall = seconds(CLOCK_MONOTONIC), cpu = seconds(CLOCK_PROCESS_CPUTIME_ID);
    for (int i = 0; i < iterations; i++) {
        int w, h, s, c;
        require(tjDecompressHeader3(handle, jpeg, (unsigned long)length, &w, &h, &s, &c) == 0,
                "timed header");
        require(tjDecompress2(handle, jpeg, (unsigned long)length, bgra, width, stride,
                              height, TJPF_BGRA, TJFLAG_STOPONWARNING) == 0, "timed decode");
    }
    cpu = seconds(CLOCK_PROCESS_CPUTIME_ID) - cpu;
    wall = seconds(CLOCK_MONOTONIC) - wall;
    for (int i = 0; i < 64; i++)
        require(allocation[i] == 0xA5 && bgra[count + (size_t)i] == 0xA5, "buffer guard changed");
    for (int y = 0; y < height; y++) {
        for (int x = width * 4; x < stride; x++)
            require(bgra[(size_t)y * (size_t)stride + (size_t)x] == 0xA5, "row padding changed");
        for (int x = 0; x < width; x++)
            require(bgra[(size_t)y * (size_t)stride + (size_t)x * 4 + 3] == 255, "nonopaque BGRA");
    }
    save(argv[3], bgra, count);
    printf("{\"width\":%d,\"height\":%d,\"stride\":%d,\"frames\":%d,"
           "\"cpu_ms_per_frame\":%.6f,\"wall_ms_per_frame\":%.6f}\n",
           width, height, stride, iterations, cpu * 1000 / iterations, wall * 1000 / iterations);
    free(allocation); free(jpeg); tjDestroy(handle);
    return 0;
}
