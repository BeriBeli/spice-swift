#!/usr/bin/env bash
# Fail when distributable Mach-O files depend on build-host library paths.
set -euo pipefail

target="${1:?usage: audit-dylib-links.sh <Mach-O-or-directory>}"
if [[ ! -e "$target" ]]; then
    echo "error: audit target does not exist: $target" >&2
    exit 2
fi

failures=0
audit_one() {
    local binary="$1"
    local dependency
    local file_kind
    local rpath

    file_kind="$(file -Lb "$binary")"
    [[ "$file_kind" == *"Mach-O"* ]] || return 0

    while IFS= read -r dependency; do
        case "$dependency" in
            /System/Library/*|/usr/lib/*|@rpath/*|@loader_path/*|@executable_path/*)
                ;;
            /opt/homebrew/*|/usr/local/*)
                printf 'error: Homebrew dependency: %s -> %s\n' "$binary" "$dependency" >&2
                failures=$((failures + 1))
                ;;
            /*)
                printf 'error: build-host dependency: %s -> %s\n' "$binary" "$dependency" >&2
                failures=$((failures + 1))
                ;;
            *)
                printf 'error: unsupported dependency path: %s -> %s\n' "$binary" "$dependency" >&2
                failures=$((failures + 1))
                ;;
        esac
    done < <(otool -L "$binary" | awk '/^\t/{print $1}')

    while IFS= read -r rpath; do
        case "$rpath" in
            @rpath|@rpath/*|@loader_path|@loader_path/*|@executable_path|@executable_path/*)
                ;;
            *)
                printf 'error: non-relocatable LC_RPATH: %s -> %s\n' "$binary" "$rpath" >&2
                failures=$((failures + 1))
                ;;
        esac
    done < <(otool -l "$binary" | awk '
        $1 == "cmd" && $2 == "LC_RPATH" { capture = 1; next }
        capture && $1 == "path" { print $2; capture = 0 }
    ')
}

if [[ -d "$target" ]]; then
    while IFS= read -r -d '' candidate; do
        audit_one "$candidate"
    done < <(find "$target" -type f -print0)
else
    audit_one "$target"
fi

if [[ "$failures" -ne 0 ]]; then
    printf 'error: found %d non-relocatable dynamic-library link(s)\n' "$failures" >&2
    exit 1
fi
printf 'Dynamic-library audit passed: %s\n' "$target"
