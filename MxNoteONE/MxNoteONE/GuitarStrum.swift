//
//  GuitarStrum.swift
//  MxNoteONE
//
//  Strumming patterns: a bar of strokes on a grid — "D-DU-UDU" is down (held), down, up (held), up, down, up in
//  eighths — written as rhythm slashes with ⊓ and V (or ↓ ↑) over them, and played as a guitar strums: the chord's
//  diagram voicing string by string, low strings first going down and the top strings first coming up; muted
//  strums a percussive chk; bass notes alternating the root and fifth (boom-chick); accents louder. The chords are
//  the chord symbols (a rhythm guitar staff follows the first staff's). Swing plays eighths long-short.
//

import Foundation

/// A chord symbol and where it comes (quarter notes from the start).
struct TimedChord: Codable, Hashable {
    var at: Double
    var symbol: String
}

/// One step of a strumming pattern.
struct StrumCell: Hashable {
    /// "D" down, "U" up, "X" muted (the way the hand is going), "B" bass note, "-" hold (the stroke before rings
    /// on), "." rest.
    var kind: Character
    var accent = false

    var isStroke: Bool { "DUXB".contains(kind) }
}

/// A strumming pattern from the library.
struct StrumPattern: Identifiable, Hashable {
    let name: String
    let beats: Int
    let beatUnit: Int
    /// Its steps, one character each (spaces ignored; > accents the next).
    let steps: String
    var id: String { "\(beats)/\(beatUnit) \(name)" }

    init(_ name: String, _ meter: String, _ steps: String) {
        self.name = name
        let parts = meter.split(separator: "/").compactMap { Int($0) }
        beats = parts.first ?? 4
        beatUnit = parts.last ?? 4
        self.steps = steps
    }

    var length: Double { Double(beats) * 4 / Double(beatUnit) }
    var compound: Bool { Self.compound(beats: beats, unit: beatUnit) }
    static func compound(beats: Int, unit: Int) -> Bool { unit == 8 && beats % 3 == 0 && beats > 3 }

    static let library: [StrumPattern] = [
        .init("Quarter Downs", "4/4", "DDDD"),
        .init("Down-Up Eighths", "4/4", "DUDUDUDU"),
        .init("Folk / Pop", "4/4", "D-DU-UDU"),
        .init("Rock", "4/4", "D-DUD-DU"),
        .init("Ballad", "4/4", "D---D-DU"),
        .init("Backbeat Accents", "4/4", "DU>DUDU>DU"),
        .init("Backbeat Chuck", "4/4", "D-XUD-XU"),
        .init("Punk Downstrokes", "4/4", "DDDDDDDD"),
        .init("Ska / Reggae Offbeats", "4/4", ".U.U.U.U"),
        .init("Funk Sixteenths", "4/4", "DUDU XUDU DUDU XUDU"),
        .init("Syncopated Sixteenths", "4/4", "D-DU -UDU D-DU -UDU"),
        .init("Boom-Chick", "4/4", "BDBD"),
        .init("Country Bass-Strum", "4/4", "B-DUB-DU"),
        .init("Half Notes", "4/4", "D-D-"),
        .init("Whole Bar", "4/4", "D"),
        .init("Waltz Downs", "3/4", "DDD"),
        .init("Waltz Eighths", "3/4", "D-DUDU"),
        .init("Boom-Chick-Chick", "3/4", "BDD"),
        .init("Waltz Bass-Strum", "3/4", "B-DUDU"),
        .init("Two Downs", "6/8", "D--D--"),
        .init("Six-Eight Eighths", "6/8", "DDUDDU"),
        .init("Six-Eight Bass-Strum", "6/8", "BDUBDU"),
        .init("March Downs", "2/4", "DD"),
        .init("Two-Four Eighths", "2/4", "DUDU"),
        .init("Polka Boom-Chick", "2/4", "BD"),
        .init("Slow Blues", "12/8", "D-UD-UD-UD-U"),
        .init("Four Downs", "12/8", "D--D--D--D--"),
    ]

    /// The patterns for a score's time: the library's (4/4's for 2/2 too), else a down strum on each beat and
    /// down-up halves of the beat.
    static func patterns(beats: Int, beatUnit: Int) -> [StrumPattern] {
        let length = Double(beats) * 4 / Double(beatUnit), compound = compound(beats: beats, unit: beatUnit)
        let mine = library.filter { abs($0.length - length) < 1e-6 && $0.compound == compound && ($0.beats == beats || length == 4) }
        if !mine.isEmpty { return mine }
        let meter = "\(beats)/\(beatUnit)"
        let count = compound ? beats / 3 : beats
        let beat = compound ? "D--" : "D"
        return [.init("Down on Each Beat", meter, String(repeating: beat, count: count)),
                .init("Down-Up", meter, String(repeating: compound ? "DUD" : "DU", count: count))]
    }

