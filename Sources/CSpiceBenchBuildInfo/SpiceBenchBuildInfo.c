#include "SpiceBenchBuildInfo.h"

#ifndef SPICE_BENCH_BUILD_REVISION
#define SPICE_BENCH_BUILD_REVISION ""
#endif

#ifndef SPICE_BENCH_BUILD_METADATA_HEX
#define SPICE_BENCH_BUILD_METADATA_HEX ""
#endif

const char *spice_bench_build_revision(void) {
    return SPICE_BENCH_BUILD_REVISION;
}

const char *spice_bench_build_metadata_hex(void) {
    return SPICE_BENCH_BUILD_METADATA_HEX;
}
