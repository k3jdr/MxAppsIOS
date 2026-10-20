//
//  StrumPatternEditor.swift
//  MxNoteONE
//
//  Making a strumming pattern: a bar's steps on a grid (beats, eighths or sixteenths) counted "1 & 2 &" — click a
//  step for the stroke the hand makes there (down on the beat, up between), again to hold, again for a rest;
//  right-click for any stroke (muted, bass note) or an accent, ⌥-click to accent. Or pick a preset, or type the
//  steps ("D-DU-UDU"). Play tries it on the bar's chord; it goes on the bar (or the bars selected), every bar, or a
//  new rhythm guitar staff.
//

import AppKit
import SwiftUI

@MainActor
enum StrumPatternEditor {
    enum Target: Hashable { case bars, every, newStaff }

    static func edit(patterns: [StrumPattern], initial: String, beats: Int, beatUnit: Int, barLabel: String, target: Target, chord: String,
                     play: @escaping (String) -> Void, in window: NSWindow?, done: @escaping (String, Target) -> Void) {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "Strumming Pattern"
        func finish(_ result: (String, Target)?) {
            if ScorePlayer.shared.isPlaying { ScorePlayer.shared.stop() }
            if let parent = panel.sheetParent { parent.endSheet(panel) } else { panel.close() }
            if let result { done(result.0, result.1) }
        }
        panel.contentView = NSHostingView(rootView: StrumPatternEditorView(patterns: patterns, initial: initial, beats: beats, beatUnit: beatUnit,
                                                                           barLabel: barLabel, target: target, chord: chord, play: play, finish: finish))
        if let window { window.beginSheet(panel) } else { panel.center(); panel.makeKeyAndOrderFront(nil) }
    }
}

struct StrumPatternEditorView: View {
    let patterns: [StrumPattern]
    let beats: Int
    let beatUnit: Int
    let barLabel: String
    let chord: String
    let play: (String) -> Void
    let finish: ((String, StrumPatternEditor.Target)?) -> Void
    @State private var cells: [StrumCell]
    @State private var text: String
    @State private var target: StrumPatternEditor.Target

    init(patterns: [StrumPattern], initial: String, beats: Int, beatUnit: Int, barLabel: String, target: StrumPatternEditor.Target, chord: String,
         play: @escaping (String) -> Void, finish: @escaping ((String, StrumPatternEditor.Target)?) -> Void) {
        self.patterns = patterns
        self.beats = beats
        self.beatUnit = beatUnit
        self.barLabel = barLabel
        self.chord = chord
        self.play = play
        self.finish = finish
        let start = StrumPattern.cells(initial) ?? [StrumCell(kind: "D")]
        _cells = State(initialValue: start)
        _target = State(initialValue: target)
        _text = State(initialValue: Self.written(start, beats: beats, beatUnit: beatUnit))
    }

    private var length: Double { Double(beats) * 4 / Double(beatUnit) }
    private var compound: Bool { StrumPattern.compound(beats: beats, unit: beatUnit) }
    private var beatLength: Double { compound ? 1.5 : 4 / Double(beatUnit) }
    private var step: Double { length / Double(max(1, cells.count)) }

    static func written(_ cells: [StrumCell], beats: Int, beatUnit: Int) -> String {
        let length = Double(beats) * 4 / Double(beatUnit)
        let beat = StrumPattern.compound(beats: beats, unit: beatUnit) ? 1.5 : 4 / Double(beatUnit)
        return StrumPattern.text(cells, perBeat: Int((beat / (length / Double(max(1, cells.count)))).rounded()))
    }

    /// The grids a bar can be cut into: the beat, eighths, sixteenths.
    private var grids: [(String, Double)] {
        let all: [(String, Double)] = compound ? [("Beats", 1.5), ("Eighths", 0.5), ("Sixteenths", 0.25)]
            : [("Beats", beatLength), ("Eighths", 0.5), ("Sixteenths", 0.25)]
        var seen = Set<Double>()
        return all.filter { g in
            let n = length / g.1
            return g.1 <= beatLength + 1e-9 && abs(n - n.rounded()) < 1e-9 && n <= 32 && seen.insert(g.1).inserted
        }
    }

    /// The count over a step: the beat's number, "&" halfway, "e" and "a" between (in 6/8, the eighths' numbers).
    private func count(_ k: Int) -> String {
        let t = Double(k) * step
        if compound {
            let eighth = t / 0.5
            if abs(eighth - eighth.rounded()) < 1e-9 { return "\(Int(eighth.rounded()) + 1)" }
            return "&"
        }
        let b = t / beatLength, into = b - b.rounded(.down)
        if abs(into) < 1e-9 { return "\(Int(b.rounded(.down)) + 1)" }
        if abs(into - 0.5) < 1e-9 { return "&" }
        return abs(into - 0.25) < 1e-9 ? "e" : "a"
    }

    /// The stroke the hand makes at a step: down on the beat (and every other step after it), up between.
    private func natural(_ k: Int) -> Character {
        guard step < beatLength - 1e-9 else { return "D" }
        let t = Double(k) * step
        let into = t - (t / beatLength + 1e-9).rounded(.down) * beatLength
        return Int((into / step).rounded()) % 2 == 0 ? "D" : "U"
    }

    private func symbol(_ c: StrumCell) -> String {
        switch c.kind {
        case "D": "↓"
        case "U": "↑"
        case "X": "✕"
        case "B": "B"
        case "-": "–"
        default: "·"
        }
    }

    private func set(_ new: [StrumCell]) {
        cells = new
        text = Self.written(new, beats: beats, beatUnit: beatUnit)
    }

