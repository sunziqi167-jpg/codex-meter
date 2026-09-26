#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h}"
OUTPUT_DIR="${PROJECT_DIR:h}"
BUILD_DIR="$(mktemp -d /tmp/codex-meter-build.XXXXXX)"
APP_DIR="$BUILD_DIR/Codex Meter.app"
CONTENTS="$APP_DIR/Contents"

cleanup() { rm -rf "$BUILD_DIR" }
trap cleanup EXIT

mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources" "$BUILD_DIR/module-cache"

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
  <key>CFBundleDisplayName</key><string>Codex Meter</string>
  <key>CFBundleExecutable</key><string>CodexMeter</string>
  <key>CFBundleIdentifier</key><string>local.codexmeter.app</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>Codex Meter</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.2</string>
  <key>CFBundleVersion</key><string>3</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

xcrun swiftc \
  -target arm64-apple-macos14.0 \
  -module-cache-path "$BUILD_DIR/module-cache" \
  -O \
  -framework AppKit \
  -framework SwiftUI \
  -framework QuartzCore \
  "$PROJECT_DIR/Sources/main.swift" \
  -o "$CONTENTS/MacOS/CodexMeter"

xattr -cr "$APP_DIR"
codesign --force --sign - "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"
"$CONTENTS/MacOS/CodexMeter" --self-test

rm -rf "$OUTPUT_DIR/Codex Meter.app" "$OUTPUT_DIR/Codex Meter.zip"
ditto --norsrc --noextattr "$APP_DIR" "$OUTPUT_DIR/Codex Meter.app"
xattr -cr "$OUTPUT_DIR/Codex Meter.app"
codesign --force --sign - "$OUTPUT_DIR/Codex Meter.app"
codesign --verify --deep --strict "$OUTPUT_DIR/Codex Meter.app"
ditto -c -k --sequesterRsrc --keepParent "$OUTPUT_DIR/Codex Meter.app" "$OUTPUT_DIR/Codex Meter.zip"

echo "Built: $OUTPUT_DIR/Codex Meter.app"
echo "Packed: $OUTPUT_DIR/Codex Meter.zip"
