//
//  ModxParameters.swift — MxModxUSB
//
//  Every setting MxModxUSB can show and change, defined once: which block it lives in, its offset, how its bytes
//  encode the value, the values the MODX accepts and how each reads. Taken from the MODX Data List (modx_en_dl_d0):
//  System and Sequencer (p. 194–195), Performance Common (p. 197), Reverb/Variation/Insertion (p. 197–198), Effect
//  Type List (p. 144–145), Performance Part (p. 207–208), Live Set (p. 196), Curve and Micro Tuning (p. 195).
//
//  The table is also the allow-list for writing: MxModxUSB sends a Parameter Change only for an address and size
//  defined here, and only a value inside its range.
//

import Foundation

/// Which block a setting is in.
enum ModxTarget: Hashable, Codable {
    case system, sequencer, common, reverb, variation, insertionA, insertionB, masterEffect
    case part(Int)
    case liveSetBank, liveSetPage(Int), liveSetSlot(page: Int, slot: Int)
    case curve(Int), microTuningName(Int), microTuningTable(Int)

    var base: ModxAddress {
        switch self {
        case .system: ModxAddress(0x00, 0x00, 0x00)
        case .sequencer: ModxAddress(0x00, 0x05, 0x00)
        case .common: ModxAddress(0x30, 0x40, 0x00)
        case .reverb: ModxAddress(0x30, 0x41, 0x00)
        case .variation: ModxAddress(0x30, 0x42, 0x00)
        case .insertionA: ModxAddress(0x30, 0x43, 0x00)
        case .insertionB: ModxAddress(0x30, 0x44, 0x00)
        case .masterEffect: ModxAddress(0x30, 0x46, 0x00)
        case .part(let p): ModxAddress(0x31, UInt8(p), 0x00)
        case .liveSetBank: ModxAddress(0x02, 0x00, 0x00)
        case .liveSetPage(let p): ModxAddress(0x03, UInt8(p), 0x00)
        case .liveSetSlot(let p, let s): ModxAddress(p < 8 ? 0x04 : 0x05, UInt8((p % 8) << 4 | s), 0x00)
        case .curve(let n): ModxAddress(0x01, UInt8(n), 0x00)
        case .microTuningName(let n): ModxAddress(0x00, 0x50 | UInt8(n), 0x00)
        case .microTuningTable(let n): ModxAddress(0x00, 0x30 | UInt8(n), 0x00)
        }
    }

    var params: [ModxParam] {
        switch self {
        case .system: ModxParams.system
        case .sequencer: ModxParams.sequencer
        case .common: ModxParams.common
        case .reverb: ModxParams.reverb
        case .variation: ModxParams.variation
        case .insertionA, .insertionB: ModxParams.insertion
        case .masterEffect: ModxParams.masterEffect
        case .part: ModxParams.part
        case .liveSetBank, .liveSetPage: ModxParams.name
        case .liveSetSlot: ModxParams.slot
        case .curve: ModxParams.curve
        case .microTuningName: ModxParams.name
        case .microTuningTable: ModxParams.microTuning
        }
    }

    var title: String {
        switch self {
        case .system: "System"
        case .sequencer: "Sequencer"
        case .common: "Performance Common"
        case .reverb: "Reverb"
        case .variation: "Variation"
        case .insertionA: "Insertion A (A/D Part)"
        case .insertionB: "Insertion B (A/D Part)"
        case .masterEffect: "Master Effect"
        case .part(let p): "Part \(p + 1)"
        case .liveSetBank: "Live Set bank"
        case .liveSetPage(let p): "Live Set page \(p + 1)"
        case .liveSetSlot(let p, let s): "Live Set page \(p + 1) slot \(s + 1)"
        case .curve(let n): "User Curve \(n + 1)"
        case .microTuningName(let n): "Micro-Tuning \(n + 1) name"
        case .microTuningTable(let n): "Micro-Tuning \(n + 1)"
        }
    }

    /// Changes here go to the MODX's edit buffer: they're lost unless stored on the instrument.
    var isEditBuffer: Bool {
        switch self {
        case .system, .sequencer, .curve, .microTuningName, .microTuningTable: false
        default: true
        }
    }
}

enum ModxEffectSlot {
    case reverb, variation, insertion, adInsertion, master
}

struct ModxParam: Identifiable {
    enum Encoding: Equatable {
        case byte
        /// Two bytes of 7 bits each: bit13-7, bit6-0.
        case value14
        /// n bytes of 4 bits each, most significant first.
        case nibbles(Int)
        /// Two bytes taken as they are (an effect type's MSB and LSB).
        case pair
        /// One bit of a byte whose other bits are other settings.
        case bit(Int)
        case text(Int)
    }

    enum Format {
        case number(suffix: String = "")
        case offset(Int, suffix: String = "")
        case names([String], first: Int = 0)
        case choices([(Int, String)])
        case onOff
        case pan
        case note
        case cc(extra: [String] = [])
        case effect(ModxEffectSlot)
        case custom((Int) -> String)
        case text
    }

    enum Restriction {
        case none, notDrum, drumOnly, partsBelow9
    }

    let key: String
    let group: String
    let name: String
    let offset: Int
    let encoding: Encoding
    let range: ClosedRange<Int>
    let format: Format
    var restriction: Restriction = .none
    /// Asked before the change is sent (e.g. a setting that would end the USB connection).
    var warning: String?

