//
//  ModxTutorials.swift — MxModxUSB
//
//  The FM Synthesis and AWM2 Synthesis tutorials. Their sound engine is the MODX7 itself: each lesson builds its
//  sound on an FM-X or AWM2 Part of the current Performance, by Parameter Changes to that Part's voice blocks (in the
//  MODX's edit buffer), and you play it on the MODX's keyboard. A lesson is data: what it teaches at each instruction
//  level (Settings ▸ Guidance), the settings that make its sound — on top of a plain starting sound, so every
//  lesson starts the same whatever the Part was — and the settings to change while you listen.
//

import Foundation

enum ModxEngine: String, CaseIterable, Identifiable {
    case fmx, awm2

    var id: String { rawValue }
    var partType: ModxPartType { self == .fmx ? .fmx : .awm2 }
    var title: String { self == .fmx ? "FM Synthesis" : "AWM2 Synthesis" }
    var engineName: String { self == .fmx ? "FM-X" : "AWM2" }
    var lessons: [TutorialLesson] { self == .fmx ? ModxTutorials.fmLessons : ModxTutorials.awm2Lessons }

    /// The plain sound every lesson starts from.
    func base(algorithm: Int?) -> [TutorialSetting] {
        self == .fmx ? ModxTutorials.fmBase(algorithm: algorithm ?? 8) : ModxTutorials.awmBase
    }
}

/// A setting a lesson makes, in a block of the tutorial's Part.
struct TutorialSetting: Equatable {
    enum Block: Hashable {
        case part, arp, fmCommon
        case op(Int), element(Int), elementFilter(Int)   // 0-based
    }
    let block: Block
    let key: String
    let value: Int

    func target(part p: Int) -> ModxTarget {
        switch block {
        case .part: .part(p)
        case .arp: .partArp(p)
        case .fmCommon: .fmCommon(p)
        case .op(let o): .fmOperator(part: p, op: o)
        case .element(let e): .element(part: p, element: e)
        case .elementFilter(let e): .elementFilter(part: p, element: e)
        }
    }

    var param: ModxParam? { ModxParams.voiceParam(key) }
}

/// A setting to change while playing, shown with the lesson.
struct TutorialControl: Identifiable {
    let block: TutorialSetting.Block
    let key: String
    let label: String
    var id: String { "\(block)-\(key)" }
    var param: ModxParam? { ModxParams.voiceParam(key) }
}

struct TutorialLesson: Identifiable {
    let id: String
    let title: String
    /// The line under the title (not at Minimal).
    let goal: String
    /// "Why it works" (Full only).
    var theory: [String] = []
    /// "Try this" (always).
    var steps: [String] = []
    /// "Listen for" (Full and Brief).
    var listen: String? = nil
    /// A page that only teaches, with no sound of its own (gone at Minimal).
    var lessonOnly = false
    /// FM-X: the algorithm the lesson uses.
    var algorithm: Int? = nil
    var setup: [TutorialSetting] = []
    var controls: [TutorialControl] = []

    /// Everything the lesson sets: the engine's plain sound, then the lesson's own settings (a later one wins).
    func settings(_ engine: ModxEngine) -> [TutorialSetting] {
        var order: [String] = []
        var byKey: [String: TutorialSetting] = [:]
        for s in engine.base(algorithm: algorithm) + setup {
            let key = "\(s.block)|\(s.key)"
            if byKey[key] == nil { order.append(key) }
            byKey[key] = s
        }
        return order.compactMap { byKey[$0] }
    }
}

// MARK: - Building blocks

private func part(_ key: String, _ v: Int) -> TutorialSetting { .init(block: .part, key: key, value: v) }
private func arp(_ v: Int) -> TutorialSetting { .init(block: .arp, key: "arp.switch", value: v) }
private func fm(_ key: String, _ v: Int) -> TutorialSetting { .init(block: .fmCommon, key: "fm.\(key)", value: v) }
/// Operator `n` (1–8).
private func op(_ n: Int, _ key: String, _ v: Int) -> TutorialSetting { .init(block: .op(n - 1), key: "op.\(key)", value: v) }
/// Element `n` (1–8): Element Group 1 …
private func el(_ n: Int, _ key: String, _ v: Int) -> TutorialSetting { .init(block: .element(n - 1), key: "el.\(key)", value: v) }
/// … and Group 2 (filter, FEG, LFO).
private func ef(_ n: Int, _ key: String, _ v: Int) -> TutorialSetting { .init(block: .elementFilter(n - 1), key: "ef.\(key)", value: v) }

private func cFM(_ key: String, _ label: String) -> TutorialControl { .init(block: .fmCommon, key: "fm.\(key)", label: label) }
private func cOp(_ n: Int, _ key: String, _ label: String) -> TutorialControl { .init(block: .op(n - 1), key: "op.\(key)", label: label) }
private func cEl(_ n: Int, _ key: String, _ label: String) -> TutorialControl { .init(block: .element(n - 1), key: "el.\(key)", label: label) }
private func cEf(_ n: Int, _ key: String, _ label: String) -> TutorialControl { .init(block: .elementFilter(n - 1), key: "ef.\(key)", label: label) }

