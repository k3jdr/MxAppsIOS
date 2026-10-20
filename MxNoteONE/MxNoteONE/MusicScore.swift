//
//  MusicScore.swift
//  MxNoteONE
//
//  Music scores on a page, inserted and edited like tables: a staff (treble
//  or bass clef, key and time signature, tempo) with a melody of notes and
//  rests — whole to sixteenth, dotted, sharp / flat / natural, tied — laid out
//  in bars that wrap to the container's width, eighths and sixteenths beamed.
//
//  Editing, as in MuseScore: letters A–G add a note after the cursor (in the
//  octave nearest the previous note), 0 a rest; 3–7 choose the length
//  (16th, 8th, quarter, half, whole) and . a dot; ↑ / ↓ move the selected
//  note a step (⌘ an octave); + / - / = sharp, flat, natural; T ties it to
//  the next note; ← / → move; Delete removes; Space plays. Double-click the
//  staff to put a note at that pitch; drag a note up or down. The Score
//  ribbon tab has the same tools. Playback uses the Mac's General MIDI piano.
//
//  Chords: ⇧A–G adds a note to the chord; ⌃K types chord symbols (C, Am7,
//  G/B) above the staff. ⌃L types lyrics under the notes (Space or Tab: next
//  note, - : next syllable). Guitar Tab adds a TAB staff with each note's
//  string and fret (any tuning — guitar, bass, ukulele, mandolin, banjo —
//  and a capo; GuitarTab.swift), or shows TAB only, with the rhythm under it.
//  Click the TAB (or ⌃T) to type frets onto its strings: ↑ / ↓ change string,
//  digits are frets, ⇧3–⇧7 lengths; ⌥ with a letter marks a technique (⌥H
//  hammer-on / pull-off, ⌥S slide, ⌥B bend, ⌥V vibrato, ⌥M palm mute…).
//  ⌥↑ / ⌥↓ move a note to another string. Chord diagrams (GuitarChords.swift)
//  show the voicing chosen for each chord, or a chart of every chord used.
//

import AppKit
import AVFoundation

// MARK: - Model

struct ScoreNote: Codable, Hashable, Identifiable {
    enum Duration: Int, Codable, CaseIterable, Identifiable {
        case whole = 1, half = 2, quarter = 4, eighth = 8, sixteenth = 16
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .whole: "Whole"
            case .half: "Half"
            case .quarter: "Quarter"
            case .eighth: "Eighth"
            case .sixteenth: "Sixteenth"
            }
        }
        /// MuseScore's number keys.
        var key: String {
            switch self {
            case .sixteenth: "3"
            case .eighth: "4"
            case .quarter: "5"
            case .half: "6"
            case .whole: "7"
            }
        }
        var glyph: String {
            switch self {
            case .whole: "𝅝"
            case .half: "𝅗𝅥"
            case .quarter: "♩"
            case .eighth: "♪"
            case .sixteenth: "𝅘𝅥𝅯"
            }
        }
    }

    var id = UUID()
    var duration: Duration = .quarter
    var dotted = false
    var rest = false
    /// 0 = C … 6 = B.
    var step = 0
    var octave = 4
    /// An accidental written on the note (-1 flat, 0 natural, 1 sharp); nil = as the key and bar give.
    var alter: Int?
    /// Tied to the next note.
    var tie = false
    /// More notes sounding with this one (a chord).
    var chord: [ChordTone]?
    /// A chord symbol above the staff (C, Am7, G/B).
    var chordSymbol: String?
    /// A syllable under the note (ending in "-" when the word goes on).
    var lyric: String?
    /// Figured bass under the note, top figure first ("6/4", "7/♯", "♯6"; "64" works too).
    var figures: String?
    /// A Roman numeral under the note ("V7", "ii6", "V65/V", "G: I").
    var numeral: String?
    /// The guitar string for the TAB staff (0 = low E … 5 = high E); nil = chosen automatically.
    var tabString: Int?
    /// A triplet note: three in the time of two.
    var tuplet: Bool?
    /// The tuplet's ratio, [actual, normal] — 5 in the time of 4 is [5, 4]; nil is a triplet (3 in the time of 2).
    var tupletRatio: [Int]?
    /// A grace note ("acciaccatura", slashed and quick, or "appoggiatura", taking time from the next note): small,
    /// before the note it leads to, and no time of its own in the bar.
    var grace: String?
    /// On a percussion staff: the drum (DrumKit id) — its place, notehead and sound.
    var drum: String?
    /// Slash notation: "beat" (a stemless slash per beat) or "rhythm" (slashes with stems showing the rhythm). A slash
    /// sits on the middle line and plays the chord symbol in effect.
    var slash: String?
    /// A dynamic marking under the note (pp … ff, sfz, fp).
    var dynamic: String?
    /// A slur starts here / ends here.
    var slurStart: Bool?
    var slurEnd: Bool?
    /// A hairpin starts here (1 crescendo, -1 diminuendo) / ends here.
    var hairpin: Int?
    var hairpinEnd: Bool?
    /// Articulations on the note (staccato, staccatissimo, tenuto, accent, marcato).
    var articulations: [String]?
    /// A fermata (hold) over the note.
    var fermata: Bool?
    /// An ornament: trill, mordent, prall (inverted mordent) or turn.
    var ornament: String?
    /// Under an ottava line: 8va (1) or 15ma (2) over the staff, 8vb (−1) or 15mb (−2) under it. The note is kept
    /// (and plays) where it sounds, and is drawn an octave (two) nearer the staff.
    var ottava: Int?
    /// Cross-staff: drawn on the staff below (1) or above (−1) — a piano's hands sharing a passage — while still
    /// counted, beamed and played with its own staff.
    var crossStaff: Int?
    /// How it's played on a fretted instrument: hammer-ons, slides, bends, vibrato, palm muting, harmonics…
    var guitar: GuitarMarks?

    /// Length in quarter notes.
    var beats: Double {
        guard grace == nil else { return 0 }
        return 4 / Double(duration.rawValue) * (dotted ? 1.5 : 1) * (tupletActual.map { Double(tupletNormal) / Double($0) } ?? 1)
    }
    /// How many notes the tuplet has (3 for a triplet), and in the time of how many.
    var tupletActual: Int? { tuplet == true ? (tupletRatio?.first ?? 3) : nil }
    var tupletNormal: Int { tupletRatio?.last ?? 2 }
    /// Length without the triplet (what three of them share two of).
    var normalBeats: Double { 4 / Double(duration.rawValue) * (dotted ? 1.5 : 1) }
    /// Steps up from C0 (for staff positions).
    var diatonic: Int { octave * 7 + step }
}

/// A note added to a chord.
struct ChordTone: Codable, Hashable {
    var step: Int
    var octave: Int
    var alter: Int?
    /// A drum played with the note (hi-hat with a kick).
    var drum: String?
    /// Its string on the TAB staff (as `ScoreNote.tabString`); nil: chosen with the rest.
    var tabString: Int?
    var diatonic: Int { octave * 7 + step }
}

/// A staff after the first: its clef, notes and second voice (key, time, tempo and bars are the score's).
struct ScoreStaff: Codable, Hashable {
    var name: String?
    var clef: ScoreData.Clef = .treble
    var notes: [ScoreNote] = []
    var voices: [[ScoreNote]]?
    /// A transposing instrument's interval ([steps, semitones]: sounding = written + it) and which instrument it is.
    var transpose: [Int]?
    var instrument: String?
    /// Its General MIDI sound (nil: piano).
    var program: Int?
}

/// What happens at a bar: a new key from it, a repeat starting there, or ending at its end.
struct ScoreBarMark: Codable, Hashable {
    var keyFifths: Int?
    var repeatStart: Bool?
    var repeatEnd: Bool?
    /// A bar of a 1st (or 2nd…) ending: played only on that time through the repeat.
    var ending: Int?
    /// A new tempo from this bar (quarter notes a minute), with a word for it (Allegro, a tempo…) and the note the
    /// metronome mark counts in ("quarter", "dotted", "half", "eighth").
    var tempo: Int?
    var tempoText: String?
    var tempoUnit: String?
    /// Gradually slower (-1, rit.) or faster (1, accel.) from this bar to the next tempo change.
    var gradual: Int?
    var isEmpty: Bool {
        keyFifths == nil && repeatStart != true && repeatEnd != true && ending == nil && tempo == nil && (tempoText ?? "").isEmpty && tempoUnit == nil && gradual == nil
    }
}

struct ScoreData: Codable, Hashable {
    enum Clef: String, Codable, CaseIterable, Identifiable {
        case treble, bass, percussion
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
        /// The bottom line's note, in steps from C0 (treble: E4, bass: G2; a drum staff is placed as treble).
        var bottomLine: Int { self == .bass ? 2 * 7 + 4 : 4 * 7 + 2 }
    }

    var title = ""
    var clef: Clef = .treble
    /// Sharps (+) or flats (−) in the key signature.
    var keyFifths = 0
    var beats = 4
    var beatUnit = 4
    /// Quarter notes per minute.
    var tempo = 100
    var notes: [ScoreNote] = []
    /// More voices on the staff (voice 2 …): stems down, sharing the bars with voice 1.
    var voices: [[ScoreNote]]?
    /// A guitar TAB staff under the music.
    var showTab: Bool?
    /// TAB only: the TAB staff (with the rhythm under it) instead of the music.
    var tabOnly: Bool?
    /// The fretted instrument (TabInstrument id) and its strings when they're tuned otherwise (MIDI, the TAB's
    /// bottom line first).
    var tabInstrument: String?
    var tabTuning: [Int]?
    /// A capo on this fret (guitar): TAB frets count from it; chord names and diagrams show the shapes played.
    var capo: Int?
    /// Guitar chord diagrams over the chord symbols.
    var chordDiagrams: Bool?
    /// The voicing chosen for a chord (by the chord as it's played — with a capo, the shape's name).
    var chordShapes: [String: GuitarChords.Shape]?
    /// A chart of every chord's diagram under the title.
    var chordChart: Bool?
    /// The first staff's General MIDI sound (nil: piano, or with TAB its instrument's).
    var program: Int?
    /// Under the title, at the right (a lead sheet's composer, arranger…).
    var composer: String?
    /// So many bars on each line (lead sheets: 4); nil fits as many as there's room for.
    var barsPerLine: Int?
    /// Eighths played long-short (swing, shuffle).
    var swing: Bool?
    /// Strums marked with arrows (↓ ↑) instead of the pick strokes ⊓ and V.
    var strumArrows: Bool?
    /// The chords a staff with none of its own follows — the first staff's, where they come (a rhythm guitar staff
    /// under a lead sheet). Set as the staff is looked at (`forStaff`), never kept.
    var chordTrack: [TimedChord]?

    /// How a chord symbol is written: with a capo, the shape played too — "E♭ (C)".
    func chordLabel(_ symbol: String) -> String {
        guard let capo, capo > 0 else { return symbol }
        let shape = GuitarChords.transposed(symbol, by: -capo)
        return shape == symbol ? symbol : "\(symbol) (\(shape))"
    }
    /// Key changes and repeat signs, by bar (0 = the first bar).
    var barMarks: [Int: ScoreBarMark]?
    /// More staves under the first (a piano's left hand, other instruments), sharing the bars.
    var staves: [ScoreStaff]?
    /// The first staff's name (shown nowhere yet; used in exports and Quick Help).
    var staffName: String?
    /// The first two staves joined by a brace, as for piano (bar lines run through both).
    var grandStaff: Bool?
    /// The first staff's transposing instrument: [steps, semitones] from where it's written to where it sounds (a
    /// B♭ clarinet is [-1, -2], as MusicXML's <transpose>), and which instrument (ScoreInstrument id). Its notes are
    /// kept as written; the score's keys are concert pitch.
    var transpose: [Int]?
    var instrument: String?
    /// Every staff shown as it sounds (transposing instruments in concert pitch).
    var concertPitch: Bool?

    // MARK: Staves

    var staffCount: Int { 1 + (staves?.count ?? 0) }

    /// One staff as a score of its own (its clef, notes and voices; the shared key, time, tempo and bars). A
    /// transposing instrument's staff has the keys it's written in (a B♭ clarinet's D major for concert C major).
    func forStaff(_ i: Int) -> ScoreData {
        var copy = self
        copy.staves = nil
        copy.grandStaff = nil
        if i > 0, let more = staves, more.indices.contains(i - 1) {
            let staff = more[i - 1]
            copy.clef = staff.clef
            copy.notes = staff.notes
            copy.voices = staff.voices
            copy.staffName = staff.name
            copy.showTab = nil
            copy.tabOnly = nil
            copy.transpose = staff.transpose
            copy.instrument = staff.instrument
            copy.program = staff.program
            // Slashes with no chord symbols of their own strum the first staff's chords.
            if !copy.hasChordSymbols, copy.notes.contains(where: { $0.slash != nil }) { copy.chordTrack = timedChords }
        }
        if let t = copy.transposition { copy.useWrittenKeys(for: t) }
        return copy
    }

    /// Puts a staff's notes (and clef) back from its own score.
    mutating func setStaff(_ i: Int, _ view: ScoreData) {
        if i == 0 {
            clef = view.clef
            notes = view.notes
            voices = view.voices
            staffName = view.staffName
            transpose = view.transpose
            instrument = view.instrument
            program = view.program
            return
        }
        var more = staves ?? []
        while more.count < i { more.append(ScoreStaff()) }
        more[i - 1] = ScoreStaff(name: view.staffName, clef: view.clef, notes: view.notes, voices: view.voices,
                                 transpose: view.transpose, instrument: view.instrument, program: view.program)
        staves = more
    }

    /// A staff's name for menus: its own, else "Staff 2 (Bass)".
    func staffTitle(_ i: Int) -> String {
        let st = forStaff(i)
        if let name = st.staffName, !name.isEmpty { return name }
        if grandStaff == true, i < 2 { return i == 0 ? "Right Hand" : "Left Hand" }
        return "Staff \(i + 1) (\(st.clef.title))"
    }

    // MARK: Key changes and repeats

    func mark(_ bar: Int) -> ScoreBarMark { barMarks?[bar] ?? ScoreBarMark() }

    mutating func setMark(_ bar: Int, _ change: (inout ScoreBarMark) -> Void) {
        var m = mark(bar)
        change(&m)
        var all = barMarks ?? [:]
        all[bar] = m.isEmpty ? nil : m
        barMarks = all.isEmpty ? nil : all
    }

    /// The key in a bar: the last change at or before it, else the key at the start.
    func fifths(inBar bar: Int) -> Int {
        guard let barMarks else { return keyFifths }
        return barMarks.filter { $0.key <= bar && $0.key > 0 && $0.value.keyFifths != nil }.max { $0.key < $1.key }?.value.keyFifths ?? keyFifths
    }

    /// The bar a note is in.
    func bar(of index: Int) -> Int {
        var filled = 0.0, bar = 0
        for (i, note) in notes.enumerated() {
            if i == index { return bar }
            filled += note.beats
            if filled >= measureLength - 1e-9 { bar += 1; filled = 0 }
        }
        return bar
    }

    // MARK: Tempo

    /// Tempo words with their usual speeds.
    static let tempoTerms: [(String, Int)] = [
        ("Largo", 50), ("Adagio", 66), ("Andante", 76), ("Moderato", 100), ("Allegretto", 112), ("Allegro", 132), ("Vivace", 160), ("Presto", 184),
    ]
    /// The notes a metronome mark can count in: (id, quarter notes in one, glyph).
    static let tempoUnits: [(String, Double, String)] = [("quarter", 1, "\u{2669}"), ("dotted", 1.5, "\u{2669}."), ("half", 2, "\u{1D15E}"), ("eighth", 0.5, "\u{266A}")]

    /// The tempo in a bar before any rit. / accel. (quarter notes a minute): the last change at or before it.
    func tempo(inBar bar: Int) -> Int {
        guard let barMarks else { return tempo }
        return barMarks.filter { $0.key <= bar && $0.key > 0 && $0.value.tempo != nil }.max { $0.key < $1.key }?.value.tempo ?? tempo
    }

    /// The bars with a tempo change or a rit. / accel. (the first bar counts, for its metronome mark).
    var tempoBars: [Int] {
        let marked = (barMarks ?? [:]).filter { $0.value.tempo != nil || $0.value.gradual != nil || !($0.value.tempoText ?? "").isEmpty }.map(\.key)
        return Array(Set(marked + [0])).sorted()
    }

    /// The tempo at a point in a bar (`x` quarter notes in), rit. and accel. included.
    func tempo(atBar bar: Int, offset x: Double) -> Double {
        let base = Double(tempo(inBar: bar))
        // The last rit./accel. at or before this bar, if no tempo change has come since.
        guard let barMarks, let (g, mark) = barMarks.filter({ $0.key <= bar && $0.value.gradual != nil }).max(by: { $0.key < $1.key }),
              let direction = mark.gradual,
              !barMarks.contains(where: { $0.key > g && $0.key <= bar && $0.value.tempo != nil && $0.key != g }) else { return base }
        // It runs to the next tempo change (reaching that tempo), else over two bars by about a third.
        let from = Double(tempo(inBar: g))
        let next = barMarks.filter { $0.key > g && $0.value.tempo != nil }.min { $0.key < $1.key }
        let endBar = next?.key ?? g + 2
        let to = next.flatMap { $0.value.tempo.map(Double.init) } ?? from * (direction < 0 ? 0.7 : 1.3)
        let done = min(1, (Double(bar - g) * measureLength + x) / (Double(endBar - g) * measureLength))
        return from + (to - from) * done
    }

    /// How a tempo is written: [word] ♩ = n (in the mark's note).
    func tempoLabel(bar: Int) -> String {
        let m = mark(bar)
        let unit = Self.tempoUnits.first { $0.0 == (m.tempoUnit ?? "quarter") } ?? Self.tempoUnits[0]
        let bpm = Int((Double(bar == 0 ? tempo : (m.tempo ?? tempo(inBar: bar))) / unit.1).rounded())
        let word = (m.tempoText ?? "").trimmingCharacters(in: .whitespaces)
        let number = bar == 0 || m.tempo != nil ? "\(unit.2) = \(bpm)" : ""
        return [word, number].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Bars in the order they play: at an end repeat, back to the last start repeat (or the beginning), once.
    func playOrder(bars: Int) -> [Int] {
        var order: [Int] = [], b = 0, start = 0, repeated = Set<Int>(), secondTime = false
        while b < bars, order.count < 5000 {
            let m = mark(b)
            if m.repeatStart == true { start = b }
            // The second time through, the 1st ending is skipped (the 2nd ending follows the repeat sign).
            if secondTime, m.ending == 1 {
                if m.repeatEnd == true { secondTime = false; start = b + 1 }
                b += 1
                continue
            }
            order.append(b)
            if m.repeatEnd == true {
                if !repeated.contains(b) {
                    repeated.insert(b)
                    b = start
                    secondTime = true
                    continue
                }
                secondTime = false
                start = b + 1
            }
            b += 1
        }
        return order
    }

    // MARK: Slash notation

    /// The middle line's note (where slashes sit).
    var middleLine: (step: Int, octave: Int) {
        let d = clef.bottomLine + 4
        return (d % 7, d / 7)
    }

    /// The chord symbol in effect at a note (its own, else the last one before it — or, on a staff that follows
    /// the first staff's chords, the one sounding there).
    func chordSymbol(at index: Int) -> String? {
        if let own = notes[...index].last(where: { !($0.chordSymbol ?? "").isEmpty })?.chordSymbol { return own }
        guard let track = chordTrack, !track.isEmpty else { return nil }
        let t = onsets[index]
        return track.last { $0.at <= t + 1e-6 }?.symbol
    }

    /// The chord symbols and where they come (quarter notes from the start).
    var timedChords: [TimedChord] {
        var t = 0.0, out: [TimedChord] = []
        for n in notes {
            if let c = n.chordSymbol, !c.isEmpty { out.append(TimedChord(at: t, symbol: c)) }
            t += n.beats
        }
        return out
    }

    /// The notes of a chord symbol, voiced for comping: the bass (or root) low, the chord above middle C.
    static func voicing(_ symbol: String) -> [Int] {
        guard let chord = GuitarChords.parse(symbol) else { return [] }
        let intervals: [String: [Int]] = [
            "": [0, 4, 7], "m": [0, 3, 7], "7": [0, 4, 7, 10], "maj7": [0, 4, 7, 11], "m7": [0, 3, 7, 10], "sus2": [0, 2, 7],
            "sus4": [0, 5, 7], "7sus4": [0, 5, 7, 10], "dim": [0, 3, 6], "dim7": [0, 3, 6, 9], "aug": [0, 4, 8], "6": [0, 4, 7, 9],
            "m6": [0, 3, 7, 9], "9": [0, 4, 10, 14], "add9": [0, 4, 7, 14], "m7b5": [0, 3, 6, 10], "5": [0, 7],
        ]
        let bass = 36 + (chord.bass ?? chord.root)
        let root = 53 + ((chord.root - 5 + 12) % 12)   // F3 … E4
        return [bass] + (intervals[chord.quality] ?? [0, 4, 7]).map { root + $0 }
    }

    /// Accidentals a new key cancels with naturals (steps and whether they were sharps).
    static func cancelled(from old: Int, to new: Int) -> (steps: [Int], sharps: Bool) {
        guard old != 0 else { return ([], true) }
        let sharps = old > 0
        let oldSteps = Array((sharps ? sharpOrder : flatOrder).prefix(abs(old)))
        if new == 0 || (new > 0) != sharps { return (oldSteps, sharps) }
        return (Array(oldSteps.dropFirst(abs(new))), sharps)
    }

    // MARK: Voices

    /// A voice's notes (0 = voice 1).
    func line(_ voice: Int) -> [ScoreNote] {
        voice == 0 ? notes : (voices.flatMap { $0.indices.contains(voice - 1) ? $0[voice - 1] : nil } ?? [])
    }

    mutating func setLine(_ voice: Int, _ list: [ScoreNote]) {
        if voice == 0 { notes = list; return }
        var all = voices ?? []
        while all.count < voice { all.append([]) }
        all[voice - 1] = list
        while all.last?.isEmpty == true { all.removeLast() }
        voices = all.isEmpty ? nil : all
    }

    /// The score as one voice sees it (its notes, the same key, time and clef): pitches, accidentals, ties and tab
    /// work per voice.
    func forVoice(_ voice: Int) -> ScoreData {
        guard voice != 0 else { return self }
        var copy = self
        copy.notes = line(voice)
        copy.voices = nil
        return copy
    }

    var hasSecondVoice: Bool { !line(1).isEmpty }
    /// Voices 1 and 2 (the staff shows two).
    static let voiceCount = 2

    /// Where each note starts, in quarter notes from the beginning.
    var onsets: [Double] {
        var t = 0.0
        return notes.map { n in defer { t += n.beats }; return t }
    }

    /// Tuplet groups in a bar: runs of notes of one tuplet kind, each as long as its "normal" notes (a triplet of
    /// eighths: three in the time of two eighths).
    func tupletGroups(in bar: Range<Int>) -> [[Int]] {
        var groups: [[Int]] = [], current: [Int] = [], total = 0.0, target = 0.0, ratio: [Int] = []
        for i in bar {
            let n = notes[i]
            guard let actual = n.tupletActual else {
                if n.grace != nil { continue }
                if !current.isEmpty { groups.append(current) }
                current = []; total = 0
                continue
            }
            let r = [actual, n.tupletNormal]
            if !current.isEmpty, r != ratio {
                groups.append(current)
                current = []; total = 0
            }
            if current.isEmpty { target = n.normalBeats * Double(n.tupletNormal); ratio = r }
            current.append(i)
            total += n.beats
            if total >= target - 1e-6 {
                groups.append(current)
                current = []; total = 0
            }
        }
        if !current.isEmpty { groups.append(current) }
        return groups
    }

    /// Tuplets offered (⌃2 … ⌃9 as in MuseScore): [actual, normal] and name.
    static let tupletKinds: [([Int], String)] = [
        ([2, 3], "Duplet"), ([3, 2], "Triplet"), ([4, 3], "Quadruplet"), ([5, 4], "Quintuplet"), ([6, 4], "Sextuplet"),
        ([7, 4], "Septuplet"), ([9, 8], "Nonuplet"),
    ]

    /// A number in superscript (for note names: C5 8³).
    static func superscript(_ n: Int) -> String {
        let map: [Character: Character] = ["0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹"]
        return String(String(n).compactMap { map[$0] })
    }

    /// Rests filling a length (largest first), to keep a voice in step.
    static func rests(for beats: Double) -> [ScoreNote] {
        var left = beats, result: [ScoreNote] = []
        let options: [(ScoreNote.Duration, Bool)] = [(.whole, true), (.whole, false), (.half, true), (.half, false), (.quarter, true),
                                                    (.quarter, false), (.eighth, true), (.eighth, false), (.sixteenth, false)]
        while left > 1e-6 {
            guard let fit = options.first(where: { ScoreNote(duration: $0.0, dotted: $0.1).beats <= left + 1e-6 }) else { break }
            result.append(ScoreNote(duration: fit.0, dotted: fit.1, rest: true))
            left -= result.last!.beats
        }
        return result
    }

    /// A bar's length in quarter notes.
    var measureLength: Double { Double(beats) * 4 / Double(beatUnit) }

    static let sharpOrder = [3, 0, 4, 1, 5, 2, 6]   // F C G D A E B
    static let flatOrder = [6, 2, 5, 1, 4, 0, 3]    // B E A D G C F

    /// The key signature's sharp (1) or flat (-1) on a step (in the first bar's key, or a bar's).
    func keyAlter(_ step: Int, bar: Int = 0) -> Int { Self.keyAlter(step, fifths: bar == 0 ? keyFifths : fifths(inBar: bar)) }

    static func keyAlter(_ step: Int, fifths: Int) -> Int {
        if fifths > 0, sharpOrder.prefix(fifths).contains(step) { return 1 }
        if fifths < 0, flatOrder.prefix(-fifths).contains(step) { return -1 }
        return 0
    }

    /// The key's alteration where a note is (its bar's key).
    func keyAlter(_ step: Int, at index: Int) -> Int { barMarks == nil ? keyAlter(step) : keyAlter(step, bar: bar(of: index)) }

    static let keyNames: [(Int, String)] = [
        (0, "C major / A minor"), (1, "G major / E minor"), (2, "D major / B minor"), (3, "A major / F♯ minor"),
        (4, "E major / C♯ minor"), (5, "B major / G♯ minor"), (6, "F♯ major / D♯ minor"), (-1, "F major / D minor"),
        (-2, "B♭ major / G minor"), (-3, "E♭ major / C minor"), (-4, "A♭ major / F minor"), (-5, "D♭ major / B♭ minor"),
        (-6, "G♭ major / E♭ minor"),
    ]
    static let times: [(Int, Int)] = [(4, 4), (3, 4), (2, 4), (2, 2), (6, 8), (3, 8), (9, 8), (12, 8), (5, 4)]

    /// Bars: the notes of each, in order (a note that runs past a bar line stays in its bar).
    var measures: [Range<Int>] {
        var result: [Range<Int>] = []
        var start = 0, filled = 0.0
        for (i, note) in notes.enumerated() {
            filled += note.beats
            if filled >= measureLength - 1e-9 {
                result.append(start..<(i + 1))
                start = i + 1
                filled = 0
            }
        }
        if start < notes.count || result.isEmpty { result.append(start..<notes.count) }
        return result
    }

    /// The pitch each note sounds (alterations: written, else earlier in the bar, else the key) — MIDI numbers.
    func midi(_ index: Int) -> Int? {
        let note = notes[index]
        guard !note.rest else { return nil }
        // A drum's General MIDI sound.
        if let drum = DrumKit.instrument(note.drum) { return drum.midi }
        // A slash plays its chord (its first note stands for it).
        if note.slash != nil { return midis(index).first }
        return Self.midi(step: note.step, octave: note.octave, alter: soundingAlter(index)) + soundingShift
    }

    static func midi(step: Int, octave: Int, alter: Int) -> Int {
        (octave + 1) * 12 + [0, 2, 4, 5, 7, 9, 11][step] + alter
    }

    /// The alteration in effect for a note.
    func soundingAlter(_ index: Int) -> Int {
        let note = notes[index]
        if let alter = note.alter, !tiedFrom(index) { return alter }
        // A note tied over keeps the pitch it's tied from (even across the bar line).
        if tiedFrom(index) { return soundingAlter(index - 1) }
        return alterBefore(index) ?? keyAlter(note.step, at: index)
    }

    /// Whether the note before is tied to this one (same line or space).
    func tiedFrom(_ index: Int) -> Bool {
        index > 0 && notes[index - 1].tie && !notes[index - 1].rest && !notes[index].rest && notes[index - 1].diatonic == notes[index].diatonic
    }

    /// An accidental written earlier in the same bar on the same line or space.
    func alterBefore(_ index: Int) -> Int? {
        guard let bar = measures.first(where: { $0.contains(index) }) else { return nil }
        let note = notes[index]
        return notes[bar.lowerBound..<index].last { !$0.rest && $0.diatonic == note.diatonic && $0.alter != nil }?.alter
    }

    /// Whether a note shows its accidental (it differs from what the key and the bar already give).
    func showsAccidental(_ index: Int) -> Bool {
        let note = notes[index]
        // The continuation of a tie doesn't repeat its accidental.
        guard !note.rest, let alter = note.alter, !tiedFrom(index), clef != .percussion, note.slash == nil else { return false }
        return alter != (alterBefore(index) ?? keyAlter(note.step, at: index))
    }

    /// Every pitch a note sounds (the note and its chord tones), as MIDI numbers.
    func midis(_ index: Int) -> [Int] {
        if notes[index].slash != nil, !notes[index].rest {
            return chordSymbol(at: index).map { Self.voicing($0).map { $0 + soundingShift } } ?? []
        }
        guard let main = midi(index) else { return [] }
        let tones = (notes[index].chord ?? []).map {
            DrumKit.instrument($0.drum)?.midi ?? Self.midi(step: $0.step, octave: $0.octave, alter: $0.alter ?? keyAlter($0.step, at: index)) + soundingShift
        }
        return [main] + tones
    }

    // MARK: Articulations and ornaments

    /// (id, name, key) — the keys as in MuseScore.
    static let articulationKinds: [(String, String, String)] = [
        ("staccato", "Staccato", "⇧S"), ("staccatissimo", "Staccatissimo", ""), ("tenuto", "Tenuto", "⇧N"),
        ("accent", "Accent", "⇧V"), ("marcato", "Marcato", "⇧O"),
    ]
    static let ornamentKinds: [(String, String)] = [("trill", "Trill"), ("mordent", "Mordent"), ("prall", "Inverted Mordent"), ("turn", "Turn")]

    /// The pitch a step above (1) or below (-1) a note, in the key (for ornaments).
    func neighbor(_ index: Int, _ direction: Int) -> Int? {
        let note = notes[index]
        guard !note.rest else { return nil }
        let d = note.diatonic + direction
        let step = ((d % 7) + 7) % 7, octave = d / 7
        return Self.midi(step: step, octave: octave, alter: keyAlter(step, at: index)) + soundingShift
    }

    // MARK: Dynamics, hairpins and slurs

    static let dynamics = ["ppp", "pp", "p", "mp", "mf", "f", "ff", "fff", "sfz", "fp"]
    /// MIDI velocities for the levels.
    static let dynamicLevels: [String: Int] = ["ppp": 24, "pp": 36, "p": 50, "mp": 64, "mf": 80, "f": 96, "ff": 112, "fff": 124]
    static let defaultVelocity = 80

    /// Slurs as (first note, last note).
    var slurs: [(Int, Int)] { spans(start: { $0.slurStart == true }, end: { $0.slurEnd == true }) }
    /// Hairpins as (first note, last note, 1 crescendo / -1 diminuendo).
    var hairpins: [(Int, Int, Int)] {
        spans(start: { $0.hairpin != nil }, end: { $0.hairpinEnd == true }).map { ($0.0, $0.1, notes[$0.0].hairpin ?? 1) }
    }

    /// Each start paired with the next end after it.
    private func spans(start: (ScoreNote) -> Bool, end: (ScoreNote) -> Bool) -> [(Int, Int)] {
        var result: [(Int, Int)] = [], open: Int?
        for (i, note) in notes.enumerated() {
            if let o = open, i > o, end(note) { result.append((o, i)); open = nil }
            if start(note) { open = i }
        }
        return result
    }

    var hasDynamics: Bool {
        (0..<Self.voiceCount).contains { v in line(v).contains { $0.dynamic != nil || $0.hairpin != nil } }
    }

    /// How loud each note plays (MIDI velocity): the dynamic in effect, hairpins growing or fading to the next
    /// dynamic (or by two levels), sfz and fp accenting their note.
    var velocities: [Int] {
        let onsets = self.onsets
        var result = Array(repeating: Self.defaultVelocity, count: notes.count)
        var level = Self.defaultVelocity
        let pins = hairpins
        var i = 0
        while i < notes.count {
            if let d = notes[i].dynamic {
                if let v = Self.dynamicLevels[d] { level = v }
                if d == "fp" { level = Self.dynamicLevels["p"]! }
            }
            if let pin = pins.first(where: { $0.0 == i }) {
                let from = level
                // Towards the next dynamic after the hairpin (if it goes that way), else two levels on.
                let next = notes[(pin.1)...].lazy.compactMap { $0.dynamic.flatMap { Self.dynamicLevels[$0] } }.first
                let to = next.flatMap { (($0 - from) * pin.2) > 0 ? $0 : nil } ?? max(20, min(127, from + pin.2 * 30))
                let span = max(1e-6, onsets[pin.1] - onsets[pin.0])
                for k in pin.0...pin.1 {
                    result[k] = from + Int((Double(to - from) * (onsets[k] - onsets[pin.0]) / span).rounded())
                }
                accent(pin.0...pin.1)
                level = to
                i = pin.1 + 1
                continue
            }
            result[i] = level
            accent(i...i)
            i += 1
        }
        func accent(_ range: ClosedRange<Int>) {
            for k in range {
                if notes[k].dynamic == "sfz" { result[k] = min(127, max(result[k], 112) + 8) }
                if notes[k].dynamic == "fp" { result[k] = 100 }
            }
        }
        return result
    }

    /// The dynamic level at a time (from this line's notes, accents left out) — for a voice without its own dynamics.
    func level(at time: Double) -> Int {
        let onsets = self.onsets, v = velocities
        guard let k = onsets.lastIndex(where: { $0 <= time + 1e-6 }) else { return Self.defaultVelocity }
        if notes[k].dynamic == "sfz" || notes[k].dynamic == "fp" {
            return notes[k].dynamic == "fp" ? Self.dynamicLevels["p"]! : (k > 0 ? v[k - 1] : Self.defaultVelocity)
        }
        return v[k]
    }

    var hasChordSymbols: Bool { notes.contains { !($0.chordSymbol ?? "").isEmpty } }
    var hasLyrics: Bool { notes.contains { !($0.lyric ?? "").isEmpty } }

    /// A short description (for exports and search).
    var summary: String {
        let key = Self.keyNames.first { $0.0 == keyFifths }?.1 ?? ""
        return "\(title.isEmpty ? "Music score" : title)\(capo.map { " (capo \($0))" } ?? "") — \(staffCount > 1 ? "\(staffCount) staves\(grandStaff == true ? " (piano)" : ""), " : "")\(measures.count) bars, \(beats)/\(beatUnit), \(key), ♩ = \(tempo)"
    }

    /// The melody in letter names (for exports): C4 q, D#4 8., r h…
    var noteNames: String {
        let bars = barMarks == nil ? [] : measures
        func marked(_ i: Int, _ text: String) -> String {
            guard let b = bars.firstIndex(where: { $0.contains(i) }) else { return text }
            var text = text
            let m = mark(b)
            if i == bars[b].lowerBound {
                if m.gradual != nil { text = (m.gradual! < 0 ? "rit. " : "accel. ") + text }
                if b > 0, m.tempo != nil || !(m.tempoText ?? "").isEmpty { text = "{\(tempoLabel(bar: b))} " + text }
                if b > 0, let k = m.keyFifths { text = "[key: \(Self.keyNames.first { $0.0 == k }?.1 ?? "\(k)")] " + text }
                if m.repeatStart == true { text = "|: " + text }
            }
            if i == bars[b].upperBound - 1, m.repeatEnd == true { text += " :|" }
            return text
        }
        return notes.enumerated().map { i, n in marked(i, name(i, n)) }.joined(separator: " · ")
            + (hasSecondVoice ? " ‖ voice 2: " + forVoice(1).noteNames : "")
            + (1..<staffCount).map { " ‖‖ \(staffTitle($0)): " + forStaff($0).noteNames }.joined()
    }

    /// Articulations, fermata and ornament in words (‹stacc. tr›).
    private func marks(_ n: ScoreNote) -> String {
        let short = ["staccato": "stacc.", "staccatissimo": "staccatiss.", "tenuto": "ten.", "accent": "acc.", "marcato": "marc.",
                     "trill": "tr", "mordent": "mord.", "prall": "prall", "turn": "turn"]
        let strum = n.guitar?.strum.map { ["down": "↓", "up": "↑", "bass": "bass"][$0] ?? $0 }
        let words = (strum.map { [(n.guitar?.dead == true ? "x" : "") + $0] } ?? []) + (n.articulations ?? []).compactMap { short[$0] }
            + (n.ornament.flatMap { short[$0] }.map { [$0] } ?? []) + (n.fermata == true ? ["fermata"] : [])
        return words.isEmpty ? "" : " ‹" + words.joined(separator: " ") + "›"
    }

    /// One note by name (C4 q, D♯4 8., r h…).
    private func name(_ i: Int, _ n: ScoreNote) -> String {
        let length = ["", "w", "h", "", "q", "", "", "", "8", "", "", "", "", "", "", "", "16"][n.duration.rawValue] + (n.dotted ? "." : "")
            + (n.tupletActual.map(Self.superscript) ?? "") + (n.grace != nil ? " grace" : "")
        if n.rest { return "r" + length + marks(n) }
        if n.slash != nil { return ((n.chordSymbol ?? "").isEmpty ? "" : "[\(n.chordSymbol!)] ") + "/ \(length)" + marks(n) }
        if let drum = DrumKit.instrument(n.drum) {
            let others = (n.chord ?? []).compactMap { DrumKit.instrument($0.drum)?.name }
            return ([drum.name] + others).joined(separator: "+") + " \(length)" + marks(n)
        }
        let alter = soundingAlter(i)
        let name = ["C", "D", "E", "F", "G", "A", "B"][n.step] + (alter > 0 ? "♯" : alter < 0 ? "♭" : "")
        let tones = (n.chord ?? []).map { t in
            ["C", "D", "E", "F", "G", "A", "B"][t.step] + ((t.alter ?? keyAlter(t.step, at: i)) > 0 ? "♯" : (t.alter ?? keyAlter(t.step, at: i)) < 0 ? "♭" : "") + "\(t.octave)"
        }
        let symbol = ((n.chordSymbol ?? "").isEmpty ? "" : "[\(n.chordSymbol!)] ") + (n.dynamic.map { "*\($0)* " } ?? "")
            + (n.hairpin.map { $0 > 0 ? "cresc. " : "dim. " } ?? "") + (n.slurStart == true ? "(" : "")
        let lyric = (n.lyric ?? "").isEmpty ? "" : " “\(n.lyric!)”"
        return symbol + "\(name)\(n.octave)" + tones.map { "+" + $0 }.joined() + " \(length)" + (n.tie ? "~" : "")
            + (n.slurEnd == true ? ")" : "") + marks(n) + lyric
    }
}

// MARK: - Playback

/// Plays scores with the Mac's General MIDI instruments (each staff its sound: piano, guitars, bass…), and how
/// fretted notes are played — bends and vibrato with pitch bend, slides as quick runs, hammer-ons without a fresh
/// pick, palm muting, dead notes, harmonics, let ring.
final class ScorePlayer {
    static let shared = ScorePlayer()

