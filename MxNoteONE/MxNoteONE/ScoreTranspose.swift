//
//  ScoreTranspose.swift
//  MxNoteONE
//
//  Transposition and concert pitch. Transpose moves music — the whole score, or the selected notes — by an
//  interval, to a key, or by steps in the key: notes, chord tones, chord symbols and key signatures, spelt for the
//  new key (accidentals only where the key and the bar don't give them; double sharps and flats respelt).
//
//  A staff can be a transposing instrument (B♭ clarinet or trumpet, E♭ alto sax, F horn…). Its notes are kept
//  where the player reads them, in the instrument's own key (concert C major is D major for a B♭ clarinet), and
//  sound lower or higher; the score's key signatures are kept in concert pitch. Concert Pitch shows every staff as
//  it sounds — notes written that way go back to where the player reads them.
//

import AppKit

/// An interval: letter steps and semitones (a major 2nd up is 1, 2; a minor 3rd down −2, −3).
struct ScoreInterval: Hashable {
    var steps: Int
    var semitones: Int

    static let unison = ScoreInterval(steps: 0, semitones: 0)

    /// How far it moves a key round the circle of fifths (a major 2nd: two sharps more).
    var fifths: Int { 7 * semitones - 12 * steps }
    var inverse: ScoreInterval { ScoreInterval(steps: -steps, semitones: -semitones) }
    var isUp: Bool { semitones > 0 || (semitones == 0 && steps > 0) }

    /// The intervals Transpose offers.
    static let named: [(String, ScoreInterval)] = [
        ("Minor 2nd", .init(steps: 1, semitones: 1)), ("Major 2nd", .init(steps: 1, semitones: 2)),
        ("Minor 3rd", .init(steps: 2, semitones: 3)), ("Major 3rd", .init(steps: 2, semitones: 4)),
        ("Perfect 4th", .init(steps: 3, semitones: 5)), ("Augmented 4th", .init(steps: 3, semitones: 6)),
        ("Diminished 5th", .init(steps: 4, semitones: 6)), ("Perfect 5th", .init(steps: 4, semitones: 7)),
        ("Minor 6th", .init(steps: 5, semitones: 8)), ("Major 6th", .init(steps: 5, semitones: 9)),
        ("Minor 7th", .init(steps: 6, semitones: 10)), ("Major 7th", .init(steps: 6, semitones: 11)),
        ("Octave", .init(steps: 7, semitones: 12)),
    ]

    /// "a major 2nd", "an octave and a major 2nd" (without the direction).
    var size: String {
        let a = isUp || self == .unison ? self : inverse
        let octaves = a.steps / 7
        let simple = ScoreInterval(steps: a.steps - octaves * 7, semitones: a.semitones - octaves * 12)
        let octaveWords = octaves == 0 ? "" : octaves == 1 ? "an octave" : "\(octaves) octaves"
        guard simple != .unison else { return octaves == 0 ? "a unison" : octaveWords }
        let name = Self.named.first { $0.1 == simple }?.0.lowercased()
            ?? (simple == ScoreInterval(steps: 0, semitones: 1) ? "augmented unison" : "\(simple.steps + 1)th")
        let article = name.first.map { "aeiou".contains($0) } == true ? "an" : "a"
        return octaves == 0 ? "\(article) \(name)" : "\(octaveWords) and \(article) \(name)"
    }

    /// "a major 2nd up", "a perfect 5th down".
    var name: String { "\(size) \(isUp ? "up" : "down")" }
}

/// A transposing instrument: where its notes are written against where they sound.
struct ScoreInstrument: Identifiable, Hashable {
    let id: String
    let name: String
    /// Beside the staff ("B♭ Cl.").
    let short: String
    /// Sounding pitch = written pitch + this (as MusicXML's <transpose>): a B♭ clarinet sounds a major 2nd lower.
    let sounds: ScoreInterval
    let clef: ScoreData.Clef

