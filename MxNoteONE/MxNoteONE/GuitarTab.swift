//
//  GuitarTab.swift
//  MxNoteONE
//
//  Tablature for fretted instruments — guitar (standard, drop and open tunings, DADGAD, seven-string, nylon),
//  bass (four and five strings), ukulele, mandolin and banjo — with a capo. Strings and frets for every note are
//  chosen together, so the hand moves as little as it can and chords sit under one hand (a note's own string, or a
//  chord note's, when it's been chosen). The playing techniques TAB writes: hammer-ons and pull-offs, slides, bends
//  (and releases), vibrato, palm muting, let ring, natural and artificial harmonics, dead and ghost notes, tapping.
//  And the other way: a string and fret as a note (typing frets into the TAB).
//

import Foundation

/// A fretted instrument and its tuning.
struct TabInstrument: Identifiable, Equatable {
    let id: String
    let name: String
    /// Open strings, the TAB's bottom line first, as MIDI numbers.
    let strings: [Int]
    /// Written an octave above where it sounds (guitar, bass, banjo), on this clef.
    let octaveUp: Bool
    let clef: ScoreData.Clef
    /// Its General MIDI sound.
    let program: Int
    let frets: Int
    /// Grouped in menus by this.
    let family: String

    static let all: [TabInstrument] = [
        .init(id: "guitar", name: "Guitar — Standard (E A D G B E)", strings: [40, 45, 50, 55, 59, 64], octaveUp: true, clef: .treble, program: 25, frets: 24, family: "Guitar"),
        .init(id: "guitar-nylon", name: "Classical Guitar (E A D G B E)", strings: [40, 45, 50, 55, 59, 64], octaveUp: true, clef: .treble, program: 24, frets: 19, family: "Guitar"),
        .init(id: "guitar-electric", name: "Electric Guitar (E A D G B E)", strings: [40, 45, 50, 55, 59, 64], octaveUp: true, clef: .treble, program: 27, frets: 24, family: "Guitar"),
        .init(id: "drop-d", name: "Drop D (D A D G B E)", strings: [38, 45, 50, 55, 59, 64], octaveUp: true, clef: .treble, program: 25, frets: 24, family: "Guitar"),
        .init(id: "half-down", name: "Half Step Down (E♭ A♭ D♭ G♭ B♭ E♭)", strings: [39, 44, 49, 54, 58, 63], octaveUp: true, clef: .treble, program: 25, frets: 24, family: "Guitar"),
        .init(id: "full-down", name: "Full Step Down (D G C F A D)", strings: [38, 43, 48, 53, 57, 62], octaveUp: true, clef: .treble, program: 25, frets: 24, family: "Guitar"),
        .init(id: "drop-c", name: "Drop C (C G C F A D)", strings: [36, 43, 48, 53, 57, 62], octaveUp: true, clef: .treble, program: 29, frets: 24, family: "Guitar"),
        .init(id: "open-g", name: "Open G (D G D G B D)", strings: [38, 43, 50, 55, 59, 62], octaveUp: true, clef: .treble, program: 25, frets: 24, family: "Guitar"),
        .init(id: "open-d", name: "Open D (D A D F♯ A D)", strings: [38, 45, 50, 54, 57, 62], octaveUp: true, clef: .treble, program: 25, frets: 24, family: "Guitar"),
        .init(id: "open-e", name: "Open E (E B E G♯ B E)", strings: [40, 47, 52, 56, 59, 64], octaveUp: true, clef: .treble, program: 25, frets: 24, family: "Guitar"),
        .init(id: "dadgad", name: "DADGAD (D A D G A D)", strings: [38, 45, 50, 55, 57, 62], octaveUp: true, clef: .treble, program: 25, frets: 24, family: "Guitar"),
        .init(id: "seven-string", name: "Seven-String Guitar (B E A D G B E)", strings: [35, 40, 45, 50, 55, 59, 64], octaveUp: true, clef: .treble, program: 27, frets: 24, family: "Guitar"),
        .init(id: "bass", name: "Bass (E A D G)", strings: [28, 33, 38, 43], octaveUp: true, clef: .bass, program: 33, frets: 20, family: "Bass"),
        .init(id: "bass-5", name: "Five-String Bass (B E A D G)", strings: [23, 28, 33, 38, 43], octaveUp: true, clef: .bass, program: 33, frets: 24, family: "Bass"),
        .init(id: "ukulele", name: "Ukulele (G C E A)", strings: [67, 60, 64, 69], octaveUp: false, clef: .treble, program: 24, frets: 15, family: "Other"),
        .init(id: "baritone-ukulele", name: "Baritone Ukulele (D G B E)", strings: [50, 55, 59, 64], octaveUp: false, clef: .treble, program: 24, frets: 18, family: "Other"),
        .init(id: "mandolin", name: "Mandolin (G D A E)", strings: [55, 62, 69, 76], octaveUp: false, clef: .treble, program: 25, frets: 20, family: "Other"),
        .init(id: "banjo", name: "Banjo — Open G (g D G B D)", strings: [67, 50, 55, 59, 62], octaveUp: true, clef: .treble, program: 105, frets: 22, family: "Other"),
    ]