/// An operator that decays to silence: `time` sets how quickly.
private func decaying(_ n: Int, time: Int, to level: Int = 0, release: Int = 40) -> [TutorialSetting] {
    [op(n, "aegDecay1", time), op(n, "aegDecay1Level", level), op(n, "aegDecay2", time), op(n, "aegDecay2Level", level),
     op(n, "aegRelease", release)]
}

enum ModxTutorials {
    // MARK: Plain sounds

    /// The Part's own offsets to every element's or operator's envelopes and filter (Performance Part 31 0p 46–51:
    /// AEG and FEG times, sustain, FEG depth, cutoff, resonance), set to none — a pad's long release offset would
    /// otherwise stretch every lesson's envelope.
    static let neutralPartOffsets: [TutorialSetting] = [70, 71, 72, 73, 74, 75, 76, 77, 78, 80, 81].map { part("part.tone.\($0)", 64) }

    /// FM-X: the algorithm, every operator a silent sine at ratio 1 with an organ-like envelope, no feedback, the
    /// filter open (LPF24D at 255), no pitch EG, LFO or velocity, no Part offsets, and the Part's arpeggio and motion
    /// sequencer off.
    static func fmBase(algorithm: Int) -> [TutorialSetting] {
        var s = neutralPartOffsets + [part("part.msSwitch", 0), arp(0), fm("algorithm", algorithm - 1), fm("feedback", 0), fm("pitchVel", 64),
                 fm("randomPitch", 0), fm("filterType", 0), fm("cutoff", 255), fm("cutoffVel", 64), fm("resonance", 0),
                 fm("fegDepth", 64), fm("lfoPitch", 0), fm("lfoAmp", 0), fm("lfoFilter", 0)]
        s += (0..<5).map { fm("peg\($0)", 50) }
        for n in 1...8 {
            s += [op(n, "level", 0), op(n, "levelVel", 7), op(n, "mode", 0), op(n, "coarse", 1), op(n, "fine", 0),
                  op(n, "detune", 15), op(n, "pitchVel", 7), op(n, "keyReset", 1), op(n, "form", 0), op(n, "skirt", 0),
                  op(n, "spectralRes", 0), op(n, "aegAttackLevel", 99), op(n, "aegDecay1Level", 99), op(n, "aegDecay2Level", 99),
                  op(n, "aegReleaseLevel", 0), op(n, "aegAttack", 0), op(n, "aegDecay1", 0), op(n, "aegDecay2", 0),
                  op(n, "aegRelease", 40), op(n, "aegHold", 0), op(n, "aegKeyFollow", 0), op(n, "pegInitial", 50),
                  op(n, "pegAttackLevel", 50), op(n, "lsLowDepth", 0), op(n, "lsHighDepth", 0), op(n, "pitchCtrl", 7),
                  op(n, "levelCtrl", 7), op(n, "lfoPitch", 0), op(n, "lfoAmp", 0)]
        }
        return s
    }

    /// AWM2: one element playing a preset waveform through an open filter (LPF24D at 255), no filter or pitch EG,
    /// LFO, EQ or velocity, on the whole keyboard; the other elements off; arpeggio and motion sequencer off.
    static func awmElement(_ n: Int, wave: Int, level: Int = 110) -> [TutorialSetting] {
        [el(n, "switch", 1), el(n, "waveBank", 0), el(n, "wave", wave), el(n, "level", level), el(n, "pan", 64), el(n, "xa", 0),
         el(n, "connection", 0), el(n, "partLFO", 0), el(n, "noteLow", 0), el(n, "noteHigh", 127), el(n, "velLow", 1),
         el(n, "velHigh", 127), el(n, "velFade", 0), el(n, "levelVel", 64), el(n, "aegAttack", 0), el(n, "aegDecay1", 64),
         el(n, "aegDecay2", 64), el(n, "aegRelease", 40), el(n, "aegInitial", 0), el(n, "aegAttackLevel", 127),
         el(n, "aegDecay1Level", 127), el(n, "aegDecay2Level", 127), el(n, "coarse", 64), el(n, "fine", 64),
         el(n, "pitchVel", 64), el(n, "randomPitch", 0), el(n, "pegDepth", 64),
         ef(n, "type", 0), ef(n, "cutoff", 255), ef(n, "resonance", 0), ef(n, "cutoffVel", 64), ef(n, "hpf", 0),
         ef(n, "fegDepth", 64), ef(n, "fegDepthVel", 64), ef(n, "fegHold", 0), ef(n, "fegAttack", 0), ef(n, "fegDecay1", 64),
         ef(n, "fegDecay2", 64), ef(n, "fegRelease", 64), ef(n, "fegHoldLevel", 128), ef(n, "fegAttackLevel", 255),
         ef(n, "fegDecay1Level", 192), ef(n, "fegDecay2Level", 128), ef(n, "fegReleaseLevel", 128), ef(n, "eqType", 5),
         ef(n, "lfoWave", 1), ef(n, "lfoReset", 1), ef(n, "lfoSpeed", 32), ef(n, "lfoDelay", 0), ef(n, "lfoFade", 0),
         ef(n, "lfoPitch", 0), ef(n, "lfoAmp", 0), ef(n, "lfoFilter", 0)]
    }

