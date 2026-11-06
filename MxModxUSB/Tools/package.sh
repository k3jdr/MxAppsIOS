#!/bin/bash
# Packages the Release build from build-install-mxmodxusb.command as build/MxModxUSB-<version>.dmg, with an
# Applications shortcut. It's signed for development only, not notarized, so it's for Macs under this Apple Developer
# team.
#
#     ~/MyCodeGIT/MxAppsIOS/MxModxUSB/build-install-mxmodxusb.command && ~/MyCodeGIT/MxAppsIOS/MxModxUSB/Tools/package.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$HOME/Library/Developer/Xcode/DerivedData/MxModxUSB-cli/Build/Products/Release/MxModxUSB.app"
[ -d "$APP" ] || { echo "No Release build at $APP. Run build-install-mxmodxusb.command first."; exit 1; }
codesign --verify --deep --strict "$APP"

VERSION="$(defaults read "$APP/Contents/Info" CFBundleShortVersionString)"
OUT="$ROOT/build/MxModxUSB-$VERSION.dmg"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/MxModxUSB.app"
ln -s /Applications "$STAGE/Applications"

mkdir -p "$ROOT/build"
hdiutil create -quiet -volname "MxModxUSB $VERSION" -srcfolder "$STAGE" -format UDZO -fs APFS -ov "$OUT"
hdiutil verify -quiet "$OUT"
echo "Packaged $OUT"
