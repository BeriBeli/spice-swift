#!/usr/bin/env bash
set -euo pipefail

# Rebuild the checked-in, relocatable macOS static dependency artifacts from
# pinned upstream sources, including spice-gtk's QUIC C codec. Homebrew runtime
# libraries are never inputs. CMake is a maintainer-only JPEG build tool.

if [[ "$#" -gt 1 || ( "$#" -eq 1 && "$1" != "--jpeg-only" && "$1" != "--quic-only" ) ]]; then
    echo "usage: build-native-dependencies.sh [--jpeg-only|--quic-only]" >&2
    exit 2
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "${1:-}" == "--quic-only" ]]; then
    exec "$ROOT_DIR/Scripts/build-quic-native.sh"
fi
OUTPUT_DIR="$ROOT_DIR/Artifacts"
WORK_DIR="${SWIFTSPICE_NATIVE_WORK_DIR:-$(mktemp -d /private/tmp/swiftspice-native.XXXXXX)}"
MACOS_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-26.0}"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
CLANG="$(xcrun --sdk macosx --find clang)"
AR="$(xcrun --sdk macosx --find ar)"
RANLIB="$(xcrun --sdk macosx --find ranlib)"
PARALLEL_JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '4')"

JPEG_VERSION="3.2.1"
JPEG_ARCHIVE="libjpeg-turbo-$JPEG_VERSION.tar.gz"
JPEG_URL="https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/$JPEG_VERSION/$JPEG_ARCHIVE"
JPEG_SHA256="c27ad72a68da151177929aa969ae773a2da5ac2af9ce946079314fdac8cece7f"

USBREDIR_VERSION="0.15.0"
USBREDIR_ARCHIVE="usbredir-$USBREDIR_VERSION.tar.xz"
USBREDIR_URL="https://www.spice-space.org/download/usbredir/$USBREDIR_ARCHIVE"
USBREDIR_SHA256="6dc2a380277688a068191245dac2ab7063a552999d8ac3ad8e841c10ff050961"

LIBUSB_VERSION="1.0.30"
LIBUSB_ARCHIVE="libusb-$LIBUSB_VERSION.tar.bz2"
LIBUSB_URL="https://github.com/libusb/libusb/releases/download/v$LIBUSB_VERSION/$LIBUSB_ARCHIVE"
LIBUSB_SHA256="fea36f34f9156400209595e300840767ab1a385ede1dc7ee893015aea9c6dbaf"

cleanup() {
    if [[ -z "${SWIFTSPICE_NATIVE_WORK_DIR:-}" ]]; then
        rm -rf "$WORK_DIR"
    fi
}
trap cleanup EXIT

require_tool() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "error: required build tool '$1' was not found" >&2
        exit 1
    }
}

fetch_verified() {
    local url="$1"
    local archive="$2"
    local expected="$3"
    local destination="$WORK_DIR/downloads/$archive"
    mkdir -p "$WORK_DIR/downloads"
    if [[ ! -f "$destination" ]]; then
        curl -fL --retry 3 -o "$destination" "$url"
    fi
    local actual
    actual="$(shasum -a 256 "$destination" | awk '{print $1}')"
    if [[ "$actual" != "$expected" ]]; then
        echo "error: SHA-256 mismatch for $archive" >&2
        echo "expected: $expected" >&2
        echo "actual:   $actual" >&2
        exit 1
    fi
}

write_framework_module_map() {
    local directory="$1"
    local module="$2"
    shift 2
    {
        printf 'framework module %s {\n' "$module"
        for header in "$@"; do
            printf '  header "%s"\n' "$header"
        done
        printf '  export *\n}\n'
    } >"$directory/module.modulemap"
}

