#!/usr/bin/env bash
# Build only the unchanged spice-common QUIC codec shipped in spice-gtk 0.42.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
[[ "$#" -eq 0 ]] || { echo "usage: build-quic-native.sh" >&2; exit 2; }
mkdir -p "$ROOT_DIR/.build"
WORK_DIR="${SWIFTSPICE_NATIVE_WORK_DIR:-$(mktemp -d "$ROOT_DIR/.build/quic-native.XXXXXX")}"
cleanup() {
    if [[ -z "${SWIFTSPICE_NATIVE_WORK_DIR:-}" ]]; then rm -rf "$WORK_DIR"; fi
}
trap cleanup EXIT
DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-26.0}"
CLANG="$(xcrun --sdk macosx --find clang)"
SOURCE="$ROOT_DIR/Sources/CSpiceQUIC"
SPICE_GTK_VERSION="0.42"
SPICE_GTK_ARCHIVE="spice-gtk-$SPICE_GTK_VERSION.tar.xz"
SPICE_GTK_URL="https://www.spice-space.org/download/gtk/$SPICE_GTK_ARCHIVE"
SPICE_GTK_SHA256="9380117f1811ad1faa1812cb6602479b6290d4a0d8cc442d44427f7f6c0e7a58"
mkdir -p "$WORK_DIR/downloads" "$WORK_DIR/src" "$WORK_DIR/quic/spice"
ARCHIVE="$WORK_DIR/downloads/$SPICE_GTK_ARCHIVE"
if [[ ! -f "$ARCHIVE" ]]; then
    curl -fL --retry 3 -o "$ARCHIVE.download" "$SPICE_GTK_URL"
    mv "$ARCHIVE.download" "$ARCHIVE"
fi
[[ "$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')" == "$SPICE_GTK_SHA256" ]] || {
    echo "error: SHA-256 mismatch for $SPICE_GTK_ARCHIVE" >&2; exit 1;
}
tar -xf "$ARCHIVE" -C "$WORK_DIR/src"
UPSTREAM="$WORK_DIR/src/spice-gtk-$SPICE_GTK_VERSION/subprojects/spice-common"
QUIC_SOURCE="$WORK_DIR/quic"
cp "$UPSTREAM/common/quic.c" "$UPSTREAM/common/quic_tmpl.c" \
    "$UPSTREAM/common/quic_family_tmpl.c" "$QUIC_SOURCE/"
# Supply the platform macros used by the standalone codec; retain the upstream
# algorithm and the package's existing public C ABI without linking GTK/GLib.
cp "$SOURCE/quic.h" "$QUIC_SOURCE/"
cat > "$QUIC_SOURCE/log.h" <<'HEADER'
#pragma once
#include <assert.h>
#define SPICE_VERIFY(value) _Static_assert((value), "SPICE verification failed")
#define spice_assert(value) assert(value)
#define spice_extra_assert(value) assert(value)
#define spice_return_if_fail(value) do { if (!(value)) return; } while (0)
#define spice_warn_if_reached() ((void)0)
#define G_UNLIKELY(value) __builtin_expect(!!(value), 0)
#define SPICE_ATTR_PACKED __attribute__((packed))
#define SPICE_GNUC_UNUSED __attribute__((unused))
#define SPICE_CONSTRUCTOR_FUNC(name) static void __attribute__((constructor)) name(void)
#define GUINT32_TO_LE(value) (value)
#define GUINT32_FROM_LE(value) (value)
#define TRUE 1
#define FALSE 0
#if __BYTE_ORDER__ != __ORDER_LITTLE_ENDIAN__
#error This platform adapter requires a little-endian host
#endif
HEADER
cat > "$QUIC_SOURCE/quic_config.h" <<'HEADER'
#pragma once
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#define SPICE_BEGIN_DECLS
#define SPICE_END_DECLS
#define MEMCLEAR(pointer, size) memset((pointer), 0, (size))
HEADER
printf '%s\n' '#define ENABLE_EXTRA_CHECKS 0' > "$QUIC_SOURCE/config.h"
printf '%s\n' '#pragma pack(push, 1)' > "$QUIC_SOURCE/spice/start-packed.h"
printf '%s\n' '#pragma pack(pop)' > "$QUIC_SOURCE/spice/end-packed.h"
"$CLANG" -c "$QUIC_SOURCE/quic.c" -o "$WORK_DIR/quic.o" \
    -std=c11 -O2 -DNDEBUG -arch arm64 -I "$QUIC_SOURCE" \
    -isysroot "$(xcrun --sdk macosx --show-sdk-path)" \
    -mmacosx-version-min="$DEPLOYMENT_TARGET"