    static let all: [ScoreInstrument] = [
        .init(id: "bb-clarinet", name: "B♭ Clarinet", short: "B♭ Cl.", sounds: .init(steps: -1, semitones: -2), clef: .treble),
        .init(id: "a-clarinet", name: "A Clarinet", short: "A Cl.", sounds: .init(steps: -2, semitones: -3), clef: .treble),
        .init(id: "eb-clarinet", name: "E♭ Clarinet", short: "E♭ Cl.", sounds: .init(steps: 2, semitones: 3), clef: .treble),
        .init(id: "bass-clarinet", name: "B♭ Bass Clarinet", short: "B. Cl.", sounds: .init(steps: -8, semitones: -14), clef: .treble),
        .init(id: "soprano-sax", name: "B♭ Soprano Sax", short: "S. Sax", sounds: .init(steps: -1, semitones: -2), clef: .treble),
        .init(id: "alto-sax", name: "E♭ Alto Sax", short: "A. Sax", sounds: .init(steps: -5, semitones: -9), clef: .treble),
        .init(id: "tenor-sax", name: "B♭ Tenor Sax", short: "T. Sax", sounds: .init(steps: -8, semitones: -14), clef: .treble),
        .init(id: "baritone-sax", name: "E♭ Baritone Sax", short: "Bar. Sax", sounds: .init(steps: -12, semitones: -21), clef: .treble),
        .init(id: "bb-trumpet", name: "B♭ Trumpet", short: "B♭ Tpt.", sounds: .init(steps: -1, semitones: -2), clef: .treble),
        .init(id: "flugelhorn", name: "B♭ Flugelhorn", short: "Flgh.", sounds: .init(steps: -1, semitones: -2), clef: .treble),
        .init(id: "f-horn", name: "F Horn", short: "Hn.", sounds: .init(steps: -4, semitones: -7), clef: .treble),
        .init(id: "english-horn", name: "English Horn", short: "E. Hn.", sounds: .init(steps: -4, semitones: -7), clef: .treble),
        .init(id: "piccolo", name: "Piccolo", short: "Picc.", sounds: .init(steps: 7, semitones: 12), clef: .treble),
        .init(id: "glockenspiel", name: "Glockenspiel", short: "Glk.", sounds: .init(steps: 14, semitones: 24), clef: .treble),
        .init(id: "guitar", name: "Guitar", short: "Gtr.", sounds: .init(steps: -7, semitones: -12), clef: .treble),
        .init(id: "bass-guitar", name: "Bass Guitar", short: "B. Gtr.", sounds: .init(steps: -7, semitones: -12), clef: .bass),
        .init(id: "double-bass", name: "Double Bass", short: "Cb.", sounds: .init(steps: -7, semitones: -12), clef: .bass),
    ]

    static func find(_ id: String?) -> ScoreInstrument? { all.first { $0.id == id } }

    /// The instrument a MusicXML part probably is: by its name ("Clarinet in B♭", "Alto Saxophone"), else the first
    /// that transposes the same way.
    static func guess(name: String, sounds: ScoreInterval) -> ScoreInstrument? {
        let n = name.lowercased().replacingOccurrences(of: "saxophone", with: "sax").replacingOccurrences(of: "♭", with: "b")
        let matches = all.filter { $0.sounds == sounds }
        let words: [(String, String)] = [("bass clarinet", "bass-clarinet"), ("clarinet", "bb-clarinet"), ("soprano sax", "soprano-sax"),
                                         ("alto sax", "alto-sax"), ("tenor sax", "tenor-sax"), ("baritone sax", "baritone-sax"),
                                         ("trumpet", "bb-trumpet"), ("flugel", "flugelhorn"), ("english horn", "english-horn"),
                                         ("cor anglais", "english-horn"), ("horn", "f-horn"), ("piccolo", "piccolo"),
                                         ("glock", "glockenspiel"), ("bass guitar", "bass-guitar"), ("guitar", "guitar"),
                                         ("contrabass", "double-bass"), ("double bass", "double-bass")]
        for (word, id) in words where n.contains(word) {
            if let m = matches.first(where: { $0.id == id }) { return m }
            // "Clarinet in A" / "in Eb": the clarinet that transposes that way.
            if id == "bb-clarinet", let m = matches.first(where: { $0.id.hasSuffix("clarinet") }) { return m }
        }
        return matches.first
    }
}

extension ScoreData {
    // MARK: Transposing staves

    /// How this staff's instrument transposes (nil: it sounds as written; a drum staff never transposes).
    var transposition: ScoreInterval? {
        guard clef != .percussion, let t = transpose, t.count == 2, t != [0, 0] else { return nil }
        return ScoreInterval(steps: t[0], semitones: t[1])
    }

    /// How far the music sounds from where it's written, in semitones (for playback).
    var soundingShift: Int { transposition?.semitones ?? 0 }

    /// Any staff that transposes.
    var hasTransposingStaff: Bool { (0..<staffCount).contains { forStaff($0).transposition != nil } }

    /// The label beside a transposing staff ("B♭ Cl."), or "in B♭" for an instrument not in the list.
    var instrumentLabel: String? {
        guard let t = transposition else { return nil }
        if let known = ScoreInstrument.find(instrument), known.sounds == t { return known.short }
        // The concert note a written C sounds.
        let (d, a) = Self.moved(4 * 7, 0, by: t)
        return "in " + ["C", "D", "E", "F", "G", "A", "B"][Self.mod7(d)] + (a > 0 ? "♯" : a < 0 ? "♭" : "")
    }

