#!/bin/sh
set -eu

PACKAGE_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

cd "$PACKAGE_ROOT"
swift build -c release --disable-sandbox --product spice-bench >&2
exec .build/release/spice-bench "$@"
