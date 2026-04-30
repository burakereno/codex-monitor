#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/.build/CodexStatus.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
APP_VERSION="${APP_VERSION:-0.1.0}"
APP_BUILD_NUMBER="${APP_BUILD_NUMBER:-1}"
MIN_MACOS_VERSION="${MIN_MACOS_VERSION:-13.0}"

cd "$ROOT_DIR"
rm -rf "$ROOT_DIR/.build/release/CodexStatus_CodexStatus.bundle"
swift build -c release

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$ROOT_DIR/.build/release/CodexStatus" "$MACOS_DIR/CodexStatus"

RESOURCE_BUNDLE="$ROOT_DIR/.build/release/CodexStatus_CodexStatus.bundle"
if [[ -d "$RESOURCE_BUNDLE" ]]; then
  cp -R "$RESOURCE_BUNDLE" "$APP_DIR/"
fi

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>CodexStatus</string>
  <key>CFBundleIdentifier</key>
  <string>dev.local.CodexStatus</string>
  <key>CFBundleName</key>
  <string>Token Monitor</string>
  <key>CFBundleDisplayName</key>
  <string>Token Monitor</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$APP_BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_MACOS_VERSION</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

echo "Built $APP_DIR"
