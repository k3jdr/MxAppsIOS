//
//  ModxVoiceParameters.swift — MxModxUSB
//
//  The voice blocks the FM-X and AWM2 tutorials change, from the MODX Data List (modx_en_dl_d0):
//    AWM2  Element Group 1  41 ep 00  (103 bytes, p. 217)  switch, waveform, zones, level, amplitude EG, pitch
//          Element Group 2  42 ep 00  (70 bytes, p. 218)   filter, filter EG, EQ, LFO
//    FM-X  Part Common      48 0p 00  (86 bytes, p. 219–220) filter, pitch EG, 2nd LFO, algorithm, feedback
//          Operator         49 op 00  (47 bytes, p. 220)   frequency, spectral form, pitch and amplitude EGs, level
//  (e = element 0–7, o = operator 0–7, p = Part 0–15; the mid address byte is e or o in the high nibble, p in the low.)
//  Only what's listed here can be written, and only to a Part of that engine (ModxParam.Restriction .fmxOnly,
//  .awm2Only). Checked against a MODX7's own dumps: an FM-X Part stores its algorithm from 0 (68 is algorithm 69);
//  envelope "times" are lengths (an attack time of 0 is instant).
//

import Foundation

extension ModxParams {
    // MARK: FM-X

    static let fmCommon: [ModxParam] = {
        let r = ModxParam.Restriction.fmxOnly
        var list = [
            p("fm.algorithm", "Algorithm", "Algorithm", 0x4F, .byte, 0...87, .custom { "\($0 + 1)" }, r),
            p("fm.feedback", "Algorithm", "Feedback Level", 0x50, .byte, 0...7, .number(), r),
            p("fm.pitchVel", "Pitch", "Pitch Velocity Sensitivity", 0x06, .byte, 0...127, .offset(64), r),
            p("fm.randomPitch", "Pitch", "Random Pitch Depth", 0x07, .byte, 0...127, .number(), r),
            p("fm.filterType", "Filter", "Filter Type", 0x0B, .byte, 0...21, .custom(ModxVoice.filterTypeName), r),
            p("fm.cutoff", "Filter", "Filter Cutoff", 0x0C, .value14, 0...255, .number(), r),
            p("fm.cutoffVel", "Filter", "Cutoff Velocity Sensitivity", 0x0E, .byte, 0...127, .offset(64), r),
            p("fm.resonance", "Filter", "Filter Resonance", 0x0F, .byte, 0...127, .number(), r),
            p("fm.fegAttack", "Filter EG", "FEG Attack Time", 0x18, .byte, 0...127, .number(), r),
            p("fm.fegDecay1", "Filter EG", "FEG Decay 1 Time", 0x19, .byte, 0...127, .number(), r),
            p("fm.fegDecay2", "Filter EG", "FEG Decay 2 Time", 0x1A, .byte, 0...127, .number(), r),
            p("fm.fegRelease", "Filter EG", "FEG Release Time", 0x1B, .byte, 0...127, .number(), r),
            p("fm.fegDepth", "Filter EG", "FEG Depth", 0x26, .byte, 0...127, .offset(64), r),
            p("fm.pegDepth", "Pitch EG", "PEG Depth", 0x45, .byte, 0...3, .names(["8 oct", "2 oct", "1 oct", "0.5 oct"]), r),
            p("fm.lfoWave", "2nd LFO", "2nd LFO Wave", 0x47, .byte, 0...5,
              .names(["Triangle", "Saw Down", "Saw Up", "Square", "Sine", "S/H"]), r),
            p("fm.lfoSpeed", "2nd LFO", "2nd LFO Speed", 0x48, .byte, 0...99, .number(), r),
            p("fm.lfoPitch", "2nd LFO", "2nd LFO Pitch Modulation Depth", 0x4C, .byte, 0...99, .number(), r),
            p("fm.lfoAmp", "2nd LFO", "2nd LFO Amplitude Modulation Depth", 0x4D, .byte, 0...99, .number(), r),
            p("fm.lfoFilter", "2nd LFO", "2nd LFO Filter Modulation Depth", 0x4E, .byte, 0...99, .number(), r),
        ]
        for (i, name) in ["Initial", "Attack", "Decay 1", "Decay 2", "Release"].enumerated() {
            list.append(p("fm.peg\(i)", "Pitch EG", "PEG \(name) Level", 0x3B + i, .byte, 0...100, .offset(50), r))
        }
        for (i, name) in ["Attack", "Decay 1", "Decay 2", "Release"].enumerated() {
            list.append(p("fm.pegTime\(i)", "Pitch EG", "PEG \(name) Time", 0x40 + i, .byte, 0...99, .number(), r))
        }
        return list
    }()