    /// The staff written in the keys its instrument reads (a B♭ clarinet's D major for concert C major).
    mutating func useWrittenKeys(for t: ScoreInterval) {
        keyFifths = Self.writtenKey(keyFifths, t)
        if let marks = barMarks {
            barMarks = marks.mapValues { mark in
                var m = mark
                if let k = m.keyFifths { m.keyFifths = Self.writtenKey(k, t) }
                return m
            }
        }
    }

    /// A key kept between six flats and six sharps — one beyond is written the other way (C♯ major as D♭ major).
    static func simplestKey(_ fifths: Int) -> Int {
        var k = fifths
        while k > 6 { k -= 12 }
        while k < -6 { k += 12 }
        return k
    }

    /// The key an instrument reads for a concert key, and back.
    static func writtenKey(_ concert: Int, _ t: ScoreInterval) -> Int { simplestKey(concert - t.fifths) }
    static func concertKey(_ written: Int, _ t: ScoreInterval) -> Int { simplestKey(written + t.fifths) }

    /// The interval that takes music in one key to another, moving it so many semitones (its letters follow the keys).
    static func interval(semitones: Int, from: Int, to: Int) -> ScoreInterval {
        let steps = (Double(7 * semitones - (to - from)) / 12).rounded()
        return ScoreInterval(steps: Int(steps), semitones: semitones)
    }

    // MARK: Pitches

    static func mod7(_ d: Int) -> Int { ((d % 7) + 7) % 7 }
    static func floor7(_ d: Int) -> Int { d >= 0 ? d / 7 : -((-d + 6) / 7) }
    /// The natural note on a line or space, as a MIDI number.
    static func natural(_ diatonic: Int) -> Int { midi(step: mod7(diatonic), octave: floor7(diatonic), alter: 0) }

    /// A pitch with at most one sharp or flat: F𝄪 is written G, C𝄫 B♭.
    static func plainSpelling(_ diatonic: Int, _ alter: Int) -> (Int, Int) {
        var d = diatonic, a = alter
        while a > 1 { a -= natural(d + 1) - natural(d); d += 1 }
        while a < -1 { a += natural(d) - natural(d - 1); d -= 1 }
        return (d, a)
    }

    /// A pitch (line or space and alteration) moved by an interval.
    static func moved(_ diatonic: Int, _ alter: Int, by i: ScoreInterval) -> (Int, Int) {
        let pitch = natural(diatonic) + alter + i.semitones
        let d = diatonic + i.steps
        return plainSpelling(d, pitch - natural(d))
    }

    /// A pitch moved so many steps up or down in a key, keeping how far it is from the key's note there (F♯ in C
    /// major up a step is G♯) — or, with `keepAlterations` off, landing on the key's own note.
    static func movedInKey(_ diatonic: Int, _ alter: Int, steps: Int, fifths: Int, keepAlterations: Bool = true) -> (Int, Int) {
        let d = diatonic + steps
        let degree = keepAlterations ? alter - keyAlter(mod7(diatonic), fifths: fifths) : 0
        return plainSpelling(d, keyAlter(mod7(d), fifths: fifths) + degree)
    }

    // MARK: Chord symbols

    /// A chord symbol's root and bass moved (`move` takes and gives a letter, 0 = C, and its alteration); the
    /// chord's kind is kept, and ♯ ♭ or # b as it was written.
    static func movedChordSymbol(_ symbol: String, _ move: (Int, Int) -> (Int, Int)) -> String {
        let letters: [Character] = ["C", "D", "E", "F", "G", "A", "B"]
        let chars = Array(symbol)
        guard let first = chars.first, let root = letters.firstIndex(of: first) else { return symbol }
        func accidental(at i: Int) -> (Int, Int) {   // (alteration, characters)
            guard i < chars.count else { return (0, 0) }
            switch chars[i] {
            case "♯", "#": return (1, 1)
            case "♭", "b": return (-1, 1)
            default: return (0, 0)
            }
        }
        let (rootAlter, rootLength) = accidental(at: 1)
        var rest = String(chars[(1 + rootLength)...])
        // A bass note at the end: "/E", "/F♯".
        var bass: (Int, Int)?
        if let slash = rest.lastIndex(of: "/") {
            let after = Array(rest[rest.index(after: slash)...])
            if let letter = after.first, let b = letters.firstIndex(of: letter), after.count <= 2 {
                let alter = after.count == 2 ? (after[1] == "♯" || after[1] == "#" ? 1 : after[1] == "♭" || after[1] == "b" ? -1 : 9) : 0
                if alter != 9 {
                    bass = (b, alter)
                    rest = String(rest[..<slash])
                }
            }
        }
        let ascii = symbol.contains("#") || (rootLength == 1 && chars[1] == "b") || symbol.hasSuffix("b") && bass != nil
        func write(_ p: (Int, Int)) -> String {
            String(letters[mod7(p.0)]) + (p.1 > 0 ? (ascii ? "#" : "♯") : p.1 < 0 ? (ascii ? "b" : "♭") : "")
        }
        var out = write(move(root, rootAlter)) + rest
        if let bass { out += "/" + write(move(bass.0, bass.1)) }
        return out
    }