    var id: String { key }

    var size: Int {
        switch encoding {
        case .byte, .bit: 1
        case .value14, .pair: 2
        case .nibbles(let n): n
        case .text(let n): n
        }
    }

    var isText: Bool { if case .text = encoding { true } else { false } }

    /// The value as stored in `data` (a block's data, offset from its base).
    func value(in data: [UInt8]) -> Int? {
        guard offset + size <= data.count else { return nil }
        let b = Array(data[offset..<(offset + size)])
        switch encoding {
        case .byte: return Int(b[0])
        case .value14: return Int(b[0]) << 7 | Int(b[1])
        case .nibbles: return b.reduce(0) { $0 << 4 | Int($1 & 0x0F) }
        case .pair: return Int(b[0]) << 8 | Int(b[1])
        case .bit(let n): return Int(b[0] >> UInt8(n) & 1)
        case .text: return nil
        }
    }

    func text(in data: [UInt8]) -> String? {
        guard case .text(let n) = encoding, offset + n <= data.count else { return nil }
        return ModxSysEx.text(Array(data[offset..<(offset + n)]))
    }

    /// The bytes that set `value`, given the block's current data (a bit shares its byte with other settings).
    func bytes(for value: Int, current data: [UInt8]) -> [UInt8]? {
        guard isAllowed(value) else { return nil }
        switch encoding {
        case .byte: return [UInt8(value)]
        case .value14: return [UInt8(value >> 7 & 0x7F), UInt8(value & 0x7F)]
        case .nibbles(let n): return (0..<n).map { UInt8(value >> (4 * (n - 1 - $0)) & 0x0F) }
        case .pair: return [UInt8(value >> 8 & 0x7F), UInt8(value & 0x7F)]
        case .bit(let n):
            guard offset < data.count else { return nil }
            let mask = UInt8(1 << n)
            return [value == 0 ? data[offset] & ~mask : data[offset] | mask]
        case .text: return nil
        }
    }

    /// ASCII, padded with spaces to the field's length; characters the MODX can't show become spaces.
    func bytes(forText text: String) -> [UInt8]? {
        guard case .text(let n) = encoding else { return nil }
        var out = text.unicodeScalars.prefix(n).map { $0.value >= 0x20 && $0.value < 0x7F ? UInt8($0.value) : 0x20 }
        while out.count < n { out.append(0x20) }
        return out
    }

    func isAllowed(_ value: Int) -> Bool {
        guard range.contains(value) else { return false }
        switch format {
        case .choices(let list): return list.contains { $0.0 == value }
        case .effect(let slot): return ModxEffects.allowed(slot).contains { $0.value == value }
        default: return true
        }
    }

    /// Every value the setting can take, in order (for pickers).
    var allowedValues: [Int] {
        switch format {
        case .choices(let list): list.map(\.0)
        case .effect(let slot): ModxEffects.allowed(slot).map(\.value)
        default: Array(range)
        }
    }

    func display(_ value: Int) -> String {
        switch format {
        case .number(let suffix): return "\(value)\(suffix)"
        case .offset(let center, let suffix):
            let d = value - center
            return (d > 0 ? "+\(d)" : "\(d)") + suffix
        case .names(let names, let first):
            let i = value - first
            return i >= 0 && i < names.count ? names[i] : "Value \(value)"
        case .choices(let list): return list.first { $0.0 == value }?.1 ?? "Value \(value)"
        case .onOff: return value == 0 ? "Off" : "On"
        case .pan: return ModxNames.pan(UInt8(clamping: value))
        case .note: return ModxNames.note(value)
        case .cc(let extra): return ModxNames.controlNumber(UInt8(clamping: value), extra: extra)
        case .effect: return ModxNames.effect(msb: UInt8(value >> 8), lsb: UInt8(value & 0xFF))
        case .custom(let f): return f(value)
        case .text: return ""
        }
    }

    /// Whether the setting applies to this Part (the Data List marks some "not available for Drum Part" and so on).
    func applies(to part: ModxPart?) -> Bool {
        guard let part else { return true }
        switch restriction {
        case .none: return true
        case .notDrum: return part.type != .drum
        case .drumOnly: return part.type == .drum
        case .partsBelow9: return part.index < 8
        }
    }
}

enum ModxEffects {
    struct EffectType: Identifiable {
        let value: Int
        let category: String
        var id: Int { value }
        var name: String { ModxNames.effect(msb: UInt8(value >> 8), lsb: UInt8(value & 0xFF)) }
    }

    private static func t(_ msb: Int, _ lsb: Int, _ category: String) -> EffectType {
        EffectType(value: msb << 8 | lsb, category: category)
    }

