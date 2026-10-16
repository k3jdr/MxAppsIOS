//
//  ScoreMusicXML.swift
//  MxNoteONE
//
//  MusicXML, the format MuseScore, Finale, Sibelius and Dorico exchange
//  scores in: a score exports as MusicXML 4.0 (notes, rests, dots, ties,
//  accidentals, chords, chord symbols, lyrics, dynamics, hairpins, slurs,
//  articulations, ornaments, fermatas,
//  key and key changes, repeats,
//  time, clef, tempo, and
//  guitar strings and frets when the TAB staff is on), and MusicXML files —
//  .musicxml, .xml or compressed .mxl — import as a score (the first part's
//  first voice; what's left out is reported).
//

import AppKit
import UniformTypeIdentifiers

enum MusicXML {
    // MARK: Export

    private static let types: [ScoreNote.Duration: String] = [.whole: "whole", .half: "half", .quarter: "quarter", .eighth: "eighth", .sixteenth: "16th"]
    private static let divisions = 8   // per quarter note (a dotted sixteenth is 3)

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func duration(_ note: ScoreNote) -> Int { Int((note.beats * Double(divisions)).rounded()) }

    static func export(_ score: ScoreData) -> String {
        var out = """
        <?xml version="1.0" encoding="UTF-8" standalone="no"?>
        <!DOCTYPE score-partwise PUBLIC "-//Recordare//DTD MusicXML 4.0 Partwise//EN" "http://www.musicxml.org/dtds/partwise.dtd">
        <score-partwise version="4.0">

        """
        if !score.title.isEmpty { out += "  <work><work-title>\(escape(score.title))</work-title></work>\n" }
        // Parts: a grand staff's two staves are one part (as MuseScore writes piano); every other staff is a part.
        let count = score.staffCount
        let groups: [[Int]] = score.grandStaff == true && count >= 2 ? [[0, 1]] + (2..<count).map { [$0] } : (0..<count).map { [$0] }
        let staffScores = (0..<count).map { score.forStaff($0) }
        let barCount = max(1, staffScores.flatMap { st in
            [st.notes.isEmpty ? 0 : st.measures.count, st.hasSecondVoice ? st.forVoice(1).measures.count : 0]
        }.max() ?? 1)
        let measureDuration = Int((score.measureLength * Double(divisions)).rounded())
        func partName(_ group: [Int]) -> String {
            if group.count == 2 { return score.staffName ?? "Piano" }
            let st = staffScores[group[0]]
            if let name = st.staffName, !name.isEmpty { return name }
            if st.clef == .percussion { return "Drums" }
            return count == 1 ? (score.showTab == true ? "Guitar" : "Music") : "Staff \(group[0] + 1)"
        }
        out += "  <identification><encoding><software>MxNoteONE</software></encoding></identification>\n  <part-list>"
        for (p, group) in groups.enumerated() {
            out += "<score-part id=\"P\(p + 1)\"><part-name>\(escape(partName(group)))</part-name>"
            // A drum staff: its instruments and their General MIDI drum sounds (channel 10).
            if group.count == 1, staffScores[group[0]].clef == .percussion {
                for drum in DrumKit.instruments { out += "<score-instrument id=\"P\(p + 1)-I\(drum.midi)\"><instrument-name>\(drum.name)</instrument-name></score-instrument>" }
                for drum in DrumKit.instruments {
                    out += "<midi-instrument id=\"P\(p + 1)-I\(drum.midi)\"><midi-channel>10</midi-channel><midi-unpitched>\(drum.midi + 1)</midi-unpitched></midi-instrument>"
                }
            }
            out += "</score-part>"
        }
        out += "</part-list>\n"
        func clefXML(_ clef: ScoreData.Clef, number: Int?) -> String {
            let n = number.map { " number=\"\($0)\"" } ?? ""
            switch clef {
            case .treble: return "<clef\(n)><sign>G</sign><line>2</line></clef>"
            case .bass: return "<clef\(n)><sign>F</sign><line>4</line></clef>"
            case .percussion: return "<clef\(n)><sign>percussion</sign></clef>"
            }
        }
        for (p, group) in groups.enumerated() {
            out += "  <part id=\"P\(p + 1)\">\n"
            for m in 0..<barCount {
                out += "    <measure number=\"\(m + 1)\">\n"
                let mark = score.mark(m)
                if mark.repeatStart == true {
                    out += "      <barline location=\"left\"><bar-style>heavy-light</bar-style><repeat direction=\"forward\"/></barline>\n"
                }
                if m > 0, let fifths = mark.keyFifths {
                    out += "      <attributes><key><fifths>\(fifths)</fifths></key></attributes>\n"
                }
                if m == 0 {
                    out += "      <attributes><divisions>\(divisions)</divisions><key><fifths>\(score.keyFifths)</fifths></key>"
                    out += "<time><beats>\(score.beats)</beats><beat-type>\(score.beatUnit)</beat-type></time>"
                    if group.count == 2 { out += "<staves>2</staves>" }
                    for (k, st) in group.enumerated() { out += clefXML(staffScores[st].clef, number: group.count == 2 ? k + 1 : nil) }
                    if p == 0, let capo = score.capo, capo > 0 { out += "<staff-details><capo>\(capo)</capo></staff-details>" }
                    out += "</attributes>\n"
                    if p == 0 { out += tempoXML(score, bar: 0) }
                } else if p == 0, mark.tempo != nil || !(mark.tempoText ?? "").isEmpty {
                    out += tempoXML(score, bar: m)
                }
                if p == 0, let g = mark.gradual {
                    out += "      <direction placement=\"above\"><direction-type><words font-style=\"italic\">\(g < 0 ? "rit." : "accel.")</words></direction-type></direction>\n"
                }
                // Each staff's voices in turn, going back to the bar line between them.
                var previous = 0
                for (k, st) in group.enumerated() {
                    let staffNumber = group.count == 2 ? k + 1 : nil
                    for v in 0..<ScoreData.voiceCount {
                        let line = staffScores[st].forVoice(v)
                        if v > 0, !staffScores[st].hasSecondVoice { continue }
                        let bars = line.notes.isEmpty ? [] : line.measures
                        let number = k * 4 + v + 1
                        var chunk = "", length = 0
                        if bars.indices.contains(m) {
                            chunk = notesXML(line, bars[m], voice: number, staff: staffNumber, part: p + 1)
                            length = bars[m].reduce(0) { $0 + duration(line.notes[$1]) }
                        } else if v == 0 {
                            // A bar this staff has no notes in: a whole-bar rest.
                            chunk = "      <note><rest measure=\"yes\"/><duration>\(measureDuration)</duration><voice>\(number)</voice>"
                                + (staffNumber.map { "<staff>\($0)</staff>" } ?? "") + "</note>\n"
                            length = measureDuration
                        } else {
                            continue
                        }
                        if previous > 0 { out += "      <backup><duration>\(previous)</duration></backup>\n" }
                        out += chunk
                        previous = length
                    }
                }
                if mark.repeatEnd == true {
                    out += "      <barline location=\"right\"><bar-style>light-heavy</bar-style><repeat direction=\"backward\"/></barline>\n"
                } else if m == barCount - 1 {
                    out += "      <barline location=\"right\"><bar-style>light-heavy</bar-style></barline>\n"
                }
                out += "    </measure>\n"
            }
            out += "  </part>\n"
        }
        out += "</score-partwise>\n"
        return out
    }

