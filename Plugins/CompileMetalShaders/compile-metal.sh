#!/bin/sh

set -eu

if [ "$#" -ne 3 ]; then
    echo "usage: compile-metal.sh SOURCE AIR_OUTPUT METALLIB_OUTPUT" >&2
    exit 64
fi

source_path=$1
air_output=$2
metallib_output=$3

metal_path=$(/usr/bin/xcrun --find metal)

# Xcode 26 ships the current Metal compiler as an optional, cryptex-mounted
# component. `xcrun --find metal` still reports the forwarding shim, so resolve
# the installed component without embedding its machine-specific mount path.
component_json=$(/usr/bin/xcodebuild -showComponent MetalToolchain -json 2>/dev/null || true)
component_root=$(
    /usr/bin/printf '%s' "$component_json" \
        | /usr/bin/plutil -extract toolchainSearchPath raw -o - - 2>/dev/null \
        || true
)
if [ -n "$component_root" ] \
    && [ -x "$component_root/Metal.xctoolchain/usr/bin/metal" ]; then
    metal_path="$component_root/Metal.xctoolchain/usr/bin/metal"
fi

if ! "$metal_path" -help >/dev/null 2>&1; then
    echo "Metal Toolchain is unavailable; install it with: xcodebuild -downloadComponent MetalToolchain" >&2
    exit 69
fi

sdk_path=$(/usr/bin/xcrun --sdk macosx --show-sdk-path)
deployment_target=${MACOSX_DEPLOYMENT_TARGET:-26.0}
module_cache=$(dirname "$air_output")/MetalModuleCache

mkdir -p "$module_cache"

metallib_path=$(dirname "$metal_path")/metallib
if [ -x "$metallib_path" ]; then
    "$metal_path" \
        -c \
        -std=metal3.2 \
        -target "air64-apple-macos${deployment_target}" \
        -isysroot "$sdk_path" \
        -fmodules-cache-path="$module_cache" \
        "$source_path" \
        -o "$air_output"
    "$metallib_path" "$air_output" -o "$metallib_output"
else
    # The Xcode 26 driver links Metal source directly into a metallib.
    "$metal_path" \
        -std=metal3.2 \
        -target "air64-apple-macos${deployment_target}" \
        -isysroot "$sdk_path" \
        -fmodules-cache-path="$module_cache" \
        "$source_path" \
        -o "$metallib_output"
fi
