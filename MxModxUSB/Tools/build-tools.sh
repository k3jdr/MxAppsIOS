#!/bin/bash
# Builds MxModxUSB's test tool into $1 (default: MxModxUSB/build/tools):
#   modx-tests  checks the SysEx decoding against replies a real MODX7 sent (no MODX needed)
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$HERE/build/tools}"
mkdir -p "$OUT"
SRC="$HERE/MxModxUSB"
swiftc -O -parse-as-library "$HERE/Tools/ModxTests.swift" "$SRC"/MODX/*.swift "$SRC"/Device/*.swift \
    "$SRC"/MIDI/*.swift -framework CoreMIDI -framework CoreAudio -framework AVFoundation -o "$OUT/modx-tests"
echo "Built $OUT/modx-tests"