    static let guitar = all[0]

    static func preset(_ id: String?) -> TabInstrument? { all.first { $0.id == id } }

    /// A string's note name ("E", "A♭", "g" for a banjo's short fifth string).
    static func noteName(_ midi: Int, flats: Bool = false) -> String {
        (flats ? ["C", "D♭", "D", "E♭", "E", "F", "G♭", "G", "A♭", "A", "B♭", "B"] : ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"])[((midi % 12) + 12) % 12]
    }

    /// The tuning as letters, lowest line first ("D A D G B E").
    static func letters(_ strings: [Int]) -> String {
        let flats = strings.contains { [1, 3, 6, 8, 10].contains($0 % 12) } && strings.contains { [3, 8].contains($0 % 12) }
        return strings.map { noteName($0, flats: flats) }.joined(separator: " ")
    }

    /// General MIDI sounds offered for scores (piano and the fretted ones).
    static let sounds: [(Int, String)] = [
        (0, "Piano"), (24, "Nylon Guitar"), (25, "Steel Guitar"), (26, "Jazz Guitar"), (27, "Clean Electric Guitar"),
        (28, "Muted Electric Guitar"), (29, "Overdriven Guitar"), (30, "Distortion Guitar"), (32, "Acoustic Bass"),
        (33, "Fingered Bass"), (34, "Picked Bass"), (35, "Fretless Bass"), (105, "Banjo"), (46, "Harp"), (40, "Violin"),
        (73, "Flute"), (56, "Trumpet"), (48, "Strings"), (52, "Choir"),
    ]
}

/// How a note is played on a fretted instrument (what TAB writes beside its fret).
struct GuitarMarks: Codable, Hashable {
    /// Bent up so many semitones (1 = ½, 2 = full, 3 = 1½), and let back down.
    var bend: Double?
    var release: Bool?
    /// "next" — slid to the next note; "in" — slid into from below; "out" — slid away downward.
    var slide: String?
    /// A hammer-on (up) or pull-off (down) to the next note.
    var legato: Bool?
    var vibrato: Bool?
    var palmMute: Bool?
    var letRing: Bool?
    /// "natural" (touched over the fret) or "artificial" (an octave over the fretted note).
    var harmonic: String?
    /// A dead (muted) note: x.
    var dead: Bool?
    /// A ghost note, played softly: (5).
    var ghost: Bool?
    var tap: Bool?
    /// A strum: "down" (low strings first), "up" (the top strings, high first) or "bass" (the chord's bass note —
    /// every other one under the same chord, its fifth: boom-chick).
    var strum: String?

    var isEmpty: Bool { self == GuitarMarks() }

    /// The techniques, for menus: (id, name, key in TAB input — with ⌥).
    static let kinds: [(String, String, String)] = [
        ("legato", "Hammer-On / Pull-Off", "H"), ("slide", "Slide to the Next Note", "S"), ("slide-in", "Slide In", "I"),
        ("slide-out", "Slide Out", "O"), ("bend-1", "Bend ½", "B"), ("bend-2", "Bend Full", ""), ("bend-3", "Bend 1½", ""),
        ("release", "Bend and Release", "R"), ("vibrato", "Vibrato", "V"), ("palmMute", "Palm Mute", "M"),
        ("letRing", "Let Ring", "L"), ("natural", "Natural Harmonic", "N"), ("artificial", "Artificial Harmonic", "A"),
        ("dead", "Dead Note", "X"), ("ghost", "Ghost Note", "G"), ("tap", "Tap", "T"),
    ]
    /// Strums, for menus (as `kinds`).
    static let strumKinds: [(String, String, String)] = [
        ("strum-down", "Down Strum", "D"), ("strum-up", "Up Strum", "U"), ("strum-bass", "Bass Note (Boom-Chick)", ""),
    ]

    func has(_ kind: String) -> Bool {
        switch kind {
        case "legato": legato == true
        case "slide": slide == "next"
        case "slide-in": slide == "in"
        case "slide-out": slide == "out"
        case "bend-1": bend == 1
        case "bend-2": bend == 2
        case "bend-3": bend == 3
        case "release": release == true
        case "vibrato": vibrato == true
        case "palmMute": palmMute == true
        case "letRing": letRing == true
        case "natural": harmonic == "natural"
        case "artificial": harmonic == "artificial"
        case "dead": dead == true
        case "ghost": ghost == true
        case "tap": tap == true
        case "strum-down": strum == "down"
        case "strum-up": strum == "up"
        case "strum-bass": strum == "bass"
        default: false
        }
    }

