#!/bin/sh
# Builds build/Proxio.app (ad-hoc signed) from the ProxioApp executable.
set -e
cd "$(dirname "$0")/.."
swift build -c release --product ProxioApp
APP=build/Proxio.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$(swift build -c release --show-bin-path)/ProxioApp" "$APP/Contents/MacOS/Proxio"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Proxio</string>
  <key>CFBundleDisplayName</key><string>Proxio</string>
  <key>CFBundleIdentifier</key><string>dev.proxio.app</string>
  <key>CFBundleExecutable</key><string>Proxio</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
echo "Built $APP"
