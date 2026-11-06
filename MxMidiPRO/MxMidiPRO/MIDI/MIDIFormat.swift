//
//  MIDIFormat.swift — MxMidiPRO
//
//  How a message reads in the log, in copies and in exports: MMM's "NOTE_ON  Note=56 Velocity=40" style, with note
//  names (middle C is C3 in Logic Pro), controller names and system-exclusive manufacturers.
//

import CoreMIDI
import Foundation

enum TimeDisplay: String, CaseIterable, Identifiable {
    case sinceReset, clock
    var id: String { rawValue }
    var title: String { self == .sinceReset ? "Seconds since Reset" : "Time of day" }
}

enum LogColumn: String, CaseIterable {
    case seq, time, dir, port, ch, type, data, raw

    var title: String {
        switch self {
        case .seq: "#"
        case .time: "Time"
        case .dir: "Dir"
        case .port: "Port"
        case .ch: "Ch"
        case .type: "Message"
        case .data: "Data"
        case .raw: "Bytes"
        }
    }

    /// Widths in points for 11-point Menlo; Data takes what's left.
    var width: CGFloat {
        switch self {
        case .seq: 46
        case .time: 72
        case .dir: 30
        case .port: 110
        case .ch: 22
        case .type: 116
        case .data: 250
        case .raw: 170
        }
    }
}

struct MIDIFormatter {
    var middleCOctave = 3
    var timeDisplay: TimeDisplay = .sinceReset
    var startTime: UInt64 = 0
    var portNames: [MIDIUniqueID: String] = [:]

    private static let noteNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    private static let clockFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    func noteName(_ note: UInt8) -> String {
        let n = Int(note)
        return Self.noteNames[n % 12] + String(n / 12 + middleCOctave - 5)
    }

    func portName(_ e: MIDIEvent) -> String {
        let name = portNames[e.portID] ?? "Port \(e.portID)"
        return e.route == .thru ? "▸ " + name : name
    }

    func time(_ e: MIDIEvent) -> String {
        switch timeDisplay {
        case .sinceReset:
            return String(format: "%.3f", HostClock.interval(from: startTime, to: e.hostTime))
        case .clock:
            let age = HostClock.interval(from: e.hostTime, to: HostClock.now)
            return Self.clockFormat.string(from: Date().addingTimeInterval(-age))
        }
    }

    func channel(_ e: MIDIEvent) -> String { e.channel.map(String.init) ?? "" }

    func data(_ e: MIDIEvent) -> String {
        switch e.kind {
        case .noteOn, .noteOff:
            return "Note=\(e.data1) \(noteName(e.data1))  Velocity=\(e.data2)"
        case .polyPressure:
            return "Note=\(e.data1) \(noteName(e.data1))  Value=\(e.data2)"
        case .controlChange:
            let name = MIDINames.controller(e.data1)
            return "CC=\(e.data1) Value=\(e.data2)" + (name.isEmpty ? "" : "  \(name)")
        case .programChange:
            return "Program=\(e.data1)"
        case .channelPressure:
            return "Value=\(e.data1)"
        case .pitchBend:
            let offset = e.bend - 8192
            return "Value=\(e.bend) (\(offset >= 0 ? "+" : "")\(offset))"
        case .sysex:
            let bytes = e.sysex ?? []
            let maker = MIDINames.manufacturer(bytes)
            let preview = bytes.prefix(12).map { String(format: "%02X", $0) }.joined(separator: " ")
            return "Length=\(bytes.count)" + (maker.isEmpty ? "" : "  \(maker)") + "  \(preview)"
                + (bytes.count > 12 ? " …" : "")
        case .mtcQuarterFrame:
            let piece = Int(e.data1 >> 4)
            return "Piece=\(piece) \(MIDINames.mtcPiece(piece))  Value=\(e.data1 & 0x0F)"
        case .songPosition:
            let beats = Int(e.data2) << 7 | Int(e.data1)
            return "Beats=\(beats)  (bar \(beats / 16 + 1), beat \(beats % 16 / 4 + 1) in 4/4)"
        case .songSelect:
            return "Song=\(e.data1)"
        default:
            return ""
        }
    }

    func raw(_ e: MIDIEvent) -> String {
        let bytes = e.bytes
        let shown = bytes.prefix(24).map { String(format: "%02X", $0) }.joined(separator: " ")
        return bytes.count > 24 ? shown + " …" : shown
    }

    func text(_ e: MIDIEvent, _ column: LogColumn) -> String {
        switch column {
        case .seq: String(e.seq)
        case .time: time(e)
        case .dir: e.direction.label
        case .port: portName(e)
        case .ch: channel(e)
        case .type: e.kind.label
        case .data: data(e)
        case .raw: raw(e)
        }
    }

