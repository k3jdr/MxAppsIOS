//
//  ChordDiagramEditor.swift
//  MxNoteONE
//
//  Drawing a chord diagram by hand: click a fret on a string for a dot (again to take it off), over the nut for
//  open or not played; the fret the diagram starts at; fingers worked out, or set by clicking a dot (1–4). The
//  notes it plays are named as you go, and Play strums it. Saved, it's the voicing for that chord everywhere in
//  the score.
//

import AppKit
import SwiftUI

@MainActor
enum ChordDiagramEditor {
    enum Result {
        case cancel, automatic
        case shape(GuitarChords.Shape)
    }

    static func edit(name: String, shape: GuitarChords.Shape, strings: [Int], capo: Int, program: Int, in window: NSWindow?,
                     done: @escaping (Result) -> Void) {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 470), styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "\(name) — Chord Diagram"
        func finish(_ r: Result) {
            if let parent = panel.sheetParent { parent.endSheet(panel) } else { panel.close() }
            done(r)
        }
        panel.contentView = NSHostingView(rootView: ChordDiagramEditorView(name: name, shape: shape, strings: strings, capo: capo, program: program, finish: finish))
        if let window { window.beginSheet(panel) } else { panel.center(); panel.makeKeyAndOrderFront(nil) }
    }
}

struct ChordDiagramEditorView: View {
    let name: String
    @State var shape: GuitarChords.Shape
    let strings: [Int]
    let capo: Int
    let program: Int
    let finish: (ChordDiagramEditor.Result) -> Void
    @State private var base: Int
    @State private var customFingers: Bool

    init(name: String, shape: GuitarChords.Shape, strings: [Int], capo: Int, program: Int, finish: @escaping (ChordDiagramEditor.Result) -> Void) {
        self.name = name
        self.strings = strings
        self.capo = capo
        self.program = program
        self.finish = finish
        var s = shape
        if s.frets.count != strings.count { s = GuitarChords.Shape(frets: Array(repeating: 0, count: strings.count)) }
        _shape = State(initialValue: s)
        _base = State(initialValue: s.baseFret)
        _customFingers = State(initialValue: shape.fingers != nil)
    }

    private let rows = 5
    private let gap: CGFloat = 38, fretHeight: CGFloat = 44

    /// What it plays, named.
    private var playing: String {
        let pitches = shape.frets.enumerated().compactMap { s, f in f.map { strings[s] + $0 + capo } }
        let notes = pitches.sorted().map { TabInstrument.noteName($0) }.joined(separator: " ")
        let named = GuitarChords.name(pitches, flats: false).map { " — \($0)" } ?? ""
        return notes.isEmpty ? "Nothing played" : notes + named
    }

    var body: some View {
        VStack(spacing: 12) {
            Text(name).font(.system(size: 22, weight: .semibold))
            Canvas { ctx, size in draw(ctx, size) }
                .frame(width: gap * CGFloat(strings.count - 1) + 80, height: fretHeight * CGFloat(rows) + 60)
                .contentShape(Rectangle())
                .gesture(SpatialTapGesture().onEnded { tap($0.location) })
            Text(playing).font(.callout).foregroundStyle(.secondary)
            HStack {
                Stepper("Starts at fret \(base)", value: $base, in: 1...20)
                Spacer()
                Toggle("Set fingers", isOn: $customFingers).toggleStyle(.checkbox)
                    .help("Click a dot to number its finger (1 index … 4 little); off, they're worked out")
            }
            .padding(.horizontal)
            HStack {
                Button("Play") {
                    ScorePlayer.shared.strum(shape.frets.enumerated().compactMap { s, f in f.map { strings[s] + $0 + capo } }, program: program)
                }
                Button("Automatic") { finish(.automatic) }.help("Back to the voicing chosen for it")
                Spacer()
                Button("Cancel") { finish(.cancel) }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    var s = shape
                    if !customFingers { s.fingers = nil }
                    finish(.shape(s))
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal)
        }
        .padding(.vertical, 16)
        .frame(width: max(360, gap * CGFloat(strings.count - 1) + 140))
    }

    private var left: CGFloat { 40 }
    private var top: CGFloat { 44 }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize) {
        let n = strings.count
        let width = gap * CGFloat(n - 1)
        for s in 0..<n {
            ctx.fill(Path(CGRect(x: left + CGFloat(s) * gap - 0.75, y: top, width: 1.5, height: fretHeight * CGFloat(rows))), with: .color(.primary))
            ctx.draw(Text(TabInstrument.noteName(strings[s] + capo)).font(.caption2).foregroundStyle(.secondary), at: CGPoint(x: left + CGFloat(s) * gap, y: top + fretHeight * CGFloat(rows) + 12))
        }
        for f in 0...rows {
            ctx.fill(Path(CGRect(x: left, y: top + CGFloat(f) * fretHeight - 0.75, width: width, height: 1.5)), with: .color(.primary))
        }
        if base == 1 {
            ctx.fill(Path(CGRect(x: left, y: top - 4, width: width, height: 5)), with: .color(.primary))
        } else {
            ctx.draw(Text("\(base)fr").font(.caption), at: CGPoint(x: left + width + 20, y: top + fretHeight * 0.5))
        }
        let fingers = customFingers ? (shape.fingers ?? Array(repeating: nil, count: n)) : shape.fingering
        for (s, f) in shape.frets.enumerated() {
            let x = left + CGFloat(s) * gap
            switch f {
            case nil:
                var p = Path()
                p.move(to: CGPoint(x: x - 7, y: top - 25)); p.addLine(to: CGPoint(x: x + 7, y: top - 11))
                p.move(to: CGPoint(x: x - 7, y: top - 11)); p.addLine(to: CGPoint(x: x + 7, y: top - 25))
                ctx.stroke(p, with: .color(.primary), lineWidth: 1.6)
            case 0?:
                ctx.stroke(Path(ellipseIn: CGRect(x: x - 7, y: top - 25, width: 14, height: 14)), with: .color(.primary), lineWidth: 1.6)
            case let fret?:
                let row = fret - base
                guard row >= 0, row < rows else { continue }
                let y = top + (CGFloat(row) + 0.5) * fretHeight
                ctx.fill(Path(ellipseIn: CGRect(x: x - 14, y: y - 14, width: 28, height: 28)), with: .color(.accentColor))
                if s < fingers.count, let d = fingers[s] {
                    ctx.draw(Text("\(d)").font(.system(size: 14, weight: .bold)).foregroundStyle(.white), at: CGPoint(x: x, y: y))
                }
            }
        }
    }

    private func tap(_ p: CGPoint) {
        let n = strings.count
        let s = Int(((p.x - left) / gap).rounded())
        guard (0..<n).contains(s), abs(p.x - (left + CGFloat(s) * gap)) < gap * 0.5 else { return }
        var frets = shape.frets
        if p.y < top {
            // Over the nut: open, or not played.
            frets[s] = frets[s] == 0 ? nil : 0
        } else {
            let row = Int((p.y - top) / fretHeight)
            guard row >= 0, row < rows else { return }
            let fret = base + row
            if frets[s] == fret {
                if customFingers {
                    // Clicking a dot numbers its finger.
                    var f = shape.fingers ?? Array(repeating: nil, count: n)
                    let current = f[s] ?? 0
                    f[s] = current >= 4 ? nil : current + 1
                    shape.fingers = f
                    return
                }
                frets[s] = 0
            } else {
                frets[s] = fret
            }
        }
        shape.frets = frets
        if !customFingers { shape.fingers = nil }
    }
}