    /// A tempo mark: its word, the metronome mark in its note, and the speed for playback.
    private static func tempoXML(_ score: ScoreData, bar: Int) -> String {
        let mark = score.mark(bar)
        let quarters = bar == 0 ? score.tempo : (mark.tempo ?? score.tempo(inBar: bar))
        let unit = ScoreData.tempoUnits.first { $0.0 == (mark.tempoUnit ?? "quarter") } ?? ScoreData.tempoUnits[0]
        var x = "      <direction placement=\"above\">"
        if let word = mark.tempoText, !word.isEmpty {
            x += "<direction-type><words font-weight=\"bold\">\(escape(word))</words></direction-type>"
        }
        if bar == 0 || mark.tempo != nil {
            let beatUnit = unit.0 == "dotted" ? "quarter</beat-unit><beat-unit-dot/>" : unit.0 + "</beat-unit>"
            x += "<direction-type><metronome><beat-unit>\(beatUnit)<per-minute>\(Int((Double(quarters) / unit.1).rounded()))</per-minute></metronome></direction-type>"
            x += "<sound tempo=\"\(quarters)\"/>"
        }
        return x + "</direction>\n"
    }

    /// One voice's notes in a bar (voice 2 after a <backup>).
    private static func notesXML(_ score: ScoreData, _ bar: Range<Int>, voice: Int, staff: Int? = nil, part: Int = 1) -> String {
        let steps = ["C", "D", "E", "F", "G", "A", "B"]
        var out = ""
        // In a part with two staves, each note and direction says which staff.
        let staffTag = staff.map { "<staff>\($0)</staff>" } ?? ""
        let stemDown = voice % 4 == 2
        // Triplets: where each group starts and stops.
        let groups = score.tupletGroups(in: bar)
        let starts = Set(groups.compactMap(\.first)), stops = Set(groups.compactMap(\.last))
        for i in bar {
            let note = score.notes[i]
            if let symbol = note.chordSymbol, !symbol.isEmpty {
                let frame = score.chordDiagrams == true ? GuitarChords.diagram(for: symbol, capo: score.capo ?? 0)?.shape : nil
                out += "      " + harmony(symbol, frame: frame) + "\n"
            }
            if let d = note.dynamic, ScoreData.dynamics.contains(d) {
                let level = ScoreData.dynamicLevels[d] ?? (d == "sfz" ? 120 : 100)
                out += "      <direction placement=\"below\"><direction-type><dynamics><\(d)/></dynamics></direction-type>"
                out += "<voice>\(voice)</voice>\(staffTag)<sound dynamics=\"\(Int((Double(level) * 100 / 90).rounded()))\"/></direction>\n"
            }
            if let pin = note.hairpin {
                out += "      <direction placement=\"below\"><direction-type><wedge type=\"\(pin > 0 ? "crescendo" : "diminuendo")\"/></direction-type>"
                out += "<voice>\(voice)</voice>\(staffTag)</direction>\n"
            }
            let tiedFrom = i > 0 && score.notes[i - 1].tie && !note.rest
            let tab = score.showTab == true ? score.tab(i) : []
            func noteXML(chord: Bool, step: Int, octave: Int, alter: Int, accidental: Int?, main: Bool, tabSpot: (string: Int, fret: Int)?,
                         drum: DrumInstrument? = nil) -> String {
                var x = "      <note>"
                if let grace = note.grace { x += grace == "acciaccatura" ? "<grace slash=\"yes\"/>" : "<grace/>" }
                if chord { x += "<chord/>" }
                if note.rest {
                    x += "<rest/>"
                } else if drum != nil {
                    // A drum: where it's written, not a pitch.
                    x += "<unpitched><display-step>\(steps[step])</display-step><display-octave>\(octave)</display-octave></unpitched>"
                } else {
                    x += "<pitch><step>\(steps[step])</step>" + (alter != 0 ? "<alter>\(alter)</alter>" : "") + "<octave>\(octave)</octave></pitch>"
                }
                if note.grace == nil { x += "<duration>\(duration(note))</duration>" }
                if main, tiedFrom { x += "<tie type=\"stop\"/>" }
                if main, note.tie, !note.rest { x += "<tie type=\"start\"/>" }
                if let drum, !note.rest { x += "<instrument id=\"P\(part)-I\(drum.midi)\"/>" }
                x += "<voice>\(voice)</voice><type>\(types[note.duration]!)</type>"
                if note.dotted { x += "<dot/>" }
                if let accidental { x += "<accidental>\(accidental > 0 ? "sharp" : accidental < 0 ? "flat" : "natural")</accidental>" }
                if let actual = note.tupletActual {
                    x += "<time-modification><actual-notes>\(actual)</actual-notes><normal-notes>\(note.tupletNormal)</normal-notes></time-modification>"
                }
                if stemDown { x += "<stem>down</stem>" }
                if let drum, !note.rest, drum.head != .normal {
                    x += "<notehead>\(drum.head == .x ? "x" : drum.head == .circleX ? "circle-x" : "diamond")</notehead>"
                }
                x += staffTag
                var notations = ""
                if main, note.tupletActual != nil, starts.contains(i) { notations += "<tuplet type=\"start\" bracket=\"\(note.duration.rawValue >= 8 ? "no" : "yes")\"/>" }
                if main, note.tupletActual != nil, stops.contains(i) { notations += "<tuplet type=\"stop\"/>" }
                if main, tiedFrom { notations += "<tied type=\"stop\"/>" }
                if main, note.slurEnd == true { notations += "<slur type=\"stop\" number=\"1\"/>" }
                if main, note.slurStart == true { notations += "<slur type=\"start\" number=\"1\"/>" }
                if main, note.tie, !note.rest { notations += "<tied type=\"start\"/>" }
                if main {
                    let arts = (note.articulations ?? []).compactMap { articulationXML[$0] }
                    if !arts.isEmpty { notations += "<articulations>" + arts.joined() + "</articulations>" }
                    if let o = note.ornament, let x = ornamentXML[o] { notations += "<ornaments>\(x)</ornaments>" }
                    if note.fermata == true { notations += "<fermata type=\"\(stemDown ? "inverted" : "upright")\"/>" }
                }
                if let tabSpot { notations += "<technical><string>\(6 - tabSpot.string)</string><fret>\(tabSpot.fret)</fret></technical>" }
                if !notations.isEmpty { x += "<notations>\(notations)</notations>" }
                if main, let lyric = note.lyric, !lyric.isEmpty { x += lyricXML(score, i) }
                return x + "</note>\n"
            }
            let shift = score.clef == .treble ? 12 : 0
            func spot(_ midi: Int) -> (string: Int, fret: Int)? { tab.first { ScoreData.tuning[$0.string] + $0.fret == midi - shift } }
            let mainMidi = score.midi(i)
            out += noteXML(chord: false, step: note.step, octave: note.octave, alter: note.rest ? 0 : score.soundingAlter(i),
                           accidental: score.showsAccidental(i) ? note.alter : nil, main: true,
                           tabSpot: score.clef == .percussion ? nil : mainMidi.flatMap(spot), drum: DrumKit.instrument(note.drum))
            for tone in note.chord ?? [] where !note.rest {
                let alter = tone.alter ?? score.keyAlter(tone.step, at: i)
                let midi = ScoreData.midi(step: tone.step, octave: tone.octave, alter: alter)
                out += noteXML(chord: true, step: tone.step, octave: tone.octave, alter: alter,
                               accidental: tone.alter != nil && tone.alter != score.keyAlter(tone.step, at: i) ? tone.alter : nil, main: false,
                               tabSpot: score.clef == .percussion ? nil : spot(midi), drum: DrumKit.instrument(tone.drum))
            }
            if note.hairpinEnd == true {
                out += "      <direction placement=\"below\"><direction-type><wedge type=\"stop\"/></direction-type><voice>\(voice)</voice>\(staffTag)</direction>\n"
            }
        }
        return out
    }
    private static let articulationXML = ["staccato": "<staccato/>", "staccatissimo": "<staccatissimo/>", "tenuto": "<tenuto/>",
                                          "accent": "<accent/>", "marcato": "<strong-accent type=\"up\"/>"]
    private static let ornamentXML = ["trill": "<trill-mark/>", "mordent": "<mordent/>", "prall": "<inverted-mordent/>", "turn": "<turn/>"]

