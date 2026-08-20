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
"$ROOT_DIR/Scripts/audit-dylib-links.sh" "$ROOT_DIR/Artifacts"

if [[ "$fail" -ne 0 ]]; then
    exit 1
fi
echo "Relocatable native artifact closure verified"