    static let fmOperator: [ModxParam] = {
        let r = ModxParam.Restriction.fmxOnly
        let curves = ModxParam.Format.names(["-Linear", "-Exp", "+Exp", "+Linear"])
        return [
            p("op.level", "Level", "Operator Level", 0x1A, .byte, 0...99, .number(), r),
            p("op.levelVel", "Level", "Level Velocity Sensitivity", 0x20, .byte, 0...14, .offset(7), r),
            p("op.mode", "Frequency", "Frequency Mode", 0x03, .byte, 0...1, .names(["Ratio", "Fixed"]), r),
            p("op.coarse", "Frequency", "Coarse (ratio)", 0x04, .byte, 0...31, .custom { $0 == 0 ? "0.5" : "\($0)" }, r),
            p("op.fine", "Frequency", "Fine", 0x05, .byte, 0...127, .number(), r),
            p("op.detune", "Frequency", "Detune", 0x06, .byte, 0...30, .offset(15), r),
            p("op.pitchVel", "Frequency", "Pitch Velocity Sensitivity", 0x08, .byte, 0...14, .offset(7), r),
            p("op.keyReset", "Frequency", "Key On Reset", 0x01, .byte, 0...1, .onOff, r),
            p("op.form", "Spectral", "Spectral Form", 0x09, .byte, 0...6,
              .names(["Sine", "All 1", "All 2", "Odd 1", "Odd 2", "Res 1", "Res 2"]), r),
            p("op.skirt", "Spectral", "Spectral Skirt", 0x0A, .byte, 0...7, .number(), r),
            p("op.spectralRes", "Spectral", "Spectral Resonance", 0x0B, .byte, 0...99, .number(), r),
            p("op.aegAttackLevel", "Amplitude EG", "Attack Level", 0x10, .byte, 0...99, .number(), r),
            p("op.aegDecay1Level", "Amplitude EG", "Decay 1 Level", 0x11, .byte, 0...99, .number(), r),
            p("op.aegDecay2Level", "Amplitude EG", "Decay 2 Level (sustain)", 0x12, .byte, 0...99, .number(), r),
            p("op.aegReleaseLevel", "Amplitude EG", "Release Level", 0x13, .byte, 0...99, .number(), r),
            p("op.aegAttack", "Amplitude EG", "Attack Time", 0x14, .byte, 0...99, .number(), r),
            p("op.aegDecay1", "Amplitude EG", "Decay 1 Time", 0x15, .byte, 0...99, .number(), r),
            p("op.aegDecay2", "Amplitude EG", "Decay 2 Time", 0x16, .byte, 0...99, .number(), r),
            p("op.aegRelease", "Amplitude EG", "Release Time", 0x17, .byte, 0...99, .number(), r),
            p("op.aegHold", "Amplitude EG", "Hold Time", 0x18, .byte, 0...99, .number(), r),
            p("op.aegKeyFollow", "Amplitude EG", "Time Key Follow", 0x19, .byte, 0...7, .number(), r),
            p("op.pegInitial", "Pitch EG", "PEG Initial Level", 0x0C, .byte, 0...100, .offset(50), r),
            p("op.pegAttackLevel", "Pitch EG", "PEG Attack Level", 0x0D, .byte, 0...100, .offset(50), r),
            p("op.pegAttack", "Pitch EG", "PEG Attack Time", 0x0E, .byte, 0...99, .number(), r),
            p("op.pegDecay", "Pitch EG", "PEG Decay Time", 0x0F, .byte, 0...99, .number(), r),
            p("op.lsBreak", "Level Scaling", "Break Point", 0x1B, .byte, 0...99, .custom { ModxNames.note(21 + $0) }, r),
            p("op.lsLowDepth", "Level Scaling", "Low Depth", 0x1C, .byte, 0...99, .number(), r),
            p("op.lsHighDepth", "Level Scaling", "High Depth", 0x1D, .byte, 0...99, .number(), r),
            p("op.lsLowCurve", "Level Scaling", "Low Curve", 0x1E, .byte, 0...3, curves, r),
            p("op.lsHighCurve", "Level Scaling", "High Curve", 0x1F, .byte, 0...3, curves, r),
            p("op.lfoPitch", "2nd LFO", "Pitch Depth Offset", 0x21, .byte, 0...7, .number(), r),
            p("op.lfoAmp", "2nd LFO", "Amplitude Depth Offset", 0x22, .byte, 0...7, .number(), r),
            p("op.pitchCtrl", "Controllers", "Pitch Controller Sensitivity", 0x23, .byte, 0...14, .offset(7), r),
            p("op.levelCtrl", "Controllers", "Level Controller Sensitivity", 0x24, .byte, 0...14, .offset(7), r),
        ]
    }()