    private let engine = AVAudioEngine()
    private let sampler = AVAudioUnitSampler()
    /// General MIDI drums, for percussion staves.
    private let drums = AVAudioUnitSampler()
    private var soundingDrums: Set<UInt8> = []
    private var started = false
    private var work: [DispatchWorkItem] = []
    /// Keys sounding: program, channel and key.
    private var sounding: Set<[Int]> = []
    /// Samplers for sounds other than the piano, by General MIDI program.
    private var samplers: [Int: AVAudioUnitSampler] = [:]
    private let bank = URL(fileURLWithPath: "/System/Library/Components/CoreAudio.component/Contents/Resources/gs_instruments.dls")
    /// Channels taken in turn by notes that bend (so a bend bends only its note).
    private var nextChannel: UInt8 = 1
    /// The note being played (for highlighting), and the view playing.
    private(set) weak var view: ScoreView?
    var isPlaying: Bool { !work.isEmpty }

    private func start() {
        guard !started else { return }
        engine.attach(sampler)
        engine.connect(sampler, to: engine.mainMixerNode, format: nil)
        engine.attach(drums)
        engine.connect(drums, to: engine.mainMixerNode, format: nil)
        if FileManager.default.fileExists(atPath: bank.path) {
            try? sampler.loadSoundBankInstrument(at: bank, program: 0, bankMSB: UInt8(kAUSampler_DefaultMelodicBankMSB), bankLSB: 0)
            try? drums.loadSoundBankInstrument(at: bank, program: 0, bankMSB: UInt8(kAUSampler_DefaultPercussionBankMSB), bankLSB: 0)
        }
        #if DEBUG
        if Self.muted { engine.mainMixerNode.outputVolume = 0 }
        #endif
        try? engine.start()
        started = true
    }

    #if DEBUG
    /// Self-tests play silently.
    nonisolated(unsafe) static var muted = false
    #endif

    /// A single note or chord (heard while entering notes).
    func preview(_ midi: Int) { preview([midi]) }

    /// Drum sounds (heard while entering drum notes).
    func previewDrums(_ midis: [Int]) {
        start()
        let keys = midis.map { UInt8(max(0, min(127, $0))) }
        for key in keys { drums.startNote(key, withVelocity: 90, onChannel: 9) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            for key in keys { self?.drums.stopNote(key, onChannel: 9) }
        }
    }

    func preview(_ midis: [Int], program: Int = 0) {
        start()
        let s = instrument(program)
        let keys = midis.map { UInt8(max(0, min(127, $0))) }
        for key in keys { s.startNote(key, withVelocity: 80, onChannel: 0) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            for key in keys { s.stopNote(key, onChannel: 0) }
        }
    }

    /// A chord strummed, lowest string first.
    func strum(_ midis: [Int], program: Int) {
        start()
        let s = instrument(program)
        for (k, m) in midis.enumerated() {
            let key = UInt8(max(0, min(127, m)))
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(k) * 0.03) { s.startNote(key, withVelocity: 85, onChannel: 0) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { s.stopNote(key, onChannel: 0) }
        }
    }

    /// The sampler for a General MIDI sound (made when it's first wanted).
    private func instrument(_ program: Int) -> AVAudioUnitSampler {
        if program == 0 { return sampler }
        if let s = samplers[program] { return s }
        let s = AVAudioUnitSampler()
        engine.attach(s)
        engine.connect(s, to: engine.mainMixerNode, format: nil)
        if FileManager.default.fileExists(atPath: bank.path) {
            try? s.loadSoundBankInstrument(at: bank, program: UInt8(max(0, min(127, program))), bankMSB: UInt8(kAUSampler_DefaultMelodicBankMSB), bankLSB: 0)
        }
        samplers[program] = s
        return s
    }

    /// Plays every voice from a point (in quarter notes from the start) to the end, highlighting the notes sounding.
    /// Plays every voice from a point in a bar (`offset` quarter notes in), taking repeats.
    func play(_ score: ScoreData, fromBar startBar: Int, offset: Double, in view: ScoreView?) {
        stop()
        start()
        self.view = view
        let secondsPerBeat = 60 / Double(max(20, score.tempo))
        // Every staff's voices, as lines (staff 1 voice 1 first).
        let parts: [(staff: Int, voice: Int)] = (0..<score.staffCount).flatMap { st in (0..<ScoreData.voiceCount).map { (st, $0) } }
        let lines = parts.map { score.forStaff($0.staff).forVoice($0.voice) }
        let barsByVoice = lines.map { $0.notes.isEmpty ? [] : $0.measures }
        let barCount = barsByVoice.map(\.count).max() ?? 0
        var order = score.playOrder(bars: barCount)
        if let first = order.firstIndex(of: startBar) { order = Array(order[first...]) }
        #if DEBUG
        Self.plan = []
        Self.bends = []
        #endif
        // 1. What sounds: each voice's notes in playing order (tied notes as one), with when and how long (in beats).
        struct Sound {
            let voice: Int; let index: Int; var time: Double; var length: Double; let velocity: Int
            /// An acciaccatura: how far before the beat it plays (seconds), and how long.
            var early: Double = 0
            var quick: Double?
        }
        var sounds: [Sound] = []
        // Each line's sound, and how far it plays from where it's written (guitar sounds an octave under its music).
        let programs = lines.map(\.sound)
        let playShift = lines.map { $0.showTab == true ? -($0.tabOffset - ($0.capo ?? 0)) : 0 }
        let plans = lines.map { $0.hasGuitarMarks ? $0.tabPlan() : [] }
        for v in lines.indices {
            let line = lines[v]
            let onsets = line.onsets
            // How loud: the voice's own dynamics, else voice 1's at the same time.
            let ownDynamics = line.notes.contains { $0.dynamic != nil || $0.hairpin != nil }
            let loudness: [Int] = ownDynamics || v == 0 ? line.velocities : onsets.map { lines[0].level(at: $0) }
            var events: [(index: Int, time: Double)] = []
            var barTime = 0.0
            for (k, b) in order.enumerated() {
                defer { barTime += k == 0 ? score.measureLength - offset : score.measureLength }
                guard barsByVoice[v].indices.contains(b) else { continue }
                let bar = barsByVoice[v][b]
                guard let first = bar.first else { continue }
                for i in bar {
                    let t = barTime + onsets[i] - onsets[first] - (k == 0 ? offset : 0)
                    if t >= -1e-6 { events.append((i, max(0, t))) }
                }
            }
            var j = 0
            while j < events.count {
                let i = events[j].index
                var length = line.notes[i].beats
                var last = j
                // Tied notes sound as one.
                while line.notes[events[last].index].tie, last + 1 < events.count, events[last + 1].index == events[last].index + 1,
                      !line.notes[events[last + 1].index].rest, line.midi(events[last + 1].index) == line.midi(i) {
                    last += 1
                    length += line.notes[events[last].index].beats
                }
                sounds.append(Sound(voice: v, index: i, time: events[j].time, length: length, velocity: loudness[i]))
                j = last + 1
            }
        }
        // Grace notes: an acciaccatura is crushed in just before its note; an appoggiatura takes half the note's time.
        for k in sounds.indices.reversed() where lines[sounds[k].voice].notes[sounds[k].index].grace != nil {
            let kind = lines[sounds[k].voice].notes[sounds[k].index].grace
            guard let main = sounds[(k + 1)...].firstIndex(where: { $0.voice == sounds[k].voice && lines[$0.voice].notes[$0.index].grace == nil }) else { continue }
            let between = sounds[(k + 1)..<main].filter { $0.voice == sounds[k].voice }.count
            if kind == "appoggiatura" {
                let half = sounds[main].length / 2
                sounds[k].time = sounds[main].time
                sounds[k].length = half
                sounds[main].time += half
                sounds[main].length -= half
            } else {
                sounds[k].time = sounds[main].time
                sounds[k].early = 0.075 * Double(between + 1)
                sounds[k].quick = 0.07
            }
        }
        // Swing: each beat's two eighths long-short (two thirds of the beat and one third).
        if score.swing == true, score.beatUnit <= 4 {
            func swung(_ t: Double) -> Double {
                let a = t + offset, beat = (a + 1e-9).rounded(.down), f = a - beat
                return beat + (f <= 0.5 ? f * 4 / 3 : 2.0 / 3 + (f - 0.5) * 2 / 3) - offset
            }
            for k in sounds.indices {
                let from = swung(sounds[k].time), to = swung(sounds[k].time + sounds[k].length)
                sounds[k].time = from
                sounds[k].length = max(0.05, to - from)
            }
        }
        // 2. Beats to seconds through the tempo changes (rit. and accel. change it gradually).
        let barLength = score.measureLength, step = 1.0 / 24
        let total = Double(order.count) * barLength
        var clock: [Double] = [0]
        var beat = 0.0
        while beat < total {
            let u = beat + step / 2 + offset
            let k = max(0, min(order.count - 1, Int(u / barLength)))
            let bpm = order.isEmpty ? Double(score.tempo) : score.tempo(atBar: order[k], offset: u - Double(k) * barLength)
            clock.append(clock[clock.count - 1] + step * 60 / max(10, bpm))
            beat += step
        }
        func seconds(_ t: Double) -> Double {
            let i = t / step, lo = Int(i)
            guard lo + 1 < clock.count else { return clock[clock.count - 1] + (t - Double(clock.count - 1) * step) * secondsPerBeat }
            return clock[lo] + (clock[lo + 1] - clock[lo]) * (i - Double(lo))
        }
        // 3. Fermatas hold their note about twice as long; everything after waits.
        let holds = sounds.filter { lines[$0.voice].notes[$0.index].fermata == true }.map { ($0.time, $0.length) }
        func delay(_ t: Double) -> Double {
            holds.reduce(0) { $0 + ($1.0 + $1.1 <= t + 1e-6 ? seconds($1.0 + $1.1) - seconds($1.0) : 0) }
        }
        // Let ring: a note sounds on to the end of its run.
        var ringEnds: [Int: Double] = [:]   // sound → when its run ends (beats)
        for v in lines.indices where lines[v].hasGuitarMarks {
            for run in lines[v].runs({ $0.letRing == true }) {
                let inRun = sounds.indices.filter { sounds[$0].voice == v && run.contains(sounds[$0].index) }
                let end = inRun.map { sounds[$0].time + sounds[$0].length }.max() ?? 0
                for k in inRun { ringEnds[k] = end }
            }
        }
        // 4. Schedule: articulations shape length and loudness; ornaments play their notes; guitar techniques theirs.
        let lineOnsets = lines.map(\.onsets)
        var end = 0.0
        for (k, sound) in sounds.enumerated() {
            let line = lines[sound.voice]
            let note = line.notes[sound.index]
            let g = note.guitar
            let ref = NoteRef(voice: parts[sound.voice].voice, index: sound.index, staff: parts[sound.voice].staff)
            let start = max(0, seconds(sound.time) + delay(sound.time) - sound.early)
            var span = sound.quick ?? (seconds(sound.time + sound.length) - seconds(sound.time)) * (note.fermata == true ? 2 : 1)
            let marks = Set(note.articulations ?? [])
            let inSlur = line.slurs.contains { $0.0 <= sound.index && sound.index < $0.1 }
            var sounding = marks.contains("staccatissimo") ? 0.3 : marks.contains("staccato") ? 0.5
                : marks.contains("tenuto") || inSlur ? 1.0 : 0.95
            var velocity = sound.velocity
            if marks.contains("accent") { velocity += 18 }
            if marks.contains("marcato") { velocity += 28 }
            // The note before hammered on or pulled off to this one: no fresh pick.
            let previous = sounds[..<k].last { $0.voice == sound.voice }
            if let previous, line.notes[previous.index].guitar?.legato == true { velocity = Int(Double(velocity) * 0.65) }
            if g?.legato == true || g?.slide == "next" { sounding = 1.0 }
            if g?.palmMute == true { sounding = min(sounding, 0.35); velocity -= 12 }
            if g?.ghost == true { velocity -= 30 }
            if let ringEnd = ringEnds[k] { span = max(span, seconds(ringEnd) - seconds(sound.time)); sounding = 1.0 }
            if g?.dead == true { velocity = Int(Double(velocity) * 0.6) }
            // A strummed slash: its chord's voicing, string by string (it sounds where the neck is: no shift).
            let strum = line.strummed(sound.index) ? line.strumPitches(sound.index) : nil
            if strum != nil || g?.strum != nil {
                if g?.strum == "up" { velocity -= 8 }
                if line.onBeat(sound.index, onsets: lineOnsets[sound.voice]) { velocity += 6 }
            }
            let vel = UInt8(max(1, min(127, velocity)))
            var keys = strum.map { $0.map { UInt8(max(0, min(127, $0))) } }
                ?? line.midis(sound.index).map { UInt8(max(0, min(127, $0 + playShift[sound.voice]))) }
            // A harmonic sounds its overtone.
            if let h = g?.harmonic, let spot = plans[sound.voice].indices.contains(sound.index) ? plans[sound.voice][sound.index].first : nil {
                keys = [UInt8(max(0, min(127, line.harmonicPitch(spot, artificial: h == "artificial") + (line.capo ?? 0))))]
            }
            // The highlight lasts the whole note.
            let on = DispatchWorkItem { [weak self] in self?.view?.playing.insert(ref) }
            let off = DispatchWorkItem { [weak self] in self?.view?.playing.remove(ref) }
            DispatchQueue.main.asyncAfter(deadline: .now() + start, execute: on)
            DispatchQueue.main.asyncAfter(deadline: .now() + start + span * 0.97, execute: off)
            work += [on, off]
            end = max(end, start + span)
            guard !keys.isEmpty else { continue }
            // The pitches: the note (and chord) as written, or an ornament's quick notes on the main pitch.
            var parts: [(keys: [UInt8], at: Double, length: Double)] = [(keys, 0, g?.dead == true ? min(0.06, span) : span * sounding)]
            // Strummed: a string at a time — down from the lowest, up from the highest — all stopping together.
            if strum != nil || (g?.strum.map { $0 != "bass" } == true && keys.count > 1) {
                let order = strum != nil ? keys : (g?.strum == "up" ? keys.sorted(by: >) : keys.sorted())
                let spread = order.count < 2 ? 0 : min(0.022, max(0.006, span * 0.16 / Double(order.count)))
                let length = g?.dead == true ? min(0.05, span) : span * sounding
                parts = order.enumerated().map { k, key in ([key], Double(k) * spread, max(0.03, length - Double(k) * spread)) }
            }
            if let ornament = note.ornament, let main = keys.first {
                let up = line.neighbor(sound.index, 1).map { UInt8(max(0, min(127, $0 + playShift[sound.voice]))) } ?? main
                let down = line.neighbor(sound.index, -1).map { UInt8(max(0, min(127, $0 + playShift[sound.voice]))) } ?? main
                let quick = min(0.09, span / 4)
                let others = Array(keys.dropFirst())
                var run: [UInt8]
                switch ornament {
                case "trill": run = (0..<max(2, Int(span / quick))).map { $0 % 2 == 0 ? up : main }
                case "mordent": run = [main, down]
                case "prall": run = [main, up]
                default: run = [up, main, down]   // turn
                }
                parts = run.enumerated().map { ([$0.element], Double($0.offset) * quick, quick * 0.95) }
                let after = Double(run.count) * quick
                if ornament != "trill", after < span { parts.append(([main], after, (span - after) * sounding)) }
                if !others.isEmpty { parts.append((others, 0, span * sounding)) }
            }
            // Slides: a quick run up or down to the next note; in from below; away downward.
            if let main = keys.first, let slide = g?.slide {
                let quick = 0.04
                switch slide {
                case "next":
                    if let nextSound = sounds[(k + 1)...].first(where: { $0.voice == sound.voice }), let target = line.midis(nextSound.index).first.map({ $0 + playShift[sound.voice] }) {
                        let steps = Array(Swift.stride(from: Int(main), to: target, by: target > Int(main) ? 1 : -1).dropFirst())
                        let runStart = max(span * 0.55, span - Double(steps.count) * quick)
                        parts[0].length = runStart
                        for (j, m) in steps.enumerated() where runStart + Double(j) * quick < span {
                            parts.append(([UInt8(max(0, min(127, m)))], runStart + Double(j) * quick, quick))
                        }
                    }
                case "in":
                    parts.insert(([UInt8(max(0, Int(main) - 3))], -0.08, 0.04), at: 0)
                    parts.insert(([UInt8(max(0, Int(main) - 1))], -0.04, 0.04), at: 1)
                case "out":
                    parts[0].length = span * 0.55
                    for j in 1...4 { parts.append(([UInt8(max(0, Int(main) - j))], span * 0.55 + Double(j - 1) * quick, quick)) }
                default: break
                }
            }
            #if DEBUG
            Self.plan.append((ref, start, span, parts.map { ($0.keys, $0.at, $0.length) }))
            #endif
            // A percussion staff plays the General MIDI drums; a bend or vibrato plays on a channel of its own.
            let isDrum = line.clef == .percussion
            let program = programs[sound.voice]
            let player = instrument(program)
            var channel: UInt8 = 0
            if g?.bend != nil || g?.vibrato == true {
                channel = nextChannel
                nextChannel = nextChannel >= 8 ? 1 : nextChannel + 1
                scheduleBend(g!, channel: channel, on: player, start: start, span: span)
            }
            for part in parts {
                let ch = channel
                let down = DispatchWorkItem { [weak self] in
                    for key in part.keys {
                        if isDrum {
                            self?.drums.startNote(key, withVelocity: vel, onChannel: 9)
                            self?.soundingDrums.insert(key)
                        } else {
                            player.startNote(key, withVelocity: vel, onChannel: ch)
                            self?.sounding.insert([program, Int(ch), Int(key)])
                        }
                    }
                }
                let up = DispatchWorkItem { [weak self] in
                    for key in part.keys {
                        if isDrum {
                            self?.drums.stopNote(key, onChannel: 9)
                            self?.soundingDrums.remove(key)
                        } else {
                            player.stopNote(key, onChannel: ch)
                            self?.sounding.remove([program, Int(ch), Int(key)])
                        }
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + max(0, start + part.at), execute: down)
                DispatchQueue.main.asyncAfter(deadline: .now() + max(0, start + part.at) + max(0.03, part.length), execute: up)
                work += [down, up]
            }
        }
        guard !work.isEmpty else { return stop() }
        let finish = DispatchWorkItem { [weak self] in self?.stop() }
        DispatchQueue.main.asyncAfter(deadline: .now() + end + 0.05, execute: finish)
        work.append(finish)
        view?.needsDisplay = true
        NotebookStore.shared.editor.scorePlaying = true
    }

    #if DEBUG
    /// Self-tests: what the last play scheduled (note, start, length in seconds, and its pitches).
    nonisolated(unsafe) static var plan: [(ref: NoteRef, start: Double, span: Double, parts: [(keys: [UInt8], at: Double, length: Double)])] = []
    #endif

    /// A bend (up, held, and let back down for a release) or vibrato, as pitch bend on the note's channel (two
    /// semitones each way: a full bend is the most).
    private func scheduleBend(_ g: GuitarMarks, channel: UInt8, on player: AVAudioUnitSampler, start: Double, span: Double) {
        var events: [(Double, Double)] = [(0, 0)]   // (seconds from the note's start, semitones)
        if let bend = g.bend {
            let amount = min(2, bend)
            for k in 0...8 { events.append((span * (0.2 + 0.25 * Double(k) / 8), amount * Double(k) / 8)) }
            if g.release == true { for k in 0...8 { events.append((span * (0.62 + 0.25 * Double(k) / 8), amount * (1 - Double(k) / 8))) } }
        }
        if g.vibrato == true {
            let base = events.last?.1 ?? 0
            var t = span * 0.2
            while t < span * 0.98 {
                events.append((t, base + 0.3 * sin((t - span * 0.2) * 2 * .pi * 5.5)))
                t += 0.03
            }
        }
        events.append((span + 0.02, 0))
        #if DEBUG
        Self.bends.append((channel, events))
        #endif
        for (at, semis) in events {
            let value = UInt16(max(0, min(16383, 8192 + Int(semis / 2 * 8191))))
            let item = DispatchWorkItem { player.sendPitchBend(value, onChannel: channel) }
            DispatchQueue.main.asyncAfter(deadline: .now() + start + at, execute: item)
            work.append(item)
        }
    }

    #if DEBUG
    /// Self-tests: the pitch bends the last play scheduled (channel, and semitones over time).
    nonisolated(unsafe) static var bends: [(UInt8, [(Double, Double)])] = []
    #endif

    func stop() {
        work.forEach { $0.cancel() }
        work = []
        for k in sounding { instrument(k[0]).stopNote(UInt8(k[2]), onChannel: UInt8(k[1])) }
        for ch in UInt8(0)...8 {
            sampler.sendPitchBend(8192, onChannel: ch)
            for s in samplers.values { s.sendPitchBend(8192, onChannel: ch) }
        }
        for key in soundingDrums { drums.stopNote(key, onChannel: 9) }
        soundingDrums = []
        sounding = []
        view?.playing = []
        view = nil
        NotebookStore.shared.editor.scorePlaying = false
    }
}

// MARK: - The staff view

/// A note in a voice (0 = voice 1).
struct NoteRef: Hashable {
    let voice: Int
    let index: Int
    var staff = 0
}

/// Draws a score and edits it (it's the first responder while a score is being worked on).
final class ScoreView: NSView, NSTextFieldDelegate {
    /// The score being edited (the Score ribbon tab acts on it).
    static weak var active: ScoreView? {
        didSet {
            NotebookStore.shared.editor.scoreActive = active != nil
            if oldValue !== active { oldValue?.needsDisplay = true }
        }
    }

    weak var owner: ScoreElementView?
    /// The whole score (every staff).
    var fullScore: ScoreData { owner?.score ?? ScoreData() }
    /// The staff being drawn (or, between drawing, the one being written) as a score of its own — as it's shown
    /// (with Concert Pitch on, a transposing instrument's staff as it sounds).
    var score: ScoreData { shownStaff(drawingStaff) }
    /// Staves in concert pitch, worked out once for each change to the score.
    private var shownCache: (revision: Int, staves: [Int: ScoreData]) = (-1, [:])

    /// A staff as it's shown (as written, or in concert pitch).
    func shownStaff(_ i: Int) -> ScoreData {
        let full = fullScore
        guard full.concertPitch == true, let owner else { return full.forStaff(i) }
        if shownCache.revision != owner.revision { shownCache = (owner.revision, [:]) }
        if let cached = shownCache.staves[i] { return cached }
        let st = full.shown(i)
        shownCache.staves[i] = st
        return st
    }
    var isExport = false
    /// The staff being written (0 = the top one).
    private(set) var staffIndex = 0
    /// The staff the drawing code is on (it's `staffIndex` except while drawing the others).
    private var drawingStaff = 0

    /// The selected note (clicked or arrowed to), and where new notes go (an index from 0 to the number of notes).
    private(set) var selected: Int?
    /// The other end of a selection of several notes (⇧← ⇧→ or ⇧-click), from `selected`.
    private(set) var rangeEnd: Int?
    /// The selected notes, first to last (one note, or a run).
    var selectedRange: ClosedRange<Int>? {
        guard let s = selected else { return nil }
        guard let e = rangeEnd, cur.notes.indices.contains(e) else { return s...s }
        return min(s, e)...max(s, e)
    }
    private(set) var cursor = 0
    /// The note just typed: ↑ ↓, accidentals and ties act on it, while number keys and . set the next note's length.
    private(set) var lastEntered: Int?
    /// The notes sounding during playback (every voice).
    var playing: Set<NoteRef> = [] {
        didSet { if oldValue != playing { needsDisplay = true } }
    }
    /// The voice being written (0 = voice 1, stems up; 1 = voice 2, stems down).
    private(set) var voice = 0
    /// Typing frets into the TAB, and the string the next fret goes on (0 = the bottom line).
    private(set) var tabInput = false
    private(set) var tabString = 0
    /// The last fret typed (two digits quickly make one fret: 1 then 2 is 12).
    private var lastFret: (index: Int, string: Int, value: Int, at: Date)?
    /// The score as the current voice sees it.
    var cur: ScoreData { score.forVoice(voice) }

    /// The length, dot and triplet for new notes (shared with the Score ribbon tab).
    static var inputDuration: ScoreNote.Duration = .quarter
    static var inputDotted = false
    /// The tuplet new notes go in ([actual, normal]; nil: none).
    static var inputTuplet: [Int]?
    static var inputTriplet: Bool { inputTuplet == [3, 2] }
    /// New notes are entered as rhythmic slashes.
    static var inputSlash = false

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { !isExport }

    // MARK: Layout

    static let space: CGFloat = 8
    private var space: CGFloat { Self.space }
    /// Room for the title (and the composer under it, at the right).
    private var titleHeight: CGFloat {
        let full = fullScore
        let chart = chordChartHeight
        if full.title.isEmpty && (full.composer ?? "").isEmpty { return (showsConcertLabel ? 18 : 0) + chart }
        return 26 + ((full.composer ?? "").isEmpty ? 0 : 14) + chart
    }

    /// The chord chart under the title: each chord used, with its diagram, in the order they come.
    var chartChords: [String] {
        let full = fullScore
        guard full.chordChart == true else { return [] }
        var seen = Set<String>(), out: [String] = []
        for st in 0..<full.staffCount {
            for n in full.forStaff(st).notes {
                guard let sym = n.chordSymbol, !sym.isEmpty else { continue }
                let played = (full.capo ?? 0) > 0 ? GuitarChords.transposed(sym, by: -(full.capo ?? 0)) : sym
                if seen.insert(played).inserted { out.append(sym) }
            }
        }
        return out
    }
    private var chartItem: NSSize {
        let d = GuitarChords.size(space: space, strings: fullScore.stringCount)
        return NSSize(width: d.width + space * 1.6, height: d.height + space * 2.4)
    }
    private var chartColumns: Int { max(1, Int((bounds.width - space * 2) / chartItem.width)) }
    private var chordChartHeight: CGFloat {
        let n = chartChords.count
        guard n > 0 else { return 0 }
        let rows = (n + chartColumns - 1) / chartColumns
        return CGFloat(rows) * chartItem.height + space
    }
    // Room around a staff (for the staff being drawn; the functions take any staff's score).
    private func chordBand(_ st: ScoreData) -> CGFloat {
        guard st.hasChordSymbols else { return 0 }
        return space * 2.6 + (st.chordDiagrams == true ? GuitarChords.size(space: space, strings: st.stringCount).height + space * 0.4 : 0)
    }
    private func lyricBand(_ st: ScoreData) -> CGFloat { st.hasLyrics ? space * 2.8 : 0 }
    /// Figured bass (as many rows as the deepest stack) and Roman numerals, under the lyrics.
    private func figureBand(_ st: ScoreData) -> CGFloat {
        let rows = st.figureRows
        return rows == 0 ? 0 : CGFloat(rows) * FiguredBass.rowHeight + space * 1.0
    }
    private func numeralBand(_ st: ScoreData) -> CGFloat { st.hasNumerals ? space * 3.6 : 0 }
    /// Room for figures and numerals pushed down by low notes.
    private func analysisRoom(_ st: ScoreData) -> CGFloat { st.hasFigures || st.hasNumerals ? space * 2.2 : 0 }
    /// The TAB staff under the music (its strings, room for techniques over it); none when it's TAB only.
    private func tabBand(_ st: ScoreData) -> CGFloat {
        st.showTab == true && st.tabOnly != true ? tabGap * CGFloat(st.stringCount - 1) + space * 3.5 + techniqueRoom(st) : 0
    }
    /// Room over the TAB for bends, P.M., let ring and vibrato.
    private func techniqueRoom(_ st: ScoreData) -> CGFloat {
        st.showTab == true && st.notes.contains(where: { g in g.guitar.map { $0.bend != nil || $0.palmMute == true || $0.letRing == true || $0.vibrato == true || $0.harmonic == "artificial" || $0.tap == true } ?? false }) ? space * 5.4 : 0
    }
    /// TAB only: the TAB in place of the music, with the rhythm under it.
    private func tabOnly(_ st: ScoreData) -> Bool { st.showTab == true && st.tabOnly == true }
    /// The height of a staff's lines: five lines, or (TAB only) the TAB's strings and its rhythm.
    private func bodyHeight(_ st: ScoreData) -> CGFloat {
        tabOnly(st) ? tabGap * CGFloat(st.stringCount - 1) + space * 3.4 : space * 4
    }
    private var bodyHeight: CGFloat { bodyHeight(score) }
    private func dynamicBand(_ st: ScoreData) -> CGFloat { st.hasDynamics ? space * 3 : 0 }
    private func markBandAbove(_ st: ScoreData) -> CGFloat {
        let endings = (st.barMarks ?? [:]).values.contains { $0.ending != nil } ? space * 2.2 : 0
        let ottava = (st.notes + st.line(1)).contains { ($0.ottava ?? 0) > 0 } ? space * 2.4 : 0
        let guitar = st.notes.contains { n in n.guitar.map { $0.vibrato == true || $0.palmMute == true || $0.letRing == true || $0.bend != nil || $0.tap == true } ?? false } ? space * 3.6 : 0
        return endings + ottava + guitar + (tabOnly(st) ? 0 : strumBand(st.notes))
            + (st.notes.contains { $0.fermata == true || $0.ornament != nil || (st.hasSecondVoice && $0.articulations != nil) } ? space * 2.6 : 0)
    }
    private func markBandBelow(_ st: ScoreData) -> CGFloat {
        let ottava = (st.notes + st.line(1)).contains { ($0.ottava ?? 0) < 0 } ? space * 2.4 : 0
        return ottava + (st.hasSecondVoice && st.line(1).contains { $0.fermata == true || $0.ornament != nil || $0.articulations != nil } ? space * 3.4 : 0)
            + strumBand(st.line(1))
    }
    /// Room for strum marks (⊓ V, or arrows) over a voice's notes.
    private func strumBand(_ notes: [ScoreNote]) -> CGFloat {
        notes.contains { !$0.rest && $0.guitar?.strum.map { $0 != "bass" } == true } ? space * 2.2 : 0
    }
    private var chordBand: CGFloat { chordBand(score) }
    private var lyricBand: CGFloat { lyricBand(score) }
    private var tabBand: CGFloat { tabBand(score) }
    /// Dynamics and hairpins under the staff.
    private var dynamicBand: CGFloat { dynamicBand(score) }
    /// Room over the staff for marks above notes (fermatas, ornaments, and voice 1's articulations past its stems),
    /// and under it for voice 2's.
    private var markBandAbove: CGFloat { markBandAbove(score) }
    private var markBandBelow: CGFloat { markBandBelow(score) }
    /// Metronome marks, tempo words and rit. / accel. over everything else.
    private var tempoBand: CGFloat { space * 2.6 }

    /// Each staff's place in a system: how far its top line is from the system's top, and the system's height.
    private var staffOffsets: [CGFloat] = [0]
    private var cachedSystemHeight: CGFloat = 0
    private var systemHeight: CGFloat { cachedSystemHeight }

    private func measureStaves() {
        var y = tempoBand
        var offsets: [CGFloat] = []
        staffClefs = (0..<fullScore.staffCount).map { fullScore.forStaff($0).clef }
        for i in 0..<fullScore.staffCount {
            let st = shownStaff(i)
            let tabOnly = tabOnly(st)
            let above = (tabOnly ? space * 1.5 + techniqueRoom(st) + strumBand(st.notes) : space * 4.5 + markBandAbove(st)) + chordBand(st)
            let below = (tabOnly ? space * 1.2 : space * 4.5 + tabBand(st) + markBandBelow(st)) + lyricBand(st) + figureBand(st) + numeralBand(st) + analysisRoom(st) + dynamicBand(st)
            // Staves after the first sit a little closer (a grand staff's two hands most of all).
            let tighten: CGFloat = i == 0 ? 0 : (fullScore.grandStaff == true && i == 1 ? space * 2.2 : space * 1.2)
            offsets.append(y + above - tighten)
            y += above + bodyHeight(st) + below - tighten
        }
        staffOffsets = offsets
        cachedSystemHeight = y
    }

    /// Room at the left for a brace or bracket when there are several staves, and for transposing instruments' names.
    private var staffLeft: CGFloat { (fullScore.staffCount > 1 ? space * 2.8 : space) + labelRoom }