    /// The Reverb block's types, in the Effect Type List's order: HD, REV-X, R3 and SPX halls, rooms, plates, stage.
    private static let reverbTypes = [0x03, 0x00, 0x01, 0x02, 0x13, 0x10, 0x11, 0x12, 0x21, 0x20, 0x30, 0x40]
        .map { t(1, $0, "Reverb") }
    private static let shared: [EffectType] = {
        var list = [t(1, 0x02, "Reverb"), t(1, 0x12, "Reverb"), t(1, 0x30, "Reverb"), t(1, 0x50, "Reverb"), t(1, 0x58, "Reverb")]
        list += [0x00, 0x10, 0x20, 0x28, 0x30, 0x40, 0x50, 0x60, 0x68].map { t(2, $0, "Delay") }
        list += [0x00, 0x10, 0x20, 0x30, 0x40].map { t(3, $0, "Chorus") }
        list += [0x00, 0x10, 0x20, 0x30, 0x08].map { t(4, $0, "Flanger") }
        list += [0x00, 0x10, 0x20, 0x30, 0x18].map { t(5, $0, "Phaser") }
        list += [0x00, 0x10, 0x20, 0x30].map { t(6, $0, "Tremolo & Rotary") }
        list += [0x00, 0x10, 0x20, 0x30, 0x40, 0x41, 0x42, 0x43, 0x44, 0x45, 0x46, 0x47].map { t(7, $0, "Distortion") }
        list += [0x00, 0x10, 0x20, 0x30, 0x38, 0x40].map { t(8, $0, "Compressor") }
        list += [0x00, 0x10, 0x20].map { t(0x0A, $0, "Wah") }
        list += [0x00, 0x10, 0x20, 0x30].map { t(0x0B, $0, "Lo-Fi") }
        list += [0x00, 0x10, 0x20, 0x30, 0x38, 0x39, 0x3A, 0x3B, 0x40, 0x50, 0x60, 0x28, 0x70, 0x78, 0x79, 0x7A, 0x7B]
            .map { t(0x0C, $0, "Tech") }
        list += [0x00, 0x08, 0x10, 0x18, 0x20, 0x28, 0x29, 0x2A, 0x30, 0x40, 0x50, 0x60, 0x70].map { t(0x0D, $0, "Misc") }
        return list
    }()
    private static let notOnAD: Set<Int> = [0x0C70, 0x0C78, 0x0C79, 0x0C7A, 0x0C7B]
    private static let master = [t(2, 0x40, "Delay"), t(7, 0x30, "Distortion"), t(8, 0x00, "Compressor"), t(8, 0x20, "Compressor"),
                                 t(8, 0x30, "Compressor"), t(8, 0x38, "Compressor"), t(8, 0x40, "Compressor"), t(0x0B, 0x00, "Lo-Fi"),
                                 t(0x0B, 0x30, "Lo-Fi"), t(0x0C, 0x00, "Tech"), t(0x0C, 0x20, "Tech"), t(0x0C, 0x38, "Tech"),
                                 t(0x0C, 0x39, "Tech"), t(0x0C, 0x3A, "Tech"), t(0x0C, 0x3B, "Tech"), t(0x0C, 0x40, "Tech"),
                                 t(0x0C, 0x50, "Tech"), t(0x0C, 0x70, "Tech"), t(0x0C, 0x78, "Tech"), t(0x0C, 0x79, "Tech"),
                                 t(0x0C, 0x7A, "Tech"), t(0x0C, 0x7B, "Tech"), t(0x0D, 0x08, "Misc"), t(0x0D, 0x28, "Misc"),
                                 t(0x0D, 0x29, "Misc"), t(0x0D, 0x2A, "Misc")]

    /// The types each effect block takes (Effect Type List, the REV / VAR / InsA / InsB / ADIns / Mas columns).
    static func allowed(_ slot: ModxEffectSlot) -> [EffectType] {
        switch slot {
        case .reverb: [t(0, 0, "Off")] + reverbTypes
        case .variation: [t(0, 0, "Off")] + shared
        case .insertion: [t(0, 0, "Thru")] + shared
        case .adInsertion: [t(0, 0, "Thru")] + shared.filter { !notOnAD.contains($0.value) }
        case .master: master
        }
    }
}

enum ModxParams {
    private static func p(_ key: String, _ group: String, _ name: String, _ offset: Int, _ encoding: ModxParam.Encoding = .byte,
                          _ range: ClosedRange<Int> = 0...127, _ format: ModxParam.Format = .number(),
                          _ restriction: ModxParam.Restriction = .none, warning: String? = nil) -> ModxParam {
        ModxParam(key: key, group: group, name: name, offset: offset, encoding: encoding, range: range, format: format,
                  restriction: restriction, warning: warning)
    }

    private static let gains = ["-6 dB", "0 dB", "+6 dB", "+12 dB"]
    private static let swingFormat = ModxParam.Format.custom { "\($0 - 128 > 0 ? "+" : "")\($0 - 128)" }

