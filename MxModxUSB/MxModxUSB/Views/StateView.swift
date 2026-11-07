//
//  StateView.swift — MxModxUSB
//
//  Current State: what the MODX is doing now, drawn as its signal path — the keys (and MIDI Songs) into the Parts,
//  each Part through its insertion effects, volume and pan, then its dry signal and sends into the Variation and
//  Reverb and the main mix with the Master Effect, or straight out to USB — each line as thick as its level, lit and
//  moving while a Part plays. Below it: what explains the sound ("What you'll hear"), the MODX's USB audio as levels
//  (when asked to listen), and every value behind the drawing with its address.
//

import AppKit
import SwiftUI

struct StateView: View {
    let model: ModxModel
    @Bindable private var settings = ModxSettings.shared

    var body: some View {
        let path = model.signalPath
        ScrollView {
            VStack(spacing: 16) {
                SignalPanel(model: model, path: path, meter: model.meter)
                FindingsCard(path: path, connected: model.connected && model.partsLoaded)
                AudioCard(model: model, meter: model.meter, explain: settings.guidance == .full)
                SettingsCard(model: model, path: path)
            }
            .padding(18)
        }
    }
}

// MARK: The signal path

private struct SignalPanel: View {
    let model: ModxModel
    let path: ModxSignalPath
    let meter: ModxAudioMeter

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 18) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("NOW PLAYING").font(.system(size: 10, weight: .semibold)).tracking(2).foregroundStyle(Modx.live.opacity(0.8))
                    Text(model.common.name.isEmpty ? "—" : model.common.name).font(.title2.weight(.bold)).foregroundStyle(.white)
                }
                Text("Tempo \(model.common.tempo) BPM").foregroundStyle(.white.opacity(0.75))
                    .quickHelp("Tempo", "The Performance's tempo: tempo-synced effects (Tempo Cross Delay, Tempo Delay …) repeat in time with it.", symbol: "metronome")
                HStack(spacing: 6) {
                    Lamp(on: model.live.clockBPM != nil, color: Modx.live)
                    Text(model.live.clockBPM.map { String(format: "Clock %.1f BPM", $0) } ?? "No clock").foregroundStyle(.white.opacity(0.75))
                }
                HStack(spacing: 6) {
                    Lamp(on: model.live.activeSensing, color: Modx.live)
                    Text("Active Sensing").foregroundStyle(.white.opacity(0.75))
                }
                Spacer()
                if let read = model.lastRead {
                    Text("Read \(read.formatted(date: .omitted, time: .standard))").font(.caption).foregroundStyle(.white.opacity(0.5))
                }
                Button { model.readPerformanceAgain() } label: { Label("Read Again", systemImage: "arrow.clockwise") }
                    .disabled(!model.connected || model.loading)
                    .help("Read the Performance and its Parts again (changes made on the MODX's own screens show only when read)")
                    .quickHelp("Read Again", "Reads the current Performance and its Parts again. Changes made on the MODX's own screens aren't sent to the app, so they show here when read. A tutorial carries on.", symbol: "arrow.clockwise")
            }
            .font(.callout)

            if path.parts.isEmpty {
                Text(model.connected ? "Reading the Performance…" : "Connect the MODX by USB to see what it's doing.")
                    .foregroundStyle(.white.opacity(0.6)).frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ScrollView(.horizontal) {
                    FlowDiagram(path: path, meter: meter).padding(.vertical, 6)
                }
            }
        }
        .padding(18)
        .background(Modx.panel, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Modx.panelLine))
    }
}

/// Each node's frame, so the lines can be drawn between them.
private struct NodeBounds: PreferenceKey {
    static var defaultValue: [String: Anchor<CGRect>] { [:] }
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

private extension View {
    func flowNode(_ id: String) -> some View { anchorPreference(key: NodeBounds.self, value: .bounds) { [id: $0] } }
}

private struct FlowEdge: Identifiable {
    let from: String
    let to: String
    /// 0 … 1: the line's thickness.
    var level: Double
    var color: Color
    /// Sound is going along it now.
    var active = false
    /// It carries nothing at the moment (a Part muted, an effect switched off).
    var dimmed = false
    var id: String { from + ">" + to }
}

private struct FlowDiagram: View {
    let path: ModxSignalPath
    let meter: ModxAudioMeter

