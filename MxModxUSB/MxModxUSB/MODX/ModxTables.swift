//
//  ModxTables.swift — MxModxUSB
//
//  What the MODX's bytes mean, from the MODX Data List (modx_en_dl_d0): System and Sequencer (p. 194–195),
//  Performance Common (p. 197), Performance Part (p. 207–208), Live Set (p. 196), Bank Select (p. 190),
//  Performance Category List (p. 18) and Effect Type List (p. 144–145).
//

import Foundation

/// One setting as the app shows it: a name, its value in words, the raw value, and the address it came from.
struct ModxSetting: Identifiable, Hashable {
    let group: String
    let name: String
    let value: String
    let raw: String
    let address: String
    var id: String { address + name }
}

enum ModxNames {
    static let noteNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

    /// Yamaha's note names: middle C (60) is C3, so note 0 is C-2.
    static func note(_ n: Int) -> String { noteNames[((n % 12) + 12) % 12] + String(n / 12 - 2) }

    static func signed(_ v: UInt8, center: Int = 64) -> String {
        let d = Int(v) - center
        return d > 0 ? "+\(d)" : "\(d)"
    }

    static func pan(_ v: UInt8) -> String {
        v == 64 ? "C" : v < 64 ? "L\(64 - Int(v))" : "R\(Int(v) - 64)"
    }

    static func onOff(_ v: UInt8) -> String { v == 0 ? "Off" : "On" }

    static func pick(_ v: UInt8, _ names: [String]) -> String {
        Int(v) < names.count ? names[Int(v)] : "Value \(v)"
    }

    static func controlNumber(_ v: UInt8, extra: [String] = []) -> String {
        if v == 0 { return "Off" }
        if v <= 95 { return "CC \(v)" }
        return pick(v - 96, extra)
    }

    static let gain = ["-6 dB", "0 dB", "+6 dB", "+12 dB"]

    static let mainCategories = ["Piano", "Keyboard", "Organ", "Guitar", "Bass", "Strings", "Brass", "Woodwind",
                                 "Syn Lead", "Pad/Choir", "Syn Comp", "Chromatic Perc", "Drum/Perc", "Sound FX",
                                 "Musical FX", "Ethnic", "No Assign"]

    private static let genres = ["Rock/Pop", "R&B/Hip Hop", "Electronic", "Jazz/World"]
    static let subCategories: [[String]] = [
        ["Acoustic", "Layer", "Modern", "Vintage"], ["Electric Piano", "FM Piano", "Clavi", "Synth"],
        ["Tone Wheel", "Combo", "Pipe", "Synth"], ["Acoustic", "Electric Clean", "Distortion", "Synth"],
        ["Acoustic", "Electric", "Synth", ""], ["Solo", "Ensemble", "Pizzicato", "Synth"],
        ["Solo", "Ensemble", "Orchestra", "Synth"], ["Saxophone", "Flute", "Woodwind", "Reed/Pipe"],
        ["Analog", "Digital", "Hip Hop", "Dance"], ["Analog", "Warm", "Bright", "Choir"],
        ["Analog", "Digital", "Decay", "Hook"], ["Mallet", "Bell", "Synth Bell", "Pitched Drum"],
        ["Drums", "Percussion", "Synth", ""], ["Moving", "Ambient", "Nature", "Sci-Fi"],
        ["Moving", "Ambient", "Sweep", "Hit"], ["Bowed", "Plucked", "Struck", "Blown"],
    ].map { $0.filter { !$0.isEmpty } + genres }

    /// "Piano / Acoustic"; sub-category index 0 is the first sub-category (checked against Preset 1 #2,
    /// "CFX + FM EP 2": Piano/Acoustic and Keyboard/FM Piano).
    static func category(main: UInt8, sub: UInt8) -> String {
        guard Int(main) < 16 else { return "No Assign" }
        let subs = subCategories[Int(main)]
        let subName = Int(sub) < subs.count ? subs[Int(sub)] : ""
        return subName.isEmpty ? mainCategories[Int(main)] : "\(mainCategories[Int(main)]) / \(subName)"
    }

