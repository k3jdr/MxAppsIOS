//
//  GuitarChords.swift
//  MxNoteONE
//
//  Guitar chord diagrams for chord symbols: a fingering for C, Am7, F♯m,
//  B♭maj7, Dsus4, G/B… — an open chord where there's a usual one, else a
//  barre shape (on the 6th string's root or the 5th's, whichever is lower on
//  the neck). With a capo, the chord shape that's played: the chord symbol
//  moved down by the capo's frets (E♭ with capo 3 is played as a C shape).
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

    /// A fingering: each string's fret, low E first (nil = not played).
    struct Shape: Equatable {
        var frets: [Int?]
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

    /// A fingering for a chord.
    static func shape(_ chord: Chord) -> Shape? {
        if let text = open["\(chord.root)\(chord.quality)"] { return Shape(frets: frets(text)) }
        var options: [(Int, [Int?])] = []
        if let e = eShape[chord.quality] { options.append(((chord.root - 4 + 12) % 12, e)) }
        if let a = aShape[chord.quality] { options.append(((chord.root - 9 + 12) % 12, a)) }
        guard let best = options.min(by: { $0.0 < $1.0 }) else { return nil }
        return Shape(frets: best.1.map { $0.map { $0 + best.0 } })
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

    /// The diagram for a chord symbol (with a capo: the shape that's played) and its name.
    static func diagram(for symbol: String, capo: Int) -> (name: String, shape: Shape)? {
        let played = capo > 0 ? transposed(symbol, by: -capo) : symbol
        guard let chord = parse(played), let shape = shape(chord) else { return nil }
        return (played, shape)
    }

    // MARK: Drawing

    /// A diagram's size (six strings, four or five frets, the open/muted marks above).
    static func size(space: CGFloat) -> NSSize { NSSize(width: space * 4.6, height: space * 5.6) }

    /// Draws a diagram with its top-left at a point: strings, frets (the nut, or "5fr"), dots, barre, ○ and ×.
    static func draw(_ shape: Shape, at origin: NSPoint, space: CGFloat, color: NSColor) {
        let gap = space * 0.72, fret = space * 0.9
        let rows = max(4, (shape.frets.compactMap { $0 }.max() ?? 0) - shape.baseFret + 1)
        let markY = origin.y + space * 0.45
        let top = origin.y + space * 1.1
        let left = origin.x + space * 0.5
        let width = gap * 5, height = fret * CGFloat(min(rows, 5))
        color.set()
        // Strings and frets.
        for s in 0..<6 {
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
        // A barre across the strings it holds.
        if let barre = shape.barre {
            let y = top + (CGFloat(barre.fret - shape.baseFret) + 0.5) * fret
            let bar = NSBezierPath(roundedRect: NSRect(x: left + CGFloat(barre.from) * gap - gap * 0.35, y: y - fret * 0.28,
                                                       width: CGFloat(barre.to - barre.from) * gap + gap * 0.7, height: fret * 0.56),
                                   xRadius: fret * 0.28, yRadius: fret * 0.28)
            bar.fill()
        }
        for (s, f) in shape.frets.enumerated() {
            let x = left + CGFloat(s) * gap
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
                let r = gap * 0.38
                let y = top + (CGFloat(n - shape.baseFret) + 0.5) * fret
                NSBezierPath(ovalIn: NSRect(x: x - r, y: y - r, width: r * 2, height: r * 2)).fill()
            }
        }
    }
}