    /// A chord symbol moved by an interval (C → D, F♯m7/C♯ → G♯m7/D♯).
    static func movedChordSymbol(_ symbol: String, by i: ScoreInterval) -> String {
        movedChordSymbol(symbol) { letter, alter in
            let (d, a) = moved(4 * 7 + letter, alter, by: i)
            return (mod7(d), a)
        }
    }

    // MARK: Moving music

    /// A voice's notes with new pitches — `pitch` gets each note's index, bar, line or space and real alteration
    /// (from the key and the bar) and gives the new ones — written for the keys of `target`: an accidental only
    /// where its key and the bar don't give it. Rests, drums and slashes keep their places; chord symbols go
    /// through `chords`.
    func respelledLine(_ v: Int, keys target: ScoreData,
                       pitch: (_ index: Int, _ bar: Int, _ diatonic: Int, _ alter: Int) -> (Int, Int),
                       chords: (_ index: Int, _ bar: Int, _ symbol: String) -> String) -> [ScoreNote] {
        let src = forVoice(v)
        var out = src.notes
        guard clef != .percussion, !out.isEmpty else { return out }
        for (b, range) in src.measures.enumerated() {
            let key = target.fifths(inBar: b)
            // Accidentals written so far in the bar, by line or space.
            var written: [Int: Int] = [:]
            for i in range {
                let note = src.notes[i]
                if let symbol = note.chordSymbol, !symbol.isEmpty { out[i].chordSymbol = chords(i, b, symbol) }
                guard !note.rest, note.drum == nil, note.slash == nil else { continue }
                if src.tiedFrom(i) {
                    // Tied over: the note it's tied from, again.
                    out[i].step = out[i - 1].step
                    out[i].octave = out[i - 1].octave
                    out[i].alter = nil
                } else {
                    let (d, a) = pitch(i, b, note.diatonic, src.soundingAlter(i))
                    out[i].step = Self.mod7(d)
                    out[i].octave = Self.floor7(d)
                    if a == (written[d] ?? Self.keyAlter(Self.mod7(d), fifths: key)) {
                        out[i].alter = nil
                    } else {
                        out[i].alter = a
                        written[d] = a
                    }
                }
                if let tones = note.chord {
                    out[i].chord = tones.map { tone in
                        guard tone.drum == nil else { return tone }
                        let (d, a) = pitch(i, b, tone.diatonic, tone.alter ?? src.keyAlter(tone.step, at: i))
                        var t = tone
                        t.step = Self.mod7(d)
                        t.octave = Self.floor7(d)
                        t.alter = a == Self.keyAlter(t.step, fifths: key) ? nil : a
                        return t
                    }
                }
            }
        }
        return out
    }

    /// Every voice of a staff moved by an interval (bar by bar) into `target` — a copy of the staff with the keys
    /// the music goes into.
    func respelledStaff(into target: ScoreData, by interval: (Int) -> ScoreInterval, chords: Bool = true) -> ScoreData {
        var out = target
        for v in 0...(voices?.count ?? 0) {
            out.setLine(v, respelledLine(v, keys: target,
                                         pitch: { _, bar, d, a in Self.moved(d, a, by: interval(bar)) },
                                         chords: { _, bar, s in chords ? Self.movedChordSymbol(s, by: interval(bar)) : s }))
        }
        return out
    }

    // MARK: Concert pitch

    /// A staff as it's shown: as written, or — with Concert Pitch on — as it sounds, in the score's keys.
    func shown(_ i: Int) -> ScoreData {
        let written = forStaff(i)
        guard concertPitch == true, let t = written.transposition else { return written }
        var concert = written
        concert.keyFifths = keyFifths
        concert.barMarks = barMarks
        concert.transpose = nil
        return written.respelledStaff(into: concert) { bar in
            Self.interval(semitones: t.semitones, from: written.fifths(inBar: bar), to: concert.fifths(inBar: bar))
        }
    }

