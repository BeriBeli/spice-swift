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
"$SWIFT_PATH" build -c release --disable-sandbox --product spice-bench >&2
export SPICE_BENCH_SWIFT_EXECUTABLE="$SWIFT_PATH"
export SPICE_BENCH_SWIFT_VERSION="$SWIFT_VERSION"
exec .build/release/spice-bench "$@"
