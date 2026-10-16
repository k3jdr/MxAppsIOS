//
//  ScoreMusicXML.swift
//  MxNoteONE
//
//  MusicXML, the format MuseScore, Finale, Sibelius and Dorico exchange
//  scores in: a score exports as MusicXML 4.0 (notes, rests, dots, ties,
//  accidentals, chords, chord symbols, lyrics, key, time, clef, tempo, and
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
        out += """
          <identification><encoding><software>MxNoteONE</software></encoding></identification>
          <part-list><score-part id="P1"><part-name>\(score.showTab == true ? "Guitar" : "Music")</part-name></score-part></part-list>
          <part id="P1">

        """
        let steps = ["C", "D", "E", "F", "G", "A", "B"]
        let measures = score.measures
        for (m, bar) in measures.enumerated() {
            out += "    <measure number=\"\(m + 1)\">\n"
            if m == 0 {
                out += "      <attributes><divisions>\(divisions)</divisions><key><fifths>\(score.keyFifths)</fifths></key>"
                out += "<time><beats>\(score.beats)</beats><beat-type>\(score.beatUnit)</beat-type></time>"
                out += score.clef == .treble ? "<clef><sign>G</sign><line>2</line></clef>" : "<clef><sign>F</sign><line>4</line></clef>"
                out += "</attributes>\n"
                out += "      <direction placement=\"above\"><direction-type><metronome><beat-unit>quarter</beat-unit>"
                out += "<per-minute>\(score.tempo)</per-minute></metronome></direction-type><sound tempo=\"\(score.tempo)\"/></direction>\n"
            }
            for i in bar {
                let note = score.notes[i]
                if let symbol = note.chordSymbol, !symbol.isEmpty { out += "      " + harmony(symbol) + "\n" }
                let tiedFrom = i > 0 && score.notes[i - 1].tie && !note.rest
                let tab = score.showTab == true ? score.tab(i) : []
                func noteXML(chord: Bool, step: Int, octave: Int, alter: Int, accidental: Int?, main: Bool, tabSpot: (string: Int, fret: Int)?) -> String {
                    var x = "      <note>"
                    if chord { x += "<chord/>" }
                    if note.rest {
                        x += "<rest/>"
                    } else {
                        x += "<pitch><step>\(steps[step])</step>" + (alter != 0 ? "<alter>\(alter)</alter>" : "") + "<octave>\(octave)</octave></pitch>"
                    }
                    x += "<duration>\(duration(note))</duration>"
                    if main, tiedFrom { x += "<tie type=\"stop\"/>" }
                    if main, note.tie, !note.rest { x += "<tie type=\"start\"/>" }
                    x += "<voice>1</voice><type>\(types[note.duration]!)</type>"
                    if note.dotted { x += "<dot/>" }
                    if let accidental { x += "<accidental>\(accidental > 0 ? "sharp" : accidental < 0 ? "flat" : "natural")</accidental>" }
                    var notations = ""
                    if main, tiedFrom { notations += "<tied type=\"stop\"/>" }
                    if main, note.tie, !note.rest { notations += "<tied type=\"start\"/>" }
                    if let tabSpot { notations += "<technical><string>\(6 - tabSpot.string)</string><fret>\(tabSpot.fret)</fret></technical>" }
                    if !notations.isEmpty { x += "<notations>\(notations)</notations>" }
                    if main, let lyric = note.lyric, !lyric.isEmpty { x += lyricXML(score, i) }
                    return x + "</note>\n"
                }
                let shift = score.clef == .treble ? 12 : 0
                func spot(_ midi: Int) -> (string: Int, fret: Int)? { tab.first { ScoreData.tuning[$0.string] + $0.fret == midi - shift } }
                let mainMidi = score.midi(i)
                out += noteXML(chord: false, step: note.step, octave: note.octave, alter: note.rest ? 0 : score.soundingAlter(i),
                               accidental: score.showsAccidental(i) ? note.alter : nil, main: true, tabSpot: mainMidi.flatMap(spot))
                for tone in note.chord ?? [] where !note.rest {
                    let alter = tone.alter ?? score.keyAlter(tone.step)
                    let midi = ScoreData.midi(step: tone.step, octave: tone.octave, alter: alter)
                    out += noteXML(chord: true, step: tone.step, octave: tone.octave, alter: alter,
                                   accidental: tone.alter != nil && tone.alter != score.keyAlter(tone.step) ? tone.alter : nil, main: false, tabSpot: spot(midi))
                }
            }
            if m == measures.count - 1 { out += "      <barline location=\"right\"><bar-style>light-heavy</bar-style></barline>\n" }
            out += "    </measure>\n"
        }
        out += "  </part>\n</score-partwise>\n"
        return out
    }

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
    private static func harmony(_ symbol: String) -> String {
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
        guard let part = parts.first else { throw ImportError.noPart }
        var score = ScoreData()
        var notes: [String] = []
        func text(_ e: XMLElement?, _ path: String) -> String? {
            var node: XMLElement? = e
            for name in path.split(separator: "/") { node = node?.elements(forName: String(name)).first }
            return node?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        score.title = text(rootElement, "work/work-title") ?? text(rootElement, "movement-title") ?? ""
        if parts.count > 1 {
            let names = (try? rootElement.nodes(forXPath: "part-list/score-part/part-name"))?.compactMap(\.stringValue) ?? []
            notes.append("Only the first part\(names.first.map { " (\($0))" } ?? "") was imported; \(parts.count - 1) other part\(parts.count > 2 ? "s were" : " was") left out.")
        }
        var divisions = 1.0
        var seenAttributes = false
        var pendingSymbol: String?
        var skippedVoices = 0, skippedGrace = 0, changedKey = false
        let stepNames = ["C", "D", "E", "F", "G", "A", "B"]
        let typeNames: [String: ScoreNote.Duration] = ["whole": .whole, "breve": .whole, "half": .half, "quarter": .quarter,
                                                       "eighth": .eighth, "16th": .sixteenth, "32nd": .sixteenth, "64th": .sixteenth]
        for measure in part.elements(forName: "measure") {
            for child in measure.children ?? [] {
                guard let e = child as? XMLElement else { continue }
                switch e.name {
                case "attributes":
                    if let d = text(e, "divisions").flatMap(Double.init), d > 0 { divisions = d }
                    if let f = text(e, "key/fifths").flatMap(Int.init) {
                        if seenAttributes, f != score.keyFifths { changedKey = true } else { score.keyFifths = max(-7, min(7, f)) }
                    }
                    if !seenAttributes {
                        if let b = text(e, "time/beats").flatMap(Int.init), let u = text(e, "time/beat-type").flatMap(Int.init) {
                            score.beats = b
                            score.beatUnit = u
                        }
                        if let sign = text(e, "clef/sign") { score.clef = sign == "F" ? .bass : .treble }
                    }
                    seenAttributes = true
                case "direction":
                    if let tempo = (e.elements(forName: "sound").first?.attribute(forName: "tempo")?.stringValue).flatMap(Double.init)
                        ?? text(e, "direction-type/metronome/per-minute").flatMap(Double.init) {
                        score.tempo = max(20, min(300, Int(tempo.rounded())))
                    }
                case "harmony":
                    pendingSymbol = symbol(from: e)
                case "note":
                    if e.elements(forName: "grace").first != nil || e.elements(forName: "cue").first != nil { skippedGrace += 1; continue }
                    if let voice = text(e, "voice"), voice != "1" { skippedVoices += 1; continue }
                    if let staff = text(e, "staff"), staff != "1" { skippedVoices += 1; continue }
                    let isChord = e.elements(forName: "chord").first != nil
                    let pitch = e.elements(forName: "pitch").first
                    let step = text(pitch, "step").flatMap { stepNames.firstIndex(of: $0) }
                    let octave = text(pitch, "octave").flatMap(Int.init) ?? 4
                    let alter = Int((text(pitch, "alter").flatMap(Double.init) ?? 0).rounded())
                    let hasAccidental = e.elements(forName: "accidental").first != nil
                    if isChord {
                        guard let step, var last = score.notes.popLast() else { continue }
                        let written: Int? = hasAccidental || alter != score.keyAlter(step) ? alter : nil
                        last.chord = (last.chord ?? []) + [ChordTone(step: step, octave: octave, alter: written)]
                        score.notes.append(last)
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
                        note.alter = hasAccidental || alter != score.keyAlter(step) ? alter : nil
                    }
                    note.tie = e.elements(forName: "tie").contains { $0.attribute(forName: "type")?.stringValue == "start" }
                    if let lyric = e.elements(forName: "lyric").first(where: { ($0.attribute(forName: "number")?.stringValue ?? "1") == "1" })
                        ?? e.elements(forName: "lyric").first, let words = text(lyric, "text"), !words.isEmpty {
                        let syllabic = text(lyric, "syllabic") ?? "single"
                        note.lyric = words + (syllabic == "begin" || syllabic == "middle" ? "-" : "")
                    }
                    if let string = text(e, "notations/technical/string").flatMap(Int.init), (1...6).contains(string) {
                        note.tabString = 6 - string
                        score.showTab = true
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
        guard !score.notes.isEmpty else { throw ImportError.noPart }
        if skippedVoices > 0 { notes.append("\(skippedVoices) note\(skippedVoices == 1 ? "" : "s") in other voices or staves left out (a score has one melody line).") }
        if skippedGrace > 0 { notes.append("\(skippedGrace) grace or cue note\(skippedGrace == 1 ? "" : "s") left out.") }
        if changedKey { notes.append("The key changes during the piece; the first key is used throughout.") }
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
