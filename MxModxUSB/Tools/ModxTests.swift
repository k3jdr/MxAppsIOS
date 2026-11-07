// ModxTests.swift — checks MxModxUSB's decoding against replies a MODX7 (firmware 2.50) really sent over USB on
// 11/6/26 (Performance "CFX + FM EP 2", Live Set bank "Preset"). Tools/build-tools.sh builds it; no MODX needed.

import AVFoundation
import CoreMIDI
import Foundation

@main
struct ModxTests {
    nonisolated(unsafe) static var failures = 0

    static func check(_ ok: Bool, _ what: String, line: Int = #line) {
        if ok { print("  ok    \(what)") } else { failures += 1; print("  FAIL  \(what)  (line \(line))") }
    }

    static func bytes(_ hex: String) -> [UInt8] { hex.split(separator: " ").compactMap { UInt8($0, radix: 16) } }

    static func block(_ hex: String) -> ModxBlock? {
        if case .block(let b) = ModxSysEx.parse(bytes(hex)) { return b }
        return nil
    }

    static let identity = "F0 7E 7F 06 02 43 00 41 57 06 0F 00 00 7F F7"
    static let system = "F0 43 00 7F 1C 00 40 07 00 00 00 7F 40 00 04 00 00 01 40 40 01 00 00 01 01 00 01 01 00 40 00 01 01 60 5F 01 5C 00 00 00 00 01 00 01 00 00 00 01 00 01 01 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 4D F7"
    static let sequencer = "F0 43 00 7F 1C 00 19 07 00 05 00 01 00 64 00 02 01 00 01 01 00 00 01 01 00 00 00 00 00 00 00 00 08 F7"
    static let common = "F0 43 00 7F 1C 00 62 07 30 40 00 43 46 58 20 2B 20 46 4D 20 45 50 20 32 20 20 20 20 20 20 20 00 00 00 00 01 00 00 00 04 00 00 40 00 40 40 40 40 40 40 00 40 40 40 40 00 5A 00 00 00 00 00 00 00 00 00 00 7F 40 01 7F 00 01 01 01 00 00 00 10 02 0B 60 56 57 58 59 11 12 13 14 15 16 17 18 7F 00 00 00 00 00 00 00 01 00 03 60 F7"
    static let reverb = "F0 43 00 7F 1C 00 4B 07 30 41 00 01 00 00 00 20 00 0A 00 2B 00 0D 00 31 00 1D 00 08 00 07 00 37 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 40 40 01 10 F7"
    static let masterEffect = "F0 43 00 7F 1C 00 4C 07 30 46 00 08 20 00 00 10 00 5A 00 03 00 29 00 0F 00 54 00 03 00 28 00 04 00 54 00 03 00 28 00 34 00 60 00 06 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 7F 40 10 07 00 44 F7"
    static let knobNames = "F0 43 00 7F 1C 01 04 07 30 50 00 41 73 73 69 67 6E 65 64 20 20 20 20 20 20 20 20 41 73 73 69 67 6E 65 64 20 20 20 20 20 20 20 20" + String(repeating: " 20", count: 96) + " 1D F7"
    static let part1 = "F0 43 00 7F 1C 00 7D 07 31 00 00 43 46 58 20 2B 20 46 4D 20 45 50 20 32 20 20 20 20 20 20 20 00 00 01 01 00 01 00 00 01 7F 00 7F 42 3E 40 40 62 40 03 08 00 0C 00 00 7F 40 40 10 07 00 40 01 00 01 01 00 00 00 00 01 00 00 00 00 7C 7F 7F 70 78 01 40 40 40 40 40 40 40 40 40 00 40 40 00 00 36 40 00 01 0D 40 00 01 67 40 00 00 00 30 40 01 00 00 30 40 01 40 00 40 40 40 40 40 40 40 01 00 01 40 40 40 00 3A F7"
    static let bankName = "F0 43 00 7F 1C 00 18 07 02 00 00 50 72 65 73 65 74 00 00 00 00 00 00 00 00 00 00 00 00 00 00 04 F7"
    static let slot1 = "F0 43 00 7F 1C 00 22 07 04 00 00 41 2E 50 49 41 4E 4F 20 43 46 58 2B 46 4D 20 45 50 00 00 00 04 40 00 01 7F 01 00 00 00 00 56 F7"
    static let slot2 = "F0 43 00 7F 1C 00 22 07 04 01 00 53 59 4E 20 50 41 44 20 77 2F 20 41 75 74 6F 20 53 4B 00 00 06 40 03 72 6E 01 00 00 00 00 1E F7"
    static let curve = "F0 43 00 7F 1C 00 29 07 01 00 00 55 73 65 72 20 31 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 12 24 36 48 5A 6C 7F 00 12 24 36 48 5A 6C 7F 00 16 F7"
    static let tuningName = "F0 43 00 7F 1C 00 18 07 00 50 00 55 73 65 72 20 31 00 00 00 00 00 00 00 00 00 00 00 00 00 00 39 F7"

