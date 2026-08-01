#!/usr/bin/env bash
set -euo pipefail

# Rebuild the checked-in, relocatable macOS static dependency artifacts from
# pinned upstream source releases. Homebrew is deliberately neither queried nor
# used as an input. CMake is only a build-time tool for libjpeg-turbo.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="$ROOT_DIR/Artifacts"
WORK_DIR="${SWIFTSPICE_NATIVE_WORK_DIR:-$(mktemp -d /private/tmp/swiftspice-native.XXXXXX)}"
MACOS_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-26.0}"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
CLANG="$(xcrun --sdk macosx --find clang)"
AR="$(xcrun --sdk macosx --find ar)"
RANLIB="$(xcrun --sdk macosx --find ranlib)"
PARALLEL_JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '4')"

JPEG_VERSION="3.2.0"
JPEG_ARCHIVE="libjpeg-turbo-$JPEG_VERSION.tar.gz"
JPEG_URL="https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/$JPEG_VERSION/$JPEG_ARCHIVE"
JPEG_SHA256="6f30092cef9fb839779646608f4ee14ae3cbac989c47fa05e841b0841f09878e"

SPICE_GTK_VERSION="0.42"
SPICE_GTK_ARCHIVE="spice-gtk-$SPICE_GTK_VERSION.tar.xz"
SPICE_GTK_URL="https://www.spice-space.org/download/gtk/$SPICE_GTK_ARCHIVE"
SPICE_GTK_SHA256="9380117f1811ad1faa1812cb6602479b6290d4a0d8cc442d44427f7f6c0e7a58"

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

write_module_map() {
    local directory="$1"
    local module="$2"
    local header="$3"
    printf 'module %s {\n  header "%s"\n  export *\n}\n' "$module" "$header" \
        >"$directory/module.modulemap"
}

require_tool curl
require_tool cmake
require_tool xcodebuild

fetch_verified "$JPEG_URL" "$JPEG_ARCHIVE" "$JPEG_SHA256"
fetch_verified "$SPICE_GTK_URL" "$SPICE_GTK_ARCHIVE" "$SPICE_GTK_SHA256"
fetch_verified "$USBREDIR_URL" "$USBREDIR_ARCHIVE" "$USBREDIR_SHA256"
fetch_verified "$LIBUSB_URL" "$LIBUSB_ARCHIVE" "$LIBUSB_SHA256"

mkdir -p "$WORK_DIR/src"
tar -xf "$WORK_DIR/downloads/$JPEG_ARCHIVE" -C "$WORK_DIR/src"
tar -xf "$WORK_DIR/downloads/$SPICE_GTK_ARCHIVE" -C "$WORK_DIR/src"
tar -xf "$WORK_DIR/downloads/$USBREDIR_ARCHIVE" -C "$WORK_DIR/src"
tar -xf "$WORK_DIR/downloads/$LIBUSB_ARCHIVE" -C "$WORK_DIR/src"