create_static_xcframework() {
    local module="$1"
    local source="$2"
    local framework="$WORK_DIR/frameworks/$module.framework"
    local version="$framework/Versions/A"
    local info_plist="$version/Resources/Info.plist"

    rm -rf "$framework"
    mkdir -p "$version/Headers" "$version/Modules" "$version/Resources"
    cp "$source/lib$module.a" "$version/$module"
    cp "$source/Headers/"*.h "$version/Headers/"
    cp "$source/Headers/module.modulemap" "$version/Modules/module.modulemap"

    plutil -create xml1 "$info_plist"
    plutil -insert CFBundleDevelopmentRegion -string en "$info_plist"
    plutil -insert CFBundleExecutable -string "$module" "$info_plist"
    plutil -insert CFBundleIdentifier -string "com.beribeli.SwiftSpice.$module" "$info_plist"
    plutil -insert CFBundleInfoDictionaryVersion -string 6.0 "$info_plist"
    plutil -insert CFBundleName -string "$module" "$info_plist"
    plutil -insert CFBundlePackageType -string FMWK "$info_plist"
    plutil -insert CFBundleShortVersionString -string 1.0 "$info_plist"
    plutil -insert CFBundleVersion -string 1 "$info_plist"
    plutil -insert MinimumOSVersion -string "$MACOS_DEPLOYMENT_TARGET" "$info_plist"

    ln -s A "$framework/Versions/Current"
    ln -s "Versions/Current/$module" "$framework/$module"
    ln -s Versions/Current/Headers "$framework/Headers"
    ln -s Versions/Current/Modules "$framework/Modules"
    ln -s Versions/Current/Resources "$framework/Resources"

    rm -rf "$OUTPUT_DIR/$module.xcframework"
    xcodebuild -create-xcframework \
        -framework "$framework" \
        -output "$OUTPUT_DIR/$module.xcframework"
}

require_tool curl
require_tool cmake
require_tool xcodebuild

fetch_verified "$JPEG_URL" "$JPEG_ARCHIVE" "$JPEG_SHA256"
mkdir -p "$WORK_DIR/src"
tar -xf "$WORK_DIR/downloads/$JPEG_ARCHIVE" -C "$WORK_DIR/src"

readonly arch="arm64"
arch_dir="$WORK_DIR/build/$arch"
prefix="$arch_dir/prefix"
mkdir -p "$arch_dir" "$prefix"

# AArch64 uses upstream Neon intrinsics, with no external assembler. Fail if
# CMake cannot enable that backend instead of silently producing scalar code.
# Pin BUILD as well: upstream otherwise embeds the date of configuration.
env -u CFLAGS -u CPPFLAGS -u CXXFLAGS -u LDFLAGS \
cmake -S "$WORK_DIR/src/libjpeg-turbo-$JPEG_VERSION" \
    -B "$arch_dir/jpeg" \
    -DCMAKE_C_COMPILER="$CLANG" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD="$JPEG_VERSION" \
    -DCMAKE_OSX_ARCHITECTURES="$arch" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOS_DEPLOYMENT_TARGET" \
    -DCMAKE_OSX_SYSROOT="$SDK_PATH" \
    -DCMAKE_INSTALL_PREFIX="$prefix/jpeg" \
    -DENABLE_SHARED=OFF \
    -DWITH_JAVA=OFF \
    -DWITH_SIMD=ON \
    -DREQUIRE_SIMD=ON \
    -DWITH_TESTS=OFF \
    -DWITH_TOOLS=OFF
cmake --build "$arch_dir/jpeg" --target install --parallel

artifact_stage="$WORK_DIR/artifacts"
mkdir -p "$artifact_stage/CTurboJPEG/Headers"
# Apple's ar otherwise stores build time/uid/gid in the archive. Repack with
# deterministic metadata even when reusing an existing CMake build directory.
ZERO_AR_DATE=1 /usr/bin/libtool -static -D \
    -o "$artifact_stage/CTurboJPEG/libCTurboJPEG.a" "$prefix/jpeg/lib/libturbojpeg.a"
