#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${1:-$ROOT_DIR/.build/Codex Monitor.app}"
APP_BUNDLE_NAME="$(basename "$APP_PATH")"
APP_DISPLAY_NAME="${APP_BUNDLE_NAME%.app}"
OUTPUT_DMG="${2:-$ROOT_DIR/CodexMonitor.dmg}"

VOLUME_NAME="${VOLUME_NAME:-Codex Monitor}"
DMG_TITLE="${DMG_TITLE:-Codex Monitor, built for}"
DMG_SUBTITLE="${DMG_SUBTITLE:-Codex usage tracking}"
DMG_HINT="${DMG_HINT:-Drag Codex Monitor to Applications}"

WINDOW_WIDTH="${WINDOW_WIDTH:-760}"
WINDOW_HEIGHT="${WINDOW_HEIGHT:-610}"
BACKGROUND_WIDTH="${BACKGROUND_WIDTH:-$WINDOW_WIDTH}"
BACKGROUND_HEIGHT="${BACKGROUND_HEIGHT:-$WINDOW_HEIGHT}"
ICON_SIZE="${ICON_SIZE:-128}"
APP_X="${APP_X:-245}"
APP_Y="${APP_Y:-300}"
APPLICATIONS_X="${APPLICATIONS_X:-515}"
APPLICATIONS_Y="${APPLICATIONS_Y:-300}"

TITLE_Y="${TITLE_Y:-474}"
SUBTITLE_Y="${SUBTITLE_Y:-435}"
HINT_Y="${HINT_Y:-154}"
GRID_X_LEFT="${GRID_X_LEFT:-120}"
GRID_X_RIGHT="${GRID_X_RIGHT:-640}"
GRID_Y_LOWER="${GRID_Y_LOWER:-210}"
GRID_Y_UPPER="${GRID_Y_UPPER:-410}"

if [[ ! -d "$APP_PATH" ]]; then
  echo "App bundle not found: $APP_PATH" >&2
  exit 1
fi

WORK_DIR="$(mktemp -d)"
STAGING_DIR="$WORK_DIR/staging"
BACKGROUND_DIR="$STAGING_DIR/.background"
BACKGROUND_PATH="$BACKGROUND_DIR/background.png"
RW_DMG="$WORK_DIR/$VOLUME_NAME.rw.dmg"
MOUNT_DIR="$WORK_DIR/mount"
BACKGROUND_SCRIPT="$WORK_DIR/make-dmg-background.swift"
MOUNTED=0

cleanup() {
  if [[ "$MOUNTED" == "1" ]]; then
    hdiutil detach "$MOUNT_DIR" -quiet -force >/dev/null 2>&1 || true
  fi
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

mkdir -p "$BACKGROUND_DIR" "$MOUNT_DIR"
cp -R "$APP_PATH" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"

cat > "$BACKGROUND_SCRIPT" <<'SWIFT'
import AppKit
import Foundation

let args = CommandLine.arguments
let outputPath = args[1]
let width = CGFloat(Double(args[2]) ?? 760)
let height = CGFloat(Double(args[3]) ?? 610)
let title = args[4]
let subtitle = args[5]
let hint = args[6]
let titleY = CGFloat(Double(args[7]) ?? 474)
let subtitleY = CGFloat(Double(args[8]) ?? 435)
let hintY = CGFloat(Double(args[9]) ?? 154)
let gridXLeft = CGFloat(Double(args[10]) ?? 120)
let gridXRight = CGFloat(Double(args[11]) ?? 640)
let gridYLower = CGFloat(Double(args[12]) ?? 210)
let gridYUpper = CGFloat(Double(args[13]) ?? 410)

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(calibratedRed: red / 255, green: green / 255, blue: blue / 255, alpha: alpha)
}

let image = NSImage(size: NSSize(width: width, height: height))
image.lockFocus()

color(247, 248, 246).setFill()
NSBezierPath(rect: NSRect(x: 0, y: 0, width: width, height: height)).fill()