    /// Performance banks by Bank Select LSB (the MSB is 63 for a single Part, 64 for a whole Performance).
    static func bank(lsb: UInt8) -> String {
        switch lsb {
        case 0x00...0x1F: "Preset \(Int(lsb) + 1)"
        case 0x20...0x24: "User \(Int(lsb) - 0x1F)"
        case 0x28...0x4F: "Library \(Int(lsb) - 0x27)"
        default: String(format: "Bank %02X", lsb)
        }
    }

    static let slotColors = ["Black", "Red", "Yellow", "Green", "Blue", "Azure", "Pink", "Orange", "Purple",
                             "Sakura", "Cream", "Lime", "Aqua", "Beige", "Mint", "Lilac"]

    static func effect(msb: UInt8, lsb: UInt8) -> String {
        if msb == 0 { return "No Effect" }
        return effectTypes[Int(msb) << 8 | Int(lsb)] ?? String(format: "Type %02X %02X", msb, lsb)
    }

    private static let effectTypes: [Int: String] = {
        let list: [(Int, [(Int, String)])] = [
            (0x01, [(0x03, "HD Hall"), (0x00, "REV-X Hall"), (0x01, "R3 Hall"), (0x02, "SPX Hall"), (0x13, "HD Room"),
                    (0x10, "REV-X Room"), (0x11, "R3 Room"), (0x12, "SPX Room"), (0x21, "HD Plate"), (0x20, "R3 Plate"),
                    (0x30, "SPX Stage"), (0x40, "Space Simulator"), (0x50, "Gated Reverb"), (0x58, "Reverse Reverb")]),
            (0x02, [(0x00, "Cross Delay"), (0x10, "Tempo Cross Delay"), (0x20, "Tempo Delay Mono"),
                    (0x28, "Tempo Delay Stereo"), (0x30, "Control Delay"), (0x40, "Delay LR"), (0x50, "Delay LCR"),
                    (0x60, "Analog Delay Retro"), (0x68, "Analog Delay Modern")]),
            (0x03, [(0x00, "G Chorus"), (0x10, "2 Modulator"), (0x20, "SPX Chorus"), (0x30, "Symphonic"),
                    (0x40, "Ensemble Detune")]),
            (0x04, [(0x00, "VCM Flanger"), (0x10, "Classic Flanger"), (0x20, "Tempo Flanger"), (0x30, "Dynamic Flanger"),
                    (0x08, "Control Flanger")]),
            (0x05, [(0x00, "VCM Phaser Mono"), (0x10, "VCM Phaser Stereo"), (0x20, "Tempo Phaser"),
                    (0x30, "Dynamic Phaser"), (0x18, "Control Phaser")]),
            (0x06, [(0x00, "Auto Pan"), (0x10, "Tremolo"), (0x20, "Rotary Speaker 1"), (0x30, "Rotary Speaker 2")]),
            (0x07, [(0x00, "Amp Simulator 1"), (0x10, "Amp Simulator 2"), (0x20, "Comp Distortion"),
                    (0x30, "Comp Distortion Delay"), (0x40, "US Combo"), (0x41, "Jazz Combo"), (0x42, "US High Gain"),
                    (0x43, "British Lead"), (0x44, "Multi FX"), (0x45, "Small Stereo"), (0x46, "British Combo"),
                    (0x47, "British Legend")]),
            (0x08, [(0x00, "VCM Compressor 376"), (0x10, "Classic Compressor"), (0x20, "Multi Band Comp"),
                    (0x30, "Uni Comp Down"), (0x38, "Uni Comp Up"), (0x40, "Parallel Comp")]),
            (0x0A, [(0x00, "VCM Auto Wah"), (0x10, "VCM Touch Wah"), (0x20, "VCM Pedal Wah")]),
            (0x0B, [(0x00, "Lo-Fi"), (0x10, "Noisy"), (0x20, "Digital Turntable"), (0x30, "Bit Crusher")]),
            (0x0C, [(0x00, "Ring Modulator"), (0x10, "Dynamic Ring Modulator"), (0x20, "Dynamic Filter"),
                    (0x30, "Auto Synth"), (0x38, "Spiralizer P"), (0x39, "Tempo Spiralizer P"), (0x3A, "Spiralizer F"),
                    (0x3B, "Tempo Spiralizer F"), (0x40, "Isolator"), (0x50, "Slice"), (0x60, "Tech Modulation"),
                    (0x28, "Control Filter"), (0x70, "Vinyl Break"), (0x78, "Beat Repeat Even"),
                    (0x79, "Beat Repeat Triplet"), (0x7A, "Beat Repeat Even+Triplet"), (0x7B, "Beat Repeat Free")]),
            (0x0D, [(0x00, "VCM EQ 501"), (0x08, "Presence"), (0x10, "Harmonic Enhancer"),
                    (0x18, "Stereophonic Optimizer"), (0x20, "Talking Modulator"), (0x28, "Wave Folder"),
                    (0x29, "VCM Mini Filter"), (0x2A, "VCM Mini Booster"), (0x30, "Damper Resonance"),
                    (0x40, "Pitch Change"), (0x50, "Early Reflection"), (0x60, "Vocoder"),
                    (0x70, "Noise Gate+Comp+EQ")]),
        ]
        var table: [Int: String] = [:]
        for (msb, types) in list { for (lsb, name) in types { table[msb << 8 | lsb] = name } }
        return table
    }()
}