cp "$ROOT_DIR/Sources/CTurboJPEG/shim.h" "$artifact_stage/CTurboJPEG/Headers/"
cp "$WORK_DIR/src/libjpeg-turbo-$JPEG_VERSION/src/turbojpeg.h" "$artifact_stage/CTurboJPEG/Headers/"
write_framework_module_map "$artifact_stage/CTurboJPEG/Headers" CTurboJPEG shim.h turbojpeg.h
mkdir -p "$OUTPUT_DIR"
create_static_xcframework CTurboJPEG "$artifact_stage/CTurboJPEG"
mkdir -p "$OUTPUT_DIR/CTurboJPEG.xcframework/Licenses"
cp "$WORK_DIR/src/libjpeg-turbo-$JPEG_VERSION/LICENSE.md" \
    "$OUTPUT_DIR/CTurboJPEG.xcframework/Licenses/libjpeg-turbo-LICENSE.md"
{
    printf 'Source: %s\nSHA-256: %s\n' "$JPEG_URL" "$JPEG_SHA256"
    printf 'Configuration: Release; arm64; BUILD=%s; macOS=%s; WITH_SIMD=ON; REQUIRE_SIMD=ON; deterministic archive (libtool -static -D, ZERO_AR_DATE=1); ENABLE_SHARED=OFF; WITH_JAVA=OFF; WITH_TESTS=OFF; WITH_TOOLS=OFF\n' "$JPEG_VERSION" "$MACOS_DEPLOYMENT_TARGET"
    "$CLANG" --version | head -1
    printf 'macOS SDK: %s\nCMake: %s\n' "$(xcrun --sdk macosx --show-sdk-version)" "$(cmake --version | head -1)"
    shasum -a 256 "$OUTPUT_DIR/CTurboJPEG.xcframework/macos-arm64/CTurboJPEG.framework/Versions/A/CTurboJPEG" | awk '{print "Archive SHA-256: " $1}'
} >"$OUTPUT_DIR/CTurboJPEG.xcframework/BUILD_PROVENANCE.txt"

if [[ "${1:-}" == "--jpeg-only" ]]; then
    "$ROOT_DIR/Scripts/verify-native-closure.sh" --artifacts-only
    exit 0
fi

fetch_verified "$USBREDIR_URL" "$USBREDIR_ARCHIVE" "$USBREDIR_SHA256"
fetch_verified "$LIBUSB_URL" "$LIBUSB_ARCHIVE" "$LIBUSB_SHA256"
tar -xf "$WORK_DIR/downloads/$USBREDIR_ARCHIVE" -C "$WORK_DIR/src"
tar -xf "$WORK_DIR/downloads/$LIBUSB_ARCHIVE" -C "$WORK_DIR/src"

    libusb_build="$arch_dir/libusb"
    mkdir -p "$libusb_build"
    (
        cd "$libusb_build"
        # SDK 27 declares pipe2, but our macOS 26 deployment target cannot use it.
        ac_cv_func_pipe2=no \
        CC="$CLANG" \
        CFLAGS="-arch $arch -isysroot $SDK_PATH -mmacosx-version-min=$MACOS_DEPLOYMENT_TARGET -O2" \
        LDFLAGS="-arch $arch -isysroot $SDK_PATH -mmacosx-version-min=$MACOS_DEPLOYMENT_TARGET" \
            "$WORK_DIR/src/libusb-$LIBUSB_VERSION/configure" \
            --host="$arch-apple-darwin" \
            --prefix="$prefix/libusb" \
            --disable-shared \
            --enable-static
        make -j"$PARALLEL_JOBS"
        make install
    )

    usbredir_src="$WORK_DIR/src/usbredir-$USBREDIR_VERSION"
    usbredir_build="$arch_dir/usbredir"
    mkdir -p "$usbredir_build/objects"
    printf '%s\n' \
        '#define USBREDIR_VISIBLE __attribute__((visibility("default")))' \
        '#define VERSION "0.15.0"' \
        '#define PACKAGE_VERSION "0.15.0"' \
        '#define HAVE_INTTYPES_H 1' \
        '#define HAVE_STDINT_H 1' \
        '#define HAVE_STDLIB_H 1' \
        '#define HAVE_STRING_H 1' \
        '#define HAVE_STRINGS_H 1' \
        '#define HAVE_SYS_STAT_H 1' \
        '#define HAVE_SYS_TYPES_H 1' \
        '#define HAVE_UNISTD_H 1' >"$usbredir_build/config.h"
    usbredir_includes=(
        -I"$usbredir_build"
        -I"$usbredir_src"
        -I"$usbredir_src/usbredirparser"
        -I"$usbredir_src/usbredirhost"
        -I"$prefix/libusb/include/libusb-1.0"
    )
    usbredir_sources=(
        "$usbredir_src/usbredirparser/usbredirparser.c"
        "$usbredir_src/usbredirparser/usbredirfilter.c"
        "$usbredir_src/usbredirhost/usbredirhost.c"
    )
    usbredir_objects=()
    for source in "${usbredir_sources[@]}"; do
        object="$usbredir_build/objects/$(basename "${source%.c}").o"
        "$CLANG" -c "$source" -o "$object" -std=c11 -O2 -fvisibility=hidden \
            -arch "$arch" -isysroot "$SDK_PATH" \
            -mmacosx-version-min="$MACOS_DEPLOYMENT_TARGET" \
            "${usbredir_includes[@]}"
        usbredir_objects+=("$object")
    done
    "$AR" crs "$usbredir_build/libusbredir.a" "${usbredir_objects[@]}"
    "$RANLIB" "$usbredir_build/libusbredir.a"

    ZERO_AR_DATE=1 /usr/bin/libtool -static -D -o "$arch_dir/libCUSBRedir.a" \
        "$usbredir_build/libusbredir.a" "$prefix/libusb/lib/libusb-1.0.a"