    static let labelFont = NSFont.systemFont(ofSize: 9.5)
    /// The names beside transposing instruments' staves ("B♭ Cl."), by staff.
    private var instrumentLabels: [Int: String] {
        let full = fullScore
        var labels: [Int: String] = [:]
        for i in 0..<full.staffCount { if let label = full.forStaff(i).instrumentLabel { labels[i] = label } }
        return labels
    }
    private var labelRoom: CGFloat {
        let widths = instrumentLabels.values.map { ($0 as NSString).size(withAttributes: [.font: Self.labelFont]).width }
        return widths.max().map { $0 + space * 0.8 } ?? 0
    }
    /// "Concert Pitch" over the music when transposing staves are shown as they sound.
    private var showsConcertLabel: Bool { fullScore.concertPitch == true && fullScore.hasTransposingStaff }

    /// Draws (or measures) as the given staff.
    private func useStaff(_ i: Int) {
        drawingStaff = max(0, min(fullScore.staffCount - 1, i))
        placed = allPlaced.filter { $0.staff == drawingStaff }
    }

    private func withStaff<T>(_ i: Int, _ body: () -> T) -> T {
        let old = drawingStaff
        useStaff(i)
        defer { useStaff(old) }
        return body()
    }
    /// TAB lines' spacing.
    private var tabGap: CGFloat { space * 1.3 }

    static let lyricFont = NSFont.systemFont(ofSize: 12)
    static let chordFont = NSFont.systemFont(ofSize: 13, weight: .semibold)

    struct Placed {
        let index: Int
        let x: CGFloat
        let system: Int
        var voice = 0
        var staff = 0
    }

    /// Every staff's placed notes, and the staff being drawn's.
    private var allPlaced: [Placed] = []
    private(set) var placed: [Placed] = []
    /// Where the caret goes for each cursor position (x, system).
    private var caretSpots: [(x: CGFloat, system: Int)] = []
    /// Bar lines (x, system), and where each system's notes start.
    private var barLines: [(x: CGFloat, system: Int, style: BarStyle)] = []
    private(set) var systemCount = 1
    private var systemStarts: [CGFloat] = []
    /// Each system's first bar (its key signature is that bar's key).
    private var systemFirstBars: [Int] = [0]
    /// Key changes within a line (x, system, from, to) and start-repeat signs (x, system).
    private var keyChanges: [(x: CGFloat, system: Int, from: Int, to: Int)] = []
    private var repeatStarts: [(x: CGFloat, system: Int)] = []
    /// Where each bar starts (x, system).
    private var barStarts: [Int: (x: CGFloat, system: Int)] = [:]

    enum BarStyle { case single, double, final, endRepeat }

    /// The height the score needs at a width.
    func neededHeight() -> CGFloat {
        layoutNotes()
        return titleHeight + CGFloat(systemCount) * systemHeight + space
    }

    private func width(of note: ScoreNote, index: Int, in line: ScoreData? = nil) -> CGFloat {
        let score = line ?? self.score
        // Grace notes are small and sit close to their note.
        if note.grace != nil { return space * (1.9 + (score.showsAccidental(index) ? 1.0 : 0)) }
        let base: CGFloat
        switch note.duration {
        case .sixteenth: base = 2.3
        case .eighth: base = 2.7
        case .quarter: base = 3.4
        case .half: base = 4.4
        case .whole: base = 5.4
        }
        var width = space * (base + (note.dotted ? 0.7 : 0) + (score.showsAccidental(index) ? 1.3 : 0))
        // Chord notes a step apart sit side by side; accidentals on chord notes need room.
        if let chord = note.chord, !chord.isEmpty {
            let positions = ([note.diatonic] + chord.map(\.diatonic)).sorted()
            if zip(positions, positions.dropFirst()).contains(where: { $1 - $0 == 1 }) { width += space * 1.2 }
            if chord.contains(where: { $0.alter != nil && $0.alter != score.keyAlter($0.step, at: index) }) { width += space * 1.2 }
        }
        // Words and chord names don't run into the next note.
        if let lyric = note.lyric, !lyric.isEmpty {
            width = max(width, (lyric as NSString).size(withAttributes: [.font: Self.lyricFont]).width + space * 1.2)
        }
        if let symbol = note.chordSymbol, !symbol.isEmpty {
            width = max(width, (score.chordLabel(symbol) as NSString).size(withAttributes: [.font: Self.chordFont]).width + space * 1.2)
            if score.chordDiagrams == true { width = max(width, GuitarChords.size(space: space).width + space * 1.4) }
        }
        if let dynamic = note.dynamic {
            width = max(width, (dynamic as NSString).size(withAttributes: [.font: Self.dynamicFont]).width + space * 1.0)
        }
        return width
    }

    private func headerWidth(system: Int) -> CGFloat {
        headerWidth(fifths: score.fifths(inBar: systemFirstBars.indices.contains(system) ? systemFirstBars[system] : 0), first: system == 0)
    }

    private func headerWidth(fifths: Int, first: Bool) -> CGFloat {
        space * (4.2 + CGFloat(abs(fifths)) * 1.05 + (first ? 2.8 : 0) + 0.8)
    }

    /// Room for a key change inside a line: naturals for what it cancels, then the new key.
    private func keyChangeWidth(bar m: Int) -> CGFloat {
        guard m > 0, let to = score.mark(m).keyFifths else { return 0 }
        let from = score.fifths(inBar: m - 1)
        guard from != to else { return 0 }
        return space * (CGFloat(ScoreData.cancelled(from: from, to: to).steps.count + abs(to)) * 1.05 + 1.2)
    }

    /// Places every voice's notes: notes that start together line up, and the bars wrap into lines.
    private func layoutNotes() {
        allPlaced = []
        caretSpots = []
        barLines = []
        systemStarts = []
        measureStaves()
        if staffIndex >= fullScore.staffCount { staffIndex = 0; voice = 0 }
        drawingStaff = staffIndex
        let usable = max(bounds.width - space - staffLeft, space * 20)
        // Every staff's voices (bars and beats line up across all of them).
        let parts: [(staff: Int, voice: Int)] = (0..<fullScore.staffCount).flatMap { st in (0..<ScoreData.voiceCount).map { (st, $0) } }
        let staffScores = (0..<fullScore.staffCount).map { shownStaff($0) }
        let lines = parts.map { staffScores[$0.staff].forVoice($0.voice) }
        let mineLine = parts.firstIndex { $0.staff == staffIndex && $0.voice == voice } ?? 0
        let barsByVoice = lines.map { $0.notes.isEmpty ? [] : $0.measures }
        let barCount = max(1, barsByVoice.map(\.count).max() ?? 1)
        // Each bar's notes by when they start (in quarter notes from the bar line).
        struct Event { let onset: Double; let voice: Int; let index: Int }   // voice: the line (staff and voice)
        var events: [[Event]] = []
        var gaps: [[(onset: Double, gap: CGFloat)]] = []
        for m in 0..<barCount {
            var list: [Event] = []
            for v in lines.indices where m < barsByVoice[v].count {
                var t = 0.0
                let bar = barsByVoice[v][m]
                for i in bar {
                    // Grace notes come just before their note (a sliver earlier each, so they get their own place).
                    var onset = t
                    if lines[v].notes[i].grace != nil {
                        let following = bar[i...].prefix { lines[v].notes[$0].grace != nil }.count
                        onset = t - 0.001 * Double(following)
                    }
                    list.append(Event(onset: onset, voice: v, index: i))
                    t += lines[v].notes[i].beats
                }
            }
            events.append(list)
            let onsets = Array(Set(list.map { ($0.onset * 1e6).rounded() / 1e6 })).sorted()
            var row: [(Double, CGFloat)] = []
            for (k, onset) in onsets.enumerated() {
                let next = k + 1 < onsets.count ? onsets[k + 1] : nil
                var gap = space * 2.2
                for e in list where abs(e.onset - onset) < 1e-6 {
                    let note = lines[e.voice].notes[e.index]
                    let w = width(of: note, index: e.index, in: lines[e.voice])
                    gap = max(gap, next.map { w * min(1, CGFloat(($0 - onset) / note.beats)) } ?? w)
                }
                row.append((onset, gap))
            }
            gaps.append(row)
        }
        let widths: [CGFloat] = gaps.map { $0.isEmpty ? space * 8 : $0.reduce(space * 1.2) { $0 + $1.gap } }
        // Fixed room: a start repeat before the notes, an end repeat after them, a key change (inside a line).
        let repeatRoom = (0..<barCount).map { score.mark($0).repeatStart == true ? space * 1.6 : 0 }
        let endRoom = (0..<barCount).map { score.mark($0).repeatEnd == true ? space * 1.2 : 0 }
        let keyRoom = (0..<barCount).map { keyChangeWidth(bar: $0) }
        func fixed(_ m: Int, atStart: Bool) -> CGFloat { repeatRoom[m] + endRoom[m] + (atStart ? 0 : keyRoom[m]) }
        // Bars into systems (lines). With Bars per Line, a line takes that many bars, squeezed a little if need be.
        let perLine = fullScore.barsPerLine
        let squeeze: CGFloat = perLine == nil ? 1 : 0.7
        var systems: [[Int]] = [[]]
        var used = headerWidth(fifths: score.keyFifths, first: true)
        for (m, w) in widths.enumerated() {
            let full = perLine.map { systems[systems.count - 1].count >= $0 } ?? false
            if !systems[systems.count - 1].isEmpty, full || used + w * squeeze + fixed(m, atStart: false) > usable {
                systems.append([])
                used = headerWidth(fifths: score.fifths(inBar: m), first: false)
            }
            used += w * squeeze + fixed(m, atStart: systems[systems.count - 1].isEmpty)
            systems[systems.count - 1].append(m)
        }
        systemCount = systems.count
        systemFirstBars = systems.map { $0.first ?? 0 }
        keyChanges = []
        repeatStarts = []
        barStarts = [:]
        var spots: [(Double, CGFloat, Int)] = []   // the current voice: (onset key, x, system) per note
        for (s, bars) in systems.enumerated() {
            let header = headerWidth(system: s)
            let start = staffLeft + header
            systemStarts.append(start)
            let natural = bars.reduce(0) { $0 + widths[$1] }
            let fixedRoom = bars.enumerated().reduce(0) { $0 + fixed($1.element, atStart: $1.offset == 0) }
            // Full lines are spread to the width (not the last one, unless it has its Bars per Line); a line too wide is squeezed.
            let fit = natural > 0 ? (usable - header - fixedRoom) / natural : 1
            let spread = s < systems.count - 1 || perLine.map { bars.count >= $0 } == true
            let stretch = spread ? max(squeeze, fit) : max(squeeze, min(1, fit))
            var x = start
            for (k, m) in bars.enumerated() {
                barStarts[m] = (k == 0 && m > 0 ? x - space * 0.4 : x, s)
                // A key change inside a line (at a line's start it's the line's key signature).
                if k > 0, keyRoom[m] > 0, let to = score.mark(m).keyFifths {
                    keyChanges.append((x, s, score.fifths(inBar: m - 1), to))
                    x += keyRoom[m]
                }
                if repeatRoom[m] > 0 {
                    repeatStarts.append((x, s))
                    x += repeatRoom[m]
                }
                var nx = x + space * 1.2 * stretch
                var xs: [Double: CGFloat] = [:]
                for (onset, gap) in gaps[m] {
                    xs[onset] = nx
                    nx += gap * stretch
                }
                for e in events[m] {
                    let key = (e.onset * 1e6).rounded() / 1e6
                    let ex = xs[key] ?? nx
                    let accidental = lines[e.voice].showsAccidental(e.index) ? space * 1.3 : 0
                    allPlaced.append(Placed(index: e.index, x: ex + accidental, system: s, voice: parts[e.voice].voice, staff: parts[e.voice].staff))
                    if e.voice == mineLine { spots.append((Double(e.index), ex, s)) }
                }
                if barsByVoice[mineLine].isEmpty, m == 0 { spots.append((-1, x + space * 1.2 * stretch, s)) }
                x += widths[m] * stretch + endRoom[m]
                let last = m == barCount - 1
                let style: BarStyle = score.mark(m).repeatEnd == true ? .endRepeat : last ? .final
                    : m + 1 < barCount && keyRoom[m + 1] > 0 ? .double : .single
                barLines.append((x, s, style))
            }
        }
        // The current voice's caret: before each of its notes, and after the last.
        caretSpots = spots.filter { $0.0 >= 0 }.sorted { $0.0 < $1.0 }.map { ($0.1 - space * 0.9, $0.2) }
        let mine = lines[mineLine]
        useStaff(staffIndex)
        if let lastPlaced = placed.last(where: { $0.voice == voice && $0.index == mine.notes.count - 1 }) {
            let note = mine.notes[lastPlaced.index]
            caretSpots.append((lastPlaced.x + width(of: note, index: lastPlaced.index, in: mine) - space * 1.2, lastPlaced.system))
        } else {
            caretSpots.append(((systemStarts.first ?? space * 6) + space, 0))
        }
    }

    /// A placed note (by voice and index).
    private func place(_ voice: Int, _ index: Int) -> Placed? {
        placed.first { $0.voice == voice && $0.index == index }
    }

    /// The top of a system's staff.
    private func staffTop(_ system: Int) -> CGFloat {
        titleHeight + CGFloat(system) * systemHeight
            + (staffOffsets.indices.contains(drawingStaff) ? staffOffsets[drawingStaff] : tempoBand + space * 4.5)
    }

    private func lyricY(_ system: Int) -> CGFloat {
        staffTop(system) + bodyHeight + (tabOnly(score) ? space * 0.8 : space * 3.4 + markBandBelow) + dynamicBand
    }

    /// The middle of the dynamics band (under the staff, clear of stems and ledger lines).
    private func dynamicY(_ system: Int) -> CGFloat {
        staffTop(system) + bodyHeight + (tabOnly(score) ? space * 1.2 : space * 3.6 + markBandBelow)
    }

    /// The TAB staff's top line (the highest string): the staff's place when it's TAB only.
    private func tabTop(_ system: Int) -> CGFloat {
        if tabOnly(score) { return staffTop(system) }
        return staffTop(system) + space * 4 + space * 4.2 + lyricBand + figureBand(score) + numeralBand(score) + analysisRoom(score) + dynamicBand + markBandBelow
            + techniqueRoom(score)
    }

    /// The top of the figured bass under the staff (under any lyrics, and clear of low notes and their stems),
    /// and of the Roman numerals under that.
    private func figureTop(_ system: Int) -> CGFloat {
        let base = staffTop(system) + bodyHeight + (tabOnly(score) ? space * 1.0 : space * 3.0 + markBandBelow) + dynamicBand + lyricBand
        guard lyricBand == 0, let lowest = lowestOnStaff[drawingStaff]?[system] else { return base }
        return min(max(base, lowest + space * 1.0), base + space * 2.2)
    }

    /// How far down each system's notes and stems reach, by staff (from the last drawing).
    private var lowestOnStaff: [Int: [Int: CGFloat]] = [:]

    private func measureLowest() {
        var lowest: [Int: CGFloat] = [:]
        for p in placed {
            guard let shape = shapes[NoteRef(voice: p.voice, index: p.index)] else { continue }
            let bottom = shape.up ? shape.low : shape.low + space * 3.5
            lowest[p.system] = max(lowest[p.system] ?? 0, bottom)
        }
        lowestOnStaff[drawingStaff] = lowest
    }
    private func numeralTop(_ system: Int) -> CGFloat { figureTop(system) + figureBand(score) + space * 0.6 }

    /// Half-spaces up from the bottom line of the staff a note is drawn on (an ottava draws it an octave or two
    /// nearer the staff; a cross-staff note sits on the staff above or below).
    private func position(_ note: ScoreNote) -> Int { position(note.diatonic, of: note) }

    /// The same for a chord note of `note` (or any line or space it's drawn against).
    private func position(_ diatonic: Int, of note: ScoreNote) -> Int {
        let st = drawnStaff(note)
        let clef = staffClefs.indices.contains(st) ? staffClefs[st] : score.clef
        return diatonic - (note.ottava ?? 0) * 7 - clef.bottomLine
    }

    private func y(position: Int, system: Int) -> CGFloat {
        staffTop(system) + space * 4 - CGFloat(position) * space / 2
    }

    /// A position on the staff a note is drawn on.
    private func y(position: Int, system: Int, of note: ScoreNote) -> CGFloat {
        staffTop(system, staff: drawnStaff(note)) + space * 4 - CGFloat(position) * space / 2
    }

    /// The top line of any staff in a system.
    private func staffTop(_ system: Int, staff: Int) -> CGFloat {
        titleHeight + CGFloat(system) * systemHeight
            + (staffOffsets.indices.contains(staff) ? staffOffsets[staff] : tempoBand + space * 4.5)
    }

    /// Every staff's clef (cross-staff notes are placed by the clef of the staff they're drawn on).
    private var staffClefs: [ScoreData.Clef] = []

