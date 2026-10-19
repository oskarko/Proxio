#!/bin/sh
# Regenerates Resources/AppIcon.icns from the SwiftUI artwork in Theme.swift.
set -e
cd "$(dirname "$0")/.."
swift build --product ProxioApp
TMP=$(mktemp -d)
"$(swift build --show-bin-path)/ProxioApp" --render-icon "$TMP/icon_1024.png"
SET="$TMP/AppIcon.iconset"
mkdir "$SET"
for size in 16 32 128 256 512; do
  sips -z $size $size "$TMP/icon_1024.png" --out "$SET/icon_${size}x${size}.png" >/dev/null
  sips -z $((size*2)) $((size*2)) "$TMP/icon_1024.png" --out "$SET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o Resources/AppIcon.icns
cp "$TMP/icon_1024.png" Resources/AppIcon.png
rm -rf "$TMP"
echo "Wrote Resources/AppIcon.icns"