mkdir -p "$artifact_stage/CUSBRedir/Headers"

cp "$WORK_DIR/build/arm64/libCUSBRedir.a" \
    "$artifact_stage/CUSBRedir/libCUSBRedir.a"
cp "$WORK_DIR/src/usbredir-$USBREDIR_VERSION/usbredirhost/usbredirhost.h" \
    "$WORK_DIR/src/usbredir-$USBREDIR_VERSION/usbredirparser/usbredirfilter.h" \
    "$WORK_DIR/src/usbredir-$USBREDIR_VERSION/usbredirparser/usbredirparser.h" \
    "$WORK_DIR/src/usbredir-$USBREDIR_VERSION/usbredirparser/usbredirproto.h" \
    "$WORK_DIR/build/arm64/prefix/libusb/include/libusb-1.0/libusb.h" \
    "$artifact_stage/CUSBRedir/Headers/"
sed -i '' 's|#include <libusb.h>|#include "libusb.h"|' \
    "$artifact_stage/CUSBRedir/Headers/usbredirhost.h"
write_framework_module_map "$artifact_stage/CUSBRedir/Headers" \
    CUSBRedir usbredirhost.h libusb.h usbredirfilter.h usbredirparser.h usbredirproto.h

mkdir -p "$OUTPUT_DIR"
create_static_xcframework CUSBRedir "$artifact_stage/CUSBRedir"
mkdir -p "$OUTPUT_DIR/CUSBRedir.xcframework/Licenses"
cp "$WORK_DIR/src/usbredir-$USBREDIR_VERSION/COPYING.LIB" \
    "$OUTPUT_DIR/CUSBRedir.xcframework/Licenses/usbredir-COPYING.LIB"
cp "$WORK_DIR/src/libusb-$LIBUSB_VERSION/COPYING" \
    "$OUTPUT_DIR/CUSBRedir.xcframework/Licenses/libusb-COPYING"

"$ROOT_DIR/Scripts/build-quic-native.sh"

"$ROOT_DIR/Scripts/verify-native-closure.sh" --artifacts-only
echo "Native dependency artifacts rebuilt in $OUTPUT_DIR"