// MARK: System and Sequencer

enum ModxSystemTable {
    /// The System block, 00 00 00, 60 bytes.
    static func settings(_ b: ModxBlock) -> [ModxSetting] {
        func row(_ group: String, _ offset: Int, _ name: String, _ value: String) -> ModxSetting {
            ModxSetting(group: group, name: name, value: value, raw: String(format: "%02X", b[offset]),
                        address: String(format: "00 00 %02X", offset))
        }
        let tune = (Int(b[2] & 0x0F) << 12 | Int(b[3] & 0x0F) << 8 | Int(b[4] & 0x0F) << 4 | Int(b[5] & 0x0F)) - 1024
        let N = ModxNames.self
        return [
            row("Tone Generator", 0x00, "Volume", "\(b[0x00])"),
            row("Tone Generator", 0x01, "Note Shift", "\(N.signed(b[0x01])) semitones"),
            ModxSetting(group: "Tone Generator", name: "Tune", value: String(format: "%+.1f cents", Double(tune) / 10),
                        raw: (2...5).map { String(format: "%02X", b[$0]) }.joined(separator: " "), address: "00 00 02"),
            row("Keyboard", 0x07, "Transpose", "\(N.signed(b[0x07])) semitones"),
            row("Keyboard", 0x08, "Octave Shift", N.signed(b[0x08])),
            row("Keyboard", 0x11, "Velocity Curve", N.pick(b[0x11], ["Normal", "Soft", "Hard", "Wide", "Fixed"])),
            row("Keyboard", 0x12, "Fixed Velocity", "\(b[0x12])"),
            row("Controllers", 0x06, "Controller Reset", N.pick(b[0x06], ["Hold", "Reset"])),
            row("Controllers", 0x16, "Foot Switch Assign", N.controlNumber(b[0x16], extra: ["Arp SW", "Motion Seq SW",
                "Play/Stop", "Live Set +", "Live Set −", "Octave Reset"])),
            row("Controllers", 0x17, "Super Knob Control Number", N.controlNumber(b[0x17])),
            row("Controllers", 0x19, "Scene Select Control Number", N.controlNumber(b[0x19])),
            row("Controllers", 0x3B, "Sustain Pedal", N.pick(b[0x3B], ["FC3A (Half On)", "FC3A (Half Off)", "FC4A/FC5"])),
            row("MIDI", 0x18, "MIDI IN/OUT", N.pick(b[0x18], ["MIDI", "USB"])),
            row("MIDI", 0x30, "MIDI I/O Mode", N.pick(b[0x30], ["Multi", "Single"])),
            row("MIDI", 0x31, "MIDI I/O Channel", "Ch \(Int(b[0x31]) + 1)"),
            row("MIDI", 0x09, "Local Control", N.onOff(b[0x09])),
            row("MIDI", 0x14, "Receive/Transmit Bank Select", N.onOff(b[0x14])),
            row("MIDI", 0x15, "Receive/Transmit Program Change", N.onOff(b[0x15])),
            row("MIDI", 0x28, "Arpeggiator MIDI Out", N.onOff(b[0x28])),
            row("MIDI", 0x29, "MIDI Thru", N.onOff(b[0x29])),
            row("MIDI", 0x1F, "Bulk Interval", "\(Int(b[0x1F]) * 50) ms"),
            row("Audio", 0x0F, "USB Main L&R Output Gain", N.pick(b[0x0F], N.gain)),
            row("Audio", 0x10, "USB Individual Output Gain", N.pick(b[0x10], N.gain)),
            row("Audio", 0x0D, "Analog Output L&R Gain", N.pick(b[0x0D], N.gain)),
            row("Audio", 0x24, "A/D Input Gain", N.pick(b[0x24], ["Mic", "Line"])),
            row("Audio", 0x27, "Direct Monitor", N.onOff(b[0x27])),
            row("Power On", 0x1E, "Power On Mode", N.pick(b[0x1E], ["Performance", "Live Set"])),
            row("Power On", 0x20, "Power On Live Set Bank", b[0x20] == 0 ? "Preset"
                : b[0x20] <= 8 ? "User \(b[0x20])" : "Library \(Int(b[0x20]) - 8)"),
            row("Power On", 0x21, "Power On Live Set Page", "Page \(Int(b[0x21]) + 1)"),
            row("Power On", 0x22, "Power On Live Set Slot", "Slot \(Int(b[0x22]) + 1)"),
            row("Panel", 0x0C, "Touch Panel Sound", N.onOff(b[0x0C])),
            row("Panel", 0x26, "LED Half Glow Brightness", N.pick(b[0x26], ["Off", "1/4", "1/2"])),
            row("Panel", 0x1D, "Audition Lock", N.onOff(b[0x1D])),
        ]
    }