    static let awmBase: [TutorialSetting] =
        neutralPartOffsets + [part("part.msSwitch", 0), arp(0)] + awmElement(1, wave: 2125) + (2...8).map { el($0, "switch", 0) }

    // MARK: FM-X lessons

    static let fmLessons: [TutorialLesson] = [
        TutorialLesson(
            id: "fm.what", title: "What FM Is",
            goal: "One oscillator bending another's pitch, so fast that you hear a new tone colour instead.",
            theory: [
                "Frequency modulation (John Chowning, Stanford, 1973; Yamaha's DX7, 1983) makes tone colour by letting one sine wave — the modulator — push another — the carrier — faster and slower hundreds or thousands of times a second. You don't hear vibrato: you hear new frequencies, sidebands, at the carrier's frequency plus and minus whole multiples of the modulator's.",
                "Two things decide the sound. The ratio between the modulator's and the carrier's frequency decides where the sidebands fall: whole-number ratios land them on the harmonic series (a pitched, instrument-like tone), others between harmonics (bells, metal, noise). The modulator's level — the modulation index — decides how many sidebands are strong: low is pure, high is bright and buzzy.",
                "Yamaha calls each oscillator with its own envelope and level an operator. Carriers are the operators you hear; modulators are heard only through what they do to carriers. An algorithm is the wiring: which operators modulate which.",
                "The MODX7's FM-X engine has 8 operators per Part and 88 algorithms. Beyond the DX7 it gives each operator a spectral form — not only a sine but waveforms with all, odd or resonant harmonics — and a filter after the operators, as AWM2 has.",
            ],
            steps: [
                "Choose an FM-X Part of the current Performance above and start: the app keeps a copy of the Part so it can put it back.",
                "Go through the lessons in order; each one sets up its sound on the MODX when you press Set Up on the MODX. Play the MODX's keyboard and move the controls below each lesson.",
            ],
            lessonOnly: true),
        TutorialLesson(
            id: "fm.sine", title: "One Operator: a Sine Wave",
            goal: "A carrier alone is a pure sine wave — the plainest sound there is.",
            theory: [
                "With nothing modulating it, a carrier is a sine wave: one frequency, no harmonics. Flutes, whistles and tuning forks come close; everything brighter has more harmonics.",
                "Algorithm 8 wires operator 1 into operator 2. Operator 1 is silent here (level 0), so you hear operator 2 alone.",
                "The ratio (Coarse) multiplies the key's frequency: 1 plays at the key's pitch, 2 an octave above, 0.5 an octave below. The amplitude envelope shapes the volume over time: Attack Time is how quickly the note sounds, Release Time how long it rings after you let go.",
            ],
            steps: ["Press Set Up on the MODX, then play a few notes.", "Change the carrier's ratio to 2 and 0.5.", "Lengthen the attack and the release."],
            listen: "A smooth, hollow tone with no edge; the attack and release change only how it starts and ends, never its colour.",
            algorithm: 8, setup: [op(2, "level", 99)],
            controls: [cOp(2, "level", "Carrier level (operator 2)"), cOp(2, "coarse", "Carrier ratio"),
                       cOp(2, "aegAttack", "Carrier attack time"), cOp(2, "aegRelease", "Carrier release time")]),
        TutorialLesson(
            id: "fm.modulator", title: "A Modulator Adds Harmonics",
            goal: "Turn up a modulator and the sine wave grows brighter, step by step.",
            theory: [
                "Operator 1 now modulates operator 2 at the same frequency (ratio 1:1). Its level is the modulation index: at 0 nothing changes; as it rises, sidebands at 2×, 3×, 4× … the key's frequency appear and grow, and the tone goes from sine to something like a sawtooth.",
                "This is FM's version of opening a filter — but done by adding harmonics, not taking them away, which is why FM sounds can be so bright and clear.",
            ],
            steps: ["Set up, then hold a note.", "Raise the modulator's level slowly from 0 to 99.", "Try the modulator's ratio at 2: the harmonics change."],
            listen: "Low levels add warmth; around the middle it turns reedy; near the top it gets brassy and harsh.",
            algorithm: 8, setup: [op(2, "level", 99), op(1, "level", 45)],
            controls: [cOp(1, "level", "Modulator level (operator 1)"), cOp(1, "coarse", "Modulator ratio"), cOp(2, "level", "Carrier level")]),
        TutorialLesson(
            id: "fm.ratio", title: "Ratios: Which Harmonics",
            goal: "The modulator's ratio decides which harmonics you get: all of them, odd ones only, or none in tune.",
            theory: [
                "The sidebands sit at the carrier's frequency plus and minus multiples of the modulator's. With carrier 1 and modulator 1 every harmonic appears; with modulator 2 they fall on 1, 3, 5 … — odd harmonics only, the hollow sound of a square wave or a clarinet.",
                "Whole-number ratios keep everything on the harmonic series, so the sound has a clear pitch. Fine moves the ratio off a whole number: the sidebands land between harmonics and the tone turns metallic, then clangorous — the start of bells.",
            ],
            steps: ["Set up (modulator ratio 2), and play.", "Try modulator ratios 1, 2, 3 and 4.", "Raise Fine a little, then a lot.", "Put the carrier's ratio at 2 with the modulator at 1 for another colour."],
            listen: "Ratio 1 is buzzy, 2 hollow, 3 and 4 nasal; any Fine at all makes it ring like metal.",
            algorithm: 8, setup: [op(2, "level", 99), op(1, "level", 70), op(1, "coarse", 2)],
            controls: [cOp(1, "coarse", "Modulator ratio"), cOp(1, "fine", "Modulator fine"), cOp(2, "coarse", "Carrier ratio"),
                       cOp(1, "level", "Modulator level")]),
        TutorialLesson(
            id: "fm.feedback", title: "Feedback",
            goal: "An operator that modulates itself turns from a sine into a sawtooth — and then into noise.",
            theory: [
                "In every FM-X algorithm one operator feeds its own output back into itself; in algorithms 1–8 it's operator 1. A little feedback adds harmonics much as a modulator does; more makes a bright, saw-like wave; the most turns it into noise.",
                "Algorithm 1 makes all eight operators carriers, so here you hear operator 1 itself, with the Feedback Level (0–7) changing it.",
            ],
            steps: ["Set up, then hold a note.", "Step Feedback from 0 to 7."],
            listen: "0 is the plain sine; 3–5 a buzzy sawtooth; 7 breaks up into noise — useful for breath and percussion.",
            algorithm: 1, setup: [op(1, "level", 99), fm("feedback", 3)],
            controls: [cFM("feedback", "Feedback level"), cOp(1, "level", "Operator 1 level")]),
        TutorialLesson(
            id: "fm.envelope", title: "Envelopes Shape the Brightness",
            goal: "Give the modulator its own envelope and the tone changes colour as the note goes on.",
            theory: [
                "Each operator has its own amplitude envelope. On a carrier it shapes loudness; on a modulator it shapes the modulation index — so the brightness changes over the note. Here the modulator starts strong and decays to nothing while the carrier holds: a bright attack that mellows into a sine.",
                "This is how FM makes plucked strings, electric pianos and brass: real instruments are brightest in their first moments.",
            ],
            steps: ["Set up and play short and long notes.", "Make the modulator's decay longer and shorter.", "Raise the modulator's sustain level (Decay 2 Level) so some brightness stays."],
            listen: "A quick 'pluck' of brightness at each note, fading to a soft tone — longer decay, slower fade.",
            algorithm: 8,
            setup: [op(2, "level", 99), op(1, "level", 85)] + decaying(1, time: 45),
            controls: [cOp(1, "aegDecay1", "Modulator decay time"), cOp(1, "aegDecay2Level", "Modulator sustain level"),
                       cOp(1, "level", "Modulator level"), cOp(1, "aegAttack", "Modulator attack time")]),
        TutorialLesson(
            id: "fm.velocity", title: "Velocity Makes It Expressive",
            goal: "Let how hard you play set the modulator's level: soft is mellow, hard is bright.",
            theory: [
                "Level Velocity Sensitivity scales an operator's level by how hard you play. On the carrier that's loudness, as on any synth. On a modulator it's brightness — the FM trick that made the DX7's electric piano bark when struck hard.",
            ],
            steps: ["Set up, then play very softly and very hard.", "Turn the modulator's velocity sensitivity down to 0, then back up.", "Give the carrier some velocity sensitivity too."],
            listen: "Soft notes nearly sine-pure, hard notes bright and biting — the colour, not only the volume, follows your hands.",
            algorithm: 8,
            setup: [op(2, "level", 99), op(1, "level", 92), op(1, "levelVel", 14)] + decaying(1, time: 50, to: 10),
            controls: [cOp(1, "levelVel", "Modulator velocity sensitivity"), cOp(2, "levelVel", "Carrier velocity sensitivity"),
                       cOp(1, "level", "Modulator level")]),
        TutorialLesson(
            id: "fm.stack", title: "Stacks: Modulating a Modulator",
            goal: "A modulator can itself be modulated — a stack of three gives far more complex tones.",
            theory: [
                "Algorithm 2 chains operators 1 → 2 → 3 → 4. Here operator 1 is silent, so 2 modulates 3 and 3 modulates the carrier, 4. Operator 2 makes operator 3's own sound richer, and that richer signal modulates the carrier — the harmonics multiply.",
                "Stacks are where FM's aggressive basses, leads and brasses come from. Keep the top of the stack low at first: a little goes a long way.",
            ],
            steps: ["Set up and play.", "Raise operator 3 (the middle) and then operator 2 (the top).", "Change the top operator's ratio."],
            listen: "Each step up the stack adds grit and complexity, much faster than a single modulator does.",
            algorithm: 2,
            setup: [op(4, "level", 99), op(3, "level", 60), op(2, "level", 40)],
            controls: [cOp(3, "level", "Middle modulator (operator 3)"), cOp(2, "level", "Top modulator (operator 2)"),
                       cOp(2, "coarse", "Top modulator ratio"), cOp(4, "level", "Carrier (operator 4)")]),
        TutorialLesson(
            id: "fm.parallel", title: "Two Voices in Parallel: an Electric Piano",
            goal: "Two separate modulator–carrier pairs, played together, make one instrument with two parts.",
            theory: [
                "Algorithm 6 has two pairs: 1 → 2 and 3 → 4. Each pair is its own little FM voice, and you hear both at once. The classic FM electric piano works this way: one pair makes the 'tine' — a high, fast-decaying ratio for the metallic strike — and the other the warm body of the note.",
                "Here operator 1 runs at ratio 14 and decays quickly (the tine); operator 3 at ratio 1 decays slowly (the body). Both carriers die away like a struck string.",
            ],
            steps: ["Set up and play chords, softly and hard.", "Turn the tine (operator 1) up and down.", "Change the body's modulator (operator 3) level."],
            listen: "A bell-like 'ping' at the start of each note over a round, decaying tone; hard notes ping more.",
            algorithm: 6,
            setup: [op(2, "level", 88), op(4, "level", 92),
                    op(1, "coarse", 14), op(1, "level", 58), op(1, "levelVel", 13), op(3, "level", 62), op(3, "levelVel", 11)]
                + decaying(1, time: 22) + decaying(3, time: 50, to: 18)
                + decaying(2, time: 75, release: 30) + decaying(4, time: 80, release: 30),
            controls: [cOp(1, "level", "Tine (operator 1)"), cOp(3, "level", "Body modulator (operator 3)"),
                       cOp(2, "level", "Tine carrier (operator 2)"), cOp(4, "level", "Body carrier (operator 4)")]),
        TutorialLesson(
            id: "fm.additive", title: "Additive: Operators as Drawbars",
            goal: "With every operator a carrier, FM becomes additive synthesis — like an organ's drawbars.",
            theory: [
                "Algorithm 1 makes all eight operators carriers. Each one is a sine at its own ratio, and you hear them added together — exactly how a tonewheel organ builds its tone from drawbars.",
                "Here the operators sit at ratios 0.5, 1, 2, 3, 4, 5, 6 and 8 — the same footages as an organ's drawbars (16', 8', 4', 2⅔', 2', 1⅗', 1⅓' and 1'). Their levels are the drawbars.",
            ],
            steps: ["Set up and play chords.", "Pull 'drawbars' in and out with the operator levels.", "Try only the first three for a soft organ, or all eight for a full one."],
            listen: "Every level changes the organ's registration; there's no buzz of modulation, only sines adding up.",
            algorithm: 1,
            setup: [op(1, "coarse", 0), op(2, "coarse", 1), op(3, "coarse", 2), op(4, "coarse", 3), op(5, "coarse", 4),
                    op(6, "coarse", 5), op(7, "coarse", 6), op(8, "coarse", 8),
                    op(1, "level", 82), op(2, "level", 90), op(3, "level", 84), op(4, "level", 60), op(5, "level", 55)]
                + (1...8).map { op($0, "aegRelease", 8) },
            controls: (1...8).map { n in cOp(n, "level", ["16'", "8'", "4'", "2⅔'", "2'", "1⅗'", "1⅓'", "1'"][n - 1] + " (operator \(n))") }),
        TutorialLesson(
            id: "fm.spectral", title: "FM-X Spectral Forms",
            goal: "FM-X operators needn't be sine waves: a richer modulator gives a richer tone with less effort.",
            theory: [
                "The DX7's operators were all sines. FM-X gives each operator a Spectral Form: All 1 and All 2 have every harmonic, Odd 1 and Odd 2 odd harmonics only, Res 1 and Res 2 a resonant peak. Skirt shapes how the harmonics fall away; Spectral Resonance moves the peak of the Res forms.",
                "On a modulator a richer form multiplies the sidebands; on a carrier it's heard directly, much like an analog oscillator's wave.",
            ],
            steps: ["Set up (the modulator is at Odd 1) and play.", "Go through the modulator's spectral forms.", "Change Skirt, and with a Res form, Spectral Resonance."],
            listen: "Each form gives the same modulator level a different character — hollow, buzzy or vocal.",
            algorithm: 8,
            setup: [op(2, "level", 99), op(1, "level", 60), op(1, "form", 3)],
            controls: [cOp(1, "form", "Modulator spectral form"), cOp(1, "skirt", "Modulator skirt"),
                       cOp(1, "spectralRes", "Modulator spectral resonance"), cOp(1, "level", "Modulator level")]),
        TutorialLesson(
            id: "fm.bell", title: "Inharmonic Ratios: a Bell",
            goal: "Put the modulator between harmonics and let the note ring: you've made a bell.",
            theory: [
                "Bells, chimes and gongs have partials that aren't whole multiples of their pitch. A modulator ratio that isn't a whole number does the same: here the modulator is at ratio 3 moved off by Fine, so its sidebands fall between harmonics.",
                "Both operators decay slowly with a long release, as a struck bell does; the modulator decays a little faster, so the clang softens as the bell rings.",
            ],
            steps: ["Set up and play single notes high on the keyboard; let them ring.", "Move Fine to retune the bell.", "Shorten the carrier's decay for a chime."],
            listen: "A metallic strike that rings on, with a pitch that's clear but 'not quite' — the sound of a bell.",
            algorithm: 8,
            setup: [op(2, "level", 99), op(1, "level", 72), op(1, "coarse", 3), op(1, "fine", 41)]
                + decaying(2, time: 85, release: 80) + decaying(1, time: 70, release: 80),
            controls: [cOp(1, "fine", "Modulator fine"), cOp(1, "coarse", "Modulator ratio"), cOp(1, "level", "Modulator level"),
                       cOp(2, "aegDecay1", "Carrier decay time")]),
    ]

