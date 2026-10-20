//
//  GuitarChords.swift
//  MxNoteONE
//
//  Chord diagrams for chord symbols: a fingering for C, Am7, F♯m, B♭maj7,
//  Dsus4, G/B… — on guitar, the usual open chord where there is one, else a
//  barre shape; in any tuning (drop and open tunings, bass, ukulele,
//  mandolin, banjo), voicings found up the neck — several to choose from, or
//  one drawn by hand. Fingers are numbered in the dots. With a capo, the shape
//  that's played: the chord symbol moved down by the capo's frets (E♭ with
//  capo 3 is played as a C shape). And the other way: a chord named from the
//  notes sounding.
//

import AppKit

enum GuitarChords {
    /// A chord symbol: root (pitch class 0 = C), its kind, and a bass note.
    struct Chord {
        var root: Int
        var quality: String
        var suffix: String
        var bass: Int?
        var flats: Bool
    }

    /// A fingering: each string's fret, the lowest string first (nil = not played), and the finger on each
    /// (1 index … 4 little; nil: worked out).
    struct Shape: Codable, Hashable {
        var frets: [Int?]
        var fingers: [Int?]?

        init(frets: [Int?], fingers: [Int?]? = nil) {
            self.frets = frets
            self.fingers = fingers
        }

        /// The fret the diagram starts at (1 = the nut shows).
        var baseFret: Int {
            let played = frets.compactMap { $0 }.filter { $0 > 0 }
            guard let high = played.max(), let low = played.min() else { return 1 }
            return high <= 4 ? 1 : low
        }
        /// A barre: the lowest fret held on several strings, from the first such string to the last.
        var barre: (fret: Int, from: Int, to: Int)? {
            let played = frets.enumerated().compactMap { i, f in f.map { (i, $0) } }.filter { $0.1 > 0 }
            guard let low = played.map(\.1).min() else { return nil }
            let on = played.filter { $0.1 == low }.map(\.0)
            guard on.count >= 3, let first = on.first, let last = on.last,
                  frets[first...last].allSatisfy({ ($0 ?? 0) >= low }) else { return nil }
            return (low, first, last)
        }

        /// Fingers: a barre's fret is the first finger; the other notes take the next fingers, lowest fret first.
        var fingering: [Int?] {
            if let fingers, fingers.count == frets.count { return fingers }
            var out = [Int?](repeating: nil, count: frets.count)
            var next = 1
            if let b = barre {
                for s in b.from...b.to where frets[s] == b.fret { out[s] = 1 }
                next = 2
            }
            let rest = frets.enumerated().compactMap { s, f -> (Int, Int)? in
                guard let f, f > 0, out[s] == nil else { return nil }
                return (s, f)
            }.sorted { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0 < $1.0 }
            for (s, _) in rest {
                if next <= 4 { out[s] = next }
                next += 1
            }
            return out
        }

        /// Written as frets ("x32010"; frets past 9 in brackets).
        var text: String { frets.map { f in f.map { $0 > 9 ? "(\($0))" : "\($0)" } ?? "x" }.joined() }
    }

