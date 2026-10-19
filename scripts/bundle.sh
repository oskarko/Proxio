#!/bin/sh
# Builds build/Proxio.app from the ProxioApp executable.
# Ad-hoc signed by default. With PROXIO_SIGN_IDENTITY set (e.g. "Apple Development: Name (TEAMID)"),
# the privileged helper is built, embedded as a launch daemon and everything is signed with that identity;
# the helper only serves apps signed by the same team.
set -e
cd "$(dirname "$0")/.."
swift build -c release --product ProxioApp
APP=build/Proxio.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Localizations (en, es, ru, fr) live outside SwiftPM so Bundle.main resolves them.
for lproj in Sources/ProxioApp/Localization/*.lproj; do cp -R "$lproj" "$APP/Contents/Resources/"; done
cp "$(swift build -c release --show-bin-path)/ProxioApp" "$APP/Contents/MacOS/Proxio"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Proxio</string>
  <key>CFBundleDisplayName</key><string>Proxio</string>
  <key>CFBundleIdentifier</key><string>dev.proxio.app</string>
  <key>CFBundleExecutable</key><string>Proxio</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>es</string><string>ru</string><string>fr</string></array>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
if [ -n "$PROXIO_SIGN_IDENTITY" ]; then
  swift build -c release --product ProxioHelper
  mkdir -p "$APP/Contents/Library/LaunchDaemons"
  cp "$(swift build -c release --show-bin-path)/ProxioHelper" "$APP/Contents/MacOS/dev.proxio.helper"
  cat > "$APP/Contents/Library/LaunchDaemons/dev.proxio.helper.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>dev.proxio.helper</string>
  <key>BundleProgram</key><string>Contents/MacOS/dev.proxio.helper</string>
  <key>MachServices</key><dict><key>dev.proxio.helper</key><true/></dict>
  <key>AssociatedBundleIdentifiers</key><array><string>dev.proxio.app</string></array>
</dict></plist>
PLIST
  codesign --force --options runtime --identifier dev.proxio.helper --sign "$PROXIO_SIGN_IDENTITY" "$APP/Contents/MacOS/dev.proxio.helper"
  codesign --force --sign "$PROXIO_SIGN_IDENTITY" "$APP"
else
  codesign --force --sign - "$APP"
fi
echo "Built $APP"
