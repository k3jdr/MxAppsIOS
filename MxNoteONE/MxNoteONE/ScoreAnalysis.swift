//
//  ScoreAnalysis.swift
//  MxNoteONE
//
//  Figured bass and Roman numeral analysis. Figures are typed under a note (⌃F) — "6", "64" or "6/4", "7/♯",
//  "♯6", "4 3" — and drawn stacked, top to bottom; Roman numerals (⌃R) — "I", "V7", "ii6", "V65/V", "vii°7",
//  "♭VI", "N6", "G: I64" — are drawn as an analysis does, with inversion figures stacked beside the numeral.
//
//  Analyze works them out from the music: at each note of the lowest staff, the notes sounding on every staff
//  (in concert pitch) are named as a chord — root, quality, inversion — in the key (major or minor, from how the
//  music begins and ends), with secondary dominants (V/V, vii°7/V), the Neapolitan (N6) and borrowed chords
//  (♭VI); and the figured bass from the intervals over the bass, with the accidentals the key doesn't give.
//

import AppKit

// MARK: - Figured bass

enum FiguredBass {
    /// One figure: an accidental before it, the number, and what comes after (♯ ♭ ♮, + raised, \ slashed).
    struct Row: Equatable {
        var prefix = ""
        var number = ""
        var suffix = ""
        /// "_": the figure above is held on (a line to the next note).
        var extends = false
        var text: String { prefix + number + suffix }
    }

    static let font = NSFont(name: "TimesNewRomanPSMT", size: 13) ?? .systemFont(ofSize: 12)
    static let rowHeight: CGFloat = 12.5

    /// # b n typed for ♯ ♭ ♮.
    static func glyphs(_ s: String) -> String {
        s.replacingOccurrences(of: "#", with: "♯").replacingOccurrences(of: "b", with: "♭").replacingOccurrences(of: "n", with: "♮")
    }

    /// The figures top to bottom: rows split by "/", "," or spaces, or a run of digits ("64", "♯642") one per digit.
    static func rows(_ text: String) -> [Row] {
        let t = glyphs(text.trimmingCharacters(in: .whitespaces))
        guard !t.isEmpty else { return [] }
        var chunks = t.split(whereSeparator: { "/, \n".contains($0) }).map(String.init)
        if chunks.count == 1 { chunks = splitDigits(chunks[0]) }
        return chunks.map(row)
    }

    /// "♯64" → "♯6", "4": an accidental goes with the number after it; + and \ with the one before.
    private static func splitDigits(_ s: String) -> [String] {
        var tokens: [String] = [], current = "", hasDigit = false
        for ch in s {
            if ch.isNumber {
                if hasDigit {
                    // Accidentals after the last number belong to this one.
                    var moved = ""
                    while let last = current.last, "♯♭♮".contains(last) { moved = String(last) + moved; current.removeLast() }
                    tokens.append(current)
                    current = moved + String(ch)
                } else {
                    current.append(ch)
                }
                hasDigit = true
            } else {
                current.append(ch)
            }
        }
        tokens.append(current)
        return tokens.filter { !$0.isEmpty }
    }

    private static func row(_ s: String) -> Row {
        if s == "_" || s == "-" { return Row(extends: true) }
        var r = Row()
        var seenNumber = false
        for ch in s {
            if ch.isNumber { r.number.append(ch); seenNumber = true } else if seenNumber { r.suffix.append(ch) } else { r.prefix.append(ch) }
        }
        return r
    }

