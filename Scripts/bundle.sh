#!/usr/bin/env bash
#
# Assemble and ad-hoc sign FSMetrics.app using only the Command Line Tools
# toolchain (no Xcode, no signing identity).
set -euo pipefail

CONFIG=release
PRODUCT=FSMetricsApp
CLI=fsmetrics
APP="build/FSMetrics.app"

# Run from the package root regardless of the caller's working directory.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "==> Building $PRODUCT and $CLI ($CONFIG)"
swift build -c "$CONFIG" --product "$PRODUCT"
swift build -c "$CONFIG" --product "$CLI"
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/$PRODUCT" "$APP/Contents/MacOS/FSMetrics"

# The CLI rides along so the LaunchAgent and headless runs can use the bundled
# copy instead of a SwiftPM build directory. It lives in Resources, not
# MacOS: this filesystem is case-insensitive, so `MacOS/fsmetrics` would
# overwrite `MacOS/FSMetrics`.
cp "$BIN/$CLI" "$APP/Contents/Resources/$CLI"

# Info.plist
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>FSMetrics</string>
  <key>CFBundleDisplayName</key><string>macOS_FSMetrics</string>
  <key>CFBundleIdentifier</key><string>local.fsmetrics</string>
  <key>CFBundleExecutable</key><string>FSMetrics</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>CFBundleIconFile</key><string>AppIcon</string>
</dict></plist>
PLIST
plutil -lint "$APP/Contents/Info.plist"

# Icon (optional, if art exists): build .iconset then:
# iconutil -c icns Assets/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc sign (no identity required) after every binary is in place.
codesign --force --deep --sign - "$APP"
codesign --verify --verbose "$APP"

echo ""
echo "==> Built and signed $ROOT/$APP"
echo "    Launch it with: open $APP"