    /// The System block, 00 00 00 (60 bytes).
    static let system: [ModxParam] = [
        p("sys.volume", "Tone Generator", "Volume", 0x00),
        p("sys.noteShift", "Tone Generator", "Note Shift", 0x01, .byte, 40...88, .offset(64, suffix: " semitones")),
        p("sys.tune", "Tone Generator", "Tune", 0x02, .nibbles(4), 0...2047,
          .custom { String(format: "%+.1f cents", Double($0 - 1024) / 10) }),
        p("sys.transpose", "Keyboard", "Transpose", 0x07, .byte, 53...75, .offset(64, suffix: " semitones")),
        p("sys.octave", "Keyboard", "Octave Shift", 0x08, .byte, 61...67, .offset(64)),
        p("sys.velocityCurve", "Keyboard", "Velocity Curve", 0x11, .byte, 0...4, .names(["Normal", "Soft", "Hard", "Wide", "Fixed"])),
        p("sys.fixedVelocity", "Keyboard", "Fixed Velocity", 0x12, .byte, 1...127),
        p("sys.controllerReset", "Controllers", "Controller Reset", 0x06, .byte, 0...1, .names(["Hold", "Reset"])),
        p("sys.footSwitch", "Controllers", "Foot Switch Assign", 0x16, .byte, 0...101,
          .cc(extra: ["Arp SW", "Motion Seq SW", "Play/Stop", "Live Set +", "Live Set −", "Octave Reset"])),
        p("sys.superKnobCC", "Controllers", "Super Knob Control Number", 0x17, .byte, 0...95, .cc()),
        p("sys.sceneCC", "Controllers", "Scene Select Control Number", 0x19, .byte, 0...95, .cc()),
        p("sys.sustainPedal", "Controllers", "Sustain Pedal", 0x3B, .byte, 0...2,
          .names(["FC3A (Half On)", "FC3A (Half Off)", "FC4A/FC5"])),
        p("sys.midiInOut", "MIDI", "MIDI IN/OUT", 0x18, .byte, 0...1, .names(["MIDI", "USB"]),
          warning: "With MIDI IN/OUT set to MIDI the MODX stops talking over USB: this app loses it until you set it back to USB on the MODX (UTILITY ▸ Settings ▸ MIDI I/O)."),
        p("sys.ioMode", "MIDI", "MIDI I/O Mode", 0x30, .byte, 0...1, .names(["Multi", "Single"])),
        p("sys.ioChannel", "MIDI", "MIDI I/O Channel", 0x31, .byte, 0...15, .custom { "Ch \($0 + 1)" }),
        p("sys.local", "MIDI", "Local Control", 0x09, .byte, 0...1, .onOff,
          warning: "With Local Control off the MODX's keyboard no longer plays its own sounds."),
        p("sys.bankSelect", "MIDI", "Receive/Transmit Bank Select", 0x14, .byte, 0...1, .onOff),
        p("sys.programChange", "MIDI", "Receive/Transmit Program Change", 0x15, .byte, 0...1, .onOff),
        p("sys.arpOut", "MIDI", "Arpeggiator MIDI Out", 0x28, .byte, 0...1, .onOff),
        p("sys.midiThru", "MIDI", "MIDI Thru", 0x29, .byte, 0...1, .onOff),
        p("sys.bulkInterval", "MIDI", "Bulk Interval", 0x1F, .byte, 0...18, .custom { "\($0 * 50) ms" }),
        p("sys.usbMainGain", "Audio", "USB Main L&R Output Gain", 0x0F, .byte, 0...3, .names(gains)),
        p("sys.usbIndividualGain", "Audio", "USB Individual Output Gain", 0x10, .byte, 0...3, .names(gains)),
        p("sys.analogGain", "Audio", "Analog Output L&R Gain", 0x0D, .byte, 0...3, .names(gains)),
        p("sys.adGain", "Audio", "A/D Input Gain", 0x24, .byte, 0...1, .names(["Mic", "Line"])),
        p("sys.directMonitor", "Audio", "Direct Monitor", 0x27, .byte, 0...1, .onOff),
        p("sys.powerOnMode", "Power On", "Power On Mode", 0x1E, .byte, 0...1, .names(["Performance", "Live Set"])),
        p("sys.powerOnBank", "Power On", "Power On Live Set Bank", 0x20, .byte, 0...16,
          .custom { $0 == 0 ? "Preset" : $0 <= 8 ? "User \($0)" : "Library \($0 - 8)" }),
        p("sys.powerOnPage", "Power On", "Power On Live Set Page", 0x21, .byte, 0...15, .custom { "Page \($0 + 1)" }),
        p("sys.powerOnSlot", "Power On", "Power On Live Set Slot", 0x22, .byte, 0...15, .custom { "Slot \($0 + 1)" }),
        p("sys.touchSound", "Panel", "Touch Panel Sound", 0x0C, .byte, 0...1, .onOff),
        p("sys.ledBrightness", "Panel", "LED Half Glow Brightness", 0x26, .byte, 0...2, .names(["Off", "1/4", "1/2"])),
        p("sys.auditionLock", "Panel", "Audition Lock", 0x1D, .byte, 0...1, .onOff),
    ]

