#!/usr/bin/env bash
# Build the primary SwiftSpice library product for Apple Silicon.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

CONFIGURATION="${CONFIGURATION:-${CONFIG:-release}}"
PRODUCT_NAME="SwiftSpice"
SCRATCH_PATH="$ROOT_DIR/.build/lib-arm64"

log() {
    printf '\033[1;34m[build-lib]\033[0m %s\n' "$*"
}

die() {
    printf '\033[1;31m[build-lib] error:\033[0m %s\n' "$*" >&2
    exit 1
}

[[ "$(uname -m)" == "arm64" ]] || die "SwiftSpice supports Apple Silicon only"
xcode-select -p >/dev/null 2>&1 || die "Xcode command-line tools are unavailable"

mkdir -p "$ROOT_DIR/.build/module-cache"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$ROOT_DIR/.build/module-cache}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-$ROOT_DIR/.build/module-cache}"

log "building $PRODUCT_NAME ($CONFIGURATION, arm64)"
swift build --disable-sandbox \
    -c "$CONFIGURATION" \
    --triple arm64-apple-macosx26.0 \
    --scratch-path "$SCRATCH_PATH" \
    --product "$PRODUCT_NAME" \
    -Xswiftc -warnings-as-errors
BIN_PATH="$(swift build --disable-sandbox \
    -c "$CONFIGURATION" \
    --triple arm64-apple-macosx26.0 \
    --scratch-path "$SCRATCH_PATH" \
    --show-bin-path)"

[[ -d "$BIN_PATH/$PRODUCT_NAME.swiftmodule" ]] \
    || die "built Swift module not found: $BIN_PATH/$PRODUCT_NAME.swiftmodule"
"$ROOT_DIR/Scripts/verify-native-closure.sh" --artifacts-only

log "done -> $BIN_PATH/$PRODUCT_NAME.swiftmodule"
