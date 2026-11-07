//
//  MIDISong.swift — MxModxUSB
//
//  A song to edit and play on the MODX: tracks of notes (with lengths, paired from Note On and Note Off) and their
//  other events, a tempo map and a time signature. Opening a Standard MIDI File splits every track by MIDI channel,
//  as Logic Pro does on import, so each track plays one channel — one Part of the MODX. Saving writes format 1: a
//  conductor track (name, time signature, tempos) and one track per song track. Events the app doesn't edit (other
//  controllers, pitch bend, meta events, SysEx) are kept and saved; SysEx is never played.
//

import Foundation

struct SongNote: Identifiable, Hashable {
    var id = UUID()
    var tick: Int
    var length: Int
    var key: Int
    var velocity: Int
    var end: Int { tick + length }
}

struct SongTrack: Identifiable, Equatable {
    var id = UUID()
    var name: String
    /// 0–15: the channel every event of the track plays on (the MODX's Part channel + 1 in Multi mode).
    var channel: Int
    var notes: [SongNote] = []
    /// Its other events: controllers, program changes, pitch bend and pressure, on the track's channel, and the
    /// track's own meta events and SysEx (saved, never played).
    var events: [SMF.Event] = []
    var muted = false
    var soloed = false

    /// A controller's value at the start of the song (tick 0), if the track sets one there.
    func controller(_ number: UInt8) -> Int? {
        events.first { $0.tick == 0 && $0.kind == 0xB0 && $0.data.first == number }.map { Int($0.data[1]) }
    }

    /// Sets a controller at the start of the song (the mixer's volume and pan).
    mutating func setController(_ number: UInt8, _ value: Int) {
        let v = UInt8(clamping: max(0, min(127, value)))
        if let i = events.firstIndex(where: { $0.tick == 0 && $0.kind == 0xB0 && $0.data.first == number }) {
            events[i].data = [number, v]
        } else {
            events.insert(SMF.Event(tick: 0, status: 0xB0 | UInt8(channel), data: [number, v]), at: 0)
        }
    }

    var volume: Int { controller(7) ?? 100 }
    var pan: Int { controller(10) ?? 64 }
    /// The first Program Change the track sends (1–128), if any.
    var program: Int? { events.first { $0.kind == 0xC0 }.map { Int($0.data[0]) + 1 } }

    mutating func setChannel(_ c: Int) {
        channel = max(0, min(15, c))
        for i in events.indices where events[i].status < 0xF0 {
            events[i].status = events[i].status & 0xF0 | UInt8(channel)
        }
    }

    var lastTick: Int { max(notes.map(\.end).max() ?? 0, events.map(\.tick).max() ?? 0) }
}

struct TempoChange: Equatable {
    var tick: Int
    var microsPerQuarter: Int
    var bpm: Double { 60_000_000 / Double(microsPerQuarter) }
}

struct MIDISong: Equatable {
    var name = "Untitled"
    var division = 480
    var tempos = [TempoChange(tick: 0, microsPerQuarter: 500_000)]
    var beatsPerBar = 4
    var beatUnit = 4
    /// The conductor track's other events (time signatures, key signatures, markers, text), kept for saving.
    var conductor: [SMF.Event] = []
    var tracks: [SongTrack] = []

    // MARK: Time

    var ticksPerBeat: Int { division * 4 / max(1, beatUnit) }
    var ticksPerBar: Int { ticksPerBeat * beatsPerBar }
    var bpm: Double { tempos.first?.bpm ?? 120 }
    var length: Int { tracks.map(\.lastTick).max() ?? 0 }
    /// Whole bars, at least one.
    var bars: Int { max(1, Int((Double(length) / Double(ticksPerBar)).rounded(.up))) }

    func seconds(atTick t: Int) -> Double {
        var seconds = 0.0, from = 0
        var micros = tempos.first?.microsPerQuarter ?? 500_000
        for change in tempos.dropFirst() where change.tick < t {
            seconds += Double(change.tick - from) * Double(micros) / 1e6 / Double(division)
            from = change.tick
            micros = change.microsPerQuarter
        }
        return seconds + Double(t - from) * Double(micros) / 1e6 / Double(division)
    }

    func tick(atSeconds s: Double) -> Int {
        var seconds = 0.0, from = 0
        var micros = tempos.first?.microsPerQuarter ?? 500_000
        for change in tempos.dropFirst() {
            let next = seconds + Double(change.tick - from) * Double(micros) / 1e6 / Double(division)
            if next > s { break }
            seconds = next
            from = change.tick
            micros = change.microsPerQuarter
        }
        return from + Int((s - seconds) * 1e6 * Double(division) / Double(micros))
    }

    /// "bar.beat.tick", from 1.1.1.
    func position(_ tick: Int) -> String {
        let bar = tick / ticksPerBar + 1
        let beat = tick % ticksPerBar / ticksPerBeat + 1
        let sub = tick % ticksPerBeat * 4 / ticksPerBeat + 1   // sixteenths
        return "\(bar).\(beat).\(sub)"
    }

