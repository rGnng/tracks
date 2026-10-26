#!/usr/bin/env bash
# Build Tracks (internal name: Audia) into a double-clickable .app bundle.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"

echo "==> swift build -c $CONFIG"
export AUDIA_MACOS_SDK_VERSION="$(xcrun --show-sdk-version)"
swift build -c "$CONFIG"

BIN=".build/$CONFIG/Audia"
if [[ ! -f "$BIN" ]]; then
  echo "error: binary not found at $BIN" >&2
  exit 1
fi

APP="build/Tracks.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Audia"
if [[ -f Resources/AppIcon.icns ]]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

if [[ -d Assets/AccentColors.xcassets ]]; then
  xcrun actool Assets/AccentColors.xcassets \
    --compile "$APP/Contents/Resources" \
    --platform macosx \
    --minimum-deployment-target 15.0 \
    --output-format human-readable-text \
    --notices --warnings >/dev/null
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Tracks</string>
    <key>CFBundleDisplayName</key>
    <string>Tracks</string>
    <key>CFBundleIdentifier</key>
    <string>com.audia.tracks</string>
    <key>CFBundleExecutable</key>
    <string>Audia</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>NSAccentColorName</key>
    <string>AccentColor</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

# MediaRemote/Now Playing only accepts a fully sealed app bundle. A linker-only
# signature leaves Info.plist unbound and macOS rejects remote media commands.
# Ad-hoc signing is sufficient for the locally built app.
codesign --force --deep --sign - "$APP" >/dev/null

echo "==> Built $APP"
echo "    Run: open $APP"
