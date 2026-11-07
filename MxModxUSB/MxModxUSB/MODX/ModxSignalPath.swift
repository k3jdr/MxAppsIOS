//
//  ModxSignalPath.swift — MxModxUSB
//
//  What the MODX is doing with sound right now, from what the app has read: which Parts the keys play, each Part's
//  path — its two insertion effects, volume and pan, then its dry signal and its sends to the Variation and Reverb, or
//  straight out to a USB output — and what the System effects and the Master Effect are; with the notes that explain
//  what you hear: an echo, a Part switched off or muted, a Part that only the Mac hears, Local Control off.
//
//  Where it comes from (all read already; nothing new is asked of the MODX):
//    Part 31 0p 00: switch 16, Keyboard Control 17, Mute 18, velocity and note limits 1C–1F, volume 24, pan 25,
//      insertion switch 26, Reverb send 29, Variation send 2A, dry level 2C, insertion connection 3B, output 3F,
//      Motion Seq Part Switch 74;
//    Part Insertion A 31 2p 00 and B 31 3p 00 (type: category, type); Part arpeggio 31 6p 00 (Part Arp Switch, 00);
//    Reverb 30 41 00 (type, return 44, pan 45, switch 46); Variation 30 42 00 (type, return 44, pan 45, to Reverb 46,
//      switch 47); Master Effect 30 46 00 (type);
//    System 00 00 00: Local Control 09, MIDI I/O Mode 30, MIDI I/O Channel 31.
//

import Foundation

struct ModxSignalPath: Equatable {
    struct Effect: Equatable {
        enum Kind: Equatable { case none, repeats, reverb, other }
        /// Category << 8 | type, as the MODX stores it (0: no effect).
        var value = 0
        var name = "No Effect"
        var on = true

        var kind: Kind { Self.kind(value) }
        var isNone: Bool { value >> 8 == 0 }
        /// Repeats in time with the Performance's tempo.
        var followsTempo: Bool { name.hasPrefix("Tempo") || name.hasPrefix("Beat Repeat") }

        init(value: Int = 0, on: Bool = true) {
            self.value = value
            self.on = on
            name = ModxNames.effect(msb: UInt8(value >> 8 & 0x7F), lsb: UInt8(value & 0x7F))
        }

        init(block: ModxBlock?, on: Bool = true) {
            self.init(value: block.map { Int($0[0]) << 8 | Int($0[1]) } ?? 0, on: on)
        }

        /// Delays, the delay in Comp Distortion Delay, Beat Repeat: effects that play notes again.
        static func kind(_ value: Int) -> Kind {
            let category = value >> 8, type = value & 0xFF
            if category == 0 { return .none }
            if category == 0x02 || (category == 0x07 && type == 0x30) || (category == 0x0C && (0x78...0x7B).contains(type)) { return .repeats }
            return category == 0x01 ? .reverb : .other
        }
    }

    struct Part: Equatable, Identifiable {
        let index: Int
        var name = ""
        var type = ""
        var switchOn = true
        var keys = true
        var muted = false
        /// Muted by a tutorial's Hear only this Part.
        var mutedToHearOne = false
        var noteLow = 0, noteHigh = 127, velocityLow = 1, velocityHigh = 127
        var volume = 100, pan = 64, dry = 127, reverbSend = 0, variationSend = 0
        var output: UInt8 = 0
        var outputName = "Main L&R"
        var insertionA = Effect()
        var insertionB = Effect()
        var insertionConnection = "Ins A → B"
        var arp = false
        var motionSeq = false
        /// The keys held now that this Part plays.
        var heldNotes: [Int] = []
        /// Channels of MIDI Songs tracks playing it now.
        var fromSong = false

        var id: Int { index }
        var number: Int { index + 1 }
        /// Into the main mix and the System effects (Main L&R); any other output skips them.
        var toMain: Bool { output == 0 }
        var silent: Bool { !switchOn || muted || output == 125 || volume == 0 }
        var sounding: Bool { !silent && (!heldNotes.isEmpty || fromSong) }
        var usbOutput: Bool { (9...12).contains(output) || (66...73).contains(output) }