    @MainActor static func main() {
        print("Identity")
        if case .identity(let id) = ModxSysEx.parse(bytes(identity)) {
            check(id.model == "MODX7" && id.firmware == "2.50" && id.keyCount == 76, "MODX7, firmware 2.50, 76 keys")
        } else { check(false, "identity reply parses") }

        print("\nBlocks and checksums")
        let all = [system, sequencer, common, reverb, masterEffect, knobNames, part1, bankName, slot1, slot2, curve, tuningName]
        let blocks = all.compactMap(block)
        check(blocks.count == all.count, "all \(all.count) captured blocks parse")
        check(blocks.allSatisfy(\.checksumOK), "every checksum checks out (model ID + address + data + sum ≡ 0)")
        var damaged = bytes(system)
        damaged[20] ^= 0x01
        if case .block(let b) = ModxSysEx.parse(damaged) { check(!b.checksumOK, "a changed byte fails the checksum") }
        check(block(system)?.data.count == 60 && block(common)?.data.count == 94 && block(part1)?.data.count == 121,
              "block sizes match the Data List (System 60, Common 94, Part 121)")

        print("\nSystem and Sequencer")
        let settings = Dictionary((block(system).map(ModxSystemTable.settings) ?? []).map { ($0.name, $0.value) },
                                  uniquingKeysWith: { a, _ in a })
        check(settings["Volume"] == "127" && settings["Tune"] == "+0.0 cents" && settings["Transpose"] == "0 semitones",
              "volume 127, tune +0.0 cents, transpose 0")
        check(settings["Local Control"] == "On" && settings["MIDI IN/OUT"] == "USB" && settings["MIDI I/O Mode"] == "Multi",
              "local control on, MIDI over USB, multi mode")
        check(settings["Super Knob Control Number"] == "CC 95" && settings["Scene Select Control Number"] == "CC 92"
              && settings["Foot Switch Assign"] == "Arp SW", "super knob CC 95, scene CC 92, foot switch Arp SW")
        check(settings["Bulk Interval"] == "0 ms" && settings["Velocity Curve"] == "Normal" && settings["Direct Monitor"] == "On", "bulk interval 0 ms, normal curve, direct monitor on")
        let seq = Dictionary((block(sequencer).map(ModxSystemTable.sequencer) ?? []).map { ($0.name, $0.value) },
                             uniquingKeysWith: { a, _ in a })
        check(seq["Click Mode"] == "Rec" && seq["Click Volume"] == "100" && seq["Click Beat"] == "4th"
              && seq["MIDI Clock Out"] == "On", "click Rec, volume 100, 4th, clock out on")

        print("\nPerformance")
        var perf = ModxPerformanceCommon()
        for b in [common, reverb, masterEffect, knobNames].compactMap(block) { perf.read(block: b) }
        check(perf.name == "CFX + FM EP 2" && perf.tempo == 90 && perf.volume == 127, "“CFX + FM EP 2”, 90 BPM, volume 127")
        check(perf.knobFunction == "Assign" && perf.knobNumbers == Array(0x11...0x18) && perf.unitMultiply == "100%"
              && perf.swing == 0, "knobs on Assign sending CC 17–24, unit multiply 100%, swing 0")
        check(perf.reverb == "REV-X Hall" && perf.masterEffect == "Multi Band Comp", "reverb REV-X Hall, master effect Multi Band Comp")
        check(perf.knobNames.prefix(2) == ["Assigned", "Assigned"] && perf.knobNames.count == 8, "eight knob names")

        var part = ModxPart(index: 0)
        if let b = block(part1) {
            part.name = b.text(0, 20)
            for offset in ModxPart.requested where offset > 0x13 { part.apply(offset: offset, value: b[Int(offset)]) }
        }
        check(part.name == "CFX + FM EP 2" && part.category == "Piano / Acoustic" && part.volume == 98,
              "Part 1: “CFX + FM EP 2”, Piano / Acoustic, volume 98")
        check(part.partSwitch && part.keyboardControl && !part.mute && part.noteRange == "C-2 – G8"
              && part.outputName == "Main L&R" && part.receives == "PB AT PC Bank CC", "Part 1 switches, range, output, receive")
        check(ModxNames.category(main: 1, sub: 1) == "Keyboard / FM Piano", "Keyboard / FM Piano (Part 2)")

        print("\nLive Set and user data")
        let live = ModxLiveSet(blocks: [bankName, slot1, slot2].compactMap(block))
        check(live.bankName == "Preset" && live.slots.count == 2, "bank “Preset” with the two slots")
        if live.slots.count == 2 {
            let a = live.slots[0], b = live.slots[1]
            check(a.name == "A.PIANO CFX+FM EP" && a.colorName == "Blue" && a.bankName == "Preset 1" && a.number == 2
                  && a.volume == 127 && a.on, "slot 1: A.PIANO CFX+FM EP, Blue, Preset 1 #2")
            check(b.name == "SYN PAD w/ Auto SK" && b.colorName == "Pink" && b.bankName == "Preset 4" && b.number == 115
                  && b.volume == 110, "slot 2: SYN PAD w/ Auto SK, Pink, Preset 4 #115")
        }
        let userCurve = block(curve).flatMap(ModxUserCurve.init(block:))
        check(userCurve?.name == "User 1" && userCurve?.outputs == [0x00, 0x12, 0x24, 0x36, 0x48, 0x5A, 0x6C, 0x7F]
              && userCurve?.step == false, "user curve 1: linear")
        check(block(tuningName)?.text(0, 20) == "User 1", "micro-tuning table name")

        print("\nRequests")
        check(ModxLink.isAllowed(.dump(.system)) && ModxLink.isAllowed(.dump(.microTuningName(7)))
              && ModxLink.isAllowed(.bulk(.performancePartBulk(15))) && ModxLink.isAllowed(.parameter(.part(15).with(low: 0x40))),
              "requests the MODX accepts are allowed")
        check(!ModxLink.isAllowed(.dump(.common)) && !ModxLink.isAllowed(.dump(.part(0)))
              && !ModxLink.isAllowed(.parameter(.fmCommon(part: 0))) && !ModxLink.isAllowed(.parameter(.drumKey(0, part: 0)))
              && !ModxLink.isAllowed(.parameter(.element(0, part: 1))),
              "requests that put “Illegal Bulk Data” on the MODX's screen are refused")
        let words = UMP.sysexWords(ModxSysEx.parameterRequest(.part(0)))
        check(words == [0x3016_4330, 0x7F1C_0731, 0x3032_0000, 0], "a Parameter Request packs into two SysEx7 packets")

        print("\nWriting: messages")
        var rebuilt = 0
        for hex in all {
            guard let b = block(hex) else { continue }
            if ModxSysEx.bulkDump(b.address, data: b.data) == bytes(hex) { rebuilt += 1 }
        }
        check(rebuilt == all.count, "every captured block rebuilds byte for byte as a Bulk Dump (\(rebuilt) of \(all.count))")
        check(ModxSysEx.bulkDump(.performanceCommonBulk, data: []) == bytes("F0 43 00 7F 1C 00 04 07 0E 53 00 18 F7"),
              "a Bulk Header matches the MODX's own")
        check(ModxSysEx.parameterChange(.common.with(low: 0x38), data: [54]) == bytes("F0 43 10 7F 1C 07 30 40 38 36 F7"),
              "Parameter Change: Performance Volume 54 (as sent in the write test)")

        print("\nWriting: values")
        func param(_ list: [ModxParam], _ key: String) -> ModxParam { list.first { $0.key == key }! }
        let tempo = param(ModxParams.common, "com.tempo")
        let commonData = block(common)!.data
        check(tempo.value(in: commonData) == 90 && tempo.bytes(for: 120, current: commonData) == [0x00, 0x78]
              && tempo.bytes(for: 301, current: commonData) == nil, "tempo 90 reads, 120 encodes as 00 78, 301 is refused")
        let tune = param(ModxParams.system, "sys.tune")
        let systemData = block(system)!.data
        check(tune.value(in: systemData) == 1024 && tune.display(1024) == "+0.0 cents" && tune.bytes(for: 1034, current: systemData) == [0, 4, 0, 10],
              "tune: 1024 is +0.0 cents, +1.0 cents encodes as 00 04 00 0A")
        let pb = param(ModxParams.part, "part.rx.64.6")
        let partData = block(part1)!.data
        check(pb.value(in: partData) == 1 && pb.bytes(for: 0, current: partData) == [0x3C],
              "receive Pitch Bend is bit 6 of 7C: switching it off leaves 3C")
        let name = param(ModxParams.common, "com.name")
        check(name.bytes(forText: "Live Rig") == Array("Live Rig".utf8) + Array(repeating: 0x20, count: 12)
              && name.bytes(forText: "Ünïcode") == [0x20, 0x6E, 0x20, 0x63, 0x6F, 0x64, 0x65] + Array(repeating: 0x20, count: 13),
              "names are 20 ASCII characters, padded with spaces")
        let rev = param(ModxParams.reverb, "rev.type"), varType = param(ModxParams.variation, "var.type")
        let mfx = param(ModxParams.masterEffect, "mfx.type")
        check(rev.isAllowed(0x0100) && !rev.isAllowed(0x0300) && varType.isAllowed(0x0300) && !varType.isAllowed(0x0103)
              && mfx.isAllowed(0x0820) && !mfx.isAllowed(0x0300),
              "effect types per block: REV-X Hall for Reverb only, G Chorus not for Reverb or Master, Multi Band Comp for Master")
        check(ModxEffects.allowed(.reverb).count == 13 && ModxEffects.allowed(.master).count == 26
              && ModxEffects.allowed(.adInsertion).count == ModxEffects.allowed(.insertion).count - 5,
              "13 Reverb choices, 26 Master Effect types, five Tech effects not on the A/D insertion")

        print("\nWriting: what may be sent")
        check(ModxLink.isWritable(.common.with(low: 0x38), data: [54]) && ModxLink.isWritable(.system.with(low: 0x0C), data: [0])
              && ModxLink.isWritable(ModxAddress(0x31, 0x01, 0x24), data: [100]),
              "Performance Volume, Touch Panel Sound and Part 2 Volume may be changed")
        check(!ModxLink.isWritable(ModxAddress(0x00, 0x00, 0x07), data: [80]) && !ModxLink.isWritable(ModxAddress(0x30, 0x40, 0x14), data: [1])
              && !ModxLink.isWritable(ModxAddress(0x41, 0x00, 0x05), data: [1]) && !ModxLink.isWritable(.common.with(low: 0x2C), data: [0x5A])
              && !ModxLink.isWritable(.common.with(low: 0x03), data: [0x07]),
              "refused: transpose out of range, a reserved byte, a reserved element byte, half a two-byte value, a control character")
        check(ModxLink.isWritable(ModxAddress(0x48, 0x00, 0x4F), data: [7]) && !ModxLink.isWritable(ModxAddress(0x48, 0x00, 0x4F), data: [88])
              && ModxLink.isWritable(ModxAddress(0x49, 0x10, 0x1A), data: [99]) && !ModxLink.isWritable(ModxAddress(0x49, 0x10, 0x1A), data: [100])
              && !ModxLink.isWritable(ModxAddress(0x49, 0x10, 0x00), data: [0]) && !ModxLink.isWritable(ModxAddress(0x48, 0x00, 0x51), data: [0])
              && !ModxLink.isWritable(ModxAddress(0x49, 0x80, 0x1A), data: [10]),
              "FM-X: algorithm 1–88 and operator 2's level 0–99 may be sent; reserved bytes and a ninth operator may not")
        check(ModxLink.isWritable(ModxAddress(0x41, 0x11, 0x03), data: [0x10, 0x4D]) && ModxLink.isWritable(ModxAddress(0x42, 0x11, 0x01), data: [0x01, 0x7F])
              && !ModxLink.isWritable(ModxAddress(0x41, 0x11, 0x49), data: [0x08]) && ModxLink.isWritable(ModxAddress(0x31, 0x62, 0x00), data: [0])
              && !ModxLink.isWritable(ModxAddress(0x31, 0x62, 0x01), data: [0]),
              "AWM2: Part 2 element 2's waveform (2125 Saw) and cutoff 255; not a coarse tune below −48; the Part Arp Switch, not the byte after it")
        var fmPart = ModxPart(index: 0), awmPart = ModxPart(index: 1)
        fmPart.type = .fmx; awmPart.type = .awm2
        let level = ModxParams.fmOperator.first { $0.key == "op.level" }!, cutoff = ModxParams.elementFilter.first { $0.key == "ef.cutoff" }!
        check(level.applies(to: fmPart) && !level.applies(to: awmPart) && cutoff.applies(to: awmPart) && !cutoff.applies(to: fmPart),
              "FM-X settings only for an FM-X Part, AWM2 element settings only for an AWM2 Part")
        let algorithms = ModxFMAlgorithms.known
        check(algorithms.count == 8 && algorithms.values.allSatisfy { a in a.positions.count == 8 && a.feedback == 1
                  && a.edges.allSatisfy { a.positions[$0.from]!.row == a.positions[$0.to]!.row + 1 || a.positions[$0.to]!.row == 0 } }
              && algorithms[1]!.carriers == Array(1...8) && algorithms[8]!.carriers == Array(2...8) && algorithms[6]!.carriers == [2, 4, 5, 6, 7, 8]
              && algorithms[2]!.modulates(3) == [4],
              "FM-X algorithms 1–8 as the Algorithm Chart draws them: 8 operators, feedback on 1, modulators above their targets")
        check(ModxLink.isWritable(.common.with(low: 0x03), data: [0x41]) && ModxLink.isWritable(ModxAddress(0x04, 0x01, 0x13), data: [0x20])
              && !ModxLink.isWritable(.common.with(low: 0x00), data: Array(repeating: 0x41, count: 20)),
              "names go one character at a time (Name 4 of the Performance, Name 20 of a slot), never as one 20-byte change")
        check(ModxBulkRules.isAllowed(ModxAddress(0x04, 0x01, 0x00), size: 30) && !ModxBulkRules.isAllowed(.system, size: 59)
              && ModxBulkRules.isAllowed(ModxAddress(0x0E, 0x52, 0x0F), size: 0) && !ModxBulkRules.isAllowed(ModxAddress(0x0E, 0x25, 0x00), size: 0)
              && ModxBulkRules.isAllowed(.sequencer, size: block(sequencer)!.data.count),
              "bulk blocks: a 30-byte Live Set slot, not a short System block; Part 16's header, not the whole edit buffer's")

        print("\nWorkspace file")
        var file = ModxWorkspaceFile()
        file.model = "MODX7"; file.firmware = "2.50"; file.performance = "CFX + FM EP 2"
        func entry(_ hex: String) -> ModxWorkspaceFile.Block {
            let b = block(hex)!
            return .init(address: b.address.description, data: ModxWorkspaceFile.hex(b.data))
        }
        file.sections = [
            .init(id: "system", title: "System", header: nil, blocks: [entry(system)]),
            .init(id: "performance.common", title: "Performance Common", header: "0E 53 00", blocks: [entry(common), entry(reverb)]),
            .init(id: "performance.part1", title: "Part 1", header: "0E 52 00", blocks: [entry(part1)]),
            .init(id: "liveSet", title: "Live Set", header: "0E 51 00", blocks: [entry(bankName), entry(slot1), entry(slot2)]),
        ]
        file.summary = ModxModel.summary(of: file)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("modx-test-\(getpid()).modxworkspace")
        do {
            try file.write(url)
            let back = try ModxWorkspaceFile.read(url)
            check(back.sections == file.sections && back.model == "MODX7" && back.summary == file.summary, "saves and reads back the same")
            try? FileManager.default.removeItem(at: url)
        } catch { check(false, "workspace write/read: \(error)") }
        check(file.summary.contains { $0.title == "System" && $0.rows.count == 33 } && file.summary.contains { $0.title == "Parts" },
              "the readable summary has the System settings and the Parts")
        let messages = file.messages(for: file.sections[1])
        check(messages?.count == 4 && messages?.first?.0 == .performanceCommonBulk && messages?.last?.0 == ModxAddress(0x0F, 0x53, 0x00),
              "a section sends as header, blocks, footer")
        var wrong = file.sections[2]
        wrong.header = "0E 52 01"
        check(file.messages(for: wrong) == nil, "Part 1's blocks won't go under Part 2's header")
        var tampered = file.sections[0]
        tampered.blocks[0].data += " 00"
        check(file.messages(for: tampered) == nil, "a block of the wrong size isn't sent")

        print("\nLive Set: Performance names and workspace banks")
        check(ModxPresetPerformances.names.count == 2227 && ModxPresetPerformances.names.first == "CFX + FM EP",
              "2,227 preset Performances (firmware 2.50), No. 1 “CFX + FM EP”")
        check(ModxPerformanceNames.preset(lsb: 3, number: 97) == "Ocean Pad",
              "Preset 4 #97 is “Ocean Pad” (what the MODX shows for Best of MODX 1, slot 6, whose slot name is “SYN PAD”)")
        let names = ModxPerformanceNames()
        if live.slots.count == 2 {
            check(names.name(of: live.slots[0])?.name == "CFX + FM EP 2" && names.name(of: live.slots[1])?.name == "Creation",
                  "slots 1 and 2 recall “CFX + FM EP 2” and “Creation”, as the Data List's Live Set List says")
            var oneSlot = live.slots[1]
            oneSlot.bankMSB = 63
            var voice = live.slots[1]
            voice.bankMSB = 0
            check(names.name(of: oneSlot)?.name == "Creation" && names.name(of: voice) == nil,
                  "a One Part slot (MSB 63) names its Performance too; other banks aren't Performances")
        }
        check(ModxPerformanceNames.preset(lsb: 32, number: 1) == nil && ModxPerformanceNames.preset(lsb: 0, number: 129) == nil
              && ModxPerformanceNames.preset(lsb: 17, number: 128) == nil,
              "no preset name for User banks, numbers past 128, or past the list's end (Preset 18 #128)")
        var learned = ModxPerformanceNames()
        check(learned.learn(lsb: 32, number: 5, name: "My Pad") && learned.name(lsb: 32, number: 5)! == ("My Pad", .seen)
              && !learned.learn(lsb: 32, number: 5, name: "My Pad"),
              "a User Performance's name is learned once, as seen")
        check(!learned.learn(lsb: 3, number: 97, name: "Ocean Pad") && learned.seen.count == 1,
              "a preset's own name isn't stored again")
        check(learned.learn(lsb: 3, number: 97, name: "Renamed") && learned.name(lsb: 3, number: 97)?.name == "Renamed"
              && learned.learn(lsb: 3, number: 97, name: "Ocean Pad") && learned.name(lsb: 3, number: 97)! == ("Ocean Pad", .preset),
              "a name seen on the MODX wins over the list, and seeing the list's name again drops it")
        let workspaceURL = URL(fileURLWithPath: "/tmp/Test.modxworkspace")
        if let bank = ModxWorkspaceLiveSet(url: workspaceURL, file: file) {
            let sendable = bank.file.sections.first.flatMap { bank.file.messages(for: $0) }
            check(bank.liveSet.bankName == "Preset" && bank.liveSet.slots.count == 2 && bank.fileName == "Test"
                  && bank.file.sections.map(\.id) == ["liveSet"] && sendable?.count == 5
                  && sendable?.first?.0 == .liveSetBulk && sendable?.last?.0 == ModxAddress(0x0F, 0x51, 0x00),
                  "a workspace's Live Set bank: its slots, and only that section to send (header, 3 blocks, footer)")
        } else { check(false, "a workspace's Live Set bank") }
        var noLiveSet = file
        noLiveSet.sections.removeAll { $0.id == "liveSet" }
        check(ModxWorkspaceLiveSet(url: workspaceURL, file: noLiveSet) == nil, "a workspace without a Live Set offers no bank")
        check(file.summary.contains { $0.rows.contains { $0.last == "Creation (slot “SYN PAD w/ Auto SK”) · Preset 4 #115" } },
              "the readable summary names a slot's Performance and its slot name")

        print("\nMIDI songs")
        check(SMF.vlq(0) == [0] && SMF.vlq(127) == [0x7F] && SMF.vlq(128) == [0x81, 0x00] && SMF.vlq(0x0FFF_FFFF) == [0xFF, 0xFF, 0xFF, 0x7F],
              "variable-length delta times: 0, 127, 128, the largest")
        // Format 0, 96 ticks a quarter: 100 BPM, 3/4, a name; on channel 1 a C3 (60) for a quarter, then E3 by
        // running status, ended by a Note On of velocity 0; on channel 2 a program change, a controller and a G2.
        let format0: [UInt8] = Array("MThd".utf8) + [0, 0, 0, 6, 0, 0, 0, 1, 0, 96] + Array("MTrk".utf8)
        var body: [UInt8] = [0x00, 0xFF, 0x03, 0x04] + Array("Demo".utf8)
        body += [0x00, 0xFF, 0x51, 0x03, 0x09, 0x27, 0xC0]   // 600,000 µs = 100 BPM
        body += [0x00, 0xFF, 0x58, 0x04, 0x03, 0x02, 0x18, 0x08]   // 3/4
        body += [0x00, 0x90, 60, 100, 0x60, 0x80, 60, 64]   // C3, a quarter
        body += [0x00, 0x90, 64, 90, 0x30, 64, 0]   // E3 by running status, off by velocity 0 after an eighth
        body += [0x00, 0xC1, 5, 0x00, 0xB1, 7, 80, 0x00, 0x91, 55, 70, 0x81, 0x40, 0x81, 55, 0]   // ch 2: PC, CC7, G2 (192 ticks)
        body += [0x00, 0xF0, 0x05, 0x7E, 0x7F, 0x09, 0x01, 0xF7]   // a GM System On (kept, never played)
        body += [0x00, 0xFF, 0x2F, 0x00]
        let fileBytes = format0 + [0, 0, 0, UInt8(body.count)] + body
        if let smf = try? SMF.parse(Data(fileBytes)) {
            let song = MIDISong(smf: smf, name: "file")
            check(smf.format == 0 && smf.division == 96 && smf.tracks.count == 1 && smf.tracks[0].count == 13,
                  "reads a format 0 file: 96 ticks a quarter, one track of 13 events (running status included)")
            check(song.tracks.count == 2 && song.tracks.map(\.channel) == [0, 1] && song.tracks[0].name == "Demo · Ch 1"
                  && song.tracks[0].notes.map { [$0.tick, $0.length, $0.key, $0.velocity] } == [[0, 96, 60, 100], [96, 48, 64, 90]]
                  && song.tracks[1].notes.map { [$0.tick, $0.length, $0.key] } == [[144, 192, 55]],
                  "splits it by channel into 2 tracks and pairs the notes (a Note On of velocity 0 ends one)")
            check(abs(song.bpm - 100) < 0.01 && song.beatsPerBar == 3 && song.beatUnit == 4 && song.tracks[1].program == 6
                  && song.tracks[1].controller(7) == nil && song.tracks[1].events.contains { $0.tick == 144 && $0.data == [7, 80] }
                  && song.tracks[0].events.contains { $0.status == 0xF0 },
                  "tempo 100, 3/4, the second track's program 6 and its volume change at tick 144 (not a start volume); the SysEx kept")
            let events = song.playEvents(sendProgramChanges: false)
            check(!events.contains { $0.bytes[0] & 0xF0 == 0xC0 || $0.bytes[0] == 0xF0 }
                  && song.playEvents(sendProgramChanges: true).contains { $0.bytes == [0xC1, 5] }
                  && events.first.map { $0.bytes == [0x90, 60, 100] } == true
                  && events.firstIndex { $0.bytes == [0x80, 60, 64] }! < events.firstIndex { $0.bytes == [0x90, 64, 90] }!,
                  "plays no SysEx, and Program Change only if asked; at one tick the Note Off before the Note On")
            if let back = try? SMF.parse(song.smf.encode()) {
                let again = MIDISong(smf: back, name: "again")
                check(back.format == 1 && back.tracks.count == 3 && again.name == "file" && again.tracks.count == 2
                      && again.tracks.map { $0.notes.map { [$0.tick, $0.length, $0.key, $0.velocity] } } == song.tracks.map { $0.notes.map { [$0.tick, $0.length, $0.key, $0.velocity] } }
                      && abs(again.bpm - 100) < 0.01 && again.beatsPerBar == 3 && again.tracks[1].program == 6
                      && again.tracks[1].events.contains { $0.tick == 144 && $0.kind == 0xB0 && $0.data == [7, 80] },
                      "saves format 1 (a conductor track and 2 tracks) and reads back the same notes, tempo, metre, volume and program")
            } else { check(false, "the saved file reads back") }
        } else { check(false, "reads a format 0 file") }
        check((try? SMF.parse(Data("RIFF....".utf8))) == nil, "refuses a file that isn't MIDI")
        var timed = MIDISong()
        timed.division = 480
        timed.tempos = [TempoChange(tick: 0, microsPerQuarter: 500_000), TempoChange(tick: 960, microsPerQuarter: 1_000_000)]
        check(abs(timed.seconds(atTick: 960) - 1.0) < 1e-9 && abs(timed.seconds(atTick: 1440) - 2.0) < 1e-9
              && timed.tick(atSeconds: 2.0) == 1440 && timed.tick(atSeconds: 0.5) == 480 && timed.position(0) == "1.1.1"
              && timed.position(timed.ticksPerBar + timed.ticksPerBeat + 120) == "2.2.2",
              "the tempo map: two beats at 120 BPM take a second, the next beat at 60 another; bar.beat.sixteenth")
        let demo = MIDISong.demo(parts: [(0, false, "Piano"), (1, false, "Bass"), (2, false, "Lead"), (9, true, "Drums")])
        check(demo.tracks.map(\.name) == ["Chords", "Bass", "Melody", "Drums"] && demo.tracks.map(\.channel) == [0, 1, 2, 9]
              && demo.bars == 8 && abs(demo.bpm - 100) < 0.01 && demo.tracks.allSatisfy { $0.controller(7) != nil },
              "the demo song: chords, bass, melody and drums on the Performance's Parts, 8 bars at 100 BPM, each with a volume")
        check(MIDISong.demo(parts: [(3, false, "Pad")]).tracks.map(\.channel) == [3, 3, 3],
              "with a single Part, every demo track plays it")
        var track = SongTrack(name: "T", channel: 0)
        track.events = [SMF.Event(tick: 0, status: 0xB0, data: [7, 90]), SMF.Event(tick: 10, status: 0xE0, data: [0, 64])]
        track.setChannel(4)
        track.setController(7, 70)
        track.setController(10, 20)
        check(track.events.allSatisfy { $0.status & 0x0F == 4 } && track.volume == 70 && track.pan == 20 && track.events.count == 3,
              "a track's channel moves all its events; the mixer's volume and pan replace or add a controller at the start")

        print("\nTutorials")
        let numericFM = (ModxParams.fmCommon + ModxParams.fmOperator).filter { param in
            switch param.format { case .names, .choices, .onOff, .note, .effect, .text: false; case .custom: !["op.lsBreak", "fm.filterType"].contains(param.key); default: true }
        }
        let coarse = ModxParams.fmOperator.first { $0.key == "op.coarse" }!
        check(numericFM.count == 53 && numericFM.allSatisfy { $0.unit != nil } && coarse.display(0) == "×0.5" && coarse.display(3) == "×3"
              && ModxParams.fmOperator.first { $0.key == "op.level" }!.unit == "of 99"
              && ModxParams.fmOperator.first { $0.key == "op.levelVel" }!.unit == "of ±7",
              "every numeric FM-X setting has a unit label (53): levels “of 99”, sensitivities “of ±7”, ratios “×3”")
        let attack = ModxTiming.fmAttack, decay = ModxTiming.fmDecay, release = ModxTiming.fmRelease
        check(attack.label(0) == "< 3 ms" && attack.label(40) == "≈ 100 ms" && attack.label(50) == "≈ 310 ms"
              && attack.label(60) == "≈ 1.0 s" && attack.label(85) == "≈ 16 s" && attack.label(97) == "> 32 s" && attack.label(99) == "> 40 s",
              "FM-X attack times as measured on the MODX7: 0 under 3 ms, 40 ≈ 100 ms, 60 ≈ 1 s, 99 over 40 s")
        check(decay.label(40) == "≈ 390 ms" && release.label(50) == "≈ 1.1 s" && release.label(0) == "< 3 ms" && decay.label(95) == "> 80 s",
              "decay and release labelled as a full fall, twice the 99→50 time measured (decay 40 ≈ 390 ms, as timed to level 0)")
        let rising = (0...99).map { decay.seconds($0) ?? .infinity }
        check(zip(rising, rising.dropFirst()).allSatisfy { $0 <= $1 } && (0...99).allSatisfy { !attack.label($0).isEmpty }
              && (decay.seconds(42)! > decay.seconds(40)! && decay.seconds(42)! < decay.seconds(45)!),
              "times never fall as the value rises, and values between those measured are interpolated")
        check(["op.aegAttack", "op.aegDecay1", "op.aegRelease"].allSatisfy { k in ModxParams.fmOperator.first { $0.key == k }!.timing != nil }
              && ModxParams.fmOperator.first { $0.key == "op.aegAttack" }!.unitLabel(40) == "≈ 100 ms"
              && ModxParams.fmOperator.first { $0.key == "op.level" }!.unitLabel(40) == "of 99",
              "the lessons' attack, decay and release times show milliseconds or seconds; other settings keep their unit")
        for engine in ModxEngine.allCases {
            let lessons = engine.lessons
            var problems: [String] = []
            var count = 0
            for lesson in lessons where !lesson.lessonOnly {
                for s in lesson.settings(engine) {
                    count += 1
                    let target = s.target(part: 3)
                    guard let param = s.param else { problems.append("\(lesson.id): no setting \(s.key)"); continue }
                    guard let bytes = param.bytes(for: s.value, current: [UInt8](repeating: 0, count: 128)) else {
                        problems.append("\(lesson.id): \(s.key) = \(s.value) out of range"); continue
                    }
                    let address = target.base.with(low: target.base.low + UInt8(param.offset))
                    if !ModxLink.isWritable(address, data: bytes) { problems.append("\(lesson.id): \(s.key) at \(address) not writable") }
                    if ModxParams.find(address, size: bytes.count)?.1.key != s.key { problems.append("\(lesson.id): \(s.key) found as another setting") }
                }
                for control in lesson.controls where control.param == nil { problems.append("\(lesson.id): no control \(control.key)") }
                if engine == .fmx, let a = lesson.algorithm, ModxFMAlgorithms.known[a] == nil { problems.append("\(lesson.id): algorithm \(a) not drawn") }
            }
            check(problems.isEmpty && Set(lessons.map(\.id)).count == lessons.count && lessons.first?.lessonOnly == true,
                  "\(engine.title): \(lessons.count) lessons, \(count) settings, each one the MODX accepts at its address\(problems.isEmpty ? "" : " — \(problems.prefix(4))")")
        }
        var awm = ModxPart(index: 3)
        awm.type = .awm2
        let fmOnly = ModxTutorials.fmBase(algorithm: 8).compactMap { $0.param }.filter { $0.restriction == .fmxOnly }
        check(!fmOnly.isEmpty && fmOnly.allSatisfy { !$0.applies(to: awm) }
              && ModxTutorials.fmLessons[2].settings(.fmx).contains { $0.key == "op.level" && $0.block == .op(0) && $0.value == 45 }
              && ModxTutorials.fmLessons[2].settings(.fmx).filter { $0.key == "op.level" && $0.block == .op(0) }.count == 1,
              "a lesson's own settings replace the plain sound's (one operator 1 level, the lesson's 45); FM-X settings never on an AWM2 Part")
        let plain: [String: Int] = ["part.variation": 0, "part.reverb": 0, "part.insSwitch": 0, "part.dry": 127, "part.pan": 64]
        let plainEverywhere = (ModxTutorials.fmLessons.map { $0.settings(.fmx) } + ModxTutorials.awm2Lessons.map { $0.settings(.awm2) }).allSatisfy { settings in
            plain.allSatisfy { key, value in settings.filter { $0.key == key && $0.block == .part }.map(\.value) == [value] }
        }
        check(plainEverywhere, "every lesson plays dry and centred: no Variation or Reverb send, insertion effects off, dry level full, pan centre")
        check(ModxLink.liveSetSelect(page: 0, slot: 9, channel: 0) == [[0xB0, 0x00, 0x3E], [0xB0, 0x20, 0x00], [0xC0, 0x09]]
              && ModxLink.liveSetSelect(page: 15, slot: 15, channel: 3) == [[0xB3, 0x00, 0x3E], [0xB3, 0x20, 0x0F], [0xC3, 0x0F]]
              && ModxLink.liveSetSelect(page: 16, slot: 0, channel: 0) == nil && ModxLink.liveSetSelect(page: 0, slot: 0, channel: 16) == nil,
              "choosing a slot: Live Set Select — Bank Select MSB 62, LSB page, Program Change slot — and nothing out of range")
        check(UMP.messageWords([0xB0, 0x00, 0x3E]) == [0x20B0_003E] && UMP.messageWords([0xC0, 0x09]) == [0x20C0_0900],
              "as MIDI 1.0 channel-voice packets on group 1")

        // Current State: the signal path, from a Performance like FM Sweeping Poly in a tutorial (Part 1 a pad panned
        // hard left, sending to a Tempo Cross Delay; Part 2 muted to hear Part 1 alone) plus a bass straight to USB.
        func stateBlock(_ a: ModxAddress, _ size: Int, _ values: [Int: UInt8]) -> ModxBlock {
            var data = [UInt8](repeating: 0, count: size)
            for (offset, value) in values { data[offset] = value }
            return ModxBlock(address: a, data: data, checksumOK: true)
        }
        var pad = ModxPart(index: 0); pad.name = "FM Sweeping Poly"; pad.type = .fmx; pad.partSwitch = true; pad.keyboardControl = true
        pad.pan = 1; pad.variationSend = 32
        var choir = ModxPart(index: 1); choir.name = "PAD/CHOIR"; choir.partSwitch = true; choir.keyboardControl = true; choir.mute = true
        var bass = ModxPart(index: 2); bass.name = "Bass"; bass.partSwitch = true; bass.keyboardControl = true; bass.output = 9; bass.noteHigh = 59
        bass.variationSend = 40
        let stateStore: [ModxAddress: ModxBlock] = [
            ModxAddress(0x30, 0x42, 0x00): stateBlock(ModxAddress(0x30, 0x42, 0x00), 72, [0: 0x02, 1: 0x10, 0x44: 96, 0x45: 64, 0x47: 1]),
            ModxAddress(0x30, 0x41, 0x00): stateBlock(ModxAddress(0x30, 0x41, 0x00), 71, [0: 0x01, 1: 0x00, 0x44: 64, 0x45: 64, 0x46: 1]),
            ModxAddress(0x31, 0x00, 0x00): stateBlock(ModxAddress(0x31, 0x00, 0x00), 121, [0x26: 3, 0x3B: 1, 0x74: 1]),
            ModxAddress(0x31, 0x20, 0x00): stateBlock(ModxAddress(0x31, 0x20, 0x00), 68, [0: 0x0C, 1: 0x00]),
            ModxAddress(0x31, 0x30, 0x00): stateBlock(ModxAddress(0x31, 0x30, 0x00), 68, [0: 0x03, 1: 0x10]),
            ModxAddress(0x31, 0x22, 0x00): stateBlock(ModxAddress(0x31, 0x22, 0x00), 68, [0: 0x02, 1: 0x28]),
        ]
        let allParts = [pad, choir, bass] + (3..<16).map { ModxPart(index: $0) }
        let localOn = stateBlock(ModxAddress(0x00, 0x00, 0x00), 60, [0x09: 1])
        let state = ModxSignalPath(parts: allParts, store: stateStore, system: localOn, tempo: 90, notes: [48, 72], velocity: 100, hearOnly: [1])
        let p1 = state.parts[0], p3 = state.parts[2]
        check(state.parts.count == 3 && p1.insertionA.name == "Ring Modulator" && p1.insertionA.on && p1.insertionB.name == "2 Modulator"
              && p1.insertionB.on && p1.insertionConnection == "Ins A → B" && p1.motionSeq && !p3.insertionA.on && p3.insertionA.name == "Tempo Delay Stereo",
              "Current State: each Part's insertion effects (31 2p, 31 3p) with their switches and connection")
        check(p1.heldNotes == [48, 72] && p3.heldNotes == [48] && state.parts[1].heldNotes == [48, 72] && !state.parts[1].sounding && p1.sounding
              && p3.usbChannels == [2, 3] && !p3.toMain && state.variation.name == "Tempo Cross Delay" && state.variationReturn == 96 && state.variation.on,
              "the keys held play the Parts whose limits take them; a muted Part doesn't sound; USB 1&2 is the MODX's audio channels 3–4")
        let findings = Dictionary(uniqueKeysWithValues: state.findings.map { ($0.id, $0.text) })
        check(findings["keys"] == "The keys play Parts 1 and 3."
              && findings["echo0"] == "Part 1 echoes: it sends 32 to the Variation, Tempo Cross Delay (return 96), which repeats its notes in time with the tempo (90 BPM)."
              && findings["pan0"] == "Part 1 is panned hard left (L63)." && findings["hearOne"]?.hasPrefix("Part 2 (PAD/CHOIR) is muted by") == true
              && findings["mute1"] == nil && findings["usb2"]?.contains("straight to USB 1&2") == true && findings["echo2"] == nil && findings["insA2"] == nil,
              "what you'll hear: the delay that echoes Part 1 (not the bass, which skips it), the hard pan, the tutorial's mutes, the Part only the Mac hears")
        let localOff = ModxSignalPath(parts: allParts, store: stateStore, system: stateBlock(ModxAddress(0x00, 0x00, 0x00), 60, [0x09: 0]),
                                      tempo: 90, notes: [60], velocity: 90)
        check(localOff.findings.first?.id == "local" && localOff.keyParts.isEmpty && localOff.parts.allSatisfy { $0.heldNotes.isEmpty },
              "with Local Control off the keys play no Part, and the page says so first")
        check(ModxSignalPath.Effect(value: 0x0210).kind == .repeats && ModxSignalPath.Effect(value: 0x0100).kind == .reverb
              && ModxSignalPath.Effect(value: 0x0C78).kind == .repeats && ModxSignalPath.Effect(value: 0x0730).kind == .repeats
              && ModxSignalPath.Effect(value: 0x0D00).kind == .other && ModxSignalPath.Effect(value: 0).kind == .none
              && ModxSignalPath.pan(1) == "L63" && ModxSignalPath.pan(64) == "C" && ModxSignalPath.pan(127) == "R63",
              "delays, Comp Distortion Delay and Beat Repeat count as repeating notes; pan reads L63 … C … R63")
        let collector = ModxAudioMeter.Collector()
        collector.reset(channels: 2, rate: 44100)
        if let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2),
           let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2646) {
            buffer.frameLength = 2646
            for c in 0..<2 { for i in 0..<2646 { buffer.floatChannelData![c][i] = 0.5 * sin(Float(i) * 2 * .pi * 441 / 44100) } }
            collector.add(buffer)
        }
        let levels = collector.take()
        check(levels.peaks.count == 2 && abs(levels.peaks[0] - 0.5) < 0.001 && abs(levels.rms[0] - 0.3536) < 0.002 && levels.history.count == 3
              && abs(ModxAudioMeter.decibels(0.5) - -6.02) < 0.01 && ModxAudioMeter.decibels(0) == ModxAudioMeter.floor
              && collector.take().peaks == [0, 0],
              "the audio meter: a −6 dBFS sine reads peak 0.5 and RMS 0.354, three 20 ms steps in 60 ms, and the next reading starts afresh")

        print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) FAILED.")
        exit(failures == 0 ? 0 : 1)
    }
}
