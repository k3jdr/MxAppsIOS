#!/bin/bash
# Build MxMidiPRO (Release), install it in /Applications, and open it. Log: MxMidiPRO/build-install.log
# The spy driver is not installed by this script: MxMidiPRO installs it when you choose Set Up OUT Monitoring… ▸
# Install Driver (it then needs the MIDI server restarted once, with Logic Pro quit).
REPO="$HOME/MyCodeGIT/MxAppsIOS"
LOG="$REPO/MxMidiPRO/build-install.log"
DERIVED="$HOME/Library/Developer/Xcode/DerivedData/MxMidiPRO-cli"
APP="$DERIVED/Build/Products/Release/MxMidiPRO.app"
exec > >(tee "$LOG") 2>&1
set -o pipefail
step() { echo; echo "=== $1 ($(date +%H:%M:%S))"; }
fail() { echo; echo "FAILED: $1"; echo "=== END FAILED"; exit 1; }

step "Build"
cd "$REPO/MxMidiPRO" || fail "no MxMidiPRO folder"
if ! xcodebuild -project MxMidiPRO.xcodeproj -scheme MxMidiPRO -configuration Release \
        -derivedDataPath "$DERIVED" -allowProvisioningUpdates build 2>&1 | grep -E "error:|\*\* BUILD|Signing Identity"; then
    fail "xcodebuild (the errors are above)"
fi
[ -d "$APP" ] || fail "no app at $APP"

step "Install in /Applications"
osascript -e 'tell application id "com.k3jdr.MxMidiPRO" to quit' 2>/dev/null
for i in 1 2 3 4 5 6 7 8 9 10; do pgrep -x MxMidiPRO >/dev/null || break; sleep 1; done
pgrep -x MxMidiPRO >/dev/null && fail "MxMidiPRO is still running: quit it and run this again"
if [ -d /Applications/MxMidiPRO.app ]; then mv /Applications/MxMidiPRO.app "/tmp/MxMidiPRO.previous.$$.app" || fail "can't move the old app aside"; fi
ditto "$APP" /Applications/MxMidiPRO.app || fail "copy to /Applications"
codesign --verify --deep --strict /Applications/MxMidiPRO.app && echo "Signature OK"
echo "Installed $(defaults read /Applications/MxMidiPRO.app/Contents/Info CFBundleShortVersionString 2>/dev/null) build $(defaults read /Applications/MxMidiPRO.app/Contents/Info CFBundleVersion 2>/dev/null)"

DRIVER="$HOME/Library/Audio/MIDI Drivers/MxMidiPRO Spy.plugin"
if [ -d "$DRIVER" ]; then
    cdhash() { codesign -dvvv "$1" 2>&1 | grep '^CDHash='; }
    if [ "$(cdhash "$DRIVER")" = "$(cdhash "/Applications/MxMidiPRO.app/Contents/PlugIns/MxMidiPRO Spy.plugin")" ]; then
        echo "Spy driver: installed and current"
    else
        echo "Spy driver: installed but older than this build — MxMidiPRO ▸ Set Up OUT Monitoring… ▸ Update Driver"
    fi
else
    echo "Spy driver: not installed (MxMidiPRO ▸ Set Up OUT Monitoring…)"
fi

step "Open"
open /Applications/MxMidiPRO.app
echo; echo "=== END OK"