    mutating func setTempo(_ bpm: Double) {
        let micros = Int((60_000_000 / max(20, min(300, bpm))).rounded())
        if tempos.isEmpty || tempos[0].tick != 0 { tempos.insert(TempoChange(tick: 0, microsPerQuarter: micros), at: 0) }
        else { tempos[0].microsPerQuarter = micros }
    }

    // MARK: From and to a Standard MIDI File

    init() {}

    init(smf: SMF, name: String) {
        self.name = name
        division = smf.division
        var tempoByTick: [Int: Int] = [:]
        var signature: (Int, Int)?
        var trackNumber = 0
        for source in smf.tracks {
            let trackName = source.first { $0.metaType == 0x03 }.map { String(decoding: $0.metaData, as: UTF8.self) }
            var byChannel: [Int: [SMF.Event]] = [:]
            var others: [SMF.Event] = []
            for e in source {
                switch e.metaType {
                case 0x51 where e.metaData.count == 3:
                    tempoByTick[e.tick] = e.metaData.reduce(0) { $0 << 8 | Int($1) }
                case 0x58 where e.metaData.count >= 2:
                    if signature == nil { signature = (Int(e.metaData[0]), 1 << Int(e.metaData[1])) }
                    conductor.append(e)
                case 0x03, 0x2F:
                    break
                default:
                    if let c = e.channel { byChannel[c, default: []].append(e) } else { others.append(e) }
                }
            }
            if byChannel.isEmpty {
                conductor += others
                if trackNumber == 0, let trackName, !trackName.isEmpty, smf.tracks.count > 1 { self.name = trackName }
            }
            for (i, c) in byChannel.keys.sorted().enumerated() {
                trackNumber += 1
                let base = trackName.flatMap { $0.isEmpty ? nil : $0 } ?? "Track \(trackNumber)"
                var track = SongTrack(name: byChannel.count > 1 ? "\(base) · Ch \(c + 1)" : base, channel: c)
                let (notes, rest) = Self.pairNotes(byChannel[c]!, end: source.last?.tick ?? 0, division: smf.division)
                track.notes = notes
                track.events = rest + (i == 0 ? others : [])
                tracks.append(track)
            }
        }
        if !tempoByTick.isEmpty {
            tempos = tempoByTick.keys.sorted().map { TempoChange(tick: $0, microsPerQuarter: tempoByTick[$0]!) }
            if tempos[0].tick != 0 { tempos.insert(TempoChange(tick: 0, microsPerQuarter: 500_000), at: 0) }
        }
        if let signature { beatsPerBar = max(1, signature.0); beatUnit = max(1, signature.1) }
    }

    /// Note On / Note Off pairs become notes (a Note On of velocity 0 is a Note Off; a key struck again before its
    /// release closes in order); everything else stays an event.
    static func pairNotes(_ events: [SMF.Event], end: Int, division: Int) -> ([SongNote], [SMF.Event]) {
        var open: [Int: [(tick: Int, velocity: Int)]] = [:]
        var notes: [SongNote] = []
        var rest: [SMF.Event] = []
        for e in events {
            let key = Int(e.data.first ?? 0)
            if e.kind == 0x90, e.data.count == 2, e.data[1] > 0 {
                open[key, default: []].append((e.tick, Int(e.data[1])))
            } else if e.kind == 0x80 || (e.kind == 0x90 && e.data.count == 2) {
                if var list = open[key], !list.isEmpty {
                    let on = list.removeFirst()
                    open[key] = list
                    notes.append(SongNote(tick: on.tick, length: max(1, e.tick - on.tick), key: key, velocity: on.velocity))
                }
            } else {
                rest.append(e)
            }
        }
        for (key, list) in open {
            for on in list { notes.append(SongNote(tick: on.tick, length: max(division / 4, end - on.tick), key: key, velocity: on.velocity)) }
        }
        return (notes.sorted { ($0.tick, $0.key) < ($1.tick, $1.key) }, rest)
    }

    var smf: SMF {
        var conductorTrack: [SMF.Event] = [.meta(0, 0x03, Array(name.utf8))]
        if !conductor.contains(where: { $0.metaType == 0x58 }) {
            let power = UInt8(max(0, Int(log2(Double(max(1, beatUnit))))))
            conductorTrack.append(.meta(0, 0x58, [UInt8(clamping: beatsPerBar), power, 24, 8]))
        }
        conductorTrack += tempos.map { t in .meta(t.tick, 0x51, [UInt8(t.microsPerQuarter >> 16 & 0xFF), UInt8(t.microsPerQuarter >> 8 & 0xFF), UInt8(t.microsPerQuarter & 0xFF)]) }
        conductorTrack += conductor
        var out = SMF(format: 1, division: division, tracks: [conductorTrack.sorted { $0.tick < $1.tick }])
        for track in tracks {
            var list: [(SMF.Event, Int)] = [(.meta(0, 0x03, Array(track.name.utf8)), 0)]
            list += track.events.map { ($0, $0.status < 0xF0 ? 2 : 0) }
            let ch = UInt8(track.channel)
            for n in track.notes {
                list.append((SMF.Event(tick: n.tick, status: 0x90 | ch, data: [UInt8(clamping: n.key), UInt8(clamping: max(1, n.velocity))]), 3))
                list.append((SMF.Event(tick: n.end, status: 0x80 | ch, data: [UInt8(clamping: n.key), 64]), 1))
            }
            // At one tick: meta events, then Note Offs, then controllers, then Note Ons.
            out.tracks.append(list.sorted { ($0.0.tick, $0.1) < ($1.0.tick, $1.1) }.map(\.0))
        }
        return out
    }

