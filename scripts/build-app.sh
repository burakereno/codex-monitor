#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/.build/Codex Monitor.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
APP_ICON="$ROOT_DIR/Sources/CodexMonitor/Resources/AppIcon.icns"

cd "$ROOT_DIR"

REMOTE_LATEST_TAG="$(git ls-remote --tags --refs origin 'v*' 2>/dev/null | awk '{ sub("refs/tags/", "", $2); print $2 }' | sort -Vr | head -1)"
LOCAL_LATEST_TAG="$(git tag -l 'v*' --sort=-v:refname | head -1)"
LATEST_TAG="${REMOTE_LATEST_TAG:-$LOCAL_LATEST_TAG}"
DEFAULT_APP_VERSION="${LATEST_TAG#v}"
if [[ -z "$LATEST_TAG" || "$DEFAULT_APP_VERSION" == "$LATEST_TAG" ]]; then
  DEFAULT_APP_VERSION="0.1.0"
fi
DEFAULT_BUILD_NUMBER="$(echo "$DEFAULT_APP_VERSION" | awk -F. '{print $3}')"
APP_VERSION="${APP_VERSION:-$DEFAULT_APP_VERSION}"
APP_BUILD_NUMBER="${APP_BUILD_NUMBER:-${DEFAULT_BUILD_NUMBER:-1}}"
MIN_MACOS_VERSION="${MIN_MACOS_VERSION:-14.0}"
BUNDLE_IDENTIFIER="${BUNDLE_IDENTIFIER:-dev.local.CodexMonitor.local}"

rm -rf "$ROOT_DIR/.build/release/CodexMonitor_CodexMonitor.bundle"
swift build -c release

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$ROOT_DIR/.build/release/CodexMonitor" "$MACOS_DIR/CodexMonitor"

RESOURCE_BUNDLE="$ROOT_DIR/.build/release/CodexMonitor_CodexMonitor.bundle"
if [[ -d "$RESOURCE_BUNDLE" ]]; then
  cp -R "$RESOURCE_BUNDLE" "$APP_DIR/"
fi
if [[ -f "$APP_ICON" ]]; then
  cp "$APP_ICON" "$RESOURCES_DIR/AppIcon.icns"
fi

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>CodexMonitor</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_IDENTIFIER</string>
  <key>CFBundleName</key>
  <string>Codex Monitor</string>
  <key>CFBundleDisplayName</key>
  <string>Codex Monitor</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIconName</key>
  <string>AppIcon</string>
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
