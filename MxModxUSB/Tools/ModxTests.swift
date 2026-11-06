// ModxTests.swift — checks MxModxUSB's decoding against replies a MODX7 (firmware 2.50) really sent over USB on
// 11/6/26 (Performance "CFX + FM EP 2", Live Set bank "Preset"). Tools/build-tools.sh builds it; no MODX needed.

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
              && !ModxLink.isWritable(ModxAddress(0x41, 0x00, 0x00), data: [1]) && !ModxLink.isWritable(.common.with(low: 0x2C), data: [0x5A])
              && !ModxLink.isWritable(.common.with(low: 0x03), data: [0x07]),
              "refused: transpose out of range, a reserved byte, element data, half a two-byte value, a control character")
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
        check(ModxLink.liveSetSelect(page: 0, slot: 9, channel: 0) == [[0xB0, 0x00, 0x3E], [0xB0, 0x20, 0x00], [0xC0, 0x09]]
              && ModxLink.liveSetSelect(page: 15, slot: 15, channel: 3) == [[0xB3, 0x00, 0x3E], [0xB3, 0x20, 0x0F], [0xC3, 0x0F]]
              && ModxLink.liveSetSelect(page: 16, slot: 0, channel: 0) == nil && ModxLink.liveSetSelect(page: 0, slot: 0, channel: 16) == nil,
              "choosing a slot: Live Set Select — Bank Select MSB 62, LSB page, Program Change slot — and nothing out of range")
        check(UMP.messageWords([0xB0, 0x00, 0x3E]) == [0x20B0_003E] && UMP.messageWords([0xC0, 0x09]) == [0x20C0_0900],
              "as MIDI 1.0 channel-voice packets on group 1")

        print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) FAILED.")
        exit(failures == 0 ? 0 : 1)
    }
}
