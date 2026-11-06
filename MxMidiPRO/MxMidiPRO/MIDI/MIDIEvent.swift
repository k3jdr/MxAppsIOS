//
//  MIDIEvent.swift — MxMidiPRO
//
//  One MIDI 1.0 message as the monitor shows it, and what kind of message it is.
//

import CoreMIDI
import Foundation

/// IN is a device's output on its way to Logic Pro; OUT is what Logic Pro (or any app) sends to a device.
enum MIDIDirection: UInt8 {
    case input, output
    var label: String { self == .input ? "IN" : "OUT" }
}

/// How the message reached the monitor: listening to a source, the spy driver, or one of our thru ports.
enum MIDIRoute: UInt8 {
    case direct, spy, thru
}

struct MIDIEvent {
    var seq: Int = 0
    let hostTime: UInt64
    let direction: MIDIDirection
    let route: MIDIRoute
    let portID: MIDIUniqueID
    let status: UInt8
    let data1: UInt8
    let data2: UInt8
    /// The whole message, F0 … F7, for system exclusive; nil otherwise.
    let sysex: [UInt8]?

    var kind: MIDIKind { MIDIKind(status: status, data2: data2) }
    var channel: Int? { status >= 0x80 && status < 0xF0 ? Int(status & 0x0F) + 1 : nil }

    var bytes: [UInt8] {
        if let sysex { return sysex }
        switch MIDIEvent.length(ofStatus: status) {
        case 1: return [status]
        case 2: return [status, data1]
        default: return [status, data1, data2]
        }
    }

    /// 14-bit pitch-bend value (0 … 16383, 8192 is centre).
    var bend: Int { Int(data2) << 7 | Int(data1) }

    static func length(ofStatus status: UInt8) -> Int {
        switch status {
        case 0x80...0xBF, 0xE0...0xEF, 0xF2: return 3
        case 0xC0...0xDF, 0xF1, 0xF3: return 2
        default: return 1
        }
    }
}

enum MIDIKind: Int, CaseIterable {
    case noteOn, noteOff, polyPressure, controlChange, programChange, channelPressure, pitchBend
    case sysex, mtcQuarterFrame, songPosition, songSelect, tuneRequest
    case clock, start, continueTransport, stop, activeSensing, systemReset, undefined

    init(status: UInt8, data2: UInt8) {
        switch status & 0xF0 {
        case 0x80: self = .noteOff
        case 0x90: self = data2 == 0 ? .noteOff : .noteOn
        case 0xA0: self = .polyPressure
        case 0xB0: self = .controlChange
        case 0xC0: self = .programChange
        case 0xD0: self = .channelPressure
        case 0xE0: self = .pitchBend
        default:
            switch status {
            case 0xF0: self = .sysex
            case 0xF1: self = .mtcQuarterFrame
            case 0xF2: self = .songPosition
            case 0xF3: self = .songSelect
            case 0xF6: self = .tuneRequest
            case 0xF8: self = .clock
            case 0xFA: self = .start
            case 0xFB: self = .continueTransport
            case 0xFC: self = .stop
            case 0xFE: self = .activeSensing
            case 0xFF: self = .systemReset
            default: self = .undefined
            }
        }
    }

    /// The log's message column, in MMM's upper-case style.
    var label: String {
        switch self {
        case .noteOn: "NOTE_ON"
        case .noteOff: "NOTE_OFF"
        case .polyPressure: "POLY_PRESSURE"
        case .controlChange: "CONTROL_CHANGE"
        case .programChange: "PROGRAM_CHANGE"
        case .channelPressure: "CHANNEL_PRESSURE"
        case .pitchBend: "PITCH_BEND"
        case .sysex: "SYSEX"
        case .mtcQuarterFrame: "MTC_QUARTER_FRAME"
        case .songPosition: "SONG_POSITION"
        case .songSelect: "SONG_SELECT"
        case .tuneRequest: "TUNE_REQUEST"
        case .clock: "CLOCK"
        case .start: "START"
        case .continueTransport: "CONTINUE"
        case .stop: "STOP"
        case .activeSensing: "ACTIVE_SENSING"
        case .systemReset: "SYSTEM_RESET"
        case .undefined: "UNDEFINED"
        }
    }

    var group: MIDIFilterGroup {
        switch self {
        case .noteOn, .noteOff: .notes
        case .polyPressure: .polyPressure
        case .controlChange: .controlChange
        case .programChange: .programChange
        case .channelPressure: .channelPressure
        case .pitchBend: .pitchBend
        case .sysex: .sysex
        case .mtcQuarterFrame, .songPosition, .songSelect, .tuneRequest: .systemCommon
        case .start, .continueTransport, .stop: .transport
        case .clock: .clock
        case .activeSensing: .activeSensing
        case .systemReset, .undefined: .other
        }
    }
}

/// The Types filter's groups. Clock and Active Sensing start hidden: a synced Logic Pro sends 24 clocks per beat
/// and many keyboards send Active Sensing three times a second.
enum MIDIFilterGroup: String, CaseIterable, Identifiable, Codable {
    case notes, polyPressure, controlChange, programChange, channelPressure, pitchBend
    case sysex, systemCommon, transport, clock, activeSensing, other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .notes: "Notes (on / off)"
        case .polyPressure: "Poly Pressure"
        case .controlChange: "Control Change"
        case .programChange: "Program Change"
        case .channelPressure: "Channel Pressure"
        case .pitchBend: "Pitch Bend"
        case .sysex: "System Exclusive"
        case .systemCommon: "MTC, Song Position & Select"
        case .transport: "Start, Continue & Stop"
        case .clock: "Clock"
        case .activeSensing: "Active Sensing"
        case .other: "System Reset & Undefined"
        }
    }

    static let hiddenByDefault: Set<MIDIFilterGroup> = [.clock, .activeSensing]
}