    static let variationColor = Color(red: 0.75, green: 0.55, blue: 1.0)
    static let reverbColor = Color(red: 0.45, green: 0.75, blue: 1.0)
    static let mixColor = Color(white: 0.85)

    private var usbOutputs: [ModxSignalPath.Part] {
        var seen: Set<UInt8> = []
        return path.parts.filter { $0.usbOutput && seen.insert($0.output).inserted }
    }

    var body: some View {
        let edges = Self.edges(path)
        HStack(alignment: .center, spacing: 46) {
            VStack(spacing: 14) {
                KeysNode(path: path).flowNode("keys")
                if !path.songChannels.isEmpty { SongNode(path: path).flowNode("song") }
            }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(path.parts) { part in PartNode(part: part).flowNode("part\(part.index)") }
            }
            VStack(spacing: 28) {
                EffectNode(title: "Variation", effect: path.variation, ret: path.variationReturn, pan: path.variationPan,
                           toReverb: path.variationToReverb, tempo: path.tempo, color: Self.variationColor,
                           active: edges.contains { $0.to == "var" && $0.active })
                    .flowNode("var")
                EffectNode(title: "Reverb", effect: path.reverb, ret: path.reverbReturn, pan: path.reverbPan, toReverb: nil,
                           tempo: path.tempo, color: Self.reverbColor, active: edges.contains { $0.to == "rev" && $0.active })
                    .flowNode("rev")
            }
            VStack(spacing: 22) {
                MasterNode(effect: path.masterEffect, active: path.mainSounding).flowNode("master")
                OutputNode(title: "Main L&R", detail: "The MODX's outputs, and USB Main L/R to the Mac",
                           channels: [0, 1], meter: meter, active: path.mainSounding)
                    .flowNode("main")
                ForEach(usbOutputs) { part in
                    OutputNode(title: part.outputName, detail: "Straight to the Mac: not in the main outputs",
                               channels: part.usbChannels, meter: meter,
                               active: path.parts.contains { $0.output == part.output && $0.sounding })
                        .flowNode("usb\(part.output)")
                }
            }
        }
        .padding(.horizontal, 4)
        .backgroundPreferenceValue(NodeBounds.self) { anchors in
            GeometryReader { g in
                let rects = anchors.mapValues { g[$0] }
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !edges.contains(where: \.active))) { timeline in
                    Canvas { context, _ in
                        Self.draw(edges, rects, time: timeline.date.timeIntervalSinceReferenceDate, in: &context)
                    }
                }
            }
        }
    }

    static func edges(_ path: ModxSignalPath) -> [FlowEdge] {
        var out: [FlowEdge] = []
        for part in path.parts {
            let color = Modx.partColors[part.index % Modx.partColors.count]
            let id = "part\(part.index)"
            if part.keys && part.switchOn {
                out.append(FlowEdge(from: "keys", to: id, level: 0.35, color: Modx.live,
                                    active: !part.heldNotes.isEmpty && !part.silent, dimmed: part.muted || path.localControl == false))
            }
            if part.fromSong {
                out.append(FlowEdge(from: "song", to: id, level: 0.35, color: Modx.live, active: !part.silent, dimmed: part.muted))
            }
            let vol = Double(part.volume) / 127
            if part.toMain {
                if part.dry > 0 {
                    out.append(FlowEdge(from: id, to: "master", level: vol * Double(part.dry) / 127, color: color,
                                        active: part.sounding, dimmed: part.silent))
                }
                if part.variationSend > 0 {
                    out.append(FlowEdge(from: id, to: "var", level: vol * Double(part.variationSend) / 127, color: color,
                                        active: part.sounding && path.variation.on, dimmed: part.silent || !path.variation.on))
                }
                if part.reverbSend > 0 {
                    out.append(FlowEdge(from: id, to: "rev", level: vol * Double(part.reverbSend) / 127, color: color,
                                        active: part.sounding && path.reverb.on, dimmed: part.silent || !path.reverb.on))
                }
            } else if part.usbOutput {
                out.append(FlowEdge(from: id, to: "usb\(part.output)", level: vol, color: color, active: part.sounding, dimmed: part.silent))
            }
        }
        let intoVariation = out.contains { $0.to == "var" && $0.active }
        let intoReverb = out.contains { $0.to == "rev" && $0.active }
        if path.variationToReverb > 0 {
            out.append(FlowEdge(from: "var", to: "rev", level: Double(path.variationToReverb) / 127, color: variationColor,
                                active: intoVariation && path.reverb.on, dimmed: !path.variation.on || !path.reverb.on))
        }
        if path.variationReturn > 0 {
            out.append(FlowEdge(from: "var", to: "master", level: Double(path.variationReturn) / 127, color: variationColor,
                                active: intoVariation, dimmed: !path.variation.on))
        }
        if path.reverbReturn > 0 {
            out.append(FlowEdge(from: "rev", to: "master", level: Double(path.reverbReturn) / 127, color: reverbColor,
                                active: intoReverb || (intoVariation && path.variationToReverb > 0), dimmed: !path.reverb.on))
        }
        out.append(FlowEdge(from: "master", to: "main", level: 0.8, color: mixColor, active: path.mainSounding))
        return out
    }

    static func draw(_ edges: [FlowEdge], _ rects: [String: CGRect], time: TimeInterval, in context: inout GraphicsContext) {
        for edge in edges.sorted(by: { !$0.active && $1.active }) {
            guard let a = rects[edge.from], let b = rects[edge.to] else { continue }
            var line = Path()
            if b.minX > a.maxX + 4 {
                let start = CGPoint(x: a.maxX, y: a.midY), end = CGPoint(x: b.minX, y: b.midY)
                let dx = (end.x - start.x) * 0.5
                line.move(to: start)
                line.addCurve(to: end, control1: CGPoint(x: start.x + dx, y: start.y), control2: CGPoint(x: end.x - dx, y: end.y))
            } else {   // the same column: from the bottom of one to the top of the next
                line.move(to: CGPoint(x: a.midX, y: a.maxY))
                line.addLine(to: CGPoint(x: b.midX, y: b.minY))
            }
            let width = 1.5 + 4.5 * min(max(edge.level, 0), 1)
            if edge.dimmed {
                context.stroke(line, with: .color(edge.color.opacity(0.22)), style: StrokeStyle(lineWidth: width, lineCap: .round, dash: [3, 5]))
            } else if edge.active {
                context.stroke(line, with: .color(edge.color.opacity(0.25)), style: StrokeStyle(lineWidth: width + 7, lineCap: .round))
                context.stroke(line, with: .color(edge.color), style: StrokeStyle(lineWidth: width, lineCap: .round))
                context.stroke(line, with: .color(.white.opacity(0.75)),
                               style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [2, 12], dashPhase: -CGFloat(time * 60)))
            } else {
                context.stroke(line, with: .color(edge.color.opacity(0.5)), style: StrokeStyle(lineWidth: width, lineCap: .round))
            }
        }
    }
}