        /// USB audio channels (0-based, among the MODX's 10: Main L/R, USB 1–8) a direct output goes to.
        var usbChannels: [Int] {
            switch output {
            case 9...12: let first = 2 + Int(output - 9) * 2; return [first, first + 1]
            case 66...73: return [2 + Int(output - 66)]
            default: return []
            }
        }

        func plays(note: Int, velocity: Int) -> Bool {
            let noteOK = noteLow <= noteHigh ? (noteLow...noteHigh).contains(note) : note >= noteLow || note <= noteHigh
            let velocityOK = velocity == 0 || (velocityLow <= velocityHigh ? (velocityLow...velocityHigh).contains(velocity)
                                                 : velocity >= velocityLow || velocity <= velocityHigh)
            return noteOK && velocityOK
        }
    }

    struct Finding: Equatable, Identifiable {
        enum Level: Equatable { case info, notice, warning }
        let id: String
        let level: Level
        let symbol: String
        let text: String
    }

    var parts: [Part] = []
    var variation = Effect()
    var variationReturn = 0, variationPan = 64, variationToReverb = 0
    var reverb = Effect()
    var reverbReturn = 0, reverbPan = 64
    var masterEffect = Effect()
    /// nil until System is read.
    var localControl: Bool?
    var singleChannel: Int?
    var tempo = 0
    var heldNotes: [Int] = []
    var songChannels: Set<Int> = []

    var keyParts: [Part] { localControl == false ? [] : parts.filter { $0.keys && $0.switchOn && !$0.muted } }
    var anySounding: Bool { parts.contains(where: \.sounding) }
    var mainSounding: Bool { parts.contains { $0.sounding && $0.toMain } }

    /// - Parameters:
    ///   - hearOnly: Parts a tutorial muted to hear only its own.
    ///   - songChannels: channels (0-based) MIDI Songs is playing now.
    init(parts modxParts: [ModxPart], store: [ModxAddress: ModxBlock], system: ModxBlock?, tempo: Int,
         notes: Set<Int>, velocity: UInt8, songChannels: Set<Int> = [], hearOnly: Set<Int> = []) {
        self.tempo = tempo
        self.songChannels = songChannels
        heldNotes = notes.sorted()
        if let system {
            localControl = system[0x09] != 0
            singleChannel = system[0x30] == 1 ? Int(system[0x31]) : nil
        }
        let held = heldNotes
        for mp in modxParts where mp.inUse {
            let p = mp.index
            let block = store[ModxAddress(0x31, UInt8(p), 0x00)]
            var part = Part(index: p)
            part.name = mp.name
            part.type = mp.type == .awm2 && mp.elementsOn > 0 ? "AWM2 · \(mp.elementsOn) el" : mp.type.rawValue
            part.switchOn = mp.partSwitch
            part.keys = mp.keyboardControl
            part.muted = mp.mute
            part.mutedToHearOne = mp.mute && hearOnly.contains(p)
            part.noteLow = Int(mp.noteLow); part.noteHigh = Int(mp.noteHigh)
            part.velocityLow = Int(mp.velocityLow); part.velocityHigh = Int(mp.velocityHigh)
            part.volume = Int(mp.volume); part.pan = Int(mp.pan); part.dry = Int(mp.dryLevel)
            part.reverbSend = Int(mp.reverbSend); part.variationSend = Int(mp.variationSend)
            part.output = mp.output
            part.outputName = mp.outputName
            let insSwitch = block.map { Int($0[0x26]) } ?? 0
            part.insertionA = Effect(block: store[ModxAddress(0x31, 0x20 | UInt8(p), 0x00)], on: insSwitch & 1 == 1)
            part.insertionB = Effect(block: store[ModxAddress(0x31, 0x30 | UInt8(p), 0x00)], on: insSwitch & 2 == 2)
            part.insertionConnection = ModxNames.pick(block?[0x3B] ?? 1, ["Parallel", "Ins A → B", "Ins B → A"])
            part.arp = store[ModxAddress(0x31, 0x60 | UInt8(p), 0x00)].map { $0[0] == 1 } ?? false
            part.motionSeq = block.map { $0[0x74] == 1 } ?? false
            if localControl != false, part.keys {   // the keys reach a Part through Keyboard Control
                part.heldNotes = held.filter { part.plays(note: $0, velocity: Int(velocity)) }
            }
            // Multi: channel n plays Part n; Single: the MIDI I/O channel plays the Parts with Keyboard Control on.
            if let single = singleChannel { part.fromSong = songChannels.contains(single) && part.keys }
            else { part.fromSong = songChannels.contains(p) }
            parts.append(part)
        }
        if let b = store[ModxAddress(0x30, 0x42, 0x00)] {
            variation = Effect(block: b, on: b[0x47] != 0)
            variationReturn = Int(b[0x44]); variationPan = Int(b[0x45]); variationToReverb = Int(b[0x46])
        }
        if let b = store[ModxAddress(0x30, 0x41, 0x00)] {
            reverb = Effect(block: b, on: b[0x46] != 0)
            reverbReturn = Int(b[0x44]); reverbPan = Int(b[0x45])
        }
        masterEffect = Effect(block: store[ModxAddress(0x30, 0x46, 0x00)])
    }

