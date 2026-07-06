#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="CodexMonitor"
APP_DIR="$ROOT_DIR/.build/Codex Monitor.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
APP_ICON="$ROOT_DIR/Sources/CodexMonitor/Resources/AppIcon.icns"
APP_RESOURCES="$ROOT_DIR/Sources/CodexMonitor/Resources"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
MIN_MACOS_VERSION="${MIN_MACOS_VERSION:-14.0}"

cd "$ROOT_DIR"

REMOTE_LATEST_TAG="$(git ls-remote --tags --refs origin 'v*' 2>/dev/null | awk '{ sub("refs/tags/", "", $2); print $2 }' | sort -Vr | head -1)"
LOCAL_LATEST_TAG="$(git tag -l 'v*' --sort=-v:refname | head -1)"
LATEST_TAG="${REMOTE_LATEST_TAG:-$LOCAL_LATEST_TAG}"
DEFAULT_APP_VERSION="${LATEST_TAG#v}"
if [[ -z "$LATEST_TAG" || "$DEFAULT_APP_VERSION" == "$LATEST_TAG" ]]; then
  DEFAULT_APP_VERSION="0.1.0"
fi
DEFAULT_BUILD_NUMBER="$(echo "$DEFAULT_APP_VERSION" | awk -F. '{print $3}')"
if [[ -z "$DEFAULT_BUILD_NUMBER" || "$DEFAULT_BUILD_NUMBER" == "0" ]]; then
  DEFAULT_BUILD_NUMBER="1"
fi
APP_VERSION="${APP_VERSION:-$DEFAULT_APP_VERSION}"
APP_BUILD_NUMBER="${APP_BUILD_NUMBER:-${DEFAULT_BUILD_NUMBER:-1}}"
BUNDLE_IDENTIFIER="${BUNDLE_IDENTIFIER:-dev.local.CodexMonitor.local}"

swift build -c release

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$CONTENTS_DIR/Resources"
cp "$ROOT_DIR/.build/release/$APP_NAME" "$MACOS_DIR/$APP_NAME"
chmod +x "$MACOS_DIR/$APP_NAME"

if [[ -d "$APP_RESOURCES" ]]; then
  cp -R "$APP_RESOURCES"/. "$CONTENTS_DIR/Resources/"
fi
if [[ -f "$APP_ICON" ]]; then
  cp "$APP_ICON" "$CONTENTS_DIR/Resources/AppIcon.icns"
fi

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
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
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

CODESIGN_ARGS=(--force --deep --options runtime --sign "$CODESIGN_IDENTITY")
if [[ "$CODESIGN_IDENTITY" != "-" ]]; then
  CODESIGN_ARGS+=(--timestamp)
fi
/usr/bin/codesign "${CODESIGN_ARGS[@]}" "$APP_DIR" >/dev/null

echo "Built $APP_DIR"
