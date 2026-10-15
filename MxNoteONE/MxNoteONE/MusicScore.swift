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

    /// Length in quarter notes.
    var beats: Double { 4 / Double(duration.rawValue) * (dotted ? 1.5 : 1) }
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
    /// A guitar TAB staff under the music.
    var showTab: Bool?

    /// A bar's length in quarter notes.
    var measureLength: Double { Double(beats) * 4 / Double(beatUnit) }

    static let sharpOrder = [3, 0, 4, 1, 5, 2, 6]   // F C G D A E B
    static let flatOrder = [6, 2, 5, 1, 4, 0, 3]    // B E A D G C F

    /// The key signature's sharp (1) or flat (-1) on a step.
    func keyAlter(_ step: Int) -> Int {
        if keyFifths > 0, Self.sharpOrder.prefix(keyFifths).contains(step) { return 1 }
        if keyFifths < 0, Self.flatOrder.prefix(-keyFifths).contains(step) { return -1 }
        return 0
    }

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
        if let alter = note.alter { return alter }
        return alterBefore(index) ?? keyAlter(note.step)
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
        guard !note.rest, let alter = note.alter else { return false }
        return alter != (alterBefore(index) ?? keyAlter(note.step))
    }

    /// Every pitch a note sounds (the note and its chord tones), as MIDI numbers.
    func midis(_ index: Int) -> [Int] {
        guard let main = midi(index) else { return [] }
        let tones = (notes[index].chord ?? []).map { Self.midi(step: $0.step, octave: $0.octave, alter: $0.alter ?? keyAlter($0.step)) }
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

    var hasChordSymbols: Bool { notes.contains { !($0.chordSymbol ?? "").isEmpty } }
    var hasLyrics: Bool { notes.contains { !($0.lyric ?? "").isEmpty } }

    /// A short description (for exports and search).
    var summary: String {
        let key = Self.keyNames.first { $0.0 == keyFifths }?.1 ?? ""
        return "\(title.isEmpty ? "Music score" : title) — \(measures.count) bars, \(beats)/\(beatUnit), \(key), ♩ = \(tempo)"
    }

    /// The melody in letter names (for exports): C4 q, D#4 8., r h…
    var noteNames: String {
        notes.enumerated().map { i, n in
            let length = ["", "w", "h", "", "q", "", "", "", "8", "", "", "", "", "", "", "", "16"][n.duration.rawValue] + (n.dotted ? "." : "")
            if n.rest { return "r" + length }
            let alter = soundingAlter(i)
            let name = ["C", "D", "E", "F", "G", "A", "B"][n.step] + (alter > 0 ? "♯" : alter < 0 ? "♭" : "")
            let tones = (n.chord ?? []).map { t in
                ["C", "D", "E", "F", "G", "A", "B"][t.step] + ((t.alter ?? keyAlter(t.step)) > 0 ? "♯" : (t.alter ?? keyAlter(t.step)) < 0 ? "♭" : "") + "\(t.octave)"
            }
            let symbol = (n.chordSymbol ?? "").isEmpty ? "" : "[\(n.chordSymbol!)] "
            let lyric = (n.lyric ?? "").isEmpty ? "" : " “\(n.lyric!)”"
            return symbol + "\(name)\(n.octave)" + tones.map { "+" + $0 }.joined() + " \(length)" + (n.tie ? "~" : "") + lyric
        }.joined(separator: " · ")
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

    /// Plays from a note to the end, highlighting each note in the view.
    func play(_ score: ScoreData, from first: Int, in view: ScoreView) {
        stop()
        guard first < score.notes.count else { return }
        start()
        self.view = view
        let secondsPerBeat = 60 / Double(max(20, score.tempo))
        var time = 0.0
        var i = first
        while i < score.notes.count {
            var length = score.notes[i].beats
            var last = i
            // Tied notes sound as one.
            while score.notes[last].tie, last + 1 < score.notes.count, !score.notes[last + 1].rest,
                  score.midi(last + 1) == score.midi(i) {
                last += 1
                length += score.notes[last].beats
            }
            let index = i
            let keys = score.midis(i).map { UInt8(max(0, min(127, $0))) }
            let on = DispatchWorkItem { [weak self] in
                self?.view?.playing = index
                for key in keys {
                    self?.sampler.startNote(key, withVelocity: 90, onChannel: 0)
                    self?.sounding.insert(key)
                }
            }
            let off = DispatchWorkItem { [weak self] in
                for key in keys {
                    self?.sampler.stopNote(key, onChannel: 0)
                    self?.sounding.remove(key)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + time, execute: on)
            DispatchQueue.main.asyncAfter(deadline: .now() + time + length * secondsPerBeat * 0.95, execute: off)
            work += [on, off]
            time += length * secondsPerBeat
            i = last + 1
        }
        let end = DispatchWorkItem { [weak self] in self?.stop() }
        DispatchQueue.main.asyncAfter(deadline: .now() + time + 0.05, execute: end)
        work.append(end)
        view.needsDisplay = true
        NotebookStore.shared.editor.scorePlaying = true
    }

    func stop() {
        work.forEach { $0.cancel() }
        work = []
        for key in sounding { sampler.stopNote(key, onChannel: 0) }
        sounding = []
        view?.playing = nil
        view = nil
        NotebookStore.shared.editor.scorePlaying = false
    }
}

// MARK: - The staff view

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
    private(set) var cursor = 0
    /// The note just typed: ↑ ↓, accidentals and ties act on it, while number keys and . set the next note's length.
    private(set) var lastEntered: Int?
    /// The note sounding during playback.
    var playing: Int? {
        didSet { if oldValue != playing { needsDisplay = true } }
    }

    /// The length and dot for new notes (shared with the Score ribbon tab).
    static var inputDuration: ScoreNote.Duration = .quarter
    static var inputDotted = false

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { !isExport }

    // MARK: Layout

    static let space: CGFloat = 8
    private var space: CGFloat { Self.space }
    private let titleHeight: CGFloat = 26
    private var chordBand: CGFloat { score.hasChordSymbols ? space * 2.6 : 0 }
    private var lyricBand: CGFloat { score.hasLyrics ? space * 2.8 : 0 }
    private var tabBand: CGFloat { score.showTab == true ? space * 10 : 0 }
    private var systemHeight: CGFloat { space * 13 + chordBand + lyricBand + tabBand }
    /// TAB lines' spacing.
    private var tabGap: CGFloat { space * 1.3 }

    static let lyricFont = NSFont.systemFont(ofSize: 12)
    static let chordFont = NSFont.systemFont(ofSize: 13, weight: .semibold)

    struct Placed {
        let index: Int
        let x: CGFloat
        let system: Int
    }

    private(set) var placed: [Placed] = []
    /// Where the caret goes for each cursor position (x, system).
    private var caretSpots: [(x: CGFloat, system: Int)] = []
    /// Bar lines (x, system), and where each system's notes start.
    private var barLines: [(x: CGFloat, system: Int, final: Bool)] = []
    private var systemCount = 1
    private var systemStarts: [CGFloat] = []

    /// The height the score needs at a width.
    func neededHeight() -> CGFloat {
        layoutNotes()
        return (score.title.isEmpty ? 0 : titleHeight) + CGFloat(systemCount) * systemHeight + space
    }

    private func width(of note: ScoreNote, index: Int) -> CGFloat {
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
            if chord.contains(where: { $0.alter != nil && $0.alter != score.keyAlter($0.step) }) { width += space * 1.2 }
        }
        // Words and chord names don't run into the next note.
        if let lyric = note.lyric, !lyric.isEmpty {
            width = max(width, (lyric as NSString).size(withAttributes: [.font: Self.lyricFont]).width + space * 1.2)
        }
        if let symbol = note.chordSymbol, !symbol.isEmpty {
            width = max(width, (symbol as NSString).size(withAttributes: [.font: Self.chordFont]).width + space * 1.2)
        }
        return width
    }

    private func headerWidth(system: Int) -> CGFloat {
        space * (4.2 + CGFloat(abs(score.keyFifths)) * 1.05 + (system == 0 ? 2.8 : 0) + 0.8)
    }

    private func layoutNotes() {
        placed = []
        caretSpots = []
        barLines = []
        systemStarts = []
        let usable = max(bounds.width - space * 2, space * 20)
        let measures = score.measures
        // Each bar's natural width.
        let widths: [CGFloat] = measures.map { bar in
            bar.isEmpty ? space * 8 : bar.reduce(space * 1.2) { $0 + width(of: score.notes[$1], index: $1) }
        }
        // Bars into systems (lines).
        var systems: [[Int]] = [[]]
        var used = headerWidth(system: 0)
        for (m, w) in widths.enumerated() {
            if !systems[systems.count - 1].isEmpty, used + w > usable {
                systems.append([])
                used = headerWidth(system: systems.count - 1)
            }
            systems[systems.count - 1].append(m)
            used += w
        }
        systemCount = systems.count
        for (s, bars) in systems.enumerated() {
            let start = space + headerWidth(system: s)
            systemStarts.append(start)
            let natural = bars.reduce(0) { $0 + widths[$1] }
            // Full lines are spread to the width (not the last one).
            let stretch = s < systems.count - 1 && natural > 0 ? max(1, (usable - headerWidth(system: s)) / natural) : 1
            var x = start
            for m in bars {
                let bar = measures[m]
                var nx = x + space * 1.2 * stretch
                for i in bar {
                    caretSpots.append((nx - space * 0.9, s))
                    let accidental = score.showsAccidental(i) ? space * 1.3 : 0
                    placed.append(Placed(index: i, x: nx + accidental, system: s))
                    nx += width(of: score.notes[i], index: i) * stretch
                }
                x += widths[m] * stretch
                let last = m == measures.count - 1
                barLines.append((x, s, last))
            }
        }
        // The caret after the last note.
        if let lastPlaced = placed.last {
            let note = score.notes[lastPlaced.index]
            caretSpots.append((lastPlaced.x + width(of: note, index: lastPlaced.index) - space * 1.2, lastPlaced.system))
        } else {
            caretSpots.append(((systemStarts.first ?? space * 6) + space, 0))
        }
    }

    /// The top of a system's staff.
    private func staffTop(_ system: Int) -> CGFloat {
        (score.title.isEmpty ? 0 : titleHeight) + CGFloat(system) * systemHeight + space * 4.5 + chordBand
    }

    private func lyricY(_ system: Int) -> CGFloat { staffTop(system) + space * 4 + space * 3.4 }

    /// The TAB staff's top line (high E).
    private func tabTop(_ system: Int) -> CGFloat { staffTop(system) + space * 4 + space * 4.2 + lyricBand }

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
            if bar.final {
                NSRect(x: bar.x - space * 0.9, y: top, width: 1, height: bottom - top).fill()
                NSRect(x: bar.x - space * 0.5, y: top, width: 3.5, height: bottom - top).fill()
            } else {
                NSRect(x: bar.x - 0.5, y: top, width: 1, height: bottom - top).fill()
            }
        }
        drawNotes(ink: ink)
        drawWords(ink: ink)
        if score.showTab == true { drawTab(ink: ink) }
        drawCaret()
    }

    /// Chord symbols above the staff, lyrics under it (with hyphens between syllables).
    private func drawWords(ink: NSColor) {
        for (k, p) in placed.enumerated() {
            let note = score.notes[p.index]
            let color = colorFor(p.index, ink: ink)
            if let symbol = note.chordSymbol, !symbol.isEmpty {
                let attrs: [NSAttributedString.Key: Any] = [.font: Self.chordFont, .foregroundColor: color]
                (symbol as NSString).draw(at: NSPoint(x: p.x - space * 0.2, y: staffTop(p.system) - space * 2 - chordBand + space * 0.2),
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
            NSRect(x: bar.x - 0.5, y: tabTop(bar.system), width: bar.final ? 3 : 1, height: tabGap * 5).fill()
        }
        for p in placed where !score.notes[p.index].rest {
            let color = colorFor(p.index, ink: ink)
            let attrs: [NSAttributedString.Key: Any] = [.font: fretFont, .foregroundColor: color]
            for spot in score.tab(p.index) {
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
        // Key signature.
        var x = space * 5.2
        let sharps = score.keyFifths > 0
        let order = sharps ? ScoreData.sharpOrder : ScoreData.flatOrder
        // Where each accidental sits (treble: F5 C5 G5 D5 A4 E5 B4 / B4 E5 A4 D5 G4 C5 F4; bass two octaves lower).
        let trebleSharps = [5 * 7 + 3, 5 * 7 + 0, 5 * 7 + 4, 5 * 7 + 1, 4 * 7 + 5, 5 * 7 + 2, 4 * 7 + 6]
        let trebleFlats = [4 * 7 + 6, 5 * 7 + 2, 4 * 7 + 5, 5 * 7 + 1, 4 * 7 + 4, 5 * 7 + 0, 4 * 7 + 3]
        for k in 0..<abs(score.keyFifths) {
            var d = (sharps ? trebleSharps : trebleFlats)[k]
            if score.clef == .bass { d -= 14 }
            _ = order
            drawAccidental(sharps ? 1 : -1, x: x, y: y(position: d - score.clef.bottomLine, system: system), ink: ink)
            x += space * 1.05
        }
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
    private func beamGroups() -> [[Int]] {
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

    private func drawNotes(ink: NSColor) {
        stemSpans = [:]
        let groups = beamGroups()
        var beamed: [Int: (group: [Int], up: Bool)] = [:]
        for g in groups {
            let average = g.reduce(0) { $0 + position(score.notes[$1]) } / g.count
            for i in g { beamed[i] = (g, average < 4) }
        }
        for p in placed {
            let note = score.notes[p.index]
            let color = colorFor(p.index, ink: ink)
            if note.rest {
                drawRest(note, x: p.x, system: p.system, color: color)
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
            let up = beamed[p.index]?.up ?? (allPositions.reduce(0, +) / allPositions.count < 4)
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
                    if let alter = tone.alter, alter != score.keyAlter(tone.step) {
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
                colorFor(pt.i, ink: ink).setFill()
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

    private func colorFor(_ index: Int, ink: NSColor) -> NSColor {
        if index == playing { return .systemOrange }
        if !isExport, index == selected || index == lastEntered, ScoreView.active === self { return .controlAccentColor }
        return ink
    }

    private func ledger(x: CGFloat, y: CGFloat) {
        NSRect(x: x - space * 0.45, y: y - 0.6, width: space * 2.15, height: 1.2).fill()
    }

    private func drawRest(_ note: ScoreNote, x: CGFloat, system: Int, color: NSColor) {
        let top = staffTop(system)
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
        selected = index.flatMap { score.notes.indices.contains($0) ? $0 : nil }
        lastEntered = nil
        if let selected { cursor = selected + 1 }
        needsDisplay = true
    }

    /// The note commands act on: the selected one, else the one just typed.
    private var target: Int? {
        let i = selected ?? lastEntered
        return i.flatMap { score.notes.indices.contains($0) ? $0 : nil }
    }

    /// Adds a note (or rest) after the cursor; a note goes in the octave nearest the note before it.
    func insert(step: Int?, octave: Int? = nil) {
        var note = ScoreNote(duration: Self.inputDuration, dotted: Self.inputDotted, rest: step == nil)
        if let step {
            note.step = step
            if let octave {
                note.octave = octave
            } else {
                let previous = score.notes[..<min(cursor, score.notes.count)].last { !$0.rest }
                let reference = previous?.diatonic ?? (score.clef == .treble ? 4 * 7 + 6 : 3 * 7 + 1)
                var best = 4
                for o in 1...7 where abs(o * 7 + step - reference) < abs(best * 7 + step - reference) { best = o }
                note.octave = best
            }
        }
        let at = min(cursor, score.notes.count)
        edit(step == nil ? "Add Rest" : "Add Note") { $0.notes.insert(note, at: at) }
        // Keep entering after it.
        selected = nil
        lastEntered = at
        cursor = at + 1
        needsDisplay = true
        if let midi = score.midi(at) { ScorePlayer.shared.preview(midi) }
    }

    private func changeSelected(_ name: String, _ change: (inout ScoreNote) -> Void) {
        guard let i = target else { return NSSound.beep() }
        edit(name) { change(&$0.notes[i]) }
        if let midi = score.midi(i) { ScorePlayer.shared.preview(midi) }
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
            Self.inputDotted = score.notes[s].dotted
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
        guard let i = target, !score.notes[i].rest else { return NSSound.beep() }
        let note = score.notes[i]
        let top = ([note.diatonic] + (note.chord ?? []).map(\.diatonic)).max()!
        var octave = top / 7
        if octave * 7 + step <= top { octave += 1 }
        edit("Add Chord Note") { $0.notes[i].chord = ($0.notes[i].chord ?? []) + [ChordTone(step: step, octave: octave)] }
        ScorePlayer.shared.preview(score.midis(i))
    }

    func clearChordTones() {
        changeSelected("Remove Chord Notes") { $0.chord = nil }
    }

    /// The selected note onto the next higher (+1) or lower (-1) guitar string, where it can be played.
    func moveString(by delta: Int) {
        guard let i = target, !score.notes[i].rest, let current = score.tab(i).first?.string else { return NSSound.beep() }
        let shift = score.clef == .treble ? 12 : 0
        guard let pitch = score.midi(i).map({ $0 - shift }) else { return }
        var string = current + delta
        while ScoreData.tuning.indices.contains(string) {
            let fret = pitch - ScoreData.tuning[string]
            if fret >= 0 && fret <= 24 {
                let chosen = string
                edit("Guitar String") { $0.notes[i].tabString = chosen }
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
        guard !score.notes.isEmpty else { return NSSound.beep() }
        var index = target ?? (cursor > 0 ? cursor - 1 : 0)
        if kind == .lyric, score.notes[index].rest, let next = nextNote(after: index, kind: kind) { index = next }
        openField(kind, at: index)
    }

    private func nextNote(after index: Int, kind: WordKind, backwards: Bool = false) -> Int? {
        var i = index + (backwards ? -1 : 1)
        while score.notes.indices.contains(i) {
            // Lyrics skip rests; chord symbols can go on any note or rest.
            if kind == .chordSymbol || !score.notes[i].rest { return i }
            i += backwards ? -1 : 1
        }
        return nil
    }

    private func openField(_ kind: WordKind, at index: Int) {
        field?.removeFromSuperview()
        layoutNotes()
        guard let p = placed.first(where: { $0.index == index }) else { return }
        fieldKind = kind
        fieldIndex = index
        selected = index
        lastEntered = nil
        cursor = index + 1
        let font = kind == .lyric ? Self.lyricFont : Self.chordFont
        let text = (kind == .lyric ? score.notes[index].lyric : score.notes[index].chordSymbol) ?? ""
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
        guard score.notes.indices.contains(i) else { return }
        let old = kind == .lyric ? score.notes[i].lyric : score.notes[i].chordSymbol
        guard (old ?? "") != text else { return }
        edit(kind == .lyric ? "Lyrics" : "Chord Symbol") { data in
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
            edit("Delete Note") { $0.notes.remove(at: i) }
            select(i > 0 ? i - 1 : nil)
            if selected == nil { cursor = 0 }
        } else if cursor > 0 {
            let i = cursor - 1
            edit("Delete Note") { $0.notes.remove(at: i) }
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
            if next < 0 { selected = nil; cursor = 0 } else if next >= score.notes.count { selected = nil; cursor = score.notes.count } else { select(next) }
        } else {
            let next = cursor + delta
            if delta < 0, cursor > 0 { select(cursor - 1) } else if delta > 0, cursor < score.notes.count { select(cursor) } else { cursor = max(0, min(score.notes.count, next)) }
        }
        needsDisplay = true
    }

    func togglePlay() {
        if ScorePlayer.shared.isPlaying {
            ScorePlayer.shared.stop()
        } else {
            let from = selected ?? (cursor < score.notes.count ? cursor : 0)
            ScorePlayer.shared.play(score, from: from, in: self)
        }
    }

    override func keyDown(with event: NSEvent) {
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let command = event.modifierFlags.contains(.command)
        switch event.keyCode {
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
        if event.modifierFlags.contains(.control) {
            switch chars {
            case "k": return beginWords(.chordSymbol)
            case "l": return beginWords(.lyric)
            default: return super.keyDown(with: event)
            }
        }
        guard !command else { return super.keyDown(with: event) }
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
        default: super.keyDown(with: event)
        }
    }

    // MARK: Mouse

    /// The note (head or rest) under a point.
    private func note(at p: NSPoint) -> Int? {
        layoutNotes()
        return placed.first { pl in
            let note = score.notes[pl.index]
            let cy = note.rest ? staffTop(pl.system) + space * 2 : y(position: position(note), system: pl.system)
            return NSRect(x: pl.x - space * 0.4, y: cy - space * 1.2, width: space * 2.2, height: space * 2.4).contains(p)
        }?.index
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
        if let i = note(at: p) {
            select(i)
            if let midi = score.midi(i) { ScorePlayer.shared.preview(midi) }
            // Drag up or down to change the pitch.
            guard !score.notes[i].rest, let window else { return }
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

    override func menu(for event: NSEvent) -> NSMenu? { owner?.contextMenu() }
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
        let time = NSMenuItem(title: "Time Signature", action: nil, keyEquivalent: "")
        let times = NSMenu()
        for (b, u) in ScoreData.times {
            times.addItem(ClosureMenuItem("\(b)/\(u)", state: score.beats == b && score.beatUnit == u) { [weak self] in
                self?.update({ $0.beats = b; $0.beatUnit = u }, actionName: "Time Signature")
            })
        }
        time.submenu = times
        menu.addItem(time)
        let tempo = NSMenuItem(title: "Tempo (♩ = \(score.tempo))", action: nil, keyEquivalent: "")
        let tempos = NSMenu()
        for t in [60, 72, 80, 90, 100, 112, 120, 132, 144, 160] {
            tempos.addItem(ClosureMenuItem("♩ = \(t)", state: score.tempo == t) { [weak self] in self?.update({ $0.tempo = t }, actionName: "Tempo") })
        }
        tempo.submenu = tempos
        menu.addItem(tempo)
        menu.addItem(ClosureMenuItem("Copy Score as Picture") { [weak self] in self?.copyPicture() })
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
