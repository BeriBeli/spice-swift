#!/usr/bin/env bash
# Run the complete test suite with AddressSanitizer instrumentation.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

SCRATCH_PATH="${SWIFTSPICE_ASAN_SCRATCH_PATH:-$ROOT_DIR/.build/address-sanitizer}"

printf '[address-sanitizer] running the complete test suite\n'
swift test --disable-sandbox \
    --scratch-path "$SCRATCH_PATH" \
    --sanitize address \
    -Xswiftc -warnings-as-errors \
    -q
printf '[address-sanitizer] passed\n'
