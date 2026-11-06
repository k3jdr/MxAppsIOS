// MxMidiTests.swift — checks MxMidiPRO's MIDI code outside the app (Tools/build-tools.sh builds it).
//
//   • the byte parser (running status, realtime bytes inside messages, system exclusive across packets);
//   • the spy driver's envelope: SpyDriver/MxSpyCore.c encodes, the app's SpyFeed decodes;
//   • Universal MIDI Packets back to MIDI 1.0 bytes;
//   • note names and message text;
//   • the engine end to end on virtual ports only — IN from a source, a thru port forwarding to a destination, and the
//     spy path fed by the driver's own code — so nothing is sent to real devices.
//
// Run:  mxmidi-tests -MxSpyTestSource "MxTest Spy Feed" -MxThruTestTarget "MxTest Synth"

import CoreMIDI
import Foundation

@main
struct MxMidiTests {
    nonisolated(unsafe) static var failures = 0

    static func check(_ ok: Bool, _ what: String, line: Int = #line) {
        if ok { print("  ok    \(what)") } else { failures += 1; print("  FAIL  \(what)  (line \(line))") }
    }

    static func section(_ title: String) { print("\n\(title)") }

    typealias Message = (status: UInt8, d1: UInt8, d2: UInt8, sysex: [UInt8]?)

    static func feed(_ parser: inout MIDIByteParser, _ bytes: [UInt8]) -> [Message] {
        var out: [Message] = []
        for b in bytes { parser.feed(b) { out.append(($0, $1, $2, $3)) } }
        return out
    }

    static func same(_ m: Message, _ s: UInt8, _ d1: UInt8 = 0, _ d2: UInt8 = 0) -> Bool {
        m.status == s && m.d1 == d1 && m.d2 == d2 && m.sysex == nil
    }

    static func pump(_ seconds: Double) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    static func main() {
        parserTests()
        spyEnvelopeTests()
        umpTests()
        formatTests()
        engineTests()
        print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) FAILED.")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: Parser

    static func parserTests() {
        section("Byte parser")
        var p = MIDIByteParser()
        var out = feed(&p, [0x90, 60, 100, 62, 90, 0xF8, 64, 0])
        check(out.count == 4, "running status with a clock between messages gives 4 messages")
        if out.count == 4 {
            check(same(out[0], 0x90, 60, 100) && same(out[1], 0x90, 62, 90), "note-ons by running status")
            check(same(out[2], 0xF8), "clock passed through")
            check(same(out[3], 0x90, 64, 0) && MIDIKind(status: 0x90, data2: 0) == .noteOff, "velocity 0 is a note-off")
        }

        p = MIDIByteParser()
        out = feed(&p, [0xB0, 0xF8, 1, 0xFE, 64])
        check(out.count == 3 && same(out[0], 0xF8) && same(out[1], 0xFE) && same(out[2], 0xB0, 1, 64),
              "realtime bytes inside a control change")

        p = MIDIByteParser()
        out = feed(&p, [0xF0, 0x43, 0x10])
        check(out.isEmpty, "system exclusive waits for F7")
        out = feed(&p, [0x4C, 0xF8, 0x00, 0xF7])
        check(out.count == 2 && same(out[0], 0xF8) && out[1].sysex == [0xF0, 0x43, 0x10, 0x4C, 0x00, 0xF7],
              "system exclusive across two packets, clock inside it")

        p = MIDIByteParser()
        out = feed(&p, [0xF0, 1, 2, 0x80, 60, 0])
        check(out.count == 2 && out[0].sysex == [0xF0, 1, 2] && same(out[1], 0x80, 60, 0),
              "a status byte ends an unterminated system exclusive")

        p = MIDIByteParser()
        out = feed(&p, [0xF2, 0x10, 0x02, 0x05])
        check(out.count == 1 && same(out[0], 0xF2, 0x10, 0x02), "song position; no running status after it")

        p = MIDIByteParser()
        out = feed(&p, [0xC3, 5, 6, 0xD3, 40])
        check(out.count == 3 && same(out[0], 0xC3, 5) && same(out[1], 0xC3, 6) && same(out[2], 0xD3, 40),
              "two-byte messages with running status")
    }