readonly arch="arm64"
    arch_dir="$WORK_DIR/build/$arch"
    prefix="$arch_dir/prefix"
    mkdir -p "$arch_dir" "$prefix"

    env -u CFLAGS -u CPPFLAGS -u CXXFLAGS -u LDFLAGS \
    cmake -S "$WORK_DIR/src/libjpeg-turbo-$JPEG_VERSION" \
        -B "$arch_dir/jpeg" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_OSX_ARCHITECTURES="$arch" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOS_DEPLOYMENT_TARGET" \
        -DCMAKE_OSX_SYSROOT="$SDK_PATH" \
        -DCMAKE_INSTALL_PREFIX="$prefix/jpeg" \
        -DENABLE_SHARED=OFF \
        -DWITH_JAVA=OFF \
        -DWITH_SIMD=OFF \
        -DWITH_TESTS=OFF \
        -DWITH_TOOLS=OFF
    cmake --build "$arch_dir/jpeg" --target install --parallel

    libusb_build="$arch_dir/libusb"
    mkdir -p "$libusb_build"
    (
        cd "$libusb_build"
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

    quic_src="$WORK_DIR/src/spice-gtk-$SPICE_GTK_VERSION/subprojects/spice-common/common"
    quic_build="$arch_dir/quic"
    mkdir -p "$quic_build/src/spice"
    cp "$quic_src/quic.c" "$quic_src/quic_tmpl.c" "$quic_src/quic_family_tmpl.c" \
        "$quic_build/src/"
    printf '%s\n' \
        '#pragma once' \
        '#include <assert.h>' \
        '#define SPICE_VERIFY(value) _Static_assert((value), "SPICE verification failed")' \
        '#define spice_assert(value) assert(value)' \
        '#define spice_extra_assert(value) assert(value)' \
        '#define spice_return_if_fail(value) do { if (!(value)) return; } while (0)' \
        '#define spice_warn_if_reached() ((void)0)' \
        '#define G_UNLIKELY(value) __builtin_expect(!!(value), 0)' \
        '#define SPICE_ATTR_PACKED __attribute__((packed))' \
        '#define SPICE_GNUC_UNUSED __attribute__((unused))' \
        '#define SPICE_CONSTRUCTOR_FUNC(name) static void __attribute__((constructor)) name(void)' \
        '#define GUINT32_TO_LE(value) (value)' \
        '#define GUINT32_FROM_LE(value) (value)' \
        '#define TRUE 1' \
        '#define FALSE 0' \
        >"$quic_build/src/log.h"
    printf '%s\n' \
        '#pragma once' \
        '#include <stdint.h>' \
        '#define SPICE_BEGIN_DECLS' \
        '#define SPICE_END_DECLS' \
        '#define SPICE_GNUC_NORETURN __attribute__((noreturn))' \
        '#define SPICE_GNUC_PRINTF(format_index, argument_index) __attribute__((format(printf, format_index, argument_index)))' \
        'typedef enum { QUIC_IMAGE_TYPE_INVALID, QUIC_IMAGE_TYPE_GRAY, QUIC_IMAGE_TYPE_RGB16, QUIC_IMAGE_TYPE_RGB24, QUIC_IMAGE_TYPE_RGB32, QUIC_IMAGE_TYPE_RGBA } QuicImageType;' \
        '#define QUIC_ERROR -1' \
        '#define QUIC_OK 0' \
        'typedef void *QuicContext;' \
        'typedef struct QuicUsrContext QuicUsrContext;' \
        'struct QuicUsrContext {' \
        '  SPICE_GNUC_NORETURN SPICE_GNUC_PRINTF(2, 3) void (*error)(QuicUsrContext *, const char *, ...);' \
        '  SPICE_GNUC_PRINTF(2, 3) void (*warn)(QuicUsrContext *, const char *, ...);' \
        '  SPICE_GNUC_PRINTF(2, 3) void (*info)(QuicUsrContext *, const char *, ...);' \
        '  void *(*malloc)(QuicUsrContext *, int);' \
        '  void (*free)(QuicUsrContext *, void *);' \
        '  int (*more_space)(QuicUsrContext *, uint32_t **, int);' \
        '  int (*more_lines)(QuicUsrContext *, uint8_t **);' \
        '};' \
        'int quic_encode(QuicContext *, QuicImageType, int, int, uint8_t *, unsigned int, int, uint32_t *, unsigned int);' \
        'int quic_decode_begin(QuicContext *, uint32_t *, unsigned int, QuicImageType *, int *, int *);' \
        'int quic_decode(QuicContext *, QuicImageType, uint8_t *, int);' \
        'QuicContext *quic_create(QuicUsrContext *);' \
        'void quic_destroy(QuicContext *);' \
        >"$quic_build/src/quic.h"
    printf '%s\n' \
        '#pragma once' \
        '#include <stddef.h>' \
        '#include <stdint.h>' \
        '#include <string.h>' \
        '#define SPICE_BEGIN_DECLS' \
        '#define SPICE_END_DECLS' \
        '#define MEMCLEAR(pointer, size) memset((pointer), 0, (size))' \
        >"$quic_build/src/quic_config.h"
    printf '%s\n' '#define ENABLE_EXTRA_CHECKS 0' >"$quic_build/src/config.h"
    printf '%s\n' '#pragma pack(push, 1)' >"$quic_build/src/spice/start-packed.h"
    printf '%s\n' '#pragma pack(pop)' >"$quic_build/src/spice/end-packed.h"
    "$CLANG" -c "$quic_build/src/quic.c" -o "$quic_build/quic.o" \
        -std=c11 -O2 -DNDEBUG -arch "$arch" -isysroot "$SDK_PATH" \
        -mmacosx-version-min="$MACOS_DEPLOYMENT_TARGET" -I"$quic_build/src"
    "$AR" crs "$quic_build/libspicequic.a" "$quic_build/quic.o"
    "$RANLIB" "$quic_build/libspicequic.a"

    /usr/bin/libtool -static -o "$arch_dir/libCUSBRedir.a" \
        "$usbredir_build/libusbredir.a" "$prefix/libusb/lib/libusb-1.0.a"
    cp "$prefix/jpeg/lib/libturbojpeg.a" "$arch_dir/libCTurboJPEG.a"
    cp "$quic_build/libspicequic.a" "$arch_dir/libCSpiceQUIC.a"

artifact_stage="$WORK_DIR/artifacts"
mkdir -p "$artifact_stage/CTurboJPEG/Headers" \
    "$artifact_stage/CSpiceQUIC/Headers" \
    "$artifact_stage/CUSBRedir/Headers"

cp "$WORK_DIR/build/arm64/libCTurboJPEG.a" \
    "$artifact_stage/CTurboJPEG/libCTurboJPEG.a"
cp "$ROOT_DIR/Sources/CTurboJPEG/shim.h" "$artifact_stage/CTurboJPEG/Headers/"
cp "$WORK_DIR/src/libjpeg-turbo-$JPEG_VERSION/src/turbojpeg.h" "$artifact_stage/CTurboJPEG/Headers/"
write_module_map "$artifact_stage/CTurboJPEG/Headers" CTurboJPEG shim.h

cp "$WORK_DIR/build/arm64/libCSpiceQUIC.a" \
    "$artifact_stage/CSpiceQUIC/libCSpiceQUIC.a"
cp "$ROOT_DIR/Sources/CSpiceQUIC/shim.h" "$artifact_stage/CSpiceQUIC/Headers/"
write_module_map "$artifact_stage/CSpiceQUIC/Headers" CSpiceQUIC shim.h

cp "$WORK_DIR/build/arm64/libCUSBRedir.a" \
    "$artifact_stage/CUSBRedir/libCUSBRedir.a"
cp "$WORK_DIR/src/usbredir-$USBREDIR_VERSION/usbredirhost/usbredirhost.h" \
    "$WORK_DIR/src/usbredir-$USBREDIR_VERSION/usbredirparser/usbredirfilter.h" \
    "$WORK_DIR/src/usbredir-$USBREDIR_VERSION/usbredirparser/usbredirparser.h" \
    "$WORK_DIR/src/usbredir-$USBREDIR_VERSION/usbredirparser/usbredirproto.h" \
    "$WORK_DIR/build/arm64/prefix/libusb/include/libusb-1.0/libusb.h" \
    "$artifact_stage/CUSBRedir/Headers/"
write_module_map "$artifact_stage/CUSBRedir/Headers" CUSBRedir usbredirhost.h

mkdir -p "$OUTPUT_DIR"
for module in CTurboJPEG CSpiceQUIC CUSBRedir; do
    rm -rf "$OUTPUT_DIR/$module.xcframework"
    xcodebuild -create-xcframework \
        -library "$artifact_stage/$module/lib$module.a" \
        -headers "$artifact_stage/$module/Headers" \
        -output "$OUTPUT_DIR/$module.xcframework"
done

mkdir -p "$OUTPUT_DIR/CTurboJPEG.xcframework/Licenses" \
    "$OUTPUT_DIR/CSpiceQUIC.xcframework/Licenses" \
    "$OUTPUT_DIR/CUSBRedir.xcframework/Licenses"
cp "$WORK_DIR/src/libjpeg-turbo-$JPEG_VERSION/LICENSE.md" \
    "$OUTPUT_DIR/CTurboJPEG.xcframework/Licenses/libjpeg-turbo-LICENSE.md"
cp "$WORK_DIR/src/spice-gtk-$SPICE_GTK_VERSION/subprojects/spice-common/COPYING" \
    "$OUTPUT_DIR/CSpiceQUIC.xcframework/Licenses/spice-common-COPYING"
cp "$WORK_DIR/src/usbredir-$USBREDIR_VERSION/COPYING.LIB" \
    "$OUTPUT_DIR/CUSBRedir.xcframework/Licenses/usbredir-COPYING.LIB"
cp "$WORK_DIR/src/libusb-$LIBUSB_VERSION/COPYING" \
    "$OUTPUT_DIR/CUSBRedir.xcframework/Licenses/libusb-COPYING"

"$ROOT_DIR/Scripts/verify-native-closure.sh" --artifacts-only
echo "Native dependency artifacts rebuilt in $OUTPUT_DIR"