    /// The steps as written for menus ("D-DU-UDU"; sixteenths grouped by the beat).
    var display: String { Self.cells(steps).map { Self.text($0, perBeat: Int((Double($0.count) / Double(beats)).rounded())) } ?? steps }

    /// The pattern used last (where the pattern editor starts).
    static var lastUsed: String? {
        get { UserDefaults.standard.string(forKey: "MxNoteONE.strumPattern") }
        set { UserDefaults.standard.set(newValue, forKey: "MxNoteONE.strumPattern") }
    }

    /// Steps from text: D U X B - . (any case), > before a stroke accents it; spaces and bar lines are ignored.
    static func cells(_ text: String) -> [StrumCell]? {
        var out: [StrumCell] = [], accent = false
        for c in text.uppercased() {
            if c == " " || c == "|" || c == "," { continue }
            if c == ">" || c == "!" { accent = true; continue }
            guard "DUXB-.".contains(c) else { return nil }
            out.append(StrumCell(kind: c, accent: accent && "DUXB".contains(c)))
            accent = false
        }
        return out.isEmpty ? nil : out
    }

    /// Steps as text, grouped by the beat when there are four or more to a beat.
    static func text(_ cells: [StrumCell], perBeat: Int = 0) -> String {
        var out = ""
        for (k, c) in cells.enumerated() {
            if perBeat >= 4, k > 0, k % perBeat == 0 { out += " " }
            out += (c.accent ? ">" : "") + String(c.kind)
        }
        return out
    }

    /// Steps on a sixteenth grid (to compare patterns written on different grids).
    static func sixteenths(_ cells: [StrumCell], length: Double) -> [StrumCell] {
        let per = max(1, Int((length / Double(cells.count) * 4).rounded()))
        return cells.flatMap { c in [c] + Array(repeating: StrumCell(kind: c.kind == "." ? "." : "-"), count: per - 1) }
    }

    /// A length in quarter notes as notes: one if it can be, else the longest first (tied).
    static func pieces(_ length: Double) -> [(ScoreNote.Duration, Bool)] {
        let values: [(Double, ScoreNote.Duration, Bool)] = [
            (4, .whole, false), (3, .half, true), (2, .half, false), (1.5, .quarter, true), (1, .quarter, false),
            (0.75, .eighth, true), (0.5, .eighth, false), (0.375, .sixteenth, true), (0.25, .sixteenth, false),
        ]
        var left = length, out: [(ScoreNote.Duration, Bool)] = []
        while left > 1e-6, let v = values.first(where: { $0.0 <= left + 1e-6 }) {
            out.append((v.1, v.2))
            left -= v.0
        }
        return out
    }
}

extension ScoreData {
    /// Where bass notes sit in slash notation: a third under the middle line.
    var bassSlashLine: (step: Int, octave: Int) {
        let d = clef.bottomLine + 2
        return (d % 7, d / 7)
    }

    /// The beat, in quarter notes (a dotted quarter in 6/8).
    var beatLength: Double {
        StrumPattern.compound(beats: beats, unit: beatUnit) ? 1.5 : 4 / Double(beatUnit)
    }

    // MARK: Writing patterns