    static func pan(_ value: Int) -> String { value == 64 ? "C" : value < 64 ? "L\(64 - value)" : "R\(value - 64)" }

    private static func list(_ numbers: [Int]) -> String {
        guard numbers.count > 1 else { return numbers.first.map(String.init) ?? "" }
        return numbers.dropLast().map(String.init).joined(separator: ", ") + " and \(numbers.last!)"
    }

    private static func partsPhrase(_ parts: [Part]) -> String {
        parts.count == 1 ? "Part \(parts[0].number) (\(parts[0].name))" : "Parts \(list(parts.map(\.number)))"
    }

    /// What explains the sound: the things a player would otherwise have to find on the MODX's screens.
    var findings: [Finding] {
        var out: [Finding] = []
        func add(_ id: String, _ level: Finding.Level, _ symbol: String, _ text: String) {
            out.append(Finding(id: id, level: level, symbol: symbol, text: text))
        }
        if localControl == false {
            add("local", .warning, "pianokeys",
                "Local Control is off: the keys play nothing on the MODX itself — their notes only go out over MIDI, and sound only if something sends them back.")
        } else if !parts.isEmpty {
            let keyed = keyParts
            if keyed.isEmpty {
                add("keys", .warning, "pianokeys", "No Part plays from the keys: every Part is switched off, muted or has Keyboard Control off.")
            } else {
                add("keys", .info, "pianokeys", "The keys play \(Self.partsPhrase(keyed)).")
            }
        }
        if let single = singleChannel {
            add("single", .notice, "cable.connector",
                "MIDI I/O Mode is Single: the MODX takes MIDI on channel \(single + 1) only, for the Parts with Keyboard Control on.")
        }
        let hearOne = parts.filter(\.mutedToHearOne)
        if !hearOne.isEmpty {
            add("hearOne", .info, "speaker.slash",
                "\(Self.partsPhrase(hearOne)) \(hearOne.count == 1 ? "is" : "are") muted by the tutorial's Hear only this Part.")
        }
        for part in parts {
            let n = "Part \(part.number)"
            if !part.switchOn { add("off\(part.index)", .notice, "power", "\(n) (\(part.name)) is switched off."); continue }
            if part.muted && !part.mutedToHearOne { add("mute\(part.index)", .notice, "speaker.slash", "\(n) (\(part.name)) is muted.") }
            if part.muted { continue }
            if part.output == 125 { add("outOff\(part.index)", .warning, "speaker.slash", "\(n)'s output is Off: it makes no sound."); continue }
            if part.volume == 0 { add("vol\(part.index)", .warning, "speaker.slash", "\(n)'s volume is 0.") }
            if part.usbOutput {
                add("usb\(part.index)", .notice, "arrow.right.to.line",
                    "\(n) goes straight to \(part.outputName): it skips the Variation, Reverb and Master Effect and isn't in the MODX's main outputs — only the Mac hears it.")
            }
            if !part.keys && part.switchOn {
                add("kbd\(part.index)", .info, "pianokeys",
                    "\(n) has Keyboard Control off: the keys don't play it, only MIDI on channel \(part.number) does.")
            }
            for (slot, effect) in [("A", part.insertionA), ("B", part.insertionB)] where effect.on && effect.kind == .repeats {
                add("ins\(slot)\(part.index)", .notice, "repeat",
                    "\(n)'s Insertion \(slot), \(effect.name), repeats its notes" + (effect.followsTempo ? " in time with the tempo (\(tempo) BPM)" : "") + " — on this Part only.")
            }
            if part.toMain, part.variationSend > 0, variation.on, variationReturn > 0, variation.kind == .repeats {
                add("echo\(part.index)", .notice, "repeat",
                    "\(n) echoes: it sends \(part.variationSend) to the Variation, \(variation.name) (return \(variationReturn)), which repeats its notes"
                        + (variation.followsTempo ? " in time with the tempo (\(tempo) BPM)." : "."))
            }
            if part.toMain, part.dry == 0, part.reverbSend + part.variationSend > 0 {
                add("dry\(part.index)", .info, "drop", "\(n) is heard only through its effects (Dry Level 0).")
            }
            if part.pan <= 8 || part.pan >= 120 {
                add("pan\(part.index)", .info, "arrow.left.and.right",
                    "\(n) is panned hard \(part.pan < 64 ? "left" : "right") (\(Self.pan(part.pan))).")
            }
            if part.arp {
                add("arp\(part.index)", .info, "circle.grid.cross",
                    "\(n)'s Arpeggio switch is on: while [ARP ON/OFF] is lit, held keys play its pattern.")
            }
        }
        let sending = parts.filter { !$0.silent && $0.toMain }
        if !variation.on, sending.contains(where: { $0.variationSend > 0 }) {
            add("varOff", .info, "power", "The Variation (\(variation.name)) is switched off: the Parts' sends to it do nothing.")
        }
        if !reverb.on, sending.contains(where: { $0.reverbSend > 0 }) {
            add("revOff", .info, "power", "The Reverb (\(reverb.name)) is switched off: the Parts' sends to it do nothing.")
        }
        if !songChannels.isEmpty {
            let fed = parts.filter(\.fromSong)
            add("song", .info, "music.note.list",
                "MIDI Songs is playing on channel\(songChannels.count == 1 ? "" : "s") \(Self.list(songChannels.sorted().map { $0 + 1 }))"
                    + (fed.isEmpty ? ", but no Part takes \(songChannels.count == 1 ? "it" : "them")." : ": \(Self.partsPhrase(fed)) play\(fed.count == 1 ? "s" : "") it."))
        }
        return out
    }
}

extension ModxModel {
    /// The signal path as of now: the read settings with the keys held this moment and the song playing.
    var signalPath: ModxSignalPath {
        var channels: Set<Int> = []
        if studio.isPlaying {
            let tracks = studio.song.tracks
            let soloing = tracks.contains(where: \.soloed)
            channels = Set(tracks.filter { soloing ? $0.soloed : !$0.muted }.map(\.channel))
        }
        return ModxSignalPath(parts: parts, store: store, system: system, tempo: common.tempo, notes: live.notes,
                              velocity: live.lastVelocity, songChannels: channels, hearOnly: Set(tutorial.map { Array($0.mutes.keys) } ?? []))
    }
}