    /// The staff a note is drawn on: its own, or the one above or below for a cross-staff note.
    private func drawnStaff(_ note: ScoreNote) -> Int {
        guard let c = note.crossStaff, c != 0 else { return drawingStaff }
        let t = drawingStaff + c
        guard staffClefs.indices.contains(t), staffClefs[t] != .percussion, staffClefs.indices.contains(drawingStaff),
              staffClefs[drawingStaff] != .percussion else { return drawingStaff }
        return t
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        bounds.fill()
        layoutNotes()
        let ink = NSColor.black
        if !score.title.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: ink]
            let size = (score.title as NSString).size(withAttributes: attrs)
            (score.title as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: 4), withAttributes: attrs)
        }
        if let composer = fullScore.composer, !composer.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: ink]
            let size = (composer as NSString).size(withAttributes: attrs)
            (composer as NSString).draw(at: NSPoint(x: bounds.width - space * 1.5 - size.width, y: 26), withAttributes: attrs)
        }
        drawChordChart(ink: ink)
        // Each staff in turn (the code below draws "the staff"), then what joins them, then the tempo marks.
        fretSpots = []
        diagramSpots = []
        for st in 0..<fullScore.staffCount {
            useStaff(st)
            // TAB only: the TAB in the music's place.
            if tabOnly(score) {
                shapes = [:]
                drawDynamics(ink: ink)
                drawWords(ink: ink)
                drawTab(ink: ink)
                drawStrums(ink: ink)
                continue
            }
            for s in 0..<systemCount { drawStaff(s, ink: ink) }
            for bar in barLines {
                let top = staffTop(bar.system), bottom = top + space * 4
                ink.setFill()
                switch bar.style {
                case .final, .endRepeat:
                    NSRect(x: bar.x - space * 0.9, y: top, width: 1, height: bottom - top).fill()
                    NSRect(x: bar.x - space * 0.5, y: top, width: 3.5, height: bottom - top).fill()
                    if bar.style == .endRepeat { repeatDots(x: bar.x - space * 1.5, system: bar.system) }
                case .double:
                    NSRect(x: bar.x - space * 0.45, y: top, width: 1, height: bottom - top).fill()
                    NSRect(x: bar.x - 0.5, y: top, width: 1, height: bottom - top).fill()
                case .single:
                    NSRect(x: bar.x - 0.5, y: top, width: 1, height: bottom - top).fill()
                }
            }
            // Start repeats: thick, thin, dots.
            for r in repeatStarts {
                let top = staffTop(r.system)
                ink.setFill()
                NSRect(x: r.x - 0.5, y: top, width: 3.5, height: space * 4).fill()
                NSRect(x: r.x + space * 0.55, y: top, width: 1, height: space * 4).fill()
                repeatDots(x: r.x + space * 0.95, system: r.system)
            }
            for change in keyChanges where score.clef != .percussion {
                drawKeySignature(change.to, cancelling: change.from, x: change.x + space * 0.5, system: change.system, ink: ink)
            }
            drawNotes(ink: ink)
            drawOttavas(ink: ink)
            drawSlurs(ink: ink)
            drawMarks(ink: ink)
            drawGuitarMarks(ink: ink)
            drawStrums(ink: ink)
            drawDynamics(ink: ink)
            drawWords(ink: ink)
            if score.showTab == true { drawTab(ink: ink) }
        }
        drawStaffGroups(ink: ink)
        drawInstrumentLabels(ink: ink)
        useStaff(0)
        drawEndings(ink: ink)
        drawTempos(ink: ink)
        if let capo = fullScore.capo, capo > 0 {
            let attrs: [NSAttributedString.Key: Any] = [.font: Self.tempoWordFont, .foregroundColor: ink]
            let label = "Capo \(capo)" as NSString
            let size = label.size(withAttributes: attrs)
            label.draw(at: NSPoint(x: bounds.width - space * 1.5 - size.width, y: tempoY(0) - size.height / 2), withAttributes: attrs)
        }
        useStaff(staffIndex)
        drawCaret()
    }

    // MARK: 1st and 2nd endings

    /// Brackets over the bars of each ending, numbered "1." "2."; the last ending is left open at its end.
    private func drawEndings(ink: NSColor) {
        let marks = fullScore.barMarks ?? [:]
        let bars = marks.filter { $0.value.ending != nil }.map(\.key).sorted()
        guard !bars.isEmpty else { return }
        // Runs of bars with the same ending.
        var runs: [(number: Int, from: Int, to: Int)] = []
        for b in bars {
            let n = marks[b]?.ending ?? 0
            if let last = runs.last, last.number == n, last.to == b - 1 { runs[runs.count - 1].to = b } else { runs.append((n, b, b)) }
        }
        let highest = runs.map(\.number).max() ?? 1
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: ink]
        ink.setFill()
        for run in runs {
            guard let start = barStarts[run.from] else { continue }
            let endBar = barLines.indices.contains(run.to) ? barLines[run.to] : nil
            for s in start.system...max(start.system, endBar?.system ?? start.system) {
                let y = staffTop(s) - space * 2.4
                let from = s == start.system ? start.x + space * 0.2 : (systemStarts.indices.contains(s) ? systemStarts[s] : start.x)
                let to = (s == endBar?.system ? endBar!.x : lineEnd) - space * 0.4
                guard to > from else { continue }
                NSRect(x: from, y: y, width: to - from, height: 1.2).fill()
                if s == start.system {
                    NSRect(x: from, y: y, width: 1.2, height: space * 1.6).fill()
                    ("\(run.number)." as NSString).draw(at: NSPoint(x: from + space * 0.4, y: y + 1), withAttributes: attrs)
                }
                // The 1st ending closes over its last bar line; the last one stays open.
                if s == endBar?.system, run.number < highest {
                    NSRect(x: to - 1.2, y: y, width: 1.2, height: space * 1.6).fill()
                }
            }
        }
    }

    // MARK: Ottava lines

    static let ottavaFont = NSFont(name: "Georgia-BoldItalic", size: 11) ?? .boldSystemFont(ofSize: 11)

    /// 8va, 15ma (over the staff) and 8vb, 15mb (under it): the sign at the first note, a dashed line to the last
    /// and a hook at its end — on each line of music the passage runs through.
    private func drawOttavas(ink: NSColor) {
        for v in 0..<ScoreData.voiceCount {
            let line = score.line(v)
            guard line.contains(where: { $0.ottava != nil }) else { continue }
            let spots = placed.filter { $0.voice == v }
            var i = 0
            while i < line.count {
                guard let o = line[i].ottava, o != 0 else { i += 1; continue }
                var j = i
                while j + 1 < line.count, line[j + 1].ottava == o { j += 1 }
                let run = Array(i...j)
                for system in Set(run.compactMap { k in spots.first { $0.index == k }?.system }).sorted() {
                    let here = run.compactMap { k in spots.first { $0.index == k && $0.system == system } }
                    guard let first = here.first, let last = here.last else { continue }
                    let continues = last.index < j
                    drawOttava(o, from: first.x - space * 0.3, to: last.x + space * (continues ? 2.4 : 1.6), system: system,
                               notes: here.map { NoteRef(voice: v, index: $0.index) }, hook: !continues,
                               continued: first.index > i, color: colorFor(NoteRef(voice: v, index: first.index), ink: ink))
                }
                i = j + 1
            }
        }
    }

    private func drawOttava(_ o: Int, from x1: CGFloat, to x2: CGFloat, system: Int, notes: [NoteRef], hook: Bool, continued: Bool, color: NSColor) {
        let above = o > 0
        let staffTopY = staffTop(system), staffBottomY = staffTop(system) + space * 4
        // Clear of the notes' heads and stems.
        let tops = notes.compactMap { shapes[$0].map { $0.up ? $0.high - space * 3.5 : $0.high } }
        let bottoms = notes.compactMap { shapes[$0].map { $0.up ? $0.low : $0.low + space * 3.5 } }
        let y = above ? min(staffTopY - space * 1.8, (tops.min() ?? staffTopY) - space * 1.3)
                      : max(staffBottomY + space * 1.8, (bottoms.max() ?? staffBottomY) + space * 1.3)
        let label = (abs(o) == 2 ? (above ? "15ma" : "15mb") : (above ? "8va" : "8vb"))
        let text = (continued ? "(\(label))" : label) as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: Self.ottavaFont, .foregroundColor: color]
        let size = text.size(withAttributes: attrs)
        text.draw(at: NSPoint(x: x1, y: y - size.height / 2), withAttributes: attrs)
        color.setStroke()
        let dash = NSBezierPath()
        dash.move(to: NSPoint(x: x1 + size.width + 3, y: y))
        dash.line(to: NSPoint(x: max(x1 + size.width + 6, x2), y: y))
        if hook { dash.line(to: NSPoint(x: max(x1 + size.width + 6, x2), y: y + (above ? 1 : -1) * space * 0.9)) }
        dash.lineWidth = 1
        dash.setLineDash([4, 3], count: 2, phase: 0)
        dash.stroke()
    }

    // MARK: Transposing instruments

    /// The instrument's name beside each transposing staff ("B♭ Cl."), and "Concert Pitch" over the music when
    /// they're shown as they sound.
    private func drawInstrumentLabels(ink: NSColor) {
        let labels = instrumentLabels
        if showsConcertLabel {
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10.5, weight: .medium), .foregroundColor: ink]
            ("Concert Pitch" as NSString).draw(at: NSPoint(x: space, y: 5), withAttributes: attrs)
        }
        guard !labels.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [.font: Self.labelFont, .foregroundColor: ink]
        // Right-aligned before the staff (and before a brace or bracket).
        let right = staffLeft - (fullScore.staffCount > 1 ? space * 2.2 : space * 0.5)
        for (i, label) in labels {
            let size = (label as NSString).size(withAttributes: attrs)
            withStaff(i) {
                for system in 0..<systemCount {
                    (label as NSString).draw(at: NSPoint(x: right - size.width, y: staffTop(system) + space * 2 - size.height / 2), withAttributes: attrs)
                }
            }
        }
    }

    // MARK: Several staves

    /// Where staves meet: a line down the left of each system, a brace for a grand staff (or a bracket for other
    /// staves), and bar lines running through from one staff to the next.
    private func drawStaffGroups(ink: NSColor) {
        let count = fullScore.staffCount
        guard count > 1 else { return }
        let tops = (0..<count).map { st in withStaff(st) { (0..<systemCount).map { staffTop($0) } } }
        ink.setFill()
        for system in 0..<systemCount {
            let top = tops[0][system], bottom = tops[count - 1][system] + space * 4
            // The system's left line.
            NSRect(x: staffLeft - 0.5, y: top, width: 1.2, height: bottom - top).fill()
            if fullScore.grandStaff == true {
                drawBrace(x: staffLeft - space * 1.5, top: top, bottom: tops[1][system] + space * 4, ink: ink)
                if count > 2 { drawBracket(x: staffLeft - space * 1.0, top: tops[2][system], bottom: bottom, ink: ink) }
            } else {
                drawBracket(x: staffLeft - space * 1.0, top: top, bottom: bottom, ink: ink)
            }
            // Bar lines through the gaps between staves.
            for bar in barLines where bar.system == system {
                for st in 0..<(count - 1) {
                    let from = tops[st][system] + space * 4, to = tops[st + 1][system]
                    let wide = bar.style == .final || bar.style == .endRepeat
                    if wide {
                        NSRect(x: bar.x - space * 0.9, y: from, width: 1, height: to - from).fill()
                        NSRect(x: bar.x - space * 0.5, y: from, width: 3.5, height: to - from).fill()
                    } else {
                        NSRect(x: bar.x - 0.5, y: from, width: 1, height: to - from).fill()
                        if bar.style == .double { NSRect(x: bar.x - space * 0.45, y: from, width: 1, height: to - from).fill() }
                    }
                }
            }
            for r in repeatStarts where r.system == system {
                for st in 0..<(count - 1) {
                    let from = tops[st][system] + space * 4, to = tops[st + 1][system]
                    NSRect(x: r.x - 0.5, y: from, width: 3.5, height: to - from).fill()
                    NSRect(x: r.x + space * 0.55, y: from, width: 1, height: to - from).fill()
                }
            }
        }
    }

    /// A curly brace from top to bottom (piano staves).
    private func drawBrace(x: CGFloat, top: CGFloat, bottom: CGFloat, ink: NSColor) {
        let mid = (top + bottom) / 2, w = space * 1.3
        let path = NSBezierPath()
        path.move(to: NSPoint(x: x + w, y: top))
        path.curve(to: NSPoint(x: x, y: mid), controlPoint1: NSPoint(x: x - w * 0.2, y: top + (mid - top) * 0.25),
                   controlPoint2: NSPoint(x: x + w * 0.9, y: mid - (mid - top) * 0.2))
        path.curve(to: NSPoint(x: x + w, y: bottom), controlPoint1: NSPoint(x: x + w * 0.9, y: mid + (bottom - mid) * 0.2),
                   controlPoint2: NSPoint(x: x - w * 0.2, y: bottom - (bottom - mid) * 0.25))
        path.curve(to: NSPoint(x: x + w * 0.3, y: mid), controlPoint1: NSPoint(x: x + w * 0.45, y: bottom - (bottom - mid) * 0.3),
                   controlPoint2: NSPoint(x: x + w * 1.6, y: mid + (bottom - mid) * 0.15))
        path.curve(to: NSPoint(x: x + w, y: top), controlPoint1: NSPoint(x: x + w * 1.6, y: mid - (mid - top) * 0.15),
                   controlPoint2: NSPoint(x: x + w * 0.45, y: top + (mid - top) * 0.3))
        path.close()
        ink.setFill()
        path.fill()
    }

    /// A square bracket (ensemble staves): a thick line with hooks.
    private func drawBracket(x: CGFloat, top: CGFloat, bottom: CGFloat, ink: NSColor) {
        ink.setFill()
        NSRect(x: x, y: top - space * 0.4, width: space * 0.45, height: bottom - top + space * 0.8).fill()
        for (y, dir) in [(top - space * 0.4, -1.0), (bottom + space * 0.4, 1.0)] {
            let hook = NSBezierPath()
            hook.move(to: NSPoint(x: x, y: y))
            hook.curve(to: NSPoint(x: x + space * 1.3, y: y + CGFloat(dir) * space * 0.7), controlPoint1: NSPoint(x: x + space * 0.6, y: y),
                       controlPoint2: NSPoint(x: x + space * 1.1, y: y + CGFloat(dir) * space * 0.3))
            hook.line(to: NSPoint(x: x + space * 1.15, y: y + CGFloat(dir) * space * 0.75))
            hook.curve(to: NSPoint(x: x, y: y - CGFloat(dir) * space * 0.25), controlPoint1: NSPoint(x: x + space * 0.9, y: y + CGFloat(dir) * space * 0.3),
                       controlPoint2: NSPoint(x: x + space * 0.4, y: y - CGFloat(dir) * space * 0.1))
            hook.close()
            hook.fill()
        }
    }

    // MARK: Tempo marks

    static let tempoWordFont = NSFont(name: "Georgia-Bold", size: 13) ?? .boldSystemFont(ofSize: 13)
    static let tempoItalicFont = NSFont(name: "Georgia-Italic", size: 13) ?? .systemFont(ofSize: 13)

    /// The tempo band's text line in a system.
    private func tempoY(_ system: Int) -> CGFloat { staffTop(system) - space * 4.5 - chordBand - markBandAbove - tempoBand + space * 0.9 }

    /// Metronome marks (♩ = 120, with a tempo word) where the tempo is set or changes; rit. / accel. with a dashed
    /// line to where the change ends.
    private func drawTempos(ink: NSColor) {
        let bars = score.tempoBars
        let barCount = barLines.count
        for b in bars where b < max(1, barCount) {
            let at = b == 0 ? (x: space * 1.2, system: 0) : (barStarts[b] ?? (x: space * 1.2, system: 0))
            var x = at.x
            let y = tempoY(at.system)
            let label = score.tempoLabel(bar: b)
            let mark = score.mark(b)
            if !label.isEmpty {
                let text = NSMutableAttributedString()
                let word = (mark.tempoText ?? "").trimmingCharacters(in: .whitespaces)
                if !word.isEmpty {
                    text.append(NSAttributedString(string: word + (label.count > word.count ? " " : ""), attributes: [.font: Self.tempoWordFont, .foregroundColor: ink]))
                }
                let number = word.isEmpty ? label : String(label.dropFirst(word.count)).trimmingCharacters(in: .whitespaces)
                if !number.isEmpty {
                    // The note glyph a little larger.
                    let glyphEnd = number.firstIndex(of: "=") ?? number.startIndex
                    let glyph = String(number[..<glyphEnd]), rest = String(number[glyphEnd...])
                    text.append(NSAttributedString(string: "(" , attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: ink]))
                    text.append(NSAttributedString(string: glyph, attributes: [.font: NSFont(name: "Apple Symbols", size: 17) ?? .systemFont(ofSize: 15), .foregroundColor: ink,
                                                                               .baselineOffset: -1]))
                    text.append(NSAttributedString(string: rest + ")", attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: ink]))
                    if word.isEmpty {
                        // A bare metronome mark goes without brackets.
                        text.deleteCharacters(in: NSRange(location: text.length - 1, length: 1))
                        let open = (text.string as NSString).range(of: "(")
                        if open.location != NSNotFound { text.deleteCharacters(in: open) }
                    }
                }
                let size = text.size()
                text.draw(at: NSPoint(x: x, y: y - size.height / 2))
                x += size.width + space * 0.8
            }
            // Swing eighths, after the first tempo.
            if b == 0, fullScore.swing == true {
                let attrs: [NSAttributedString.Key: Any] = [.font: Self.tempoWordFont, .foregroundColor: ink]
                let word = "Swing" as NSString
                let size = word.size(withAttributes: attrs)
                word.draw(at: NSPoint(x: x, y: y - size.height / 2), withAttributes: attrs)
                x += size.width + space * 0.8
            }
            if let direction = mark.gradual {
                let attrs: [NSAttributedString.Key: Any] = [.font: Self.tempoItalicFont, .foregroundColor: ink]
                let word = direction < 0 ? "rit." : "accel."
                let size = (word as NSString).size(withAttributes: attrs)
                (word as NSString).draw(at: NSPoint(x: x, y: y - size.height / 2), withAttributes: attrs)
                // Dashes to the next tempo change (or two bars on).
                let next = bars.first { $0 > b && score.mark($0).tempo != nil } ?? min(b + 2, barCount)
                let endAt: (x: CGFloat, system: Int) = barStarts[next].map { ($0.x - space * 0.6, $0.system) }
                    ?? (barLines.last.map { ($0.x - space, $0.system) } ?? (lineEnd, at.system))
                let startX = x + size.width + space * 0.5
                for s in at.system...max(at.system, endAt.system) {
                    let from = s == at.system ? startX : (systemStarts.indices.contains(s) ? systemStarts[s] : space * 6)
                    let to = s == endAt.system ? endAt.x : lineEnd
                    guard to - from > space else { continue }
                    let path = NSBezierPath()
                    path.move(to: NSPoint(x: from, y: tempoY(s) + 1))
                    path.line(to: NSPoint(x: to, y: tempoY(s) + 1))
                    path.setLineDash([4, 4], count: 2, phase: 0)
                    path.lineWidth = 1
                    ink.setStroke()
                    path.stroke()
                }
            }
        }
    }

    // MARK: Articulations, ornaments, fermatas

    /// Articulations by the note head (away from the stem; with two voices, past each voice's stems), then ornaments
    /// and a fermata beyond them, outside the staff.
    private func drawMarks(ink: NSColor) {
        let two = score.hasSecondVoice
        for p in placed {
            let line = score.forVoice(p.voice)
            let note = line.notes[p.index]
            let marks = ScoreData.articulationKinds.map(\.0).filter { (note.articulations ?? []).contains($0) }
            guard !marks.isEmpty || note.ornament != nil || note.fermata == true else { continue }
            let ref = NoteRef(voice: p.voice, index: p.index)
            let color = colorFor(ref, ink: ink)
            let top = staffTop(p.system), bottom = top + space * 4
            let cx = p.x + space * 0.62
            let shape = shapes[ref] ?? (up: true, low: top + space * 2.5, high: top + space * 1.5)
            // Articulations: on the head's side (stem up → under the note), or past the stem with two voices.
            let above = two ? p.voice == 0 : !shape.up
            var y: CGFloat
            if two {
                y = above ? shape.high - space * 4.4 : shape.low + space * 4.4
            } else {
                y = above ? shape.high - space * 1.2 : shape.low + space * 1.2
            }
            color.set()
            for mark in marks {
                // Dots and lines sit in a space, not on a staff line.
                if y > top - 1, y < bottom + 1, ["staccato", "tenuto", "staccatissimo"].contains(mark) {
                    let k = ((y - top) / space)
                    if abs(k - k.rounded()) < 0.25 { y += above ? -space * 0.5 : space * 0.5 }
                }
                drawArticulation(mark, x: cx, y: y, above: above, color: color)
                y += above ? -space * 1.1 : space * 1.1
            }
            // Ornaments and fermatas: outside the staff, beyond any articulations.
            let outsideAbove = two ? p.voice == 0 : true
            var oy = outsideAbove ? min(top - space * 1.4, (above && !marks.isEmpty ? y : shape.high - (shape.up ? space * 4.4 : space * 1.4)) - space * 0.4)
                                  : max(bottom + space * 1.4, (!above && !marks.isEmpty ? y : shape.low + space * 4.4) + space * 0.4)
            if let ornament = note.ornament {
                drawOrnament(ornament, x: cx, y: oy, color: color)
                oy += outsideAbove ? -space * 1.6 : space * 1.6
            }
            if note.fermata == true {
                let glyph = outsideAbove ? "\u{1D110}" : "\u{1D111}"
                let font = NSFont(name: "Apple Symbols", size: space * 3.4) ?? .systemFont(ofSize: space * 3)
                let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
                let size = (glyph as NSString).size(withAttributes: attrs)
                (glyph as NSString).draw(at: NSPoint(x: cx - size.width / 2, y: oy - size.height * (outsideAbove ? 0.62 : 0.38)), withAttributes: attrs)
            }
        }
    }

    private func drawArticulation(_ mark: String, x: CGFloat, y: CGFloat, above: Bool, color: NSColor) {
        let toward: CGFloat = above ? 1 : -1   // towards the note (down when above)
        switch mark {
        case "staccato":
            let r = space * 0.22
            NSBezierPath(ovalIn: NSRect(x: x - r, y: y - r, width: r * 2, height: r * 2)).fill()
        case "staccatissimo":
            let path = NSBezierPath()
            path.move(to: NSPoint(x: x - space * 0.22, y: y - toward * space * 0.4))
            path.line(to: NSPoint(x: x + space * 0.22, y: y - toward * space * 0.4))
            path.line(to: NSPoint(x: x, y: y + toward * space * 0.4))
            path.close()
            path.fill()
        case "tenuto":
            NSRect(x: x - space * 0.65, y: y - 0.75, width: space * 1.3, height: 1.5).fill()
        case "accent":
            let path = NSBezierPath()
            path.move(to: NSPoint(x: x - space * 0.7, y: y - space * 0.42))
            path.line(to: NSPoint(x: x + space * 0.7, y: y))
            path.line(to: NSPoint(x: x - space * 0.7, y: y + space * 0.42))
            path.lineWidth = 1.3
            path.stroke()
        case "marcato":
            // An upturned wedge (^) over the note, v under it.
            let tip = y - toward * space * 0.5, base = y + toward * space * 0.5
            let path = NSBezierPath()
            path.move(to: NSPoint(x: x - space * 0.5, y: base))
            path.line(to: NSPoint(x: x, y: tip))
            path.line(to: NSPoint(x: x + space * 0.5, y: base))
            path.line(to: NSPoint(x: x + space * 0.25, y: base))
            path.line(to: NSPoint(x: x, y: tip + toward * space * 0.45))
            path.line(to: NSPoint(x: x - space * 0.25, y: base))
            path.close()
            path.fill()
        default:
            break
        }
    }

    private func drawOrnament(_ ornament: String, x: CGFloat, y: CGFloat, color: NSColor) {
        color.set()
        switch ornament {
        case "trill":
            let attrs: [NSAttributedString.Key: Any] = [.font: Self.dynamicFont, .foregroundColor: color]
            let size = ("tr" as NSString).size(withAttributes: attrs)
            ("tr" as NSString).draw(at: NSPoint(x: x - size.width / 2, y: y - size.height / 2), withAttributes: attrs)
        case "mordent", "prall":
            // A short zigzag; the mordent has a stroke through it.
            let w = space * 1.8, h = space * 0.75
            let path = NSBezierPath()
            path.move(to: NSPoint(x: x - w / 2, y: y + h / 2))
            for k in 1...4 { path.line(to: NSPoint(x: x - w / 2 + w * CGFloat(k) / 4, y: k % 2 == 1 ? y - h / 2 : y + h / 2)) }
            path.lineWidth = 1.6
            path.lineJoinStyle = .round
            path.stroke()
            if ornament == "mordent" {
                NSRect(x: x - 0.6, y: y - h, width: 1.2, height: h * 2).fill()
            }
        default:
            // Turn: an S lying on its side.
            let w = space * 2.0, h = space * 0.8
            let path = NSBezierPath()
            path.move(to: NSPoint(x: x - w / 2, y: y + h * 0.1))
            path.curve(to: NSPoint(x: x, y: y), controlPoint1: NSPoint(x: x - w / 2, y: y - h), controlPoint2: NSPoint(x: x - w * 0.1, y: y - h))
            path.curve(to: NSPoint(x: x + w / 2, y: y - h * 0.1), controlPoint1: NSPoint(x: x + w * 0.1, y: y + h), controlPoint2: NSPoint(x: x + w / 2, y: y + h))
            path.lineWidth = 2.0
            path.lineCapStyle = .round
            path.stroke()
        }
    }

    // MARK: Slurs, dynamics, hairpins

    /// Where a line (system) ends on the right.
    private var lineEnd: CGFloat { bounds.width - space * 1.5 }

    /// Slurs: curves over (or under) the notes they join — over when stems go down, under when they go up
    /// (with two voices: voice 1 over, voice 2 under). A slur running onto the next line is drawn in two parts.
    private func drawSlurs(ink: NSColor) {
        let two = score.hasSecondVoice
        for v in 0..<ScoreData.voiceCount where !score.line(v).isEmpty {
            let line = score.forVoice(v)
            for (a, b) in line.slurs {
                guard let pa = place(v, a), let pb = place(v, b), let sa = shapes[NoteRef(voice: v, index: a)],
                      let sb = shapes[NoteRef(voice: v, index: b)] else { continue }
                let above = two ? v == 0 : !(sa.up && sb.up)
                func end(_ s: (up: Bool, low: CGFloat, high: CGFloat)) -> CGFloat {
                    above ? s.high - (s.up ? space * 3.9 : space * 1.0) : s.low + (s.up ? space * 1.0 : space * 3.9)
                }
                let color = colorFor(NoteRef(voice: v, index: a), ink: ink)
                let head = space * 0.62
                if pa.system == pb.system {
                    slur(from: NSPoint(x: pa.x + head, y: end(sa)), to: NSPoint(x: pb.x + head, y: end(sb)), above: above, color: color)
                } else {
                    slur(from: NSPoint(x: pa.x + head, y: end(sa)), to: NSPoint(x: lineEnd, y: end(sa)), above: above, color: color)
                    let start = systemStarts.indices.contains(pb.system) ? systemStarts[pb.system] : space * 6
                    slur(from: NSPoint(x: start, y: end(sb)), to: NSPoint(x: pb.x + head, y: end(sb)), above: above, color: color)
                }
            }
        }
    }

    /// A slur's curve: thin at the ends, thicker in the middle.
    private func slur(from a: NSPoint, to b: NSPoint, above: Bool, color: NSColor) {
        let dx = b.x - a.x
        guard dx > 2 else { return }
        let lift = min(space * 2.2, dx * 0.12 + space * 0.7) * (above ? -1 : 1)
        let thick: CGFloat = 1.6 * (above ? -1 : 1)
        let path = NSBezierPath()
        path.move(to: a)
        path.curve(to: b, controlPoint1: NSPoint(x: a.x + dx / 3, y: a.y + lift + thick), controlPoint2: NSPoint(x: b.x - dx / 3, y: b.y + lift + thick))
        path.curve(to: a, controlPoint1: NSPoint(x: b.x - dx / 3, y: b.y + lift), controlPoint2: NSPoint(x: a.x + dx / 3, y: a.y + lift))
        path.close()
        color.set()
        path.fill()
        path.lineWidth = 0.5
        path.stroke()
    }

    static let dynamicFont = NSFont(name: "Georgia-BoldItalic", size: 15) ?? NSFont.systemFont(ofSize: 15, weight: .bold)

    /// Dynamic markings under the notes, and hairpins (crescendo opening, diminuendo closing) between them.
    private func drawDynamics(ink: NSColor) {
        guard score.hasDynamics else { return }
        for v in 0..<ScoreData.voiceCount where !score.line(v).isEmpty {
            let line = score.forVoice(v)
            var textEnds: [Int: CGFloat] = [:]   // where a note's dynamic ends (a hairpin starts after it)
            for p in placed where p.voice == v {
                guard let d = line.notes[p.index].dynamic else { continue }
                let color = colorFor(NoteRef(voice: v, index: p.index), ink: ink)
                let attrs: [NSAttributedString.Key: Any] = [.font: Self.dynamicFont, .foregroundColor: color]
                let size = (d as NSString).size(withAttributes: attrs)
                let x = p.x + space * 0.62 - size.width / 2
                (d as NSString).draw(at: NSPoint(x: x, y: dynamicY(p.system) - size.height / 2), withAttributes: attrs)
                textEnds[p.index] = x + size.width
            }
            for (a, b, direction) in line.hairpins {
                guard let pa = place(v, a), let pb = place(v, b) else { continue }
                let color = colorFor(NoteRef(voice: v, index: a), ink: ink)
                let startX = max(pa.x, (textEnds[a] ?? pa.x - space) + space * 0.6)
                // To the end of the last note (or before its own dynamic).
                let lastNote = line.notes[b]
                var endX = pb.x + space * (lastNote.duration.rawValue >= 4 ? 1.6 : 2.6)
                if lastNote.dynamic != nil, let textEnd = textEnds[b] {
                    let width = (lastNote.dynamic! as NSString).size(withAttributes: [.font: Self.dynamicFont]).width
                    endX = textEnd - width - space * 0.6
                }
                if pa.system == pb.system {
                    hairpin(from: startX, to: endX, system: pa.system, crescendo: direction > 0, open: (false, false), color: color)
                } else {
                    hairpin(from: startX, to: lineEnd, system: pa.system, crescendo: direction > 0, open: (false, true), color: color)
                    let start = systemStarts.indices.contains(pb.system) ? systemStarts[pb.system] : space * 6
                    hairpin(from: start, to: endX, system: pb.system, crescendo: direction > 0, open: (true, false), color: color)
                }
            }
        }
    }

    /// A hairpin's two lines (a part continuing on another line starts or ends half open).
    private func hairpin(from x1: CGFloat, to x2: CGFloat, system: Int, crescendo: Bool, open: (Bool, Bool), color: NSColor) {
        guard x2 - x1 > space else { return }
        let mid = dynamicY(system), wide = space * 0.75
        var left = crescendo ? 0 : wide, right = crescendo ? wide : 0
        if open.0 { left = wide / 2 }
        if open.1 { right = wide / 2 }
        let path = NSBezierPath()
        path.move(to: NSPoint(x: x1, y: mid - left))
        path.line(to: NSPoint(x: x2, y: mid - right))
        path.move(to: NSPoint(x: x1, y: mid + left))
        path.line(to: NSPoint(x: x2, y: mid + right))
        path.lineWidth = 1.1
        color.setStroke()
        path.stroke()
    }

    /// The two dots of a repeat sign (in the second and third spaces).
    private func repeatDots(x: CGFloat, system: Int) {
        let top = staffTop(system), d = space * 0.42
        for line in [1.5, 2.5] {
            NSBezierPath(ovalIn: NSRect(x: x, y: top + space * CGFloat(line) - d / 2, width: d, height: d)).fill()
        }
    }

    /// A key signature: naturals cancelling the old key's accidentals first (on a change), then the new key's.
    @discardableResult
    private func drawKeySignature(_ fifths: Int, cancelling old: Int? = nil, x: CGFloat, system: Int, ink: NSColor) -> CGFloat {
        // Where each accidental sits (treble: F5 C5 G5 D5 A4 E5 B4 / B4 E5 A4 D5 G4 C5 F4; bass two octaves lower).
        let trebleSharps = [5 * 7 + 3, 5 * 7 + 0, 5 * 7 + 4, 5 * 7 + 1, 4 * 7 + 5, 5 * 7 + 2, 4 * 7 + 6]
        let trebleFlats = [4 * 7 + 6, 5 * 7 + 2, 4 * 7 + 5, 5 * 7 + 1, 4 * 7 + 4, 5 * 7 + 0, 4 * 7 + 3]
        func place(_ sharps: Bool, _ k: Int) -> CGFloat {
            var d = (sharps ? trebleSharps : trebleFlats)[k]
            if score.clef == .bass { d -= 14 }
            return y(position: d - score.clef.bottomLine, system: system)
        }
        var x = x
        if let old {
            let cancel = ScoreData.cancelled(from: old, to: fifths)
            let order = cancel.sharps ? ScoreData.sharpOrder : ScoreData.flatOrder
            for step in cancel.steps {
                guard let k = order.firstIndex(of: step) else { continue }
                drawAccidental(0, x: x, y: place(cancel.sharps, k), ink: ink)
                x += space * 1.05
            }
        }
        for k in 0..<abs(fifths) {
            drawAccidental(fifths > 0 ? 1 : -1, x: x, y: place(fifths > 0, k), ink: ink)
            x += space * 1.05
        }
        return x
    }

    /// Chord symbols above the staff, lyrics under it (with hyphens between syllables).
    private func drawWords(ink: NSColor) {
        let placed = self.placed.filter { $0.voice == 0 }
        measureLowest()
        for (k, p) in placed.enumerated() {
            let note = score.notes[p.index]
            let color = colorFor(NoteRef(voice: 0, index: p.index), ink: ink)
            if let symbol = note.chordSymbol, !symbol.isEmpty {
                let attrs: [NSAttributedString.Key: Any] = [.font: Self.chordFont, .foregroundColor: color]
                let top = staffTop(p.system) - space * 2 - chordBand - (tabOnly(score) ? techniqueRoom(score) + strumBand(score.notes) - space * 1.5 : markBandAbove) + space * 0.2
                (score.chordLabel(symbol) as NSString).draw(at: NSPoint(x: p.x - space * 0.2, y: top), withAttributes: attrs)
                // The chord's diagram under its name (with a capo, the shape played): the voicing chosen for it.
                if score.chordDiagrams == true, let diagram = chordDiagram(symbol) {
                    let origin = NSPoint(x: p.x - space * 0.9, y: top + space * 2.2)
                    GuitarChords.draw(diagram.shape, at: origin, space: space, color: color)
                    diagramSpots.append((NSRect(origin: origin, size: GuitarChords.size(space: space, strings: diagram.shape.frets.count)), symbol, NoteRef(voice: 0, index: p.index, staff: drawingStaff)))
                }
            }
            // Figured bass, stacked under the note; the Roman numeral under that.
            if let figures = note.figures, !figures.isEmpty {
                let next = k + 1 < placed.count && placed[k + 1].system == p.system ? placed[k + 1].x + space * 0.62 : nil
                FiguredBass.draw(figures, centre: p.x + space * 0.62, top: figureTop(p.system), next: next, color: color)
            }
            if let numeral = note.numeral, !numeral.isEmpty {
                RomanNumeral.draw(numeral, centre: p.x + space * 0.62, top: numeralTop(p.system), color: color)
            }
            guard let lyric = note.lyric, !lyric.isEmpty else { continue }
            let attrs: [NSAttributedString.Key: Any] = [.font: Self.lyricFont, .foregroundColor: color]
            let word = lyric.hasSuffix("-") ? String(lyric.dropLast()) : lyric
            let size = (word as NSString).size(withAttributes: attrs)
            let center = p.x + space * 0.62
            (word as NSString).draw(at: NSPoint(x: center - size.width / 2, y: lyricY(p.system)), withAttributes: attrs)
            if lyric.hasSuffix("-"), k + 1 < placed.count, placed[k + 1].system == p.system {
                let nextWord = (score.notes[placed[k + 1].index].lyric ?? "").replacingOccurrences(of: "-", with: "")
                let nextLeft = placed[k + 1].x + space * 0.62 - (nextWord as NSString).size(withAttributes: attrs).width / 2
                let mid = (center + size.width / 2 + nextLeft) / 2
                ("-" as NSString).draw(at: NSPoint(x: mid - 2.5, y: lyricY(p.system)), withAttributes: attrs)
            }
        }
    }

    // MARK: Guitar TAB

    /// Where frets were drawn (for clicks): the note, its string and the fret's box.
    private var fretSpots: [(rect: NSRect, ref: NoteRef, string: Int)] = []
    /// Where chord diagrams were drawn (a click plays the chord): the box, the chord symbol and its note.
    private var diagramSpots: [(rect: NSRect, symbol: String, ref: NoteRef?)] = []

    /// A chord symbol's diagram, as this score plays it: in its instrument's tuning, with a capo the shape played,
    /// and the voicing chosen for it.
    func chordDiagram(_ symbol: String) -> (name: String, shape: GuitarChords.Shape)? {
        let full = fullScore
        return GuitarChords.diagram(for: symbol, capo: full.capo ?? 0, strings: full.openStrings, frets: min(15, full.maxFret), chosen: full.chordShapes)
    }

    /// The chart of every chord used, under the title.
    private func drawChordChart(ink: NSColor) {
        let chords = chartChords
        guard !chords.isEmpty else { return }
        let item = chartItem, columns = chartColumns
        let top = titleHeight - chordChartHeight
        let attrs: [NSAttributedString.Key: Any] = [.font: Self.chordFont, .foregroundColor: ink]
        let rowWidth = CGFloat(min(columns, chords.count)) * item.width
        let left = max(space, (bounds.width - rowWidth) / 2)
        for (k, symbol) in chords.enumerated() {
            guard let diagram = chordDiagram(symbol) else { continue }
            let x = left + CGFloat(k % columns) * item.width, y = top + CGFloat(k / columns) * item.height
            let name = fullScore.chordLabel(symbol) as NSString
            let size = name.size(withAttributes: attrs)
            let d = GuitarChords.size(space: space, strings: diagram.shape.frets.count)
            name.draw(at: NSPoint(x: x + (d.width - size.width) / 2, y: y), withAttributes: attrs)
            let origin = NSPoint(x: x, y: y + space * 1.9)
            GuitarChords.draw(diagram.shape, at: origin, space: space, color: ink)
            diagramSpots.append((NSRect(origin: origin, size: d), symbol, nil))
        }
    }

    /// What's written for a fret: x for a dead note, (5) for a ghost note or a tied note's continuation, <12> for a
    /// natural harmonic, 5<17> for an artificial one.
    private func fretText(_ note: ScoreNote, _ spot: TabSpot, tied: Bool, in line: ScoreData) -> String {
        let g = note.guitar
        if g?.dead == true { return "x" }
        if g?.harmonic == "natural" { return "<\(spot.fret)>" }
        if g?.harmonic == "artificial" { return "\(spot.fret)<\(spot.fret + 12)>" }
        if g?.ghost == true || tied { return "(\(spot.fret))" }
        return "\(spot.fret)"
    }

    /// The TAB staff: a line for each string (the highest on top), each note's fret, how it's played — and, TAB
    /// only, the rhythm under it.
    private func drawTab(ink: NSColor) {
        let st = score
        let n = st.stringCount
        let only = tabOnly(st)
        let fretFont = NSFont.systemFont(ofSize: 11, weight: .medium)
        let left = only ? staffLeft : space
        let height = tabGap * CGFloat(n - 1)
        for s in 0..<systemCount {
            let top = tabTop(s)
            ink.setFill()
            for line in 0..<n {
                NSRect(x: left, y: top + CGFloat(line) * tabGap - 0.5, width: bounds.width - space - left, height: 1).fill()
            }
            // T A B down the left, over a white strip (as printed tab).
            let letter = min(tabGap * 1.15, height / 3.3)
            let tabAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: letter), .foregroundColor: ink]
            let first = top + (height - letter * 3.6) / 2
            NSColor.white.setFill()
            NSRect(x: left + space * 0.6, y: first, width: space * 1.9, height: letter * 3.6).fill()
            for (i, l) in ["T", "A", "B"].enumerated() {
                let size = (l as NSString).size(withAttributes: tabAttrs)
                (l as NSString).draw(at: NSPoint(x: left + space * 1.55 - size.width / 2, y: first + CGFloat(i) * letter * 1.2), withAttributes: tabAttrs)
            }
            // TAB only: the time signature on the first line.
            if only, s == 0 {
                let font = NSFont(name: "Georgia-Bold", size: space * 2.7) ?? .boldSystemFont(ofSize: space * 2.7)
                let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink]
                NSColor.white.setFill()
                NSRect(x: left + space * 3.7, y: top + 1, width: space * 2.2, height: height - 2).fill()
                for (i, number) in ["\(st.beats)", "\(st.beatUnit)"].enumerated() {
                    let size = (number as NSString).size(withAttributes: attrs)
                    (number as NSString).draw(at: NSPoint(x: left + space * 3.9 + (space * 1.8 - size.width) / 2,
                                                          y: top + height / 2 + (i == 0 ? -size.height * 0.82 : -size.height * 0.12)), withAttributes: attrs)
                }
            }
        }
        for bar in barLines {
            ink.setFill()
            let top = tabTop(bar.system)
            switch bar.style {
            case .final, .endRepeat:
                NSRect(x: bar.x - space * 0.9, y: top, width: 1, height: height).fill()
                NSRect(x: bar.x - space * 0.5, y: top, width: 3.5, height: height).fill()
                if bar.style == .endRepeat {
                    for k in [0.35, 0.65] { NSBezierPath(ovalIn: NSRect(x: bar.x - space * 1.6, y: top + height * k - 2, width: 4, height: 4)).fill() }
                }
            case .double:
                NSRect(x: bar.x - space * 0.45, y: top, width: 1, height: height).fill()
                NSRect(x: bar.x - 0.5, y: top, width: 1, height: height).fill()
            case .single:
                NSRect(x: bar.x - 0.5, y: top, width: 1, height: height).fill()
            }
        }
        if only {
            for r in repeatStarts {
                let top = tabTop(r.system)
                ink.setFill()
                NSRect(x: r.x - 0.5, y: top, width: 3.5, height: height).fill()
                NSRect(x: r.x + space * 0.55, y: top, width: 1, height: height).fill()
                for k in [0.35, 0.65] { NSBezierPath(ovalIn: NSRect(x: r.x + space * 0.95, y: top + height * k - 2, width: 4, height: 4)).fill() }
            }
        }
        // Each voice's frets (chosen for the whole line at once).
        var frets: [NoteRef: [(spot: TabSpot, center: NSPoint, width: CGFloat)]] = [:]
        for v in 0..<ScoreData.voiceCount where !st.line(v).isEmpty {
            let line = st.forVoice(v)
            let plan = line.tabPlan()
            for p in placed where p.voice == v {
                let note = line.notes[p.index]
                let color = colorFor(NoteRef(voice: v, index: p.index), ink: ink)
                if note.rest {
                    if only, v == 0 { drawRest(note, x: p.x, system: p.system, color: color, lift: height / 2 - space * 2) }
                    continue
                }
                let tied = line.tiedFrom(p.index)
                let small = note.grace != nil
                let attrs: [NSAttributedString.Key: Any] = [.font: small ? NSFont.systemFont(ofSize: 8.5) : fretFont, .foregroundColor: color]
                for spot in plan.indices.contains(p.index) ? plan[p.index] : [] {
                    let text = fretText(note, spot, tied: tied, in: line)
                    let size = (text as NSString).size(withAttributes: attrs)
                    let cy = tabTop(p.system) + CGFloat(n - 1 - spot.string) * tabGap
                    let cx = p.x + space * 0.62
                    let box = NSRect(x: cx - size.width / 2 - 1.5, y: cy - size.height / 2, width: size.width + 3, height: size.height)
                    NSColor.white.setFill()
                    box.fill()
                    (text as NSString).draw(at: NSPoint(x: box.minX + 1.5, y: box.minY), withAttributes: attrs)
                    let ref = NoteRef(voice: v, index: p.index, staff: drawingStaff)
                    frets[NoteRef(voice: v, index: p.index), default: []].append((spot, NSPoint(x: cx, y: cy), box.width))
                    fretSpots.append((box.insetBy(dx: -3, dy: -2), ref, spot.string))
                }
            }
            drawTabTechniques(line, voice: v, frets: frets, ink: ink)
        }
        if only { drawTabRhythm(ink: ink) }
        // Typing frets: the string the next fret goes on, at the caret (or on the selected note).
        if tabInput, ScoreView.active === self, drawingStaff == staffIndex {
            var x: CGFloat?, system = 0
            if let i = selected, let p = place(voice, i) { x = p.x + space * 0.62; system = p.system } else if cursor < caretSpots.count { x = caretSpots[cursor].x + space * 0.4; system = caretSpots[cursor].system }
            if let x {
                let y = tabTop(system) + CGFloat(n - 1 - tabString) * tabGap
                NSColor.controlAccentColor.withAlphaComponent(0.35).setFill()
                NSBezierPath(roundedRect: NSRect(x: x - space * 0.9, y: y - tabGap * 0.45, width: space * 1.8, height: tabGap * 0.9), xRadius: 3, yRadius: 3).fill()
                NSColor.controlAccentColor.setFill()
                NSRect(x: x - space * 0.9, y: y + tabGap * 0.45 - 1, width: space * 1.8, height: 2).fill()
            }
        }
    }

    /// Hammer-ons and pull-offs, slides, bends, vibrato, palm muting, let ring, harmonics and taps on the TAB.
    private func drawTabTechniques(_ line: ScoreData, voice v: Int, frets: [NoteRef: [(spot: TabSpot, center: NSPoint, width: CGFloat)]], ink: NSColor) {
        let markFont = NSFont.systemFont(ofSize: 9, weight: .semibold)
        let mine = placed.filter { $0.voice == v }
        func spot(_ i: Int) -> (spot: TabSpot, center: NSPoint, width: CGFloat)? { frets[NoteRef(voice: v, index: i)]?.first }
        func bendY(_ system: Int) -> CGFloat { tabTop(system) - space * 0.9 }
        func vibratoY(_ system: Int) -> CGFloat { tabTop(system) - space * 2.6 }
        func wordsY(_ system: Int) -> CGFloat { tabTop(system) - space * 3.3 }
        for (k, p) in mine.enumerated() {
            let note = line.notes[p.index]
            guard let g = note.guitar, !note.rest, let here = spot(p.index) else { continue }
            let color = colorFor(NoteRef(voice: v, index: p.index), ink: ink)
            color.set()
            let next = k + 1 < mine.count ? mine[k + 1] : nil
            let there = next.flatMap { nx in nx.system == p.system && !line.notes[nx.index].rest ? spot(nx.index) : nil }
            let up = next.map { (line.midi($0.index) ?? 0) >= (line.midi(p.index) ?? 0) } ?? true
            // Hammer-on / pull-off: an arc to the next fret, H or P over it.
            if g.legato == true, let there {
                let a = NSPoint(x: here.center.x, y: here.center.y - tabGap * 0.55), b = NSPoint(x: there.center.x, y: there.center.y - tabGap * 0.55)
                let arc = NSBezierPath()
                arc.move(to: a)
                arc.curve(to: b, controlPoint1: NSPoint(x: a.x + (b.x - a.x) * 0.25, y: min(a.y, b.y) - space * 1.1),
                          controlPoint2: NSPoint(x: a.x + (b.x - a.x) * 0.75, y: min(a.y, b.y) - space * 1.1))
                arc.lineWidth = 1
                arc.stroke()
                let letter = (up ? "H" : "P") as NSString
                let attrs: [NSAttributedString.Key: Any] = [.font: markFont, .foregroundColor: color]
                let size = letter.size(withAttributes: attrs)
                letter.draw(at: NSPoint(x: (a.x + b.x) / 2 - size.width / 2, y: min(a.y, b.y) - space * 1.1 - size.height), withAttributes: attrs)
            }
            // Slides: a line to the next fret (rising or falling), or in from below, or away downward.
            let sl = NSBezierPath()
            sl.lineWidth = 1.1
            switch g.slide {
            case "next"?:
                if let there {
                    let dy = (up ? -1 : 1) * tabGap * 0.28
                    sl.move(to: NSPoint(x: here.center.x + here.width / 2 + 1, y: here.center.y - dy))
                    sl.line(to: NSPoint(x: there.center.x - there.width / 2 - 1, y: there.center.y + dy))
                }
            case "in"?:
                sl.move(to: NSPoint(x: here.center.x - here.width / 2 - space * 1.3, y: here.center.y + tabGap * 0.3))
                sl.line(to: NSPoint(x: here.center.x - here.width / 2 - 1, y: here.center.y - tabGap * 0.2))
            case "out"?:
                sl.move(to: NSPoint(x: here.center.x + here.width / 2 + 1, y: here.center.y - tabGap * 0.2))
                sl.line(to: NSPoint(x: here.center.x + here.width / 2 + space * 1.3, y: here.center.y + tabGap * 0.3))
            default: break
            }
            sl.stroke()
            // A bend: a curved arrow up from the fret to over the staff, its size at the tip; a release comes back.
            if let bend = g.bend {
                let from = NSPoint(x: here.center.x + here.width / 2 + 1, y: here.center.y)
                let tip = NSPoint(x: from.x + space * 1.5, y: bendY(p.system))
                let curve = NSBezierPath()
                curve.move(to: from)
                curve.curve(to: tip, controlPoint1: NSPoint(x: tip.x, y: from.y), controlPoint2: NSPoint(x: tip.x, y: from.y))
                if g.release == true {
                    curve.move(to: tip)
                    curve.curve(to: NSPoint(x: tip.x + space * 1.4, y: from.y - tabGap * 0.3), controlPoint1: NSPoint(x: tip.x + space * 1.2, y: tip.y), controlPoint2: NSPoint(x: tip.x + space * 1.4, y: tip.y))
                }
                curve.lineWidth = 1.1
                curve.stroke()
                let head = NSBezierPath()
                head.move(to: tip)
                head.line(to: NSPoint(x: tip.x - 2.8, y: tip.y + 5))
                head.line(to: NSPoint(x: tip.x + 2.8, y: tip.y + 5))
                head.close()
                head.fill()
                let label = GuitarMarks.bendLabel(bend) as NSString
                let attrs: [NSAttributedString.Key: Any] = [.font: markFont, .foregroundColor: color]
                let size = label.size(withAttributes: attrs)
                label.draw(at: NSPoint(x: tip.x - size.width / 2, y: tip.y - size.height - 1), withAttributes: attrs)
            }
            // Vibrato: a wavy line over the staff.
            if g.vibrato == true {
                let width = max(space * 2.4, (next.map { $0.system == p.system ? $0.x - p.x : space * 3 } ?? space * 3) - space * 0.6)
                wavy(from: NSPoint(x: p.x, y: vibratoY(p.system)), width: width, color: color)
            }
            // Taps and artificial harmonics: T and A.H. over the staff.
            let words = [g.tap == true ? "T" : nil, g.harmonic == "artificial" ? "A.H." : nil].compactMap { $0 }
            if !words.isEmpty {
                let text = words.joined(separator: " ") as NSString
                text.draw(at: NSPoint(x: p.x, y: wordsY(p.system) - space * 0.6), withAttributes: [.font: markFont, .foregroundColor: color])
            }
        }
        // Palm muting and let ring: P.M. or "let ring" and a dashed line over the run (let ring a row higher).
        drawRuns(line, mine, rowY: { tabTop($0) - space * 4.4 }, ink: ink)
    }

    /// P.M. and let ring over their runs of notes: the word, then a dashed line to a hook at the end.
    private func drawRuns(_ line: ScoreData, _ mine: [Placed], rowY: (Int) -> CGFloat, ink: NSColor) {
        let font = NSFont.systemFont(ofSize: 9, weight: .semibold)
        let kinds: [(String, CGFloat, (GuitarMarks) -> Bool)] = [("P.M.", 0.3, { $0.palmMute == true }), ("let ring", -0.6, { $0.letRing == true })]
        for (word, lift, mark) in kinds {
            for run in line.runs(mark) {
                let ps = mine.filter { run.contains($0.index) }
                for system in Set(ps.map(\.system)).sorted() {
                    let row = ps.filter { $0.system == system }
                    guard let a = row.first, let b = row.last else { continue }
                    let y = rowY(system) + space * lift
                    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink]
                    let label = word as NSString
                    let size = label.size(withAttributes: attrs)
                    label.draw(at: NSPoint(x: a.x, y: y - size.height / 2), withAttributes: attrs)
                    let end = b.x + space * 1.6
                    if end > a.x + size.width + space * 0.5 {
                        let dash = NSBezierPath()
                        dash.move(to: NSPoint(x: a.x + size.width + space * 0.3, y: y))
                        dash.line(to: NSPoint(x: end, y: y))
                        dash.line(to: NSPoint(x: end, y: y + space * 0.6))
                        dash.setLineDash([3, 2], count: 2, phase: 0)
                        dash.lineWidth = 0.8
                        ink.setStroke()
                        dash.stroke()
                    }
                }
            }
        }
    }

    /// A wavy line (vibrato) from a point, so wide.
    private func wavy(from p: NSPoint, width: CGFloat, color: NSColor) {
        let path = NSBezierPath()
        path.move(to: p)
        var x = p.x
        let step = space * 0.55
        var up = true
        while x + step <= p.x + width {
            path.curve(to: NSPoint(x: x + step, y: p.y), controlPoint1: NSPoint(x: x + step * 0.3, y: p.y + (up ? -1 : 1) * space * 0.45),
                       controlPoint2: NSPoint(x: x + step * 0.7, y: p.y + (up ? -1 : 1) * space * 0.45))
            x += step
            up.toggle()
        }
        path.lineWidth = 1.2
        color.setStroke()
        path.stroke()
    }

    /// TAB only: the rhythm under the TAB — stems, beams and flags for voice 1, dots after them.
    private func drawTabRhythm(ink: NSColor) {
        let line = score.forVoice(0)
        let mine = placed.filter { $0.voice == 0 }
        let groups = beamGroups(line, mine)
        var inGroup: [Int: [Int]] = [:]
        for g in groups { for i in g { inGroup[i] = g } }
        let n = line.stringCount
        func stemX(_ p: Placed) -> CGFloat { p.x + space * 0.62 }
        func stemTop(_ p: Placed) -> CGFloat { tabTop(p.system) + tabGap * CGFloat(n - 1) + space * 0.7 }
        func stemBottom(_ p: Placed) -> CGFloat { stemTop(p) + space * 2.4 }
        for p in mine {
            let note = line.notes[p.index]
            guard !note.rest, note.grace == nil, note.duration != .whole else { continue }
            let color = colorFor(NoteRef(voice: 0, index: p.index), ink: ink)
            color.setFill()
            // A half note's stem is shorter (as printed tab tells it from a quarter).
            let bottom = note.duration == .half ? stemTop(p) + space * 1.4 : stemBottom(p)
            NSRect(x: stemX(p) - 0.6, y: stemTop(p), width: 1.2, height: bottom - stemTop(p)).fill()
            if note.dotted { NSBezierPath(ovalIn: NSRect(x: stemX(p) + space * 0.4, y: bottom - space * 0.45, width: 3, height: 3)).fill() }
            // Flags on eighths and sixteenths outside a beam.
            if note.duration.rawValue >= 8, inGroup[p.index] == nil {
                for f in 0..<(note.duration == .sixteenth ? 2 : 1) {
                    let fy = bottom - CGFloat(f) * space * 0.6
                    let flag = NSBezierPath()
                    flag.move(to: NSPoint(x: stemX(p), y: fy))
                    flag.line(to: NSPoint(x: stemX(p) + space * 0.9, y: fy - space * 0.8))
                    flag.lineWidth = 1.4
                    color.setStroke()
                    flag.stroke()
                }
            }
        }
        // Beams along the bottom of the stems (a second one for sixteenths).
        for g in groups {
            let ps = g.compactMap { i in mine.first { $0.index == i } }
            guard let a = ps.first, let b = ps.last else { continue }
            ink.setFill()
            let y = stemBottom(a)
            NSRect(x: stemX(a) - 0.6, y: y - space * 0.45, width: stemX(b) - stemX(a) + 1.2, height: space * 0.45).fill()
            for (k, p) in ps.enumerated() where line.notes[p.index].duration == .sixteenth {
                let nextP = k + 1 < ps.count ? ps[k + 1] : nil
                let to = nextP.flatMap { line.notes[$0.index].duration == .sixteenth ? stemX($0) : nil } ?? stemX(p) + (k == ps.count - 1 ? -space * 0.8 : space * 0.8)
                NSRect(x: min(stemX(p), to) - 0.6, y: y - space * 1.1, width: abs(to - stemX(p)) + 1.2, height: space * 0.4).fill()
            }
            // A triplet's 3 under its beam.
            if let actual = line.notes[a.index].tupletActual {
                let t = "\(actual)" as NSString
                t.draw(at: NSPoint(x: (stemX(a) + stemX(b)) / 2 - 3, y: y + space * 0.2), withAttributes: [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: ink])
            }
        }
    }

    /// How a fretted note is played, on the music: x heads for dead notes, diamonds for harmonics, brackets for
    /// ghost notes (drawn with the heads); H and P over hammer-ons and pull-offs, slide lines, bend arrows,
    /// vibrato, P.M. and let ring over the staff.
    private func drawGuitarMarks(ink: NSColor) {
        for v in 0..<ScoreData.voiceCount where !score.line(v).isEmpty {
            let line = score.forVoice(v)
            guard line.hasGuitarMarks else { continue }
            let mine = placed.filter { $0.voice == v }
            func headY(_ p: Placed) -> CGFloat { y(position: position(line.notes[p.index]), system: p.system, of: line.notes[p.index]) }
            let markFont = NSFont.systemFont(ofSize: 9, weight: .semibold)
            func rowY(_ system: Int) -> CGFloat { staffTop(system) - space * 1.1 }
            for (k, p) in mine.enumerated() {
                let note = line.notes[p.index]
                guard let g = note.guitar, !note.rest else { continue }
                let color = colorFor(NoteRef(voice: v, index: p.index), ink: ink)
                color.set()
                let next = k + 1 < mine.count && mine[k + 1].system == p.system && !line.notes[mine[k + 1].index].rest ? mine[k + 1] : nil
                let hx = p.x + space * 0.62, hy = headY(p)
                if g.legato == true, let next {
                    let nx = next.x + space * 0.62, ny = headY(next)
                    let up = (line.midi(next.index) ?? 0) >= (line.midi(p.index) ?? 0)
                    let top = min(hy, ny) - space * 1.4
                    let arc = NSBezierPath()
                    arc.move(to: NSPoint(x: hx, y: hy - space * 0.8))
                    arc.curve(to: NSPoint(x: nx, y: ny - space * 0.8), controlPoint1: NSPoint(x: hx + (nx - hx) * 0.25, y: top), controlPoint2: NSPoint(x: hx + (nx - hx) * 0.75, y: top))
                    arc.lineWidth = 1
                    arc.stroke()
                    let letter = (up ? "H" : "P") as NSString
                    letter.draw(at: NSPoint(x: (hx + nx) / 2 - 3, y: top - space * 1.3), withAttributes: [.font: markFont, .foregroundColor: color])
                }
                let sl = NSBezierPath()
                sl.lineWidth = 1.1
                switch g.slide {
                case "next"?:
                    if let next {
                        sl.move(to: NSPoint(x: hx + space * 0.9, y: hy))
                        sl.line(to: NSPoint(x: next.x - space * 0.3, y: headY(next)))
                    }
                case "in"?:
                    sl.move(to: NSPoint(x: p.x - space * 1.8, y: hy + space * 0.8))
                    sl.line(to: NSPoint(x: p.x - space * 0.3, y: hy))
                case "out"?:
                    sl.move(to: NSPoint(x: hx + space * 0.9, y: hy))
                    sl.line(to: NSPoint(x: hx + space * 2.4, y: hy + space * 0.8))
                default: break
                }
                sl.stroke()
                if let bend = g.bend {
                    let from = NSPoint(x: hx + space * 0.8, y: hy)
                    let tip = NSPoint(x: from.x + space * 1.2, y: hy - space * 2.2)
                    let curve = NSBezierPath()
                    curve.move(to: from)
                    curve.curve(to: tip, controlPoint1: NSPoint(x: tip.x, y: from.y), controlPoint2: NSPoint(x: tip.x, y: from.y))
                    curve.lineWidth = 1
                    curve.stroke()
                    let label = GuitarMarks.bendLabel(bend) + (g.release == true ? " ↘" : "")
                    (label as NSString).draw(at: NSPoint(x: tip.x - 3, y: tip.y - space * 1.4), withAttributes: [.font: markFont, .foregroundColor: color])
                }
                if g.vibrato == true {
                    let width = max(space * 2.4, (next.map { $0.x - p.x } ?? space * 3) - space * 0.6)
                    wavy(from: NSPoint(x: p.x, y: rowY(p.system)), width: width, color: color)
                }
                if g.tap == true {
                    ("T" as NSString).draw(at: NSPoint(x: hx - 3, y: rowY(p.system) - space * 1.9), withAttributes: [.font: markFont, .foregroundColor: color])
                }
                if g.ghost == true {
                    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: space * 1.6), .foregroundColor: color]
                    ("(" as NSString).draw(at: NSPoint(x: p.x - space * 0.75, y: hy - space * 1.0), withAttributes: attrs)
                    (")" as NSString).draw(at: NSPoint(x: p.x + space * 1.35, y: hy - space * 1.0), withAttributes: attrs)
                }
            }
            drawRuns(line, mine, rowY: { staffTop($0) - space * 2.6 }, ink: ink)
        }
    }

    /// Strums over the staff — ⊓ down and V up, or arrows (the way the hand goes) — clear of the stems and of any
    /// vibrato or P.M. there; voice 2's under the staff; TAB only, over the TAB. Bass notes have none.
    private func drawStrums(ink: NSColor) {
        let arrows = fullScore.strumArrows == true
        let only = tabOnly(score)
        for v in 0..<ScoreData.voiceCount where !score.line(v).isEmpty && (!only || v == 0) {
            let line = score.forVoice(v)
            guard strumBand(line.notes) > 0 else { continue }
            let rows = line.notes.contains { n in n.guitar.map { $0.vibrato == true || $0.palmMute == true || $0.letRing == true || $0.bend != nil || $0.tap == true } ?? false }
            let height = arrows ? space * 1.9 : space * 1.2
            for p in placed where p.voice == v {
                let note = line.notes[p.index]
                guard !note.rest, let strum = note.guitar?.strum, strum != "bass" else { continue }
                let ref = NoteRef(voice: v, index: p.index)
                let color = colorFor(ref, ink: ink)
                let x = p.x + space * 0.65
                if only {
                    drawStrum(up: strum == "up", arrows: arrows, x: x, bottom: tabTop(p.system) - space * 0.6 - techniqueRoom(score), color: color)
                    continue
                }
                let top = staffTop(p.system)
                let shape = shapes[ref] ?? (up: v == 0, low: top + space * 2, high: top + space * 2)
                if v == 0 {
                    let tip = shape.up && note.duration != .whole && note.slash != "beat" ? shape.high - space * 3.5 : shape.high - space * 1.1
                    var bottom = min(top - space * (rows ? 4.0 : 1.2), tip - space * 0.6)
                    if note.fermata == true || note.ornament != nil { bottom -= space * 2.4 }
                    drawStrum(up: strum == "up", arrows: arrows, x: x, bottom: bottom, color: color)
                } else {
                    let tip = shape.up || note.duration == .whole ? shape.low + space * 1.1 : shape.low + space * 3.5
                    drawStrum(up: strum == "up", arrows: arrows, x: x, bottom: max(top + space * 5.2, tip + space * 0.6) + height, color: color)
                }
            }
        }
    }

    /// A strum's mark, `bottom` its lowest point: ⊓ (down-bow: a down stroke) or V (up-bow), or an arrow.
    private func drawStrum(up: Bool, arrows: Bool, x: CGFloat, bottom: CGFloat, color: NSColor) {
        color.set()
        if arrows {
            let top = bottom - space * 1.9
            NSRect(x: x - 0.65, y: top + (up ? space * 0.5 : 0), width: 1.3, height: space * 1.4).fill()
            let head = NSBezierPath()
            let tip = up ? top : bottom, back: CGFloat = up ? space * 0.75 : -space * 0.75
            head.move(to: NSPoint(x: x, y: tip))
            head.line(to: NSPoint(x: x - space * 0.42, y: tip + back))
            head.line(to: NSPoint(x: x + space * 0.42, y: tip + back))
            head.close()
            head.fill()
        } else if up {
            let path = NSBezierPath()
            path.move(to: NSPoint(x: x - space * 0.5, y: bottom - space * 1.2))
            path.line(to: NSPoint(x: x, y: bottom))
            path.line(to: NSPoint(x: x + space * 0.5, y: bottom - space * 1.2))
            path.lineWidth = 1.2
            path.stroke()
        } else {
            let w = space * 0.6, h = space * 1.0
            NSRect(x: x - w, y: bottom - h, width: w * 2, height: space * 0.32).fill()
            NSRect(x: x - w, y: bottom - h, width: 1.2, height: h).fill()
            NSRect(x: x + w - 1.2, y: bottom - h, width: 1.2, height: h).fill()
        }
    }

    private func drawStaff(_ system: Int, ink: NSColor) {
        let top = staffTop(system)
        ink.setFill()
        for line in 0..<5 {
            NSRect(x: staffLeft, y: top + CGFloat(line) * space - 0.5, width: bounds.width - space - staffLeft, height: 1).fill()
        }
        // Clef.
        if score.clef == .percussion {
            // The percussion clef: two thick bars across the middle of the staff.
            ink.setFill()
            NSRect(x: staffLeft + space * 1.2, y: top + space, width: space * 0.45, height: space * 2).fill()
            NSRect(x: staffLeft + space * 2.0, y: top + space, width: space * 0.45, height: space * 2).fill()
        } else {
            let symbols = NSFont(name: "Apple Symbols", size: space * (score.clef == .treble ? 7.2 : 4.2)) ?? .systemFont(ofSize: space * 5)
            let clef = score.clef == .treble ? "\u{1D11E}" : "\u{1D122}"
            let clefAttrs: [NSAttributedString.Key: Any] = [.font: symbols, .foregroundColor: ink]
            let clefSize = (clef as NSString).size(withAttributes: clefAttrs)
            let clefY = score.clef == .treble ? top + space * 2 - clefSize.height * 0.56 : top - clefSize.height * 0.19
            (clef as NSString).draw(at: NSPoint(x: staffLeft + space * 0.4, y: clefY), withAttributes: clefAttrs)
        }
        // Key signature (the key of the line's first bar) — none on a drum staff.
        let fifths = score.clef == .percussion ? 0 : score.fifths(inBar: systemFirstBars.indices.contains(system) ? systemFirstBars[system] : 0)
        let x = drawKeySignature(fifths, x: staffLeft + space * 4.2, system: system, ink: ink)
        // Time signature (first line only).
        if system == 0 {
            let font = NSFont(name: "Georgia-Bold", size: space * 2.7) ?? .boldSystemFont(ofSize: space * 2.7)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink]
            for (i, number) in ["\(score.beats)", "\(score.beatUnit)"].enumerated() {
                let size = (number as NSString).size(withAttributes: attrs)
                (number as NSString).draw(at: NSPoint(x: x + space * 0.4 + (space * 1.8 - size.width) / 2,
                                                      y: top + CGFloat(i) * space * 2 + space - size.height / 2), withAttributes: attrs)
            }
        }
    }

    private func drawAccidental(_ alter: Int, x: CGFloat, y: CGFloat, ink: NSColor) {
        let glyph = alter > 0 ? "\u{266F}" : alter < 0 ? "\u{266D}" : "\u{266E}"
        let font = NSFont(name: "Apple Symbols", size: space * 3.1) ?? .systemFont(ofSize: space * 3)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink]
        let size = (glyph as NSString).size(withAttributes: attrs)
        let lift = alter < 0 ? size.height * 0.62 : size.height * 0.52
        (glyph as NSString).draw(at: NSPoint(x: x, y: y - lift), withAttributes: attrs)
    }

    /// Beamed groups: eighths and sixteenths together within a beat (a dotted quarter in compound time) and a bar.
    private func beamGroups(_ score: ScoreData, _ placed: [Placed]) -> [[Int]] {
        var groups: [[Int]] = []
        let beat = score.beatUnit == 8 && score.beats % 3 == 0 ? 1.5 : (score.beatUnit == 2 ? 2.0 : 1.0)
        for bar in score.measures {
            var position = 0.0
            var current: [Int] = []
            var currentBeat = -1
            for i in bar {
                let note = score.notes[i]
                if note.grace != nil { continue }
                // Beat slashes have no stems, so no beams either.
                if note.slash == "beat" {
                    if current.count > 1 { groups.append(current) }
                    current = []; currentBeat = -1
                    position += note.beats
                    continue
                }
                let beatIndex = Int((position + 1e-9) / beat)
                if !note.rest, note.duration.rawValue >= 8, beatIndex == currentBeat || current.isEmpty {
                    current.append(i)
                    currentBeat = beatIndex
                } else {
                    if current.count > 1 { groups.append(current) }
                    current = []
                    currentBeat = -1
                    if !note.rest, note.duration.rawValue >= 8 {
                        current = [i]
                        currentBeat = beatIndex
                    }
                }
                position += note.beats
            }
            if current.count > 1 { groups.append(current) }
        }
        // A group stays on one line.
        return groups.filter { g in Set(g.compactMap { i in placed.first { $0.index == i }?.system }).count == 1 }
    }

    /// Each note's lowest and highest head (y), for stems through chords.
    private var stemSpans: [Int: (low: CGFloat, high: CGFloat)] = [:]
    /// Every drawn note's stem direction and head span (for slurs).
    private var shapes: [NoteRef: (up: Bool, low: CGFloat, high: CGFloat)] = [:]

    private func drawNotes(ink: NSColor) {
        shapes = [:]
        // With two voices, voice 1's stems go up and voice 2's down.
        let two = score.hasSecondVoice
        for v in 0..<ScoreData.voiceCount where !score.line(v).isEmpty {
            drawVoice(v, ink: ink, forcedUp: two ? v == 0 : nil)
        }
    }

    private func drawVoice(_ v: Int, ink: NSColor, forcedUp: Bool?) {
        let score = self.score.forVoice(v)
        let placed = self.placed.filter { $0.voice == v }
        stemSpans = [:]
        let groups = beamGroups(score, placed)
        var beamed: [Int: (group: [Int], up: Bool)] = [:]
        // Groups across two staves (cross-staff notes): the beam goes between them, stems down from the upper
        // staff's notes and up from the lower's.
        var crossGroups: [[Int]: (upper: Int, lower: Int)] = [:]
        for g in groups {
            let staves = Set(g.map { drawnStaff(score.notes[$0]) })
            if staves.count > 1, let upper = staves.min(), let lower = staves.max() {
                crossGroups[g] = (upper, lower)
                for i in g { beamed[i] = (g, drawnStaff(score.notes[i]) != upper) }
                continue
            }
            let average = g.reduce(0) { $0 + position(score.notes[$1]) } / g.count
            for i in g { beamed[i] = (g, forcedUp ?? (average < 4)) }
        }
        defer { drawTriplets(score, placed, v: v, forcedUp: forcedUp, ink: ink) }
        for p in placed {
            let note = score.notes[p.index]
            let color = colorFor(NoteRef(voice: v, index: p.index), ink: ink)
            if note.rest {
                drawRest(note, x: p.x, system: p.system, color: color, lift: forcedUp.map { $0 ? -space * 1.5 : space * 1.5 } ?? 0)
                continue
            }
            if note.grace != nil {
                drawGrace(note, p, v: v, in: score, color: color, up: forcedUp ?? true)
                continue
            }
            let pos = position(note)
            let cy = y(position: pos, system: p.system, of: note)
            // Ledger lines.
            color.setFill()
            if pos <= -2 { for l in stride(from: -2, through: pos, by: -2) { ledger(x: p.x, y: y(position: l, system: p.system, of: note)) } }
            if pos >= 10 { for l in stride(from: 10, through: pos, by: 2) { ledger(x: p.x, y: y(position: l, system: p.system, of: note)) } }
            if score.showsAccidental(p.index) { drawAccidental(note.alter ?? 0, x: p.x - space * 1.35, y: cy, ink: color) }
            // Head.
            let w = note.duration == .whole ? space * 1.5 : space * 1.25, h = space * 0.95
            let head = NSBezierPath(ovalIn: NSRect(x: -w / 2, y: -h / 2, width: w, height: h))
            var transform = AffineTransform(translationByX: p.x + w / 2, byY: cy)
            if note.duration != .whole { transform.rotate(byDegrees: -20) }
            head.transform(using: transform)
            color.set()
            if note.slash != nil {
                // A slash across the middle of the staff (hollow for halves and wholes); a muted strum, an x.
                if note.guitar?.dead == true { drawMutedSlash(x: p.x, y: cy, color: color) } else { drawSlash(x: p.x, y: cy, filled: note.duration.rawValue >= 4, color: color) }
            } else if note.guitar?.dead == true || note.guitar?.harmonic != nil {
                // A dead note: an x; a harmonic: a diamond.
                DrumKit.drawHead(note.guitar?.dead == true ? .x : .diamond, x: p.x, y: cy, width: w, height: h, color: color,
                                 filled: note.duration.rawValue >= 4 && note.guitar?.dead == true)
            } else if let drum = DrumKit.instrument(note.drum), drum.head != .normal {
                // Cymbals and hi-hats: an x (the open hi-hat with a circle over it); the ride bell: a diamond.
                DrumKit.drawHead(drum.head, x: p.x, y: cy, width: w, height: h, color: color, filled: note.duration.rawValue >= 4)
            } else if note.duration.rawValue >= 4 {
                head.fill()
            } else {
                head.lineWidth = note.duration == .whole ? 1.6 : 1.4
                head.stroke()
            }
            // Chord notes: more heads on the same stem (a step apart: side by side).
            let tones = note.chord ?? []
            let allPositions = ([pos] + tones.map { position($0.diatonic, of: note) }).sorted()
            let up = beamed[p.index]?.up ?? forcedUp ?? (allPositions.reduce(0, +) / allPositions.count < 4)
            if !tones.isEmpty {
                var shifted = Set<Int>()
                for (k, tp) in allPositions.enumerated() where k > 0 && tp - allPositions[k - 1] == 1 && !shifted.contains(allPositions[k - 1]) {
                    shifted.insert(up ? tp : allPositions[k - 1])
                }
                for tone in tones {
                    let tp = position(tone.diatonic, of: note)
                    let tx = shifted.contains(tp) ? (up ? p.x + w - 1 : p.x - w + 1) : p.x
                    let ty = y(position: tp, system: p.system, of: note)
                    color.setFill()
                    if tp <= -2 { for l in stride(from: -2, through: tp, by: -2) { ledger(x: tx, y: y(position: l, system: p.system, of: note)) } }
                    if tp >= 10 { for l in stride(from: 10, through: tp, by: 2) { ledger(x: tx, y: y(position: l, system: p.system, of: note)) } }
                    if let alter = tone.alter, alter != score.keyAlter(tone.step, at: p.index) {
                        drawAccidental(alter, x: p.x - space * 1.35 - (score.showsAccidental(p.index) ? space * 1.2 : 0), y: ty, ink: color)
                    }
                    let extra = NSBezierPath(ovalIn: NSRect(x: -w / 2, y: -h / 2, width: w, height: h))
                    var t = AffineTransform(translationByX: tx + w / 2, byY: ty)
                    if note.duration != .whole { t.rotate(byDegrees: -20) }
                    extra.transform(using: t)
                    color.set()
                    if let drum = DrumKit.instrument(tone.drum), drum.head != .normal {
                        DrumKit.drawHead(drum.head, x: tx, y: ty, width: w, height: h, color: color, filled: note.duration.rawValue >= 4)
                    } else if note.duration.rawValue >= 4 { extra.fill() } else { extra.lineWidth = 1.4; extra.stroke() }
                }
                if shifted.contains(pos) {
                    // The note itself moved beside its neighbour: redraw it there.
                    NSColor.white.setFill()
                    head.fill()
                    let moved = NSBezierPath(ovalIn: NSRect(x: -w / 2, y: -h / 2, width: w, height: h))
                    var t = AffineTransform(translationByX: (up ? p.x + w - 1 : p.x - w + 1) + w / 2, byY: cy)
                    if note.duration != .whole { t.rotate(byDegrees: -20) }
                    moved.transform(using: t)
                    color.set()
                    if note.duration.rawValue >= 4 { moved.fill() } else { moved.lineWidth = 1.4; moved.stroke() }
                }
            }
            // The stem runs from the far head to past the near one.
            let lowY = y(position: allPositions.first!, system: p.system, of: note), highY = y(position: allPositions.last!, system: p.system, of: note)
            stemSpans[p.index] = (lowY, highY)
            shapes[NoteRef(voice: v, index: p.index)] = (up, lowY, highY)
            // Stem and flags (beamed notes get their stems with the beam).
            if note.duration != .whole, beamed[p.index] == nil, note.slash != "beat" {
                let sx = up ? p.x + w - 0.6 : p.x + 0.6
                let from = up ? lowY : highY
                let end = up ? highY - space * 3.5 : lowY + space * 3.5
                color.setFill()
                NSRect(x: sx - 0.6, y: min(from, end), width: 1.2, height: abs(end - from)).fill()
                if note.duration.rawValue >= 8 {
                    for f in 0..<(note.duration == .sixteenth ? 2 : 1) {
                        let fy = end + (up ? 1 : -1) * CGFloat(f) * space * 0.8
                        let flag = NSBezierPath()
                        flag.move(to: NSPoint(x: sx, y: fy))
                        flag.curve(to: NSPoint(x: sx + space * 0.9, y: fy + (up ? 1 : -1) * space * 2.4),
                                   controlPoint1: NSPoint(x: sx + space * 0.2, y: fy + (up ? 1 : -1) * space * 0.9),
                                   controlPoint2: NSPoint(x: sx + space * 1.4, y: fy + (up ? 1 : -1) * space * 1.3))
                        flag.lineWidth = 1.6
                        flag.stroke()
                    }
                }
            }
            // Dot.
            if note.dotted {
                let dy = pos % 2 == 0 ? cy - space / 2 : cy
                NSBezierPath(ovalIn: NSRect(x: p.x + w + space * 0.35, y: dy - 1.7, width: 3.4, height: 3.4)).fill()
            }
            // Tie to the next note.
            if note.tie, let next = placed.first(where: { $0.index == p.index + 1 }), next.system == p.system {
                let tie = NSBezierPath()
                let below = pos >= 4
                let ty = cy + (below ? -1 : 1) * space * -0.8
                tie.move(to: NSPoint(x: p.x + w, y: ty))
                tie.curve(to: NSPoint(x: next.x, y: ty), controlPoint1: NSPoint(x: p.x + w + space, y: ty + (below ? -1 : 1) * space * -1),
                          controlPoint2: NSPoint(x: next.x - space, y: ty + (below ? -1 : 1) * space * -1))
                tie.lineWidth = 1.2
                tie.stroke()
            }
        }
        // Beams.
        for g in groups {
            if let across = crossGroups[g] {
                drawCrossStaffBeam(g, across: across, score: score, placed: placed, beamed: beamed, v: v, ink: ink)
                continue
            }
            guard let up = beamed[g[0]]?.up else { continue }
            let points = g.compactMap { i -> (x: CGFloat, y: CGFloat, i: Int)? in
                guard let p = placed.first(where: { $0.index == i }) else { return nil }
                let w = space * 1.25
                return (up ? p.x + w - 0.6 : p.x + 0.6, y(position: position(score.notes[i]), system: p.system, of: score.notes[i]), i)
            }
            guard let first = points.first, let last = points.last else { continue }
            // A gentle slope, stems at least 3 spaces.
            let slope = max(-0.25, min(0.25, (last.y - first.y) / max(1, last.x - first.x)))
            func beamY(_ x: CGFloat) -> CGFloat { first.y + slope * (x - first.x) }
            var offset: CGFloat = up ? -space * 3.5 : space * 3.5
            for pt in points {
                let span = stemSpans[pt.i] ?? (pt.y, pt.y)
                let near = up ? span.high : span.low
                let needed = up ? (near - space * 3) - beamY(pt.x) : (near + space * 3) - beamY(pt.x)
                offset = up ? min(offset, needed) : max(offset, needed)
            }
            for pt in points {
                colorFor(NoteRef(voice: v, index: pt.i), ink: ink).setFill()
                let end = beamY(pt.x) + offset
                let span = stemSpans[pt.i] ?? (pt.y, pt.y)
                let from = up ? span.low : span.high
                NSRect(x: pt.x - 0.6, y: min(from, end), width: 1.2, height: abs(end - from)).fill()
            }
            ink.setFill()
            for level in 0..<2 {
                // Second beam between sixteenths.
                var runStart: Int?
                for (k, pt) in points.enumerated() {
                    let needs = level == 0 || score.notes[pt.i].duration == .sixteenth
                    if needs, runStart == nil { runStart = k }
                    if (!needs || k == points.count - 1), let s = runStart {
                        let e = needs ? k : k - 1
                        let shift = CGFloat(level) * space * 0.75 * (up ? 1 : -1)
                        let x1 = points[s].x, x2 = e > s ? points[e].x : points[s].x + (s > 0 ? -space : space)
                        let beam = NSBezierPath()
                        let t: CGFloat = space * 0.5 * (up ? 1 : -1)
                        beam.move(to: NSPoint(x: x1, y: beamY(x1) + offset + shift))
                        beam.line(to: NSPoint(x: x2, y: beamY(x2) + offset + shift))
                        beam.line(to: NSPoint(x: x2, y: beamY(x2) + offset + shift + t))
                        beam.line(to: NSPoint(x: x1, y: beamY(x1) + offset + shift + t))
                        beam.close()
                        beam.fill()
                        runStart = nil
                    }
                }
            }
        }
    }

    /// A beam between two staves: level with the middle of the gap, stems down to it from the upper staff's notes
    /// and up to it from the lower's.
    private func drawCrossStaffBeam(_ g: [Int], across: (upper: Int, lower: Int), score: ScoreData, placed: [Placed],
                                    beamed: [Int: (group: [Int], up: Bool)], v: Int, ink: NSColor) {
        let spots = g.compactMap { i in placed.first { $0.index == i }.map { (i, $0) } }
        guard let system = spots.first?.1.system else { return }
        let gapTop = staffTop(system, staff: across.upper) + space * 4, gapBottom = staffTop(system, staff: across.lower)
        let thickness = space * 0.5
        let levels = g.contains { score.notes[$0].duration == .sixteenth } ? 2 : 1
        // The beams' top edge, the stack centred in the gap.
        let top = (gapTop + gapBottom) / 2 - (thickness + CGFloat(levels - 1) * space * 0.75) / 2
        let w = space * 1.25
        var points: [(x: CGFloat, i: Int)] = []
        for (i, p) in spots {
            let up = beamed[i]?.up ?? false
            let x = up ? p.x + w - 0.6 : p.x + 0.6
            let span = stemSpans[i] ?? (gapTop, gapTop)
            // Down from the upper staff's highest head to the beams' far edge; up from the lower staff's lowest head.
            let from = up ? span.low : span.high
            let end = up ? top : top + thickness + CGFloat(levels - 1) * space * 0.75
            colorFor(NoteRef(voice: v, index: i), ink: ink).setFill()
            NSRect(x: x - 0.6, y: min(from, end), width: 1.2, height: abs(end - from)).fill()
            points.append((x, i))
        }
        ink.setFill()
        for level in 0..<levels {
            var runStart: Int?
            for (k, pt) in points.enumerated() {
                let needs = level == 0 || score.notes[pt.i].duration == .sixteenth
                if needs, runStart == nil { runStart = k }
                if (!needs || k == points.count - 1), let s = runStart {
                    let e = needs ? k : k - 1
                    let x1 = points[s].x, x2 = e > s ? points[e].x : points[s].x + (s > 0 ? -space : space)
                    let y = top + CGFloat(level) * space * 0.75
                    NSRect(x: min(x1, x2), y: y, width: abs(x2 - x1) + 0.6, height: thickness).fill()
                    runStart = nil
                }
            }
        }
    }

    private func colorFor(_ ref: NoteRef, ink: NSColor) -> NSColor {
        let ref = NoteRef(voice: ref.voice, index: ref.index, staff: drawingStaff)
        if playing.contains(ref) { return .systemOrange }
        // Only the staff being written shows its selection; the others are a little lighter while editing.
        if !isExport, ScoreView.active === self, fullScore.staffCount > 1, drawingStaff != staffIndex { return NSColor(white: 0.35, alpha: 1) }
        if !isExport, ref.voice == voice, ref.index == selected || ref.index == lastEntered || selectedRange?.contains(ref.index) == true,
           ScoreView.active === self { return .controlAccentColor }
        // The voice not being written is drawn a little lighter while editing.
        if !isExport, score.hasSecondVoice, ScoreView.active === self, ref.voice != voice { return NSColor(white: 0.45, alpha: 1) }
        return ink
    }

    /// Triplets: a 3 over (or under) each group, with a bracket when the notes aren't beamed together.
    private func drawTriplets(_ score: ScoreData, _ placed: [Placed], v: Int, forcedUp: Bool?, ink: NSColor) {
        let font = NSFont(name: "Georgia-BoldItalic", size: 12) ?? .boldSystemFont(ofSize: 12)
        for bar in score.measures {
            for group in score.tupletGroups(in: bar) {
                let spots = group.compactMap { i in placed.first { $0.index == i } }
                guard let first = spots.first, let last = spots.last, first.system == last.system else { continue }
                let positions = group.map { score.notes[$0].rest ? 4 : position(score.notes[$0]) }
                let up = forcedUp ?? (positions.reduce(0, +) / max(1, positions.count) < 4)
                let ys = group.map { score.notes[$0].rest ? staffTop(first.system) + space * 2 : y(position: position(score.notes[$0]), system: first.system, of: score.notes[$0]) }
                let x1 = first.x - space * 0.2, x2 = last.x + space * 1.45
                let yLine = up ? min(ys.min()! - space * 4.4, staffTop(first.system) - space * 1.2) : max(ys.max()! + space * 4.4, staffTop(first.system) + space * 5.2)
                let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: colorFor(NoteRef(voice: v, index: group[0]), ink: ink)]
                let number = "\(score.notes[group[0]].tupletActual ?? 3)" as NSString
                let size = number.size(withAttributes: attrs)
                let mid = (x1 + x2) / 2
                number.draw(at: NSPoint(x: mid - size.width / 2, y: yLine - size.height / 2), withAttributes: attrs)
                let beamedTogether = group.allSatisfy { score.notes[$0].duration.rawValue >= 8 && !score.notes[$0].rest } && group.count > 1
                if !beamedTogether {
                    ink.setStroke()
                    let bracket = NSBezierPath()
                    let hook: CGFloat = up ? space * 0.6 : -space * 0.6
                    bracket.move(to: NSPoint(x: x1, y: yLine + hook))
                    bracket.line(to: NSPoint(x: x1, y: yLine))
                    bracket.line(to: NSPoint(x: mid - size.width / 2 - 2, y: yLine))
                    bracket.move(to: NSPoint(x: mid + size.width / 2 + 2, y: yLine))
                    bracket.line(to: NSPoint(x: x2, y: yLine))
                    bracket.line(to: NSPoint(x: x2, y: yLine + hook))
                    bracket.lineWidth = 1
                    bracket.stroke()
                }
            }
        }
    }

    /// A grace note: a small head on a short stem, flagged; an acciaccatura has a slash through the stem.
    private func drawGrace(_ note: ScoreNote, _ p: Placed, v: Int, in score: ScoreData, color: NSColor, up: Bool) {
        let scale: CGFloat = 0.66
        let pos = position(note)
        let cy = y(position: pos, system: p.system, of: note)
        color.setFill()
        if pos <= -2 { for l in stride(from: -2, through: pos, by: -2) { NSRect(x: p.x - space * 0.3, y: y(position: l, system: p.system, of: note) - 0.5, width: space * 1.5, height: 1).fill() } }
        if pos >= 10 { for l in stride(from: 10, through: pos, by: 2) { NSRect(x: p.x - space * 0.3, y: y(position: l, system: p.system, of: note) - 0.5, width: space * 1.5, height: 1).fill() } }
        if score.showsAccidental(p.index) { drawAccidental(note.alter ?? 0, x: p.x - space * 1.15, y: cy, ink: color) }
        let w = space * 1.25 * scale, h = space * 0.95 * scale
        let head = NSBezierPath(ovalIn: NSRect(x: -w / 2, y: -h / 2, width: w, height: h))
        var t = AffineTransform(translationByX: p.x + w / 2, byY: cy)
        t.rotate(byDegrees: -20)
        head.transform(using: t)
        color.set()
        if note.duration.rawValue >= 4 { head.fill() } else { head.lineWidth = 1.1; head.stroke() }
        let sx = up ? p.x + w - 0.5 : p.x + 0.5
        let end = up ? cy - space * 2.6 : cy + space * 2.6
        NSRect(x: sx - 0.5, y: min(cy, end), width: 1, height: abs(end - cy)).fill()
        let dir: CGFloat = up ? 1 : -1
        if note.duration.rawValue >= 8 {
            for f in 0..<(note.duration == .sixteenth ? 2 : 1) {
                let fy = end + dir * CGFloat(f) * space * 0.55
                let flag = NSBezierPath()
                flag.move(to: NSPoint(x: sx, y: fy))
                flag.curve(to: NSPoint(x: sx + space * 0.6, y: fy + dir * space * 1.6),
                           controlPoint1: NSPoint(x: sx + space * 0.15, y: fy + dir * space * 0.6),
                           controlPoint2: NSPoint(x: sx + space * 0.95, y: fy + dir * space * 0.9))
                flag.lineWidth = 1.2
                flag.stroke()
            }
        }
        if note.grace == "acciaccatura" {
            let slash = NSBezierPath()
            slash.move(to: NSPoint(x: sx - space * 0.55, y: end + dir * space * 1.75))
            slash.line(to: NSPoint(x: sx + space * 0.85, y: end + dir * space * 0.45))
            slash.lineWidth = 1.1
            slash.stroke()
        }
        stemSpans[p.index] = (cy, cy)
        shapes[NoteRef(voice: v, index: p.index)] = (up, cy, cy)
    }

    /// A slash notehead: a thick stroke rising from the second line to the fourth.
    private func drawSlash(x: CGFloat, y: CGFloat, filled: Bool, color: NSColor) {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: x - space * 0.1, y: y + space))
        path.line(to: NSPoint(x: x + space * 0.5, y: y + space))
        path.line(to: NSPoint(x: x + space * 1.45, y: y - space))
        path.line(to: NSPoint(x: x + space * 0.85, y: y - space))
        path.close()
        color.set()
        if filled { path.fill() } else { path.lineWidth = 1.3; path.stroke() }
    }

    /// A muted strum in slash notation: an x the size of a slash.
    private func drawMutedSlash(x: CGFloat, y: CGFloat, color: NSColor) {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: x + space * 0.05, y: y - space * 0.85))
        path.line(to: NSPoint(x: x + space * 1.3, y: y + space * 0.85))
        path.move(to: NSPoint(x: x + space * 0.05, y: y + space * 0.85))
        path.line(to: NSPoint(x: x + space * 1.3, y: y - space * 0.85))
        path.lineWidth = space * 0.26
        path.lineCapStyle = .round
        color.set()
        path.stroke()
    }

    private func ledger(x: CGFloat, y: CGFloat) {
        NSRect(x: x - space * 0.45, y: y - 0.6, width: space * 2.15, height: 1.2).fill()
    }

    private func drawRest(_ note: ScoreNote, x: CGFloat, system: Int, color: NSColor, lift: CGFloat = 0) {
        // Two voices: voice 1's rests sit higher, voice 2's lower.
        let top = staffTop(system) + lift
        color.set()
        switch note.duration {
        case .whole:
            NSRect(x: x, y: top + space, width: space * 1.3, height: space * 0.55).fill()
        case .half:
            NSRect(x: x, y: top + space * 2 - space * 0.55, width: space * 1.3, height: space * 0.55).fill()
        case .quarter:
            let path = NSBezierPath()
            let cx = x + space * 0.6
            path.move(to: NSPoint(x: cx - space * 0.3, y: top + space * 0.6))
            path.line(to: NSPoint(x: cx + space * 0.4, y: top + space * 1.5))
            path.line(to: NSPoint(x: cx - space * 0.3, y: top + space * 2.3))
            path.line(to: NSPoint(x: cx + space * 0.4, y: top + space * 3.0))
            path.curve(to: NSPoint(x: cx, y: top + space * 3.6), controlPoint1: NSPoint(x: cx - space * 0.6, y: top + space * 2.9),
                       controlPoint2: NSPoint(x: cx - space * 0.5, y: top + space * 3.4))
            path.lineWidth = 2.2
            path.lineJoinStyle = .round
            path.stroke()
        case .eighth, .sixteenth:
            let count = note.duration == .sixteenth ? 2 : 1
            for k in 0..<count {
                let dy = top + space * 1.5 + CGFloat(k) * space
                NSBezierPath(ovalIn: NSRect(x: x, y: dy - space * 0.35, width: space * 0.7, height: space * 0.7)).fill()
                let stroke = NSBezierPath()
                stroke.move(to: NSPoint(x: x + space * 0.6, y: dy))
                stroke.line(to: NSPoint(x: x + space * 1.3, y: dy - space * 0.3))
                stroke.lineWidth = 1.4
                stroke.stroke()
            }
            let stem = NSBezierPath()
            stem.move(to: NSPoint(x: x + space * 1.3, y: top + space * 1.2))
            stem.line(to: NSPoint(x: x + space * 0.7, y: top + space * (count == 2 ? 3.8 : 3.0)))
            stem.lineWidth = 1.3
            stem.stroke()
        }
        if note.dotted {
            NSBezierPath(ovalIn: NSRect(x: x + space * 1.7, y: top + space * 1.5 - 1.7, width: 3.4, height: 3.4)).fill()
        }
    }

    private func drawCaret() {
        guard !isExport, ScoreView.active === self, selected == nil, cursor < caretSpots.count else { return }
        let spot = caretSpots[cursor]
        NSColor.controlAccentColor.setFill()
        NSRect(x: spot.x - 1, y: staffTop(spot.system) - space * 1.5, width: 2, height: space * 7).fill()
    }

    // MARK: Editing

    func edit(_ name: String, _ change: (inout ScoreData) -> Void) {
        owner?.update(change, actionName: name)
        needsDisplay = true
    }

    /// Changes the current staff's current voice (the change sees that voice, as it's shown, as the score's notes;
    /// in concert pitch, what's written goes back to where the instrument reads it).
    func editVoice(_ name: String, _ change: (inout ScoreData) -> Void) {
        let v = voice, st = staffIndex
        edit(name) { full in
            var view = full.shown(st).forVoice(v)
            change(&view)
            full.setShownLine(st, voice: v, view.notes)
        }
    }

    /// A key chosen while looking at this staff, as the score keeps it: a transposing staff's written key (shown
    /// when Concert Pitch is off) is turned into the concert key.
    func concertKey(_ shownKey: Int) -> Int {
        let full = fullScore
        guard full.concertPitch != true, let t = full.forStaff(staffIndex).transposition else { return shownKey }
        return ScoreData.concertKey(shownKey, t)
    }

    /// The key signature at the start, as chosen on this staff.
    func setKey(_ fifths: Int) {
        let key = concertKey(fifths)
        edit("Key Signature") { $0.keyFifths = key }
        NotebookStore.shared.editor.scoreInputChanged += 1
    }

    // MARK: Staves

    var currentStaff: Int { staffIndex }

    /// Write on another staff (⌥⌘↑ / ⌥⌘↓, or click it): voice 1, the cursor at its end.
    func setStaff(_ i: Int) {
        guard (0..<fullScore.staffCount).contains(i) else { return NSSound.beep() }
        staffIndex = i
        useStaff(i)
        voice = 0
        selected = nil
        rangeEnd = nil
        lastEntered = nil
        cursor = cur.notes.count
        NotebookStore.shared.editor.scoreInputChanged += 1
        needsDisplay = true
    }

    /// Adds an empty staff at the bottom (or a bass staff under a single treble one, joined as a piano grand staff).
    func addStaff(_ clef: ScoreData.Clef, grand: Bool = false) {
        edit(grand ? "Piano Grand Staff" : "Add Staff") { full in
            var st = ScoreData()
            st.clef = clef
            full.setStaff(full.staffCount, st)
            if grand { full.grandStaff = true; full.clef = .treble }
        }
        setStaff(fullScore.staffCount - 1)
    }

    /// Makes the score a piano score: treble and bass staves joined by a brace.
    func makeGrandStaff() {
        if fullScore.staffCount == 1 {
            addStaff(.bass, grand: true)
        } else {
            edit("Piano Grand Staff") { $0.grandStaff = $0.grandStaff == true ? nil : true }
            NotebookStore.shared.editor.scoreInputChanged += 1
        }
    }

    /// Removes the staff being written (its notes go too; Undo brings them back).
    func removeStaff() {
        let i = staffIndex
        guard fullScore.staffCount > 1 else { return NSSound.beep() }
        edit("Remove Staff") { full in
            var all = (0..<full.staffCount).map { full.forStaff($0) }
            all.remove(at: i)
            full.setStaff(0, all[0])
            full.staves = all.count > 1 ? all.dropFirst().map {
                ScoreStaff(name: $0.staffName, clef: $0.clef, notes: $0.notes, voices: $0.voices, transpose: $0.transpose, instrument: $0.instrument)
            } : nil
            if full.staffCount < 2 || i < 2 { full.grandStaff = nil }
        }
        setStaff(max(0, i - 1))
    }

    /// Moves the staff being written up or down among the staves.
    func moveStaff(by delta: Int) {
        let i = staffIndex, j = staffIndex + delta
        guard (0..<fullScore.staffCount).contains(j) else { return NSSound.beep() }
        edit("Move Staff") { full in
            let a = full.forStaff(i), b = full.forStaff(j)
            full.setStaff(i, b)
            full.setStaff(j, a)
        }
        setStaff(j)
    }

    /// The current staff's clef.
    func setClef(_ clef: ScoreData.Clef) {
        let i = staffIndex
        edit("Clef") { full in
            var st = full.forStaff(i)
            st.clef = clef
            full.setStaff(i, st)
        }
        NotebookStore.shared.editor.scoreInputChanged += 1
    }

    /// The current staff's name (for exports and menus).
    func renameStaff() {
        let alert = NSAlert()
        alert.messageText = "Staff Name"
        alert.informativeText = "A name for \(fullScore.staffTitle(staffIndex)) — the instrument or part (Violin, Left Hand…)."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = score.staffName ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let i = staffIndex, name = field.stringValue.trimmingCharacters(in: .whitespaces)
        edit("Staff Name") { full in
            var st = full.forStaff(i)
            st.staffName = name.isEmpty ? nil : name
            full.setStaff(i, st)
        }
    }

    func activate() {
        ScoreView.active = self
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        NotebookStore.shared.editor.ribbonTab = .score
        needsDisplay = true
    }

    override func becomeFirstResponder() -> Bool {
        ScoreView.active = self
        needsDisplay = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        // Focus moving to another container on the page ends editing (not the ribbon or a panel).
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, let canvas = self.owner?.canvas else { return }
            if let view = window.firstResponder as? NSView, view !== self, !view.isDescendant(of: self), view.isDescendant(of: canvas) {
                if ScoreView.active === self { ScoreView.active = nil }
                self.needsDisplay = true
            }
        }
        return true
    }

    func select(_ index: Int?) {
        selected = index.flatMap { cur.notes.indices.contains($0) ? $0 : nil }
        rangeEnd = nil
        lastEntered = nil
        if let selected { cursor = selected + 1 }
        needsDisplay = true
        NotebookStore.shared.editor.scoreInputChanged += 1
    }

    /// The note commands act on: the selected one, else the one just typed.
    private var target: Int? {
        let i = selected ?? lastEntered
        return i.flatMap { cur.notes.indices.contains($0) ? $0 : nil }
    }

    /// Adds a note (or rest) after the cursor; a note goes in the octave nearest the note before it.
    func insert(step: Int?, octave: Int? = nil) {
        var note = ScoreNote(duration: Self.inputDuration, dotted: Self.inputDotted, rest: step == nil)
        if let ratio = Self.inputTuplet {
            note.tuplet = true
            note.tupletRatio = ratio == [3, 2] ? nil : ratio
        }
        if let step {
            note.step = step
            if let octave {
                note.octave = octave
            } else {
                let previous = cur.notes[..<min(cursor, cur.notes.count)].last { !$0.rest }
                let reference = previous?.diatonic ?? (score.clef == .treble ? 4 * 7 + 6 : 3 * 7 + 1)
                var best = 4
                for o in 1...7 where abs(o * 7 + step - reference) < abs(best * 7 + step - reference) { best = o }
                note.octave = best
            }
        }
        // Slash entry: rhythmic slashes on the middle line (they play the chord symbol in effect).
        if Self.inputSlash, step != nil {
            note.slash = "rhythm"
            (note.step, note.octave) = cur.middleLine
            note.alter = nil
        }
        let at = min(cursor, cur.notes.count)
        // Between two notes of an ottava passage, the new note joins it.
        note.ottava = ottava(joining: at)
        editVoice(step == nil ? "Add Rest" : "Add Note") { $0.notes.insert(note, at: at) }
        // Keep entering after it.
        selected = nil
        lastEntered = at
        cursor = at + 1
        needsDisplay = true
        hear(at)
    }

    private func changeSelected(_ name: String, _ change: (inout ScoreNote) -> Void) {
        guard let i = target else { return NSSound.beep() }
        editVoice(name) { change(&$0.notes[i]) }
        hear(i)
    }

    func moveSelected(steps: Int) {
        changeSelected("Move Note") { n in
            guard !n.rest else { return }
            // A drum note moves to the instrument above or below.
            if let id = n.drum {
                if let next = DrumKit.neighbor(of: id, steps) { n.drum = next.id; n.step = next.step; n.octave = next.octave }
                return
            }
            let d = max(0, min(9 * 7, n.diatonic + steps))
            n.octave = d / 7
            n.step = d % 7
            n.alter = nil
        }
    }

    func setDuration(_ duration: ScoreNote.Duration) {
        Self.inputDuration = duration
        if selected != nil { changeSelected("Note Length") { $0.duration = duration } }
        NotebookStore.shared.editor.scoreInputChanged += 1
    }

    func toggleDot() {
        if let s = selected {
            changeSelected("Dot") { $0.dotted.toggle() }
            Self.inputDotted = cur.notes[s].dotted
        } else {
            Self.inputDotted.toggle()
        }
        NotebookStore.shared.editor.scoreInputChanged += 1
    }

    /// Sharp (1), flat (-1) or natural (0) on the selected note; again takes it off.
    func setAccidental(_ alter: Int) {
        changeSelected("Accidental") { n in
            guard !n.rest else { return }
            n.alter = n.alter == alter ? nil : alter
        }
    }

    func toggleTie() { changeSelected("Tie") { $0.tie.toggle() } }

    // MARK: Chords, guitar strings

    /// Adds a note to the chord: the step in the octave just above the chord's top note (⇧A–G).
    func addChordTone(step: Int) {
        guard let i = target, !cur.notes[i].rest else { return NSSound.beep() }
        let note = cur.notes[i]
        let top = ([note.diatonic] + (note.chord ?? []).map(\.diatonic)).max()!
        var octave = top / 7
        if octave * 7 + step <= top { octave += 1 }
        editVoice("Add Chord Note") { $0.notes[i].chord = ($0.notes[i].chord ?? []) + [ChordTone(step: step, octave: octave)] }
        hear(i)
    }

    /// Plays a note as it's entered (drums on a percussion staff).
    private func hear(_ i: Int) {
        guard cur.notes.indices.contains(i) else { return }
        let keys = cur.midis(i)
        guard !keys.isEmpty else { return }
        if cur.clef == .percussion { ScorePlayer.shared.previewDrums(keys); return }
        // In the staff's sound (guitar an octave under its music).
        let shift = cur.showTab == true ? -(cur.tabOffset - (cur.capo ?? 0)) : 0
        ScorePlayer.shared.preview(keys.map { $0 + shift }, program: cur.sound)
    }

    // MARK: Drums

    /// Adds a drum note after the cursor (on a percussion staff: K kick, S snare, H hi-hat…).
    func insertDrum(_ drum: DrumInstrument) {
        var note = ScoreNote(duration: Self.inputDuration, dotted: Self.inputDotted, rest: false)
        note.drum = drum.id
        note.step = drum.step
        note.octave = drum.octave
        if let ratio = Self.inputTuplet { note.tuplet = true; note.tupletRatio = ratio == [3, 2] ? nil : ratio }
        let at = min(cursor, cur.notes.count)
        editVoice(drum.name) { $0.notes.insert(note, at: at) }
        selected = nil
        lastEntered = at
        cursor = at + 1
        needsDisplay = true
        hear(at)
    }

    /// ⇧ + a drum's key: the drum played with the note (hi-hat with a kick).
    func addDrumToChord(_ drum: DrumInstrument) {
        guard let i = target, !cur.notes[i].rest else { return NSSound.beep() }
        guard cur.notes[i].drum != drum.id, !(cur.notes[i].chord ?? []).contains(where: { $0.drum == drum.id }) else { return }
        editVoice("Add \(drum.name)") { $0.notes[i].chord = ($0.notes[i].chord ?? []) + [ChordTone(step: drum.step, octave: drum.octave, drum: drum.id)] }
        hear(i)
    }

    /// The staff being written is a drum staff.
    var isPercussion: Bool { cur.clef == .percussion }

    func clearChordTones() {
        changeSelected("Remove Chord Notes") { $0.chord = nil }
    }

    /// The selected note onto the next higher (+1) or lower (-1) string, where it can be played.
    func moveString(by delta: Int) {
        guard let i = target, !cur.notes[i].rest, let current = cur.tab(i).first, let pitch = cur.midi(i) else { return NSSound.beep() }
        let st = cur
        let neck = pitch - st.tabOffset
        var string = current.string + delta
        while st.openStrings.indices.contains(string) {
            let fret = neck - st.openStrings[string]
            if (0...st.maxFret).contains(fret) {
                let chosen = string
                editVoice("Guitar String") { $0.notes[i].tabString = chosen }
                if tabInput { tabString = chosen }
                return
            }
            string += delta
        }
        NSSound.beep()
    }

    func toggleTab() {
        edit("Guitar Tab") { $0.showTab = $0.showTab == true ? nil : true }
        if fullScore.showTab != true { tabInput = false }
        NotebookStore.shared.editor.scoreInputChanged += 1
    }

    /// TAB only: the TAB staff (with the rhythm under it) in place of the music.
    func toggleTabOnly() {
        edit("TAB Only") { s in
            s.tabOnly = s.tabOnly == true ? nil : true
            if s.tabOnly == true { s.showTab = true }
        }
        NotebookStore.shared.editor.scoreInputChanged += 1
    }

    /// Guitar chord diagrams over the chord symbols.
    func toggleChordDiagrams() {
        edit("Chord Diagrams") { $0.chordDiagrams = $0.chordDiagrams == true ? nil : true }
        NotebookStore.shared.editor.scoreInputChanged += 1
    }

    /// A chart of every chord used, under the title.
    func toggleChordChart() {
        edit("Chord Chart") { $0.chordChart = $0.chordChart == true ? nil : true }
        NotebookStore.shared.editor.scoreInputChanged += 1
    }

    /// A capo (0: none): TAB counts frets from it; chord names and diagrams show the shapes played.
    func setCapo(_ fret: Int) {
        edit(fret == 0 ? "Remove Capo" : "Capo") { $0.capo = fret > 0 ? fret : nil }
        NotebookStore.shared.editor.scoreInputChanged += 1
    }

    /// A fretted instrument and its tuning (the TAB comes on; an empty staff takes the instrument's clef).
    func setTuning(_ id: String) {
        guard let preset = TabInstrument.preset(id) else { return }
        edit("Tuning") { s in
            s.tabInstrument = id
            s.tabTuning = nil
            s.showTab = true
            if s.clef != preset.clef, !s.notes.contains(where: { !$0.rest }) { s.clef = preset.clef }
        }
        tabString = min(tabString, preset.strings.count - 1)
        NotebookStore.shared.editor.scoreInputChanged += 1
    }

    /// Strings tuned otherwise: typed as notes, lowest first ("D A D G B E", "C2 G2 C3 F3 A3 D4").
    func editTuning() {
        let alert = NSAlert()
        alert.messageText = "Tuning"
        alert.informativeText = "The strings from the lowest (the TAB's bottom line) up, as notes — D A D G B E, or with octaves: C2 G2 C3 F3 A3 D4."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = TabInstrument.letters(fullScore.openStrings)
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let strings = ScoreView.parseTuning(field.stringValue, near: fullScore.openStrings), strings.count >= 3 else { return NSSound.beep() }
        edit("Tuning") { s in
            s.tabTuning = strings == s.fretted.strings ? nil : strings
            s.showTab = true
        }
        tabString = min(tabString, strings.count - 1)
        NotebookStore.shared.editor.scoreInputChanged += 1
    }

    /// Notes typed as a tuning: each with its octave, else the octave nearest the string it replaces (or just
    /// above the string under it).
    static func parseTuning(_ text: String, near current: [Int]) -> [Int]? {
        let letters: [Character: Int] = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11]
        var out: [Int] = []
        let tokens = text.replacingOccurrences(of: ",", with: " ").split(separator: " ").map(String.init)
        for (k, token) in tokens.enumerated() {
            var t = Substring(token)
            guard let first = t.first?.uppercased().first, var pc = letters[first] else { return nil }
            t = t.dropFirst()
            if let c = t.first, "#♯".contains(c) { pc += 1; t = t.dropFirst() } else if let c = t.first, "b♭".contains(c) { pc -= 1; t = t.dropFirst() }
            if let octave = Int(t) {
                out.append((octave + 1) * 12 + pc)
                continue
            }
            guard t.isEmpty else { return nil }
            let target = tokens.count == current.count ? current[k] : (out.last.map { $0 + 5 } ?? 40)
            var best = 12 + pc
            while abs(best + 12 - target) < abs(best - target) { best += 12 }
            if tokens.count != current.count, let last = out.last { while best <= last { best += 12 } }
            out.append(best)
        }
        return out.isEmpty ? nil : out
    }

    /// The staff's sound (General MIDI; nil: piano, or with TAB its instrument's).
    func setSound(_ program: Int?) {
        let st = staffIndex
        edit("Sound") { full in
            var view = full.forStaff(st)
            view.program = program
            full.setStaff(st, view)
        }
        NotebookStore.shared.editor.scoreInputChanged += 1
    }

    // MARK: Typing frets into the TAB

    /// Typing frets: on (the TAB comes on with it) or off.
    func setTabInput(_ on: Bool) {
        if on, fullScore.showTab != true { edit("Guitar Tab") { $0.showTab = true } }
        if on, staffIndex != 0 { setStaff(0) }
        tabInput = on
        tabString = max(0, min(fullScore.stringCount - 1, tabString))
        lastFret = nil
        activate()
        needsDisplay = true
        NotebookStore.shared.editor.scoreInputChanged += 1
    }

    func moveTabString(by delta: Int) {
        tabString = max(0, min(fullScore.stringCount - 1, tabString + delta))
        lastFret = nil
        needsDisplay = true
    }

    /// A fret typed on the current string: onto the selected note (or the one just typed) — changing its note on
    /// that string, or adding one there — else a new note after the caret. Two digits typed quickly make one fret.
    func typeFret(_ digit: Int) {
        let st = cur
        let string = max(0, min(st.stringCount - 1, tabString))
        let now = Date()
        var fret = digit
        var onto: Int? = selected ?? lastEntered.flatMap { $0 == cursor - 1 ? $0 : nil }
        if let last = lastFret, now.timeIntervalSince(last.at) < 1.2, last.string == string, last.value > 0, last.value < 10,
           last.value * 10 + digit <= st.maxFret, cur.notes.indices.contains(last.index) {
            fret = last.value * 10 + digit
            onto = last.index
        }
        guard fret <= st.maxFret else { return NSSound.beep() }
        let pitch = st.notePitch(string: string, fret: fret)
        if let i = onto, cur.notes.indices.contains(i) {
            setFret(pitch, string: string, at: i)
            lastFret = (i, string, fret, now)
        } else {
            let at = min(cursor, cur.notes.count)
            insertPitch(pitch, string: string)
            lastFret = (at, string, fret, now)
        }
    }

    /// The note (or chord note) on a string set to a pitch; the note's other strings kept where they are.
    private func setFret(_ pitch: Int, string: Int, at i: Int) {
        let line = cur
        let spots = line.tab(i)
        let sp = line.spelled(pitch)
        editVoice("Fret") { s in
            var n = s.notes[i]
            if n.rest {
                n.rest = false
                n.chord = nil
                (n.step, n.octave, n.alter, n.tabString) = (sp.step, sp.octave, sp.alter, string)
                s.notes[i] = n
                return
            }
            // Pin what's there to its strings (so adding a note doesn't move the others).
            if let first = spots.first { n.tabString = first.string }
            var tones = n.chord ?? []
            for (k, spot) in spots.dropFirst().enumerated() where k < tones.count { tones[k].tabString = spot.string }
            if let k = spots.firstIndex(where: { $0.string == string }) {
                if k == 0 {
                    (n.step, n.octave, n.alter) = (sp.step, sp.octave, sp.alter)
                } else if k - 1 < tones.count {
                    tones[k - 1].step = sp.step
                    tones[k - 1].octave = sp.octave
                    tones[k - 1].alter = sp.alter
                }
            } else {
                tones.append(ChordTone(step: sp.step, octave: sp.octave, alter: sp.alter, tabString: string))
            }
            n.chord = tones.isEmpty ? nil : tones
            s.notes[i] = n
        }
        hear(i)
    }

    /// A new note (of the current length) at a pitch, on a string, after the caret.
    private func insertPitch(_ pitch: Int, string: Int) {
        let sp = cur.spelled(pitch)
        var note = ScoreNote(duration: Self.inputDuration, dotted: Self.inputDotted, rest: false)
        (note.step, note.octave, note.alter, note.tabString) = (sp.step, sp.octave, sp.alter, string)
        if let ratio = Self.inputTuplet {
            note.tuplet = true
            note.tupletRatio = ratio == [3, 2] ? nil : ratio
        }
        let at = min(cursor, cur.notes.count)
        note.ottava = ottava(joining: at)
        editVoice("Add Note") { $0.notes.insert(note, at: at) }
        selected = nil
        lastEntered = at
        cursor = at + 1
        needsDisplay = true
        hear(at)
    }

    /// Delete on the TAB: the selected note's note on the current string (the whole note when it's the only one).
    func deleteFret() {
        guard let i = selected ?? lastEntered, cur.notes.indices.contains(i), !cur.notes[i].rest else { return deleteSelected() }
        let spots = cur.tab(i)
        guard let k = spots.firstIndex(where: { $0.string == tabString }) else { return NSSound.beep() }
        if spots.count <= 1 || (cur.notes[i].chord ?? []).isEmpty { return deleteSelected() }
        editVoice("Delete Fret") { s in
            var n = s.notes[i]
            var tones = n.chord ?? []
            if k == 0 {
                let t = tones.removeFirst()
                (n.step, n.octave, n.alter, n.tabString) = (t.step, t.octave, t.alter, t.tabString)
            } else if k - 1 < tones.count {
                tones.remove(at: k - 1)
            }
            n.chord = tones.isEmpty ? nil : tones
            s.notes[i] = n
        }
    }

    /// The string under a point on the TAB (the first staff's), if it's on the TAB.
    private func tabStringAt(_ p: NSPoint) -> Int? {
        guard fullScore.showTab == true, !isExport else { return nil }
        layoutNotes()
        return withStaff(0) {
            let n = score.stringCount
            for s in 0..<systemCount {
                let top = tabTop(s)
                if p.y >= top - tabGap * 0.5, p.y <= top + tabGap * (CGFloat(n - 1) + 0.5), p.x > space * 3.2 {
                    return n - 1 - max(0, min(n - 1, Int(((p.y - top) / tabGap).rounded())))
                }
            }
            return nil
        }
    }

    // MARK: Playing techniques

    /// A technique (GuitarMarks.kinds) on or off for the selected notes.
    func toggleTechnique(_ kind: String) {
        let targets = markTargets
        guard let first = targets.first, cur.notes.indices.contains(first) else { return NSSound.beep() }
        let on = !(cur.notes[first].guitar ?? GuitarMarks()).has(kind)
        let name = (GuitarMarks.kinds + GuitarMarks.strumKinds).first { $0.0 == kind }?.1 ?? "Technique"
        editVoice(name) { s in
            for i in targets where s.notes.indices.contains(i) && !s.notes[i].rest {
                var g = s.notes[i].guitar ?? GuitarMarks()
                if g.has(kind) != on { g.toggle(kind) }
                s.notes[i].guitar = g.isEmpty ? nil : g
                // A bass note's slash sits low; a strum's on the middle line.
                if kind.hasPrefix("strum"), s.notes[i].slash != nil {
                    let place = g.strum == "bass" ? s.bassSlashLine : s.middleLine
                    s.notes[i].step = place.step
                    s.notes[i].octave = place.octave
                }
            }
        }
        NotebookStore.shared.editor.scoreInputChanged += 1
    }

    /// Whether the selected note has a technique (for menus).
    func hasTechnique(_ kind: String) -> Bool {
        guard let i = target else { return false }
        return (cur.notes[i].guitar ?? GuitarMarks()).has(kind)
    }

    // MARK: Strumming patterns

    /// The patterns for the score's time signature.
    var strumPatterns: [StrumPattern] { StrumPattern.patterns(beats: score.beats, beatUnit: score.beatUnit) }

    /// The bars a pattern goes on: the selected ones, else the current bar.
    private var strumBars: [Int] {
        let line = cur
        if let r = selectedRange, r.count > 1 { return Array(Set(r.map { line.bar(of: $0) })).sorted() }
        return [currentBar]
    }

    /// Whether the current bar is strummed like this pattern (for menus).
    func strummedLike(_ pattern: StrumPattern) -> Bool {
        let line = cur
        let bar = currentBar
        guard line.measures.indices.contains(bar), !line.notes.isEmpty, line.measures[bar].contains(where: { line.notes[$0].slash != nil }),
              let here = line.strumCells(bar: bar), let cells = StrumPattern.cells(pattern.steps) else { return false }
        return StrumPattern.sixteenths(here, length: line.measureLength) == StrumPattern.sixteenths(cells, length: line.measureLength)
    }

    /// A strumming pattern ("D-DU-UDU") on the selected bars, the current bar, or every bar: rhythm slashes with
    /// their strokes, each bar's chord symbols kept where they were. A piano staff is given a guitar's sound.
    func applyStrum(_ pattern: String, everyBar: Bool = false) {
        let line = cur
        guard let cells = StrumPattern.cells(pattern), line.strumBar(cells, symbols: []) != nil else { return NSSound.beep() }
        let bars = everyBar ? Array(0..<(line.notes.isEmpty ? 1 : line.measures.count)) : strumBars
        StrumPattern.lastUsed = StrumPattern.text(cells)
        let v = voice, st = staffIndex
        let piano = fullScore.forStaff(st).sound == 0
        edit(everyBar ? "Strumming Pattern (Every Bar)" : "Strumming Pattern") { full in
            var view = full.shown(st).forVoice(v)
            view.applyStrum(cells, bars: bars)
            full.setShownLine(st, voice: v, view.notes)
            if piano {
                if st == 0 { full.program = 25 } else if full.staves?.indices.contains(st - 1) == true { full.staves?[st - 1].program = 25 }
            }
        }
        selected = nil
        rangeEnd = nil
        lastEntered = nil
        let after = cur
        if let last = bars.max(), !after.notes.isEmpty, after.measures.indices.contains(last) { cursor = after.measures[last].upperBound } else { cursor = after.notes.count }
        NotebookStore.shared.editor.scoreInputChanged += 1
    }

    /// The current bar's strumming, through every bar.
    func strumEveryBarLikeThis() {
        let line = cur
        let bar = currentBar
        guard line.measures.indices.contains(bar), !line.notes.isEmpty, line.measures[bar].contains(where: { line.notes[$0].slash != nil }),
              let cells = line.strumCells(bar: bar), cells.contains(where: \.isStroke) else { return NSSound.beep() }
        applyStrum(StrumPattern.text(cells), everyBar: true)
    }

    /// A rhythm guitar staff under the others, strummed in the pattern through as many bars as the first staff,
    /// following its chord symbols.
    func addRhythmStaff(_ pattern: String) {
        guard let cells = StrumPattern.cells(pattern) else { return NSSound.beep() }
        let full = fullScore
        let lead = full.forStaff(0)
        var rhythm = ScoreData()
        rhythm.beats = full.beats
        rhythm.beatUnit = full.beatUnit
        guard rhythm.applyStrum(cells, bars: Array(0..<(lead.notes.isEmpty ? 1 : lead.measures.count))) else { return NSSound.beep() }
        StrumPattern.lastUsed = StrumPattern.text(cells)
        let index = full.staffCount
        edit("Rhythm Guitar Staff") { f in
            f.staves = (f.staves ?? []) + [ScoreStaff(name: "Rhythm Guitar", clef: .treble, notes: rhythm.notes, program: 25)]
        }
        setStaff(index)
    }

    /// The chord a pattern is tried on: the one at the start of the current bar, else the first in the score.
    private var strumPreviewChord: String {
        let line = cur
        let bar = currentBar
        if !line.notes.isEmpty {
            let i = line.measures.indices.contains(bar) ? line.measures[bar].lowerBound : line.notes.count - 1
            if let symbol = line.chordSymbol(at: min(i, line.notes.count - 1)) { return symbol }
        }
        return fullScore.timedChords.first?.symbol ?? "C"
    }

    /// Plays a pattern twice on the current chord, at the score's tempo, with its sound, tuning, capo and swing.
    func previewStrum(_ pattern: String) {
        guard let cells = StrumPattern.cells(pattern) else { return NSSound.beep() }
        var s = fullScore
        s.staves = nil
        s.grandStaff = nil
        s.voices = nil
        s.notes = []
        s.barMarks = nil
        s.clef = .treble
        s.transpose = nil
        s.instrument = nil
        s.concertPitch = nil
        s.program = s.forStaff(staffIndex).sound == 0 ? 25 : s.forStaff(staffIndex).sound
        guard s.applyStrum(cells, bars: [0, 1]), !s.notes.isEmpty else { return NSSound.beep() }
        s.notes[0].chordSymbol = strumPreviewChord
        ScorePlayer.shared.play(s, fromBar: 0, offset: 0, in: nil)
    }

    /// The pattern editor: the steps on a grid, presets, a preview, and where it goes.
    func editStrumPattern(newStaff: Bool = false) {
        let line = cur
        let bar = currentBar
        let strummed = line.measures.indices.contains(bar) && !line.notes.isEmpty && line.measures[bar].contains(where: { line.notes[$0].slash != nil })
        let here = strummed ? line.strumCells(bar: bar).map { StrumPattern.text($0) } : nil
        let last = StrumPattern.lastUsed.flatMap { p in StrumPattern.cells(p).flatMap { line.strumBar($0, symbols: []) != nil ? p : nil } }
        let initial = here ?? last ?? strumPatterns.first?.steps ?? "D"
        let span = selectedRange.map { r in Set(r.map { line.bar(of: $0) }).count } ?? 1
        StrumPatternEditor.edit(patterns: strumPatterns, initial: initial, beats: line.beats, beatUnit: line.beatUnit,
                                barLabel: span > 1 ? "\(span) Bars" : "Bar \(bar + 1)", target: newStaff ? .newStaff : .bars, chord: strumPreviewChord,
                                play: { [weak self] p in self?.previewStrum(p) }, in: window) { [weak self] pattern, target in
            switch target {
            case .bars: self?.applyStrum(pattern)
            case .every: self?.applyStrum(pattern, everyBar: true)
            case .newStaff: self?.addRhythmStaff(pattern)
            }
        }
    }

    /// Swing eighths (long-short) on or off.
    func toggleSwing() {
        edit(fullScore.swing == true ? "Straight Eighths" : "Swing Eighths") { $0.swing = $0.swing == true ? nil : true }
        NotebookStore.shared.editor.scoreInputChanged += 1
    }

    /// Strums marked with arrows, or with ⊓ and V.
    func toggleStrumArrows() {
        edit("Strum Marks") { $0.strumArrows = $0.strumArrows == true ? nil : true }
        NotebookStore.shared.editor.scoreInputChanged += 1
    }

    // MARK: Chord diagrams

    /// The chord symbol at the selected note (its own, else the one in effect).
    var selectedChordSymbol: String? {
        guard let i = target else { return nil }
        return score.forVoice(0).notes.indices.contains(i) && voice == 0 ? score.chordSymbol(at: i) : nil
    }

    /// Voicings to choose from for a chord (the chosen one first).
    func voicings(_ symbol: String) -> [GuitarChords.Shape] {
        let full = fullScore
        let played = (full.capo ?? 0) > 0 ? GuitarChords.transposed(symbol, by: -(full.capo ?? 0)) : symbol
        guard let chord = GuitarChords.parse(played) else { return [] }
        var list = GuitarChords.voicings(chord, strings: full.openStrings, frets: min(15, full.maxFret))
        if let mine = full.chordShapes?[played], !list.contains(mine) { list.insert(mine, at: 0) }
        return list
    }

    /// The voicing for a chord, wherever it comes (nil: the handiest, again).
    func chooseVoicing(_ symbol: String, _ shape: GuitarChords.Shape?) {
        let full = fullScore
        let played = (full.capo ?? 0) > 0 ? GuitarChords.transposed(symbol, by: -(full.capo ?? 0)) : symbol
        edit(shape == nil ? "Automatic Voicing" : "Chord Voicing") { s in
            var all = s.chordShapes ?? [:]
            all[played] = shape
            s.chordShapes = all.isEmpty ? nil : all
            if s.chordDiagrams != true, s.chordChart != true { s.chordDiagrams = true }
        }
        strum(symbol)
    }

    /// Draw a chord's diagram by hand.
    func editDiagram(_ symbol: String) {
        guard let diagram = chordDiagram(symbol) else { return NSSound.beep() }
        ChordDiagramEditor.edit(name: diagram.name, shape: diagram.shape, strings: fullScore.openStrings, capo: fullScore.capo ?? 0,
                                program: fullScore.sound, in: window) { [weak self] result in
            switch result {
            case .cancel: break
            case .automatic: self?.chooseVoicing(symbol, nil)
            case .shape(let shape): self?.chooseVoicing(symbol, shape)
            }
        }
    }

    /// Plays a chord's diagram, low string to high.
    func strum(_ symbol: String) {
        guard let diagram = chordDiagram(symbol) else { return }
        let full = fullScore
        let pitches = diagram.shape.frets.enumerated().compactMap { s, f in f.map { full.openStrings[s] + $0 + (full.capo ?? 0) } }
        ScorePlayer.shared.strum(pitches, program: full.sound)
    }

    /// A chord symbol for the selected note, named from its notes (and voice 2's at the same time).
    func nameChord() {
        guard voice == 0, let i = target, !cur.notes[i].rest else { return NSSound.beep() }
        let line = score
        var pitches = line.midis(i)
        let onset = line.onsets[i]
        let second = line.forVoice(1)
        for (k, t) in second.onsets.enumerated() where abs(t - onset) < 1e-6 { pitches += second.midis(k) }
        guard let name = GuitarChords.name(pitches, flats: fullScore.keyFifths < 0) else { return NSSound.beep() }
        editVoice("Name Chord") { $0.notes[i].chordSymbol = name }
    }

    /// Chord symbols for every chord in voice 1 that hasn't one (three notes or more).
    func nameAllChords() {
        let line = score
        var names: [Int: String] = [:]
        for i in line.notes.indices where !line.notes[i].rest && (line.notes[i].chordSymbol ?? "").isEmpty {
            let pitches = line.midis(i)
            guard Set(pitches.map { $0 % 12 }).count >= 3, let name = GuitarChords.name(pitches, flats: fullScore.keyFifths < 0) else { continue }
            // The same chord again needs no new symbol.
            if let prev = line.notes[..<i].lastIndex(where: { !$0.rest }), (names[prev] ?? line.chordSymbol(at: prev)) == name { continue }
            names[i] = name
        }
        guard !names.isEmpty else { return NSSound.beep() }
        let v = voice
        if v != 0 { setVoice(0) }
        editVoice("Name Chords") { s in for (i, name) in names { s.notes[i].chordSymbol = name } }
    }

    // MARK: Lyrics and chord symbols (typed under / above the notes)

    enum WordKind { case lyric, chordSymbol, figures, numeral }
    private var field: NSTextField?
    private var fieldKind: WordKind = .lyric
    private var fieldIndex = 0

    /// ⌃L lyrics / ⌃K chord symbols, starting at the selected (or just-typed, or first) note.
    func beginWords(_ kind: WordKind) {
        // Lyrics, chord symbols, figures and numerals go with voice 1.
        if voice != 0 { setVoice(0) }
        guard !cur.notes.isEmpty else { return NSSound.beep() }
        var index = target ?? (cursor > 0 ? cursor - 1 : 0)
        if kind != .chordSymbol, cur.notes[index].rest, let next = nextNote(after: index, kind: kind) { index = next }
        openField(kind, at: index)
    }

    private func nextNote(after index: Int, kind: WordKind, backwards: Bool = false) -> Int? {
        var i = index + (backwards ? -1 : 1)
        while cur.notes.indices.contains(i) {
            // Lyrics, figures and numerals skip rests; chord symbols can go on any note or rest.
            if kind == .chordSymbol || !cur.notes[i].rest { return i }
            i += backwards ? -1 : 1
        }
        return nil
    }

    private func openField(_ kind: WordKind, at index: Int) {
        field?.removeFromSuperview()
        layoutNotes()
        guard let p = place(voice, index) else { return }
        fieldKind = kind
        fieldIndex = index
        selected = index
        lastEntered = nil
        cursor = index + 1
        let font = kind == .lyric ? Self.lyricFont : kind == .chordSymbol ? Self.chordFont : kind == .figures ? FiguredBass.font : RomanNumeral.smallFont.withSize(14)
        let text = words(kind, of: cur.notes[index]) ?? ""
        let f = NSTextField(string: text)
        f.font = font
        f.isBordered = true
        f.focusRingType = .none
        f.delegate = self
        f.alignment = kind == .lyric || kind == .figures ? .center : .left
        f.placeholderString = kind == .figures ? "6/4" : kind == .numeral ? "V7" : nil
        let width = max(space * 7, (text as NSString).size(withAttributes: [.font: font]).width + space * 3)
        let yTop: CGFloat
        switch kind {
        case .lyric: yTop = lyricY(p.system) - 2
        case .chordSymbol: yTop = staffTop(p.system) - space * 2.2 - max(chordBand, space * 2.4) + space * 0.2
        case .figures: yTop = figureTop(p.system) - 2
        case .numeral: yTop = numeralTop(p.system) - 2
        }
        let centred = kind == .lyric || kind == .figures
        f.frame = NSRect(x: centred ? p.x + space * 0.62 - width / 2 : p.x - space * 0.4, y: yTop, width: width, height: font.pointSize + 8)
        addSubview(f)
        field = f
        window?.makeFirstResponder(f)
        f.currentEditor()?.selectAll(nil)
        needsDisplay = true
    }

    /// Saves the field's words on its note.
    private func commitField() {
        guard let f = field else { return }
        let text = f.stringValue.trimmingCharacters(in: .whitespaces)
        let i = fieldIndex, kind = fieldKind
        guard cur.notes.indices.contains(i) else { return }
        guard (words(kind, of: cur.notes[i]) ?? "") != text else { return }
        let names: [WordKind: String] = [.lyric: "Lyrics", .chordSymbol: "Chord Symbol", .figures: "Figured Bass", .numeral: "Roman Numeral"]
        editVoice(names[kind] ?? "Words") { data in
            let value = text.isEmpty ? nil : text
            switch kind {
            case .lyric: data.notes[i].lyric = value
            case .chordSymbol: data.notes[i].chordSymbol = value
            case .figures: data.notes[i].figures = value
            case .numeral: data.notes[i].numeral = value
            }
        }
    }

    /// A note's words of a kind.
    private func words(_ kind: WordKind, of note: ScoreNote) -> String? {
        switch kind {
        case .lyric: note.lyric
        case .chordSymbol: note.chordSymbol
        case .figures: note.figures
        case .numeral: note.numeral
        }
    }

    func endWords() {
        commitField()
        field?.removeFromSuperview()
        field = nil
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    /// Space (or Tab) goes on to the next note; "-" ends a syllable (the word goes on under the next note).
    private func advance(backwards: Bool = false) {
        commitField()
        guard let next = nextNote(after: fieldIndex, kind: fieldKind, backwards: backwards) else { return endWords() }
        openField(fieldKind, at: next)
    }

    func controlTextDidChange(_ note: Notification) {
        guard let f = field else { return }
        let text = f.stringValue
        if text.hasSuffix(" ") {
            f.stringValue = String(text.dropLast())
            advance()
        } else if fieldKind == .lyric, text.hasSuffix("-"), text.count > 1 {
            advance()
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertTab(_:)): advance(); return true
        case #selector(NSResponder.insertBacktab(_:)): advance(backwards: true); return true
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.cancelOperation(_:)): endWords(); return true
        default: return false
        }
    }

    /// The words field (for self-tests and the ribbon).
    var wordsField: NSTextField? { field }

    func toggleRest() {
        changeSelected("Rest") { $0.rest.toggle() }
    }

    func deleteSelected() {
        if let i = selected {
            editVoice("Delete Note") { $0.notes.remove(at: i) }
            select(i > 0 ? i - 1 : nil)
            if selected == nil { cursor = 0 }
        } else if cursor > 0 {
            let i = cursor - 1
            editVoice("Delete Note") { $0.notes.remove(at: i) }
            cursor = i
            lastEntered = i > 0 ? i - 1 : nil
        } else {
            NSSound.beep()
        }
        needsDisplay = true
    }

    func moveCursor(by delta: Int) {
        lastEntered = nil
        if let s = selected {
            let next = s + delta
            if next < 0 { selected = nil; cursor = 0 } else if next >= cur.notes.count { selected = nil; cursor = cur.notes.count } else { select(next) }
        } else {
            let next = cursor + delta
            if delta < 0, cursor > 0 { select(cursor - 1) } else if delta > 0, cursor < cur.notes.count { select(cursor) } else { cursor = max(0, min(cur.notes.count, next)) }
        }
        needsDisplay = true
    }

    /// Write in voice 1 or 2 (⌥⌘1 / ⌥⌘2): the caret goes to the end of that voice.
    func setVoice(_ v: Int) {
        guard (0..<ScoreData.voiceCount).contains(v) else { return }
        voice = v
        selected = nil
        lastEntered = nil
        cursor = cur.notes.count
        NotebookStore.shared.editor.scoreInputChanged += 1
        needsDisplay = true
    }

    var currentVoice: Int { voice }

    /// Triplet (⌃3): the selected note becomes (or stops being) a triplet; otherwise the next notes are entered as triplets.
    func toggleTriplet() { toggleTuplet([3, 2]) }

    /// A tuplet ([actual, normal], e.g. [5, 4]): on the selected notes (the same again takes it off), else for the
    /// next notes entered.
    func toggleTuplet(_ ratio: [Int]) {
        let name = ScoreData.tupletKinds.first { $0.0 == ratio }?.1 ?? "Tuplet"
        if let range = selectedRange {
            let line = cur
            let allHave = range.allSatisfy { line.notes[$0].tupletActual == ratio[0] && line.notes[$0].tupletNormal == ratio[1] }
            editVoice(allHave ? "Remove \(name)" : name) { s in
                for i in range where s.notes[i].grace == nil {
                    s.notes[i].tuplet = allHave ? nil : true
                    s.notes[i].tupletRatio = allHave || ratio == [3, 2] ? nil : ratio
                }
            }
            Self.inputTuplet = allHave ? nil : ratio
        } else {
            Self.inputTuplet = Self.inputTuplet == ratio ? nil : ratio
        }
        NotebookStore.shared.editor.scoreInputChanged += 1
    }

    /// Notes entered from now on are plain (no tuplet).
    func clearTuplet() {
        if let range = selectedRange {
            editVoice("Remove Tuplet") { s in for i in range { s.notes[i].tuplet = nil; s.notes[i].tupletRatio = nil } }
        }
        Self.inputTuplet = nil
        NotebookStore.shared.editor.scoreInputChanged += 1
    }

    // MARK: Grace notes

    /// A grace note before the selected note (or the note after the cursor), at its pitch — move it with ↑ ↓.
    /// "acciaccatura" (/) is slashed and quick; "appoggiatura" (?) takes half the note's time.
    func insertGrace(_ kind: String) {
        let line = cur
        guard let at = selected ?? (cursor < line.notes.count ? cursor : nil), line.notes.indices.contains(at) else { return NSSound.beep() }
        let main = line.notes[at]
        var grace = ScoreNote(duration: kind == "appoggiatura" && main.duration.rawValue <= 4 ? .quarter : .eighth)
        grace.grace = kind
        if main.rest {
            grace.step = score.clef == .treble ? 6 : 1
            grace.octave = score.clef == .treble ? 4 : 3
        } else {
            grace.step = main.step
            grace.octave = main.octave
            grace.alter = main.alter
        }
        editVoice(kind == "appoggiatura" ? "Appoggiatura" : "Acciaccatura") { $0.notes.insert(grace, at: at) }
        select(at)
        hear(at)
    }

    /// Changes the selected grace note's kind, or makes the selected note a grace note (or a normal one again).
    func setGrace(_ kind: String?) {
        guard let i = selected, cur.notes.indices.contains(i) else { return NSSound.beep() }
        editVoice(kind == nil ? "Normal Note" : "Grace Note") { s in
            s.notes[i].grace = kind
            if kind != nil { s.notes[i].tuplet = nil; s.notes[i].tupletRatio = nil; s.notes[i].dotted = false }
        }
        NotebookStore.shared.editor.scoreInputChanged += 1
    }

    var graceHere: String? {
        guard let i = selected, cur.notes.indices.contains(i) else { return nil }
        return cur.notes[i].grace
    }

    // MARK: Dynamics, slurs and hairpins

    /// ⇧← ⇧→: selects more notes (from the selected one, or the one before the cursor).
    func extendSelection(by delta: Int) {
        guard !cur.notes.isEmpty else { return }
        if selected == nil { select(max(0, min(cur.notes.count - 1, cursor - (delta < 0 ? 1 : 0)))) ; if delta < 0 { return } }
        guard let anchor = selected else { return }
        let end = max(0, min(cur.notes.count - 1, (rangeEnd ?? anchor) + delta))
        rangeEnd = end == anchor ? nil : end
        needsDisplay = true
        NotebookStore.shared.editor.scoreInputChanged += 1
    }

    /// The notes a slur or hairpin joins: the selected run, or the note (selected or just typed) and the next.
    private var spanTarget: (Int, Int)? {
        if let r = selectedRange, r.count > 1 { return (r.lowerBound, r.upperBound) }
        guard let i = target else { return nil }
        if i + 1 < cur.notes.count { return (i, i + 1) }
        return i > 0 ? (i - 1, i) : nil
    }

    /// A dynamic (pp … ff, sfz, fp) under the selected note — nil takes it away.
    func setDynamic(_ dynamic: String?) {
        guard let i = selected ?? target else { return NSSound.beep() }
        editVoice(dynamic == nil ? "Remove Dynamic" : "Dynamic") { $0.notes[i].dynamic = dynamic }
        NotebookStore.shared.editor.scoreInputChanged += 1
    }

    var dynamicHere: String? {
        guard let i = selected ?? target, cur.notes.indices.contains(i) else { return nil }
        return cur.notes[i].dynamic
    }

    /// S: a slur over the selected notes (or to the next note); again takes it off.
    func toggleSlur() {
        guard let (a, b) = spanTarget else { return NSSound.beep() }
        editVoice("Slur") { s in
            let existing = s.slurs.first { $0.0 == a }
            if let existing {
                s.notes[existing.0].slurStart = nil
                s.notes[existing.1].slurEnd = nil
                if existing.1 == b { return }
            }
            // A slur inside or across this one goes.
            for (x, y) in s.slurs where (x >= a && x <= b) || (y >= a && y <= b) {
                s.notes[x].slurStart = nil
                s.notes[y].slurEnd = nil
            }
            s.notes[a].slurStart = true
            s.notes[b].slurEnd = true
        }
        NotebookStore.shared.editor.scoreInputChanged += 1
    }

    /// < crescendo / > diminuendo over the selected notes (or to the next note); the same again takes it off.
    func toggleHairpin(_ direction: Int) {
        guard let (a, b) = spanTarget else { return NSSound.beep() }
        editVoice(direction > 0 ? "Crescendo" : "Diminuendo") { s in
            let existing = s.hairpins.first { $0.0 == a }
            for (x, y, _) in s.hairpins where (x >= a && x <= b) || (y >= a && y <= b) {
                s.notes[x].hairpin = nil
                s.notes[y].hairpinEnd = nil
            }
            if let existing, existing.1 == b, existing.2 == direction { return }
            s.notes[a].hairpin = direction
            s.notes[b].hairpinEnd = true
        }
        NotebookStore.shared.editor.scoreInputChanged += 1
    }

    var slurHere: Bool { spanTarget.map { t in cur.slurs.contains { $0.0 == t.0 } } ?? false }
    var hairpinHere: Int? { spanTarget.flatMap { t in cur.hairpins.first { $0.0 == t.0 }?.2 } }

    // MARK: Articulations and ornaments

    // MARK: Lead sheets and slash notation

    /// Slash Entry: letters type rhythmic slashes (on and off).
    func toggleSlashEntry() {
        Self.inputSlash.toggle()
        NotebookStore.shared.editor.scoreInputChanged += 1
    }

    /// The selected notes as slashes — "rhythm" (with stems) or "beat" (without) — or back to notes (nil).
    func setSlash(_ style: String?) {
        let notes = markTargets
        guard !notes.isEmpty else { return NSSound.beep() }
        let middle = cur.middleLine
        editVoice(style == nil ? "Slashes to Notes" : style == "beat" ? "Beat Slashes" : "Rhythmic Slashes") { s in
            for i in notes where !s.notes[i].rest && s.notes[i].grace == nil {
                s.notes[i].slash = style
                if style != nil {
                    s.notes[i].step = middle.step
                    s.notes[i].octave = middle.octave
                    s.notes[i].alter = nil
                    s.notes[i].chord = nil
                    s.notes[i].drum = nil
                }
            }
        }
        NotebookStore.shared.editor.scoreInputChanged += 1
    }

    /// Fill with Slashes: the bar (or the bars selected) as one beat slash per beat — a chord chart — keeping the
    /// chord symbols on the beats where they were.
    func fillWithSlashes() {
        let line = cur
        var bars: [Int] = []
        if let r = selectedRange, r.count > 1 { bars = Array(Set(r.map { line.bar(of: $0) })).sorted() } else { bars = [currentBar] }
        let compound = line.beatUnit == 8 && line.beats % 3 == 0
        let beat: (length: Double, duration: ScoreNote.Duration, dotted: Bool) =
            compound ? (1.5, .quarter, true) : line.beatUnit == 2 ? (2, .half, false) : line.beatUnit == 8 ? (0.5, .eighth, false) : (1, .quarter, false)
        let middle = line.middleLine
        editVoice("Fill with Slashes") { s in
            let measures = s.notes.isEmpty ? [] : s.measures
            for b in bars.sorted(by: >) {
                var symbols: [(Double, String)] = []
                if measures.indices.contains(b) {
                    var t = 0.0
                    for i in measures[b] {
                        if let c = s.notes[i].chordSymbol, !c.isEmpty { symbols.append((t, c)) }
                        t += s.notes[i].beats
                    }
                }
                let count = max(1, Int((s.measureLength / beat.length).rounded()))
                var slashes: [ScoreNote] = []
                for k in 0..<count {
                    var n = ScoreNote(duration: beat.duration, dotted: beat.dotted)
                    n.slash = "beat"
                    n.step = middle.step
                    n.octave = middle.octave
                    let onset = Double(k) * beat.length
                    n.chordSymbol = symbols.first { $0.0 >= onset - 1e-6 && $0.0 < onset + beat.length - 1e-6 }?.1
                    slashes.append(n)
                }
                if measures.indices.contains(b) { s.notes.replaceSubrange(measures[b], with: slashes) } else { s.notes += slashes }
            }
        }
        selected = nil
        cursor = cur.notes.count
        NotebookStore.shared.editor.scoreInputChanged += 1
    }

    /// So many bars on each line (nil: as many as fit).
    func setBarsPerLine(_ n: Int?) {
        edit("Bars per Line") { $0.barsPerLine = n }
        NotebookStore.shared.editor.scoreInputChanged += 1
    }

    /// A 1st (2nd, 3rd) ending over the current bar — the same again takes it off.
    func toggleEnding(_ number: Int) {
        let bar = currentBar
        edit("\(number == 1 ? "1st" : number == 2 ? "2nd" : "\(number)rd") Ending") { s in
            s.setMark(bar) { $0.ending = $0.ending == number ? nil : number }
        }
        NotebookStore.shared.editor.scoreInputChanged += 1
    }

    var endingHere: Int? { score.mark(currentBar).ending }

    /// The composer (or arranger, lyricist…) shown under the title.
    func editComposer() {
        let alert = NSAlert()
        alert.messageText = "Composer"
        alert.informativeText = "Shown under the title at the right — composer, arranger, \"Words and music by…\"."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = fullScore.composer ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespaces)
        edit("Composer") { $0.composer = text.isEmpty ? nil : text }
    }

    /// The notes marks go on: the selected run, else the selected note (or the one just typed).
    private var markTargets: [Int] {
        if let r = selectedRange { return Array(r) }
        return target.map { [$0] } ?? []
    }

    // MARK: Ottavas and cross-staff notes

    /// The ottava a note put in at `index` joins: the one it's in the middle of.
    private func ottava(joining index: Int) -> Int? {
        let line = cur.notes
        guard index > 0, index < line.count, let o = line[index - 1].ottava, line[index].ottava == o else { return nil }
        return o
    }

    /// The ottava over the selected notes (nil when they differ).
    var ottavaHere: Int? {
        let values = Set(markTargets.compactMap { cur.notes.indices.contains($0) ? cur.notes[$0].ottava : nil })
        return values.count == 1 ? values.first : nil
    }

    /// 8va (1), 15ma (2), 8vb (−1) or 15mb (−2) over the selected notes, or none (nil): they sound where they are,
    /// and are drawn an octave (two) nearer the staff under the line.
    func setOttava(_ value: Int?) {
        let notes = markTargets
        guard !notes.isEmpty, cur.clef != .percussion else { return NSSound.beep() }
        let name = value.map { ["15mb", "8vb", "", "8va", "15ma"][$0 + 2] } ?? "Remove Ottava"
        editVoice(name) { s in for i in notes where s.notes.indices.contains(i) { s.notes[i].ottava = value == 0 ? nil : value } }
        NotebookStore.shared.editor.scoreInputChanged += 1
    }

    /// Whether the selected notes can go across to the staff above (−1) or below (1).
    func canMoveToStaff(_ delta: Int) -> Bool {
        let t = staffIndex + delta
        return (0..<fullScore.staffCount).contains(t) && fullScore.forStaff(t).clef != .percussion && cur.clef != .percussion
    }

    /// Cross-staff: the selected notes drawn on the staff below (1) or above (−1) — they still belong, beam and play
    /// with their own staff. Moving them back the other way puts them home; 0 puts them home at once.
    func moveToStaff(_ delta: Int) {
        let notes = markTargets.filter { cur.notes.indices.contains($0) && !cur.notes[$0].rest }
        guard !notes.isEmpty else { return NSSound.beep() }
        if delta != 0 {
            let now = cur.notes[notes[0]].crossStaff ?? 0
            let next = max(-1, min(1, now + delta))
            guard next == 0 || canMoveToStaff(next) else { return NSSound.beep() }
            editVoice(next == 0 ? "Back to Own Staff" : next > 0 ? "Cross to Staff Below" : "Cross to Staff Above") { s in
                for i in notes { s.notes[i].crossStaff = next == 0 ? nil : next }
            }
        } else {
            editVoice("Back to Own Staff") { s in for i in notes { s.notes[i].crossStaff = nil } }
        }
        NotebookStore.shared.editor.scoreInputChanged += 1
    }

    /// Where the selected note is drawn: its own staff (0), or across below (1) or above (−1).
    var crossStaffHere: Int { target.flatMap { cur.notes.indices.contains($0) ? cur.notes[$0].crossStaff : nil } ?? 0 }

    /// Adds an articulation to the notes (or takes it off when they all have it). Staccato and staccatissimo
    /// replace each other, as do accent and marcato.
    func toggleArticulation(_ mark: String) {
        let notes = markTargets
        guard !notes.isEmpty else { return NSSound.beep() }
        let name = ScoreData.articulationKinds.first { $0.0 == mark }?.1 ?? "Articulation"
        let allHave = notes.allSatisfy { (cur.notes[$0].articulations ?? []).contains(mark) }
        let rivals: [String: String] = ["staccato": "staccatissimo", "staccatissimo": "staccato", "accent": "marcato", "marcato": "accent"]
        editVoice(name) { s in
            for i in notes {
                var list = (s.notes[i].articulations ?? []).filter { $0 != mark && $0 != rivals[mark] }
                if !allHave { list.append(mark) }
                s.notes[i].articulations = list.isEmpty ? nil : list
            }
        }
        NotebookStore.shared.editor.scoreInputChanged += 1
    }

    /// Sets an ornament on the notes (the same again takes it off).
    func toggleOrnament(_ ornament: String) {
        let notes = markTargets
        guard !notes.isEmpty else { return NSSound.beep() }
        let allHave = notes.allSatisfy { cur.notes[$0].ornament == ornament }
        editVoice(ScoreData.ornamentKinds.first { $0.0 == ornament }?.1 ?? "Ornament") { s in
            for i in notes { s.notes[i].ornament = allHave ? nil : ornament }
        }
        NotebookStore.shared.editor.scoreInputChanged += 1
    }

    func toggleFermata() {
        let notes = markTargets
        guard !notes.isEmpty else { return NSSound.beep() }
        let allHave = notes.allSatisfy { cur.notes[$0].fermata == true }
        editVoice("Fermata") { s in for i in notes { s.notes[i].fermata = allHave ? nil : true } }
        NotebookStore.shared.editor.scoreInputChanged += 1
    }

    /// Clears articulations, ornaments and fermatas from the notes.
    func clearMarks() {
        let notes = markTargets
        guard !notes.isEmpty else { return NSSound.beep() }
        editVoice("Clear Articulations") { s in
            for i in notes { s.notes[i].articulations = nil; s.notes[i].ornament = nil; s.notes[i].fermata = nil }
        }
        NotebookStore.shared.editor.scoreInputChanged += 1
    }

    /// Whether the selected note has a mark (for checkmarks in menus and the ribbon).
    func hasMark(_ mark: String) -> Bool {
        guard let i = markTargets.first, cur.notes.indices.contains(i) else { return false }
        let note = cur.notes[i]
        return (note.articulations ?? []).contains(mark) || note.ornament == mark || (mark == "fermata" && note.fermata == true)
    }

    // MARK: Tempo changes

    /// A tempo from the current bar on: a speed (quarter notes a minute), a word, and the note the mark counts in.
    /// In the first bar it's the score's tempo.
    func setTempo(_ bpm: Int?, text: String? = nil, unit: String? = nil, name: String = "Tempo") {
        let bar = currentBar
        edit(name) { s in
            if bar == 0, let bpm { s.tempo = max(20, min(400, bpm)) }
            s.setMark(bar) { m in
                if bar > 0 { m.tempo = bpm.map { max(20, min(400, $0)) } }
                if let text { m.tempoText = text.isEmpty ? nil : text }
                if let unit { m.tempoUnit = unit == "quarter" ? nil : unit }
            }
        }
        NotebookStore.shared.editor.scoreInputChanged += 1
    }

    /// A tempo word with its usual speed (Allegro: 132).
    func setTempoTerm(_ term: String, _ bpm: Int) { setTempo(bpm, text: term) }

    /// rit. (-1) or accel. (1) from the current bar to the next tempo change; the same again takes it off.
    func toggleGradual(_ direction: Int) {
        let bar = currentBar
        edit(direction < 0 ? "Ritardando" : "Accelerando") { s in
            s.setMark(bar) { $0.gradual = $0.gradual == direction ? nil : direction }
        }
        NotebookStore.shared.editor.scoreInputChanged += 1
    }

    /// a tempo: back to the speed before the last rit. or accel.
    func aTempo() {
        let bar = currentBar
        let before = (score.barMarks ?? [:]).filter { $0.key < bar && $0.value.gradual != nil }.max { $0.key < $1.key }
            .map { score.tempo(inBar: $0.key) } ?? score.tempo(inBar: max(0, bar - 1))
        setTempo(before, text: "a tempo", name: "A Tempo")
    }

    /// Takes the tempo change (and rit. / accel.) off the current bar.
    func removeTempoChange() {
        let bar = currentBar
        edit("Remove Tempo Change") { s in
            s.setMark(bar) { $0.tempo = nil; $0.tempoText = nil; $0.tempoUnit = nil; $0.gradual = nil }
        }
        NotebookStore.shared.editor.scoreInputChanged += 1
    }

    var tempoHere: ScoreBarMark { score.mark(currentBar) }
    var tempoNumberHere: Int { currentBar == 0 ? score.tempo : (score.mark(currentBar).tempo ?? score.tempo(inBar: currentBar)) }

    /// Metronome Mark…: the speed, the note it counts in, and a word, for the current bar.
    func editMetronomeMark() {
        let bar = currentBar
        let mark = score.mark(bar)
        let alert = NSAlert()
        alert.messageText = bar == 0 ? "Metronome Mark" : "Tempo from Bar \(bar + 1)"
        alert.informativeText = "The speed, the note the metronome counts in, and a word for the tempo (optional)."
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let unitPopup = NSPopUpButton(frame: NSRect(x: 0, y: 58, width: 120, height: 26))
        for u in ScoreData.tempoUnits { unitPopup.addItem(withTitle: u.2 + "  " + (u.0 == "dotted" ? "dotted quarter" : u.0)) }
        let unitIndex = ScoreData.tempoUnits.firstIndex { $0.0 == (mark.tempoUnit ?? "quarter") } ?? 0
        unitPopup.selectItem(at: unitIndex)
        let equals = NSTextField(labelWithString: "=")
        equals.frame = NSRect(x: 126, y: 62, width: 14, height: 18)
        let number = NSTextField(frame: NSRect(x: 144, y: 60, width: 70, height: 22))
        number.integerValue = Int((Double(tempoNumberHere) / ScoreData.tempoUnits[unitIndex].1).rounded())
        let wordLabel = NSTextField(labelWithString: "Word:")
        wordLabel.frame = NSRect(x: 0, y: 24, width: 50, height: 18)
        let word = NSComboBox(frame: NSRect(x: 52, y: 20, width: 200, height: 26))
        word.addItems(withObjectValues: ScoreData.tempoTerms.map(\.0) + ["a tempo", "Tempo I", "Grave", "Lento", "Allegro moderato", "Allegro ma non troppo"])
        word.stringValue = mark.tempoText ?? ""
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 88))
        [unitPopup, equals, number, wordLabel, word].forEach { box.addSubview($0) }
        alert.accessoryView = box
        alert.window.initialFirstResponder = number
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let unit = ScoreData.tempoUnits[max(0, unitPopup.indexOfSelectedItem)]
        let bpm = Int((Double(max(5, number.integerValue)) * unit.1).rounded())
        setTempo(bpm, text: word.stringValue.trimmingCharacters(in: .whitespaces), unit: unit.0, name: "Metronome Mark")
    }

    // MARK: Key changes and repeats

    /// The bar commands act on: the selected note's (or the cursor's); after a full last bar, the next one.
    var currentBar: Int {
        let line = cur
        if let i = selected ?? (cursor < line.notes.count ? cursor : nil) { return line.bar(of: i) }
        guard let lastBar = line.measures.last, !line.notes.isEmpty else { return 0 }
        let filled = lastBar.reduce(0) { $0 + line.notes[$1].beats }
        return line.measures.count - (filled >= line.measureLength - 1e-9 ? 0 : 1)
    }

    /// The key a key change here sets (nil: none here).
    var keyChangeHere: Int? {
        let bar = currentBar
        return bar == 0 ? score.keyFifths : score.mark(bar).keyFifths
    }

    /// A new key from the current bar on (nil: takes the key change away). In the first bar it's the score's key.
    func setKeyChange(_ fifths: Int?) {
        let bar = currentBar
        let before = bar > 0 ? score.fifths(inBar: bar - 1) : 0
        let key = fifths.map(concertKey)
        edit(bar == 0 ? "Key Signature" : "Key Change") { s in
            if bar == 0 {
                s.keyFifths = key ?? 0
            } else {
                s.setMark(bar) { $0.keyFifths = fifths == before ? nil : key }
            }
        }
        NotebookStore.shared.editor.scoreInputChanged += 1
    }

    /// |: — repeat from the current bar.
    func toggleRepeatStart() {
        let bar = currentBar
        edit("Start Repeat") { $0.setMark(bar) { $0.repeatStart = $0.repeatStart == true ? nil : true } }
        NotebookStore.shared.editor.scoreInputChanged += 1
    }

    /// :| — back to the start repeat (or the beginning) at the end of the current bar.
    func toggleRepeatEnd() {
        let bar = currentBar
        edit("End Repeat") { $0.setMark(bar) { $0.repeatEnd = $0.repeatEnd == true ? nil : true } }
        NotebookStore.shared.editor.scoreInputChanged += 1
    }

    func togglePlay() {
        if ScorePlayer.shared.isPlaying {
            ScorePlayer.shared.stop()
        } else {
            // From the selected note (or the cursor) in the voice being written; every voice plays.
            let line = cur
            let from = selected ?? (cursor < line.notes.count ? cursor : 0)
            guard line.notes.indices.contains(from) else { return ScorePlayer.shared.play(fullScore, fromBar: 0, offset: 0, in: self) }
            let bar = line.bar(of: from)
            let onsets = line.onsets
            let barStart = line.measures.indices.contains(bar) ? line.measures[bar].lowerBound : from
            ScorePlayer.shared.play(fullScore, fromBar: bar, offset: onsets[from] - onsets[barStart], in: self)
        }
    }

    override func keyDown(with event: NSEvent) {
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let command = event.modifierFlags.contains(.command)
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        // Typing frets into the TAB: ↑ ↓ change string, digits are frets, ⇧3–⇧7 lengths, Esc stops.
        if tabInput {
            let digitKeys: [UInt16: Int] = [29: 0, 18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9]
            if flags.isEmpty, event.keyCode == 126 { return moveTabString(by: 1) }
            if flags.isEmpty, event.keyCode == 125 { return moveTabString(by: -1) }
            if flags.isEmpty, event.keyCode == 53 { return setTabInput(false) }
            if flags.isEmpty, event.keyCode == 51 || event.keyCode == 117 { return deleteFret() }
            if let d = digitKeys[event.keyCode] {
                if flags.isEmpty { return typeFret(d) }
                if flags == .shift, let length = [3: ScoreNote.Duration.sixteenth, 4: .eighth, 5: .quarter, 6: .half, 7: .whole][d] { return setDuration(length) }
            }
        }
        if flags == .control, chars == "t" { return setTabInput(!tabInput) }
        // ⌥ with a letter: a playing technique (⌥H hammer-on / pull-off, ⌥S slide, ⌥B bend, ⌥V vibrato, ⌥M palm mute…).
        if flags == .option, cur.clef != .percussion, let letter = chars.first, letter.isLetter,
           let kind = (GuitarMarks.kinds + GuitarMarks.strumKinds).first(where: { $0.2.lowercased() == String(letter) }) {
            return toggleTechnique(kind.0)
        }
        switch event.keyCode {
        case 123 where event.modifierFlags.contains(.shift): return extendSelection(by: -1)
        case 124 where event.modifierFlags.contains(.shift): return extendSelection(by: 1)
        case 123: return moveCursor(by: -1)
        case 124: return moveCursor(by: 1)
        case 126 where event.modifierFlags.contains([.option, .command]): return setStaff(staffIndex - 1)
        case 125 where event.modifierFlags.contains([.option, .command]): return setStaff(staffIndex + 1)
        // ⇧⌘↑ / ⇧⌘↓: the selected notes onto the staff above or below (cross-staff), as in MuseScore.
        case 126 where event.modifierFlags.contains([.shift, .command]): return moveToStaff(-1)
        case 125 where event.modifierFlags.contains([.shift, .command]): return moveToStaff(1)
        case 126 where event.modifierFlags.contains(.option): return moveString(by: 1)
        case 125 where event.modifierFlags.contains(.option): return moveString(by: -1)
        case 126: return moveSelected(steps: command ? 7 : 1)
        case 125: return moveSelected(steps: command ? -7 : -1)
        case 51, 117: return deleteSelected()
        case 49: return togglePlay()
        case 53:
            ScorePlayer.shared.stop()
            selected = nil
            ScoreView.active = nil
            window?.makeFirstResponder(owner?.canvas)
            owner.map { $0.canvas?.selectedElement = $0 }
            return
        default: break
        }
        if event.modifierFlags.contains([.option, .command]) {
            switch event.keyCode {
            case 18: return setVoice(0)   // 1
            case 19: return setVoice(1)   // 2
            default: break
            }
        }
        if event.modifierFlags.contains(.control) {
            switch chars {
            case "k": return beginWords(.chordSymbol)
            case "l": return beginWords(.lyric)
            case "f": return beginWords(.figures)
            case "r": return beginWords(.numeral)
            case "2", "3", "4", "5", "6", "7", "9":
                if let kind = ScoreData.tupletKinds.first(where: { "\($0.0[0])" == chars }) { return toggleTuplet(kind.0) }
                return super.keyDown(with: event)
            default: return super.keyDown(with: event)
            }
        }
        guard !command else { return super.keyDown(with: event) }
        // On a drum staff the letters are drums (⇧ adds the drum to the note).
        if cur.clef == .percussion, let letter = chars.first, letter.isLetter, !command {
            guard let drum = DrumKit.instrument(key: letter) else { NSSound.beep(); return }
            return event.modifierFlags.contains(.shift) ? addDrumToChord(drum) : insertDrum(drum)
        }
        // ⇧S staccato, ⇧N tenuto, ⇧V accent, ⇧O marcato, ⇧H fermata (as in MuseScore).
        if event.modifierFlags.contains(.shift) {
            switch chars {
            case "s": return toggleArticulation("staccato")
            case "n": return toggleArticulation("tenuto")
            case "v": return toggleArticulation("accent")
            case "o": return toggleArticulation("marcato")
            case "h": return toggleFermata()
            default: break
            }
        }
        if let letter = chars.first, let step = ["c", "d", "e", "f", "g", "a", "b"].firstIndex(of: String(letter)) {
            // ⇧ adds the note to the chord.
            return event.modifierFlags.contains(.shift) ? addChordTone(step: step) : insert(step: step)
        }
        switch chars {
        case "0": insert(step: nil)
        case "3": setDuration(.sixteenth)
        case "4": setDuration(.eighth)
        case "5": setDuration(.quarter)
        case "6": setDuration(.half)
        case "7": setDuration(.whole)
        case ".": toggleDot()
        case "+", "#": setAccidental(1)
        case "-": setAccidental(-1)
        case "=": setAccidental(0)
        case "t": toggleTie()
        case "r": toggleRest()
        case "s": toggleSlur()
        case "/": insertGrace("acciaccatura")
        case "?": insertGrace("appoggiatura")
        case "<": toggleHairpin(1)
        case ">": toggleHairpin(-1)
        default: super.keyDown(with: event)
        }
    }

    // MARK: Mouse

    /// The note under a point (for Quick Help).
    func noteRef(at p: NSPoint) -> NoteRef? { note(at: p) }

    /// The note (head or rest) under a point.
    private func note(at p: NSPoint) -> NoteRef? {
        if let hit = fretSpots.first(where: { $0.rect.contains(p) }) { return hit.ref }
        layoutNotes()
        // The staff and voice being written first (where notes overlap).
        let order = [staffIndex] + (0..<fullScore.staffCount).filter { $0 != staffIndex }
        for st in order {
            let found: NoteRef? = withStaff(st) {
                let ordered = placed.filter { $0.voice == voice || st != staffIndex } + placed.filter { $0.voice != voice && st == staffIndex }
                return ordered.first { pl in
                    let note = score.forVoice(pl.voice).notes[pl.index]
                    let cy = note.rest ? staffTop(pl.system) + space * 2 : y(position: position(note), system: pl.system, of: note)
                    return NSRect(x: pl.x - space * 0.4, y: cy - space * 1.2, width: space * 2.2, height: space * 2.4).contains(p)
                }.map { NoteRef(voice: $0.voice, index: $0.index, staff: st) }
            }
            if let found { return found }
        }
        return nil
    }

    private func system(at y: CGFloat) -> Int {
        let base = titleHeight
        return max(0, min(systemCount - 1, Int((y - base) / max(1, systemHeight))))
    }

    /// The staff nearest a point (the one whose lines it's between, or closest to).
    private func staffAt(_ p: NSPoint) -> Int {
        let sys = system(at: p.y)
        var best = 0, distance = CGFloat.greatestFiniteMagnitude
        for st in 0..<fullScore.staffCount {
            let top = withStaff(st) { staffTop(sys) }
            let d = p.y < top ? top - p.y : p.y > top + space * 4 ? p.y - top - space * 4 : 0
            if d < distance { distance = d; best = st }
        }
        return best
    }

    /// The cursor position nearest a point.
    private func gap(at p: NSPoint) -> Int {
        let s = system(at: p.y)
        var best = caretSpots.count - 1, distance = CGFloat.greatestFiniteMagnitude
        for (i, spot) in caretSpots.enumerated() where spot.system == s && abs(spot.x - p.x) < distance {
            distance = abs(spot.x - p.x)
            best = i
        }
        return best
    }

    override func mouseDown(with event: NSEvent) {
        guard !isExport else { return }
        if field != nil { endWords() }
        owner?.canvas?.selectedElement = nil
        activate()
        let p = convert(event.locationInWindow, from: nil)
        // A chord diagram: play it.
        if let d = diagramSpots.first(where: { $0.rect.contains(p) }) {
            strum(d.symbol)
            if let ref = d.ref { if ref.staff != staffIndex { setStaff(ref.staff) }; if ref.voice != voice { setVoice(ref.voice) }; select(ref.index) }
            return
        }
        // A click on the TAB: type frets onto the string there (on the fret clicked, or where the caret goes).
        if let string = tabStringAt(p) {
            if staffIndex != 0 { setStaff(0); layoutNotes() }
            tabString = string
            if let hit = fretSpots.first(where: { $0.rect.contains(p) }) {
                if hit.ref.voice != voice { setVoice(hit.ref.voice) }
                select(hit.ref.index)
                hear(hit.ref.index)
            } else {
                selected = nil
                cursor = gap(at: p)
            }
            setTabInput(true)
            return
        }
        // A click on (or near) another staff writes there.
        if let ref = note(at: p), ref.staff != staffIndex {
            setStaff(ref.staff)
            layoutNotes()
        } else if note(at: p) == nil, staffAt(p) != staffIndex {
            setStaff(staffAt(p))
            layoutNotes()
        }
        if event.clickCount == 2, note(at: p) == nil {
            // Double-click on the staff: a note at that pitch.
            let s = system(at: p.y)
            let pos = Int(((staffTop(s) + space * 4 - p.y) / (space / 2)).rounded())
            cursor = gap(at: p)
            // Under an ottava the note sounds an octave (two) from where it's drawn.
            let d = max(0, min(9 * 7, score.clef.bottomLine + pos + (ottava(joining: cursor) ?? 0) * 7))
            selected = nil
            insert(step: d % 7, octave: d / 7)
            return
        }
        if let ref = note(at: p) {
            // ⇧-click: from the selected note to this one (for a slur or a hairpin).
            if event.modifierFlags.contains(.shift), ref.voice == voice, let anchor = selected {
                rangeEnd = ref.index == anchor ? nil : ref.index
                needsDisplay = true
                NotebookStore.shared.editor.scoreInputChanged += 1
                return
            }
            if ref.voice != voice { setVoice(ref.voice) }
            let i = ref.index
            select(i)
            hear(i)
            // Drag up or down to change the pitch.
            guard !cur.notes[i].rest, let window else { return }
            let startY = p.y
            var applied = 0
            window.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: NSEvent.foreverDuration, mode: .eventTracking) { ev, stop in
                guard let ev, ev.type == .leftMouseDragged else {
                    stop.pointee = true
                    return
                }
                let y = self.convert(ev.locationInWindow, from: nil).y
                let steps = Int(((startY - y) / (self.space / 2)).rounded())
                if steps != applied {
                    self.moveSelected(steps: steps - applied)
                    applied = steps
                }
            }
        } else {
            selected = nil
            cursor = gap(at: p)
            needsDisplay = true
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        // Bar commands (key change, repeats) act where the right-click was.
        if !isExport {
            let p = convert(event.locationInWindow, from: nil)
            let st = note(at: p)?.staff ?? staffAt(p)
            if st != staffIndex { setStaff(st); layoutNotes() }
            if let ref = note(at: p) {
                if ref.voice != voice { setVoice(ref.voice) }
                select(ref.index)
            } else if !placed.isEmpty {
                selected = nil
                cursor = gap(at: p)
                needsDisplay = true
            }
        }
        return owner?.contextMenu()
    }
}