    // MARK: AWM2 lessons

    private static let square = 2136, pulse = 2134, triangle = 2138, sine = 2139, saw = 2125

    static let awm2Lessons: [TutorialLesson] = [
        TutorialLesson(
            id: "awm.what", title: "What AWM2 Is",
            goal: "Recorded sounds — waveforms — shaped by a filter and envelopes: the MODX's sample engine.",
            theory: [
                "Advanced Wave Memory 2 is Yamaha's sample-playback engine. Instead of making a waveform with oscillators, it plays a waveform — a recording of a real instrument, or of a synthesizer's wave — and then shapes it: pitch (with a pitch envelope), a filter (with a filter envelope) and amplitude (with an amplitude envelope), each with an LFO to move it.",
                "That chain — waveform, filter, amplitude — is an element. A MODX7 AWM2 Part has up to 8 elements, each with its own waveform, keyboard range and velocity range, so one Part can layer sounds, split the keyboard, or switch samples by how hard you play. The MODX7 has 6,347 preset waveforms.",
                "Because the waveform already holds the instrument's character, AWM2 is at its best for realistic pianos, strings and drums; the filter and envelopes make it a synthesizer too (subtractive synthesis: start rich, take away).",
            ],
            steps: [
                "Choose an AWM2 Part of the current Performance above and start: the app keeps a copy of the Part so it can put it back.",
                "Go through the lessons in order; each one sets up its sound on the MODX when you press Set Up on the MODX. Play the MODX's keyboard and move the controls below each lesson.",
            ],
            lessonOnly: true),
        TutorialLesson(
            id: "awm.element", title: "One Element, One Waveform",
            goal: "Element 1 alone, playing a sawtooth waveform through an open filter.",
            theory: [
                "The lessons start from a single element playing preset waveform 2125, Saw — a sawtooth, the bright, buzzy wave analog synthesizers start from because it holds every harmonic. The filter is wide open and the amplitude envelope sustains like an organ, so you hear the waveform as it is.",
                "Coarse Tune moves the element in semitones (12 = an octave); Fine Tune detunes it by fractions of a semitone.",
            ],
            steps: ["Set up and play.", "Change the element's level.", "Tune it down an octave (Coarse −12) and up a fifth (+7)."],
            listen: "A raw, bright, buzzing tone: the starting point for the filter lessons.",
            controls: [cEl(1, "level", "Element level"), cEl(1, "coarse", "Coarse tune"), cEl(1, "fine", "Fine tune")]),
        TutorialLesson(
            id: "awm.waveforms", title: "Waveforms",
            goal: "The waveform is the raw material: change it and everything else sounds different.",
            theory: [
                "Saw has all harmonics; a square (P50-1) only odd ones and sounds hollow; a narrow pulse (P25-1) is thinner and nasal; a triangle has faint odd harmonics; a sine none at all.",
                "Most of the MODX's waveforms are recordings, multi-sampled across the keyboard so each range sounds natural: pianos, guitars, strings, voices, drums. The same filter and envelopes then shape any of them.",
            ],
            steps: ["Set up, then choose each waveform in turn and play.", "Compare how bright each is with the same filter setting."],
            listen: "Saw buzzes, square is hollow, pulse nasal, triangle soft, sine pure.",
            controls: [cEl(1, "wave", "Waveform"), cEl(1, "level", "Element level")]),
        TutorialLesson(
            id: "awm.filter", title: "The Filter: Cutoff and Resonance",
            goal: "A low-pass filter takes away the upper harmonics: lower the cutoff and the sound goes dark.",
            theory: [
                "Subtractive synthesis starts from a rich waveform and filters it. A low-pass filter (here LPF24D, a steep 24 dB/octave type) passes everything below its cutoff frequency and removes what's above. Lower the cutoff and the saw loses its buzz, then its brightness, until only the fundamental is left.",
                "Resonance boosts the frequencies right at the cutoff: a little gives an edge, a lot a whistling, vocal peak — the classic synth 'squelch' when the cutoff moves.",
            ],
            steps: ["Set up (cutoff halfway, some resonance) and hold a note.", "Sweep the cutoff from 255 down to 0 and back.", "Raise the resonance and sweep again."],
            listen: "The cutoff sweep sounds like a mouth closing; resonance adds a singing peak that follows it.",
            setup: [ef(1, "cutoff", 140), ef(1, "resonance", 40)],
            controls: [cEf(1, "cutoff", "Cutoff"), cEf(1, "resonance", "Resonance")]),
        TutorialLesson(
            id: "awm.feg", title: "The Filter Envelope",
            goal: "Let an envelope move the cutoff on every note: the brightness rises and falls by itself.",
            theory: [
                "The filter envelope (FEG) moves the cutoff over the note. FEG Depth sets how far — here up from a low cutoff — and its times set how quickly it rises (Attack) and falls back (Decay 1, Decay 2) to its sustain level.",
                "A fast attack and decay make a pluck or a 'bwow' bass; a slow attack makes the sound swell open, like brass or a pad.",
            ],
            steps: ["Set up and play short notes.", "Change the FEG Depth (0 is none).", "Lengthen Decay 1 for a longer sweep; lengthen Attack for a swell."],
            listen: "Each note opens bright and closes darker — the envelope is playing the cutoff for you.",
            setup: [ef(1, "cutoff", 60), ef(1, "resonance", 30), ef(1, "fegDepth", 108), ef(1, "fegDecay1", 50), ef(1, "fegDecay2", 60),
                    ef(1, "fegDecay1Level", 150), ef(1, "fegDecay2Level", 128)],
            controls: [cEf(1, "fegDepth", "FEG depth"), cEf(1, "fegAttack", "FEG attack time"), cEf(1, "fegDecay1", "FEG decay 1 time"),
                       cEf(1, "cutoff", "Cutoff")]),
        TutorialLesson(
            id: "awm.aeg", title: "The Amplitude Envelope",
            goal: "Attack, decay, sustain and release: how the volume of every note changes over time.",
            theory: [
                "The amplitude envelope (AEG) shapes loudness. Attack Time is how long the note takes to sound; Decay 1 and Decay 2 how it falls to the sustain level (Decay 2 Level), where it stays while you hold the key; Release Time how long it takes to die after you let go.",
                "Short attack and no sustain is a pluck or a piano; slow attack and long release a pad or strings. The same waveform becomes a different instrument.",
            ],
            steps: ["Set up (a slow, pad-like envelope) and hold chords.", "Shorten the attack to 0.", "Lower the sustain to 0 and shorten Decay 1: a pluck.", "Lengthen the release."],
            listen: "The waveform's colour stays; only the note's shape in time changes — and with it the instrument.",
            setup: [el(1, "aegAttack", 64), el(1, "aegDecay1", 64), el(1, "aegDecay2", 70), el(1, "aegDecay2Level", 90), el(1, "aegRelease", 70),
                    ef(1, "cutoff", 170)],
            controls: [cEl(1, "aegAttack", "Attack time"), cEl(1, "aegDecay1", "Decay 1 time"), cEl(1, "aegDecay2Level", "Sustain level"),
                       cEl(1, "aegRelease", "Release time")]),
        TutorialLesson(
            id: "awm.velocity", title: "Velocity",
            goal: "Play harder for louder and brighter, as acoustic instruments do.",
            theory: [
                "Level Velocity Sensitivity sets how much harder playing makes the element louder; Cutoff Velocity Sensitivity how much it opens the filter. Real instruments do both: struck harder, they're louder and brighter.",
            ],
            steps: ["Set up and play softly, then hard.", "Turn each sensitivity to 0 and back up to hear what each one does."],
            listen: "With both on, a soft note is quiet and dark, a hard one loud and bright.",
            setup: [ef(1, "cutoff", 110), el(1, "levelVel", 100), ef(1, "cutoffVel", 104)],
            controls: [cEl(1, "levelVel", "Level velocity sensitivity"), cEf(1, "cutoffVel", "Cutoff velocity sensitivity"),
                       cEf(1, "cutoff", "Cutoff")]),
        TutorialLesson(
            id: "awm.lfo", title: "The LFO: Vibrato, Tremolo, Wah",
            goal: "A slow oscillator that wobbles pitch, volume or the filter.",
            theory: [
                "The element's LFO (low-frequency oscillator) is too slow to hear as a tone; instead it moves something else. On pitch it's vibrato, on amplitude tremolo, on the filter a 'wah' or a rhythmic sweep. Speed is how fast it moves; Delay Time how long after the note it starts, as a singer's vibrato does.",
            ],
            steps: ["Set up (some vibrato, after a short delay) and hold a note.", "Change the speed.", "Move the depth from pitch to amplitude and filter."],
            listen: "Vibrato bends the pitch, tremolo pulses the volume, filter depth makes it talk.",
            setup: [ef(1, "cutoff", 120), ef(1, "resonance", 30), ef(1, "lfoSpeed", 40), ef(1, "lfoPitch", 18), ef(1, "lfoDelay", 40)],
            controls: [cEf(1, "lfoSpeed", "LFO speed"), cEf(1, "lfoPitch", "Pitch depth (vibrato)"), cEf(1, "lfoAmp", "Amplitude depth (tremolo)"),
                       cEf(1, "lfoFilter", "Filter depth (wah)"), cEf(1, "lfoDelay", "LFO delay")]),
        TutorialLesson(
            id: "awm.layer", title: "Layering Two Elements",
            goal: "Two elements on the same keys: a saw and a slightly detuned square, thicker than either.",
            theory: [
                "Every element plays when its key and velocity ranges allow, so two elements on the whole keyboard play together. Detune one a little (Fine Tune) and the two beat against each other — the classic thick, chorused synth sound.",
                "Layers are how AWM2 builds rich sounds from simple parts: a piano with a string pad, a bass with a click.",
            ],
            steps: ["Set up and play.", "Change element 2's level to mix the layers.", "Detune element 2 more and less.", "Change element 2's waveform."],
            listen: "Slow beating that makes the sound wider and alive; detune it more and it turns sour.",
            setup: [ef(1, "cutoff", 160)] + awmElement(2, wave: square, level: 100) + [el(2, "fine", 72), ef(2, "cutoff", 160)],
            controls: [cEl(2, "level", "Element 2 level"), cEl(2, "fine", "Element 2 fine tune"), cEl(2, "wave", "Element 2 waveform"),
                       cEl(1, "level", "Element 1 level")]),
        TutorialLesson(
            id: "awm.split", title: "Key Ranges: a Split",
            goal: "Give each element its own range of keys: a bass on the left, a lead on the right.",
            theory: [
                "Each element has Note Limit Low and High. Element 1 here plays only up to B2 (just below middle C, C3 on the MODX), an octave down, as a bass; element 2 plays from C3 up, a brighter pulse lead. One Part, two instruments, split at C3.",
                "Multi-sampled instruments use the same ranges, with many elements or waveform zones, so each part of the keyboard plays the recording made there.",
            ],
            steps: ["Set up and play both sides of middle C.", "Move the split point: element 1's high limit and element 2's low limit.", "Overlap them for a layer in the middle."],
            listen: "A deep bass below the split and a bright lead above, from one Part.",
            setup: [el(1, "noteHigh", 59), el(1, "coarse", 52), ef(1, "cutoff", 90), ef(1, "resonance", 20)]
                + awmElement(2, wave: pulse, level: 100) + [el(2, "noteLow", 60)],
            controls: [cEl(1, "noteHigh", "Element 1 (bass) high limit"), cEl(2, "noteLow", "Element 2 (lead) low limit"),
                       cEl(1, "coarse", "Bass coarse tune"), cEl(2, "wave", "Lead waveform")]),
        TutorialLesson(
            id: "awm.velocitySwitch", title: "Velocity Ranges: Switching Samples",
            goal: "Soft playing plays one element, hard playing another — the way sampled instruments change with your touch.",
            theory: [
                "Velocity Limit Low and High give each element a range of touch. Element 1 here plays the soft notes (velocity 1–90) with a triangle; element 2 the hard ones (91–127) with a saw. Sampled pianos and drums do this with several recordings of each note, soft to hard.",
                "Velocity Cross Fade softens the switch: an element fades in over that many velocity steps instead of starting abruptly.",
            ],
            steps: ["Set up and play softly, then hard.", "Move the switch point (element 1's high and element 2's low limits).", "Raise both cross fades."],
            listen: "A soft, round tone for gentle notes and a bright one when you dig in.",
            setup: [el(1, "wave", triangle), el(1, "velHigh", 90), ef(1, "cutoff", 200)]
                + awmElement(2, wave: saw, level: 100) + [el(2, "velLow", 91), ef(2, "cutoff", 220)],
            controls: [cEl(1, "velHigh", "Element 1 (soft) high limit"), cEl(2, "velLow", "Element 2 (hard) low limit"),
                       cEl(1, "velFade", "Element 1 cross fade"), cEl(2, "velFade", "Element 2 cross fade")]),
    ]
}
