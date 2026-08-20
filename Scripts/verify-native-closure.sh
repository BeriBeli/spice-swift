#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-}"
METAL_RESOURCE_BUNDLE="SwiftSpice_SpiceMetalCompositor.bundle"
METAL_LIBRARY_NAME="SpiceVideoCompositor.metallib"

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
    local load_path
    # Only indented lines are load commands. Fat Mach-O output repeats the
    # inspected file path once per architecture.
    while IFS= read -r load_path; do
        case "$load_path" in
            /System/Library/*|/usr/lib/*|@rpath/*|@loader_path/*|@executable_path/*)
                ;;
            *)
                echo "error: disallowed load path '$load_path' in $binary" >&2
                fail=1
                ;;
        esac
    done < <(otool -L "$binary" | awk '/^\t/{print $1}')

    while IFS= read -r load_path; do
        case "$load_path" in
            @rpath|@rpath/*|@loader_path|@loader_path/*|@executable_path|@executable_path/*)
                ;;
            *)
                echo "error: non-relocatable LC_RPATH '$load_path' in $binary" >&2
                fail=1
                ;;
        esac
    done < <(otool -l "$binary" | awk '/cmd LC_RPATH/{capture=1; next} capture && /path /{print $2; capture=0}')
}

check_release_app() {
    local app_bundle="$1"
    local executable="$app_bundle/Contents/MacOS/SpiceViewer"
    local metal_library="$app_bundle/Contents/Resources/$METAL_RESOURCE_BUNDLE/$METAL_LIBRARY_NAME"
    local architectures minimum_versions minimum_version

    if [[ ! -f "$executable" ]]; then
        echo "error: app executable not found: $executable" >&2
        fail=1
        return
    fi
    if [[ ! -f "$metal_library" ]]; then
        echo "error: staged Metal library not found: $metal_library" >&2
        fail=1
        return
    fi

    architectures="$(lipo -archs "$executable" 2>/dev/null || true)"
    if [[ "$architectures" != "arm64" ]]; then
        echo "error: expected an Apple Silicon-only arm64 app slice, got: $architectures" >&2
        fail=1
    fi

    minimum_versions="$(
        otool -l "$executable" \
            | awk '/cmd LC_BUILD_VERSION/{capture=1; next} capture && /minos /{print $2; capture=0}'
    )"
    if [[ -z "$minimum_versions" ]]; then
        echo "error: app executable has no LC_BUILD_VERSION minimum OS" >&2
        fail=1
    fi
    while IFS= read -r minimum_version; do
        if ! awk -F. -v version="$minimum_version" 'BEGIN {
            split(version, parts, ".")
            exit !((parts[1] + 0) >= 26)
        }'; then
            echo "error: app slice has pre-macOS-26 minimum: $minimum_version" >&2
            fail=1
        fi
    done <<<"$minimum_versions"

    if ! strings "$metal_library" | grep -Fqx 'spice_nv12_to_bgra'; then
        echo "error: staged Metal library lacks spice_nv12_to_bgra" >&2
        fail=1
    fi

    if strings "$executable" "$metal_library" \
        | grep -E -q '/Users/|/opt/homebrew|/usr/local/(Cellar|Homebrew)'; then
        echo "error: staged release embeds an absolute build or Homebrew path" >&2
        fail=1
    fi
}

while IFS= read -r -d '' artifact; do
    check_macho "$artifact"
done < <(find "$ROOT_DIR/Artifacts" -type f -print0 2>/dev/null)

if [[ "$MODE" != "--artifacts-only" ]]; then
    APP_BUNDLE="${SWIFTSPICE_APP_BUNDLE:-$ROOT_DIR/dist/SpiceViewer.app}"
    if [[ ! -d "$APP_BUNDLE" ]]; then
        echo "error: app bundle not found: $APP_BUNDLE" >&2
        exit 1
    fi
    while IFS= read -r -d '' bundled_file; do
        check_macho "$bundled_file"
    done < <(find "$APP_BUNDLE/Contents" -type f -print0)
    check_release_app "$APP_BUNDLE"
    codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
fi

if [[ "$fail" -ne 0 ]]; then
    exit 1
fi
echo "Relocatable native dependency closure verified"
