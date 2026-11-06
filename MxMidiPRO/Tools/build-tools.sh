#!/bin/bash
# Builds MxMidiPRO's test tools into $1 (default: MxMidiPRO/build/tools):
#   mxmidi-tests  checks the parser, the spy envelope, UMP conversion and the engine on virtual ports
#   mxmidi-demo   plays a keyboard part (IN) and a Logic Pro part (OUT, through the spy's own code) on virtual ports
# Both compile the app's MIDI sources and SpyDriver/MxSpyCore.c, so they test the code the app and driver run.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$HERE/build/tools}"
mkdir -p "$OUT"
MIDI="$HERE/MxMidiPRO/MIDI"
SOURCES=("$MIDI/MIDIEvent.swift" "$MIDI/MIDIParsing.swift" "$MIDI/MIDIPorts.swift" "$MIDI/MIDIEngine.swift" "$MIDI/MIDIFormat.swift")

clang -c -O2 -Wall "$HERE/SpyDriver/MxSpyCore.c" -o "$OUT/MxSpyCore.o"
swiftc -O -parse-as-library -import-objc-header "$HERE/SpyDriver/MxSpyCore.h" \
    "$HERE/Tools/MxMidiTests.swift" "${SOURCES[@]}" "$OUT/MxSpyCore.o" -framework CoreMIDI -o "$OUT/mxmidi-tests"
swiftc -O -parse-as-library -import-objc-header "$HERE/SpyDriver/MxSpyCore.h" \
    "$HERE/Tools/MxMidiDemo.swift" "$MIDI/MIDIEvent.swift" "$OUT/MxSpyCore.o" -framework CoreMIDI -o "$OUT/mxmidi-demo"
echo "Built $OUT/mxmidi-tests and $OUT/mxmidi-demo"