    // MARK: AWM2

    static let element: [ModxParam] = {
        let r = ModxParam.Restriction.awm2Only
        return [
            p("el.switch", "Element", "Element Switch", 0x00, .byte, 0...1, .onOff, r),
            p("el.level", "Element", "Element Level", 0x28, .byte, 0...127, .number(), r),
            p("el.pan", "Element", "Pan", 0x08, .byte, 1...127, .pan, r),
            p("el.xa", "Element", "XA Control", 0x0C, .byte, 0...7,
              .names(["Normal", "Legato", "Key Off", "Cycle", "Random", "A.SW Off", "A.SW1 On", "A.SW2 On"]), r),
            p("el.connection", "Element", "Element Connection", 0x17, .byte, 0...2, .names(["Thru", "InsA", "InsB"]), r),
            p("el.partLFO", "Element", "Part LFO Element Switch", 0x23, .pair, 0...7,
              .custom { bits in bits == 0 ? "Off" : "Box " + (0..<3).filter { bits >> $0 & 1 == 1 }.map { "\($0 + 1)" }.joined(separator: ", ") }, r),
            p("el.waveBank", "Waveform", "Wave Bank", 0x01, .byte, 0...9,
              .names(["Preset", "User"] + (1...8).map { "Library \($0)" }), r),
            p("el.wave", "Waveform", "Waveform", 0x03, .value14, 1...6347, .custom(ModxVoice.waveName), r),
            p("el.noteLow", "Zone", "Note Limit Low", 0x0D, .byte, 0...127, .note, r),
            p("el.noteHigh", "Zone", "Note Limit High", 0x0E, .byte, 0...127, .note, r),
            p("el.velLow", "Zone", "Velocity Limit Low", 0x0F, .byte, 1...127, .number(), r),
            p("el.velHigh", "Zone", "Velocity Limit High", 0x10, .byte, 1...127, .number(), r),
            p("el.velFade", "Zone", "Velocity Cross Fade", 0x11, .byte, 0...127, .number(), r),
            p("el.levelVel", "Amplitude", "Level Velocity Sensitivity", 0x29, .byte, 0...127, .offset(64), r),
            p("el.levelVelOffset", "Amplitude", "Level Velocity Offset", 0x2A, .byte, 0...127, .number(), r),
            p("el.aegAttack", "Amplitude EG", "Attack Time", 0x2D, .byte, 0...127, .number(), r),
            p("el.aegDecay1", "Amplitude EG", "Decay 1 Time", 0x2E, .byte, 0...127, .number(), r),
            p("el.aegDecay2", "Amplitude EG", "Decay 2 Time", 0x2F, .byte, 0...127, .number(), r),
            p("el.aegRelease", "Amplitude EG", "Release Time", 0x31, .byte, 0...127, .number(), r),
            p("el.aegInitial", "Amplitude EG", "Initial Level", 0x32, .byte, 0...127, .number(), r),
            p("el.aegAttackLevel", "Amplitude EG", "Attack Level", 0x33, .byte, 0...127, .number(), r),
            p("el.aegDecay1Level", "Amplitude EG", "Decay 1 Level", 0x34, .byte, 0...127, .number(), r),
            p("el.aegDecay2Level", "Amplitude EG", "Decay 2 Level (sustain)", 0x35, .byte, 0...127, .number(), r),
            p("el.coarse", "Pitch", "Coarse Tune", 0x49, .byte, 16...112, .offset(64, suffix: " semitones"), r),
            p("el.fine", "Pitch", "Fine Tune", 0x4A, .byte, 0...127, .offset(64), r),
            p("el.pitchVel", "Pitch", "Pitch Velocity Sensitivity", 0x4B, .byte, 0...127, .offset(64), r),
            p("el.randomPitch", "Pitch", "Random Pitch Depth", 0x4D, .byte, 0...127, .number(), r),
            p("el.pegDepth", "Pitch", "PEG Depth", 0x60, .byte, 0...127, .offset(64), r),
        ]
    }()

