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

    /// Length in quarter notes.
    var beats: Double { 4 / Double(duration.rawValue) * (dotted ? 1.5 : 1) }
    /// Steps up from C0 (for staff positions).
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
            return "\(name)\(n.octave) \(length)" + (n.tie ? "~" : "")
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

    /// A single note (heard while entering notes).
    func preview(_ midi: Int) {
        start()
        let key = UInt8(max(0, min(127, midi)))
        sampler.startNote(key, withVelocity: 80, onChannel: 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.sampler.stopNote(key, onChannel: 0) }
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
            let midi = score.midi(i)
            let on = DispatchWorkItem { [weak self] in
                self?.view?.playing = index
                if let midi {
                    let key = UInt8(max(0, min(127, midi)))
                    self?.sampler.startNote(key, withVelocity: 90, onChannel: 0)
                    self?.sounding.insert(key)
                }
            }
            let off = DispatchWorkItem { [weak self] in
                if let midi {
                    let key = UInt8(max(0, min(127, midi)))
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
final class ScoreView: NSView {
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
    private var systemHeight: CGFloat { space * 13 }

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
        return space * (base + (note.dotted ? 0.7 : 0) + (score.showsAccidental(index) ? 1.3 : 0))
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
        (score.title.isEmpty ? 0 : titleHeight) + CGFloat(system) * systemHeight + space * 4.5
    }

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
        drawCaret()
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

    private func drawNotes(ink: NSColor) {
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
            // Stem and flags (beamed notes get their stems with the beam).
            if note.duration != .whole, beamed[p.index] == nil {
                let up = pos < 4
                let sx = up ? p.x + w - 0.6 : p.x + 0.6
                let end = up ? cy - space * 3.5 : cy + space * 3.5
                NSRect(x: sx - 0.6, y: min(cy, end), width: 1.2, height: abs(end - cy)).fill()
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
                let needed = up ? (pt.y - space * 3) - beamY(pt.x) : (pt.y + space * 3) - beamY(pt.x)
                offset = up ? min(offset, needed) : max(offset, needed)
            }
            for pt in points {
                colorFor(pt.i, ink: ink).setFill()
                let end = beamY(pt.x) + offset
                NSRect(x: pt.x - 0.6, y: min(pt.y, end), width: 1.2, height: abs(end - pt.y)).fill()
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
            if let view = window.firstResponder as? NSView, view !== self, view.isDescendant(of: canvas) {
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
        guard !command else { return super.keyDown(with: event) }
        if let letter = chars.first, let step = ["c", "d", "e", "f", "g", "a", "b"].firstIndex(of: String(letter)) {
            return insert(step: step)
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
