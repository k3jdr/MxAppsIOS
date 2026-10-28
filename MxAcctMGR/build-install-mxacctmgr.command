#!/bin/bash
# Build MxAcctMGR (Release), install it in /Applications, restart the accounts service, and open the app.
# Written by Claude for the Spending Analysis changes of 10/27/26. Log: MxAcctMGR/build-install.log
REPO="$HOME/MyCodeGIT/MxAppsIOS"
LOG="$REPO/MxAcctMGR/build-install.log"
DERIVED="$HOME/Library/Developer/Xcode/DerivedData/MxAcctMGR-cli"
APP="$DERIVED/Build/Products/Release/MxAcctMGR.app"
exec > >(tee "$LOG") 2>&1
set -o pipefail
step() { echo; echo "=== $1 ($(date +%H:%M:%S))"; }
fail() { echo; echo "FAILED: $1"; echo "=== END FAILED"; exit 1; }

step "Build"
cd "$REPO/MxAcctMGR" || fail "no MxAcctMGR folder"
if ! xcodebuild -project MxAcctMGR.xcodeproj -scheme MxAcctMGR -configuration Release \
        -derivedDataPath "$DERIVED" -allowProvisioningUpdates build 2>&1 | grep -E "error:|warning: .*Spending|\*\* BUILD|Signing Identity"; then
    fail "xcodebuild (the errors are above)"
fi
[ -d "$APP" ] || fail "no app at $APP"

step "Install in /Applications"
osascript -e 'tell application id "com.k3jdr.MxAcctMGR" to quit' 2>/dev/null
for i in 1 2 3 4 5 6 7 8 9 10; do pgrep -x MxAcctMGR >/dev/null || break; sleep 1; done
pgrep -x MxAcctMGR >/dev/null && fail "MxAcctMGR is still running: quit it and run this again"
if [ -d /Applications/MxAcctMGR.app ]; then mv /Applications/MxAcctMGR.app "/tmp/MxAcctMGR.previous.$$.app" || fail "can't move the old app aside"; fi
ditto "$APP" /Applications/MxAcctMGR.app || fail "copy to /Applications"
codesign --verify --deep --strict /Applications/MxAcctMGR.app && echo "Signature OK"
echo "Installed $(defaults read /Applications/MxAcctMGR.app/Contents/Info CFBundleShortVersionString 2>/dev/null) build $(defaults read /Applications/MxAcctMGR.app/Contents/Info CFBundleVersion 2>/dev/null)"

step "Restart the accounts service"
cd "$REPO" || fail "no repo"
python3 Services/mxservices.py restart accounts || fail "restart accounts"
sleep 2
python3 Services/mxservices.py status

step "Open"
open /Applications/MxAcctMGR.app
echo; echo "=== END OK"
