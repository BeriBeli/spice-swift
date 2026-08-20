#!/usr/bin/env bash
# Build and run the SpiceViewer integration client while retaining its output.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-${CONFIG:-debug}}"
PRODUCT_NAME="spice-viewer"
SCRATCH_PATH="$ROOT_DIR/.build/viewer-arm64"
LOG_FILE="${SWIFTSPICE_LOG:-/tmp/swiftspice-debug.log}"

cd "$ROOT_DIR"
mkdir -p "$ROOT_DIR/.build/module-cache"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$ROOT_DIR/.build/module-cache}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-$ROOT_DIR/.build/module-cache}"

if [[ "${SWIFTSPICE_SKIP_BUILD:-0}" != "1" ]]; then
    swift build --disable-sandbox \
        -c "$CONFIGURATION" \
        --triple arm64-apple-macosx26.0 \
        --scratch-path "$SCRATCH_PATH" \
        --product "$PRODUCT_NAME"
fi
BIN_PATH="$(swift build --disable-sandbox \
    -c "$CONFIGURATION" \
    --triple arm64-apple-macosx26.0 \
    --scratch-path "$SCRATCH_PATH" \
    --show-bin-path)"
VIEWER_BINARY="$BIN_PATH/$PRODUCT_NAME"
if [[ ! -x "$VIEWER_BINARY" ]]; then
    echo "error: viewer binary not found; run ./Scripts/debug-run.sh without SWIFTSPICE_SKIP_BUILD" >&2
    exit 1
fi

printf '\033[1;34m[debug-run]\033[0m running SpiceViewer -> %s\n' "$LOG_FILE"
printf 'Quit SpiceViewer to finish the capture.\n'
OS_ACTIVITY_DT_MODE=YES "$VIEWER_BINARY" "$@" 2>&1 | tee "$LOG_FILE"
printf '\nTerminal log: %s\n' "$LOG_FILE"