    /// On or off.
    mutating func toggle(_ kind: String) {
        let on = !has(kind)
        switch kind {
        case "legato": legato = on ? true : nil
        case "slide": slide = on ? "next" : nil
        case "slide-in": slide = on ? "in" : nil
        case "slide-out": slide = on ? "out" : nil
        case "bend-1": bend = on ? 1 : nil
        case "bend-2": bend = on ? 2 : nil
        case "bend-3": bend = on ? 3 : nil
        case "release":
            release = on ? true : nil
            if on, bend == nil { bend = 2 }
        case "vibrato": vibrato = on ? true : nil
        case "palmMute": palmMute = on ? true : nil
        case "letRing": letRing = on ? true : nil
        case "natural": harmonic = on ? "natural" : nil
        case "artificial": harmonic = on ? "artificial" : nil
        case "dead": dead = on ? true : nil
        case "ghost": ghost = on ? true : nil
        case "tap": tap = on ? true : nil
        case "strum-down": strum = on ? "down" : nil
        case "strum-up": strum = on ? "up" : nil
        case "strum-bass": strum = on ? "bass" : nil
        default: break
        }
        if bend == nil { release = nil }
    }

    /// How a bend is written: ½, full, 1½.
    static func bendLabel(_ semitones: Double) -> String {
        switch semitones {
        case ..<0.75: "½"
        case ..<1.5: "½"
        case ..<2.5: "full"
        case ..<3.5: "1½"
        default: "2"
        }
    }
}

/// A note's place on the neck.
struct TabSpot: Hashable {
    var string: Int
    var fret: Int
}

extension ScoreData {
    /// The fretted instrument the TAB is for (its preset, else standard guitar).
    var fretted: TabInstrument {
        if let p = TabInstrument.preset(tabInstrument) { return p }
        return .guitar
    }

    /// Open strings, the TAB's bottom line first (MIDI).
    var openStrings: [Int] { tabTuning ?? fretted.strings }
    var stringCount: Int { openStrings.count }
    var maxFret: Int { fretted.frets }

    /// Taken off a note's pitch to give the pitch on the neck: the octave guitar music is written above where it
    /// sounds (unless a transposing staff already sounds where it should), and the capo.
    var tabOffset: Int {
        let octave = soundingShift == 0 && fretted.octaveUp && clef == fretted.clef ? 12 : 0
        return octave + (capo ?? 0)
    }

    /// The sound a staff plays: its own, else (with TAB) its instrument's, else piano.
    var sound: Int { program ?? (showTab == true ? fretted.program : 0) }