    // MARK: Spy envelope

    static func spyEnvelopeTests() {
        section("Spy envelope (MxSpyCore.c → SpyFeed)")
        var generator = SystemRandomNumberGenerator()
        var allOK = true
        for length in [1, 3, 6, 7, 8, 13, 14, 100, 1000, 4096] {
            let raw = (0..<length).map { _ in UInt8.random(in: 0...255, using: &generator) }
            let id: Int32 = length % 2 == 0 ? -96_593_778 : 1_626_099_495
            let time: UInt64 = 0xFEDC_BA98_7654_3210 &+ UInt64(length)
            var encoded = [UInt8](repeating: 0, count: MxSpyEncodedSize(length))
            let size = raw.withUnsafeBufferPointer { r in
                encoded.withUnsafeMutableBufferPointer { MxSpyEncode(id, time, r.baseAddress, length, $0.baseAddress) }
            }
            let envelope = Array(encoded.prefix(size))
            let only7Bit = envelope.dropFirst().dropLast().allSatisfy { $0 < 0x80 }
            guard let decoded = SpyFeed.decode(envelope), only7Bit else { allOK = false; print("    length \(length): no decode"); continue }
            if decoded.destination != id || decoded.hostTime != time || decoded.bytes != raw {
                allOK = false
                print("    length \(length): mismatch")
            }
        }
        check(allOK, "random packets of 1 … 4096 bytes, negative and positive unique IDs, 64-bit times")
        check(SpyFeed.decode([0xF0, 0x43, 0x10, 0xF7]) == nil, "someone else's system exclusive is ignored")
    }

    // MARK: UMP