// MARK: - Container

final class ScoreElementView: ElementView {
    private(set) var score: ScoreData { didSet { revision &+= 1 } }
    /// Counts changes to the score (the staff view keeps what it works out until the next one).
    private(set) var revision = 0
    let staff = ScoreView()

    override init(element: PageElement) {
        score = element.score ?? ScoreData()
        super.init(element: element)
        staff.owner = self
        addSubview(staff)
        finishSetup()
        setWidth(frame.width)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var minWidth: CGFloat { 220 }

    override func setWidth(_ width: CGFloat) {
        let w = max(minWidth, width)
        staff.frame = NSRect(x: 0, y: Self.gripHeight, width: w, height: max(staff.frame.height, 10))
        let height = staff.neededHeight()
        setFrameSize(NSSize(width: w, height: Self.gripHeight + height))
    }

    override func layoutContent() {
        staff.frame = contentFrame
    }

    override func prepareForExport() {
        super.prepareForExport()
        staff.isExport = true
    }

    override func makeElement() -> PageElement {
        var e = super.makeElement()
        e.score = score
        return e
    }

    override func indexText() -> String? { score.title.isEmpty ? nil : score.title }

    /// Changes the score (one undo step), and fits the container to it.
    func update(_ change: (inout ScoreData) -> Void, actionName: String) {
        let old = score
        change(&score)
        guard score != old else { return }
        refit()
        controller?.markDirty()
        controller?.undoManager?.registerUndo(withTarget: self) { view in
            view.update({ $0 = old }, actionName: actionName)
            view.staff.select(nil)
        }
        controller?.undoManager?.setActionName(actionName)
    }

    private func refit() {
        let height = staff.neededHeight()
        if abs(frame.height - (Self.gripHeight + height)) > 0.5 {
            let old = frame.height
            setFrameSize(NSSize(width: frame.width, height: Self.gripHeight + height))
            heightChanged(from: old)
            canvas?.updateSize()
        }
        staff.needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // A new width can change the number of lines.
        if abs(staff.frame.width - newSize.width) > 0.5 {
            staff.frame.size.width = newSize.width
            let height = staff.neededHeight()
            if abs(newSize.height - (Self.gripHeight + height)) > 0.5 {
                DispatchQueue.main.async { [weak self] in self?.refit() }
            }
        }
    }

    /// Guitar: TAB, tuning, capo, chord diagrams and voicings, techniques, sound.
    private func guitarMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Guitar", action: nil, keyEquivalent: "")
        let m = NSMenu()
        let s = score
        m.addItem(ClosureMenuItem("Guitar Tab", state: s.showTab == true) { [weak self] in self?.staff.toggleTab() })
        m.addItem(ClosureMenuItem("TAB Only", state: s.tabOnly == true) { [weak self] in self?.staff.toggleTabOnly() })
        m.addItem(ClosureMenuItem("Type Frets in the TAB  ⌃T", state: staff.tabInput) { [weak self] in guard let self else { return }; self.staff.setTabInput(!self.staff.tabInput) })
        let tuning = NSMenuItem(title: "Tuning (\(TabInstrument.letters(s.openStrings)))", action: nil, keyEquivalent: "")
        let tunings = NSMenu()
        for family in ["Guitar", "Bass", "Other"] {
            for t in TabInstrument.all where t.family == family {
                tunings.addItem(ClosureMenuItem(t.name, state: s.tabTuning == nil && s.fretted.id == t.id) { [weak self] in self?.staff.setTuning(t.id) })
            }
            tunings.addItem(.separator())
        }
        tunings.addItem(ClosureMenuItem("Other Tuning…", state: s.tabTuning != nil) { [weak self] in self?.staff.editTuning() })
        tuning.submenu = tunings
        m.addItem(tuning)
        let capo = NSMenuItem(title: s.capo.map { "Capo (fret \($0))" } ?? "Capo", action: nil, keyEquivalent: "")
        let capos = NSMenu()
        capos.addItem(ClosureMenuItem("No Capo", state: s.capo == nil) { [weak self] in self?.staff.setCapo(0) })
        capos.addItem(.separator())
        for fret in 1...9 {
            capos.addItem(ClosureMenuItem("Capo \(fret)", state: s.capo == fret) { [weak self] in self?.staff.setCapo(fret) })
        }
        capo.submenu = capos
        m.addItem(capo)
        m.addItem(.separator())
        m.addItem(ClosureMenuItem("Chord Diagrams", state: s.chordDiagrams == true) { [weak self] in self?.staff.toggleChordDiagrams() })
        m.addItem(ClosureMenuItem("Chord Chart", state: s.chordChart == true) { [weak self] in self?.staff.toggleChordChart() })
        if let symbol = staff.selectedChordSymbol {
            let voicing = NSMenuItem(title: "\(symbol) Voicing", action: nil, keyEquivalent: "")
            let vm = NSMenu()
            let current = staff.chordDiagram(symbol)?.shape
            for shape in staff.voicings(symbol) {
                vm.addItem(ClosureMenuItem("\(shape.text)\(shape.baseFret > 1 ? "  (\(shape.baseFret)fr)" : "")", state: shape == current) { [weak self] in self?.staff.chooseVoicing(symbol, shape) })
            }
            vm.addItem(.separator())
            vm.addItem(ClosureMenuItem("Automatic") { [weak self] in self?.staff.chooseVoicing(symbol, nil) })
            voicing.submenu = vm
            m.addItem(voicing)
            m.addItem(ClosureMenuItem("Edit \(symbol) Diagram…") { [weak self] in self?.staff.editDiagram(symbol) })
        }
        m.addItem(ClosureMenuItem("Name Chord from Its Notes") { [weak self] in self?.staff.nameChord() })
        m.addItem(ClosureMenuItem("Chord Symbols from the Notes") { [weak self] in self?.staff.nameAllChords() })
        m.addItem(.separator())
        m.addItem(strumMenuItem())
        let tech = NSMenuItem(title: "Technique", action: nil, keyEquivalent: "")
        let tm = NSMenu()
        for (id, name, key) in GuitarMarks.kinds {
            tm.addItem(ClosureMenuItem(key.isEmpty ? name : "\(name)  ⌥\(key)", state: staff.hasTechnique(id)) { [weak self] in self?.staff.toggleTechnique(id) })
        }
        tech.submenu = tm
        m.addItem(tech)
        m.addItem(ClosureMenuItem("String Up  ⌥↑") { [weak self] in self?.staff.moveString(by: 1) })
        m.addItem(ClosureMenuItem("String Down  ⌥↓") { [weak self] in self?.staff.moveString(by: -1) })
        m.addItem(.separator())
        let sound = NSMenuItem(title: "Sound", action: nil, keyEquivalent: "")
        let sm = NSMenu()
        let current = staff.score.sound
        for (program, name) in TabInstrument.sounds {
            sm.addItem(ClosureMenuItem(name, state: current == program) { [weak self] in self?.staff.setSound(program) })
        }
        sound.submenu = sm
        m.addItem(sound)
        item.submenu = m
        return item
    }