    /// The Sequencer setup block, 00 05 00, 22 bytes.
    static func sequencer(_ b: ModxBlock) -> [ModxSetting] {
        func row(_ offset: Int, _ name: String, _ value: String) -> ModxSetting {
            ModxSetting(group: "Sequencer & Click", name: name, value: value, raw: String(format: "%02X", b[offset]),
                        address: String(format: "00 05 %02X", offset))
        }
        let N = ModxNames.self
        let output: String = switch b[0x01] {
        case 0: "Main L&R"
        case 8: "Assign L&R"
        case 9...12: "USB \(Int(b[0x01] - 9) * 2 + 1)&\(Int(b[0x01] - 9) * 2 + 2)"
        case 64: "Assign L"
        case 65: "Assign R"
        case 66...73: "USB \(Int(b[0x01]) - 65)"
        default: "Output \(b[0x01])"
        }
        return [
            row(0x00, "Click Mode", N.pick(b[0x00], ["Off", "Rec", "Rec/Play", "Always"])),
            row(0x01, "Click Output", output),
            row(0x02, "Click Volume", "\(b[0x02])"),
            row(0x03, "Click Type", "\(Int(b[0x03]) + 1)"),
            row(0x04, "Click Beat", N.pick(b[0x04], ["16th", "8th", "4th", "2nd", "Whole"])),
            row(0x05, "Recording Count", b[0x05] == 0 ? "Off" : "\(b[0x05]) meas"),
            row(0x07, "Transmit Sequencer Control", N.onOff(b[0x07])),
            row(0x08, "Receive Sequencer Control", N.onOff(b[0x08])),
            row(0x09, "Song Event Chase", N.pick(b[0x09], ["Off", "PC", "PC+PB+Ctrl"])),
            row(0x0B, "MIDI Sync", N.pick(b[0x0B], ["Internal", "MIDI", "A/D In"])),
            row(0x0C, "MIDI Clock Out", N.onOff(b[0x0C])),
        ]
    }
}

// MARK: Performance

struct ModxPerformanceCommon: Equatable {
    var name = ""
    var tempo = 0
    var volume = 0
    var pan: UInt8 = 64
    var knobFunction = ""
    var sliderFunction = ""
    var portamento = ""
    var usbMonitorVolume = 0
    var swing = 0
    var unitMultiply = ""
    var knobNumbers: [UInt8] = []
    var knobValues: [UInt8] = []
    var knobNames: [String] = []
    var footController1: UInt8 = 0
    var footController2: UInt8 = 0
    var reverb = ""
    var variation = ""
    var masterEffect = ""
    var insertionAD = ""