    /// A log line for copying and text exports, columns padded as on screen.
    func line(_ e: MIDIEvent, raw includeRaw: Bool) -> String {
        var parts = [pad(String(e.seq), 7, right: true), pad(time(e), 12), pad(e.direction.label, 3),
                     pad(portName(e), 22), pad(channel(e), 2, right: true), pad(e.kind.label, 17), data(e)]
        if includeRaw {
            parts[parts.count - 1] = pad(data(e), 44)
            parts.append(e.bytes.map { String(format: "%02X", $0) }.joined(separator: " "))
        }
        return parts.joined(separator: "  ").trimmingCharacters(in: .whitespaces)
    }

    static let csvHeader = "Seq,Time,Direction,Port,Channel,Message,Data,Bytes"

    func csvRow(_ e: MIDIEvent) -> String {
        let fields = [String(e.seq), time(e), e.direction.label, portName(e), channel(e), e.kind.label, data(e),
                      e.bytes.map { String(format: "%02X", $0) }.joined(separator: " ")]
        return fields.map { field in
            field.contains(where: { $0 == "," || $0 == "\"" }) ? "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : field
        }.joined(separator: ",")
    }

    private func pad(_ s: String, _ width: Int, right: Bool = false) -> String {
        let text = s.count > width ? String(s.prefix(width - 1)) + "…" : s
        let fill = String(repeating: " ", count: max(0, width - text.count))
        return right ? fill + text : text + fill
    }
}

enum MIDINames {
    static func controller(_ cc: UInt8) -> String {
        switch cc {
        case 0: "Bank Select"
        case 1: "Mod Wheel"
        case 2: "Breath"
        case 4: "Foot Pedal"
        case 5: "Portamento Time"
        case 6: "Data Entry"
        case 7: "Volume"
        case 8: "Balance"
        case 10: "Pan"
        case 11: "Expression"
        case 12: "Effect 1"
        case 13: "Effect 2"
        case 32: "Bank Select LSB"
        case 33...63: "\(controller(cc - 32).isEmpty ? "CC \(cc - 32)" : controller(cc - 32)) LSB"
        case 64: "Sustain"
        case 65: "Portamento"
        case 66: "Sostenuto"
        case 67: "Soft Pedal"
        case 68: "Legato"
        case 69: "Hold 2"
        case 70: "Sound Variation"
        case 71: "Resonance"
        case 72: "Release"
        case 73: "Attack"
        case 74: "Cutoff"
        case 75...79: "Sound Controller \(cc - 69)"
        case 84: "Portamento Control"
        case 91: "Reverb"
        case 92: "Tremolo"
        case 93: "Chorus"
        case 94: "Detune"
        case 95: "Phaser"
        case 96: "Data +1"
        case 97: "Data −1"
        case 98: "NRPN LSB"
        case 99: "NRPN MSB"
        case 100: "RPN LSB"
        case 101: "RPN MSB"
        case 120: "All Sound Off"
        case 121: "Reset All Controllers"
        case 122: "Local Control"
        case 123: "All Notes Off"
        case 124: "Omni Off"
        case 125: "Omni On"
        case 126: "Mono On"
        case 127: "Poly On"
        default: ""
        }
    }

    static func manufacturer(_ sysex: [UInt8]) -> String {
        guard sysex.count > 1 else { return "" }
        if sysex[1] == 0x00, sysex.count > 3 {
            switch (sysex[2], sysex[3]) {
            case (0x20, 0x29): return "Focusrite/Novation"
            case (0x20, 0x32): return "Behringer"
            case (0x20, 0x33): return "Access"
            case (0x20, 0x3C): return "Elektron"
            case (0x20, 0x6B): return "Arturia"
            case (0x21, 0x09): return "Native Instruments"
            case (0x21, 0x1D): return "Dreadbox"
            case (0x00, 0x0E): return "Alesis"
            case (0x00, 0x66): return "Mackie"
            case (0x01, 0x05): return "M-Audio"
            case (0x01, 0x0F): return "Line 6"
            default: return String(format: "ID 00 %02X %02X", sysex[2], sysex[3])
            }
        }
        switch sysex[1] {
        case 0x01: return "Sequential"
        case 0x04: return "Moog"
        case 0x06: return "Lexicon"
        case 0x07: return "Kurzweil"
        case 0x0F: return "Ensoniq"
        case 0x10: return "Oberheim"
        case 0x18: return "E-mu"
        case 0x33: return "Clavia (Nord)"
        case 0x3E: return "Waldorf"
        case 0x40: return "Kawai"
        case 0x41: return "Roland"
        case 0x42: return "Korg"
        case 0x43: return "Yamaha"
        case 0x44: return "Casio"
        case 0x47: return "Akai"
        case 0x7D: return "Non-commercial"
        case 0x7E: return "Universal Non-Real Time"
        case 0x7F: return "Universal Real Time"
        default: return String(format: "ID %02X", sysex[1])
        }
    }

    static func mtcPiece(_ piece: Int) -> String {
        ["frames LSB", "frames MSB", "seconds LSB", "seconds MSB", "minutes LSB", "minutes MSB", "hours LSB",
         "hours MSB + rate"][min(max(piece, 0), 7)]
    }
}
