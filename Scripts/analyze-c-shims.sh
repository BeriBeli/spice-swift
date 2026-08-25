#!/usr/bin/env bash
# Run security-focused compiler diagnostics and static analysis on owned C boundaries.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

CLANG="${CLANG:-$(xcrun -f clang)}"
SDK_PATH="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"

common_arguments=(
    --analyze
    --analyzer-output text
    -std=c17
    -arch arm64
    -isysroot "$SDK_PATH"
    -Wall
    -Wextra
    -Werror=return-type
    -Wuninitialized
    -Wimplicit-fallthrough
    -Wshorten-64-to-32
    -Werror=implicit-function-declaration
    -Xanalyzer
    -analyzer-checker=core,security,unix.Malloc,unix.MallocSizeof,unix.MismatchedDeallocator,unix.StdCLibraryFunctions,unix.cstring.BadSizeArg
)

printf '[analyze-c-shims] analyzing CUSBRedirShim\n'
"$CLANG" "${common_arguments[@]}" \
    -F "$ROOT_DIR/Artifacts/CUSBRedir.xcframework/macos-arm64" \
    -I "$ROOT_DIR/Sources/CUSBRedirShim/include" \
    "$ROOT_DIR/Sources/CUSBRedirShim/USBRedirShim.c" \
    -o /dev/null

printf '[analyze-c-shims] analyzing CSpicePixelOps\n'
"$CLANG" "${common_arguments[@]}" \
    -I "$ROOT_DIR/Sources/CSpicePixelOps/include" \
    "$ROOT_DIR/Sources/CSpicePixelOps/SpicePixelOps.c" \
    -o /dev/null

for header in Sources/CSpiceQUIC/shim.h Sources/CZlib/shim.h; do
    printf '[analyze-c-shims] analyzing %s\n' "$header"
    "$CLANG" "${common_arguments[@]}" \
        -x c \
        -include "$ROOT_DIR/$header" \
        -Xanalyzer -analyzer-opt-analyze-headers \
        /dev/null \
        -o /dev/null
done

printf '[analyze-c-shims] compiler warnings and static analysis passed\n'