    static let unitMultiplies = ["50%", "66%", "75%", "100%", "133%", "150%", "200%", "266%", "300%", "400%"]

    /// From the Performance Common block, 30 40 00 (94 bytes).
    mutating func read(common b: ModxBlock) {
        name = b.text(0x00, 20)
        knobFunction = ModxNames.pick(b[0x1C], ["Tone", "EG/FX", "EQ", "ARP/MS", "Assign"])
        sliderFunction = ModxNames.pick(b[0x1D], ["Part", "Element"])
        pan = b[0x1F]
        tempo = b.value14(0x2C)
        volume = Int(b[0x38])
        portamento = "\(ModxNames.onOff(b[0x3A])), time \(ModxNames.signed(b[0x39]))"
        usbMonitorVolume = Int(b[0x3B])
        footController1 = b[0x45]
        footController2 = b[0x46]
        knobNumbers = (0..<8).map { b[0x4B + $0] }
        knobValues = (0..<8).map { b[0x53 + $0] }
        swing = b.value14(0x5B) - 128
        unitMultiply = ModxNames.pick(b[0x5D], Self.unitMultiplies)
    }

    /// The other Common blocks that matter for an overview: effects and the assignable knobs' names.
    mutating func read(block b: ModxBlock) {
        switch (b.address.high, b.address.mid) {
        case (0x30, 0x40): read(common: b)
        case (0x30, 0x41): reverb = ModxNames.effect(msb: b[0], lsb: b[1])
        case (0x30, 0x42): variation = ModxNames.effect(msb: b[0], lsb: b[1])
        case (0x30, 0x43): insertionAD = ModxNames.effect(msb: b[0], lsb: b[1])
        case (0x30, 0x46): masterEffect = ModxNames.effect(msb: b[0], lsb: b[1])
        case (0x30, 0x50): knobNames = (0..<8).map { b.text($0 * 16, 16) }
        default: break
        }
    }
}

enum ModxPartType: String {
    case awm2 = "AWM2"
    case drum = "Drum"
    case fmx = "FM-X"
    case unknown = "—"
}

struct ModxPart: Identifiable, Equatable {
    let index: Int
    var name = ""
    var mainCategory: UInt8 = 16
    var subCategory: UInt8 = 0
    var partSwitch = false
    var keyboardControl = false
    var mute = false
    var velocityLow: UInt8 = 1
    var velocityHigh: UInt8 = 127
    var noteLow: UInt8 = 0
    var noteHigh: UInt8 = 127
    var volume: UInt8 = 100
    var pan: UInt8 = 64
    var reverbSend: UInt8 = 0
    var variationSend: UInt8 = 0
    var dryLevel: UInt8 = 127
    var noteShift: UInt8 = 64
    var monoPoly: UInt8 = 1
    var output: UInt8 = 0
    var receive: UInt8 = 0x7C
    var type: ModxPartType = .unknown
    var elementsOn = 0
    var loaded = false

    var id: Int { index }
    var number: Int { index + 1 }
    /// A Part with no name is one the Performance doesn't use (the MODX still keeps all 16).
    var inUse: Bool { !name.isEmpty }
    var category: String { ModxNames.category(main: mainCategory, sub: subCategory) }
    var noteRange: String { "\(ModxNames.note(Int(noteLow))) – \(ModxNames.note(Int(noteHigh)))" }
    var velocityRange: String { "\(velocityLow) – \(velocityHigh)" }

    var outputName: String {
        switch output {
        case 0: "Main L&R"
        case 9...12: "USB \(Int(output - 9) * 2 + 1)&\(Int(output - 9) * 2 + 2)"
        case 66...73: "USB \(Int(output) - 65)"
        case 125: "Off"
        case 127: "Drum"
        default: "Output \(output)"
        }
    }

    var receives: String {
        let names = [(6, "PB"), (5, "AT"), (4, "PC"), (3, "Bank"), (2, "CC")]
        let on = names.filter { receive >> $0.0 & 1 == 1 }.map(\.1)
        return on.isEmpty ? "None" : on.joined(separator: " ")
    }

