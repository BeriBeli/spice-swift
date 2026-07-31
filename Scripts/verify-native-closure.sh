#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-}"

fail=0
check_macho() {
    local binary="$1"
    # Static archives have no dyld load commands. otool prints their absolute
    # inspection path once per member, which is not linkage and is not embedded.
    if [[ "$binary" == *.a ]]; then
        return
    fi
    if ! file "$binary" | grep -q 'Mach-O'; then
        return
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
    codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
fi

if [[ "$fail" -ne 0 ]]; then
    exit 1
fi
echo "Relocatable native dependency closure verified"