    /// A lyric with its syllable kind ("Twin-" "kle" → begin, end).
    private static func lyricXML(_ score: ScoreData, _ i: Int) -> String {
        let lyric = score.notes[i].lyric ?? ""
        let continues = lyric.hasSuffix("-")
        let previous = score.notes[..<i].last { !($0.lyric ?? "").isEmpty }?.lyric ?? ""
        let continued = previous.hasSuffix("-")
        let syllabic = continues ? (continued ? "middle" : "begin") : (continued ? "end" : "single")
        let text = continues ? String(lyric.dropLast()) : lyric
        return "<lyric number=\"1\"><syllabic>\(syllabic)</syllabic><text>\(escape(text))</text></lyric>"
    }

    private static let kinds: [(String, String)] = [
        ("maj7", "major-seventh"), ("M7", "major-seventh"), ("Δ7", "major-seventh"), ("m7b5", "half-diminished"), ("ø", "half-diminished"),
        ("dim7", "diminished-seventh"), ("m7", "minor-seventh"), ("min7", "minor-seventh"), ("-7", "minor-seventh"), ("m6", "minor-sixth"),
        ("m9", "minor-ninth"), ("maj9", "major-ninth"), ("sus4", "suspended-fourth"), ("sus2", "suspended-second"), ("sus", "suspended-fourth"),
        ("dim", "diminished"), ("°", "diminished"), ("aug", "augmented"), ("+", "augmented"), ("m", "minor"), ("min", "minor"), ("-", "minor"),
        ("13", "dominant-13th"), ("11", "dominant-11th"), ("9", "dominant-ninth"), ("7", "dominant"), ("6", "major-sixth"), ("5", "power"), ("", "major"),
    ]