    /// Puts back a voice of a staff edited as it's shown. In concert pitch the notes go back to where the
    /// instrument reads them; the ones that didn't change stay exactly as they were.
    mutating func setShownLine(_ i: Int, voice v: Int, _ notes: [ScoreNote]) {
        var staff = forStaff(i)
        if concertPitch == true, let t = staff.transposition {
            let before = shown(i)
            let old = before.line(v)
            guard notes != old else { return }
            var edited = before
            edited.setLine(v, notes)
            let back = edited.respelledLine(v, keys: staff, pitch: { _, bar, d, a in
                Self.moved(d, a, by: Self.interval(semitones: -t.semitones, from: edited.fifths(inBar: bar), to: staff.fifths(inBar: bar)))
            }, chords: { _, bar, s in
                Self.movedChordSymbol(s, by: Self.interval(semitones: -t.semitones, from: edited.fifths(inBar: bar), to: staff.fifths(inBar: bar)))
            })
            staff.setLine(v, Self.merged(stored: staff.line(v), old: old, new: notes, converted: back))
        } else {
            staff.setLine(v, notes)
        }
        setStaff(i, staff)
    }

    /// The stored notes with an edit applied: notes the edit removed go, notes it added or changed come from
    /// `converted` (the edited line, put back as stored), and the rest stay as they were.
    static func merged(stored: [ScoreNote], old: [ScoreNote], new: [ScoreNote], converted: [ScoreNote]) -> [ScoreNote] {
        guard stored.count == old.count, converted.count == new.count else { return converted }
        let changes: [CollectionDifference<ScoreNote>.Change] = new.difference(from: old).map { change in
            switch change {
            case .remove(let offset, _, _): return .remove(offset: offset, element: stored[offset], associatedWith: nil)
            case .insert(let offset, _, _): return .insert(offset: offset, element: converted[offset], associatedWith: nil)
            }
        }
        guard let difference = CollectionDifference(changes), let result = stored.applying(difference) else { return converted }
        return result
    }

    // MARK: Transposing the score

    /// The whole score moved by an interval: every staff (each as its instrument reads it), chord symbols, and
    /// the key signatures — or, with `keys` off, the keys kept and accidentals written instead.
    func transposed(by i: ScoreInterval, keys: Bool = true, chords: Bool = true) -> ScoreData {
        var result = self
        if keys {
            result.keyFifths = Self.simplestKey(keyFifths + i.fifths)
            result.barMarks = barMarks?.mapValues { mark in
                var m = mark
                if let k = m.keyFifths { m.keyFifths = Self.simplestKey(k + i.fifths) }
                return m
            }
        }
        for s in 0..<staffCount {
            let from = forStaff(s), to = result.forStaff(s)
            guard from.clef != .percussion else { continue }
            let moved = from.respelledStaff(into: to, by: { bar in
                keys ? Self.interval(semitones: i.semitones, from: from.fifths(inBar: bar), to: to.fifths(inBar: bar)) : i
            }, chords: chords)
            result.setStaff(s, moved)
        }
        return result
    }

    /// The interval that takes the score's key to another (up, down, or whichever is closer).
    func interval(toKey target: Int, direction: Int) -> ScoreInterval {
        let change = target - keyFifths
        let steps = ((4 * change) % 7 + 7) % 7, semitones = ((7 * change) % 12 + 12) % 12
        let up = ScoreInterval(steps: steps, semitones: semitones)
        guard up != .unison else { return direction < 0 ? ScoreInterval(steps: -7, semitones: -12) : direction > 0 ? ScoreInterval(steps: 7, semitones: 12) : .unison }
        let down = ScoreInterval(steps: steps - 7, semitones: semitones - 12)
        if direction > 0 { return up }
        if direction < 0 { return down }
        return semitones <= 6 ? up : down
    }

    /// The whole score moved so many steps in its keys (a 3rd up in C major: C → E, D → F), chord symbols too.
    func transposedInKey(steps: Int, keepAlterations: Bool = true, chords: Bool = true) -> ScoreData {
        var result = self
        for s in 0..<staffCount {
            let st = forStaff(s)
            guard st.clef != .percussion else { continue }
            var out = st
            for v in 0...(st.voices?.count ?? 0) {
                out.setLine(v, st.respelledLine(v, keys: st, pitch: { _, bar, d, a in
                    Self.movedInKey(d, a, steps: steps, fifths: st.fifths(inBar: bar), keepAlterations: keepAlterations)
                }, chords: { _, bar, symbol in
                    guard chords else { return symbol }
                    let k = st.fifths(inBar: bar)
                    return Self.movedChordSymbol(symbol) { letter, alter in
                        let (d, a) = Self.movedInKey(4 * 7 + letter, alter, steps: steps, fifths: k, keepAlterations: keepAlterations)
                        return (Self.mod7(d), a)
                    }
                }))
            }
            result.setStaff(s, out)
        }
        return result
    }