/// A box in the drawing.
private struct NodeBox<Content: View>: View {
    var color: Color = Modx.live
    var active = false
    var dimmed = false
    var width: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) { content }
            .padding(9)
            .frame(width: width, alignment: .leading)
            .background(Color(white: active ? 0.2 : 0.155), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(active ? color : Color(white: 0.3), lineWidth: active ? 2 : 1))
            .shadow(color: active ? color.opacity(0.55) : .clear, radius: active ? 9 : 0)
            .opacity(dimmed ? 0.5 : 1)
    }
}

private struct Chip: View {
    let text: String
    var symbol: String? = nil
    var color: Color = .white.opacity(0.75)
    var off = false

    var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol) }
            Text(text).strikethrough(off)
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(off ? .white.opacity(0.35) : color)
        .padding(.horizontal, 5).padding(.vertical, 1.5)
        .background(.white.opacity(0.08), in: Capsule())
        .lineLimit(1)
    }
}

private struct KeysNode: View {
    let path: ModxSignalPath

    var body: some View {
        let local = path.localControl != false
        NodeBox(active: !path.heldNotes.isEmpty, dimmed: !local, width: 150) {
            Label("Keyboard", systemImage: "pianokeys").font(.callout.weight(.semibold)).foregroundStyle(.white)
            Text(path.localControl == nil ? "Local Control —" : "Local Control \(local ? "On" : "Off")")
                .font(.caption).foregroundStyle(local ? .white.opacity(0.6) : .orange)
            Text(path.heldNotes.isEmpty ? "No keys held" : path.heldNotes.map { ModxNames.note($0) }.joined(separator: " "))
                .font(.caption.monospaced()).foregroundStyle(path.heldNotes.isEmpty ? .white.opacity(0.4) : Modx.live).lineLimit(2)
        }
        .quickHelp("Keyboard", "The keys held now, as the MODX sends them. With Local Control on, the keys play every Part that has Keyboard Control on, within its note and velocity limits; off, they play nothing on the MODX itself.", symbol: "pianokeys")
    }
}