    /// The Part offsets read one Parameter Request each, and where each lands.
    static let requested: [UInt8] = Array(0x00...0x13) + [0x14, 0x15, 0x16, 0x17, 0x18, 0x1C, 0x1D, 0x1E, 0x1F,
                                                          0x24, 0x25, 0x29, 0x2A, 0x2C, 0x2D, 0x36, 0x3F, 0x40]

    /// Everything from the Part's own block, 31 0p 00.
    mutating func read(block b: ModxBlock) {
        name = b.text(0, 20)
        for offset in Self.requested where offset > 0x13 { apply(offset: offset, value: b[Int(offset)]) }
        loaded = true
    }

    mutating func apply(offset: UInt8, value: UInt8) {
        switch offset {
        case 0x00...0x13: break   // the name, gathered separately
        case 0x14: mainCategory = value
        case 0x15: subCategory = value
        case 0x16: partSwitch = value != 0
        case 0x17: keyboardControl = value != 0
        case 0x18: mute = value != 0
        case 0x1C: velocityLow = value
        case 0x1D: velocityHigh = value
        case 0x1E: noteLow = value
        case 0x1F: noteHigh = value
        case 0x24: volume = value
        case 0x25: pan = value
        case 0x29: reverbSend = value
        case 0x2A: variationSend = value
        case 0x2C: dryLevel = value
        case 0x2D: noteShift = value
        case 0x36: monoPoly = value
        case 0x3F: output = value
        case 0x40: receive = value
        default: break
        }
    }
}

// MARK: Live Set

struct ModxLiveSlot: Identifiable, Equatable {
    let page: Int
    let slot: Int
    var name = ""
    var color: UInt8 = 0
    var bankMSB: UInt8 = 0x3F
    var bankLSB: UInt8 = 0
    var number: Int = 1
    var volume: UInt8 = 100
    var on = false

    var id: Int { page * 16 + slot }
    var colorName: String { ModxNames.pick(color, ModxNames.slotColors) }
    var bankName: String { ModxNames.bank(lsb: bankLSB) }
    var isEmpty: Bool { name.isEmpty }

    /// From a slot block: 04 ps 00 (pages 1–8) or 05 ps 00 (pages 9–16), 26 bytes.
    init?(block b: ModxBlock) {
        guard b.address.high == 0x04 || b.address.high == 0x05 else { return nil }
        page = Int(b.address.mid >> 4) + (b.address.high == 0x05 ? 8 : 0)
        slot = Int(b.address.mid & 0x0F)
        name = b.text(0x00, 20)
        color = b[0x14]
        bankMSB = b[0x15]
        bankLSB = b[0x16]
        number = Int(b[0x17]) + 1
        volume = b[0x18]
        on = b[0x19] != 0
    }
}

struct ModxLiveSet: Equatable {
    var bankName = ""
    var pageNames: [String] = Array(repeating: "", count: 16)
    var slots: [ModxLiveSlot] = []

    init(blocks: [ModxBlock]) {
        for b in blocks {
            switch b.address.high {
            case 0x02: bankName = b.text(0, 20)
            case 0x03 where b.address.mid < 16: pageNames[Int(b.address.mid)] = b.text(0, 20)
            default: if let slot = ModxLiveSlot(block: b) { slots.append(slot) }
            }
        }
        slots.sort { $0.id < $1.id }
    }

    func slots(onPage page: Int) -> [ModxLiveSlot] { slots.filter { $0.page == page } }
}

// MARK: User data

struct ModxUserCurve: Identifiable, Equatable {
    let number: Int
    let name: String
    let inputs: [UInt8]
    let outputs: [UInt8]
    let step: Bool
    var id: Int { number }

    /// From a curve block, 01 nn 00 (37 bytes).
    init?(block b: ModxBlock) {
        guard b.address.high == 0x01 else { return nil }
        number = Int(b.address.mid) + 1
        name = b.text(0, 20)
        inputs = (0..<8).map { b[0x14 + $0] }
        outputs = (0..<8).map { b[0x1C + $0] }
        step = b[0x24] == 1
    }
}
