#define _POSIX_C_SOURCE 200809L

#include <inttypes.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

static int sample(uint64_t *nanoseconds) {
    struct timespec value;
    if (clock_gettime(CLOCK_MONOTONIC, &value) != 0) {
        fputs("CLOCK_MONOTONIC unavailable\n", stderr);
        return 1;
    }
    if (value.tv_sec < 0 || value.tv_nsec < 0 || value.tv_nsec >= 1000000000L) {
        fputs("CLOCK_MONOTONIC returned an invalid timespec\n", stderr);
        return 1;
    }

    const uint64_t seconds = (uint64_t)value.tv_sec;
    if (seconds > (UINT64_MAX - (uint64_t)value.tv_nsec) / UINT64_C(1000000000)) {
        fputs("CLOCK_MONOTONIC nanoseconds overflow\n", stderr);
        return 1;
    }
    *nanoseconds = seconds * UINT64_C(1000000000)
        + (uint64_t)value.tv_nsec;
    return 0;
}

int main(int argc, char **argv) {
    unsigned long count = 1;
    if (argc == 2) {
        char *end = NULL;
        errno = 0;
        count = strtoul(argv[1], &end, 10);
        if (errno != 0 || end == argv[1] || *end != '\0' || count == 0 || count > 100) {
            fputs("sample count must be in 1...100\n", stderr);
            return 2;
        }
    } else if (argc != 1) {
        fputs("usage: monotonic-nanoseconds [SAMPLE_COUNT]\n", stderr);
        return 2;
    }

    uint64_t previous = 0;
    for (unsigned long index = 0; index < count; ++index) {
        uint64_t nanoseconds = 0;
        unsigned long attempts = 0;
        do {
            if (sample(&nanoseconds) != 0) {
                return 1;
            }
            attempts += 1;
            if (attempts == 1000000) {
                fputs("CLOCK_MONOTONIC did not advance\n", stderr);
                return 1;
            }
        } while (index != 0 && nanoseconds <= previous);
        printf("%" PRIu64 "\n", nanoseconds);
        previous = nanoseconds;
    }
    if (ferror(stdout)) {
        fputs("failed to write CLOCK_MONOTONIC sample\n", stderr);
        return 1;
    }
    return 0;
}