private struct SongNode: View {
    let path: ModxSignalPath

    var body: some View {
        NodeBox(active: true, width: 150) {
            Label("MIDI Songs", systemImage: "music.note.list").font(.callout.weight(.semibold)).foregroundStyle(.white)
            Text("Playing channel\(path.songChannels.count == 1 ? "" : "s") \(path.songChannels.sorted().map { String($0 + 1) }.joined(separator: ", "))")
                .font(.caption).foregroundStyle(.white.opacity(0.6))
        }
        .quickHelp("MIDI Songs", "The MIDI Songs page is playing on the MODX: each track's channel plays the Part of the same number (MIDI I/O Mode Multi).", symbol: "music.note.list")
    }
}

private struct PartNode: View {
    let part: ModxSignalPath.Part

    var body: some View {
        let color = Modx.partColors[part.index % Modx.partColors.count]
        NodeBox(color: color, active: part.sounding, dimmed: part.silent, width: 272) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 4, height: 16)
                Text("\(part.number)").font(.callout.weight(.bold).monospacedDigit()).foregroundStyle(.white)
                Text(part.name).font(.callout.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
                Spacer(minLength: 4)
                Text(part.type).font(.caption2).foregroundStyle(.white.opacity(0.5))
            }
            HStack(spacing: 4) {
                insertion("A", part.insertionA)
                if !part.insertionA.isNone || !part.insertionB.isNone {
                    Text(part.insertionConnection == "Parallel" ? "‖" : "→").font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
                }
                insertion("B", part.insertionB)
            }
            HStack(spacing: 4) {
                Chip(text: "Vol \(part.volume)")
                Chip(text: "Pan \(ModxSignalPath.pan(part.pan))")
                if part.toMain {
                    Chip(text: "Dry \(part.dry)")
                    Chip(text: "Var \(part.variationSend)", color: part.variationSend > 0 ? FlowDiagram.variationColor : .white.opacity(0.5))
                    Chip(text: "Rev \(part.reverbSend)", color: part.reverbSend > 0 ? FlowDiagram.reverbColor : .white.opacity(0.5))
                } else {
                    Chip(text: part.outputName, symbol: "arrow.right.to.line", color: .orange)
                }
            }
            HStack(spacing: 6) {
                state
                Spacer(minLength: 0)
                if part.arp { Chip(text: "Arp", symbol: "circle.grid.cross") }
                if part.motionSeq { Chip(text: "MS", color: .white.opacity(0.5)) }
            }
        }
        .quickHelp("Part \(part.number) \(part.name)", detail, symbol: "square.stack.3d.up")
    }

    @ViewBuilder private func insertion(_ slot: String, _ effect: ModxSignalPath.Effect) -> some View {
        if effect.isNone {
            Chip(text: "Ins \(slot): none", color: .white.opacity(0.4))
        } else {
            Chip(text: "\(slot) \(effect.name)", symbol: effect.kind == .repeats ? "repeat" : nil,
                 color: effect.kind == .repeats ? .orange : .white.opacity(0.8), off: !effect.on)
        }
    }

    @ViewBuilder private var state: some View {
        if !part.switchOn {
            Text("Switched off").font(.caption).foregroundStyle(.orange)
        } else if part.muted {
            Text(part.mutedToHearOne ? "Muted (Hear only this Part)" : "Muted").font(.caption).foregroundStyle(.orange)
        } else if part.output == 125 {
            Text("Output Off").font(.caption).foregroundStyle(.orange)
        } else if !part.heldNotes.isEmpty {
            Text(part.heldNotes.map { ModxNames.note($0) }.joined(separator: " ")).font(.caption.monospaced()).foregroundStyle(Modx.live).lineLimit(1)
        } else if part.fromSong {
            Text("Playing the song").font(.caption).foregroundStyle(Modx.live)
        } else {
            Text(part.keys ? "Keys \(ModxNames.note(part.noteLow)) – \(ModxNames.note(part.noteHigh))" : "Keyboard Control off")
                .font(.caption).foregroundStyle(.white.opacity(0.45))
        }
    }

    private var detail: String {
        var lines = ["\(part.type) Part. Insertion A \(part.insertionA.name)\(part.insertionA.on ? "" : " (off)"), Insertion B \(part.insertionB.name)\(part.insertionB.on ? "" : " (off)"), \(part.insertionConnection)."]
        lines.append("Volume \(part.volume), pan \(ModxSignalPath.pan(part.pan)).")
        if part.toMain {
            lines.append("To the main mix at dry level \(part.dry), to the Variation at \(part.variationSend) and the Reverb at \(part.reverbSend).")
        } else {
            lines.append("Output \(part.outputName): it skips the System effects and the main mix.")
        }
        lines.append(part.keys ? "The keys play it from \(ModxNames.note(part.noteLow)) to \(ModxNames.note(part.noteHigh)), velocity \(part.velocityLow)–\(part.velocityHigh)." : "Keyboard Control is off: only MIDI plays it.")
        return lines.joined(separator: " ")
    }
}