    static func umpTests() {
        section("Universal MIDI Packets → bytes")
        let size = 1024
        let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 8)
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: MIDIEventList.self, capacity: 1)
        var packet = MIDIEventListInit(list, ._1_0)
        var words: [UInt32] = [
            0x2090_3C64,                                  // note on ch 1, 60, 100
            0x10F8_0000,                                  // clock
            0x20E0_0040,                                  // pitch bend ch 1, LSB 0, MSB 64
            0x3016_4310, 0x4C00_7F01,                     // sysex start, 6 bytes: 43 10 4C 00 7F 01
            0x3032_0203, 0x0000_0000,                     // sysex end, 2 bytes: 02 03
            0x20C0_0500,                                  // program change 5
        ]
        packet = MIDIEventListAdd(list, size, packet, 0, words.count, &words)
        check(packet != nil, "event list built")
        var bytes: [UInt8] = []
        UMP.forEachPacket(in: UnsafePointer(list)) { _, b in bytes.append(contentsOf: b) }
        let expected: [UInt8] = [0x90, 0x3C, 0x64, 0xF8, 0xE0, 0x00, 0x40,
                                 0xF0, 0x43, 0x10, 0x4C, 0x00, 0x7F, 0x01, 0x02, 0x03, 0xF7, 0xC0, 0x05]
        check(bytes == expected, "note, clock, bend, two-part system exclusive and program change come back as bytes")
        if bytes != expected { print("    got " + bytes.map { String(format: "%02X", $0) }.joined(separator: " ")) }
    }

    // MARK: Text

    static func formatTests() {
        section("Message text")
        var f = MIDIFormatter(middleCOctave: 3)
        check(f.noteName(60) == "C3" && f.noteName(56) == "G#2" && f.noteName(0) == "C-2", "Logic Pro's note names (middle C is C3)")
        f.middleCOctave = 4
        check(f.noteName(60) == "C4" && f.noteName(127) == "G9", "middle C is C4")
        let bend = MIDIEvent(hostTime: 0, direction: .input, route: .direct, portID: 1, status: 0xE0, data1: 0, data2: 0x40, sysex: nil)
        check(f.data(bend) == "Value=8192 (+0)", "pitch bend centre")
        let cc = MIDIEvent(hostTime: 0, direction: .output, route: .spy, portID: 1, status: 0xB1, data1: 64, data2: 127, sysex: nil)
        check(f.data(cc) == "CC=64 Value=127  Sustain" && cc.channel == 2 && cc.kind == .controlChange, "sustain on channel 2")
        let sx = MIDIEvent(hostTime: 0, direction: .input, route: .direct, portID: 1, status: 0xF0, data1: 0, data2: 0,
                           sysex: [0xF0, 0x41, 0x10, 0x42, 0xF7])
        check(f.data(sx).hasPrefix("Length=5  Roland"), "system exclusive maker")
    }

    // MARK: Engine

    static func engineTests() {
        section("Engine on virtual ports")
        guard MIDIEngine.spyTestSourceName == "MxTest Spy Feed", MIDIEngine.thruTestTargetName == "MxTest Synth" else {
            check(false, "run with -MxSpyTestSource \"MxTest Spy Feed\" -MxThruTestTarget \"MxTest Synth\"")
            return
        }
        let engine = MIDIEngine()
        engine.start()
        check(engine.lastError == nil, "engine started (\(engine.lastError ?? "no error"))")

        var client = MIDIClientRef()
        MIDIClientCreateWithBlock("MxMidiTests" as CFString, &client, nil)
        var keyboard = MIDIEndpointRef()
        MIDISourceCreateWithProtocol(client, "MxTest Keyboard" as CFString, ._1_0, &keyboard)

        // The synth records what reaches it (the thru port forwards here).
        final class Box: @unchecked Sendable { var bytes: [UInt8] = []; let lock = NSLock() }
        let received = Box()
        var synth = MIDIEndpointRef()
        MIDIDestinationCreateWithProtocol(client, "MxTest Synth" as CFString, ._1_0, &synth) { list, _ in
            var got: [UInt8] = []
            UMP.forEachPacket(in: list) { _, b in got.append(contentsOf: b) }
            received.lock.withLock { received.bytes.append(contentsOf: got) }
        }
        var out = MIDIPortRef()
        MIDIOutputPortCreate(client, "MxMidiTests Out" as CFString, &out)
        pump(0.8)

        let keyboardID = MIDIProps.uniqueID(keyboard)
        let synthID = MIDIProps.uniqueID(synth)
        check(engine.ports[keyboardID]?.transport == .virtual, "the engine lists the keyboard as a virtual source")

        // IN
        func send(_ source: MIDIEndpointRef, _ bytes: [UInt8]) {
            withEventList(bytes) { MIDIReceivedEventList(source, $0) }
        }
        _ = engine.drain()
        send(keyboard, [0x90, 0x3C, 0x64, 0x80, 0x3C, 0x00, 0xB0, 0x01, 0x40, 0xD0, 0x20])
        pump(0.4)
        let inEvents = engine.drain().events.filter { $0.portID == keyboardID }
        check(inEvents.map(\.kind) == [.noteOn, .noteOff, .controlChange, .channelPressure]
              && inEvents.allSatisfy { $0.direction == .input && $0.route == .direct },
              "IN: note on, note off, mod wheel and pressure from the keyboard")

        // Thru (no spy yet, so the thru port logs)
        engine.thruEnabled = true
        pump(0.8)
        var thruPort = MIDIEndpointRef()
        for i in 0..<MIDIGetNumberOfDestinations() where MIDIProps.string(MIDIGetDestination(i), kMIDIPropertyName) == "MxMidiPRO ▸ MxTest Synth" {
            thruPort = MIDIGetDestination(i)
        }
        check(thruPort != 0, "thru port “MxMidiPRO ▸ MxTest Synth” exists")
        // Hardware destinations get thru ports too; the tests only ever send to the test target's.
        check(engine.thruPortNames.contains("MxMidiPRO ▸ MxTest Synth"),
              "thru ports: " + engine.thruPortNames.joined(separator: ", "))
        _ = engine.drain()
        withEventList([0x91, 0x40, 0x50]) { MIDISendEventList(out, thruPort, $0) }
        pump(0.5)
        let thruEvents = engine.drain().events.filter { $0.portID == synthID }
        check(thruEvents.count == 1 && thruEvents.first?.route == .thru && thruEvents.first?.direction == .output
              && thruEvents.first?.status == 0x91, "thru: logged as OUT to the synth")
        check(received.lock.withLock { received.bytes } == [0x91, 0x40, 0x50], "thru: forwarded to the synth unchanged")

        // Spy: the driver's own code, fed into a stand-in source.
        var feedSource = MIDIEndpointRef()
        MIDISourceCreateWithProtocol(client, "MxTest Spy Feed" as CFString, ._1_0, &feedSource)
        MxSpySetSource(feedSource)
        pump(0.8)
        check(engine.spySourceID == MIDIProps.uniqueID(feedSource), "the engine took the stand-in as the spy feed")
        check(engine.ports[MIDIProps.uniqueID(feedSource)] == nil, "the spy feed isn't listed as an ordinary source")

        _ = engine.drain()
        var big: [UInt8] = [0xF0, 0x43]
        big += (0..<9_997).map { UInt8($0 % 128) }
        big.append(0xF7)
        withPacketList([[0x92, 0x30, 0x7F], [0xB2, 0x07, 0x64], big, [0x82, 0x30, 0x00]]) {
            MxSpyForwardPacketList(synth, $0)
        }
        withPacketList([[0x93, 0x31, 0x33]]) { MxSpyForwardPacketList(thruPort, $0) }   // our own port: ignored
        pump(0.6)
        let spyEvents = engine.drain().events.filter { $0.route == .spy }
        check(spyEvents.map(\.kind) == [.noteOn, .controlChange, .sysex, .noteOff]
              && spyEvents.allSatisfy { $0.portID == synthID && $0.direction == .output },
              "spy: note, volume, a 10,000-byte system exclusive and note off, all OUT to the synth")
        check(spyEvents.first { $0.kind == .sysex }?.sysex == big, "spy: the system exclusive arrives byte for byte")
        check(!spyEvents.contains { $0.status == 0x93 }, "spy: traffic to MxMidiPRO's own thru port is left out")

        received.lock.withLock { received.bytes = [] }
        withEventList([0x94, 0x41, 0x51]) { MIDISendEventList(out, thruPort, $0) }
        pump(0.4)
        check(engine.drain().events.filter { $0.route == .thru }.isEmpty
              && received.lock.withLock { received.bytes } == [0x94, 0x41, 0x51],
              "with the spy live, the thru port forwards but leaves logging to the spy")

        MxSpySetSource(0)
        MIDIClientDispose(client)
    }

    static func withEventList(_ bytes: [UInt8], _ body: (UnsafePointer<MIDIEventList>) -> Void) {
        // MIDI 1.0 channel voice messages only, which is all the tests send this way.
        var words: [UInt32] = []
        var i = 0
        while i < bytes.count {
            let status = bytes[i]
            let length = MIDIEvent.length(ofStatus: status)
            let d1 = length > 1 ? UInt32(bytes[i + 1]) : 0
            let d2 = length > 2 ? UInt32(bytes[i + 2]) : 0
            words.append(0x2000_0000 | UInt32(status) << 16 | d1 << 8 | d2)
            i += length
        }
        let size = 4096
        let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 8)
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: MIDIEventList.self, capacity: 1)
        let packet = MIDIEventListInit(list, ._1_0)
        _ = MIDIEventListAdd(list, size, packet, 0, words.count, &words)
        body(UnsafePointer(list))
    }

    static func withPacketList(_ messages: [[UInt8]], _ body: (UnsafePointer<MIDIPacketList>) -> Void) {
        let size = 65_536
        let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 8)
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: MIDIPacketList.self, capacity: 1)
        var packet = MIDIPacketListInit(list)
        for message in messages {
            packet = MIDIPacketListAdd(list, size, packet, 0, message.count, message)
        }
        body(UnsafePointer(list))
    }
}