color(205, 212, 207).setStroke()
let grid = NSBezierPath()
grid.lineWidth = 1
for x in [gridXLeft, gridXRight] {
    grid.move(to: NSPoint(x: x, y: 0))
    grid.line(to: NSPoint(x: x, y: height))
}
for y in [gridYLower, gridYUpper] {
    grid.move(to: NSPoint(x: 0, y: y))
    grid.line(to: NSPoint(x: width, y: y))
}
grid.stroke()

let paragraph = NSMutableParagraphStyle()
paragraph.alignment = .center

let titleAttributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 31, weight: .semibold),
    .foregroundColor: color(42, 45, 52),
    .paragraphStyle: paragraph
]
let subtitleAttributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 31, weight: .semibold),
    .foregroundColor: color(101, 111, 124),
    .paragraphStyle: paragraph
]
let hintAttributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 15, weight: .medium),
    .foregroundColor: color(137, 124, 113),
    .paragraphStyle: paragraph
]

title.draw(in: NSRect(x: 0, y: titleY, width: width, height: 42), withAttributes: titleAttributes)
subtitle.draw(in: NSRect(x: 0, y: subtitleY, width: width, height: 42), withAttributes: subtitleAttributes)
hint.draw(in: NSRect(x: 0, y: hintY, width: width, height: 24), withAttributes: hintAttributes)

image.unlockFocus()

guard
    let tiff = image.tiffRepresentation,
    let bitmap = NSBitmapImageRep(data: tiff),
    let png = bitmap.representation(using: .png, properties: [:])
else {
    fputs("Could not render DMG background\n", stderr)
    exit(1)
}

try png.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
SWIFT

xcrun swift "$BACKGROUND_SCRIPT" \
  "$BACKGROUND_PATH" \
  "$BACKGROUND_WIDTH" \
  "$BACKGROUND_HEIGHT" \
  "$DMG_TITLE" \
  "$DMG_SUBTITLE" \
  "$DMG_HINT" \
  "$TITLE_Y" \
  "$SUBTITLE_Y" \
  "$HINT_Y" \
  "$GRID_X_LEFT" \
  "$GRID_X_RIGHT" \
  "$GRID_Y_LOWER" \
  "$GRID_Y_UPPER"

rm -f "$OUTPUT_DMG"
hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGING_DIR" \
  -format UDRW \
  -fs HFS+ \
  -ov \
  "$RW_DMG" >/dev/null

hdiutil attach "$RW_DMG" \
  -readwrite \
  -noverify \
  -noautoopen \
  -mountpoint "$MOUNT_DIR" >/dev/null
MOUNTED=1

/usr/bin/SetFile -a V "$MOUNT_DIR/.background" >/dev/null 2>&1 || true
/usr/bin/SetFile -a V "$MOUNT_DIR/Applications" >/dev/null 2>&1 || true

osascript <<APPLESCRIPT
tell application "Finder"
  set dmgFolder to POSIX file "$MOUNT_DIR" as alias
  open dmgFolder
  delay 1
  set current view of container window of dmgFolder to icon view
  set toolbar visible of container window of dmgFolder to false
  set statusbar visible of container window of dmgFolder to false
  set bounds of container window of dmgFolder to {100, 100, 100 + $WINDOW_WIDTH, 100 + $WINDOW_HEIGHT}
  set theViewOptions to the icon view options of container window of dmgFolder
  set arrangement of theViewOptions to not arranged
  set icon size of theViewOptions to $ICON_SIZE
  set label position of theViewOptions to bottom
  set background picture of theViewOptions to file ".background:background.png" of dmgFolder
  set position of item "$APP_BUNDLE_NAME" of dmgFolder to {$APP_X, $APP_Y}
  set position of item "Applications" of dmgFolder to {$APPLICATIONS_X, $APPLICATIONS_Y}
  update dmgFolder without registering applications
  delay 1
  close container window of dmgFolder
end tell
APPLESCRIPT

sync
hdiutil detach "$MOUNT_DIR" -quiet -force >/dev/null
MOUNTED=0

hdiutil convert "$RW_DMG" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -o "$OUTPUT_DMG" >/dev/null

echo "Created $OUTPUT_DMG"