    /// Draws the figures centred on `x`, the first row's top at `top`; `next` is where the next note is (for "_").
    static func draw(_ text: String, centre x: CGFloat, top: CGFloat, next: CGFloat?, color: NSColor) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        for (k, r) in rows(text).enumerated() {
            let y = top + CGFloat(k) * rowHeight
            if r.extends {
                color.setFill()
                NSRect(x: x - 3, y: y + rowHeight * 0.55, width: max(6, (next ?? x + 20) - x - 2), height: 1).fill()
                continue
            }
            // A slashed figure (6\): the number with a stroke through it.
            let slashed = r.suffix.contains("\\")
            let shown = r.prefix + r.number + r.suffix.replacingOccurrences(of: "\\", with: "")
            let size = (shown as NSString).size(withAttributes: attrs)
            let left = x - size.width / 2
            (shown as NSString).draw(at: NSPoint(x: left, y: y), withAttributes: attrs)
            if slashed, !r.number.isEmpty {
                let before = (r.prefix as NSString).size(withAttributes: attrs).width
                let w = (r.number as NSString).size(withAttributes: attrs).width
                color.setStroke()
                let stroke = NSBezierPath()
                stroke.move(to: NSPoint(x: left + before - 1, y: y + size.height * 0.85))
                stroke.line(to: NSPoint(x: left + before + w + 1, y: y + size.height * 0.2))
                stroke.lineWidth = 1.1
                stroke.stroke()
            }
        }
    }
}

// MARK: - Roman numerals

enum RomanNumeral {
    /// One numeral of a label (V65/V has two): an accidental, the numeral, its quality (° ø +) and figures.
    struct Part: Equatable {
        var accidental = ""
        var numeral = ""
        var quality = ""
        var figures: [String] = []
    }

    static let font = NSFont(name: "TimesNewRomanPSMT", size: 16) ?? .systemFont(ofSize: 15)
    static let smallFont = NSFont(name: "TimesNewRomanPSMT", size: 10.5) ?? .systemFont(ofSize: 10)

