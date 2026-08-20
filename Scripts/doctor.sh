#!/usr/bin/env bash
# Report whether this checkout is ready to build and test SwiftSpice.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
failures=0

pass() {
    printf '  \033[1;32m✓\033[0m %s\n' "$1"
}

fail() {
    printf '  \033[1;31m✗\033[0m %s\n     ↳ %s\n' "$1" "$2"
    failures=$((failures + 1))
}

printf '\033[1;34m[doctor]\033[0m checking the SwiftSpice build environment\n'

macos_version="$(sw_vers -productVersion 2>/dev/null || true)"
macos_major="${macos_version%%.*}"
if [[ -n "$macos_major" && "$macos_major" -ge 26 ]] 2>/dev/null; then
    pass "macOS $macos_version (26+)"
else
    fail "unsupported macOS ${macos_version:-unknown}" "SwiftSpice requires macOS 26 or later."
fi

architecture="$(uname -m)"
if [[ "$architecture" == "arm64" ]]; then
    pass "Apple Silicon (arm64)"
else
    fail "unsupported architecture $architecture" "SwiftSpice supports Apple Silicon only."
fi

developer_directory="$(xcode-select -p 2>/dev/null || true)"
if [[ "$developer_directory" == */Xcode*.app/Contents/Developer ]]; then
    pass "full Xcode selected ($developer_directory)"
else
    fail "full Xcode not selected" "select an installed Xcode with xcode-select."
fi

swift_line="$(swift --version 2>/dev/null | head -1 || true)"
swift_version="$(printf '%s\n' "$swift_line" | sed -nE 's/.*Swift version ([0-9]+\.[0-9]+).*/\1/p')"
if [[ -n "$swift_version" ]] && awk -v version="$swift_version" 'BEGIN {
    split(version, parts, ".")
    exit !(parts[1] > 6 || (parts[1] == 6 && parts[2] >= 3))
}'; then
    pass "Swift $swift_version (6.3+)"
else
    fail "Swift 6.3+ required (got: ${swift_line:-unknown})" "select Xcode 26.3 or later."
fi

sdk_version="$(xcrun --sdk macosx --show-sdk-version 2>/dev/null || true)"
sdk_major="${sdk_version%%.*}"
if [[ -n "$sdk_major" && "$sdk_major" -ge 26 ]] 2>/dev/null; then
    pass "macOS SDK $sdk_version (26+)"
else
    fail "macOS 26+ SDK not found" "install and select Xcode 26 or later."
fi

metal_path="$(xcrun -f metal 2>/dev/null || true)"
if [[ -x "$metal_path" ]]; then
    pass "Metal toolchain ($metal_path)"
else
    fail "Metal toolchain not found" "run: xcodebuild -downloadComponent MetalToolchain"
fi

missing_tools=()
for tool in file git lipo otool plutil swift xcodebuild xcrun; do
    command -v "$tool" >/dev/null 2>&1 || missing_tools+=("$tool")
done
if [[ "${#missing_tools[@]}" -eq 0 ]]; then
    pass "required command-line tools are available"
else
    fail "missing command-line tools: ${missing_tools[*]}" "install or select full Xcode."
fi

for module in CTurboJPEG CSpiceQUIC CUSBRedir; do
    framework="$ROOT_DIR/Artifacts/$module.xcframework/macos-arm64/$module.framework"
    if [[ -f "$framework/Versions/A/$module" \
        && -f "$framework/Versions/A/Modules/module.modulemap" ]]; then
        pass "$module static XCFramework is present"
    else
        fail "$module artifact is incomplete" "run Scripts/build-native-dependencies.sh."
    fi
done

if "$ROOT_DIR/Scripts/verify-native-closure.sh" --artifacts-only >/dev/null 2>&1; then
    pass "native dependency closure is relocatable and arm64-only"
else
    fail "native dependency closure verification failed" \
        "run Scripts/verify-native-closure.sh --artifacts-only for details."
fi

printf '\n'
if [[ "$failures" -eq 0 ]]; then
    printf '\033[1;32m[doctor] ready for SwiftPM builds\033[0m\n'
else
    printf '\033[1;31m[doctor] %d issue(s) found\033[0m\n' "$failures"
    exit 1
fi
