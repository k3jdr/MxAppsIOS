//
//  OverviewView.swift — MxModxUSB
//
//  The instrument at a glance: a dark panel like the MODX's own — model and firmware, the current Performance on
//  a display, the connection lamps and MIDI clock, the wheels, Super Knob and eight assignable knobs moving as you
//  play, the keyboard with each Part's key range — and below it cards for the Parts, the settings that matter most,
//  and the USB connection.
//

import SwiftUI

struct OverviewView: View {
    let model: ModxModel

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                InstrumentPanel(model: model)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 330), spacing: 16, alignment: .top)], spacing: 16) {
                    PartsCard(model: model)
                    KeyboardMIDICard(model: model)
                    SoundCard(model: model)
                    USBCard(model: model)
                }
            }
            .padding(18)
        }
    }
}

private struct InstrumentPanel: View {
    let model: ModxModel

    var body: some View {
        let live = model.live
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("YAMAHA").font(.system(size: 11, weight: .semibold)).tracking(3).foregroundStyle(.white.opacity(0.6))
                    Text(model.identity?.model ?? "MODX").font(.system(size: 40, weight: .heavy)).foregroundStyle(.white)
                    Text(model.identity.map { "Firmware \($0.firmware)" } ?? (model.connected ? "Reading…" : "Not connected"))
                        .font(.caption).foregroundStyle(.white.opacity(0.6))
                }
                .frame(width: 170, alignment: .leading)

                PerformanceDisplay(model: model)

                VStack(alignment: .leading, spacing: 7) {
                    lamp("USB", model.usb != nil)
                    lamp("MIDI  \(model.portNames.filter { !$0.isEmpty }.count) ports", model.connected)
                    lamp("Audio  \(model.audio.map { "\($0.inputChannels) in · \($0.outputChannels) out" } ?? "—")", model.audio != nil)
                    lamp(live.clockBPM.map { String(format: "Clock  %.1f BPM", $0) } ?? "Clock  —", live.clockBPM != nil, Modx.live)
                    lamp("Active Sensing", live.activeSensing, Modx.live)
                }
                .frame(width: 170, alignment: .leading)
            }

            HStack(alignment: .bottom, spacing: 14) {
                Wheel(label: "Pitch", fraction: Double(live.pitchBend) / 16383, centered: true)
                Wheel(label: "Mod", fraction: Double(live.controllers[1]) / 127)
                Dial(value: Int(live.controllers[Int(model.superKnobControl)]), label: "Super Knob", size: 54,
                     color: .purple, active: live.controllers[Int(model.superKnobControl)] > 0)
                Divider().frame(height: 70).overlay(Modx.panelLine)
                ForEach(0..<8, id: \.self) { knob in
                    let cc = model.knobControl(knob)
                    let liveValue = cc > 0 && cc < 128 ? live.controllers[Int(cc)] : 0
                    let stored = knob < model.common.knobValues.count ? Int(model.common.knobValues[knob]) : 0
                    let name = knob < model.common.knobNames.count && !model.common.knobNames[knob].isEmpty
                        ? model.common.knobNames[knob] : "Knob \(knob + 1)"
                    Dial(value: liveValue > 0 ? Int(liveValue) : stored, label: name, active: liveValue > 0)
                        .help("Assignable Knob \(knob + 1)" + (cc > 0 ? ", sends CC \(cc)" : ""))
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 6) {
                    lamp("Sustain", live.controllers[64] >= 64, Modx.live)
                    Text(live.notes.isEmpty ? " " : live.notes.sorted().map { ModxNames.note($0) }.joined(separator: " "))
                        .font(.caption.monospaced()).foregroundStyle(Modx.live).lineLimit(1).frame(width: 150, alignment: .trailing)
                    if live.lastVelocity > 0 {
                        Text("Velocity \(live.lastVelocity)").font(.caption2).foregroundStyle(.white.opacity(0.6))
                    }
                }
            }

            KeyboardView(keyCount: model.identity?.keyCount ?? 76, notes: live.notes, parts: model.parts)
        }
        .padding(18)
        .background(Modx.panel, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Modx.panelLine))
        .environment(\.colorScheme, .dark)
    }

    private func lamp(_ text: String, _ on: Bool, _ color: Color = .green) -> some View {
        HStack(spacing: 7) {
            Lamp(on: on, color: color)
            Text(text).font(.caption).foregroundStyle(.white.opacity(on ? 0.9 : 0.5))
        }
    }
}

