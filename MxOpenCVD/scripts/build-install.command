#!/bin/bash
# Build MxOpenCVD (Release), install it in /Applications, and open it. Runs bootstrap.sh first if it needs to.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED="$HOME/Library/Developer/Xcode/DerivedData/MxOpenCVD-cli"
APP="$DERIVED/Build/Products/Release/MxOpenCVD.app"
set -o pipefail
step() { echo; echo "=== $1 ($(date +%H:%M:%S))"; }
fail() { echo; echo "FAILED: $1"; exit 1; }

if [ ! -f "$ROOT/Vendor/opencv/lib/libopencv_core.a" ] || [ ! -d "$ROOT/Vendor/onnxruntime/lib" ]; then
    step "Fetch and build the native libraries"
    "$ROOT/scripts/bootstrap.sh" || fail "bootstrap"
fi

step "Build"
cd "$ROOT" || fail "no repository"
if ! xcodebuild -project MxOpenCVD.xcodeproj -scheme MxOpenCVD -configuration Release \
        -derivedDataPath "$DERIVED" -allowProvisioningUpdates build 2>&1 | grep -E "error:|\*\* BUILD|Signing Identity"; then
    fail "xcodebuild (the errors are above)"
fi
[ -d "$APP" ] || fail "no app at $APP"

step "Install in /Applications"
osascript -e 'tell application id "com.k3jdr.MxOpenCVD" to quit' 2>/dev/null
for i in 1 2 3 4 5 6 7 8 9 10; do pgrep -x MxOpenCVD >/dev/null || break; sleep 1; done
pgrep -x MxOpenCVD >/dev/null && fail "MxOpenCVD is still running: quit it and run this again"
if [ -d /Applications/MxOpenCVD.app ]; then mv /Applications/MxOpenCVD.app "/tmp/MxOpenCVD.previous.$$.app" || fail "can't move the old app aside"; fi
ditto "$APP" /Applications/MxOpenCVD.app || fail "copy to /Applications"
codesign --verify --deep --strict /Applications/MxOpenCVD.app && echo "Signature OK"

step "Open"
open /Applications/MxOpenCVD.app
echo; echo "=== END OK"
