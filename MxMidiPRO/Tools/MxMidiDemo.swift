// MxMidiDemo.swift — plays MIDI traffic on virtual ports so MxMidiPRO's screens can be tried without Logic Pro or
// hardware (Tools/build-tools.sh builds it).
//
//   IN   "MxTest Keyboard" (a virtual source): a melody with changing velocities, channel and poly pressure swells,
//        a mod-wheel sweep and pitch-bend wobbles.
//   OUT  what "Logic Pro" sends to "MxTest Synth" (a virtual destination): the melody a fifth up on channel 2,
//        volume, program changes, Yamaha system exclusive, and clock — all passed through the spy driver's own
//        code (MxSpyForwardPacketList) onto the stand-in feed "MxTest Spy Feed".
//
// Start MxMidiPRO with:  -MxSpyTestSource "MxTest Spy Feed" -InScope everything -OutScope everything
// then:                  mxmidi-demo 60        (seconds)

import CoreMIDI
import Foundation

@main
struct MxMidiDemo {
    enum Port { case keyboard, synth }
    struct Step { let time: Double; let port: Port; let bytes: [UInt8] }

    static func main() {
        let seconds = Double(CommandLine.arguments.dropFirst().first ?? "") ?? 30
        var client = MIDIClientRef()
        MIDIClientCreateWithBlock("MxMidiDemo" as CFString, &client, nil)
        var keyboard = MIDIEndpointRef(), feed = MIDIEndpointRef(), synth = MIDIEndpointRef()
        MIDISourceCreateWithProtocol(client, "MxTest Keyboard" as CFString, ._1_0, &keyboard)
        MIDISourceCreateWithProtocol(client, "MxTest Spy Feed" as CFString, ._1_0, &feed)
        MIDIDestinationCreateWithProtocol(client, "MxTest Synth" as CFString, ._1_0, &synth) { _, _ in }
        MxSpySetSource(feed)
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))

        let steps = score(seconds: seconds)
        print("Playing \(steps.count) messages over \(Int(seconds)) s: IN from MxTest Keyboard, OUT to MxTest Synth.")
        let start = Date()
        for step in steps {
            let wait = step.time - Date().timeIntervalSince(start)
            if wait > 0 { Thread.sleep(forTimeInterval: wait) }
            withPacketList(step.bytes) { list in
                switch step.port {
                case .keyboard: MIDIReceived(keyboard, list)
                case .synth: MxSpyForwardPacketList(synth, list)
                }
            }
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        MxSpySetSource(0)
        MIDIClientDispose(client)
        print("Done.")
    }

    static func score(seconds: Double) -> [Step] {
        var steps: [Step] = []
        let melody: [UInt8] = [60, 62, 64, 67, 69, 72, 69, 67, 64, 62]
        let beat = 0.30
        var k = 0
        var t = 0.2
        while t < seconds - 0.5 {
            let note = melody[k % melody.count]
            let velocity = UInt8(35 + Int(85 * abs(sin(Double(k) * 0.7))))
            let length = 0.22
            steps.append(Step(time: t, port: .keyboard, bytes: [0x90, note, velocity]))
            steps.append(Step(time: t + length, port: .keyboard, bytes: [0x80, note, 0]))
            steps.append(Step(time: t + 0.004, port: .synth, bytes: [0x91, note + 7, velocity]))
            steps.append(Step(time: t + length + 0.004, port: .synth, bytes: [0x81, note + 7, 0]))
            // A pressure swell under each note; every fourth note swells its poly pressure instead.
            let peak = Double(velocity) * 0.85
            var s = 0.0
            while s <= length {
                let shape = s < 0.09 ? s / 0.09 : max(0, 1 - (s - 0.09) / (length - 0.09))
                let value = UInt8(min(127, peak * shape))
                steps.append(Step(time: t + s, port: .keyboard,
                                  bytes: k % 4 == 3 ? [0xA0, note, value] : [0xD0, value]))
                s += 0.015
            }
            steps.append(Step(time: t + length + 0.01, port: .keyboard, bytes: k % 4 == 3 ? [0xA0, note, 0] : [0xD0, 0]))
            k += 1
            t += beat
        }
        // Mod wheel: a slow sweep; pitch bend: a one-second wobble every four seconds.
        var m = 0.1
        var lastCC: UInt8 = 255
        while m < seconds - 0.5 {
            let value = UInt8(63.5 + 63.5 * sin(m * 2 * .pi / 6))
            if value != lastCC { steps.append(Step(time: m, port: .keyboard, bytes: [0xB0, 0x01, value])); lastCC = value }
            let phase = m.truncatingRemainder(dividingBy: 4)
            if phase > 2 && phase < 3 {
                let bend = Int(8192 + 6000 * sin((phase - 2) * 2 * .pi * 3))
                steps.append(Step(time: m, port: .keyboard, bytes: [0xE0, UInt8(bend & 0x7F), UInt8(bend >> 7)]))
            } else if phase >= 3 && phase < 3.05 {
                steps.append(Step(time: m, port: .keyboard, bytes: [0xE0, 0x00, 0x40]))
            }
            m += 0.05
        }
        // "Logic Pro": volume, program changes, Yamaha parameter changes, and clock at 120 bpm.
        steps.append(Step(time: 0.1, port: .synth, bytes: [0xFA]))
        var c = 0.1
        while c < seconds - 0.5 {
            steps.append(Step(time: c, port: .synth, bytes: [0xF8]))
            c += 60.0 / 120.0 / 24.0
        }
        var u = 1.0
        var program: UInt8 = 0
        while u < seconds - 0.5 {
            steps.append(Step(time: u, port: .synth, bytes: [0xB1, 0x07, UInt8(70 + Int(u * 7) % 50)]))
            if Int(u) % 5 == 0 {
                steps.append(Step(time: u + 0.01, port: .synth, bytes: [0xC1, program]))
                program = (program + 1) % 128
            }
            if Int(u) % 3 == 0 {
                steps.append(Step(time: u + 0.02, port: .synth,
                                  bytes: [0xF0, 0x43, 0x10, 0x7F, 0x1C, 0x02, 0x10, 0x00, UInt8(Int(u) % 128), 0xF7]))
            }
            u += 1.0
        }
        steps.append(Step(time: seconds - 0.4, port: .synth, bytes: [0xFC]))
        return steps.sorted { $0.time < $1.time }
    }

    static func withPacketList(_ message: [UInt8], _ body: (UnsafePointer<MIDIPacketList>) -> Void) {
        let size = 1024
        let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 8)
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: MIDIPacketList.self, capacity: 1)
        let packet = MIDIPacketListInit(list)
        _ = MIDIPacketListAdd(list, size, packet, 0, message.count, message)
        body(UnsafePointer(list))
    }
}
