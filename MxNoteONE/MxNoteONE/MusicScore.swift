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
//  string and fret (standard tuning); ⌥↑ / ⌥↓ move a note to another string.
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
    /// The guitar string for the TAB staff (0 = low E … 5 = high E); nil = chosen automatically.
    var tabString: Int?
    /// A triplet note: three in the time of two.
    var tuplet: Bool?
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

    /// Length in quarter notes.
    var beats: Double { 4 / Double(duration.rawValue) * (dotted ? 1.5 : 1) * (tuplet == true ? 2.0 / 3.0 : 1) }
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
    var diatonic: Int { octave * 7 + step }
}

/// What happens at a bar: a new key from it, a repeat starting there, or ending at its end.
struct ScoreBarMark: Codable, Hashable {
    var keyFifths: Int?
    var repeatStart: Bool?
    var repeatEnd: Bool?
    /// A new tempo from this bar (quarter notes a minute), with a word for it (Allegro, a tempo…) and the note the
    /// metronome mark counts in ("quarter", "dotted", "half", "eighth").
    var tempo: Int?
    var tempoText: String?
    var tempoUnit: String?
    /// Gradually slower (-1, rit.) or faster (1, accel.) from this bar to the next tempo change.
    var gradual: Int?
    var isEmpty: Bool {
        keyFifths == nil && repeatStart != true && repeatEnd != true && tempo == nil && (tempoText ?? "").isEmpty && tempoUnit == nil && gradual == nil
    }
}

struct ScoreData: Codable, Hashable {
    enum Clef: String, Codable, CaseIterable, Identifiable {
        case treble, bass
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
        /// The bottom line's note, in steps from C0 (treble: E4, bass: G2).
        var bottomLine: Int { self == .treble ? 4 * 7 + 2 : 2 * 7 + 4 }
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
    /// Key changes and repeat signs, by bar (0 = the first bar).
    var barMarks: [Int: ScoreBarMark]?

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
        var order: [Int] = [], b = 0, start = 0, repeated = Set<Int>()
        while b < bars, order.count < 5000 {
            if mark(b).repeatStart == true { start = b }
            order.append(b)
            if mark(b).repeatEnd == true {
                if !repeated.contains(b) {
                    repeated.insert(b)
                    b = start
                    continue
                }
                start = b + 1
            }
            b += 1
        }
        return order
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