private struct EffectNode: View {
    let title: String
    let effect: ModxSignalPath.Effect
    let ret: Int
    let pan: Int
    let toReverb: Int?
    let tempo: Int
    let color: Color
    let active: Bool

    var body: some View {
        NodeBox(color: color, active: active, dimmed: !effect.on || effect.isNone, width: 196) {
            HStack {
                Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(1.5).foregroundStyle(color)
                Spacer()
                if !effect.on { Text("Off").font(.caption2.weight(.semibold)).foregroundStyle(.orange) }
            }
            Text(effect.name).font(.callout.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
            HStack(spacing: 4) {
                Chip(text: "Return \(ret)")
                Chip(text: "Pan \(ModxSignalPath.pan(pan))")
                if let toReverb { Chip(text: "→ Rev \(toReverb)") }
            }
            if effect.kind == .repeats {
                Chip(text: effect.followsTempo ? "Repeats in time · \(tempo) BPM" : "Repeats notes", symbol: "repeat", color: .orange)
            }
        }
        .quickHelp("\(title): \(effect.name)", "A System effect, shared by every Part that sends to it (the Parts' \(title) Send). Its return (\(ret)) is how much of it goes into the main mix\(effect.on ? "" : "; it's switched off now, so the sends do nothing")." + (effect.kind == .repeats ? " A delay: it plays what it's sent again, as echoes." : ""), symbol: "sparkles")
    }
}

private struct MasterNode: View {
    let effect: ModxSignalPath.Effect
    let active: Bool

    var body: some View {
        NodeBox(color: FlowDiagram.mixColor, active: active, width: 186) {
            Text("MAIN MIX").font(.system(size: 10, weight: .semibold)).tracking(1.5).foregroundStyle(.white.opacity(0.7))
            Text("Master Effect").font(.caption).foregroundStyle(.white.opacity(0.55))
            Text(effect.name).font(.callout.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
            Text("then Master EQ").font(.caption).foregroundStyle(.white.opacity(0.45))
        }
        .quickHelp("Main mix", "The Parts' dry signals and the Variation and Reverb returns, mixed, through the Master Effect (\(effect.name)) and the Master EQ to the main outputs.", symbol: "slider.horizontal.3")
    }
}

private struct OutputNode: View {
    let title: String
    let detail: String
    let channels: [Int]
    let meter: ModxAudioMeter
    let active: Bool

    var body: some View {
        NodeBox(color: .green, active: active || (meter.level(channels)?.rms ?? ModxAudioMeter.floor) > -50, width: 186) {
            Label(title, systemImage: "speaker.wave.2").font(.callout.weight(.semibold)).foregroundStyle(.white)
            Text(detail).font(.caption).foregroundStyle(.white.opacity(0.55)).fixedSize(horizontal: false, vertical: true)
            if meter.running {
                ForEach(channels.filter { $0 < meter.channels.count }, id: \.self) { c in
                    LevelBar(channel: meter.channels[c])
                }
            }
        }
        .quickHelp(title, detail + ". With Listen on (below), the bars show what the MODX sends the Mac on these USB channels.", symbol: "speaker.wave.2")
    }
}

/// A horizontal level: RMS filled, peak and hold marks, −60 … 0 dBFS.
private struct LevelBar: View {
    let channel: ModxAudioMeter.Channel

    var body: some View {
        HStack(spacing: 5) {
            Canvas { context, size in
                func x(_ db: Float) -> CGFloat { size.width * CGFloat(min(max((db + 60) / 60, 0), 1)) }
                context.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 2), with: .color(.white.opacity(0.1)))
                context.fill(Path(roundedRect: CGRect(x: 0, y: 0, width: x(channel.rms), height: size.height), cornerRadius: 2),
                             with: .linearGradient(Gradient(colors: [.green, .yellow, .red]), startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0)))
                context.fill(Path(CGRect(x: x(channel.peak) - 1, y: 0, width: 2, height: size.height)), with: .color(.white.opacity(0.8)))
                context.fill(Path(CGRect(x: x(channel.hold) - 1, y: 0, width: 2, height: size.height)), with: .color(.red.opacity(0.9)))
            }
            .frame(height: 6)
            Text(channel.peak > ModxAudioMeter.floor + 1 ? String(format: "%.0f", channel.peak) : "–∞")
                .font(.system(size: 9).monospacedDigit()).foregroundStyle(.white.opacity(0.6)).frame(width: 22, alignment: .trailing)
        }
    }
}