    static let elementFilter: [ModxParam] = {
        let r = ModxParam.Restriction.awm2Only
        let level = ModxParam.Format.offset(128)
        return [
            p("ef.type", "Filter", "Filter Type", 0x00, .byte, 0...21, .custom(ModxVoice.filterTypeName), r),
            p("ef.cutoff", "Filter", "Cutoff", 0x01, .value14, 0...255, .number(), r),
            p("ef.resonance", "Filter", "Resonance", 0x05, .byte, 0...127, .number(), r),
            p("ef.cutoffVel", "Filter", "Cutoff Velocity Sensitivity", 0x03, .byte, 0...127, .offset(64), r),
            p("ef.hpf", "Filter", "HPF Cutoff", 0x07, .value14, 0...255, .number(), r),
            p("ef.gain", "Filter", "Filter Gain", 0x0C, .value14, 0...255, .number(), r),
            p("ef.keyFollow", "Filter", "Cutoff Key Follow", 0x30, .byte, 0...127, .number(), r),
            p("ef.fegDepth", "Filter EG", "FEG Depth", 0x1D, .byte, 0...127, .offset(64), r),
            p("ef.fegDepthVel", "Filter EG", "FEG Depth Velocity Sensitivity", 0x20, .byte, 0...127, .offset(64), r),
            p("ef.fegHold", "Filter EG", "Hold Time", 0x0E, .byte, 0...127, .number(), r),
            p("ef.fegAttack", "Filter EG", "Attack Time", 0x0F, .byte, 0...127, .number(), r),
            p("ef.fegDecay1", "Filter EG", "Decay 1 Time", 0x10, .byte, 0...127, .number(), r),
            p("ef.fegDecay2", "Filter EG", "Decay 2 Time", 0x11, .byte, 0...127, .number(), r),
            p("ef.fegRelease", "Filter EG", "Release Time", 0x12, .byte, 0...127, .number(), r),
            p("ef.fegHoldLevel", "Filter EG", "Hold Level", 0x13, .value14, 0...255, level, r),
            p("ef.fegAttackLevel", "Filter EG", "Attack Level", 0x15, .value14, 0...255, level, r),
            p("ef.fegDecay1Level", "Filter EG", "Decay 1 Level", 0x17, .value14, 0...255, level, r),
            p("ef.fegDecay2Level", "Filter EG", "Decay 2 Level (sustain)", 0x19, .value14, 0...255, level, r),
            p("ef.fegReleaseLevel", "Filter EG", "Release Level", 0x1B, .value14, 0...255, level, r),
            p("ef.eqType", "EQ", "EQ Type", 0x32, .byte, 0...5, .names(["2-band", "P.EQ", "Boost6", "Boost12", "Boost18", "Thru"]), r),
            p("ef.lfoWave", "LFO", "LFO Wave", 0x3A, .byte, 0...2, .names(["Saw", "Triangle", "Square"]), r),
            p("ef.lfoReset", "LFO", "LFO Key On Reset", 0x3B, .byte, 0...1, .onOff, r),
            p("ef.lfoSpeed", "LFO", "LFO Speed", 0x3D, .byte, 0...63, .number(), r),
            p("ef.lfoDelay", "LFO", "LFO Delay Time", 0x3C, .byte, 0...127, .number(), r),
            p("ef.lfoFade", "LFO", "LFO Fade In Time", 0x41, .byte, 0...127, .number(), r),
            p("ef.lfoPitch", "LFO", "LFO Pitch Modulation Depth", 0x3F, .byte, 0...127, .number(), r),
            p("ef.lfoAmp", "LFO", "LFO Amplitude Modulation Depth", 0x3E, .byte, 0...127, .number(), r),
            p("ef.lfoFilter", "LFO", "LFO Filter Modulation Depth", 0x40, .byte, 0...127, .number(), r),
        ]
    }()