    /// Triplet groups in a bar: runs of triplet notes, three to the time of two.
    func tripletGroups(in bar: Range<Int>) -> [[Int]] {
        var groups: [[Int]] = [], current: [Int] = [], total = 0.0, target = 0.0
        for i in bar {
            let n = notes[i]
            guard n.tuplet == true else {
                if !current.isEmpty { groups.append(current) }
                current = []; total = 0
                continue
            }
            if current.isEmpty { target = n.normalBeats * 2 }
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
        return Self.midi(step: note.step, octave: note.octave, alter: soundingAlter(index))
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
        guard !note.rest, let alter = note.alter, !tiedFrom(index) else { return false }
        return alter != (alterBefore(index) ?? keyAlter(note.step, at: index))
    }

    /// Every pitch a note sounds (the note and its chord tones), as MIDI numbers.
    func midis(_ index: Int) -> [Int] {
        guard let main = midi(index) else { return [] }
        let tones = (notes[index].chord ?? []).map { Self.midi(step: $0.step, octave: $0.octave, alter: $0.alter ?? keyAlter($0.step, at: index)) }
        return [main] + tones
    }

    /// Guitar strings in standard tuning (low E to high E), as MIDI numbers.
    static let tuning = [40, 45, 50, 55, 59, 64]

    /// Each pitch's string and fret for the TAB staff (guitar sounds an octave below treble-clef notation).
    func tab(_ index: Int) -> [(string: Int, fret: Int)] {
        let shift = clef == .treble ? 12 : 0
        let pitches = midis(index).map { $0 - shift }
        guard !pitches.isEmpty else { return [] }
        var used = Set<Int>(), result: [(Int, Int)] = []
        // The note's own string when chosen (and playable there).
        if let chosen = notes[index].tabString, Self.tuning.indices.contains(chosen) {
            let fret = pitches[0] - Self.tuning[chosen]
            if fret >= 0, fret <= 24 {
                result.append((chosen, fret))
                used.insert(chosen)
            }
        }
        // The rest, highest first, each on the free string with the lowest fret.
        let rest = result.isEmpty ? pitches : Array(pitches.dropFirst())
        for pitch in rest.sorted(by: >) {
            let options = Self.tuning.indices.filter { !used.contains($0) && pitch - Self.tuning[$0] >= 0 && pitch - Self.tuning[$0] <= 20 }
            guard let string = options.min(by: { pitch - Self.tuning[$0] < pitch - Self.tuning[$1] }) else { continue }
            result.append((string, pitch - Self.tuning[string]))
            used.insert(string)
        }
        return result
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
        return Self.midi(step: step, octave: octave, alter: keyAlter(step, at: index))
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
        return "\(title.isEmpty ? "Music score" : title) — \(measures.count) bars, \(beats)/\(beatUnit), \(key), ♩ = \(tempo)"
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
    }

    /// Articulations, fermata and ornament in words (‹stacc. tr›).
    private func marks(_ n: ScoreNote) -> String {
        let short = ["staccato": "stacc.", "staccatissimo": "staccatiss.", "tenuto": "ten.", "accent": "acc.", "marcato": "marc.",
                     "trill": "tr", "mordent": "mord.", "prall": "prall", "turn": "turn"]
        let words = (n.articulations ?? []).compactMap { short[$0] } + (n.ornament.flatMap { short[$0] }.map { [$0] } ?? [])
            + (n.fermata == true ? ["fermata"] : [])
        return words.isEmpty ? "" : " ‹" + words.joined(separator: " ") + "›"
    }

    /// One note by name (C4 q, D♯4 8., r h…).
    private func name(_ i: Int, _ n: ScoreNote) -> String {
        let length = ["", "w", "h", "", "q", "", "", "", "8", "", "", "", "", "", "", "", "16"][n.duration.rawValue] + (n.dotted ? "." : "")
            + (n.tuplet == true ? "³" : "")
        if n.rest { return "r" + length + marks(n) }
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

/// Plays scores with the Mac's General MIDI piano.
final class ScorePlayer {
    static let shared = ScorePlayer()

    private let engine = AVAudioEngine()
    private let sampler = AVAudioUnitSampler()
    private var started = false
    private var work: [DispatchWorkItem] = []
    private var sounding: Set<UInt8> = []
    /// The note being played (for highlighting), and the view playing.
    private(set) weak var view: ScoreView?
    var isPlaying: Bool { !work.isEmpty }

    private func start() {
        guard !started else { return }
        engine.attach(sampler)
        engine.connect(sampler, to: engine.mainMixerNode, format: nil)
        let bank = URL(fileURLWithPath: "/System/Library/Components/CoreAudio.component/Contents/Resources/gs_instruments.dls")
        if FileManager.default.fileExists(atPath: bank.path) {
            try? sampler.loadSoundBankInstrument(at: bank, program: 0, bankMSB: UInt8(kAUSampler_DefaultMelodicBankMSB), bankLSB: 0)
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

    func preview(_ midis: [Int]) {
        start()
        let keys = midis.map { UInt8(max(0, min(127, $0))) }
        for key in keys { sampler.startNote(key, withVelocity: 80, onChannel: 0) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            for key in keys { self?.sampler.stopNote(key, onChannel: 0) }
        }
    }

    /// Plays every voice from a point (in quarter notes from the start) to the end, highlighting the notes sounding.
    /// Plays every voice from a point in a bar (`offset` quarter notes in), taking repeats.
    func play(_ score: ScoreData, fromBar startBar: Int, offset: Double, in view: ScoreView) {
        stop()
        start()
        self.view = view
        let secondsPerBeat = 60 / Double(max(20, score.tempo))
        let lines = (0..<ScoreData.voiceCount).map { score.forVoice($0) }
        let barsByVoice = lines.map { $0.notes.isEmpty ? [] : $0.measures }
        let barCount = barsByVoice.map(\.count).max() ?? 0
        var order = score.playOrder(bars: barCount)
        if let first = order.firstIndex(of: startBar) { order = Array(order[first...]) }
        #if DEBUG
        Self.plan = []
        #endif
        // 1. What sounds: each voice's notes in playing order (tied notes as one), with when and how long (in beats).
        struct Sound { let voice: Int; let index: Int; var time: Double; var length: Double; let velocity: Int }
        var sounds: [Sound] = []
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
        // 4. Schedule: articulations shape length and loudness; ornaments play their notes.
        var end = 0.0
        for sound in sounds {
            let line = lines[sound.voice]
            let note = line.notes[sound.index]
            let ref = NoteRef(voice: sound.voice, index: sound.index)
            let start = seconds(sound.time) + delay(sound.time)
            let span = (seconds(sound.time + sound.length) - seconds(sound.time)) * (note.fermata == true ? 2 : 1)
            let marks = Set(note.articulations ?? [])
            let inSlur = line.slurs.contains { $0.0 <= sound.index && sound.index < $0.1 }
            let sounding = marks.contains("staccatissimo") ? 0.3 : marks.contains("staccato") ? 0.5
                : marks.contains("tenuto") || inSlur ? 1.0 : 0.95
            var velocity = sound.velocity
            if marks.contains("accent") { velocity += 18 }
            if marks.contains("marcato") { velocity += 28 }
            let vel = UInt8(max(1, min(127, velocity)))
            let keys = line.midis(sound.index).map { UInt8(max(0, min(127, $0))) }
            // The highlight lasts the whole note.
            let on = DispatchWorkItem { [weak self] in self?.view?.playing.insert(ref) }
            let off = DispatchWorkItem { [weak self] in self?.view?.playing.remove(ref) }
            DispatchQueue.main.asyncAfter(deadline: .now() + start, execute: on)
            DispatchQueue.main.asyncAfter(deadline: .now() + start + span * 0.97, execute: off)
            work += [on, off]
            end = max(end, start + span)
            guard !keys.isEmpty else { continue }
            // The pitches: the note (and chord) as written, or an ornament's quick notes on the main pitch.
            var parts: [(keys: [UInt8], at: Double, length: Double)] = [(keys, 0, span * sounding)]
            if let ornament = note.ornament, let main = keys.first {
                let up = line.neighbor(sound.index, 1).map { UInt8(max(0, min(127, $0))) } ?? main
                let down = line.neighbor(sound.index, -1).map { UInt8(max(0, min(127, $0))) } ?? main
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
            #if DEBUG
            Self.plan.append((ref, start, span, parts.map { ($0.keys, $0.at, $0.length) }))
            #endif
            for part in parts {
                let down = DispatchWorkItem { [weak self] in
                    for key in part.keys {
                        self?.sampler.startNote(key, withVelocity: vel, onChannel: 0)
                        self?.sounding.insert(key)
                    }
                }
                let up = DispatchWorkItem { [weak self] in
                    for key in part.keys {
                        self?.sampler.stopNote(key, onChannel: 0)
                        self?.sounding.remove(key)
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + start + part.at, execute: down)
                DispatchQueue.main.asyncAfter(deadline: .now() + start + part.at + max(0.03, part.length), execute: up)
                work += [down, up]
            }
        }
        guard !work.isEmpty else { return stop() }
        let finish = DispatchWorkItem { [weak self] in self?.stop() }
        DispatchQueue.main.asyncAfter(deadline: .now() + end + 0.05, execute: finish)
        work.append(finish)
        view.needsDisplay = true
        NotebookStore.shared.editor.scorePlaying = true
    }

    #if DEBUG
    /// Self-tests: what the last play scheduled (note, start, length in seconds, and its pitches).
    nonisolated(unsafe) static var plan: [(ref: NoteRef, start: Double, span: Double, parts: [(keys: [UInt8], at: Double, length: Double)])] = []
    #endif

    func stop() {
        work.forEach { $0.cancel() }
        work = []
        for key in sounding { sampler.stopNote(key, onChannel: 0) }
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
    var score: ScoreData { owner?.score ?? ScoreData() }
    var isExport = false

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
    /// The score as the current voice sees it.
    private var cur: ScoreData { score.forVoice(voice) }

    /// The length, dot and triplet for new notes (shared with the Score ribbon tab).
    static var inputDuration: ScoreNote.Duration = .quarter
    static var inputDotted = false
    static var inputTriplet = false

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { !isExport }

    // MARK: Layout

    static let space: CGFloat = 8
    private var space: CGFloat { Self.space }
    private let titleHeight: CGFloat = 26
    private var chordBand: CGFloat { score.hasChordSymbols ? space * 2.6 : 0 }
    private var lyricBand: CGFloat { score.hasLyrics ? space * 2.8 : 0 }
    private var tabBand: CGFloat { score.showTab == true ? space * 10 : 0 }
    /// Dynamics and hairpins under the staff.
    private var dynamicBand: CGFloat { score.hasDynamics ? space * 3 : 0 }
    /// Room over the staff for marks above notes (fermatas, ornaments, and voice 1's articulations past its stems),
    /// and under it for voice 2's.
    private var markBandAbove: CGFloat {
        score.notes.contains { $0.fermata == true || $0.ornament != nil || (score.hasSecondVoice && $0.articulations != nil) } ? space * 2.6 : 0
    }
    private var markBandBelow: CGFloat {
        score.hasSecondVoice && score.line(1).contains { $0.fermata == true || $0.ornament != nil || $0.articulations != nil } ? space * 3.4 : 0
    }
    /// Metronome marks, tempo words and rit. / accel. over everything else.
    private var tempoBand: CGFloat { space * 2.6 }
    private var systemHeight: CGFloat { space * 13 + chordBand + lyricBand + tabBand + dynamicBand + markBandAbove + markBandBelow + tempoBand }
    /// TAB lines' spacing.
    private var tabGap: CGFloat { space * 1.3 }

    static let lyricFont = NSFont.systemFont(ofSize: 12)
    static let chordFont = NSFont.systemFont(ofSize: 13, weight: .semibold)

    struct Placed {
        let index: Int
        let x: CGFloat
        let system: Int
        var voice = 0
    }

    private(set) var placed: [Placed] = []
    /// Where the caret goes for each cursor position (x, system).
    private var caretSpots: [(x: CGFloat, system: Int)] = []
    /// Bar lines (x, system), and where each system's notes start.
    private var barLines: [(x: CGFloat, system: Int, style: BarStyle)] = []
    private var systemCount = 1
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
        return (score.title.isEmpty ? 0 : titleHeight) + CGFloat(systemCount) * systemHeight + space
    }

    private func width(of note: ScoreNote, index: Int, in line: ScoreData? = nil) -> CGFloat {
        let score = line ?? self.score
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
            width = max(width, (symbol as NSString).size(withAttributes: [.font: Self.chordFont]).width + space * 1.2)
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
        placed = []
        caretSpots = []
        barLines = []
        systemStarts = []
        let usable = max(bounds.width - space * 2, space * 20)
        let lines = (0..<ScoreData.voiceCount).map { score.forVoice($0) }
        let barsByVoice = lines.map { $0.notes.isEmpty ? [] : $0.measures }
        let barCount = max(1, barsByVoice.map(\.count).max() ?? 1)
        // Each bar's notes by when they start (in quarter notes from the bar line).
        struct Event { let onset: Double; let voice: Int; let index: Int }
        var events: [[Event]] = []
        var gaps: [[(onset: Double, gap: CGFloat)]] = []
        for m in 0..<barCount {
            var list: [Event] = []
            for v in lines.indices where m < barsByVoice[v].count {
                var t = 0.0
                for i in barsByVoice[v][m] {
                    list.append(Event(onset: t, voice: v, index: i))
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
        // Bars into systems (lines).
        var systems: [[Int]] = [[]]
        var used = headerWidth(fifths: score.keyFifths, first: true)
        for (m, w) in widths.enumerated() {
            if !systems[systems.count - 1].isEmpty, used + w + fixed(m, atStart: false) > usable {
                systems.append([])
                used = headerWidth(fifths: score.fifths(inBar: m), first: false)
            }
            used += w + fixed(m, atStart: systems[systems.count - 1].isEmpty)
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
            let start = space + header
            systemStarts.append(start)
            let natural = bars.reduce(0) { $0 + widths[$1] }
            let fixedRoom = bars.enumerated().reduce(0) { $0 + fixed($1.element, atStart: $1.offset == 0) }
            // Full lines are spread to the width (not the last one).
            let stretch = s < systems.count - 1 && natural > 0 ? max(1, (usable - header - fixedRoom) / natural) : 1
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
                    placed.append(Placed(index: e.index, x: ex + accidental, system: s, voice: e.voice))
                    if e.voice == voice { spots.append((Double(e.index), ex, s)) }
                }
                if barsByVoice[voice].isEmpty, m == 0 { spots.append((-1, x + space * 1.2 * stretch, s)) }
                x += widths[m] * stretch + endRoom[m]
                let last = m == barCount - 1
                let style: BarStyle = score.mark(m).repeatEnd == true ? .endRepeat : last ? .final
                    : m + 1 < barCount && keyRoom[m + 1] > 0 ? .double : .single
                barLines.append((x, s, style))
            }
        }
        // The current voice's caret: before each of its notes, and after the last.
        caretSpots = spots.filter { $0.0 >= 0 }.sorted { $0.0 < $1.0 }.map { ($0.1 - space * 0.9, $0.2) }
        let mine = lines[voice]
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
        (score.title.isEmpty ? 0 : titleHeight) + CGFloat(system) * systemHeight + space * 4.5 + chordBand + markBandAbove + tempoBand
    }

    private func lyricY(_ system: Int) -> CGFloat { staffTop(system) + space * 4 + space * 3.4 + dynamicBand + markBandBelow }

    /// The middle of the dynamics band (under the staff, clear of stems and ledger lines).
    private func dynamicY(_ system: Int) -> CGFloat { staffTop(system) + space * 4 + space * 3.6 + markBandBelow }

    /// The TAB staff's top line (high E).
    private func tabTop(_ system: Int) -> CGFloat { staffTop(system) + space * 4 + space * 4.2 + lyricBand + dynamicBand + markBandBelow }

    /// Half-spaces up from the bottom line.
    private func position(_ note: ScoreNote) -> Int { note.diatonic - score.clef.bottomLine }

    private func y(position: Int, system: Int) -> CGFloat {
        staffTop(system) + space * 4 - CGFloat(position) * space / 2
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
        for change in keyChanges {
            drawKeySignature(change.to, cancelling: change.from, x: change.x + space * 0.5, system: change.system, ink: ink)
        }
        drawNotes(ink: ink)
        drawSlurs(ink: ink)
        drawMarks(ink: ink)
        drawDynamics(ink: ink)
        drawTempos(ink: ink)
        drawWords(ink: ink)
        if score.showTab == true { drawTab(ink: ink) }
        drawCaret()
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
        for (k, p) in placed.enumerated() {
            let note = score.notes[p.index]
            let color = colorFor(NoteRef(voice: 0, index: p.index), ink: ink)
            if let symbol = note.chordSymbol, !symbol.isEmpty {
                let attrs: [NSAttributedString.Key: Any] = [.font: Self.chordFont, .foregroundColor: color]
                (symbol as NSString).draw(at: NSPoint(x: p.x - space * 0.2, y: staffTop(p.system) - space * 2 - chordBand - markBandAbove + space * 0.2),
                                          withAttributes: attrs)
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

    /// The TAB staff: six strings (high E on top) with each note's fret.
    private func drawTab(ink: NSColor) {
        let fretFont = NSFont.systemFont(ofSize: 11, weight: .medium)
        for s in 0..<systemCount {
            let top = tabTop(s)
            ink.setFill()
            for line in 0..<6 {
                NSRect(x: space, y: top + CGFloat(line) * tabGap - 0.5, width: bounds.width - space * 2, height: 1).fill()
            }
            // T A B down the left, over a white strip (as printed tab).
            let tabAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: tabGap * 1.15), .foregroundColor: ink]
            NSColor.white.setFill()
            NSRect(x: space * 1.6, y: top + tabGap * 0.35, width: space * 1.9, height: tabGap * 4.3).fill()
            for (i, letter) in ["T", "A", "B"].enumerated() {
                let size = (letter as NSString).size(withAttributes: tabAttrs)
                (letter as NSString).draw(at: NSPoint(x: space * 2.55 - size.width / 2, y: top + tabGap * (0.5 + CGFloat(i) * 1.4)),
                                          withAttributes: tabAttrs)
            }
        }
        for bar in barLines {
            ink.setFill()
            NSRect(x: bar.x - 0.5, y: tabTop(bar.system), width: bar.style == .final || bar.style == .endRepeat ? 3 : 1, height: tabGap * 5).fill()
        }
        for p in placed where !score.forVoice(p.voice).notes[p.index].rest {
            let color = colorFor(NoteRef(voice: p.voice, index: p.index), ink: ink)
            let attrs: [NSAttributedString.Key: Any] = [.font: fretFont, .foregroundColor: color]
            for spot in score.forVoice(p.voice).tab(p.index) {
                let text = "\(spot.fret)"
                let size = (text as NSString).size(withAttributes: attrs)
                let cy = tabTop(p.system) + CGFloat(5 - spot.string) * tabGap
                let box = NSRect(x: p.x + space * 0.62 - size.width / 2 - 1.5, y: cy - size.height / 2, width: size.width + 3, height: size.height)
                NSColor.white.setFill()
                box.fill()
                (text as NSString).draw(at: NSPoint(x: box.minX + 1.5, y: box.minY), withAttributes: attrs)
            }
        }
    }

    private func drawStaff(_ system: Int, ink: NSColor) {
        let top = staffTop(system)
        ink.setFill()
        for line in 0..<5 {
            NSRect(x: space, y: top + CGFloat(line) * space - 0.5, width: bounds.width - space * 2, height: 1).fill()
        }
        // Clef.
        let symbols = NSFont(name: "Apple Symbols", size: space * (score.clef == .treble ? 7.2 : 4.2)) ?? .systemFont(ofSize: space * 5)
        let clef = score.clef == .treble ? "\u{1D11E}" : "\u{1D122}"
        let clefAttrs: [NSAttributedString.Key: Any] = [.font: symbols, .foregroundColor: ink]
        let clefSize = (clef as NSString).size(withAttributes: clefAttrs)
        let clefY = score.clef == .treble ? top + space * 2 - clefSize.height * 0.56 : top - clefSize.height * 0.19
        (clef as NSString).draw(at: NSPoint(x: space * 1.4, y: clefY), withAttributes: clefAttrs)
        // Key signature (the key of the line's first bar).
        let fifths = score.fifths(inBar: systemFirstBars.indices.contains(system) ? systemFirstBars[system] : 0)
        let x = drawKeySignature(fifths, x: space * 5.2, system: system, ink: ink)
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
        for g in groups {
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
            let pos = position(note)
            let cy = y(position: pos, system: p.system)
            // Ledger lines.
            color.setFill()
            if pos <= -2 { for l in stride(from: -2, through: pos, by: -2) { ledger(x: p.x, y: y(position: l, system: p.system)) } }
            if pos >= 10 { for l in stride(from: 10, through: pos, by: 2) { ledger(x: p.x, y: y(position: l, system: p.system)) } }
            if score.showsAccidental(p.index) { drawAccidental(note.alter ?? 0, x: p.x - space * 1.35, y: cy, ink: color) }
            // Head.
            let w = note.duration == .whole ? space * 1.5 : space * 1.25, h = space * 0.95
            let head = NSBezierPath(ovalIn: NSRect(x: -w / 2, y: -h / 2, width: w, height: h))
            var transform = AffineTransform(translationByX: p.x + w / 2, byY: cy)
            if note.duration != .whole { transform.rotate(byDegrees: -20) }
            head.transform(using: transform)
            color.set()
            if note.duration.rawValue >= 4 {
                head.fill()
            } else {
                head.lineWidth = note.duration == .whole ? 1.6 : 1.4
                head.stroke()
            }
            // Chord notes: more heads on the same stem (a step apart: side by side).
            let tones = note.chord ?? []
            let allPositions = ([pos] + tones.map { $0.diatonic - score.clef.bottomLine }).sorted()
            let up = beamed[p.index]?.up ?? forcedUp ?? (allPositions.reduce(0, +) / allPositions.count < 4)
            if !tones.isEmpty {
                var shifted = Set<Int>()
                for (k, tp) in allPositions.enumerated() where k > 0 && tp - allPositions[k - 1] == 1 && !shifted.contains(allPositions[k - 1]) {
                    shifted.insert(up ? tp : allPositions[k - 1])
                }
                for tone in tones {
                    let tp = tone.diatonic - score.clef.bottomLine
                    let tx = shifted.contains(tp) ? (up ? p.x + w - 1 : p.x - w + 1) : p.x
                    let ty = y(position: tp, system: p.system)
                    color.setFill()
                    if tp <= -2 { for l in stride(from: -2, through: tp, by: -2) { ledger(x: tx, y: y(position: l, system: p.system)) } }
                    if tp >= 10 { for l in stride(from: 10, through: tp, by: 2) { ledger(x: tx, y: y(position: l, system: p.system)) } }
                    if let alter = tone.alter, alter != score.keyAlter(tone.step, at: p.index) {
                        drawAccidental(alter, x: p.x - space * 1.35 - (score.showsAccidental(p.index) ? space * 1.2 : 0), y: ty, ink: color)
                    }
                    let extra = NSBezierPath(ovalIn: NSRect(x: -w / 2, y: -h / 2, width: w, height: h))
                    var t = AffineTransform(translationByX: tx + w / 2, byY: ty)
                    if note.duration != .whole { t.rotate(byDegrees: -20) }
                    extra.transform(using: t)
                    color.set()
                    if note.duration.rawValue >= 4 { extra.fill() } else { extra.lineWidth = 1.4; extra.stroke() }
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
            let lowY = y(position: allPositions.first!, system: p.system), highY = y(position: allPositions.last!, system: p.system)
            stemSpans[p.index] = (lowY, highY)
            shapes[NoteRef(voice: v, index: p.index)] = (up, lowY, highY)
            // Stem and flags (beamed notes get their stems with the beam).
            if note.duration != .whole, beamed[p.index] == nil {
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
            guard let up = beamed[g[0]]?.up else { continue }
            let points = g.compactMap { i -> (x: CGFloat, y: CGFloat, i: Int)? in
                guard let p = placed.first(where: { $0.index == i }) else { return nil }
                let w = space * 1.25
                return (up ? p.x + w - 0.6 : p.x + 0.6, y(position: position(score.notes[i]), system: p.system), i)
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

    private func colorFor(_ ref: NoteRef, ink: NSColor) -> NSColor {
        if playing.contains(ref) { return .systemOrange }
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
            for group in score.tripletGroups(in: bar) {
                let spots = group.compactMap { i in placed.first { $0.index == i } }
                guard let first = spots.first, let last = spots.last, first.system == last.system else { continue }
                let positions = group.map { score.notes[$0].rest ? 4 : position(score.notes[$0]) }
                let up = forcedUp ?? (positions.reduce(0, +) / max(1, positions.count) < 4)
                let ys = group.map { score.notes[$0].rest ? staffTop(first.system) + space * 2 : y(position: position(score.notes[$0]), system: first.system) }
                let x1 = first.x - space * 0.2, x2 = last.x + space * 1.45
                let yLine = up ? min(ys.min()! - space * 4.4, staffTop(first.system) - space * 1.2) : max(ys.max()! + space * 4.4, staffTop(first.system) + space * 5.2)
                let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: colorFor(NoteRef(voice: v, index: group[0]), ink: ink)]
                let size = ("3" as NSString).size(withAttributes: attrs)
                let mid = (x1 + x2) / 2
                ("3" as NSString).draw(at: NSPoint(x: mid - size.width / 2, y: yLine - size.height / 2), withAttributes: attrs)
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

    private func edit(_ name: String, _ change: (inout ScoreData) -> Void) {
        owner?.update(change, actionName: name)
        needsDisplay = true
    }

    /// Changes the current voice's notes (the change sees that voice as the score's notes).
    private func editVoice(_ name: String, _ change: (inout ScoreData) -> Void) {
        let v = voice
        edit(name) { full in
            var view = full.forVoice(v)
            change(&view)
            full.setLine(v, view.notes)
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
        if Self.inputTriplet { note.tuplet = true }
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
        let at = min(cursor, cur.notes.count)
        editVoice(step == nil ? "Add Rest" : "Add Note") { $0.notes.insert(note, at: at) }
        // Keep entering after it.
        selected = nil
        lastEntered = at
        cursor = at + 1
        needsDisplay = true
        if let midi = cur.midi(at) { ScorePlayer.shared.preview(midi) }
    }

    private func changeSelected(_ name: String, _ change: (inout ScoreNote) -> Void) {
        guard let i = target else { return NSSound.beep() }
        editVoice(name) { change(&$0.notes[i]) }
        if let midi = cur.midi(i) { ScorePlayer.shared.preview(midi) }
    }

    func moveSelected(steps: Int) {
        changeSelected("Move Note") { n in
            guard !n.rest else { return }
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
        ScorePlayer.shared.preview(cur.midis(i))
    }

    func clearChordTones() {
        changeSelected("Remove Chord Notes") { $0.chord = nil }
    }

    /// The selected note onto the next higher (+1) or lower (-1) guitar string, where it can be played.
    func moveString(by delta: Int) {
        guard let i = target, !cur.notes[i].rest, let current = cur.tab(i).first?.string else { return NSSound.beep() }
        let shift = score.clef == .treble ? 12 : 0
        guard let pitch = cur.midi(i).map({ $0 - shift }) else { return }
        var string = current + delta
        while ScoreData.tuning.indices.contains(string) {
            let fret = pitch - ScoreData.tuning[string]
            if fret >= 0 && fret <= 24 {
                let chosen = string
                editVoice("Guitar String") { $0.notes[i].tabString = chosen }
                return
            }
            string += delta
        }
        NSSound.beep()
    }

    func toggleTab() {
        edit("Guitar Tab") { $0.showTab = $0.showTab == true ? nil : true }
    }

    // MARK: Lyrics and chord symbols (typed under / above the notes)

    enum WordKind { case lyric, chordSymbol }
    private var field: NSTextField?
    private var fieldKind: WordKind = .lyric
    private var fieldIndex = 0

    /// ⌃L lyrics / ⌃K chord symbols, starting at the selected (or just-typed, or first) note.
    func beginWords(_ kind: WordKind) {
        // Lyrics and chord symbols go with voice 1.
        if voice != 0 { setVoice(0) }
        guard !cur.notes.isEmpty else { return NSSound.beep() }
        var index = target ?? (cursor > 0 ? cursor - 1 : 0)
        if kind == .lyric, cur.notes[index].rest, let next = nextNote(after: index, kind: kind) { index = next }
        openField(kind, at: index)
    }

    private func nextNote(after index: Int, kind: WordKind, backwards: Bool = false) -> Int? {
        var i = index + (backwards ? -1 : 1)
        while cur.notes.indices.contains(i) {
            // Lyrics skip rests; chord symbols can go on any note or rest.
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
        let font = kind == .lyric ? Self.lyricFont : Self.chordFont
        let text = (kind == .lyric ? cur.notes[index].lyric : cur.notes[index].chordSymbol) ?? ""
        let f = NSTextField(string: text)
        f.font = font
        f.isBordered = true
        f.focusRingType = .none
        f.delegate = self
        f.alignment = kind == .lyric ? .center : .left
        let width = max(space * 7, (text as NSString).size(withAttributes: [.font: font]).width + space * 3)
        let yTop = kind == .lyric ? lyricY(p.system) - 2 : staffTop(p.system) - space * 2.2 - max(chordBand, space * 2.4) + space * 0.2
        f.frame = NSRect(x: kind == .lyric ? p.x + space * 0.62 - width / 2 : p.x - space * 0.4, y: yTop, width: width, height: font.pointSize + 8)
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
        let old = kind == .lyric ? cur.notes[i].lyric : cur.notes[i].chordSymbol
        guard (old ?? "") != text else { return }
        editVoice(kind == .lyric ? "Lyrics" : "Chord Symbol") { data in
            if kind == .lyric { data.notes[i].lyric = text.isEmpty ? nil : text } else { data.notes[i].chordSymbol = text.isEmpty ? nil : text }
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
    func toggleTriplet() {
        if let s = selected {
            changeSelected("Triplet") { $0.tuplet = $0.tuplet == true ? nil : true }
            Self.inputTriplet = cur.notes[s].tuplet == true
        } else {
            Self.inputTriplet.toggle()
        }
        NotebookStore.shared.editor.scoreInputChanged += 1
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

    /// The notes marks go on: the selected run, else the selected note (or the one just typed).
    private var markTargets: [Int] {
        if let r = selectedRange { return Array(r) }
        return target.map { [$0] } ?? []
    }

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
        edit(bar == 0 ? "Key Signature" : "Key Change") { s in
            if bar == 0 {
                s.keyFifths = fifths ?? 0
            } else {
                s.setMark(bar) { $0.keyFifths = fifths == before ? nil : fifths }
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
            guard line.notes.indices.contains(from) else { return ScorePlayer.shared.play(score, fromBar: 0, offset: 0, in: self) }
            let bar = line.bar(of: from)
            let onsets = line.onsets
            let barStart = line.measures.indices.contains(bar) ? line.measures[bar].lowerBound : from
            ScorePlayer.shared.play(score, fromBar: bar, offset: onsets[from] - onsets[barStart], in: self)
        }
    }

    override func keyDown(with event: NSEvent) {
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let command = event.modifierFlags.contains(.command)
        switch event.keyCode {
        case 123 where event.modifierFlags.contains(.shift): return extendSelection(by: -1)
        case 124 where event.modifierFlags.contains(.shift): return extendSelection(by: 1)
        case 123: return moveCursor(by: -1)
        case 124: return moveCursor(by: 1)
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
            case "3": return toggleTriplet()
            default: return super.keyDown(with: event)
            }
        }
        guard !command else { return super.keyDown(with: event) }
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
        case "<": toggleHairpin(1)
        case ">": toggleHairpin(-1)
        default: super.keyDown(with: event)
        }
    }

    // MARK: Mouse

    /// The note (head or rest) under a point.
    private func note(at p: NSPoint) -> NoteRef? {
        layoutNotes()
        // The voice being written first (where notes of two voices overlap).
        let ordered = placed.filter { $0.voice == voice } + placed.filter { $0.voice != voice }
        return ordered.first { pl in
            let note = score.forVoice(pl.voice).notes[pl.index]
            let cy = note.rest ? staffTop(pl.system) + space * 2 : y(position: position(note), system: pl.system)
            return NSRect(x: pl.x - space * 0.4, y: cy - space * 1.2, width: space * 2.2, height: space * 2.4).contains(p)
        }.map { NoteRef(voice: $0.voice, index: $0.index) }
    }

    private func system(at y: CGFloat) -> Int {
        let base = score.title.isEmpty ? 0 : titleHeight
        return max(0, min(systemCount - 1, Int((y - base) / systemHeight)))
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
        if event.clickCount == 2, note(at: p) == nil {
            // Double-click on the staff: a note at that pitch.
            let s = system(at: p.y)
            let pos = Int(((staffTop(s) + space * 4 - p.y) / (space / 2)).rounded())
            let d = max(0, min(9 * 7, score.clef.bottomLine + pos))
            cursor = gap(at: p)
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
            if let midi = cur.midi(i) { ScorePlayer.shared.preview(midi) }
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
    private(set) var score: ScoreData
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

    override func contextMenu() -> NSMenu {
        let menu = super.contextMenu()
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(ScorePlayer.shared.isPlaying ? "Stop" : "Play") { [weak self] in self?.staff.togglePlay() })
        menu.addItem(ClosureMenuItem("Score Title…") { [weak self] in self?.editTitle() })
        menu.addItem(ClosureMenuItem("Chord Symbols…  ⌃K") { [weak self] in self?.staff.activate(); self?.staff.beginWords(.chordSymbol) })
        menu.addItem(ClosureMenuItem("Lyrics…  ⌃L") { [weak self] in self?.staff.activate(); self?.staff.beginWords(.lyric) })
        menu.addItem(ClosureMenuItem("Guitar Tab", state: score.showTab == true) { [weak self] in self?.staff.toggleTab() })
        let clef = NSMenuItem(title: "Clef", action: nil, keyEquivalent: "")
        let clefs = NSMenu()
        for c in ScoreData.Clef.allCases {
            clefs.addItem(ClosureMenuItem(c.title, state: score.clef == c) { [weak self] in self?.update({ $0.clef = c }, actionName: "Clef") })
        }
        clef.submenu = clefs
        menu.addItem(clef)
        let key = NSMenuItem(title: "Key Signature", action: nil, keyEquivalent: "")
        let keys = NSMenu()
        for (fifths, name) in ScoreData.keyNames {
            keys.addItem(ClosureMenuItem(name, state: score.keyFifths == fifths) { [weak self] in
                self?.update({ $0.keyFifths = fifths }, actionName: "Key Signature")
            })
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
