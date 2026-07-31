#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="SpiceViewer"
PRODUCT_NAME="spice-viewer"
BUNDLE_ID="com.beribeli.SpiceViewer"
MIN_SYSTEM_VERSION="26.0"
BUILD_CONFIGURATION="debug"
if [[ "$MODE" == "package" || "$MODE" == "--package" ]]; then
  BUILD_CONFIGURATION="release"
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"

if [[ "$MODE" != "--stage" && "$MODE" != "stage" ]]; then
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
fi

cd "$ROOT_DIR"
mkdir -p "$ROOT_DIR/.build/module-cache"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$ROOT_DIR/.build/module-cache}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-$ROOT_DIR/.build/module-cache}"
if [[ "$BUILD_CONFIGURATION" == "release" ]]; then
  ARM64_SCRATCH="$ROOT_DIR/.build/release-arm64"
  X86_64_SCRATCH="$ROOT_DIR/.build/release-x86_64"
  UNIVERSAL_DIR="$ROOT_DIR/.build/release-universal"
  swift build --disable-sandbox -c release --triple arm64-apple-macosx26.0 \
    --scratch-path "$ARM64_SCRATCH" --product "$PRODUCT_NAME"
  swift build --disable-sandbox -c release --triple x86_64-apple-macosx26.0 \
    --scratch-path "$X86_64_SCRATCH" --product "$PRODUCT_NAME"
  ARM64_BINARY="$(swift build --disable-sandbox -c release --triple arm64-apple-macosx26.0 \
    --scratch-path "$ARM64_SCRATCH" --show-bin-path)/$PRODUCT_NAME"
  X86_64_BINARY="$(swift build --disable-sandbox -c release --triple x86_64-apple-macosx26.0 \
    --scratch-path "$X86_64_SCRATCH" --show-bin-path)/$PRODUCT_NAME"
  mkdir -p "$UNIVERSAL_DIR"
  lipo -create "$ARM64_BINARY" "$X86_64_BINARY" -output "$UNIVERSAL_DIR/$PRODUCT_NAME"
  BUILD_BINARY="$UNIVERSAL_DIR/$PRODUCT_NAME"
else
  swift build --disable-sandbox -c "$BUILD_CONFIGURATION" --product "$PRODUCT_NAME"
  BUILD_BINARY="$(swift build --disable-sandbox -c "$BUILD_CONFIGURATION" --show-bin-path)/$PRODUCT_NAME"
fi

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>SpiceViewer uses the microphone only after you enable it for a connected SPICE Record Channel.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP_BUNDLE"
"$ROOT_DIR/Scripts/verify-native-closure.sh"

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  --stage|stage)
    echo "$APP_BUNDLE"
    ;;
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    "$ROOT_DIR/Scripts/verify-native-closure.sh"
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  --package|package)
    "$ROOT_DIR/Scripts/verify-native-closure.sh"
    echo "$APP_BUNDLE"
    ;;
  *)
    echo "usage: $0 [--stage|run|--debug|--logs|--telemetry|--verify|--package]" >&2
    exit 2
    ;;
esac
