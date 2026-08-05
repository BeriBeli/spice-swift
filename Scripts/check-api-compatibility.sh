#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASELINE_REF="${1:-v0.1.3}"
ALLOWLIST="$ROOT_DIR/Scripts/api-breakage-allowlist.txt"
TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/swiftspice-api.XXXXXX")"
BASELINE_ROOT="$TEMP_ROOT/baseline"
BASELINE_BUILD="$TEMP_ROOT/baseline-build"
CURRENT_BUILD="$TEMP_ROOT/current-build"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
TARGET_TRIPLE="$(swiftc -print-target-info | sed -n 's/.*"triple"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
DIGESTER="$(xcrun --find swift-api-digester)"

cleanup() {
    case "$TEMP_ROOT" in
        /tmp/swiftspice-api.*|/private/tmp/swiftspice-api.*|"${TMPDIR:-/tmp}"/swiftspice-api.*)
            rm -rf -- "$TEMP_ROOT"
            ;;
    esac
}
trap cleanup EXIT

fail() {
    echo "error: $*" >&2
    exit 1
}

[[ "$(uname -m)" == "arm64" ]] || fail "API compatibility gate requires Apple Silicon"
[[ -n "$TARGET_TRIPLE" ]] || fail "could not determine the Swift target triple"
[[ -f "$ALLOWLIST" ]] || fail "allowlist not found: $ALLOWLIST"
git -C "$ROOT_DIR" rev-parse --verify --quiet "${BASELINE_REF}^{commit}" >/dev/null \
    || fail "baseline ref is unavailable: $BASELINE_REF"

mkdir -p "$BASELINE_ROOT"
git -C "$ROOT_DIR" archive "$BASELINE_REF" | tar -x -C "$BASELINE_ROOT"

build_module() {
    local source_root="$1"
    local scratch_path="$2"
    local log_path="$3"
    if ! (
        cd "$source_root"
        CLANG_MODULE_CACHE_PATH="$TEMP_ROOT/clang-cache" \
        SWIFTPM_MODULECACHE_OVERRIDE="$TEMP_ROOT/swiftpm-cache" \
        swift build --disable-sandbox --scratch-path "$scratch_path" \
            --product SwiftSpice -Xswiftc -warnings-as-errors
    ) >"$log_path" 2>&1; then
        tail -80 "$log_path" >&2
        fail "failed to build SwiftSpice in $source_root"
    fi
}

bin_path() {
    local source_root="$1"
    local scratch_path="$2"
    (
        cd "$source_root"
        swift build --disable-sandbox --scratch-path "$scratch_path" --show-bin-path 2>/dev/null
    )
}

dump_api() {
    local source_root="$1"
    local build_bin="$2"
    local output_path="$3"
    local module_cache="$4"
    "$DIGESTER" -dump-sdk -module SwiftSpice \
        -target "$TARGET_TRIPLE" \
        -sdk "$SDK_PATH" \
        -module-cache-path "$module_cache" \
        -I "$build_bin/Modules" \
        -I "$build_bin/CUSBRedirShim.build" \
        -I "$source_root/Sources/CUSBRedirShim/include" \
        -I "$source_root/Sources/CZlib" \
        -I "$source_root/Artifacts/CSpiceQUIC.xcframework/macos-arm64/Headers" \
        -I "$source_root/Artifacts/CTurboJPEG.xcframework/macos-arm64/Headers" \
        -I "$source_root/Artifacts/CUSBRedir.xcframework/macos-arm64/Headers" \
        -o "$output_path"
    [[ "$(wc -c <"$output_path")" -gt 1000 ]] || fail "API graph is unexpectedly small: $output_path"
    grep -Fq '"name": "SwiftSpice"' "$output_path" || fail "API graph has no SwiftSpice root: $output_path"
}

build_module "$BASELINE_ROOT" "$BASELINE_BUILD" "$TEMP_ROOT/baseline-build.log"
build_module "$ROOT_DIR" "$CURRENT_BUILD" "$TEMP_ROOT/current-build.log"

BASELINE_BIN="$(bin_path "$BASELINE_ROOT" "$BASELINE_BUILD")"
CURRENT_BIN="$(bin_path "$ROOT_DIR" "$CURRENT_BUILD")"
BASELINE_API="$TEMP_ROOT/baseline.json"
CURRENT_API="$TEMP_ROOT/current.json"
dump_api "$BASELINE_ROOT" "$BASELINE_BIN" "$BASELINE_API" "$TEMP_ROOT/baseline-module-cache"
dump_api "$ROOT_DIR" "$CURRENT_BIN" "$CURRENT_API" "$TEMP_ROOT/current-module-cache"

diagnose_api() {
    "$DIGESTER" -diagnose-sdk -module SwiftSpice -print-module \
        -disable-os-checks \
        -target "$TARGET_TRIPLE" \
        -sdk "$SDK_PATH" \
        -module-cache-path "$TEMP_ROOT/diagnose-module-cache" \
        -I "$CURRENT_BIN/Modules" \
        -I "$CURRENT_BIN/CUSBRedirShim.build" \
        -I "$ROOT_DIR/Sources/CUSBRedirShim/include" \
        -I "$ROOT_DIR/Sources/CZlib" \
        -I "$ROOT_DIR/Artifacts/CSpiceQUIC.xcframework/macos-arm64/Headers" \
        -I "$ROOT_DIR/Artifacts/CTurboJPEG.xcframework/macos-arm64/Headers" \
        -I "$ROOT_DIR/Artifacts/CUSBRedir.xcframework/macos-arm64/Headers" \
        -baseline-path "$BASELINE_API" \
        -input-paths "$CURRENT_API" \
        "$@"
}

diagnose_api >"$TEMP_ROOT/diagnostics.txt" 2>&1
grep '^SwiftSpice:' "$TEMP_ROOT/diagnostics.txt" | LC_ALL=C sort >"$TEMP_ROOT/actual.txt" || true
LC_ALL=C sort "$ALLOWLIST" >"$TEMP_ROOT/expected.txt"
# Added enum cases are source-impacting for exhaustive switches, but the
# digester does not classify them as ABI errors. Exact comparison therefore
# rejects both new diagnostics and stale allowlist entries.
if ! diff -u "$TEMP_ROOT/expected.txt" "$TEMP_ROOT/actual.txt"; then
    fail "API diagnostics differ from the reviewed allowlist"
fi
if ! diagnose_api -error-on-abi-breakage -breakage-allowlist-path "$ALLOWLIST" \
    >"$TEMP_ROOT/allowlisted-diagnostics.txt" 2>&1; then
    cat "$TEMP_ROOT/allowlisted-diagnostics.txt" >&2
    fail "swift-api-digester rejected a non-allowlisted API change"
fi

BASELINE_BYTES="$(wc -c <"$BASELINE_API" | tr -d ' ')"
CURRENT_BYTES="$(wc -c <"$CURRENT_API" | tr -d ' ')"
ALLOWLIST_COUNT="$(wc -l <"$ALLOWLIST" | tr -d ' ')"
echo "SwiftSpice API compatibility gate passed: baseline=$BASELINE_REF baseline_bytes=$BASELINE_BYTES current_bytes=$CURRENT_BYTES reviewed_additive_enum_cases=$ALLOWLIST_COUNT"
