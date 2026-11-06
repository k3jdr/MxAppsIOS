#!/bin/bash
# Build MxModxUSB (Release), install it in /Applications, and open it. Log: MxModxUSB/build-install.log
REPO="$HOME/MyCodeGIT/MxAppsIOS"
LOG="$REPO/MxModxUSB/build-install.log"
DERIVED="$HOME/Library/Developer/Xcode/DerivedData/MxModxUSB-cli"
APP="$DERIVED/Build/Products/Release/MxModxUSB.app"
exec > >(tee "$LOG") 2>&1
set -o pipefail
step() { echo; echo "=== $1 ($(date +%H:%M:%S))"; }
fail() { echo; echo "FAILED: $1"; echo "=== END FAILED"; exit 1; }

step "Build"
cd "$REPO/MxModxUSB" || fail "no MxModxUSB folder"
if ! xcodebuild -project MxModxUSB.xcodeproj -scheme MxModxUSB -configuration Release \
        -derivedDataPath "$DERIVED" -allowProvisioningUpdates build 2>&1 | grep -E "error:|\*\* BUILD|Signing Identity"; then
    fail "xcodebuild (the errors are above)"
fi
[ -d "$APP" ] || fail "no app at $APP"

step "Install in /Applications"
osascript -e 'tell application id "com.k3jdr.MxModxUSB" to quit' 2>/dev/null
for i in 1 2 3 4 5 6 7 8 9 10; do pgrep -x MxModxUSB >/dev/null || break; sleep 1; done
pgrep -x MxModxUSB >/dev/null && fail "MxModxUSB is still running: quit it and run this again"
if [ -d /Applications/MxModxUSB.app ]; then mv /Applications/MxModxUSB.app "/tmp/MxModxUSB.previous.$$.app" || fail "can't move the old app aside"; fi
ditto "$APP" /Applications/MxModxUSB.app || fail "copy to /Applications"
codesign --verify --deep --strict /Applications/MxModxUSB.app && echo "Signature OK"
echo "Installed $(defaults read /Applications/MxModxUSB.app/Contents/Info CFBundleShortVersionString 2>/dev/null) build $(defaults read /Applications/MxModxUSB.app/Contents/Info CFBundleVersion 2>/dev/null)"

step "Open"
open /Applications/MxModxUSB.app
echo; echo "=== END OK"
