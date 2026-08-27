#!/bin/sh
set -eu

PACKAGE_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SWIFT_COMMAND=${SWIFT_EXECUTABLE:-swift}
SWIFT_PATH=$(command -v "$SWIFT_COMMAND") || {
    echo "spice-bench: Swift executable not found: $SWIFT_COMMAND" >&2
    exit 1
}
case "$SWIFT_PATH" in
    /*) ;;
    *)
        echo "spice-bench: Swift executable did not resolve to an absolute path" >&2
        exit 1
        ;;
esac
SWIFT_DIRECTORY=$(CDPATH= cd -- "$(dirname -- "$SWIFT_PATH")" && pwd -P)
SWIFT_PATH="$SWIFT_DIRECTORY/$(basename -- "$SWIFT_PATH")"
SWIFT_VERSION=$("$SWIFT_PATH" --version) || {
    echo "spice-bench: unable to capture Swift toolchain version" >&2
    exit 1
}
SWIFT_TARGET_INFO=$("$SWIFT_PATH" -print-target-info) || {
    echo "spice-bench: unable to capture Swift target information" >&2
    exit 1
}

if [ -n "${DEVELOPER_DIR:-}" ]; then
    BUILD_DEVELOPER_DIRECTORY=$DEVELOPER_DIR
else
    BUILD_DEVELOPER_DIRECTORY=$(/usr/bin/xcode-select -p) || {
        echo "spice-bench: unable to resolve the active developer directory" >&2
        exit 1
    }
fi
case "$BUILD_DEVELOPER_DIRECTORY" in
    /*) ;;
    *)
        echo "spice-bench: developer directory is not absolute" >&2
        exit 1
        ;;
esac
BUILD_DEVELOPER_DIRECTORY=$(CDPATH= cd -- "$BUILD_DEVELOPER_DIRECTORY" && pwd -P) || {
    echo "spice-bench: unable to canonicalize the developer directory" >&2
    exit 1
}
BUILD_TOOLCHAINS=${TOOLCHAINS:-}
BUILD_SDKROOT=${SDKROOT:-}
BUILD_SDK_PATH=$(/usr/bin/xcrun --sdk macosx --show-sdk-path) || {
    echo "spice-bench: unable to resolve the macOS SDK path" >&2
    exit 1
}
BUILD_SDK_VERSION=$(/usr/bin/xcrun --sdk macosx --show-sdk-version) || {
    echo "spice-bench: unable to resolve the macOS SDK version" >&2
    exit 1
}

cd "$PACKAGE_ROOT"
BUILD_REVISION=$(/usr/bin/git rev-parse --verify HEAD) || {
    echo "spice-bench: unable to resolve repository HEAD" >&2
    exit 1
}
INITIAL_STATUS=$(/usr/bin/git status --porcelain=v1 --untracked-files=all) || {
    echo "spice-bench: unable to inspect repository status" >&2
    exit 1
}
if [ -n "$INITIAL_STATUS" ]; then
    echo "spice-bench: repository must be clean before building an artifact" >&2
    exit 1
fi

SCRATCH_ROOT=${TMPDIR:-/tmp}
SCRATCH_PATH=$(mktemp -d "$SCRATCH_ROOT/spice-bench-build.XXXXXX") || {
    echo "spice-bench: unable to create an isolated SwiftPM scratch directory" >&2
    exit 1
}
cleanup() {
    rm -rf -- "$SCRATCH_PATH"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

BUILD_INFO_FILE="$SCRATCH_PATH/spice-bench-build-info"
{
    printf '%s\0' "$SWIFT_PATH"
    printf '%s\0' "$SWIFT_VERSION"
    printf '%s\0' "$SWIFT_TARGET_INFO"
    printf '%s\0' "$BUILD_DEVELOPER_DIRECTORY"
    printf '%s\0' "$BUILD_TOOLCHAINS"
    printf '%s\0' "$BUILD_SDKROOT"
    printf '%s\0' "$BUILD_SDK_PATH"
    printf '%s\0' "$BUILD_SDK_VERSION"
    printf '%s\0' 'release'
} > "$BUILD_INFO_FILE"
BUILD_INFO_HEX=$(/usr/bin/od -An -tx1 -v "$BUILD_INFO_FILE" | /usr/bin/tr -d ' \n') || {
    echo "spice-bench: unable to encode build metadata" >&2
    exit 1
}
if [ -z "$BUILD_INFO_HEX" ]; then
    echo "spice-bench: encoded build metadata is empty" >&2
    exit 1
fi

# The quotes are bytes in the compiler argument; the shell escape is only
# syntax and does not pass a backslash to SwiftPM or Clang.
REVISION_DEFINE="-DSPICE_BENCH_BUILD_REVISION=\"$BUILD_REVISION\""
BUILD_INFO_DEFINE="-DSPICE_BENCH_BUILD_METADATA_HEX=\"$BUILD_INFO_HEX\""
BINARY_DIRECTORY=$("$SWIFT_PATH" build \
    -c release \
    --disable-sandbox \
    --scratch-path "$SCRATCH_PATH" \
    --show-bin-path) || {
    echo "spice-bench: unable to resolve the isolated product directory" >&2
    exit 1
}
"$SWIFT_PATH" build \
    -c release \
    --disable-sandbox \
    --product spice-bench \
    --scratch-path "$SCRATCH_PATH" \
    -Xcc "$REVISION_DEFINE" \
    -Xcc "$BUILD_INFO_DEFINE" >&2

FINAL_REVISION=$(/usr/bin/git rev-parse --verify HEAD) || {
    echo "spice-bench: unable to re-resolve repository HEAD after build" >&2
    exit 1
}
FINAL_STATUS=$(/usr/bin/git status --porcelain=v1 --untracked-files=all) || {
    echo "spice-bench: unable to re-inspect repository status after build" >&2
    exit 1
}
if [ "$FINAL_REVISION" != "$BUILD_REVISION" ] || [ -n "$FINAL_STATUS" ]; then
    echo "spice-bench: repository changed while building the artifact" >&2
    exit 1
fi

"$BINARY_DIRECTORY/spice-bench" "$@"
