#!/bin/sh
# Builds build/Proxio-<version>.dmg.
#
#   scripts/release.sh                      ad-hoc signed DMG (runs anywhere you build it, Gatekeeper warns elsewhere)
#   PROXIO_SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" \
#   PROXIO_NOTARY_PROFILE=proxio-notary scripts/release.sh
#                                           signed with the hardened runtime, notarized and stapled
#
# Store the notarization credentials once with:
#   xcrun notarytool store-credentials proxio-notary --apple-id <id> --team-id <TEAMID>
set -e
cd "$(dirname "$0")/.."

APP=build/Proxio.app
VERSION=$(sed -n 's|.*<key>CFBundleShortVersionString</key><string>\(.*\)</string>.*|\1|p' scripts/bundle.sh)
[ -n "$PROXIO_VERSION" ] && VERSION=$PROXIO_VERSION
DMG="build/Proxio-$VERSION.dmg"

scripts/bundle.sh

if [ -n "$PROXIO_SIGN_IDENTITY" ]; then
  # Notarization needs the hardened runtime and a secure timestamp on every executable.
  if [ -f "$APP/Contents/MacOS/dev.proxio.helper" ]; then
    codesign --force --options runtime --timestamp --identifier dev.proxio.helper --sign "$PROXIO_SIGN_IDENTITY" "$APP/Contents/MacOS/dev.proxio.helper"
  fi
  codesign --force --options runtime --timestamp --sign "$PROXIO_SIGN_IDENTITY" "$APP"
  codesign --verify --deep --strict "$APP"
fi

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "Proxio" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
[ -n "$PROXIO_SIGN_IDENTITY" ] && codesign --force --timestamp --sign "$PROXIO_SIGN_IDENTITY" "$DMG"

if [ -n "$PROXIO_SIGN_IDENTITY" ] && [ -n "$PROXIO_NOTARY_PROFILE" ]; then
  xcrun notarytool submit "$DMG" --keychain-profile "$PROXIO_NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
else
  echo "Not notarized (set PROXIO_SIGN_IDENTITY to a Developer ID Application identity and PROXIO_NOTARY_PROFILE)."
fi
echo "Built $DMG"