    /// A label's key ("G" of "G: I6") and its numerals.
    static func parse(_ text: String) -> (key: String?, parts: [Part]) {
        var s = text.trimmingCharacters(in: .whitespaces)
        var key: String?
        if let colon = s.firstIndex(of: ":") {
            key = String(s[..<colon]).trimmingCharacters(in: .whitespaces)
            s = String(s[s.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        // The key's letter stays as typed ("b:" is B minor); # and b after it are ♯ and ♭.
        let shownKey = key.flatMap { k -> String? in
            guard let first = k.first else { return nil }
            return String(first) + String(k.dropFirst()).replacingOccurrences(of: "#", with: "♯").replacingOccurrences(of: "b", with: "♭")
        }
        return (shownKey, s.split(separator: "/").map { part(String($0)) })
    }

    private static func part(_ s: String) -> Part {
        var p = Part()
        var chars = Array(s)
        var i = 0
        if i < chars.count, "b♭#♯".contains(chars[i]) {
            p.accidental = "b♭".contains(chars[i]) ? "♭" : "♯"
            i += 1
        }
        // The numeral, or a chord's name (N, It, Fr, Ger, Cad).
        let rest = String(chars[i...])
        if let name = ["Ger", "Fr", "It", "Cad", "N"].first(where: { rest.hasPrefix($0) }), !(name == "N" && rest.count > 1 && chars[i + 1].isLetter) {
            p.numeral = name
            i += name.count
        } else {
            while i < chars.count, "IViv".contains(chars[i]) { p.numeral.append(chars[i]); i += 1 }
        }
        chars = Array(chars[i...])
        var digits = ""
        for ch in chars {
            switch ch {
            case "o", "°": p.quality = "°"
            case "ø", "%": p.quality = "ø"
            case "+": p.quality = "+"
            default: digits.append(ch)
            }
        }
        // Figures: a run of digits, one per row ("65" → 6 over 5); accidentals go with the number after them.
        var current = ""
        for ch in FiguredBass.glyphs(digits) {
            current.append(ch)
            if ch.isNumber { p.figures.append(current); current = "" }
        }
        if !current.isEmpty { p.figures.append(current) }
        return p
    }

    /// Draws a label with its first numeral centred on `centre` (a key, "C:", to the left of it).
    static func draw(_ text: String, centre: CGFloat, top: CGFloat, color: NSColor) {
        let big: [NSAttributedString.Key: Any] = [.font: font]
        let accidental: [NSAttributedString.Key: Any] = [.font: NSFont(name: "TimesNewRomanPSMT", size: 13) ?? smallFont]
        let (key, parts) = parse(text)
        let keyWidth = key.map { ("\($0):" as NSString).size(withAttributes: big).width + 5 } ?? 0
        let first = parts.first ?? Part()
        let core = (first.accidental.isEmpty ? 0 : (first.accidental as NSString).size(withAttributes: accidental).width + 1.5)
            + (first.numeral as NSString).size(withAttributes: big).width
        draw(text, x: centre - core / 2 - keyWidth, top: top, color: color)
    }

    /// Draws a label from `x` with its numerals' baseline area starting at `top`. Returns its width.
    @discardableResult
    static func draw(_ text: String, x: CGFloat, top: CGFloat, color: NSColor) -> CGFloat {
        let big: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let small: [NSAttributedString.Key: Any] = [.font: smallFont, .foregroundColor: color]
        let (key, parts) = parse(text)
        var cx = x
        if let key {
            let label = "\(key):" as NSString
            label.draw(at: NSPoint(x: cx, y: top), withAttributes: big)
            cx += label.size(withAttributes: big).width + 5
        }
        for (k, p) in parts.enumerated() {
            if k > 0 {
                ("/" as NSString).draw(at: NSPoint(x: cx, y: top), withAttributes: big)
                cx += ("/" as NSString).size(withAttributes: big).width
            }
            if !p.accidental.isEmpty {
                let a = p.accidental as NSString
                a.draw(at: NSPoint(x: cx, y: top + 1), withAttributes: small.merging([.font: NSFont(name: "TimesNewRomanPSMT", size: 13) ?? smallFont]) { $1 })
                cx += a.size(withAttributes: small).width + 1.5
            }
            let n = p.numeral as NSString
            n.draw(at: NSPoint(x: cx, y: top), withAttributes: big)
            cx += n.size(withAttributes: big).width
            // Quality (° ø +) high, then the figures: one high, two stacked.
            var extra: CGFloat = 0
            if !p.quality.isEmpty {
                let q = p.quality as NSString
                q.draw(at: NSPoint(x: cx + 0.5, y: top - 3), withAttributes: small)
                extra = q.size(withAttributes: small).width + 0.5
            }
            if p.figures.count == 1 {
                let f = p.figures[0] as NSString
                f.draw(at: NSPoint(x: cx + extra + 0.5, y: top - 3), withAttributes: small)
                extra += f.size(withAttributes: small).width + 0.5
            } else if p.figures.count >= 2 {
                let upper = p.figures[0] as NSString, lower = p.figures[1] as NSString
                upper.draw(at: NSPoint(x: cx + extra + 0.5, y: top - 4), withAttributes: small)
                lower.draw(at: NSPoint(x: cx + extra + 0.5, y: top + 7), withAttributes: small)
                extra += max(upper.size(withAttributes: small).width, lower.size(withAttributes: small).width) + 0.5
            }
            cx += extra
        }
        return cx - x
    }
}

// MARK: - Naming chords

/// A chord named from its notes.
struct NamedChord: Equatable {
    enum Quality: String { case major, minor, diminished, augmented, dominant7, major7, minor7, halfDiminished7, diminished7 }
    /// The root's letter (0 = C) and alteration.
    let rootStep: Int
    let rootAlter: Int
    let quality: Quality
    /// Which chord note is in the bass: 0 root, 1 third, 2 fifth, 3 seventh.
    let inversion: Int

    var isSeventh: Bool { [.dominant7, .major7, .minor7, .halfDiminished7, .diminished7].contains(quality) }
    var isMinorish: Bool { [.minor, .diminished, .minor7, .halfDiminished7, .diminished7].contains(quality) }
    var mark: String {
        switch quality {
        case .diminished, .diminished7: "°"
        case .halfDiminished7: "ø"
        case .augmented: "+"
        default: ""
        }
    }
    /// The figures beside the numeral for the inversion (a triad's 6 and 64; a seventh's 7, 65, 43, 42).
    var figures: String {
        isSeventh ? ["7", "65", "43", "42"][min(3, inversion)] : ["", "6", "64"][min(2, inversion)]
    }

    /// Semitones and letter steps above the root of the root, 3rd, 5th and (for sevenths) 7th.
    static let templates: [(Quality, [Int])] = [
        (.major, [0, 4, 7]), (.minor, [0, 3, 7]), (.diminished, [0, 3, 6]), (.augmented, [0, 4, 8]),
        (.dominant7, [0, 4, 7, 10]), (.major7, [0, 4, 7, 11]), (.minor7, [0, 3, 7, 10]), (.halfDiminished7, [0, 3, 6, 10]), (.diminished7, [0, 3, 6, 9]),
    ]

    /// A pitch sounding: line or space (steps from C0), its alteration, and MIDI number.
    struct Pitch { let diatonic: Int; let alter: Int; let midi: Int }

    /// The chord the pitches make, if they make one: every note a chord note (spelt as a stack of 3rds), the root
    /// and 3rd there, and the 5th too unless it's a seventh chord. The fullest reading wins, then the bass as root.
    static func name(_ pitches: [Pitch]) -> NamedChord? {
        guard let bass = pitches.min(by: { $0.midi < $1.midi }) else { return nil }
        // One spelling per pitch class.
        var notes: [Int: Pitch] = [:]
        for p in pitches.sorted(by: { $0.midi < $1.midi }) { let pc = ((p.midi % 12) + 12) % 12; if notes[pc] == nil { notes[pc] = p } }
        guard notes.count >= 3 else { return nil }
        var best: (chord: NamedChord, score: Int)?
        for root in notes.values {
            let rootPC = ((root.midi % 12) + 12) % 12
            for (quality, template) in templates {
                var members: [Int: Int] = [:]   // pitch class → chord member (0 root … 3 seventh)
                var fits = true
                for (pc, p) in notes {
                    let semis = ((pc - rootPC) % 12 + 12) % 12
                    let steps = ScoreData.mod7(p.diatonic - root.diatonic)
                    guard let m = template.firstIndex(of: semis), steps == [0, 2, 4, 6][m] else { fits = false; break }
                    members[pc] = m
                }
                guard fits else { continue }
                let have = Set(members.values)
                guard have.contains(0), have.contains(1), template.count == 4 ? have.contains(3) : have.contains(2) else { continue }
                let bassPC = ((bass.midi % 12) + 12) % 12
                let inversion = members[bassPC] ?? 0
                let chord = NamedChord(rootStep: ScoreData.mod7(root.diatonic), rootAlter: root.alter, quality: quality, inversion: inversion)
                let score = have.count * 10 + (have.count == template.count ? 5 : 0) + (inversion == 0 ? 2 : 0)
                if best == nil || score > best!.score { best = (chord, score) }
            }
        }
        return best?.chord
    }
}

// MARK: - Analysis

extension ScoreData {
    /// The staff figured bass and Roman numerals go under: the lowest that isn't drums.
    var analysisStaff: Int { (0..<staffCount).last { forStaff($0).clef != .percussion } ?? 0 }

    /// A key's tonic (letter and alteration): the major key, or its relative minor.
    static func tonic(fifths: Int, minor: Bool) -> (step: Int, alter: Int) {
        let step = mod7(4 * fifths - (minor ? 2 : 0))
        return (step, keyAlter(step, fifths: fifths))
    }

    /// "C", "F♯", "B♭" — a key's name ("a", "f♯" for minor keys, as analyses write them).
    static func keyName(fifths: Int, minor: Bool) -> String {
        let t = tonic(fifths: fifths, minor: minor)
        let name = ["C", "D", "E", "F", "G", "A", "B"][t.step] + (t.alter > 0 ? "♯" : t.alter < 0 ? "♭" : "")
        return minor ? name.lowercased() : name
    }

    /// The pitches each staff and voice sounds, as spans of time (quarter notes from the start, bar by bar), in
    /// concert pitch; drums and slashes left out.
    func soundingSpans() -> [(start: Double, end: Double, pitches: [NamedChord.Pitch])] {
        var concert = self
        concert.concertPitch = true
        var spans: [(Double, Double, [NamedChord.Pitch])] = []
        for s in 0..<staffCount {
            let st = concert.shown(s)
            guard st.clef != .percussion else { continue }
            for v in 0...(st.voices?.count ?? 0) {
                let line = st.forVoice(v)
                for (b, bar) in line.measures.enumerated() {
                    var t = Double(b) * measureLength
                    for i in bar {
                        let n = line.notes[i]
                        defer { t += n.beats }
                        guard !n.rest, n.grace == nil, n.drum == nil, n.slash == nil, let midi = line.midi(i) else { continue }
                        var pitches = [NamedChord.Pitch(diatonic: n.diatonic, alter: line.soundingAlter(i), midi: midi)]
                        for tone in n.chord ?? [] where tone.drum == nil {
                            let a = tone.alter ?? line.keyAlter(tone.step, at: i)
                            pitches.append(.init(diatonic: tone.diatonic, alter: a, midi: Self.midi(step: tone.step, octave: tone.octave, alter: a)))
                        }
                        spans.append((t, t + n.beats, pitches))
                    }
                }
            }
        }
        return spans
    }

    /// The notes of the analysis staff's first voice where analysis goes (not rests or grace notes), with when
    /// each starts and its bar.
    private func analysisPoints() -> [(index: Int, time: Double, bar: Int)] {
        let line = forStaff(analysisStaff)
        var points: [(Int, Double, Int)] = []
        for (b, bar) in line.measures.enumerated() {
            var t = Double(b) * measureLength
            for i in bar {
                let n = line.notes[i]
                if !n.rest, n.grace == nil { points.append((i, t, b)) }
                t += n.beats
            }
        }
        return points
    }

    /// The pitches sounding at each analysis point.
    private func soundingAtPoints() -> [(index: Int, bar: Int, pitches: [NamedChord.Pitch])] {
        let spans = soundingSpans()
        return analysisPoints().map { point in
            let pitches = spans.filter { $0.start <= point.time + 1e-6 && point.time < $0.end - 1e-6 }.flatMap(\.pitches)
            return (point.index, point.bar, pitches)
        }
    }

    /// The Roman numeral of a chord in a key.
    static func romanNumeral(_ chord: NamedChord, fifths k: Int, minor: Bool) -> String {
        let tonic = tonic(fifths: k, minor: minor)
        let degree = mod7(chord.rootStep - tonic.step)
        let numerals = ["I", "II", "III", "IV", "V", "VI", "VII"]
        // The scale's own note on that degree (in minor, the raised leading tone as well as the subtonic).
        var delta = chord.rootAlter - keyAlter(chord.rootStep, fifths: k)
        let raisedLeadingTone = minor && degree == 6 && delta == 1
        if raisedLeadingTone { delta = 0 }
        let triads: [NamedChord.Quality] = minor ? [.minor, .diminished, .major, .minor, .major, .major, .diminished]
                                                 : [.major, .minor, .minor, .major, .major, .minor, .diminished]
        let sevenths: [NamedChord.Quality] = minor ? [.minor7, .halfDiminished7, .major7, .minor7, .dominant7, .major7, .diminished7]
                                                   : [.major7, .minor7, .minor7, .major7, .dominant7, .minor7, .halfDiminished7]
        var expected = chord.isSeventh ? sevenths[degree] : triads[degree]
        // Minor's natural forms count too: v and VII (the subtonic).
        if minor, !raisedLeadingTone, degree == 6, delta == 0 { expected = chord.isSeventh ? .dominant7 : .major }
        if minor, degree == 4, chord.quality == (chord.isSeventh ? .minor7 : .minor) { expected = chord.quality }
        func numeral(_ degree: Int, minorish: Bool) -> String { minorish ? numerals[degree].lowercased() : numerals[degree] }
        let diatonic = delta == 0 && chord.quality == expected
        if !diatonic {
            // The Neapolitan: a major chord on the lowered 2nd.
            if chord.quality == .major, degree == 1, delta == -1 { return "N" + chord.figures }
            // Secondary dominants and leading-tone chords: of the scale's major and minor chords.
            let dominantLike = chord.quality == .major || chord.quality == .dominant7
            let leadingLike = [.diminished, .diminished7, .halfDiminished7].contains(chord.quality)
            if dominantLike || leadingLike {
                let targetStep = mod7(chord.rootStep + (dominantLike ? -4 : 1))
                let targetDegree = mod7(targetStep - tonic.step)
                var targetAlter = keyAlter(targetStep, fifths: k)
                if minor, targetDegree == 6 { targetAlter += 1 }
                let rootPitch = natural(chord.rootStep) + chord.rootAlter
                let targetPitch = natural(targetStep) + targetAlter
                let interval = ((targetPitch - rootPitch) % 12 + 12) % 12
                let fits = dominantLike ? interval == 5 : interval == 1
                let targetQuality = triads[targetDegree]
                if fits, targetDegree != 0 || leadingLike, targetQuality == .major || targetQuality == .minor {
                    let head = dominantLike ? "V" : "vii" + chord.mark
                    let target = numeral(targetDegree, minorish: targetQuality == .minor)
                    return head + chord.figures + "/" + target
                }
            }
        }
        let accidental = delta > 0 ? "♯" : delta < 0 ? "♭" : ""
        return accidental + numeral(degree, minorish: chord.isMinorish) + chord.mark + chord.figures
    }

    /// Roman numerals under the lowest staff, from the chords the music makes (any already there are replaced).
    /// Each key (a key change starts a new one) is major or minor as its chords show, and its first numeral
    /// says which ("C:", "a:"). A chord that doesn't change from note to note is named once.
    mutating func addRomanNumerals() {
        let s = analysisStaff
        let points = soundingAtPoints()
        let named = points.map { (index: $0.index, bar: $0.bar, chord: NamedChord.name($0.pitches)) }
        var staff = forStaff(s)
        for i in staff.notes.indices { staff.notes[i].numeral = nil }
        // Keys: the bars from each key change to the next.
        var regionStart = 0
        var lastLabel: String?
        var currentKey: (Int, Bool)?
        for (k, point) in named.enumerated() {
            let fifths = self.fifths(inBar: point.bar)
            if k == 0 || self.fifths(inBar: named[k - 1].bar) != fifths { regionStart = k }
            let region = named[regionStart...].prefix { self.fifths(inBar: $0.bar) == fifths }.compactMap(\.chord)
            let minor = Self.isMinor(region, fifths: fifths)
            guard let chord = point.chord else { lastLabel = nil; continue }
            var label = Self.romanNumeral(chord, fifths: fifths, minor: minor)
            if label == lastLabel { continue }
            lastLabel = label
            if currentKey.map({ $0 != (fifths, minor) }) ?? true {
                label = Self.keyName(fifths: fifths, minor: minor) + ": " + label
                currentKey = (fifths, minor)
            }
            staff.notes[point.index].numeral = label
        }
        setStaff(s, staff)
    }

    /// Whether a key's music is in its minor: it ends (or else begins) on the minor tonic chord, or its leading
    /// tone is raised.
    static func isMinor(_ chords: [NamedChord], fifths: Int) -> Bool {
        let major = tonic(fifths: fifths, minor: false), minor = tonic(fifths: fifths, minor: true)
        func isTonic(_ c: NamedChord, _ t: (step: Int, alter: Int), minorish: Bool) -> Bool {
            c.rootStep == t.step && c.rootAlter == t.alter && c.isMinorish == minorish && !c.isSeventh
        }
        for c in [chords.last, chords.first].compactMap({ $0 }) {
            if isTonic(c, minor, minorish: true) { return true }
            if isTonic(c, major, minorish: false) { return false }
        }
        // The dominant of the minor key (with its raised leading tone).
        let dominantStep = mod7(minor.step + 4)
        return chords.contains { $0.rootStep == dominantStep && !$0.isMinorish && ($0.quality == .major || $0.quality == .dominant7) }
            && !chords.contains { isTonic($0, major, minorish: false) }
    }

    /// The figures for the notes over a bass, in a key: intervals above the bass (5/3 left out, 6/3 as 6, 6/4,
    /// 7, 6/5, 4/3, 4/2), with an accidental where the key doesn't give the note — alone for the 3rd.
    static func figures(over bass: NamedChord.Pitch, _ upper: [NamedChord.Pitch], fifths k: Int) -> String? {
        var intervals: [Int: Int] = [:]   // interval number (2 … 7) → the note's alteration against the key
        for p in upper.sorted(by: { $0.midi < $1.midi }) where p.midi > bass.midi {
            let steps = mod7(p.diatonic - bass.diatonic)
            guard steps != 0 else { continue }
            let number = steps + 1
            if intervals[number] == nil { intervals[number] = p.alter - keyAlter(mod7(p.diatonic), fifths: k) == 0 ? 99 : p.alter }
        }
        guard !intervals.isEmpty else { return nil }
        let set = Set(intervals.keys)
        let shown: [Int]
        switch set {
        case [3, 5], [3], [5]: shown = []
        case [3, 6], [6]: shown = [6]
        case [4, 6]: shown = [6, 4]
        case [3, 5, 7], [3, 7], [5, 7], [7]: shown = [7]
        case [3, 5, 6], [5, 6]: shown = [6, 5]
        case [3, 4, 6], [3, 4]: shown = [4, 3]
        case [2, 4, 6], [2, 4], [2, 6], [2]: shown = [4, 2]
        default: shown = set.sorted(by: >)
        }
        func accidental(_ a: Int) -> String { a == 99 ? "" : a > 0 ? "♯" : a < 0 ? "♭" : "♮" }
        var rows = shown.map { n in intervals[n].map(accidental).map { $0 + "\(n)" } ?? "\(n)" }
        // An altered 3rd that isn't among the figures: its accidental alone, at the bottom.
        if !shown.contains(3), let third = intervals[3], third != 99 { rows.append(accidental(third)) }
        // An altered 5th in a root position chord.
        if shown.isEmpty, let fifth = intervals[5], fifth != 99 { rows.insert(accidental(fifth) + "5", at: 0) }
        return rows.isEmpty ? nil : rows.joined(separator: "/")
    }

    /// Figured bass under the lowest staff, from the intervals the other notes make over the bass (any already
    /// there are replaced). Plain 5/3 chords get none.
    mutating func addFiguredBass() {
        let s = analysisStaff
        var staff = forStaff(s)
        for i in staff.notes.indices { staff.notes[i].figures = nil }
        for point in soundingAtPoints() {
            guard let bass = point.pitches.min(by: { $0.midi < $1.midi }) else { continue }
            staff.notes[point.index].figures = Self.figures(over: bass, point.pitches, fifths: fifths(inBar: point.bar))
        }
        setStaff(s, staff)
    }

    /// Takes the analysis away: Roman numerals, figured bass, or both, from every staff.
    mutating func clearAnalysis(numerals: Bool, figures: Bool) {
        for s in 0..<staffCount {
            var staff = forStaff(s)
            for v in 0...(staff.voices?.count ?? 0) {
                var line = staff.line(v)
                for i in line.indices {
                    if numerals { line[i].numeral = nil }
                    if figures { line[i].figures = nil }
                }
                staff.setLine(v, line)
            }
            setStaff(s, staff)
        }
    }

    var hasFigures: Bool { notes.contains { !($0.figures ?? "").isEmpty } }
    var hasNumerals: Bool { notes.contains { !($0.numeral ?? "").isEmpty } }
    /// The most figures stacked under any note.
    var figureRows: Int { notes.map { FiguredBass.rows($0.figures ?? "").count }.max() ?? 0 }
}

// MARK: - Commands

extension ScoreView {
    /// Analyze ▸ Roman Numerals: the chords of the music named under the lowest staff.
    func addRomanNumerals() {
        edit("Roman Numeral Analysis") { $0.addRomanNumerals() }
        analysisChanged()
    }

    /// Analyze ▸ Figured Bass: the intervals over the bass, under the lowest staff.
    func addFiguredBass() {
        edit("Figured Bass") { $0.addFiguredBass() }
        analysisChanged()
    }

    func clearAnalysis(numerals: Bool, figures: Bool) {
        edit(numerals && figures ? "Clear Analysis" : numerals ? "Clear Roman Numerals" : "Clear Figured Bass") {
            $0.clearAnalysis(numerals: numerals, figures: figures)
        }
        analysisChanged()
    }

    private func analysisChanged() {
        NotebookStore.shared.editor.scoreInputChanged += 1
        needsLayout = true
        needsDisplay = true
    }
}