    /// The Sequencer setup block, 00 05 00 (22 bytes).
    static let sequencer: [ModxParam] = [
        p("seq.clickMode", "Sequencer & Click", "Click Mode", 0x00, .byte, 0...3, .names(["Off", "Rec", "Rec/Play", "Always"])),
        p("seq.clickOutput", "Sequencer & Click", "Click Output", 0x01, .byte, 0...73,
          .choices([(0, "Main L&R"), (8, "Assign L&R"), (9, "USB 1&2"), (10, "USB 3&4"), (11, "USB 5&6"), (12, "USB 7&8"),
                    (64, "Assign L"), (65, "Assign R")] + (66...73).map { ($0, "USB \($0 - 65)") })),
        p("seq.clickVolume", "Sequencer & Click", "Click Volume", 0x02),
        p("seq.clickType", "Sequencer & Click", "Click Type", 0x03, .byte, 0...9, .custom { "\($0 + 1)" }),
        p("seq.clickBeat", "Sequencer & Click", "Click Beat", 0x04, .byte, 0...4, .names(["16th", "8th", "4th", "2nd", "Whole"])),
        p("seq.recCount", "Sequencer & Click", "Recording Count", 0x05, .byte, 0...8, .custom { $0 == 0 ? "Off" : "\($0) meas" }),
        p("seq.txControl", "Sequencer & Click", "Transmit Sequencer Control", 0x07, .byte, 0...1, .onOff),
        p("seq.rxControl", "Sequencer & Click", "Receive Sequencer Control", 0x08, .byte, 0...1, .onOff),
        p("seq.eventChase", "Sequencer & Click", "Song Event Chase", 0x09, .byte, 0...2, .names(["Off", "PC", "PC+PB+Ctrl"])),
        p("seq.midiSync", "Sequencer & Click", "MIDI Sync", 0x0B, .byte, 0...2, .names(["Internal", "MIDI", "A/D In"])),
        p("seq.clockOut", "Sequencer & Click", "MIDI Clock Out", 0x0C, .byte, 0...1, .onOff),
    ]

    /// Performance Common, 30 40 00 (94 bytes).
    static let common: [ModxParam] = {
        var list = [
            p("com.name", "Performance", "Name", 0x00, .text(20), 0...0, .text),
            p("com.tempo", "Performance", "Tempo", 0x2C, .value14, 5...300, .number(suffix: " BPM")),
            p("com.volume", "Performance", "Volume", 0x38),
            p("com.pan", "Performance", "Pan", 0x1F, .byte, 1...127, .pan),
            p("com.knobFunction", "Performance", "Knob Function", 0x1C, .byte, 0...4, .names(["Tone", "EG/FX", "EQ", "ARP/MS", "Assign"])),
            p("com.sliderFunction", "Performance", "Slider Function", 0x1D, .byte, 0...1, .names(["Part", "Element"])),
            p("com.swing", "Performance", "Swing Offset", 0x5B, .value14, 8...248, swingFormat),
            p("com.unitMultiply", "Performance", "Unit Multiply", 0x5D, .byte, 0...9,
              .names(["50%", "66%", "75%", "100%", "133%", "150%", "200%", "266%", "300%", "400%"])),
            p("com.usbMonitor", "Performance", "USB Monitor Volume", 0x3B),
            p("com.portaSwitch", "Portamento", "Portamento", 0x3A, .byte, 0...1, .onOff),
            p("com.portaTime", "Portamento", "Portamento Time Offset", 0x39, .byte, 0...127, .offset(64)),
        ]
        let tone = [(0x21, "AEG Attack"), (0x22, "AEG Decay"), (0x23, "AEG Sustain"), (0x24, "AEG Release"), (0x25, "FEG Attack"),
                    (0x26, "FEG Decay"), (0x28, "FEG Release"), (0x29, "FEG Depth"), (0x2A, "Cutoff"), (0x2B, "Resonance")]
        list += tone.map { p("com.tone.\($0.0)", "Tone (offsets)", $0.1, $0.0, .byte, 0...127, .offset(64)) }
        list += [
            p("com.as1Mode", "Switches", "Assignable Switch 1 Mode", 0x3D, .byte, 0...1, .names(["Momentary", "Latch"])),
            p("com.as2Mode", "Switches", "Assignable Switch 2 Mode", 0x3E, .byte, 0...1, .names(["Momentary", "Latch"])),
            p("com.msHoldMode", "Switches", "Motion Seq Hold Mode", 0x3F, .byte, 0...1, .names(["Momentary", "Latch"])),
            p("com.ribbonCC", "Controller Numbers", "Ribbon Controller", 0x43, .byte, 0...95, .cc()),
            p("com.breathCC", "Controller Numbers", "Breath Controller", 0x44, .byte, 0...95, .cc()),
            p("com.fc1CC", "Controller Numbers", "Foot Controller 1", 0x45, .byte, 0...96, .cc(extra: ["Super Knob"])),
            p("com.fc2CC", "Controller Numbers", "Foot Controller 2", 0x46, .byte, 0...96, .cc(extra: ["Super Knob"])),
            p("com.as1CC", "Controller Numbers", "Assignable Switch 1", 0x47, .byte, 0...95, .cc()),
            p("com.as2CC", "Controller Numbers", "Assignable Switch 2", 0x48, .byte, 0...95, .cc()),
            p("com.msHoldCC", "Controller Numbers", "Motion Seq Hold", 0x49, .byte, 0...95, .cc()),
            p("com.msTriggerCC", "Controller Numbers", "Motion Seq Trigger", 0x4A, .byte, 0...95, .cc()),
        ]
        list += (0..<8).map { p("com.knob\($0 + 1)CC", "Assignable Knobs", "Knob \($0 + 1) Control Number", 0x4B + $0, .byte, 0...95, .cc()) }
        list += (0..<8).map { p("com.knob\($0 + 1)", "Assignable Knobs", "Knob \($0 + 1) Value", 0x53 + $0) }
        return list
    }()

    static let reverb: [ModxParam] = [
        p("rev.type", "Reverb", "Reverb Type", 0x00, .pair, 0...0x7F7F, .effect(.reverb)),
        p("rev.return", "Reverb", "Reverb Return", 0x44),
        p("rev.pan", "Reverb", "Reverb Pan", 0x45, .byte, 1...127, .pan),
        p("rev.switch", "Reverb", "Reverb Switch", 0x46, .byte, 0...1, .onOff),
    ]