    /// One bar of strumming as rhythm slashes: the steps spread over the bar, holds lengthening the stroke before,
    /// rests as rests. Chord symbols go where they were in the bar (`symbols`: their places in it), a chord change
    /// taking a stroke of its own. `leading`: how many notes at the start hold the last bar's stroke (nil if it's
    /// not a pattern for this bar).
    func strumBar(_ cells: [StrumCell], symbols: [TimedChord]) -> (notes: [ScoreNote], leading: Int)? {
        guard !cells.isEmpty else { return nil }
        let step = measureLength / Double(cells.count)
        // Sixteenths are the shortest a step can be.
        guard step >= 0.25 - 1e-9, abs(step * 4 - (step * 4).rounded()) < 1e-9 else { return nil }
        struct Run { var at: Double; var kind: Character; var accent: Bool; var length: Double }
        // The hand goes down on the beat (and every other step after it, on a grid finer than the beat), up between.
        func way(_ at: Double) -> Character {
            guard step < beatLength - 1e-9 else { return "D" }
            let into = at - (at / beatLength + 1e-9).rounded(.down) * beatLength
            return Int((into / step).rounded()) % 2 == 0 ? "D" : "U"
        }
        var runs: [Run] = []
        for (k, c) in cells.enumerated() {
            let at = Double(k) * step
            switch c.kind {
            case "-":
                if runs.isEmpty { runs.append(Run(at: 0, kind: "-", accent: false, length: step)) } else { runs[runs.count - 1].length += step }
            case ".":
                if runs.last?.kind == "." { runs[runs.count - 1].length += step } else { runs.append(Run(at: at, kind: ".", accent: false, length: step)) }
            default:
                runs.append(Run(at: at, kind: c.kind, accent: c.accent, length: step))
            }
        }
        // A new chord is a new stroke (a held strum stops where the chord changes).
        for chord in symbols where chord.at > 1e-6 {
            guard let r = runs.firstIndex(where: { $0.at < chord.at - 1e-6 && chord.at < $0.at + $0.length - 1e-6 }),
                  abs((chord.at - runs[r].at) * 4 - ((chord.at - runs[r].at) * 4).rounded()) < 1e-9 else { continue }
            var tail = runs[r]
            tail.at = chord.at
            tail.length = runs[r].at + runs[r].length - chord.at
            tail.accent = false
            if !".BX".contains(tail.kind) { tail.kind = way(chord.at) }
            runs[r].length = chord.at - runs[r].at
            runs.insert(tail, at: r + 1)
        }
        if runs.first?.kind == "-", symbols.contains(where: { $0.at < 1e-6 }) { runs[0].kind = "D" }
        let middle = middleLine, low = bassSlashLine
        var notes: [ScoreNote] = [], leading = 0
        for run in runs {
            let pieces = StrumPattern.pieces(run.length)
            for (k, piece) in pieces.enumerated() {
                var n = ScoreNote(duration: piece.0, dotted: piece.1)
                if run.kind == "." {
                    n.rest = true
                } else {
                    n.slash = "rhythm"
                    let place = run.kind == "B" ? low : middle
                    n.step = place.step
                    n.octave = place.octave
                    if k == 0, run.kind != "-" {
                        var g = GuitarMarks()
                        switch run.kind {
                        case "U": g.strum = "up"
                        case "B": g.strum = "bass"
                        case "X": g.dead = true; g.strum = way(run.at) == "D" ? "down" : "up"
                        default: g.strum = "down"
                        }
                        n.guitar = g
                        if run.accent { n.articulations = ["accent"] }
                    }
                    n.tie = k < pieces.count - 1
                }
                if run.kind == "-", run.at < 1e-6 { leading += 1 }
                notes.append(n)
            }
        }
        // The chord symbols, on the notes starting where they were (else the note sounding there).
        var t = 0.0
        let starts = notes.map { n -> Double in defer { t += n.beats }; return t }
        for chord in symbols {
            let i = starts.lastIndex { $0 <= chord.at + 1e-6 } ?? 0
            if (notes[i].chordSymbol ?? "").isEmpty { notes[i].chordSymbol = chord.symbol }
        }
        return (notes, leading)
    }

    /// Fills bars with a strumming pattern (bars past the end are added), keeping each bar's chord symbols where
    /// they were. False if the pattern doesn't fit a bar.
    @discardableResult
    mutating func applyStrum(_ cells: [StrumCell], bars: [Int]) -> Bool {
        guard strumBar(cells, symbols: []) != nil else { return false }
        let measures = notes.isEmpty ? [] : self.measures
        var shift = 0
        for b in Array(Set(bars)).sorted() {
            let range = measures.indices.contains(b) ? (measures[b].lowerBound + shift)..<(measures[b].upperBound + shift) : notes.count..<notes.count
            var symbols: [TimedChord] = [], t = 0.0
            for i in range {
                if let c = notes[i].chordSymbol, !c.isEmpty { symbols.append(TimedChord(at: t, symbol: c)) }
                t += notes[i].beats
            }
            guard let made = strumBar(cells, symbols: symbols) else { return false }
            var bar = made.notes
            let leading = made.leading
            let start = range.lowerBound
            let before = start > 0 ? notes[start - 1] : nil
            if leading > 0, let before, before.slash != nil, !before.rest, before.diatonic == bar[0].diatonic {
                // The bar starts holding the last bar's strum.
                notes[start - 1].tie = true
            } else {
                // Nothing to hold: rests.
                for k in 0..<leading {
                    bar[k].rest = true
                    bar[k].slash = nil
                    bar[k].tie = false
                }
                if let before, before.slash != nil { notes[start - 1].tie = false }
            }
            notes.replaceSubrange(range, with: bar)
            shift += bar.count - range.count
        }
        return true
    }