    /// Click: the natural stroke → hold → rest → the stroke again.
    private func click(_ k: Int) {
        var c = cells
        if NSEvent.modifierFlags.contains(.option) {
            guard c[k].isStroke else { return NSSound.beep() }
            c[k].accent.toggle()
        } else if c[k].isStroke {
            c[k] = StrumCell(kind: "-")
        } else if c[k].kind == "-" {
            c[k] = StrumCell(kind: ".")
        } else {
            c[k] = StrumCell(kind: natural(k))
        }
        set(c)
    }

    /// Another grid: the strokes where they fall on it.
    private func regrid(_ newStep: Double) {
        let fine = StrumPattern.sixteenths(cells, length: length)
        let every = max(1, Int((newStep / 0.25).rounded()))
        let n = Int((length / newStep).rounded())
        var out: [StrumCell] = []
        for k in 0..<n {
            let group = fine[min(fine.count - 1, k * every)..<min(fine.count, (k + 1) * every)]
            out.append(group.first { $0.isStroke } ?? group.first ?? StrumCell(kind: "-"))
        }
        set(out)
    }

    private var valid: Bool {
        guard let parsed = StrumPattern.cells(text) else { return false }
        var probe = ScoreData()
        probe.beats = beats
        probe.beatUnit = beatUnit
        return probe.strumBar(parsed, symbols: []) != nil
    }

    var body: some View {
        let width = min(34, 560 / CGFloat(max(1, cells.count)) - 4)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(beats)/\(beatUnit) — tried on \(chord)").font(.headline)
                Spacer()
                Menu("Presets") {
                    ForEach(patterns) { p in
                        Button("\(p.name)   \(p.display)") { if let c = StrumPattern.cells(p.steps) { set(c) } }
                    }
                }
                .frame(width: 120)
                Picker("", selection: Binding(get: { grids.min(by: { abs($0.1 - step) < abs($1.1 - step) })?.1 ?? step }, set: { regrid($0) })) {
                    ForEach(grids, id: \.1) { name, value in Text(name).tag(value) }
                }
                .pickerStyle(.segmented)
                .frame(width: 230)
            }
            HStack(spacing: 4) {
                ForEach(Array(cells.enumerated()), id: \.offset) { k, c in
                    VStack(spacing: 3) {
                        Text(count(k)).font(.caption2.weight(abs((Double(k) * step / beatLength) - (Double(k) * step / beatLength).rounded()) < 1e-9 ? .bold : .regular))
                            .foregroundStyle(.secondary)
                        Button { click(k) } label: {
                            VStack(spacing: 0) {
                                Text(c.accent ? ">" : " ").font(.system(size: 10, weight: .bold)).foregroundStyle(.orange)
                                Text(symbol(c)).font(.system(size: 20, weight: c.isStroke ? .semibold : .regular))
                                    .foregroundStyle(c.isStroke ? Color.primary : Color.secondary)
                            }
                            .frame(width: width, height: 50)
                            .background(RoundedRectangle(cornerRadius: 6).fill(c.isStroke ? Color.accentColor.opacity(0.18) : Color.gray.opacity(0.08)))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.35)))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("strum-step-\(k)")
                        .accessibilityValue(String(c.kind) + (c.accent ? " accented" : ""))
                        .contextMenu {
                            Button("↓  Down") { var x = cells; x[k] = StrumCell(kind: "D", accent: x[k].accent); set(x) }
                            Button("↑  Up") { var x = cells; x[k] = StrumCell(kind: "U", accent: x[k].accent); set(x) }
                            Button("✕  Muted") { var x = cells; x[k] = StrumCell(kind: "X", accent: x[k].accent); set(x) }
                            Button("B  Bass Note") { var x = cells; x[k] = StrumCell(kind: "B", accent: x[k].accent); set(x) }
                            Button("–  Hold") { var x = cells; x[k] = StrumCell(kind: "-"); set(x) }
                            Button("·  Rest") { var x = cells; x[k] = StrumCell(kind: "."); set(x) }
                            Divider()
                            Button(c.accent ? "No Accent" : "Accent  >") { var x = cells; if x[k].isStroke { x[k].accent.toggle(); set(x) } }
                        }
                    }
                }
            }
            HStack {
                TextField("Steps", text: $text)
                    .font(.system(.body, design: .monospaced))
                    .accessibilityIdentifier("strum-steps")
                    .onChange(of: text) { _, new in
                        if let c = StrumPattern.cells(new), valid, c != cells { cells = c }
                    }
                Text(valid ? "" : "Doesn't fit a bar").font(.caption).foregroundStyle(.red)
            }
            Text("D ↓ down · U ↑ up · X ✕ muted · B bass note (root, then fifth) · – hold · . rest · > accent. Click a step to change it, ⌥-click to accent it, right-click for any stroke.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Picker("Put it on", selection: $target) {
                Text(barLabel).tag(StrumPatternEditor.Target.bars)
                Text("Every Bar").tag(StrumPatternEditor.Target.every)
                Text("A New Rhythm Guitar Staff").tag(StrumPatternEditor.Target.newStaff)
            }
            .pickerStyle(.segmented)
            HStack {
                let playing = NotebookStore.shared.editor.scorePlaying
                Button(playing ? "Stop" : "Play") {
                    if ScorePlayer.shared.isPlaying { ScorePlayer.shared.stop() } else { play(text) }
                }
                .disabled(!valid)
                Spacer()
                Button("Cancel") { finish(nil) }.keyboardShortcut(.cancelAction)
                Button("Apply") { finish((StrumPattern.text(cells), target)) }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("strum-apply")
                    .disabled(!valid)
            }
        }
        .padding(18)
        .frame(width: 620)
    }
}