    static let variation: [ModxParam] = [
        p("var.type", "Variation", "Variation Type", 0x00, .pair, 0...0x7F7F, .effect(.variation)),
        p("var.return", "Variation", "Variation Return", 0x44),
        p("var.pan", "Variation", "Variation Pan", 0x45, .byte, 1...127, .pan),
        p("var.toReverb", "Variation", "Send Variation to Reverb", 0x46),
        p("var.switch", "Variation", "Variation Switch", 0x47, .byte, 0...1, .onOff),
    ]

    static let insertion: [ModxParam] = [
        p("ins.type", "Insertion", "Insertion Type", 0x00, .pair, 0...0x7F7F, .effect(.adInsertion)),
    ]

    static let masterEffect: [ModxParam] = [
        p("mfx.type", "Master Effect", "Master Effect Type", 0x00, .pair, 0...0x7F7F, .effect(.master)),
    ]

    /// Performance Part, 31 0p 00 (121 bytes).
    static let part: [ModxParam] = {
        let N = ModxNames.self
        var list = [
            p("part.name", "Part", "Name", 0x00, .text(20), 0...0, .text),
            p("part.main", "Part", "Main Category", 0x14, .byte, 0...16, .names(N.mainCategories)),
            p("part.sub", "Part", "Sub Category", 0x15, .byte, 0...7, .custom { "\($0 + 1)" }),
            p("part.switch", "Part", "Part Switch", 0x16, .byte, 0...1, .onOff),
            p("part.keyboard", "Part", "Keyboard Control", 0x17, .byte, 0...1, .onOff, .partsBelow9),
            p("part.mute", "Part", "Mute", 0x18, .byte, 0...1, .onOff),
            p("part.fxAssign", "Part", "Receive FX Assign", 0x19, .byte, 0...1, .onOff),
            p("part.velLow", "Zone", "Velocity Limit Low", 0x1C, .byte, 1...127),
            p("part.velHigh", "Zone", "Velocity Limit High", 0x1D, .byte, 1...127),
            p("part.noteLow", "Zone", "Note Limit Low", 0x1E, .byte, 0...127, .note),
            p("part.noteHigh", "Zone", "Note Limit High", 0x1F, .byte, 0...127, .note),
            p("part.volume", "Level", "Volume", 0x24),
            p("part.pan", "Level", "Pan", 0x25, .byte, 1...127, .pan),
            p("part.dry", "Level", "Dry Level", 0x2C),
            p("part.reverb", "Level", "Reverb Send", 0x29),
            p("part.variation", "Level", "Variation Send", 0x2A),
            p("part.insSwitch", "Level", "Insertion Effects", 0x26, .byte, 0...3, .names(["A off, B off", "A on, B off", "A off, B on", "A on, B on"])),
            p("part.insConnection", "Level", "Insertion Connection", 0x3B, .byte, 0...2, .names(["Parallel", "Ins A → B", "Ins B → A"])),
            p("part.insToReverb", "Level", "Insertion to Reverb Send", 0x3C, .byte, 0...127, .number(), .drumOnly),
            p("part.insToVariation", "Level", "Insertion to Variation Send", 0x3D, .byte, 0...127, .number(), .drumOnly),
            p("part.output", "Level", "Part Output", 0x3F, .byte, 0...127,
              .choices([(0, "Main L&R"), (9, "USB 1&2"), (10, "USB 3&4"), (11, "USB 5&6"), (12, "USB 7&8")]
                       + (66...73).map { ($0, "USB \($0 - 65)") } + [(125, "Off"), (127, "Drum")])),
            p("part.velDepth", "Pitch & Velocity", "Velocity Sensitivity Depth", 0x22),
            p("part.velOffset", "Pitch & Velocity", "Velocity Sensitivity Offset", 0x23),
            p("part.pbUp", "Pitch & Velocity", "Pitch Bend Range Upper", 0x20, .byte, 16...88, .offset(64)),
            p("part.pbDown", "Pitch & Velocity", "Pitch Bend Range Lower", 0x21, .byte, 16...88, .offset(64)),
            p("part.noteShift", "Pitch & Velocity", "Note Shift", 0x2D, .byte, 40...88, .offset(64, suffix: " semitones"), .notDrum),
            p("part.detune", "Pitch & Velocity", "Detune", 0x27, .nibbles(2), 0...255,
              .custom { String(format: "%+.1f Hz", Double($0 - 128) / 10) }),
            p("part.keyAssign", "Play Mode", "Key Assign", 0x35, .byte, 0...1, .names(["Single", "Multi"]), .notDrum),
            p("part.monoPoly", "Play Mode", "Mono/Poly", 0x36, .byte, 0...1, .names(["Mono", "Poly"]), .notDrum),
            p("part.legato", "Play Mode", "Legato Slope", 0x3A, .byte, 0...7, .number(), .notDrum),
            p("part.root", "Play Mode", "Micro Tuning Root", 0x39, .byte, 0...11, .names(ModxNames.noteNames), .notDrum),
            p("part.portaSwitch", "Play Mode", "Portamento", 0x31, .byte, 0...1, .onOff, .notDrum),
            p("part.portaTime", "Play Mode", "Portamento Time", 0x32, .byte, 0...127, .number(), .notDrum),
            p("part.portaMode", "Play Mode", "Portamento Mode", 0x33, .byte, 0...1, .names(["Fingered", "Full-time"]), .notDrum),
            p("part.portaTimeMode", "Play Mode", "Portamento Time Mode", 0x34, .byte, 0...3,
              .names(["Rate 1", "Time 1", "Rate 2", "Time 2"]), .notDrum),
            p("part.efGain", "Envelope Follower", "Gain", 0x2E, .byte, 16...112,
              .custom { String(format: "%+.1f dB", Double($0 - 64) / 2) }),
            p("part.efAttack", "Envelope Follower", "Attack", 0x2F, .byte, 0...19),
            p("part.efRelease", "Envelope Follower", "Release", 0x30, .byte, 0...15),
        ]
        let receives: [(Int, Int, String)] = [
            (0x40, 6, "Pitch Bend"), (0x40, 5, "Aftertouch"), (0x40, 4, "Program Change"), (0x40, 3, "Bank Select"),
            (0x40, 2, "Control Change"), (0x42, 3, "Modulation Wheel"), (0x42, 2, "Sustain/Sostenuto"), (0x42, 1, "Pan"),
            (0x42, 0, "Volume/Expression"), (0x42, 4, "Foot Controller 1"), (0x42, 5, "Foot Controller 2"),
            (0x43, 6, "Ribbon"), (0x43, 5, "Breath"), (0x43, 4, "Foot Switch"), (0x44, 6, "Motion Seq Trigger"),
            (0x44, 5, "Motion Seq Hold"), (0x44, 4, "Assignable Function 2"), (0x44, 3, "Assignable Function 1"),
            (0x42, 6, "Assignable Knob 1"),
        ] + (2...8).map { (0x41, 8 - $0, "Assignable Knob \($0)") }
        list += receives.map { p("part.rx.\($0.0).\($0.1)", "Receive", $0.2, $0.0, .bit($0.1), 0...1, .onOff) }
        let tone: [(Int, String, ModxParam.Restriction)] = [
            (0x46, "AEG Attack", .none), (0x47, "AEG Decay", .none), (0x48, "AEG Sustain", .notDrum), (0x49, "AEG Release", .notDrum),
            (0x4A, "FEG Attack", .notDrum), (0x4B, "FEG Decay", .notDrum), (0x4C, "FEG Sustain", .notDrum),
            (0x4D, "FEG Release", .notDrum), (0x4E, "FEG Depth", .notDrum), (0x50, "Cutoff", .none), (0x51, "Resonance/Width", .none),
        ]
        list += tone.map { p("part.tone.\($0.0)", "Tone (offsets)", $0.1, $0.0, .byte, 0...127, .offset(64), $0.2) }
        list.append(p("part.elementPan", "Tone (offsets)", "Element Pan", 0x45, .byte, 0...1, .onOff))
        let eqGain = ModxParam.Format.custom { String(format: "%+.2f dB", Double($0 - 64) * 0.375) }
        let eq2Gain = ModxParam.Format.custom { String(format: "%+.1f dB", Double($0 - 64) / 2) }
        let eqType = ModxParam.Format.names(["Thru", "LPF", "HPF", "Low Shelf", "Hi Shelf", "Peak/Dip"])
        list += [
            p("part.eqLowFreq", "EQ", "3-Band Low Frequency", 0x53, .value14, 0...255, .number()),
            p("part.eqLowGain", "EQ", "3-Band Low Gain", 0x55, .byte, 32...96, eqGain),
            p("part.eqMidFreq", "EQ", "3-Band Mid Frequency", 0x57, .value14, 0...255, .number()),
            p("part.eqMidGain", "EQ", "3-Band Mid Gain", 0x59, .byte, 32...96, eqGain),
            p("part.eqMidQ", "EQ", "3-Band Mid Q", 0x5A, .byte, 0...31),
            p("part.eqHighFreq", "EQ", "3-Band High Frequency", 0x5B, .value14, 131...255, .number()),
            p("part.eqHighGain", "EQ", "3-Band High Gain", 0x5D, .byte, 32...96, eqGain),
            p("part.eq1Type", "EQ", "2-Band EQ 1 Type", 0x5F, .byte, 0...5, eqType),
            p("part.eq1Freq", "EQ", "2-Band EQ 1 Frequency", 0x60, .value14, 0...255, .number()),
            p("part.eq1Gain", "EQ", "2-Band EQ 1 Gain", 0x62, .byte, 40...88, eq2Gain),
            p("part.eq1Q", "EQ", "2-Band EQ 1 Q", 0x63, .byte, 1...120),
            p("part.eq2Type", "EQ", "2-Band EQ 2 Type", 0x64, .byte, 0...5, eqType),
            p("part.eq2Freq", "EQ", "2-Band EQ 2 Frequency", 0x65, .value14, 0...255, .number()),
            p("part.eq2Gain", "EQ", "2-Band EQ 2 Gain", 0x67, .byte, 40...88, eq2Gain),
            p("part.eq2Q", "EQ", "2-Band EQ 2 Q", 0x68, .byte, 1...120),
            p("part.eqOut", "EQ", "EQ Output Gain", 0x69, .byte, 40...88, eq2Gain),
        ]
        list += (0..<8).map { p("part.knob\($0 + 1)", "Assignable Knobs", "Knob \($0 + 1) Value", 0x6A + $0) }
        list += [
            p("part.swing", "Motion Sequencer", "Swing", 0x72, .value14, 8...248, swingFormat),
            p("part.msSwitch", "Motion Sequencer", "Motion Seq Part Switch", 0x74, .byte, 0...1, .onOff),
            p("part.msAmplitude", "Motion Sequencer", "Motion Seq Amplitude", 0x75, .byte, 0...127, .offset(64)),
            p("part.msShape", "Motion Sequencer", "Motion Seq Pulse Shape", 0x76, .byte, 14...114, .offset(64)),
            p("part.msSmooth", "Motion Sequencer", "Motion Seq Smooth", 0x77, .byte, 0...127, .offset(64)),
            p("part.msRandom", "Motion Sequencer", "Motion Seq Random", 0x78),
        ]
        return list
    }()

