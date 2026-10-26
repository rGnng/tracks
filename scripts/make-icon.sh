#!/usr/bin/env bash
# Regenerate Resources/AppIcon.icns from design/app-icon.png (1024 px source).
set -euo pipefail
cd "$(dirname "$0")/.."

SRC="design/app-icon.png"
DST="Resources/AppIcon.icns"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ICONSET="$TMP/AppIcon.iconset"
mkdir -p "$ICONSET" "Resources"

make_icon() {
  local size="$1"
  local name="$2"
  sips -z "$size" "$size" "$SRC" --out "$ICONSET/$name" >/dev/null
}

make_icon 16   icon_16x16.png
make_icon 32   icon_16x16@2x.png
make_icon 32   icon_32x32.png
make_icon 64   icon_32x32@2x.png
make_icon 128  icon_128x128.png
make_icon 256  icon_128x128@2x.png
make_icon 256  icon_256x256.png
make_icon 512  icon_256x256@2x.png
make_icon 512  icon_512x512.png
make_icon 1024 icon_512x512@2x.png

iconutil -c icns "$ICONSET" -o "$DST"
echo "==> Wrote $DST"
