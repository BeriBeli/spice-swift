#include "SpiceBenchBuildInfo.h"

#ifndef SPICE_BENCH_BUILD_REVISION
#define SPICE_BENCH_BUILD_REVISION ""
#endif

const char *spice_bench_build_revision(void) {
    return SPICE_BENCH_BUILD_REVISION;
}