    /// A 20-character name (Live Set bank and pages, micro-tuning tables).
    static let name: [ModxParam] = [p("name", "Name", "Name", 0x00, .text(20), 0...0, .text)]

    /// A Live Set slot, 04/05 ps 00 (26 bytes in the Data List, 30 as a MODX7 dumps it). The MODX shows a slot by the
    /// name of the Performance it recalls; Slot Name is the slot's own (in the preset bank, a description: "SYN PAD").
    static let slot: [ModxParam] = [
        p("slot.name", "Slot", "Slot Name", 0x00, .text(20), 0...0, .text),
        p("slot.color", "Slot", "Color", 0x14, .byte, 0...15, .names(ModxNames.slotColors)),
        p("slot.type", "Slot", "Recalls", 0x15, .byte, 63...64, .choices([(63, "One Part (bank MSB 63)"), (64, "Performance (bank MSB 64)")])),
        p("slot.bank", "Slot", "Bank", 0x16, .byte, 0...79,
          .choices((0...31).map { ($0, "Preset \($0 + 1)") } + (32...36).map { ($0, "User \($0 - 31)") }
                   + (40...79).map { ($0, "Library \($0 - 39)") })),
        p("slot.number", "Slot", "Performance Number", 0x17, .byte, 0...127, .custom { "\($0 + 1)" }),
        p("slot.volume", "Slot", "Volume", 0x18),
        p("slot.switch", "Slot", "Slot Switch", 0x19, .byte, 0...1, .onOff),
    ]