    /// A bar's strumming as steps (the other way): its strokes on the grid of its shortest note. Nil for bars with
    /// tuplets or no notes.
    func strumCells(bar b: Int) -> [StrumCell]? {
        guard !notes.isEmpty, measures.indices.contains(b) else { return nil }
        let range = measures[b]
        let lengths = range.map { notes[$0].beats }
        guard !range.isEmpty, lengths.allSatisfy({ $0 > 0 && abs($0 * 4 - ($0 * 4).rounded()) < 1e-9 }) else { return nil }
        func whole(_ x: Double) -> Bool { abs(x - x.rounded()) < 1e-9 }
        var step = lengths.min() ?? 1, t = 0.0
        for l in lengths {
            if !whole(t / step) || !whole(l / step) { step = 0.25; break }
            t += l
        }
        var cells: [StrumCell] = []
        for i in range {
            let n = notes[i]
            let count = max(1, Int((n.beats / step).rounded()))
            if n.rest {
                cells += Array(repeating: StrumCell(kind: "."), count: count)
                continue
            }
            let g = n.guitar
            let kind: Character = tiedFrom(i) ? "-" : g?.dead == true ? "X" : g?.strum == "up" ? "U" : g?.strum == "bass" ? "B" : "D"
            cells.append(StrumCell(kind: kind, accent: kind != "-" && (n.articulations ?? []).contains("accent")))
            cells += Array(repeating: StrumCell(kind: "-"), count: count - 1)
        }
        // A short last bar: rests to the end.
        let missing = Int(((measureLength - lengths.reduce(0, +)) / step).rounded())
        if missing > 0 { cells += Array(repeating: StrumCell(kind: "."), count: missing) }
        return cells
    }

    // MARK: Playing strums

    /// Whether the staff sounds like a fretted instrument (guitars, basses, banjo) — its slashes are strummed.
    var frettedSound: Bool { showTab == true || (24...39).contains(sound) || (104...107).contains(sound) }

    /// Whether a note plays as a strum: a slash with a stroke, or any slash on a guitar's staff.
    func strummed(_ index: Int) -> Bool {
        let n = notes[index]
        return n.slash != nil && !n.rest && (n.guitar?.strum != nil || frettedSound)
    }

    /// The chord in effect at a note and its diagram (the voicing chosen for it; with a capo, the shape played).
    func strumShape(_ index: Int) -> (symbol: String, shape: GuitarChords.Shape)? {
        guard let symbol = chordSymbol(at: index),
              let d = GuitarChords.diagram(for: symbol, capo: capo ?? 0, strings: openStrings, frets: min(15, maxFret), chosen: chordShapes),
              d.shape.frets.count == stringCount else { return nil }
        return (symbol, d.shape)
    }

    /// The first note under the chord in effect at a note.
    private func chordStart(_ index: Int) -> Int {
        if let own = notes[...index].lastIndex(where: { !($0.chordSymbol ?? "").isEmpty }) { return own }
        guard let track = chordTrack else { return 0 }
        let times = onsets
        guard let at = track.last(where: { $0.at <= times[index] + 1e-6 })?.at else { return 0 }
        return times.firstIndex { $0 >= at - 1e-6 } ?? 0
    }

    /// The strings a strum strikes (lowest string first): every string of the chord's shape — or, for a bass
    /// note, the bass (every other bass note under the same chord, the fifth on a string beside it).
    func strumSpots(_ index: Int) -> [TabSpot] {
        guard let (symbol, shape) = strumShape(index) else { return [] }
        let played = shape.frets.enumerated().compactMap { s, f in f.map { TabSpot(string: s, fret: $0) } }
        guard notes[index].guitar?.strum == "bass", let root = played.first else { return played }
        let earlier = notes[chordStart(index)..<index].filter { $0.guitar?.strum == "bass" && !$0.rest }.count
        guard earlier % 2 == 1, let chord = GuitarChords.parse(symbol) else { return [root] }
        let capo = self.capo ?? 0
        let bass = openStrings[root.string] + capo + root.fret
        // The fifth: the one under the bass on a lower string (C's low G), else the one over it (G's open D) — near
        // the nut.
        let fifth = bass + ((chord.root + 7 - bass) % 12 + 12) % 12
        var best: (spot: TabSpot, rank: Int)?
        for (order, s) in [root.string - 1, root.string + 1, root.string + 2].enumerated() where openStrings.indices.contains(s) {
            for f in 0...5 {
                let pitch = openStrings[s] + capo + f
                guard pitch == fifth || pitch == fifth - 12 else { continue }
                let rank = (pitch < bass ? 0 : 20) + f * 3 + order
                if best == nil || rank < best!.rank { best = (TabSpot(string: s, fret: f), rank) }
            }
        }
        return [best?.spot ?? (played.count > 1 ? played[1] : root)]
    }

    /// What a strum sounds (MIDI, in the order the strings are struck): down, low to high; up, the top four strings
    /// high to low; a bass note alone.
    func strumPitches(_ index: Int) -> [Int] {
        let capo = self.capo ?? 0
        let pitches = strumSpots(index).map { openStrings[$0.string] + capo + $0.fret }
        return notes[index].guitar?.strum == "up" ? Array(pitches.suffix(4).reversed()) : pitches
    }

    /// Whether a note starts on a beat.
    func onBeat(_ index: Int, onsets times: [Double]) -> Bool {
        let x = times[index] / beatLength
        return abs(x - x.rounded()) < 1e-6
    }
}