// MARK: What you'll hear

private struct FindingsCard: View {
    let path: ModxSignalPath
    let connected: Bool

    var body: some View {
        Card(title: "What You'll Hear", systemImage: "ear") {
            let findings = path.findings
            if !connected {
                Text("Once the MODX is read, this lists what explains its sound: echoes, Parts switched off or muted, Parts only the Mac hears, Local Control.")
                    .foregroundStyle(.secondary)
            } else if findings.isEmpty {
                Text("Nothing unusual.").foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(findings) { finding in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: finding.symbol).foregroundStyle(color(finding.level)).frame(width: 18)
                            Text(finding.text).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        }
                    }
                }
            }
        }
    }

    private func color(_ level: ModxSignalPath.Finding.Level) -> Color {
        switch level {
        case .warning: .red
        case .notice: .orange
        case .info: .secondary
        }
    }
}

// MARK: The MODX's USB audio

private struct AudioCard: View {
    let model: ModxModel
    let meter: ModxAudioMeter
    let explain: Bool

    var body: some View {
        Card(title: "The MODX's USB Audio", systemImage: "waveform") {
            if explain {
                Text("What the MODX sends the Mac over USB: USB Main L/R is its main mix after every effect — what its outputs play — and USB 1–8 are Parts whose Output goes straight to USB. Listening only measures the levels; nothing is recorded or played. Below the meters, the main mix over the last 6 seconds: an echo shows as repeats.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                if meter.running {
                    Button { meter.stop() } label: { Label("Stop Listening", systemImage: "stop.fill") }
                } else {
                    Button { Task { await meter.start(device: model.audio) } } label: { Label("Listen to the MODX", systemImage: "ear") }
                        .disabled(meter.starting || model.audio == nil)
                }
                if meter.running {
                    Text("\(meter.channels.count) channels at \(Int(meter.sampleRate)) Hz").font(.caption).foregroundStyle(.secondary)
                } else if model.audio == nil {
                    Text("The MODX's USB audio isn't on the Mac.").font(.caption).foregroundStyle(.secondary)
                }
                if let problem = meter.problem {
                    Text(problem).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    if problem.contains("Privacy") {
                        Button("Open Privacy Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }
            }
            .quickHelp("Listen to the MODX", "Opens the MODX's USB audio input on the Mac and shows its levels. macOS asks once whether MxModxUSB may use audio inputs. Nothing is recorded, played or sent to the MODX.", symbol: "ear")
            if meter.running {
                HStack(alignment: .bottom, spacing: 10) {
                    ForEach(meter.channels) { channel in
                        VStack(spacing: 4) {
                            VerticalMeter(channel: channel).frame(width: 14, height: 110)
                            Text(channel.name.replacingOccurrences(of: "USB ", with: ""))
                                .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1).frame(width: 46)
                            Text(channel.peak > ModxAudioMeter.floor + 1 ? String(format: "%.0f dB", channel.peak) : "–∞")
                                .font(.system(size: 9).monospacedDigit()).foregroundStyle(.tertiary)
                        }
                    }
                }
                HistoryStrip(history: meter.history).frame(height: 96)
            }
        }
    }
}

private struct VerticalMeter: View {
    let channel: ModxAudioMeter.Channel

    var body: some View {
        Canvas { context, size in
            func y(_ db: Float) -> CGFloat { size.height * (1 - CGFloat(min(max((db + 60) / 60, 0), 1))) }
            context.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 3), with: .color(.primary.opacity(0.1)))
            let top = y(channel.rms)
            context.fill(Path(roundedRect: CGRect(x: 0, y: top, width: size.width, height: size.height - top), cornerRadius: 3),
                         with: .linearGradient(Gradient(colors: [.red, .yellow, .green, .green]),
                                               startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            context.fill(Path(CGRect(x: 0, y: y(channel.peak) - 1, width: size.width, height: 2)), with: .color(.primary.opacity(0.7)))
            context.fill(Path(CGRect(x: 0, y: y(channel.hold) - 1, width: size.width, height: 2)), with: .color(.red))
        }
    }
}

/// The main mix's level over the last 6 seconds, newest at the right.
private struct HistoryStrip: View {
    let history: [Float]

    var body: some View {
        Canvas { context, size in
            func y(_ db: Float) -> CGFloat { size.height * (1 - CGFloat(min(max((db + 60) / 60, 0), 1))) }
            context.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 6), with: .color(.primary.opacity(0.06)))
            for db: Float in [-48, -36, -24, -12] {
                context.stroke(Path { $0.move(to: CGPoint(x: 0, y: y(db))); $0.addLine(to: CGPoint(x: size.width, y: y(db))) },
                               with: .color(.primary.opacity(0.08)), lineWidth: 1)
                context.draw(Text("\(Int(db)) dB").font(.system(size: 8)).foregroundStyle(.tertiary),
                             at: CGPoint(x: 4, y: y(db) - 6), anchor: .leading)
            }
            for s in 1...5 {
                let x = size.width * (1 - CGFloat(s) / CGFloat(ModxAudioMeter.historySeconds))
                context.stroke(Path { $0.move(to: CGPoint(x: x, y: 0)); $0.addLine(to: CGPoint(x: x, y: size.height)) },
                               with: .color(.primary.opacity(0.06)), lineWidth: 1)
                context.draw(Text("−\(s) s").font(.system(size: 8)).foregroundStyle(.tertiary), at: CGPoint(x: x + 3, y: size.height - 7), anchor: .leading)
            }
            guard history.count > 1 else { return }
            let step = size.width / CGFloat(history.count - 1)
            var area = Path()
            area.move(to: CGPoint(x: 0, y: size.height))
            for (i, db) in history.enumerated() { area.addLine(to: CGPoint(x: CGFloat(i) * step, y: y(db))) }
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.closeSubpath()
            context.fill(area, with: .linearGradient(Gradient(colors: [Modx.live.opacity(0.7), Modx.live.opacity(0.1)]),
                                                     startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
        }
        .quickHelp("The main mix over time", "USB Main L/R (the louder side) every 20 ms for the last 6 seconds, −60 to 0 dBFS. A note played into a delay shows as a row of smaller bumps after it.", symbol: "waveform")
    }
}

// MARK: The values behind it

private struct SettingsCard: View {
    let model: ModxModel
    let path: ModxSignalPath

    var body: some View {
        Card(title: "The Settings Behind It", systemImage: "tablecells") {
            Text("As read from the MODX. Part settings are at 31 0p xx (p = Part − 1) unless shown; insertion effects at 31 2p 00 and 31 3p 00, the Part's arpeggio at 31 6p 00.")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                    GridRow {
                        ForEach(Self.columns, id: \.0) { column in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(column.0).font(.caption.weight(.semibold))
                                Text(column.1).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                            }
                        }
                    }
                    Divider()
                    ForEach(path.parts) { part in
                        GridRow {
                            ForEach(Array(Self.values(part).enumerated()), id: \.offset) { _, value in
                                Text(value).font(.callout.monospacedDigit()).lineLimit(1).textSelection(.enabled)
                            }
                        }
                    }
                }
                .padding(.bottom, 6)
            }
            Divider()
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                GridRow {
                    Text("Variation").font(.callout.weight(.semibold))
                    Text("30 42 00").font(.caption.monospaced()).foregroundStyle(.tertiary)
                    Text(path.variation.name)
                    Text("Return \(path.variationReturn) (44)")
                    Text("Pan \(ModxSignalPath.pan(path.variationPan)) (45)")
                    Text("To Reverb \(path.variationToReverb) (46)")
                    Text("Switch \(path.variation.on ? "On" : "Off") (47)")
                }
                GridRow {
                    Text("Reverb").font(.callout.weight(.semibold))
                    Text("30 41 00").font(.caption.monospaced()).foregroundStyle(.tertiary)
                    Text(path.reverb.name)
                    Text("Return \(path.reverbReturn) (44)")
                    Text("Pan \(ModxSignalPath.pan(path.reverbPan)) (45)")
                    Text("")
                    Text("Switch \(path.reverb.on ? "On" : "Off") (46)")
                }
                GridRow {
                    Text("Master Effect").font(.callout.weight(.semibold))
                    Text("30 46 00").font(.caption.monospaced()).foregroundStyle(.tertiary)
                    Text(path.masterEffect.name)
                }
                GridRow {
                    Text("System").font(.callout.weight(.semibold))
                    Text("00 00 00").font(.caption.monospaced()).foregroundStyle(.tertiary)
                    Text(path.localControl.map { "Local Control \($0 ? "On" : "Off") (09)" } ?? "Local Control —")
                    Text(path.singleChannel.map { "MIDI I/O Single, ch \($0 + 1) (30, 31)" } ?? "MIDI I/O Multi (30)")
                }
            }
            .font(.callout)
            .textSelection(.enabled)
        }
    }

    static let columns: [(String, String)] = [
        ("Part", ""), ("Switch", "16"), ("Keys", "17"), ("Mute", "18"), ("Notes", "1E–1F"), ("Velocity", "1C–1D"),
        ("Volume", "24"), ("Pan", "25"), ("Insertion", "26"), ("Connection", "3B"), ("Insertion A", "31 2p 00"),
        ("Insertion B", "31 3p 00"), ("Dry", "2C"), ("Reverb", "29"), ("Variation", "2A"), ("Output", "3F"),
        ("Arp", "31 6p 00"), ("Motion Seq", "74"),
    ]

    static func values(_ p: ModxSignalPath.Part) -> [String] {
        func onOff(_ on: Bool) -> String { on ? "On" : "Off" }
        let ins = [p.insertionA.on ? "A on" : "A off", p.insertionB.on ? "B on" : "B off"].joined(separator: ", ")
        return [
            "\(p.number) \(p.name)", onOff(p.switchOn), onOff(p.keys), onOff(p.muted),
            "\(ModxNames.note(p.noteLow)) – \(ModxNames.note(p.noteHigh))", "\(p.velocityLow) – \(p.velocityHigh)",
            "\(p.volume)", ModxSignalPath.pan(p.pan), ins, p.insertionConnection, p.insertionA.name, p.insertionB.name,
            "\(p.dry)", "\(p.reverbSend)", "\(p.variationSend)", p.outputName, onOff(p.arp), onOff(p.motionSeq),
        ]
    }
}