    /// A user curve, 01 nn 00 (37 bytes).
    static let curve: [ModxParam] = {
        var list = [p("curve.name", "Curve", "Name", 0x00, .text(20), 0...0, .text),
                    p("curve.type", "Curve", "Curve Type", 0x24, .byte, 0...1, .names(["Linear", "Step"]))]
        list += (1..<8).map { p("curve.in\($0 + 1)", "Points", "Input \($0 + 1)", 0x14 + $0, .byte, $0...($0 + 120)) }
        list += (0..<8).map { p("curve.out\($0 + 1)", "Points", "Output \($0 + 1)", 0x1C + $0) }
        return list
    }()

    /// A micro-tuning user table, 00 3n 00: twelve notes of −99 … +99 cents.
    static let microTuning: [ModxParam] = (0..<12).map {
        p("mt.\($0)", "Micro-Tuning", ModxNames.noteNames[$0], $0 * 2, .value14, 29...227,
          .custom { "\($0 - 128 > 0 ? "+" : "")\($0 - 128) cents" })
    }

    /// The setting at `address` with `size` bytes, if MxModxUSB knows it (the allow-list for Parameter Changes).
    static func find(_ address: ModxAddress, size: Int) -> (ModxTarget, ModxParam)? {
        for target in allTargets(containing: address) {
            let base = target.base
            guard base.high == address.high, base.mid == address.mid else { continue }
            if let param = target.params.first(where: { $0.offset == Int(address.low) && $0.size == size }) {
                return (target, param)
            }
            // A name is twenty one-character settings (Name 1 … Name 20): each character is written on its own.
            if size == 1, let param = target.params.first(where: {
                $0.isText && ($0.offset..<($0.offset + $0.size)).contains(Int(address.low)) }) {
                return (target, param)
            }
        }
        return nil
    }

    private static func allTargets(containing a: ModxAddress) -> [ModxTarget] {
        switch a.high {
        case 0x00: a.mid == 0x00 ? [.system] : a.mid == 0x05 ? [.sequencer]
            : a.mid >> 4 == 3 ? [.microTuningTable(Int(a.mid & 0x0F))] : a.mid >> 4 == 5 ? [.microTuningName(Int(a.mid & 0x0F))] : []
        case 0x01: [.curve(Int(a.mid))]
        case 0x02: [.liveSetBank]
        case 0x03: [.liveSetPage(Int(a.mid))]
        case 0x04, 0x05: [.liveSetSlot(page: Int(a.mid >> 4) + (a.high == 0x05 ? 8 : 0), slot: Int(a.mid & 0x0F))]
        case 0x30: [.common, .reverb, .variation, .insertionA, .insertionB, .masterEffect]
        case 0x31: a.mid < 16 ? [.part(Int(a.mid))] : []
        default: []
        }
    }
}