    /// A staff given another instrument: it sounds as before, written where the new instrument reads it.
    func withInstrument(_ instrument: ScoreInstrument?, staff s: Int) -> ScoreData {
        var result = self
        let from = forStaff(s)
        guard from.clef != .percussion else { return self }
        var to = from
        to.transpose = instrument.map { [$0.sounds.steps, $0.sounds.semitones] }
        to.instrument = instrument?.id
        if let instrument { to.clef = instrument.clef }
        // The copy's keys, as the new instrument reads them.
        to.keyFifths = keyFifths
        to.barMarks = barMarks
        if let t = to.transposition { to.useWrittenKeys(for: t) }
        let semitones = from.soundingShift - to.soundingShift
        var moved = from.respelledStaff(into: to) { bar in
            Self.interval(semitones: semitones, from: from.fifths(inBar: bar), to: to.fifths(inBar: bar))
        }
        // The staff takes the instrument's name (unless it has a name of its own).
        let oldName = ScoreInstrument.find(from.instrument)?.name
        if from.staffName == nil || from.staffName?.isEmpty == true || from.staffName == oldName { moved.staffName = instrument?.name }
        result.setStaff(s, moved)
        return result
    }
}

extension ScoreData {
    /// A half step up or down, spelt for the key: the key's own note where it is one (E up is F, A up in F major
    /// B♭), else a sharp going up and a flat going down (C up is C♯, D down D♭).
    static func halfStep(_ diatonic: Int, _ alter: Int, up: Bool, fifths: Int) -> (Int, Int) {
        let pitch = natural(diatonic) + alter + (up ? 1 : -1)
        let candidates = [diatonic, diatonic + (up ? 1 : -1)].map { d in (d, pitch - natural(d)) }.filter { abs($0.1) <= 1 }
        func cost(_ c: (Int, Int)) -> Int {
            if c.1 == keyAlter(mod7(c.0), fifths: fifths) { return 0 }
            if c.1 == 0 { return 1 }
            return (c.1 > 0) == up ? 2 : 3
        }
        return candidates.min { cost($0) < cost($1) } ?? plainSpelling(diatonic, alter + (up ? 1 : -1))
    }
}

/// Transpose's choices, kept between uses.
enum TransposeOptions {
    private static let defaults = UserDefaults.standard
    /// Key signatures move with the music (off: the keys stay and accidentals are written).
    static var keys: Bool {
        get { defaults.object(forKey: "MxTransposeKeys") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "MxTransposeKeys") }
    }
    static var chordSymbols: Bool {
        get { defaults.object(forKey: "MxTransposeChords") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "MxTransposeChords") }
    }
    /// Moving in the key keeps notes' sharps and flats against the key (F♯ in C major up a step is G♯).
    static var keepAlterations: Bool {
        get { defaults.object(forKey: "MxTransposeKeepAlterations") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "MxTransposeKeepAlterations") }
    }
}

extension ScoreView {
    // MARK: Transpose

    /// Transpose acts on the selected notes when there are two or more, else on the whole score.
    var transposeRange: ClosedRange<Int>? {
        guard let r = selectedRange, r.count > 1 else { return nil }
        return r
    }

    /// What Transpose will act on, for menus.
    var transposeScope: String {
        transposeRange.map { "The \($0.count) selected notes" } ?? "The whole score (select notes to transpose only them)"
    }

    private func transposed() {
        NotebookStore.shared.editor.scoreInputChanged += 1
        needsLayout = true
        needsDisplay = true
    }

    /// Moves the music by an interval: the selected notes (keys stay), or the whole score — every staff, the
    /// chord symbols and (unless that's turned off) the key signatures.
    func transpose(by interval: ScoreInterval) {
        let chords = TransposeOptions.chordSymbols
        if let r = transposeRange {
            editVoice("Transpose") { view in
                view.notes = view.respelledLine(0, keys: view, pitch: { i, _, d, a in
                    r.contains(i) ? ScoreData.moved(d, a, by: interval) : (d, a)
                }, chords: { i, _, s in
                    r.contains(i) && chords ? ScoreData.movedChordSymbol(s, by: interval) : s
                })
            }
        } else {
            let keys = TransposeOptions.keys
            edit("Transpose") { $0 = $0.transposed(by: interval, keys: keys, chords: chords) }
        }
        transposed()
    }

