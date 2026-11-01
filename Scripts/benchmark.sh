#!/usr/bin/env bash
# Opt-in local benchmarks. All benchmark CLI arguments are forwarded unchanged.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
export SWIFTSPICE_BENCHMARKS=1
export SWIFTSPICE_BENCHMARK_FIXTURES="$ROOT_DIR/.build/benchmark-fixtures"
mkdir -p "$SWIFTSPICE_BENCHMARK_FIXTURES"
xcrun clang -O3 -std=c17 -Wall -Wextra -Werror \
    -I "$ROOT_DIR/Artifacts/CTurboJPEG.xcframework/macos-arm64/CTurboJPEG.framework/Headers" \
    "$ROOT_DIR/Benchmarks/NativeJPEG/jpeg-check.c" \
    "$ROOT_DIR/Artifacts/CTurboJPEG.xcframework/macos-arm64/CTurboJPEG.framework/Versions/A/CTurboJPEG" \
    -o "$SWIFTSPICE_BENCHMARK_FIXTURES/jpeg-check"
"$SWIFTSPICE_BENCHMARK_FIXTURES/jpeg-check" generate "$SWIFTSPICE_BENCHMARK_FIXTURES/jpeg-1920x1080.jpg" 1920 1080 2 80 0
"$SWIFTSPICE_BENCHMARK_FIXTURES/jpeg-check" generate "$SWIFTSPICE_BENCHMARK_FIXTURES/jpeg-3840x2160.jpg" 3840 2160 2 80 0
exec swift package --disable-sandbox \
    --scratch-path "$ROOT_DIR/.build/benchmarks" \
    --allow-writing-to-package-directory benchmark --Xswiftc warnings-as-errors "$@"