    /// Each pitch's string and fret for every note (main note first, then its chord notes), chosen together: a
    /// chosen string is kept; otherwise the frets sit under one hand and the hand moves as little as it can.
    func tabPlan() -> [[TabSpot]] {
        let open = openStrings, top = maxFret
        var candidates: [[[TabSpot?]]] = []   // per note: candidate assignments (nil: a pitch that can't be played)
        var costs: [[Double]] = []
        for i in notes.indices {
            let n = notes[i]
            guard !n.rest, n.drum == nil else { candidates.append([]); costs.append([]); continue }
            // A slash: the strings its strum strikes, in the chord's voicing.
            if n.slash != nil {
                let spots = strumSpots(i)
                candidates.append(spots.isEmpty ? [] : [spots.map { Optional($0) }])
                costs.append(spots.isEmpty ? [] : [0])
                continue
            }
            let pitches = midis(i).map { $0 - tabOffset }
            let pins = [n.tabString] + (n.chord ?? []).map(\.tabString)
            var found: [[TabSpot?]] = []
            var current: [TabSpot?] = []
            var used = Set<Int>()
            func search(_ k: Int) {
                if found.count > 400 { return }
                if k == pitches.count { found.append(current); return }
                var options: [Int] = []
                if let pin = k < pins.count ? pins[k] : nil, open.indices.contains(pin), !used.contains(pin),
                   (0...top).contains(pitches[k] - open[pin]) {
                    options = [pin]
                } else {
                    options = open.indices.filter { !used.contains($0) && (0...top).contains(pitches[k] - open[$0]) }
                }
                if options.isEmpty {
                    current.append(nil)
                    search(k + 1)
                    current.removeLast()
                    return
                }
                for s in options {
                    used.insert(s)
                    current.append(TabSpot(string: s, fret: pitches[k] - open[s]))
                    search(k + 1)
                    current.removeLast()
                    used.remove(s)
                }
            }
            search(0)
            // The handiest few: frets close together, low on the neck, every pitch placed.
            let scored = found.map { a -> ([TabSpot?], Double) in
                let fretted = a.compactMap { $0 }.map(\.fret).filter { $0 > 0 }
                let span = Double((fretted.max() ?? 0) - (fretted.min() ?? 0))
                let missing = Double(a.filter { $0 == nil }.count)
                let average = fretted.isEmpty ? 0 : Double(fretted.reduce(0, +)) / Double(fretted.count)
                return (a, missing * 100 + max(0, span - 3) * 6 + span * 0.4 + average * 0.12)
            }.sorted { $0.1 < $1.1 }.prefix(24)
            candidates.append(scored.map(\.0))
            costs.append(scored.map(\.1))
        }
        // The path through every note's choices that moves the hand least (a tied note stays where it is).
        func position(_ a: [TabSpot?]) -> Double? {
            let fretted = a.compactMap { $0 }.map(\.fret).filter { $0 > 0 }
            return fretted.isEmpty ? nil : Double(fretted.min()!)
        }
        var best: [[Double]] = costs
        var back: [[Int]] = costs.map { Array(repeating: -1, count: $0.count) }
        var lastPlayed: Int?
        for i in notes.indices where !candidates[i].isEmpty {
            defer { lastPlayed = i }
            guard let p = lastPlayed else { continue }
            let tied = tiedFrom(i)
            for (c, a) in candidates[i].enumerated() {
                var choice = -1, value = Double.infinity
                for (d, b) in candidates[p].enumerated() {
                    var move = 0.0
                    if tied { move = a.first??.string == b.first??.string ? 0 : 50 }
                    else if let x = position(a), let y = position(b) { move = abs(x - y) * 0.7 }
                    let v = best[p][d] + move
                    if v < value { value = v; choice = d }
                }
                best[i][c] += value
                back[i][c] = choice
            }
        }
        var result = Array(repeating: [TabSpot](), count: notes.count)
        guard let last = lastPlayed, let end = best[last].indices.min(by: { best[last][$0] < best[last][$1] }) else { return result }
        var i = last, c = end
        while true {
            result[i] = candidates[i][c].compactMap { $0 }
            let prevChoice = back[i][c]
            guard let prev = notes.indices[..<i].last(where: { !candidates[$0].isEmpty }), prevChoice >= 0 else { break }
            i = prev
            c = prevChoice
        }
        return result
    }

    /// One note's strings and frets (the whole line's plan, so it's chosen with its neighbours).
    func tab(_ index: Int) -> [TabSpot] {
        let plan = tabPlan()
        return plan.indices.contains(index) ? plan[index] : []
    }

    /// The pitch a spot sounds on the neck, and as the note's written MIDI number (what `midis` gives).
    func neckPitch(_ spot: TabSpot) -> Int { openStrings[spot.string] + spot.fret }
    func notePitch(string: Int, fret: Int) -> Int { openStrings[string] + fret + tabOffset }

    /// A pitch (as `midis` gives it) written as a note: its step, octave and alteration — sharps in sharp keys,
    /// flats in flat ones.
    func spelled(_ midi: Int) -> (step: Int, octave: Int, alter: Int) {
        let written = midi - soundingShift
        let pc = ((written % 12) + 12) % 12
        let naturals: [Int: Int] = [0: 0, 2: 1, 4: 2, 5: 3, 7: 4, 9: 5, 11: 6]
        if let step = naturals[pc] { return (step, written / 12 - 1, 0) }
        if keyFifths < 0 {
            let step = naturals[(pc + 1) % 12]!
            return (step, (written + 1) / 12 - 1, -1)
        }
        let step = naturals[pc - 1]!
        return (step, written / 12 - 1, 1)
    }

    /// The pitch a harmonic sounds (natural: the string's overtone at that fret; artificial: an octave over the
    /// fretted note), on the neck.
    func harmonicPitch(_ spot: TabSpot, artificial: Bool) -> Int {
        let open = openStrings[spot.string]
        if artificial { return open + spot.fret + 12 }
        let overtones: [Int: Int] = [12: 12, 24: 24, 7: 19, 19: 19, 5: 24, 4: 28, 9: 28, 16: 28, 3: 31]
        return open + (overtones[spot.fret] ?? spot.fret + 12)
    }

    /// The notes palm-muted or let ring together: runs of consecutive notes with the mark (first, last).
    func runs(_ mark: (GuitarMarks) -> Bool) -> [ClosedRange<Int>] {
        var out: [ClosedRange<Int>] = [], start: Int?
        for i in notes.indices {
            let on = !notes[i].rest && notes[i].guitar.map(mark) == true
            if on, start == nil { start = i }
            if !on, let s = start { out.append(s...(i - 1)); start = nil }
        }
        if let s = start { out.append(s...(notes.count - 1)) }
        return out
    }

    var hasGuitarMarks: Bool { notes.contains { !($0.guitar?.isEmpty ?? true) } }
}
