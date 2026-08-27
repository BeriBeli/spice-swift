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

REVISION_DEFINE="-DSPICE_BENCH_BUILD_REVISION=\\\"$BUILD_REVISION\\\""
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
    -Xcc "$REVISION_DEFINE" >&2

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

export SPICE_BENCH_SWIFT_EXECUTABLE="$SWIFT_PATH"
export SPICE_BENCH_SWIFT_VERSION="$SWIFT_VERSION"
"$BINARY_DIRECTORY/spice-bench" "$@"