    private static let letters: [Character: Int] = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11]

    static func parse(_ symbol: String) -> Chord? {
        let text = symbol.trimmingCharacters(in: .whitespaces)
        guard let first = text.first, var root = letters[first] else { return nil }
        var rest = Substring(text.dropFirst())
        var flats = false
        if let c = rest.first, "#♯".contains(c) { root += 1; rest = rest.dropFirst() } else if let c = rest.first, "b♭".contains(c) { root -= 1; flats = true; rest = rest.dropFirst() }
        var bass: Int?
        if let slash = rest.lastIndex(of: "/"), let b = rest[rest.index(after: slash)...].first, var pc = letters[b] {
            let after = rest[rest.index(after: slash)...].dropFirst()
            if let c = after.first, "#♯".contains(c) { pc += 1 } else if let c = after.first, "b♭".contains(c) { pc -= 1; flats = true }
            bass = (pc + 12) % 12
            rest = rest[..<slash]
        }
        let suffix = String(rest)
        return Chord(root: (root + 12) % 12, quality: quality(suffix), suffix: suffix, bass: bass, flats: flats)
    }

    /// The kinds diagrams know (others are drawn as the nearest: 13 as 7, m9 as m7…).
    static func quality(_ suffix: String) -> String {
        let s = suffix.replacingOccurrences(of: "(", with: "").replacingOccurrences(of: ")", with: "")
        let table: [([String], String)] = [
            (["maj7", "M7", "Δ7", "Δ", "ma7", "maj9", "M9", "maj13"], "maj7"),
            (["m7b5", "m7♭5", "ø7", "ø", "min7b5"], "m7b5"),
            (["dim7", "°7", "o7"], "dim7"),
            (["dim", "°", "o"], "dim"),
            (["aug", "+5", "#5", "♯5", "+"], "aug"),
            (["m9", "min9", "-9", "m11", "m13"], "m7"),
            (["m7", "min7", "-7", "mi7"], "m7"),
            (["m6", "min6", "-6"], "m6"),
            (["7sus4", "7sus"], "7sus4"),
            (["sus2"], "sus2"),
            (["sus4", "sus"], "sus4"),
            (["madd9", "m(add9)"], "m"),
            (["add9", "add2", "2"], "add9"),
            (["9"], "9"),
            (["13", "11", "7b9", "7#9", "7♭9", "7♯9", "7b5", "7#5", "7"], "7"),
            (["69", "6/9", "6"], "6"),
            (["5"], "5"),
            (["m", "min", "mi", "-"], "m"),
            ([""], ""),
        ]
        for (names, kind) in table where names.contains(s) { return kind }
        return s.hasPrefix("m") && !s.hasPrefix("maj") ? "m" : ""
    }

    private static func frets(_ text: String) -> [Int?] {
        text.map { $0 == "x" ? nil : Int(String($0)) }
    }

    /// Open chords (frets low E → high e).
    private static let open: [String: String] = [
        "0": "x32010", "2": "xx0232", "4": "022100", "7": "320003", "9": "x02220",
        "9m": "x02210", "4m": "022000", "2m": "xx0231",
        "07": "x32310", "27": "xx0212", "47": "020100", "77": "320001", "97": "x02020", "117": "x21202",
        "9m7": "x02010", "4m7": "020000", "2m7": "xx0211",
        "0maj7": "x32000", "2maj7": "xx0222", "5maj7": "xx3210", "7maj7": "320002", "9maj7": "x02120", "4maj7": "021100",
        "9sus2": "x02200", "9sus4": "x02230", "2sus2": "xx0230", "2sus4": "xx0233", "4sus4": "022200",
        "0add9": "x32030", "7add9": "300003", "26": "xx0202", "96": "x02222", "06": "x32210", "46": "022120",
        "45": "022xxx", "95": "x022xx", "25": "xx023x",
    ]

    /// Barre shapes with the root on the 6th string (offsets from the root's fret).
    private static let eShape: [String: [Int?]] = [
        "": [0, 2, 2, 1, 0, 0], "m": [0, 2, 2, 0, 0, 0], "7": [0, 2, 0, 1, 0, 0], "m7": [0, 2, 0, 0, 0, 0],
        "maj7": [0, 2, 1, 1, 0, 0], "sus4": [0, 2, 2, 2, 0, 0], "7sus4": [0, 2, 0, 2, 0, 0], "6": [0, 2, 2, 1, 2, 0],
        "m6": [0, 2, 2, 0, 2, 0], "aug": [0, 3, 2, 1, 1, 0], "9": [0, 2, 0, 1, 0, 2], "add9": [0, 2, 2, 1, 0, 2],
        "dim7": [0, 1, 2, 0, 2, 0], "sus2": [0, 2, 4, 4, 0, 0], "5": [0, 2, 2, nil, nil, nil],
    ]

    /// Barre shapes with the root on the 5th string.
    private static let aShape: [String: [Int?]] = [
        "": [nil, 0, 2, 2, 2, 0], "m": [nil, 0, 2, 2, 1, 0], "7": [nil, 0, 2, 0, 2, 0], "m7": [nil, 0, 2, 0, 1, 0],
        "maj7": [nil, 0, 2, 1, 2, 0], "sus4": [nil, 0, 2, 2, 3, 0], "sus2": [nil, 0, 2, 2, 0, 0], "6": [nil, 0, 2, 2, 2, 2],
        "m6": [nil, 0, 2, 2, 1, 2], "dim": [nil, 0, 1, 2, 1, nil], "aug": [nil, 0, 3, 2, 2, 1], "9": [nil, 0, 2, 4, 2, 3],
        "add9": [nil, 0, 2, 4, 2, 0], "m7b5": [nil, 0, 1, 0, 1, nil], "dim7": [nil, 0, 1, 2, 1, 2], "5": [nil, 0, 2, 2, nil, nil],
        "7sus4": [nil, 0, 2, 0, 3, 0],
    ]

    /// A fingering for a chord on standard guitar (the usual open chord, else a barre shape).
    static func shape(_ chord: Chord) -> Shape? {
        if let text = open["\(chord.root)\(chord.quality)"] { return Shape(frets: frets(text)) }
        var options: [(Int, [Int?])] = []
        if let e = eShape[chord.quality] { options.append(((chord.root - 4 + 12) % 12, e)) }
        if let a = aShape[chord.quality] { options.append(((chord.root - 9 + 12) % 12, a)) }
        guard let best = options.min(by: { $0.0 < $1.0 }) else { return nil }
        return Shape(frets: best.1.map { $0.map { $0 + best.0 } })
    }

    /// Semitones above the root of each kind's notes; the ones that must sound, the rest left out if need be.
    static let intervals: [String: (all: [Int], needed: [Int])] = [
        "": ([0, 4, 7], [0, 4]), "m": ([0, 3, 7], [0, 3]), "7": ([0, 4, 7, 10], [0, 4, 10]), "maj7": ([0, 4, 7, 11], [0, 4, 11]),
        "m7": ([0, 3, 7, 10], [0, 3, 10]), "sus2": ([0, 2, 7], [0, 2, 7]), "sus4": ([0, 5, 7], [0, 5, 7]), "7sus4": ([0, 5, 7, 10], [0, 5, 10]),
        "dim": ([0, 3, 6], [0, 3, 6]), "dim7": ([0, 3, 6, 9], [0, 3, 6, 9]), "aug": ([0, 4, 8], [0, 4, 8]), "6": ([0, 4, 7, 9], [0, 4, 9]),
        "m6": ([0, 3, 7, 9], [0, 3, 9]), "9": ([0, 4, 7, 10, 2], [0, 4, 10, 2]), "add9": ([0, 4, 7, 2], [0, 4, 2]),
        "m7b5": ([0, 3, 6, 10], [0, 3, 6, 10]), "5": ([0, 7], [0, 7]),
    ]

    private static var voicingCache: [String: [Shape]] = [:]

    /// Voicings of a chord on an instrument (open strings, lowest first), handiest first: every needed note there,
    /// the bass (or root) lowest, the strings played next to each other, four fingers or fewer within four frets.
    /// On standard guitar the usual shape comes first.
    static func voicings(_ chord: Chord, strings: [Int], frets top: Int = 15, limit: Int = 8) -> [Shape] {
        let key = "\(chord.root)|\(chord.quality)|\(chord.bass ?? -1)|\(strings)|\(top)|\(limit)"
        if let hit = voicingCache[key] { return hit }
        let table = intervals[chord.quality] ?? intervals[""]!
        let pcs = Set(table.all.map { (chord.root + $0) % 12 }).union(chord.bass.map { [$0] } ?? [])
        let needed = Set(table.needed.map { (chord.root + $0) % 12 })
        let bassPC = chord.bass ?? chord.root
        let n = strings.count
        let minSounding = n <= 4 ? min(n, 3) : 4
        var found: [(Shape, Double)] = []
        var seen = Set<[Int?]>()
        for base in 0...max(0, top - 3) {
            let window = base == 0 ? Array(1...4) : Array(base...(base + 3))
            let options: [[Int?]] = strings.map { open in
                [nil] + ([0] + window).filter { pcs.contains((open + $0) % 12) }.map { Optional($0) }
            }
            var current = [Int?](repeating: nil, count: n)
            func search(_ s: Int) {
                if s == n {
                    evaluate(current, base: base)
                    return
                }
                for o in options[s] {
                    current[s] = o
                    search(s + 1)
                }
            }
            func evaluate(_ f: [Int?], base: Int) {
                guard !seen.contains(f) else { return }
                let sounding = f.indices.filter { f[$0] != nil }
                guard sounding.count >= minSounding, let low = sounding.first, let high = sounding.last else { return }
                // The strings played are next to each other.
                guard sounding.count == high - low + 1 else { return }
                // The bass is the chord's bass (or root).
                let notes = sounding.map { strings[$0] + f[$0]! }
                guard let lowest = notes.min(), ((lowest % 12) + 12) % 12 == bassPC else { return }
                let have = Set(notes.map { $0 % 12 })
                guard needed.isSubset(of: have) else { return }
                // Fingers: a barre on the lowest fret counts once.
                let fretted = f.compactMap { $0 }.filter { $0 > 0 }
                let shape = Shape(frets: f)
                var fingers = fretted.count
                if let b = shape.barre { fingers -= f[b.from...b.to].filter { $0 == b.fret }.count - 1 }
                guard fingers <= 4 else { return }
                if let lo = fretted.min(), let hi = fretted.max(), hi - lo > 3 { return }
                seen.insert(f)
                let opens = f.filter { $0 == 0 }.count
                let score = Double(sounding.count) * 3 + Double(have.count) * 2 + Double(opens) * (base == 0 ? 0.8 : 0)
                    - Double(fretted.min() ?? 0) * 0.35 - Double(fingers) * 0.3 - (shape.barre != nil ? 0.5 : 0)
                found.append((shape, score))
            }
            search(0)
        }
        var result = found.sorted { $0.1 > $1.1 }.map(\.0)
        if strings == TabInstrument.guitar.strings, let usual = shape(chord), chord.bass == nil {
            result.removeAll { $0.frets == usual.frets }
            result.insert(usual, at: 0)
        }
        result = Array(result.prefix(limit))
        if voicingCache.count > 500 { voicingCache.removeAll() }
        voicingCache[key] = result
        return result
    }

    /// The diagram for a chord symbol: with a capo, the shape that's played (and its name); the voicing chosen for
    /// it, else the handiest.
    static func diagram(for symbol: String, capo: Int, strings: [Int] = TabInstrument.guitar.strings, frets: Int = 15,
                        chosen: [String: Shape]? = nil) -> (name: String, shape: Shape)? {
        let played = capo > 0 ? transposed(symbol, by: -capo) : symbol
        if let mine = chosen?[played], mine.frets.count == strings.count { return (played, mine) }
        guard let chord = parse(played) else { return nil }
        if strings == TabInstrument.guitar.strings, let usual = shape(chord), chord.bass == nil { return (played, usual) }
        guard let first = voicings(chord, strings: strings, frets: frets).first else { return nil }
        return (played, first)
    }

    // MARK: Naming chords from their notes

    /// A chord symbol for the pitches sounding (MIDI): the root and kind that account for every note — the bass as
    /// the root when it can be, else a slash chord.
    static func name(_ midis: [Int], flats: Bool) -> String? {
        let pcs = Set(midis.map { (($0 % 12) + 12) % 12 })
        guard pcs.count >= 2, let bass = midis.min().map({ (($0 % 12) + 12) % 12 }) else { return nil }
        let names = flats ? flatNames : sharpNames
        let order = ["", "m", "7", "maj7", "m7", "5", "sus4", "sus2", "dim", "dim7", "m7b5", "aug", "6", "m6", "7sus4", "add9", "9"]
        var best: (String, Int)?
        for root in pcs.sorted(by: { $0 == bass ? true : $1 == bass ? false : $0 < $1 }) {
            for (rank, kind) in order.enumerated() {
                guard let t = intervals[kind] else { continue }
                let chordPCs = Set(t.all.map { (root + $0) % 12 }), need = Set(t.needed.map { (root + $0) % 12 })
                guard pcs.isSubset(of: chordPCs), need.isSubset(of: pcs) else { continue }
                // Fewer left-out notes, the bass as root, the plainer kind.
                let score = (chordPCs.count - pcs.count) * 10 + (root == bass ? 0 : 50) + rank
                let text = names[root] + kind + (root == bass ? "" : "/" + names[bass])
                if best == nil || score < best!.1 { best = (text, score) }
            }
        }
        return best?.0
    }

    private static let sharpNames = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
    private static let flatNames = ["C", "D♭", "D", "E♭", "E", "F", "G♭", "G", "A♭", "A", "B♭", "B"]
    /// As guitarists usually name chord shapes.
    private static let guitarNames = ["C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"]

    /// The chord symbol moved by some semitones (the shape played with a capo: down by its fret).
    static func transposed(_ symbol: String, by semitones: Int) -> String {
        guard let chord = parse(symbol) else { return symbol }
        let root = guitarNames[(chord.root + semitones + 120) % 12]
        let bass = chord.bass.map { "/" + guitarNames[($0 + semitones + 120) % 12] } ?? ""
        return root + chord.suffix + bass
    }

    // MARK: Drawing

    /// A diagram's size (its strings, four or five frets, the open/muted marks above).
    static func size(space: CGFloat, strings: Int = 6) -> NSSize {
        NSSize(width: space * 0.72 * CGFloat(max(1, strings - 1)) + space * 1.0 + space * 0.9, height: space * 5.6)
    }

    /// Draws a diagram with its top-left at a point: strings, frets (the nut, or "5fr"), dots with their fingers,
    /// the barre, ○ and ×.
    static func draw(_ shape: Shape, at origin: NSPoint, space: CGFloat, color: NSColor, fingers: Bool = true) {
        let gap = space * 0.72, fret = space * 0.9
        let n = shape.frets.count
        let rows = max(4, (shape.frets.compactMap { $0 }.max() ?? 0) - shape.baseFret + 1)
        let markY = origin.y + space * 0.45
        let top = origin.y + space * 1.1
        let left = origin.x + space * 0.5
        let width = gap * CGFloat(max(1, n - 1)), height = fret * CGFloat(min(rows, 5))
        color.set()
        // Strings and frets.
        for s in 0..<n {
            NSRect(x: left + CGFloat(s) * gap - 0.4, y: top, width: 0.8, height: height).fill()
        }
        for f in 0...min(rows, 5) {
            NSRect(x: left, y: top + CGFloat(f) * fret - 0.4, width: width, height: 0.8).fill()
        }
        if shape.baseFret == 1 {
            NSRect(x: left, y: top - 1.6, width: width, height: 2.4).fill()   // the nut
        } else {
            let label = "\(shape.baseFret)fr" as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 8), .foregroundColor: color]
            label.draw(at: NSPoint(x: left + width + 2, y: top + fret * 0.1), withAttributes: attrs)
        }
        let fingering = fingers ? shape.fingering : Array(repeating: nil, count: n)
        let digitAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: max(6, gap * 0.78), weight: .bold), .foregroundColor: NSColor.white]
        func digit(_ d: Int?, at p: NSPoint) {
            guard let d else { return }
            let t = "\(d)" as NSString
            let size = t.size(withAttributes: digitAttrs)
            t.draw(at: NSPoint(x: p.x - size.width / 2, y: p.y - size.height / 2), withAttributes: digitAttrs)
        }
        // A barre across the strings it holds.
        if let barre = shape.barre {
            let y = top + (CGFloat(barre.fret - shape.baseFret) + 0.5) * fret
            let bar = NSBezierPath(roundedRect: NSRect(x: left + CGFloat(barre.from) * gap - gap * 0.35, y: y - fret * 0.28,
                                                       width: CGFloat(barre.to - barre.from) * gap + gap * 0.7, height: fret * 0.56),
                                   xRadius: fret * 0.28, yRadius: fret * 0.28)
            color.set()
            bar.fill()
            digit(fingering[barre.from], at: NSPoint(x: left + CGFloat(barre.from) * gap, y: y))
        }
        for (s, f) in shape.frets.enumerated() {
            let x = left + CGFloat(s) * gap
            color.set()
            switch f {
            case nil:
                let d = gap * 0.32
                let cross = NSBezierPath()
                cross.move(to: NSPoint(x: x - d, y: markY - d)); cross.line(to: NSPoint(x: x + d, y: markY + d))
                cross.move(to: NSPoint(x: x - d, y: markY + d)); cross.line(to: NSPoint(x: x + d, y: markY - d))
                cross.lineWidth = 1
                cross.stroke()
            case 0?:
                let r = gap * 0.32
                let ring = NSBezierPath(ovalIn: NSRect(x: x - r, y: markY - r, width: r * 2, height: r * 2))
                ring.lineWidth = 0.9
                ring.stroke()
            case let n?:
                if let barre = shape.barre, barre.fret == n, (barre.from...barre.to).contains(s) { continue }
                let r = gap * 0.42
                let y = top + (CGFloat(n - shape.baseFret) + 0.5) * fret
                NSBezierPath(ovalIn: NSRect(x: x - r, y: y - r, width: r * 2, height: r * 2)).fill()
                digit(fingering[s], at: NSPoint(x: x, y: y))
            }
        }
    }
}
