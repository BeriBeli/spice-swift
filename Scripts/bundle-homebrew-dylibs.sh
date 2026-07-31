#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 2 ]]; then
    echo "usage: $0 EXECUTABLE FRAMEWORKS_DIRECTORY" >&2
    exit 2
fi

EXECUTABLE="$1"
FRAMEWORKS_DIR="$2"

if [[ ! -f "$EXECUTABLE" ]]; then
    echo "missing executable: $EXECUTABLE" >&2
    exit 1
fi

HOMEBREW_PREFIX="$(brew --prefix)"
mkdir -p "$FRAMEWORKS_DIR"

queue=("$EXECUTABLE")
processed=()

remove_code_signature() {
    codesign --remove-signature "$1" 2>/dev/null || true
}

runtime_paths() {
    otool -l "$1" \
        | awk '$1 == "cmd" && $2 == "LC_RPATH" { getline; getline; print $2 }'
}

make_runtime_paths_relocatable() {
    local binary="$1"
    local required_path="$2"
    local rpath

    while IFS= read -r rpath; do
        case "$rpath" in
            /System/Library/*|/usr/lib/*|@*)
                ;;
            /*)
                install_name_tool -delete_rpath "$rpath" "$binary"
                ;;
        esac
    done < <(runtime_paths "$binary")

    if ! runtime_paths "$binary" | grep -Fxq "$required_path"; then
        install_name_tool -add_rpath "$required_path" "$binary"
    fi
}

contains_path() {
    local candidate="$1"
    local existing
    for existing in "${processed[@]:-}"; do
        if [[ "$existing" == "$candidate" ]]; then
            return 0
        fi
    done
    return 1
}

enqueue_homebrew_library() {
    local source="$1"
    local name
    local destination
    name="$(basename "$source")"
    destination="$FRAMEWORKS_DIR/$name"

    if [[ ! -f "$destination" ]]; then
        cp -L "$source" "$destination"
        chmod u+w "$destination"
        remove_code_signature "$destination"
        install_name_tool -id "@rpath/$name" "$destination"
        make_runtime_paths_relocatable "$destination" '@loader_path'
        queue+=("$destination")
    fi
}

remove_code_signature "$EXECUTABLE"
make_runtime_paths_relocatable \
    "$EXECUTABLE" '@executable_path/../Frameworks'

while [[ "${#queue[@]}" -gt 0 ]]; do
    owner="${queue[0]}"
    queue=("${queue[@]:1}")
    if contains_path "$owner"; then
        continue
    fi
    processed+=("$owner")

    while IFS= read -r dependency; do
        case "$dependency" in
            /System/Library/*|/usr/lib/*)
                continue
                ;;
            @loader_path/*|@executable_path/*)
                continue
                ;;
            @rpath/*)
                name="${dependency#@rpath/}"
                if [[ ! -f "$FRAMEWORKS_DIR/$name" ]]; then
                    source="$(find -L "$HOMEBREW_PREFIX/opt" \
                        -path "*/lib/$name" -type f -print -quit)"
                    if [[ -z "$source" ]]; then
                        echo "cannot resolve $dependency required by $owner" >&2
                        exit 1
                    fi
                    enqueue_homebrew_library "$source"
                fi
                ;;
            "$HOMEBREW_PREFIX"/*)
                if [[ ! -f "$dependency" ]]; then
                    echo "missing Homebrew dependency: $dependency" >&2
                    exit 1
                fi
                enqueue_homebrew_library "$dependency"
                install_name_tool -change \
                    "$dependency" "@rpath/$(basename "$dependency")" "$owner"
                ;;
            /*)
                echo "refusing to bundle unexpected absolute dependency:" >&2
                echo "  $dependency" >&2
                echo "required by $owner" >&2
                exit 1
                ;;
            *)
                echo "unsupported dependency reference: $dependency" >&2
                exit 1
                ;;
        esac
    done < <(otool -L "$owner" | awk 'NR > 1 { print $1 }')
done