    /// A half step up or down. The whole score changes key (C major up is D♭ major); notes on their own, or with
    /// the keys kept, are spelt for the key they're in (E up is F, C up C♯).
    func transposeHalfStep(up: Bool) {
        let chords = TransposeOptions.chordSymbols
        if transposeRange == nil, TransposeOptions.keys {
            return transpose(by: up ? ScoreInterval(steps: 1, semitones: 1) : ScoreInterval(steps: -1, semitones: -1))
        }
        func chord(_ s: String, _ fifths: Int) -> String {
            guard chords else { return s }
            return ScoreData.movedChordSymbol(s) { letter, alter in
                let (d, a) = ScoreData.halfStep(4 * 7 + letter, alter, up: up, fifths: fifths)
                return (ScoreData.mod7(d), a)
            }
        }
        if let r = transposeRange {
            editVoice("Transpose") { view in
                view.notes = view.respelledLine(0, keys: view, pitch: { i, bar, d, a in
                    r.contains(i) ? ScoreData.halfStep(d, a, up: up, fifths: view.fifths(inBar: bar)) : (d, a)
                }, chords: { i, bar, s in r.contains(i) ? chord(s, view.fifths(inBar: bar)) : s })
            }
        } else {
            edit("Transpose") { full in
                for s in 0..<full.staffCount {
                    let st = full.forStaff(s)
                    guard st.clef != .percussion else { continue }
                    var out = st
                    for v in 0...(st.voices?.count ?? 0) {
                        out.setLine(v, st.respelledLine(v, keys: st, pitch: { _, bar, d, a in
                            ScoreData.halfStep(d, a, up: up, fifths: st.fifths(inBar: bar))
                        }, chords: { _, bar, sym in chord(sym, st.fifths(inBar: bar)) }))
                    }
                    full.setStaff(s, out)
                }
            }
        }
        transposed()
    }

    /// The whole score into another key (chosen as this staff shows keys), up, down (−1) or whichever is closer (0).
    func transpose(toKey shownKey: Int, direction: Int) {
        let target = concertKey(shownKey)
        let interval = fullScore.interval(toKey: target, direction: direction)
        guard interval != .unison else { return }
        let chords = TransposeOptions.chordSymbols
        edit("Transpose") { $0 = $0.transposed(by: interval, keys: true, chords: chords) }
        transposed()
    }

    /// Up or down so many steps in the key (a 3rd up: C → E, D → F): the selected notes, or the whole score.
    func transposeInKey(steps: Int) {
        let keep = TransposeOptions.keepAlterations, chords = TransposeOptions.chordSymbols
        if let r = transposeRange {
            editVoice("Transpose") { view in
                view.notes = view.respelledLine(0, keys: view, pitch: { i, bar, d, a in
                    r.contains(i) ? ScoreData.movedInKey(d, a, steps: steps, fifths: view.fifths(inBar: bar), keepAlterations: keep) : (d, a)
                }, chords: { i, bar, s in
                    guard r.contains(i), chords else { return s }
                    let k = view.fifths(inBar: bar)
                    return ScoreData.movedChordSymbol(s) { letter, alter in
                        let (d, a) = ScoreData.movedInKey(4 * 7 + letter, alter, steps: steps, fifths: k, keepAlterations: keep)
                        return (ScoreData.mod7(d), a)
                    }
                })
            }
        } else {
            edit("Transpose") { $0 = $0.transposedInKey(steps: steps, keepAlterations: keep, chords: chords) }
        }
        transposed()
    }

    // MARK: Instruments and concert pitch

    /// The current staff's instrument (nil: in C). It goes on sounding the same; its notes move to where the new
    /// instrument reads them.
    func setInstrument(_ instrument: ScoreInstrument?) {
        let st = staffIndex
        edit(instrument.map { "Instrument: \($0.name)" } ?? "Instrument in C") { $0 = $0.withInstrument(instrument, staff: st) }
        transposed()
    }

    /// The current staff's instrument, if it transposes.
    var currentInstrument: ScoreInstrument? {
        let st = fullScore.forStaff(staffIndex)
        guard let t = st.transposition else { return nil }
        return ScoreInstrument.find(st.instrument).flatMap { $0.sounds == t ? $0 : nil }
    }

    /// Concert Pitch: every staff as it sounds (transposing instruments too), or as their players read them.
    func toggleConcertPitch() {
        edit("Concert Pitch") { $0.concertPitch = $0.concertPitch == true ? nil : true }
        transposed()
    }