FRAMEWORK="$WORK_DIR/CSpiceQUIC.framework"
VERSION="$FRAMEWORK/Versions/A"
rm -rf "$FRAMEWORK"
mkdir -p "$VERSION/Headers" "$VERSION/Modules" "$VERSION/Resources"
ZERO_AR_DATE=1 /usr/bin/libtool -static -D -o "$VERSION/CSpiceQUIC" \
    "$WORK_DIR/quic.o"
cp "$SOURCE/shim.h" "$SOURCE/quic.h" "$VERSION/Headers/"
printf '%s\n' 'framework module CSpiceQUIC {' '  header "shim.h"' '  header "quic.h"' '  export *' '}' \
    > "$VERSION/Modules/module.modulemap"
INFO="$VERSION/Resources/Info.plist"
plutil -create xml1 "$INFO"
plutil -insert CFBundleDevelopmentRegion -string en "$INFO"
plutil -insert CFBundleExecutable -string CSpiceQUIC "$INFO"
plutil -insert CFBundleIdentifier -string com.beribeli.SwiftSpice.CSpiceQUIC "$INFO"
plutil -insert CFBundleInfoDictionaryVersion -string 6.0 "$INFO"
plutil -insert CFBundleName -string CSpiceQUIC "$INFO"
plutil -insert CFBundlePackageType -string FMWK "$INFO"
plutil -insert CFBundleShortVersionString -string 1.0 "$INFO"
plutil -insert CFBundleVersion -string 1 "$INFO"
plutil -insert MinimumOSVersion -string "$DEPLOYMENT_TARGET" "$INFO"
ln -s A "$FRAMEWORK/Versions/Current"
for item in CSpiceQUIC Headers Modules Resources; do
    ln -s "Versions/Current/$item" "$FRAMEWORK/$item"
done
STAGED="$WORK_DIR/CSpiceQUIC.xcframework"
rm -rf "$STAGED"
xcodebuild -create-xcframework -framework "$FRAMEWORK" -output "$STAGED"
mkdir -p "$STAGED/Licenses"
cp "$UPSTREAM/COPYING" "$STAGED/Licenses/spice-common-COPYING"
{
    printf '%s\n' \
        'Implementation: spice-gtk 0.42 / spice-common QUIC C codec; unchanged upstream algorithm' \
        "Source: $SPICE_GTK_URL" \
        "Upstream archive SHA-256: $SPICE_GTK_SHA256"
    printf 'Configuration: C11 -O2 -DNDEBUG; arm64; macOS=%s; deterministic archive; standalone platform macros; no GTK or GLib linkage\n' "$DEPLOYMENT_TARGET"
    "$CLANG" --version | head -1
    printf 'macOS SDK: %s\n' "$(xcrun --sdk macosx --show-sdk-version)"
    for source in quic.c quic_tmpl.c quic_family_tmpl.c; do
        hash="$(shasum -a 256 "$UPSTREAM/common/$source" | awk '{print $1}')"
        printf 'Upstream source SHA-256: %s subprojects/spice-common/common/%s\n' "$hash" "$source"
    done
    for source in Sources/CSpiceQUIC/quic.h Sources/CSpiceQUIC/shim.h Scripts/build-quic-native.sh; do
        hash="$(shasum -a 256 "$ROOT_DIR/$source" | awk '{print $1}')"
        printf 'Owned source SHA-256: %s %s\n' "$hash" "$source"
    done
    hash="$(shasum -a 256 "$VERSION/CSpiceQUIC" | awk '{print $1}')"
    printf 'Archive SHA-256: %s\n' "$hash"
} > "$STAGED/BUILD_PROVENANCE.txt"
# Replace only this artifact after a complete successful build/staging.
rm -rf "$ROOT_DIR/Artifacts/CSpiceQUIC.xcframework"
mv "$STAGED" "$ROOT_DIR/Artifacts/CSpiceQUIC.xcframework"
"$ROOT_DIR/Scripts/verify-native-closure.sh" --artifacts-only