    /// A chord symbol as MusicXML harmony (root, kind, bass); one that isn't a chord name goes in as words.
    /// A chord diagram as MusicXML's harmony frame (strings 6 = low E … 1).
    private static func frameXML(_ shape: GuitarChords.Shape) -> String {
        let rows = max(4, (shape.frets.compactMap { $0 }.max() ?? 0) - shape.baseFret + 1)
        var x = "<frame><frame-strings>6</frame-strings><frame-frets>\(min(rows, 5))</frame-frets>"
        if shape.baseFret > 1 { x += "<first-fret>\(shape.baseFret)</first-fret>" }
        for (s, f) in shape.frets.enumerated() {
            if let f { x += "<frame-note><string>\(6 - s)</string><fret>\(f)</fret></frame-note>" }
        }
        return x + "</frame>"
    }

    private static func harmony(_ symbol: String, frame: GuitarChords.Shape? = nil) -> String {
        let pattern = "^([A-G])([#♯b♭]?)(.*?)(?:/([A-G])([#♯b♭]?))?$"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: symbol, range: NSRange(location: 0, length: (symbol as NSString).length)) else {
            return "<direction placement=\"above\"><direction-type><words>\(escape(symbol))</words></direction-type></direction>"
        }
        let ns = symbol as NSString
        func part(_ i: Int) -> String { m.range(at: i).location == NSNotFound ? "" : ns.substring(with: m.range(at: i)) }
        func alter(_ s: String) -> String { s == "#" || s == "♯" ? "<root-alter>1</root-alter>" : s == "b" || s == "♭" ? "<root-alter>-1</root-alter>" : "" }
        let suffix = part(3)
        let kind = kinds.first { $0.0 == suffix }?.1 ?? "other"
        var x = "<harmony><root><root-step>\(part(1))</root-step>\(alter(part(2)))</root><kind text=\"\(escape(suffix))\">\(kind)</kind>"
        if !part(4).isEmpty {
            x += "<bass><bass-step>\(part(4))</bass-step>\(alter(part(5)).replacingOccurrences(of: "root-alter", with: "bass-alter"))</bass>"
        }
        if let frame { x += frameXML(frame) }
        return x + "</harmony>"
    }

    // MARK: Import

    struct Imported {
        var score: ScoreData
        /// What couldn't come across (other parts, voices, grace notes…).
        var notes: [String]
    }

    enum ImportError: LocalizedError {
        case unreadable, noPart
        var errorDescription: String? {
            switch self {
            case .unreadable: "The file isn't a MusicXML score MxNoteONE can read."
            case .noPart: "The MusicXML file has no music in it."
            }
        }
    }

    /// Reads a .musicxml / .xml file, or a compressed .mxl (a zip with the score inside).
    static func read(_ url: URL) throws -> Imported {
        if url.pathExtension.lowercased() == "mxl" {
            let folder = FileManager.default.temporaryDirectory.appending(path: "mxl-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: folder) }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let unzip = Process()
            unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            unzip.arguments = ["-q", "-o", url.path, "-d", folder.path]
            try unzip.run()
            unzip.waitUntilExit()
            // The score named in META-INF/container.xml, else the first MusicXML file.
            var root: URL?
            if let container = try? XMLDocument(contentsOf: folder.appending(path: "META-INF/container.xml")),
               let path = (try? container.nodes(forXPath: "//rootfile/@full-path"))?.first?.stringValue {
                root = folder.appending(path: path)
            }
            if root == nil {
                let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
                root = files.first { ["musicxml", "xml"].contains($0.pathExtension.lowercased()) && !$0.path.contains("META-INF") }
            }
            guard let root else { throw ImportError.unreadable }
            return try parse(Data(contentsOf: root))
        }
        return try parse(Data(contentsOf: url))
    }

    static func parse(_ data: Data) throws -> Imported {
        guard let doc = try? XMLDocument(data: data, options: []), let rootElement = doc.rootElement() else { throw ImportError.unreadable }
        guard rootElement.name == "score-partwise" else { throw ImportError.unreadable }
        let parts = rootElement.elements(forName: "part")
        guard !parts.isEmpty else { throw ImportError.noPart }
        var score = ScoreData()
        var notes: [String] = []
        func text(_ e: XMLElement?, _ path: String) -> String? {
            var node: XMLElement? = e
            for name in path.split(separator: "/") { node = node?.elements(forName: String(name)).first }
            return node?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        score.title = text(rootElement, "work/work-title") ?? text(rootElement, "movement-title") ?? ""
        var skippedGrace = 0, extraVoices = 0
        /// One staff of one part (`shared`: the first, which also gives the key changes, tempo and repeats).
        func readStaff(_ part: XMLElement, staff staffNumber: Int, shared: Bool, into base: ScoreData) -> ScoreData {
            var score = base
            score.notes = []
            score.voices = nil
            var divisions = 1.0
            var seenAttributes = false
            var pendingSymbol: String?
            // Dynamics and hairpins for the next note (by voice), slurs on the notes.
            var pendingDynamic: [Bool: String] = [:], pendingHairpin: [Bool: Int] = [:]
            // The bar being read and its key (a key change sets a new one from that bar).
            var barIndex = -1, key = 0
            let stepNames = ["C", "D", "E", "F", "G", "A", "B"]
            let typeNames: [String: ScoreNote.Duration] = ["whole": .whole, "breve": .whole, "half": .half, "quarter": .quarter,
                                                           "eighth": .eighth, "16th": .sixteenth, "32nd": .sixteenth, "64th": .sixteenth]
            // Voice 2: its notes per bar, placed by time (rests fill where it's silent).
            var time = 0.0, v2: [ScoreNote] = [], v2pos = 0.0, v2Bars: [[ScoreNote]] = [], secondVoice: String?, firstVoice: String?
            var seenClef = false
            let mine = "\(staffNumber)"
            for measure in part.elements(forName: "measure") {
                barIndex += 1
                defer {
                    v2Bars.append(v2)
                    v2 = []; v2pos = 0; time = 0
                }
                for child in measure.children ?? [] {
                    guard let e = child as? XMLElement else { continue }
                    switch e.name {
                    case "backup":
                        time -= (text(e, "duration").flatMap(Double.init) ?? 0) / divisions
                    case "forward":
                        time += (text(e, "duration").flatMap(Double.init) ?? 0) / divisions
                    case "attributes":
                        if let d = text(e, "divisions").flatMap(Double.init), d > 0 { divisions = d }
                        if let f = text(e, "key/fifths").flatMap(Int.init).map({ max(-7, min(7, $0)) }) {
                            if barIndex == 0 {
                                score.keyFifths = f
                            } else if f != key, shared {
                                score.setMark(barIndex) { $0.keyFifths = f }
                            }
                            key = f
                        }
                        if !seenAttributes {
                            if let b = text(e, "time/beats").flatMap(Int.init), let u = text(e, "time/beat-type").flatMap(Int.init) {
                                score.beats = b
                                score.beatUnit = u
                            }
                        }
                        if shared, let capo = text(e, "staff-details/capo").flatMap(Int.init), capo > 0 { score.capo = capo }
                        // This staff's clef (a two-staff part numbers them).
                        if !seenClef, let clef = e.elements(forName: "clef").first(where: {
                            ($0.attribute(forName: "number")?.stringValue ?? "1") == mine
                        }), let sign = text(clef, "sign") {
                            score.clef = sign == "F" ? .bass : sign == "percussion" ? .percussion : .treble
                            seenClef = true
                        }
                        seenAttributes = true
                    case "direction":
                        let directionVoice = text(e, "voice") ?? firstVoice ?? ""
                        let second = firstVoice != nil && directionVoice != firstVoice && (secondVoice == nil || secondVoice == directionVoice)
                        // Dynamics and hairpins belong to their staff; tempo marks are read once, with the first staff.
                        let ownStaff = (text(e, "staff") ?? "1") == mine
                        if ownStaff, let marks = e.elements(forName: "direction-type").first?.elements(forName: "dynamics").first,
                           let name = (marks.children ?? []).compactMap({ ($0 as? XMLElement)?.name }).first(where: { ScoreData.dynamics.contains($0) || $0 == "sf" || $0 == "sffz" }) {
                            pendingDynamic[second] = name == "sf" || name == "sffz" ? "sfz" : name
                        }
                        if ownStaff, let wedge = e.elements(forName: "direction-type").first?.elements(forName: "wedge").first,
                           let type = wedge.attribute(forName: "type")?.stringValue {
                            switch type {
                            case "crescendo": pendingHairpin[second] = 1
                            case "diminuendo": pendingHairpin[second] = -1
                            case "stop":
                                // Ends on the note just before.
                                if second {
                                    if let k = v2.lastIndex(where: { !$0.rest }) ?? v2.indices.last { v2[k].hairpinEnd = true }
                                } else if !score.notes.isEmpty {
                                    score.notes[score.notes.count - 1].hairpinEnd = true
                                }
                            default: break
                            }
                        }
                        guard shared else { break }
                        // Tempo: the speed (from <sound>, else the metronome mark in its note), a word, rit. / accel.
                        let metronome = e.elements(forName: "direction-type").compactMap { $0.elements(forName: "metronome").first }.first
                        var unitID = "quarter"
                        if let metronome, let unit = text(metronome, "beat-unit") {
                            let dotted = !metronome.elements(forName: "beat-unit-dot").isEmpty
                            unitID = dotted && unit == "quarter" ? "dotted" : ["half", "eighth"].contains(unit) ? unit : "quarter"
                        }
                        let factor = ScoreData.tempoUnits.first { $0.0 == unitID }?.1 ?? 1
                        let speed = (e.elements(forName: "sound").first?.attribute(forName: "tempo")?.stringValue).flatMap(Double.init)
                            ?? metronome.flatMap { text($0, "per-minute") }.flatMap(Double.init).map { $0 * factor }
                        let words = e.elements(forName: "direction-type").compactMap { text($0, "words") }.joined(separator: " ")
                            .trimmingCharacters(in: .whitespaces)
                        let lower = words.lowercased()
                        let gradual: Int? = ["rit", "ritard", "ritenuto", "rall", "rallentando"].contains(where: { lower.hasPrefix($0) }) ? -1
                            : ["accel", "accelerando", "stringendo"].contains(where: { lower.hasPrefix($0) }) ? 1 : nil
                        let bar = max(0, barIndex)
                        if let speed {
                            let q = max(20, min(400, Int(speed.rounded())))
                            if bar == 0 { score.tempo = q } else { score.setMark(bar) { $0.tempo = q } }
                            if unitID != "quarter" { score.setMark(bar) { $0.tempoUnit = unitID } }
                        }
                        if let gradual {
                            score.setMark(bar) { $0.gradual = gradual }
                        } else if !words.isEmpty, speed != nil || ScoreData.tempoTerms.contains(where: { lower.hasPrefix($0.0.lowercased()) }) || lower.hasPrefix("a tempo") || lower.hasPrefix("tempo") {
                            score.setMark(bar) { $0.tempoText = words }
                            // A tempo word alone: its usual speed.
                            if speed == nil, let term = ScoreData.tempoTerms.first(where: { lower.hasPrefix($0.0.lowercased()) }) {
                                if bar == 0 { score.tempo = term.1 } else { score.setMark(bar) { $0.tempo = term.1 } }
                            }
                        }
                    case "barline":
                        guard shared else { break }
                        switch e.elements(forName: "repeat").first?.attribute(forName: "direction")?.stringValue {
                        case "forward": score.setMark(barIndex) { $0.repeatStart = true }
                        case "backward": score.setMark(barIndex) { $0.repeatEnd = true }
                        default: break
                        }
                    case "harmony":
                        if (text(e, "staff") ?? "1") == mine { pendingSymbol = symbol(from: e) }
                        if shared, e.elements(forName: "frame").first != nil { score.chordDiagrams = true }
                    case "note":
                        if e.elements(forName: "cue").first != nil { skippedGrace += 1; continue }
                        let graceElement = e.elements(forName: "grace").first
                        let isChord = e.elements(forName: "chord").first != nil
                        let length = isChord ? 0 : (text(e, "duration").flatMap(Double.init) ?? 0) / divisions
                        // Only this staff's notes (the other staff of a piano part is read on its own).
                        if (text(e, "staff") ?? "1") != mine { time += length; continue }
                        // The staff's first voice, and one more as voice 2.
                        let voiceID = text(e, "voice") ?? "1"
                        if firstVoice == nil { firstVoice = voiceID }
                        let inSecond: Bool
                        if voiceID == firstVoice {
                            inSecond = false
                        } else if secondVoice == nil || secondVoice == voiceID {
                            secondVoice = voiceID
                            inSecond = true
                        } else {
                            extraVoices += 1
                            time += length
                            continue
                        }
                        let pitch = e.elements(forName: "pitch").first
                        // A drum: its written place, and which instrument (by its MIDI sound, else by place and notehead).
                        let unpitched = e.elements(forName: "unpitched").first
                        let step = text(pitch, "step").flatMap { stepNames.firstIndex(of: $0) }
                            ?? text(unpitched, "display-step").flatMap { stepNames.firstIndex(of: $0) }
                        let octave = text(pitch, "octave").flatMap(Int.init) ?? text(unpitched, "display-octave").flatMap(Int.init) ?? 4
                        var drumID: String?
                        if unpitched != nil, let step {
                            let head: DrumHead = switch text(e, "notehead") {
                            case "x", "cross": .x
                            case "circle-x", "circled": .circleX
                            case "diamond": .diamond
                            default: .normal
                            }
                            let byMidi = e.elements(forName: "instrument").first?.attribute(forName: "id")?.stringValue
                                .flatMap { drumNotes[$0] }.flatMap { DrumKit.instrument(midi: $0) }
                            drumID = (byMidi ?? DrumKit.instrument(diatonic: octave * 7 + step, head: head))?.id
                        }
                        let alter = Int((text(pitch, "alter").flatMap(Double.init) ?? 0).rounded())
                        let hasAccidental = e.elements(forName: "accidental").first != nil
                        if isChord {
                            guard let step else { continue }
                            let written: Int? = hasAccidental || alter != ScoreData.keyAlter(step, fifths: key) ? alter : nil
                            let tone = ChordTone(step: step, octave: octave, alter: drumID == nil ? written : nil, drum: drumID)
                            if inSecond {
                                if var last = v2.popLast() { last.chord = (last.chord ?? []) + [tone]; v2.append(last) }
                            } else if var last = score.notes.popLast() {
                                last.chord = (last.chord ?? []) + [tone]
                                score.notes.append(last)
                            }
                            continue
                        }
                        var note = ScoreNote()
                        note.rest = e.elements(forName: "rest").first != nil || step == nil
                        if let type = text(e, "type"), let d = typeNames[type] {
                            note.duration = d
                            note.dotted = !e.elements(forName: "dot").isEmpty
                        } else if let d = text(e, "duration").flatMap(Double.init) {
                            // No <type>: the nearest length from the duration.
                            let beats = d / divisions
                            let options: [(ScoreNote.Duration, Bool)] = [(.whole, true), (.whole, false), (.half, true), (.half, false), (.quarter, true),
                                                                        (.quarter, false), (.eighth, true), (.eighth, false), (.sixteenth, false)]
                            let best = options.min { abs(ScoreNote(duration: $0.0, dotted: $0.1).beats - beats) < abs(ScoreNote(duration: $1.0, dotted: $1.1).beats - beats) }!
                            note.duration = best.0
                            note.dotted = best.1
                        }
                        if let step, !note.rest {
                            note.step = step
                            note.octave = octave
                            note.drum = drumID
                            note.alter = hasAccidental || alter != ScoreData.keyAlter(step, fifths: key) ? alter : nil
                        }
                        note.tie = e.elements(forName: "tie").contains { $0.attribute(forName: "type")?.stringValue == "start" }
                        if let actual = text(e, "time-modification/actual-notes").flatMap(Int.init),
                           let normal = text(e, "time-modification/normal-notes").flatMap(Int.init), actual > 1, normal > 0, actual != normal {
                            note.tuplet = true
                            note.tupletRatio = actual == 3 && normal == 2 ? nil : [actual, normal]
                        }
                        if let graceElement {
                            note.grace = graceElement.attribute(forName: "slash")?.stringValue == "yes" ? "acciaccatura" : "appoggiatura"
                            note.tuplet = nil; note.tupletRatio = nil
                        }
                        for slur in e.elements(forName: "notations").flatMap({ $0.elements(forName: "slur") }) {
                            switch slur.attribute(forName: "type")?.stringValue {
                            case "start": note.slurStart = true
                            case "stop": note.slurEnd = true
                            default: break
                            }
                        }
                        if let d = pendingDynamic.removeValue(forKey: inSecond) { note.dynamic = d }
                        // Articulations, ornaments, fermata.
                        for notation in e.elements(forName: "notations") {
                            let names = notation.elements(forName: "articulations").flatMap { ($0.children ?? []).compactMap { ($0 as? XMLElement)?.name } }
                            let kinds: [String: String] = ["staccato": "staccato", "staccatissimo": "staccatissimo", "spiccato": "staccatissimo",
                                                           "tenuto": "tenuto", "detached-legato": "tenuto", "accent": "accent", "strong-accent": "marcato"]
                            let found = names.compactMap { kinds[$0] }
                            if !found.isEmpty { note.articulations = Array(NSOrderedSet(array: (note.articulations ?? []) + found)) as? [String] }
                            let ornaments: [String: String] = ["trill-mark": "trill", "mordent": "mordent", "inverted-mordent": "prall", "turn": "turn",
                                                               "inverted-turn": "turn", "delayed-turn": "turn"]
                            if let o = notation.elements(forName: "ornaments").flatMap({ ($0.children ?? []).compactMap { ($0 as? XMLElement)?.name } })
                                .compactMap({ ornaments[$0] }).first { note.ornament = o }
                            if !notation.elements(forName: "fermata").isEmpty { note.fermata = true }
                        }
                        if let h = pendingHairpin.removeValue(forKey: inSecond) { note.hairpin = h }
                        if inSecond {
                            // In step with voice 1: rests where voice 2 starts later.
                            if time > v2pos + 1e-6 { v2 += ScoreData.rests(for: time - v2pos) }
                            v2.append(note)
                            v2pos = time + length
                            time += length
                            continue
                        }
                        time += length
                        if let lyric = e.elements(forName: "lyric").first(where: { ($0.attribute(forName: "number")?.stringValue ?? "1") == "1" })
                            ?? e.elements(forName: "lyric").first, let words = text(lyric, "text"), !words.isEmpty {
                            let syllabic = text(lyric, "syllabic") ?? "single"
                            note.lyric = words + (syllabic == "begin" || syllabic == "middle" ? "-" : "")
                        }
                        if let string = text(e, "notations/technical/string").flatMap(Int.init), (1...6).contains(string) {
                            note.tabString = 6 - string
                            if shared { score.showTab = true }
                        }
                        if let symbol = pendingSymbol {
                            note.chordSymbol = symbol
                            pendingSymbol = nil
                        }
                        score.notes.append(note)
                    default:
                        break
                    }
                }
            }
            // Voice 2: its bars, with whole-bar rests where it's silent and rests to finish a bar.
            if v2Bars.contains(where: { !$0.isEmpty }) {
                var line: [ScoreNote] = []
                for bar in v2Bars {
                    let filled = bar.reduce(0) { $0 + $1.beats }
                    line += bar + ScoreData.rests(for: max(0, score.measureLength - filled))
                }
                score.setLine(1, line)
            }
            return score
        }
        // Every part's staves: a part with two staves (piano) gives two; the first part's become a grand staff.
        // Drum instruments: id → General MIDI drum note.
        var drumNotes: [String: Int] = [:]
        for node in (try? rootElement.nodes(forXPath: "part-list/score-part/midi-instrument")) ?? [] {
            guard let el = node as? XMLElement, let id = el.attribute(forName: "id")?.stringValue,
                  let n = text(el, "midi-unpitched").flatMap(Int.init) else { continue }
            drumNotes[id] = n - 1
        }
        let partNames: [String: String] = Dictionary(uniqueKeysWithValues: ((try? rootElement.nodes(forXPath: "part-list/score-part")) ?? [])
            .compactMap { $0 as? XMLElement }.compactMap { el in el.attribute(forName: "id")?.stringValue.map { ($0, text(el, "part-name") ?? "") } })
        var staves: [ScoreData] = []
        var grand = false
        for (p, part) in parts.enumerated() {
            let count = part.elements(forName: "measure").first?.elements(forName: "attributes").compactMap { text($0, "staves").flatMap(Int.init) }.first ?? 1
            if count > 2 { notes.append("A part with \(count) staves: only its first two were imported.") }
            let name = part.attribute(forName: "id")?.stringValue.flatMap { partNames[$0] } ?? ""
            for k in 1...max(1, min(count, 2)) {
                var staff = readStaff(part, staff: k, shared: p == 0 && k == 1, into: staves.first ?? score)
                if parts.count > 1 || count > 1 {
                    staff.staffName = count > 1 ? nil : (name.isEmpty ? nil : name)
                }
                staves.append(staff)
            }
            if p == 0, count >= 2 { grand = true; if !name.isEmpty, parts.count > 1 { score.staffName = name } }
        }
        let pianoName = score.staffName
        score = staves[0]
        if grand { score.staffName = pianoName }
        for i in 1..<max(1, staves.count) { score.setStaff(i, staves[i]) }
        score.grandStaff = grand ? true : nil
        guard (0..<score.staffCount).contains(where: { !score.forStaff($0).notes.isEmpty }) else { throw ImportError.noPart }
        if extraVoices > 0 { notes.append("\(extraVoices) note\(extraVoices == 1 ? "" : "s") in a third or later voice left out (a score has two voices).") }
        if skippedGrace > 0 { notes.append("\(skippedGrace) cue note\(skippedGrace == 1 ? "" : "s") left out.") }
        return Imported(score: score, notes: notes)
    }

    /// A chord symbol from MusicXML harmony: root, kind (its text, or a name for it) and bass.
    private static func symbol(from e: XMLElement) -> String? {
        func value(_ path: String) -> String? {
            var node: XMLElement? = e
            for name in path.split(separator: "/") { node = node?.elements(forName: String(name)).first }
            return node?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let root = value("root/root-step") else { return nil }
        func accidental(_ s: String?) -> String { s.flatMap(Double.init).map { $0 > 0 ? "♯" : $0 < 0 ? "♭" : "" } ?? "" }
        let kindElement = e.elements(forName: "kind").first
        let kindValue = kindElement?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "major"
        let suffix = kindElement?.attribute(forName: "text")?.stringValue ?? kinds.first { $0.1 == kindValue }?.0 ?? ""
        var symbol = root + accidental(value("root/root-alter")) + suffix
        if let bass = value("bass/bass-step") { symbol += "/" + bass + accidental(value("bass/bass-alter")) }
        return symbol
    }

    // MARK: Files

    static let fileTypes: [UTType] = [UTType(filenameExtension: "musicxml"), UTType(filenameExtension: "mxl"), .xml].compactMap { $0 }

    /// Export MusicXML…: saves a score as a .musicxml file.
    static func save(_ score: ScoreData, from window: NSWindow?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "musicxml") ?? .xml]
        panel.nameFieldStringValue = (score.title.isEmpty ? "Score" : score.title) + ".musicxml"
        let write = { (url: URL) in
            do {
                try export(score).write(to: url, atomically: true, encoding: .utf8)
            } catch {
                NotebookStore.shared.showAlert("Couldn't export the score", error.localizedDescription)
            }
        }
        if let window {
            panel.beginSheetModal(for: window) { if $0 == .OK, let url = panel.url { write(url) } }
        } else if panel.runModal() == .OK, let url = panel.url {
            write(url)
        }
    }
}
