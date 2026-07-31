#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 1 ]]; then
    echo "usage: $0 APP_BUNDLE" >&2
    exit 2
fi

APP_BUNDLE="$1"
FRAMEWORKS_DIR="$APP_BUNDLE/Contents/Frameworks"
failed=false
found_macho=false

while IFS= read -r candidate; do
    if ! file "$candidate" | grep -q 'Mach-O'; then
        continue
    fi
    found_macho=true

    while IFS= read -r dependency; do
        case "$dependency" in
            /System/Library/*|/usr/lib/*|@loader_path/*|@executable_path/*)
                ;;
            @rpath/*)
                relative_path="${dependency#@rpath/}"
                if [[ ! -f "$FRAMEWORKS_DIR/$relative_path" ]]; then
                    echo "$candidate has unresolved dependency $dependency" >&2
                    failed=true
                fi
                ;;
            /*)
                echo "$candidate has absolute non-system dependency $dependency" >&2
                failed=true
                ;;
            *)
                echo "$candidate has unsupported dependency $dependency" >&2
                failed=true
                ;;
        esac
    done < <(otool -L "$candidate" | awk 'NR > 1 { print $1 }')

    while IFS= read -r rpath; do
        case "$rpath" in
            /System/Library/*|/usr/lib/*|@*)
                ;;
            /*)
                echo "$candidate has absolute non-system runtime path $rpath" >&2
                failed=true
                ;;
        esac
    done < <(
        otool -l "$candidate" \
            | awk '$1 == "cmd" && $2 == "LC_RPATH" { getline; getline; print $2 }'
    )
done < <(find "$APP_BUNDLE" -type f -print)

if [[ "$found_macho" != true ]]; then
    echo "no Mach-O files found in $APP_BUNDLE" >&2
    exit 1
fi
if [[ "$failed" == true ]]; then
    exit 1
fi

echo "relocatable Mach-O verification passed: $APP_BUNDLE"