    // MARK: Playing

    struct PlayEvent {
        let tick: Int
        let track: UUID
        let bytes: [UInt8]
        let isNoteOn: Bool
    }

    /// The channel messages to play, in order: notes, controllers, pitch bend, pressure — and Bank Select and Program
    /// Change only if asked for (they change the MODX Part's sound). Never SysEx.
    func playEvents(sendProgramChanges: Bool) -> [PlayEvent] {
        var list: [(PlayEvent, Int)] = []
        for track in tracks {
            let ch = UInt8(track.channel)
            for e in track.events where e.status < 0xF0 {
                let isBank = e.kind == 0xB0 && (e.data.first == 0 || e.data.first == 32)
                if (e.kind == 0xC0 || isBank) && !sendProgramChanges { continue }
                list.append((PlayEvent(tick: e.tick, track: track.id, bytes: [e.status & 0xF0 | ch] + e.data, isNoteOn: false), 1))
            }
            for n in track.notes {
                list.append((PlayEvent(tick: n.tick, track: track.id, bytes: [0x90 | ch, UInt8(clamping: n.key), UInt8(clamping: max(1, n.velocity))], isNoteOn: true), 2))
                list.append((PlayEvent(tick: n.end, track: track.id, bytes: [0x80 | ch, UInt8(clamping: n.key), 64], isNoteOn: false), 0))
            }
        }
        return list.sorted { ($0.0.tick, $0.1) < ($1.0.tick, $1.1) }.map(\.0)
    }

    // MARK: A demo song

    /// Eight bars in C (C – Am – F – G, twice) at 100 BPM for the Parts given: chords, bass and melody on the first
    /// three non-drum Parts (fewer if there are fewer), and drums on a drum Part if there is one. Channel n is Part n.
    static func demo(parts: [(index: Int, isDrum: Bool, name: String)]) -> MIDISong {
        var song = MIDISong()
        song.name = "Demo Song"
        song.setTempo(100)
        let q = song.division, bar = song.ticksPerBar
        let voices = parts.filter { !$0.isDrum }
        let chordsPart = voices.first?.index ?? 0
        let bassPart = voices.count > 1 ? voices[1].index : chordsPart
        let melodyPart = voices.count > 2 ? voices[2].index : chordsPart
        let progression: [(root: Int, chord: [Int])] = [(36, [60, 64, 67]), (33, [57, 60, 64]), (29, [53, 57, 60]), (31, [55, 59, 62])]

        var chords = SongTrack(name: "Chords", channel: chordsPart)
        var bass = SongTrack(name: "Bass", channel: bassPart)
        var melody = SongTrack(name: "Melody", channel: melodyPart)
        let tune: [[Int]] = [[72, 74, 76, 79], [76, 74, 72, 69], [69, 72, 74, 72], [71, 74, 79, 74]]
        for b in 0..<8 {
            let start = b * bar
            let step = progression[b % 4]
            for key in step.chord { chords.notes.append(SongNote(tick: start, length: bar - q / 8, key: key, velocity: 72)) }
            for (i, offset) in [0, 0, 7, 12].enumerated() {
                bass.notes.append(SongNote(tick: start + i * q, length: q * 3 / 4, key: step.root + offset, velocity: 92))
            }
            for (i, key) in tune[b % 4].enumerated() where b % 2 == 0 || i < 2 {
                melody.notes.append(SongNote(tick: start + i * q, length: b % 2 == 0 ? q - q / 8 : q * 2 - q / 8, key: key, velocity: 88))
            }
        }
        chords.setController(7, 92); chords.setController(10, 52)
        bass.setController(7, 104); bass.setController(10, 64)
        melody.setController(7, 100); melody.setController(10, 78)
        song.tracks = [chords, bass, melody]
        if let drumPart = parts.first(where: \.isDrum)?.index {
            var drums = SongTrack(name: "Drums", channel: drumPart)
            for b in 0..<8 {
                for beat in 0..<4 {
                    let t = b * bar + beat * q
                    drums.notes.append(SongNote(tick: t, length: q / 4, key: beat % 2 == 0 ? 36 : 38, velocity: beat % 2 == 0 ? 110 : 100))
                    drums.notes.append(SongNote(tick: t, length: q / 4, key: 42, velocity: 80))
                    drums.notes.append(SongNote(tick: t + q / 2, length: q / 4, key: 42, velocity: 64))
                }
            }
            drums.setController(7, 100)
            song.tracks.append(drums)
        }
        return song
    }
}