private struct PerformanceDisplay: View {
    let model: ModxModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("PERFORMANCE").font(.system(size: 10, weight: .bold)).tracking(2).foregroundStyle(Modx.live.opacity(0.8))
            Text(model.common.name.isEmpty ? "—" : model.common.name)
                .font(.system(size: 30, weight: .semibold, design: .rounded)).foregroundStyle(.white)
                .lineLimit(1).minimumScaleFactor(0.6)
            HStack(spacing: 14) {
                badge("♩ \(model.common.tempo > 0 ? "\(model.common.tempo)" : "—")")
                badge("\(model.partsInUse.count) of 16 Parts")
                if let slot = model.currentSlot {
                    badge("\(slot.bankName) · #\(slot.number)")
                    badge("Live Set: \(model.liveSet?.bankName ?? "") › \(model.liveSet?.pageNames[slot.page] ?? "") › Slot \(slot.slot + 1)")
                } else if let bank = model.liveSet?.bankName, !bank.isEmpty {
                    badge("Live Set: \(bank)")
                }
            }
            HStack(spacing: 6) {
                ForEach(model.partsInUse) { part in
                    Text("\(part.number) \(part.category)")
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Modx.partColors[part.index % 16].opacity(0.85), in: Capsule())
                        .foregroundStyle(.black)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 118, alignment: .topLeading)
        .background(Modx.display, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Modx.live.opacity(0.25)))
    }

    private func badge(_ text: String) -> some View {
        Text(text).font(.callout.monospacedDigit()).foregroundStyle(.white.opacity(0.85))
    }
}

private struct PartsCard: View {
    let model: ModxModel

    var body: some View {
        Card(title: "Parts in the Performance", systemImage: "square.stack.3d.up") {
            if model.partsInUse.isEmpty {
                Text(model.partsLoaded ? "No Parts in use." : "Reading the Parts…").foregroundStyle(.secondary)
            }
            ForEach(model.partsInUse) { part in
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 2).fill(Modx.partColors[part.index % 16]).frame(width: 4, height: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(part.number)  \(part.name)").font(.callout.weight(.semibold))
                        Text("\(part.category) · \(typeText(part)) · \(part.noteRange)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        ProgressView(value: Double(part.volume), total: 127).frame(width: 70)
                        Text("vol \(part.volume) · pan \(ModxNames.pan(part.pan))").font(.caption2).foregroundStyle(.secondary)
                    }
                    if part.mute { Image(systemName: "speaker.slash.fill").foregroundStyle(.secondary).help("Muted") }
                    if !part.partSwitch { Image(systemName: "power").foregroundStyle(.secondary).help("Part switched off") }
                }
            }
        }
    }

    private func typeText(_ part: ModxPart) -> String {
        switch part.type {
        case .awm2: "AWM2, \(part.elementsOn) element\(part.elementsOn == 1 ? "" : "s")"
        case .drum: "Drum, \(part.elementsOn) keys"
        case .fmx: "FM-X"
        case .unknown: "reading…"
        }
    }
}

private struct KeyboardMIDICard: View {
    let model: ModxModel

    var body: some View {
        Card(title: "Keyboard & MIDI", systemImage: "pianokeys") {
            ForEach(["Transpose", "Octave Shift", "Velocity Curve", "Local Control", "MIDI IN/OUT", "MIDI I/O Mode",
                     "MIDI I/O Channel", "MIDI Clock Out", "MIDI Sync"], id: \.self) { name in
                ValueRow(name: name, value: model.systemValue(name))
            }
        }
    }
}

private struct SoundCard: View {
    let model: ModxModel

    var body: some View {
        Card(title: "Sound", systemImage: "speaker.wave.2") {
            ValueRow(name: "Tone Generator Volume", value: model.systemValue("Volume"))
            ValueRow(name: "Tune", value: model.systemValue("Tune"))
            ValueRow(name: "Note Shift", value: model.systemValue("Note Shift"))
            ValueRow(name: "Performance Volume", value: model.common.volume > 0 ? "\(model.common.volume)" : "—")
            ValueRow(name: "Reverb", value: model.common.reverb.isEmpty ? "—" : model.common.reverb)
            ValueRow(name: "Variation", value: model.common.variation.isEmpty ? "—" : model.common.variation)
            ValueRow(name: "Master Effect", value: model.common.masterEffect.isEmpty ? "—" : model.common.masterEffect)
            ValueRow(name: "USB Main Output Gain", value: model.systemValue("USB Main L&R Output Gain"))
        }
    }
}

private struct USBCard: View {
    let model: ModxModel

    var body: some View {
        Card(title: "Connection", systemImage: "cable.connector") {
            if let usb = model.usb {
                ValueRow(name: "USB", value: "\(USBDeviceInfo.bcd(usb.usbVersion)), \(usb.speedText)")
                ValueRow(name: "Vendor / Product", value: String(format: "%04X / %04X", usb.vendorID, usb.productID))
                ValueRow(name: "Interfaces", value: "\(Set(usb.interfaces.map(\.number)).count)")
            } else {
                Text("The MODX isn't on USB.").foregroundStyle(.secondary)
            }
            ForEach(ModxPort.allCases) { port in
                ValueRow(name: "MIDI \(port.title)", value: model.portNames[port.rawValue].isEmpty ? "—" : "\(model.live.counts[port.rawValue]) messages")
            }
            if let audio = model.audio {
                ValueRow(name: "Audio", value: "\(audio.inputChannels) in · \(audio.outputChannels) out · \(Int(audio.sampleRate)) Hz")
            }
        }
    }
}
