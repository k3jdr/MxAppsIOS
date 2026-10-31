#!/bin/bash
# Packages the Release build from build-install.command as build/MxOpenCVD-<version>.dmg, with an Applications shortcut.
# It's signed for development only, not notarized, so it's for Macs under this Apple Developer team.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$HOME/Library/Developer/Xcode/DerivedData/MxOpenCVD-cli/Build/Products/Release/MxOpenCVD.app"
[ -d "$APP" ] || { echo "No Release build at $APP. Run scripts/build-install.command first."; exit 1; }
codesign --verify --deep --strict "$APP"

VERSION="$(defaults read "$APP/Contents/Info" CFBundleShortVersionString)"
OUT="$ROOT/build/MxOpenCVD-$VERSION.dmg"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/MxOpenCVD.app"
ln -s /Applications "$STAGE/Applications"

mkdir -p "$ROOT/build"
hdiutil create -quiet -volname "MxOpenCVD $VERSION" -srcfolder "$STAGE" -format UDZO -fs APFS -ov "$OUT"
hdiutil verify -quiet "$OUT"
echo "Packaged $OUT"
