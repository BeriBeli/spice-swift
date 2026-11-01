#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "$#" -gt 1 || ( "$#" -eq 1 && "$1" != "--artifacts-only" ) ]]; then
    echo "usage: verify-native-closure.sh [--artifacts-only]" >&2
    exit 2
fi

fail=0
check_macho() {
    local binary="$1"
    local architectures
    local file_kind
    file_kind="$(file "$binary")"
    # Static archives have no dyld load commands, but release inputs must still
    # be Apple Silicon-only so an Intel slice cannot re-enter the product.
    # A static framework's executable has no .a suffix, so inspect its file kind.
    if [[ "$binary" == *.a || "$file_kind" == *"current ar archive"* ]]; then
        local archive_architectures
        archive_architectures="$(lipo -archs "$binary" 2>/dev/null || true)"
        if [[ "$archive_architectures" != "arm64" ]]; then
            echo "error: expected an arm64-only static archive, got '$archive_architectures': $binary" >&2
            fail=1
        fi
        return
    fi
    if [[ "$file_kind" != *"Mach-O"* ]]; then
        return
    fi
    architectures="$(lipo -archs "$binary" 2>/dev/null || true)"
    if [[ "$architectures" != "arm64" ]]; then
        echo "error: expected an arm64-only Mach-O, got '$architectures': $binary" >&2
        fail=1
    fi
}

while IFS= read -r -d '' artifact; do
    check_macho "$artifact"
done < <(find "$ROOT_DIR/Artifacts" -type f -print0 2>/dev/null)
# These are the exact-quality decode kernels used by our arm64 JPEG/MJPEG
# boundary. Prevent a scalar-only rebuild from silently replacing the artifact.
jpeg_archive="$ROOT_DIR/Artifacts/CTurboJPEG.xcframework/macos-arm64/CTurboJPEG.framework/Versions/A/CTurboJPEG"
jpeg_symbols="$(nm -gUj "$jpeg_archive")"
for module in CTurboJPEG CSpiceQUIC; do
    archive="$ROOT_DIR/Artifacts/$module.xcframework/macos-arm64/$module.framework/Versions/A/$module"
    provenance="$ROOT_DIR/Artifacts/$module.xcframework/BUILD_PROVENANCE.txt"
    expected_hash="$(awk '/^Archive SHA-256: / {print $3}' "$provenance")"
    actual_hash="$(shasum -a 256 "$archive" | awk '{print $1}')"
    if [[ "$expected_hash" != "$actual_hash" ]]; then
        echo "error: $module archive does not match its build provenance" >&2
        fail=1
    fi
done
quic_archive="$ROOT_DIR/Artifacts/CSpiceQUIC.xcframework/macos-arm64/CSpiceQUIC.framework/Versions/A/CSpiceQUIC"
quic_provenance="$ROOT_DIR/Artifacts/CSpiceQUIC.xcframework/BUILD_PROVENANCE.txt"
quic_symbols="$(nm -gUj "$quic_archive")"
for symbol in _quic_create _quic_destroy _quic_encode _quic_decode_begin _quic_decode; do
    if ! /usr/bin/grep -qx "$symbol" <<<"$quic_symbols"; then
        echo "error: missing QUIC ABI/implementation symbol: $symbol" >&2
        fail=1
    fi
done
if /usr/bin/grep -Eq '^_(zig_quic_|spice_quic_zig_)' <<<"$quic_symbols"; then
    echo "error: Zig QUIC implementation leaked into the spice-gtk artifact" >&2
    fail=1
fi
source_count=0
while read -r expected_hash source; do
    source_count=$((source_count + 1))
    actual_hash="$(shasum -a 256 "$ROOT_DIR/$source" | awk '{print $1}')"
    if [[ "$expected_hash" != "$actual_hash" ]]; then
        echo "error: QUIC artifact source changed; rebuild with Scripts/build-quic-native.sh: $source" >&2
        fail=1
    fi
done < <(awk '/^Owned source SHA-256: / {print $4, $5}' "$quic_provenance")
if [[ "$source_count" -ne 3 ]]; then
    echo "error: incomplete QUIC source provenance" >&2
    fail=1
fi
for header in shim.h quic.h; do
    if ! cmp -s "$ROOT_DIR/Sources/CSpiceQUIC/$header" \
        "$ROOT_DIR/Artifacts/CSpiceQUIC.xcframework/macos-arm64/CSpiceQUIC.framework/Versions/A/Headers/$header"; then
        echo "error: stale QUIC artifact header: $header" >&2
        fail=1
    fi
done
if ! /usr/bin/grep -qx 'Implementation: spice-gtk 0.42 / spice-common QUIC C codec; unchanged upstream algorithm' "$quic_provenance"; then
    echo "error: QUIC artifact must use the pinned spice-gtk C implementation" >&2
    fail=1
fi
for symbol in _jsimd_idct_islow_neon _jsimd_h2v2_fancy_upsample_neon _jsimd_ycc_extbgrx_convert_neon; do
    if ! /usr/bin/grep -qx "$symbol" <<<"$jpeg_symbols"; then
        echo "error: missing JPEG Neon kernel: $symbol" >&2
        fail=1
    fi
done
"$ROOT_DIR/Scripts/audit-dylib-links.sh" "$ROOT_DIR/Artifacts"

if [[ "$fail" -ne 0 ]]; then
    exit 1
fi
echo "Relocatable native artifact closure verified"
