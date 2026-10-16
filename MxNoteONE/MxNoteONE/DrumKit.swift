//
//  DrumKit.swift
//  MxNoteONE
//
//  Drum notation: a percussion staff's instruments — where each sits on the
//  staff, its notehead (x for cymbals and hi-hats, a diamond for the ride
//  bell), its General MIDI drum sound, and the key that adds it (K kick,
//  S snare, H hi-hat…). Hands go in voice 1 (stems up), feet in voice 2.
//

import AppKit

enum DrumHead: String, Codable {
    case normal, x, circleX, diamond
}

struct DrumInstrument: Identifiable, Hashable {
    let id: String
    let name: String
    /// Typed on a percussion staff (⇧ adds it to the chord: hi-hat with a kick).
    let key: Character
    /// Where it's written (treble-clef positions, as MuseScore's drum staff).
    let step: Int
    let octave: Int
    let head: DrumHead
    /// The General MIDI drum note.
    let midi: Int
    /// Played with the feet (voice 2, stems down).
    let foot: Bool

    var diatonic: Int { octave * 7 + step }
}

enum DrumKit {
    static let instruments: [DrumInstrument] = [
        DrumInstrument(id: "crash", name: "Crash Cymbal", key: "c", step: 5, octave: 5, head: .x, midi: 49, foot: false),
        DrumInstrument(id: "hihat", name: "Closed Hi-Hat", key: "h", step: 4, octave: 5, head: .x, midi: 42, foot: false),
        DrumInstrument(id: "openhat", name: "Open Hi-Hat", key: "o", step: 4, octave: 5, head: .circleX, midi: 46, foot: false),
        DrumInstrument(id: "ride", name: "Ride Cymbal", key: "r", step: 3, octave: 5, head: .x, midi: 51, foot: false),
        DrumInstrument(id: "bell", name: "Ride Bell", key: "b", step: 3, octave: 5, head: .diamond, midi: 53, foot: false),
        DrumInstrument(id: "hightom", name: "High Tom", key: "t", step: 2, octave: 5, head: .normal, midi: 50, foot: false),
        DrumInstrument(id: "midtom", name: "Mid Tom", key: "m", step: 1, octave: 5, head: .normal, midi: 47, foot: false),
        DrumInstrument(id: "snare", name: "Snare Drum", key: "s", step: 0, octave: 5, head: .normal, midi: 38, foot: false),
        DrumInstrument(id: "sidestick", name: "Side Stick", key: "x", step: 0, octave: 5, head: .x, midi: 37, foot: false),
        DrumInstrument(id: "floortom", name: "Floor Tom", key: "f", step: 5, octave: 4, head: .normal, midi: 43, foot: false),
        DrumInstrument(id: "kick", name: "Bass Drum", key: "k", step: 3, octave: 4, head: .normal, midi: 36, foot: true),
        DrumInstrument(id: "pedalhat", name: "Pedal Hi-Hat", key: "p", step: 1, octave: 4, head: .x, midi: 44, foot: true),
    ]

    static func instrument(_ id: String?) -> DrumInstrument? {
        guard let id else { return nil }
        return instruments.first { $0.id == id }
    }

    static func instrument(key: Character) -> DrumInstrument? {
        instruments.first { $0.key == Character(key.lowercased()) }
    }

    /// The instrument a General MIDI drum note is (for MusicXML), else the nearest by staff position.
    static func instrument(midi: Int) -> DrumInstrument? {
        instruments.first { $0.midi == midi }
            ?? [35: "kick", 40: "snare", 39: "sidestick", 41: "floortom", 45: "midtom", 48: "hightom", 52: "crash", 55: "crash", 57: "crash", 59: "ride"]
            .first { $0.key == midi }.flatMap { instrument($0.value) }
    }

    static func instrument(diatonic: Int, head: DrumHead) -> DrumInstrument? {
        instruments.first { $0.diatonic == diatonic && $0.head == head } ?? instruments.first { $0.diatonic == diatonic }
    }

    /// The instrument a step above (+1) or below (-1) on the staff (↑ ↓ on a drum note).
    static func neighbor(of id: String, _ direction: Int) -> DrumInstrument? {
        guard let current = instrument(id) else { return nil }
        let positions = Array(Set(instruments.map(\.diatonic))).sorted()
        guard let i = positions.firstIndex(of: current.diatonic) else { return nil }
        let j = i + (direction > 0 ? 1 : -1)
        guard positions.indices.contains(j) else { return nil }
        return instruments.first { $0.diatonic == positions[j] && $0.head == .normal } ?? instruments.first { $0.diatonic == positions[j] }
    }

    /// Draws a drum notehead (x, circled x, diamond) at a head's place.
    static func drawHead(_ head: DrumHead, x: CGFloat, y: CGFloat, width w: CGFloat, height h: CGFloat, color: NSColor, filled: Bool) {
        color.set()
        switch head {
        case .x, .circleX:
            let d = h * 0.55
            let path = NSBezierPath()
            path.move(to: NSPoint(x: x + w / 2 - d, y: y - d)); path.line(to: NSPoint(x: x + w / 2 + d, y: y + d))
            path.move(to: NSPoint(x: x + w / 2 - d, y: y + d)); path.line(to: NSPoint(x: x + w / 2 + d, y: y - d))
            path.lineWidth = 1.5
            path.stroke()
            if head == .circleX {
                // Open hi-hat: a small circle over the note.
                let r = h * 0.32
                let ring = NSBezierPath(ovalIn: NSRect(x: x + w / 2 - r, y: y - h * 2.1 - r, width: r * 2, height: r * 2))
                ring.lineWidth = 1.1
                ring.stroke()
            }
        case .diamond:
            let path = NSBezierPath()
            path.move(to: NSPoint(x: x + w / 2, y: y - h * 0.6))
            path.line(to: NSPoint(x: x + w * 0.95, y: y))
            path.line(to: NSPoint(x: x + w / 2, y: y + h * 0.6))
            path.line(to: NSPoint(x: x + w * 0.05, y: y))
            path.close()
            if filled { path.fill() } else { path.lineWidth = 1.2; path.stroke() }
        case .normal:
            break
        }
    }
}