    // MARK: The Transpose dialog

    /// Transpose…: to a key, by an interval, or in the key — with the options for keys and chord symbols.
    func showTransposeDialog() {
        let alert = NSAlert()
        alert.messageText = "Transpose"
        alert.informativeText = transposeScope + "."
        alert.addButton(withTitle: "Transpose")
        alert.addButton(withTitle: "Cancel")
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 430, height: 190))
        // Radio buttons with one action and superview work as a group.
        let group = RadioGroup()
        func radio(_ title: String, y: CGFloat) -> NSButton {
            let b = NSButton(radioButtonWithTitle: title, target: group, action: #selector(RadioGroup.pick(_:)))
            b.frame = NSRect(x: 0, y: y, width: 120, height: 22)
            box.addSubview(b)
            return b
        }
        func popup(_ items: [String], x: CGFloat, y: CGFloat, width: CGFloat) -> NSPopUpButton {
            let p = NSPopUpButton(frame: NSRect(x: x, y: y - 2, width: width, height: 26), pullsDown: false)
            p.addItems(withTitles: items)
            box.addSubview(p)
            return p
        }
        let selection = transposeRange != nil
        let toKey = radio("To key:", y: 164), byInterval = radio("By interval:", y: 132), inKey = radio("In the key:", y: 100)
        let keyNames = ScoreData.keyNames.map(\.1)
        let keyPopup = popup(keyNames, x: 120, y: 164, width: 190)
        if let i = ScoreData.keyNames.firstIndex(where: { $0.0 == score.keyFifths }) { keyPopup.selectItem(at: i) }
        let keyDirection = popup(["Closest", "Up", "Down"], x: 316, y: 164, width: 110)
        let intervalPopup = popup(ScoreInterval.named.map(\.0), x: 120, y: 132, width: 190)
        intervalPopup.selectItem(at: 1)
        let intervalDirection = popup(["Up", "Down"], x: 316, y: 132, width: 110)
        let stepNames = ["A 2nd", "A 3rd", "A 4th", "A 5th", "A 6th", "A 7th", "An octave"]
        let stepPopup = popup(stepNames, x: 120, y: 100, width: 190)
        let stepDirection = popup(["Up", "Down"], x: 316, y: 100, width: 110)
        func check(_ title: String, y: CGFloat, on: Bool) -> NSButton {
            let b = NSButton(checkboxWithTitle: title, target: nil, action: nil)
            b.frame = NSRect(x: 0, y: y, width: 430, height: 20)
            b.state = on ? .on : .off
            box.addSubview(b)
            return b
        }
        let keysBox = check(selection ? "Transpose key signatures (not for selected notes: the keys stay)" : "Transpose key signatures",
                            y: 62, on: TransposeOptions.keys && !selection)
        keysBox.isEnabled = !selection
        let chordsBox = check("Transpose chord symbols", y: 38, on: TransposeOptions.chordSymbols)
        let keepBox = check("In the key: keep sharps and flats against the key (F♯ in C major up a step is G♯)", y: 14, on: TransposeOptions.keepAlterations)
        // To a key changes the whole score's key, so it's for the whole score only.
        if selection { toKey.isEnabled = false; keyPopup.isEnabled = false; keyDirection.isEnabled = false; byInterval.state = .on } else { toKey.state = .on }
        alert.accessoryView = box
        let answer = alert.runModal()
        withExtendedLifetime(group) {}
        guard answer == .alertFirstButtonReturn else { return }
        if !selection { TransposeOptions.keys = keysBox.state == .on }
        TransposeOptions.chordSymbols = chordsBox.state == .on
        TransposeOptions.keepAlterations = keepBox.state == .on
        if toKey.state == .on, !selection {
            let key = ScoreData.keyNames[max(0, keyPopup.indexOfSelectedItem)].0
            transpose(toKey: key, direction: [0, 1, -1][max(0, keyDirection.indexOfSelectedItem)])
        } else if inKey.state == .on {
            let steps = stepPopup.indexOfSelectedItem + 1
            transposeInKey(steps: stepDirection.indexOfSelectedItem == 1 ? -steps : steps)
        } else {
            let interval = ScoreInterval.named[max(0, intervalPopup.indexOfSelectedItem)].1
            transpose(by: intervalDirection.indexOfSelectedItem == 1 ? interval.inverse : interval)
        }
    }
}

/// The target the Transpose dialog's radio buttons share (it only groups them).
private final class RadioGroup: NSObject {
    @objc func pick(_ sender: NSButton) {}
}