    /// A Part's arpeggio block, 31 6p 00 (Data List p. 210): only its switch.
    static let partArp: [ModxParam] = [p("arp.switch", "Arpeggio", "Part Arp Switch", 0x00, .byte, 0...1, .onOff)]

    /// A setting of a voice block by its key (the tutorials name settings by key).
    static func voiceParam(_ key: String) -> ModxParam? {
        (fmCommon + fmOperator + element + elementFilter + partArp + part).first { $0.key == key }
    }
}

enum ModxVoice {
    /// The Data List names 19 filter types for the 22 values; only the first six are named here, where their order
    /// is certain. The tutorials use LPF24D (0).
    static func filterTypeName(_ value: Int) -> String {
        let names = ["LPF24D", "LPF24A", "LPF18", "LPF18s", "LPF12+HPF12", "LPF6+HPF12"]
        return value < names.count ? names[value] : "Filter type \(value)"
    }

    /// Preset waveforms the AWM2 tutorial uses (Waveform List, p. 68: Synth Lead ▸ Analog).
    static let basicWaves: [(number: Int, name: String)] = [
        (2125, "Saw"), (2136, "P50-1 (square)"), (2134, "P25-1 (pulse)"), (2138, "Tri Wave"), (2139, "Sine"),
    ]

    static func waveName(_ number: Int) -> String {
        basicWaves.first { $0.number == number }.map { "\(number) \($0.name)" } ?? "\(number)"
    }
}

/// FM-X algorithms 1–8 as the Data List's Algorithm Chart (p. 182) draws them: carriers along the bottom row (row 0),
/// modulators above the operator they modulate, and operator 1's feedback loop. The other 80 are in the chart.
enum ModxFMAlgorithms {
    struct Algorithm {
        let number: Int
        /// Where each operator (1–8) sits: column, and row above the carriers.
        let positions: [Int: (col: Int, row: Int)]
        /// Modulator → the operator it modulates.
        let edges: [(from: Int, to: Int)]
        let feedback: Int

        var carriers: [Int] { (1...8).filter { positions[$0]?.row == 0 } }
        func modulates(_ op: Int) -> [Int] { edges.filter { $0.from == op }.map(\.to) }
    }

    private static func row(_ ops: ClosedRange<Int>, from col: Int) -> [Int: (col: Int, row: Int)] {
        Dictionary(uniqueKeysWithValues: ops.enumerated().map { ($0.element, (col + $0.offset, 0)) })
    }

    static let known: [Int: Algorithm] = {
        var list: [Algorithm] = []
        list.append(Algorithm(number: 1, positions: row(1...8, from: 0), edges: [], feedback: 1))
        list.append(Algorithm(number: 2, positions: [1: (0, 3), 2: (0, 2), 3: (0, 1)].merging(row(4...8, from: 0)) { a, _ in a },
                              edges: [(1, 2), (2, 3), (3, 4)], feedback: 1))
        list.append(Algorithm(number: 3, positions: [1: (0, 2), 2: (1, 2), 3: (1, 1)].merging(row(4...8, from: 1)) { a, _ in a },
                              edges: [(1, 3), (2, 3), (3, 4)], feedback: 1))
        list.append(Algorithm(number: 4, positions: [2: (1, 2), 1: (0, 1), 3: (1, 1)].merging(row(4...8, from: 1)) { a, _ in a },
                              edges: [(2, 3), (3, 4), (1, 4)], feedback: 1))
        list.append(Algorithm(number: 5, positions: [1: (0, 2), 2: (0, 1), 3: (1, 1)].merging(row(4...8, from: 1)) { a, _ in a },
                              edges: [(1, 2), (2, 4), (3, 4)], feedback: 1))
        list.append(Algorithm(number: 6, positions: [1: (0, 1), 3: (1, 1), 2: (0, 0)].merging(row(4...8, from: 1)) { a, _ in a },
                              edges: [(1, 2), (3, 4)], feedback: 1))
        list.append(Algorithm(number: 7, positions: [1: (1, 1)].merging(row(2...8, from: 0)) { a, _ in a },
                              edges: [(1, 2), (1, 3), (1, 4)], feedback: 1))
        list.append(Algorithm(number: 8, positions: [1: (0, 1)].merging(row(2...8, from: 0)) { a, _ in a },
                              edges: [(1, 2)], feedback: 1))
        return Dictionary(uniqueKeysWithValues: list.map { ($0.number, $0) })
    }()
}