    /// Strumming: patterns for the bar, the editor, strokes on the selected notes, swing, how strums are marked.
    private func strumMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Strumming", action: nil, keyEquivalent: "")
        let m = NSMenu()
        let s = score
        let bars = staff.selectedRange.map { r in Set(r.map { staff.cur.bar(of: $0) }).count } ?? 1
        let heading = NSMenuItem(title: bars > 1 ? "Pattern for the \(bars) Bars Selected" : "Pattern for Bar \(staff.currentBar + 1)", action: nil, keyEquivalent: "")
        heading.isEnabled = false
        m.addItem(heading)
        for p in staff.strumPatterns {
            m.addItem(ClosureMenuItem("\(p.name)   \(p.display)", state: staff.strummedLike(p)) { [weak self] in self?.staff.applyStrum(p.steps) })
        }
        m.addItem(.separator())
        m.addItem(ClosureMenuItem("Pattern Editor…") { [weak self] in self?.staff.editStrumPattern() })
        m.addItem(ClosureMenuItem("Strum Every Bar Like This One") { [weak self] in self?.staff.strumEveryBarLikeThis() })
        m.addItem(ClosureMenuItem("New Rhythm Guitar Staff…") { [weak self] in self?.staff.editStrumPattern(newStaff: true) })
        m.addItem(.separator())
        for (id, name, key) in GuitarMarks.strumKinds {
            m.addItem(ClosureMenuItem(key.isEmpty ? name : "\(name)  ⌥\(key)", state: staff.hasTechnique(id)) { [weak self] in self?.staff.toggleTechnique(id) })
        }
        m.addItem(ClosureMenuItem("Muted Strum  ⌥X", state: staff.hasTechnique("dead")) { [weak self] in self?.staff.toggleTechnique("dead") })
        m.addItem(ClosureMenuItem("Accent  ⇧V", state: staff.hasMark("accent")) { [weak self] in self?.staff.toggleArticulation("accent") })
        m.addItem(.separator())
        m.addItem(ClosureMenuItem("Swing Eighths", state: s.swing == true) { [weak self] in self?.staff.toggleSwing() })
        m.addItem(ClosureMenuItem("Mark Strums with Arrows (↓ ↑)", state: s.strumArrows == true) { [weak self] in self?.staff.toggleStrumArrows() })
        item.submenu = m
        return item
    }

    override func contextMenu() -> NSMenu {
        let menu = super.contextMenu()
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(ScorePlayer.shared.isPlaying ? "Stop" : "Play") { [weak self] in self?.staff.togglePlay() })
        menu.addItem(ClosureMenuItem("Score Title…") { [weak self] in self?.editTitle() })
        menu.addItem(ClosureMenuItem("Chord Symbols…  ⌃K") { [weak self] in self?.staff.activate(); self?.staff.beginWords(.chordSymbol) })
        menu.addItem(ClosureMenuItem("Lyrics…  ⌃L") { [weak self] in self?.staff.activate(); self?.staff.beginWords(.lyric) })
        menu.addItem(guitarMenuItem())
        let clef = NSMenuItem(title: score.staffCount > 1 ? "Clef (\(score.staffTitle(staff.currentStaff)))" : "Clef", action: nil, keyEquivalent: "")
        let clefs = NSMenu()
        for c in ScoreData.Clef.allCases {
            clefs.addItem(ClosureMenuItem(c.title, state: staff.score.clef == c) { [weak self] in self?.staff.setClef(c) })
        }
        clef.submenu = clefs
        menu.addItem(clef)
        // Staves: add, piano, move between, rename, remove.
        let staves = NSMenuItem(title: "Staves", action: nil, keyEquivalent: "")
        let staffMenu = NSMenu()
        if score.staffCount > 1 {
            for i in 0..<score.staffCount {
                staffMenu.addItem(ClosureMenuItem("Write in \(score.staffTitle(i))", state: staff.currentStaff == i) { [weak self] in self?.staff.setStaff(i) })
            }
            staffMenu.addItem(.separator())
        }
        staffMenu.addItem(ClosureMenuItem("Add Treble Staff") { [weak self] in self?.staff.addStaff(.treble) })
        staffMenu.addItem(ClosureMenuItem("Add Bass Staff") { [weak self] in self?.staff.addStaff(.bass) })
        staffMenu.addItem(ClosureMenuItem("Add Percussion Staff (Drums)") { [weak self] in self?.staff.addStaff(.percussion) })
        staffMenu.addItem(ClosureMenuItem(score.staffCount == 1 ? "Make Piano Grand Staff" : "Piano Brace (Grand Staff)", state: score.grandStaff == true) { [weak self] in
            self?.staff.makeGrandStaff()
        })
        if score.staffCount > 1 {
            staffMenu.addItem(.separator())
            staffMenu.addItem(ClosureMenuItem("Move Staff Up") { [weak self] in self?.staff.moveStaff(by: -1) })
            staffMenu.addItem(ClosureMenuItem("Move Staff Down") { [weak self] in self?.staff.moveStaff(by: 1) })
            staffMenu.addItem(ClosureMenuItem("Rename Staff…") { [weak self] in self?.staff.renameStaff() })
            staffMenu.addItem(ClosureMenuItem("Remove \(score.staffTitle(staff.currentStaff))") { [weak self] in self?.staff.removeStaff() })
        }
        staves.submenu = staffMenu
        menu.addItem(staves)
        // Transpose, the staff's instrument, concert pitch.
        let transpose = NSMenuItem(title: "Transpose", action: nil, keyEquivalent: "")
        let tMenu = NSMenu()
        let scopeItem = NSMenuItem(title: staff.transposeScope, action: nil, keyEquivalent: "")
        scopeItem.isEnabled = false
        tMenu.addItem(scopeItem)
        tMenu.addItem(ClosureMenuItem("Up a Half Step") { [weak self] in self?.staff.transposeHalfStep(up: true) })
        tMenu.addItem(ClosureMenuItem("Down a Half Step") { [weak self] in self?.staff.transposeHalfStep(up: false) })
        tMenu.addItem(ClosureMenuItem("Up an Octave") { [weak self] in self?.staff.transpose(by: ScoreInterval(steps: 7, semitones: 12)) })
        tMenu.addItem(ClosureMenuItem("Down an Octave") { [weak self] in self?.staff.transpose(by: ScoreInterval(steps: -7, semitones: -12)) })
        for (title, sign) in [("Up by Interval", 1), ("Down by Interval", -1)] {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for (name, interval) in ScoreInterval.named {
                sub.addItem(ClosureMenuItem(name) { [weak self] in self?.staff.transpose(by: sign > 0 ? interval : interval.inverse) })
            }
            item.submenu = sub
            tMenu.addItem(item)
        }
        if staff.transposeRange == nil {
            let toKey = NSMenuItem(title: "To Key", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for (fifths, name) in ScoreData.keyNames {
                sub.addItem(ClosureMenuItem(name, state: staff.score.keyFifths == fifths) { [weak self] in self?.staff.transpose(toKey: fifths, direction: 0) })
            }
            toKey.submenu = sub
            tMenu.addItem(toKey)
        }
        tMenu.addItem(.separator())
        tMenu.addItem(ClosureMenuItem("Transpose…") { [weak self] in self?.staff.showTransposeDialog() })
        transpose.submenu = tMenu
        menu.addItem(transpose)
        let instrumentItem = NSMenuItem(title: "Instrument", action: nil, keyEquivalent: "")
        let iMenu = NSMenu()
        let staffInstrument = staff.currentInstrument, transposes = score.forStaff(staff.currentStaff).transposition != nil
        iMenu.addItem(ClosureMenuItem("In C (as it sounds)", state: !transposes) { [weak self] in self?.staff.setInstrument(nil) })
        iMenu.addItem(.separator())
        for instrument in ScoreInstrument.all {
            iMenu.addItem(ClosureMenuItem(instrument.name, state: staffInstrument == instrument) { [weak self] in self?.staff.setInstrument(instrument) })
        }
        instrumentItem.submenu = iMenu
        menu.addItem(instrumentItem)
        menu.addItem(ClosureMenuItem("Concert Pitch", state: score.concertPitch == true) { [weak self] in self?.staff.toggleConcertPitch() })
        // Ottava lines and cross-staff notes, for the notes right-clicked (or selected).
        let ottavaItem = NSMenuItem(title: "Ottava", action: nil, keyEquivalent: "")
        let oMenu = NSMenu()
        let ottavaNow = staff.ottavaHere
        for (value, name) in [(1, "8va (an octave higher)"), (2, "15ma (two octaves higher)"), (-1, "8vb (an octave lower)"), (-2, "15mb (two octaves lower)")] {
            oMenu.addItem(ClosureMenuItem(name, state: ottavaNow == value) { [weak self] in self?.staff.setOttava(value) })
        }
        oMenu.addItem(.separator())
        oMenu.addItem(ClosureMenuItem("Remove Ottava") { [weak self] in self?.staff.setOttava(nil) })
        ottavaItem.submenu = oMenu
        menu.addItem(ottavaItem)
        if score.staffCount > 1 {
            let crossItem = NSMenuItem(title: "Cross-Staff", action: nil, keyEquivalent: "")
            let cMenu = NSMenu()
            cMenu.autoenablesItems = false
            let below = ClosureMenuItem("Move to Staff Below (⇧⌘↓)", state: staff.crossStaffHere == 1) { [weak self] in self?.staff.moveToStaff(1) }
            below.isEnabled = staff.canMoveToStaff(1) || staff.crossStaffHere == -1
            let aboveItem = ClosureMenuItem("Move to Staff Above (⇧⌘↑)", state: staff.crossStaffHere == -1) { [weak self] in self?.staff.moveToStaff(-1) }
            aboveItem.isEnabled = staff.canMoveToStaff(-1) || staff.crossStaffHere == 1
            cMenu.addItem(below)
            cMenu.addItem(aboveItem)
            cMenu.addItem(ClosureMenuItem("Back to Own Staff") { [weak self] in self?.staff.moveToStaff(0) })
            crossItem.submenu = cMenu
            menu.addItem(crossItem)
        }
        // Figured bass and Roman numerals.
        let analysisItem = NSMenuItem(title: "Analysis", action: nil, keyEquivalent: "")
        let aMenu = NSMenu()
        aMenu.addItem(ClosureMenuItem("Figured Bass… (⌃F)") { [weak self] in self?.staff.beginWords(.figures) })
        aMenu.addItem(ClosureMenuItem("Roman Numeral… (⌃R)") { [weak self] in self?.staff.beginWords(.numeral) })
        aMenu.addItem(.separator())
        aMenu.addItem(ClosureMenuItem("Analyze Roman Numerals") { [weak self] in self?.staff.addRomanNumerals() })
        aMenu.addItem(ClosureMenuItem("Analyze Figured Bass") { [weak self] in self?.staff.addFiguredBass() })
        aMenu.addItem(.separator())
        aMenu.addItem(ClosureMenuItem("Clear Roman Numerals") { [weak self] in self?.staff.clearAnalysis(numerals: true, figures: false) })
        aMenu.addItem(ClosureMenuItem("Clear Figured Bass") { [weak self] in self?.staff.clearAnalysis(numerals: false, figures: true) })
        analysisItem.submenu = aMenu
        menu.addItem(analysisItem)
        let key = NSMenuItem(title: "Key Signature", action: nil, keyEquivalent: "")
        let keys = NSMenu()
        for (fifths, name) in ScoreData.keyNames {
            keys.addItem(ClosureMenuItem(name, state: staff.score.keyFifths == fifths) { [weak self] in self?.staff.setKey(fifths) })
        }
        key.submenu = keys
        menu.addItem(key)
        // Dynamics, slur and hairpins at the note right-clicked (or the selected notes).
        let dynamic = NSMenuItem(title: "Dynamic", action: nil, keyEquivalent: "")
        let dynamics = NSMenu()
        let current = staff.dynamicHere
        for d in ScoreData.dynamics {
            dynamics.addItem(ClosureMenuItem(d, state: current == d) { [weak self] in self?.staff.setDynamic(d) })
        }
        if current != nil {
            dynamics.addItem(.separator())
            dynamics.addItem(ClosureMenuItem("Remove Dynamic") { [weak self] in self?.staff.setDynamic(nil) })
        }
        dynamic.submenu = dynamics
        menu.addItem(dynamic)
        menu.addItem(ClosureMenuItem("Slur  S", state: staff.slurHere) { [weak self] in self?.staff.toggleSlur() })
        menu.addItem(ClosureMenuItem("Crescendo  <", state: staff.hairpinHere == 1) { [weak self] in self?.staff.toggleHairpin(1) })
        menu.addItem(ClosureMenuItem("Diminuendo  >", state: staff.hairpinHere == -1) { [weak self] in self?.staff.toggleHairpin(-1) })
        let tuplet = NSMenuItem(title: "Tuplet", action: nil, keyEquivalent: "")
        let tuplets = NSMenu()
        for (ratio, name) in ScoreData.tupletKinds {
            tuplets.addItem(ClosureMenuItem("\(name) (\(ratio[0]):\(ratio[1]))  ⌃\(ratio[0])", state: ScoreView.inputTuplet == ratio) { [weak self] in
                self?.staff.toggleTuplet(ratio)
            })
        }
        tuplets.addItem(.separator())
        tuplets.addItem(ClosureMenuItem("No Tuplet") { [weak self] in self?.staff.clearTuplet() })
        tuplet.submenu = tuplets
        menu.addItem(tuplet)
        let grace = NSMenuItem(title: "Grace Note", action: nil, keyEquivalent: "")
        let graces = NSMenu()
        graces.addItem(ClosureMenuItem("Add Acciaccatura Before  /") { [weak self] in self?.staff.insertGrace("acciaccatura") })
        graces.addItem(ClosureMenuItem("Add Appoggiatura Before  ?") { [weak self] in self?.staff.insertGrace("appoggiatura") })
        if let kind = staff.graceHere {
            graces.addItem(.separator())
            graces.addItem(ClosureMenuItem("Acciaccatura", state: kind == "acciaccatura") { [weak self] in self?.staff.setGrace("acciaccatura") })
            graces.addItem(ClosureMenuItem("Appoggiatura", state: kind == "appoggiatura") { [weak self] in self?.staff.setGrace("appoggiatura") })
            graces.addItem(ClosureMenuItem("Normal Note") { [weak self] in self?.staff.setGrace(nil) })
        }
        grace.submenu = graces
        menu.addItem(grace)
        let lead = NSMenuItem(title: "Lead Sheet", action: nil, keyEquivalent: "")
        let leadMenu = NSMenu()
        leadMenu.addItem(ClosureMenuItem("Fill Bar with Slashes") { [weak self] in self?.staff.fillWithSlashes() })
        leadMenu.addItem(ClosureMenuItem("Rhythmic Slashes") { [weak self] in self?.staff.setSlash("rhythm") })
        leadMenu.addItem(ClosureMenuItem("Beat Slashes") { [weak self] in self?.staff.setSlash("beat") })
        leadMenu.addItem(ClosureMenuItem("Slashes Back to Notes") { [weak self] in self?.staff.setSlash(nil) })
        leadMenu.addItem(ClosureMenuItem("Slash Entry", state: ScoreView.inputSlash) { [weak self] in self?.staff.toggleSlashEntry() })
        leadMenu.addItem(.separator())
        for n in 1...3 {
            leadMenu.addItem(ClosureMenuItem("\(n == 1 ? "1st" : n == 2 ? "2nd" : "3rd") Ending (bar \(staff.currentBar + 1))", state: staff.endingHere == n) { [weak self] in
                self?.staff.toggleEnding(n)
            })
        }
        leadMenu.addItem(.separator())
        let perLine = NSMenuItem(title: "Bars per Line", action: nil, keyEquivalent: "")
        let perLineMenu = NSMenu()
        perLineMenu.addItem(ClosureMenuItem("As Many as Fit", state: score.barsPerLine == nil) { [weak self] in self?.staff.setBarsPerLine(nil) })
        for n in [2, 3, 4, 5, 6, 8] {
            perLineMenu.addItem(ClosureMenuItem("\(n)", state: score.barsPerLine == n) { [weak self] in self?.staff.setBarsPerLine(n) })
        }
        perLine.submenu = perLineMenu
        leadMenu.addItem(perLine)
        leadMenu.addItem(ClosureMenuItem("Composer…") { [weak self] in self?.staff.editComposer() })
        lead.submenu = leadMenu
        menu.addItem(lead)
        let articulation = NSMenuItem(title: "Articulations & Ornaments", action: nil, keyEquivalent: "")
        let arts = NSMenu()
        for (id, name, key) in ScoreData.articulationKinds {
            arts.addItem(ClosureMenuItem(key.isEmpty ? name : "\(name)  \(key)", state: staff.hasMark(id)) { [weak self] in self?.staff.toggleArticulation(id) })
        }
        arts.addItem(.separator())
        for (id, name) in ScoreData.ornamentKinds {
            arts.addItem(ClosureMenuItem(name, state: staff.hasMark(id)) { [weak self] in self?.staff.toggleOrnament(id) })
        }
        arts.addItem(ClosureMenuItem("Fermata  ⇧H", state: staff.hasMark("fermata")) { [weak self] in self?.staff.toggleFermata() })
        arts.addItem(.separator())
        arts.addItem(ClosureMenuItem("Clear Articulations & Ornaments") { [weak self] in self?.staff.clearMarks() })
        articulation.submenu = arts
        menu.addItem(articulation)
        // At the bar right-clicked (or the cursor's).
        let bar = staff.currentBar
        let change = NSMenuItem(title: bar == 0 ? "Key Change (first bar: the key signature)" : "Key Change from Bar \(bar + 1)", action: nil, keyEquivalent: "")
        let changes = NSMenu()
        let here = staff.keyChangeHere
        for (fifths, name) in ScoreData.keyNames {
            changes.addItem(ClosureMenuItem(name, state: here == fifths) { [weak self] in self?.staff.setKeyChange(fifths) })
        }
        if bar > 0, here != nil {
            changes.addItem(.separator())
            changes.addItem(ClosureMenuItem("Remove Key Change") { [weak self] in self?.staff.setKeyChange(nil) })
        }
        change.submenu = changes
        menu.addItem(change)
        menu.addItem(ClosureMenuItem("Start Repeat  |:  (Bar \(bar + 1))", state: score.mark(bar).repeatStart == true) { [weak self] in
            self?.staff.toggleRepeatStart()
        })
        menu.addItem(ClosureMenuItem("End Repeat  :|  (Bar \(bar + 1))", state: score.mark(bar).repeatEnd == true) { [weak self] in
            self?.staff.toggleRepeatEnd()
        })
        let time = NSMenuItem(title: "Time Signature", action: nil, keyEquivalent: "")
        let times = NSMenu()
        for (b, u) in ScoreData.times {
            times.addItem(ClosureMenuItem("\(b)/\(u)", state: score.beats == b && score.beatUnit == u) { [weak self] in
                self?.update({ $0.beats = b; $0.beatUnit = u }, actionName: "Time Signature")
            })
        }
        time.submenu = times
        menu.addItem(time)
        let tempoBar = staff.currentBar
        let tempo = NSMenuItem(title: tempoBar == 0 ? "Tempo (\(score.tempoLabel(bar: 0)))" : "Tempo from Bar \(tempoBar + 1)", action: nil, keyEquivalent: "")
        tempo.submenu = tempoMenu(bar: tempoBar)
        menu.addItem(tempo)
        menu.addItem(ClosureMenuItem("Copy Score as Picture") { [weak self] in self?.copyPicture() })
        menu.addItem(ClosureMenuItem("Export MusicXML…") { [weak self] in
            guard let self else { return }
            MusicXML.save(self.score, from: self.window)
        })
        return menu
    }

    /// Tempo words, speeds, rit. / accel. / a tempo and the Metronome Mark dialog, for a bar.
    private func tempoMenu(bar: Int) -> NSMenu {
        let menu = NSMenu()
        let here = staff.tempoHere
        for (term, bpm) in ScoreData.tempoTerms {
            menu.addItem(ClosureMenuItem("\(term)  (♩ = \(bpm))", state: here.tempoText == term) { [weak self] in self?.staff.setTempoTerm(term, bpm) })
        }
        menu.addItem(.separator())
        let number = staff.tempoNumberHere
        for t in [60, 72, 80, 90, 100, 112, 120, 132, 144, 160] {
            menu.addItem(ClosureMenuItem("♩ = \(t)", state: number == t && (bar == 0 || here.tempo != nil)) { [weak self] in self?.staff.setTempo(t) })
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("rit. (gradually slower)", state: here.gradual == -1) { [weak self] in self?.staff.toggleGradual(-1) })
        menu.addItem(ClosureMenuItem("accel. (gradually faster)", state: here.gradual == 1) { [weak self] in self?.staff.toggleGradual(1) })
        if bar > 0 { menu.addItem(ClosureMenuItem("a tempo") { [weak self] in self?.staff.aTempo() }) }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Metronome Mark…") { [weak self] in self?.staff.editMetronomeMark() })
        if bar > 0, !here.isEmpty, here.tempo != nil || here.gradual != nil || here.tempoText != nil {
            menu.addItem(ClosureMenuItem("Remove Tempo Change") { [weak self] in self?.staff.removeTempoChange() })
        }
        return menu
    }

    func editTitle() {
        let alert = NSAlert()
        alert.messageText = "Score Title"
        let field = NSTextField(string: score.title)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let title = field.stringValue
        update({ $0.title = title }, actionName: "Score Title")
    }

    func image() -> NSImage? {
        let wasActive = ScoreView.active === staff
        if wasActive { ScoreView.active = nil }
        defer { if wasActive { ScoreView.active = staff } }
        guard let rep = staff.bitmapImageRepForCachingDisplay(in: staff.bounds) else { return nil }
        staff.cacheDisplay(in: staff.bounds, to: rep)
        let image = NSImage(size: staff.bounds.size)
        image.addRepresentation(rep)
        return image
    }

    private func copyPicture() {
        guard let image = image() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }
}
