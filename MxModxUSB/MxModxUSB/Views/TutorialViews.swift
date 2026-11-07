//
//  TutorialViews.swift — MxModxUSB
//
//  The FM Synthesis and AWM2 Synthesis pages: a lesson list beside the lesson, taught at the instruction level in
//  Settings ▸ Guidance (also in each page's header), and played on the MODX7 — the lesson's sound is set up on an
//  FM-X or AWM2 Part of the current Performance, and its controls change that Part as you play.
//

import SwiftUI

struct TutorialView: View {
    let model: ModxModel
    let engine: ModxEngine
    @Bindable private var settings = ModxSettings.shared
    @State private var lessonID: String?
    @State private var chosenPart: Int?

    init(model: ModxModel, engine: ModxEngine) {
        self.model = model
        self.engine = engine
        _lessonID = State(initialValue: UserDefaults.standard.string(forKey: "tutorialLesson.\(engine.rawValue)"))
    }

    private var lessons: [TutorialLesson] { engine.lessons.filter(settings.shows) }
    private var lesson: TutorialLesson? { lessons.first { $0.id == lessonID } ?? lessons.first }
    private var session: ModxTutorialSession? { model.tutorial?.engine == engine ? model.tutorial : nil }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            sessionStrip
            Divider()
            HStack(spacing: 0) {
                lessonList
                Divider()
                if let lesson {
                    LessonView(model: model, engine: engine, lesson: lesson, session: session, next: next, previous: previous)
                        .quickHelpArea(lesson.title, lesson.goal + (lesson.lessonOnly ? " A page to read: no sound to set up."
                                       : " Set Up on the MODX builds its sound on the tutorial's Part; then play the MODX and change it below."),
                                       symbol: "graduationcap")
                }
            }
        }
        .onChange(of: lessonID) { _, id in UserDefaults.standard.set(id, forKey: "tutorialLesson.\(engine.rawValue)") }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(engine.title) on the MODX7").font(.title2.weight(.semibold))
                if settings.showsIntroductions {
                    Text(engine == .fmx ? "Frequency modulation, with the MODX7's FM-X engine: 8 operators, 88 algorithms."
                         : "Advanced Wave Memory 2, the MODX7's sample engine: up to 8 elements, 6,347 waveforms.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text("Instruction").foregroundStyle(.secondary).font(.callout)
            Picker("Instruction", selection: $settings.guidance) {
                ForEach(ModxGuidance.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .help("How much each lesson teaches (also Settings ▸ Guidance)")
            .quickHelp("Instruction level", "Full: everything, with “Why it works”. Brief: no “Why it works”. Minimal: also no line under the titles or “Listen for”, and the pages that only teach leave the list. The same as Settings ▸ Guidance.")
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
    }

    // MARK: The Part the tutorial uses

    @ViewBuilder private var sessionStrip: some View {
        HStack(spacing: 10) {
            Image(systemName: session == nil ? "pianokeys" : "checkmark.circle.fill").foregroundStyle(session == nil ? Modx.accent : .green)
            stripContent
            Spacer(minLength: 8)
            if let busy = model.tutorialBusy {
                ProgressView().controlSize(.small)
                Text(busy).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            } else if let report = model.tutorialReport, model.tutorialEngine == nil || model.tutorialEngine == engine {
                Text(report).font(.caption).foregroundStyle(.secondary).lineLimit(2).frame(maxWidth: 420, alignment: .trailing)
            }
        }
        .font(.callout)
        .padding(.horizontal, 18).padding(.vertical, 9)
        .background(Modx.accent.opacity(0.06))
    }

    @ViewBuilder private var stripContent: some View {
        let candidates = model.tutorialParts(engine)
        if !model.connected {
            Text("Connect the MODX: the tutorial plays its sounds there.")
        } else if !model.editsUnlocked {
            Text("The lessons set up their sounds on the MODX: unlock changes to let them.")
            Button("Unlock Changes") { model.editsUnlocked = true }
                .quickHelp("Unlock Changes", "Lets the app send changes to the MODX — the same as the lock in the toolbar. Lesson sounds go to the MODX's edit buffer, never into its memory.")
        } else if let session {
            Text("Part \(session.part + 1) “\(model.parts[session.part].name)” of “\(session.performance)”, kept as it was.")
                .lineLimit(1)
            Toggle("Hear only this Part", isOn: Binding(get: { session.hearingOnly }, set: { on in Task { await model.setTutorialSolo(on) } }))
                .toggleStyle(.checkbox)
                .disabled(model.tutorialBusy != nil)
                .quickHelp("Hear only this Part", "Mutes the Performance's other Parts that are playing while you learn, and unmutes them as they were when you turn it off or put the Part back — even after the app was quit with it on (it remembers which Parts it muted until the Performance is chosen again on the MODX).")
            Button("Put Part \(session.part + 1) Back") { Task { await model.putTutorialPartBack() } }
                .disabled(model.tutorialBusy != nil)
                .quickHelp("Put Part Back", "Sends the Part back to the MODX exactly as it was when the tutorial started (a Bulk Dump of the copy it kept), checks it, and ends the tutorial.")
        } else if candidates.isEmpty {
            noPart
        } else {
            Text("Use").foregroundStyle(.secondary)
            Picker("Part", selection: Binding(get: { chosenPart ?? candidates[0].index }, set: { chosenPart = $0 })) {
                ForEach(candidates) { Text("Part \($0.index + 1) · \($0.name)").tag($0.index) }
            }
            .labelsHidden().fixedSize()
            Button("Start with This Part") {
                let p = chosenPart.flatMap { c in candidates.contains { $0.index == c } ? c : nil } ?? candidates[0].index
                Task { await model.startTutorial(engine, part: p) }
            }
            .disabled(model.tutorialBusy != nil)
            .quickHelp("Start with This Part", "Reads the Part and keeps a copy, so Put Part Back can restore it; then each lesson's Set Up on the MODX changes this Part.")
        }
    }

    @ViewBuilder private var noPart: some View {
        let suggestions = suggestedSlots
        Text(model.partsLoaded ? "“\(model.common.name)” has no \(engine.engineName) Part. Choose a Performance with one on the MODX\(suggestions.isEmpty ? "." : ", or play:")"
             : "Reading the Performance's Parts…")
            .lineLimit(2)
        ForEach(suggestions) { slot in
            Button(model.performanceName(for: slot)?.name ?? slot.name) { model.selectLiveSetSlot(slot) }
                .disabled(model.liveSetSelectProblem != nil || model.selectingSlot != nil)
                .help("Plays Live Set page \(slot.page + 1), slot \(slot.slot + 1) on the MODX")
        }
    }

    /// Live Set slots likely to have a Part of this engine: Yamaha's preset FM-X Performances are named "FM …".
    private var suggestedSlots: [ModxLiveSlot] {
        guard let liveSet = model.liveSet else { return [] }
        let named = liveSet.slots.filter { !$0.isEmpty }.map { ($0, model.performanceName(for: $0)?.name ?? $0.name) }
        let fits = named.filter { engine == .fmx ? $0.1.hasPrefix("FM ") : !$0.1.hasPrefix("FM ") }
        return Array(fits.prefix(3).map(\.0))
    }

    // MARK: Lessons

    private var lessonList: some View {
        List(selection: Binding(get: { lesson?.id }, set: { lessonID = $0 })) {
            Section("Lessons") {
                ForEach(Array(lessons.enumerated()), id: \.element.id) { i, item in
                    HStack(spacing: 6) {
                        Text("\(i + 1)").monospacedDigit().foregroundStyle(.secondary).frame(width: 18, alignment: .trailing)
                        Text(item.title).lineLimit(2)
                        Spacer(minLength: 0)
                        if item.lessonOnly { Image(systemName: "book").foregroundStyle(.secondary).help("Reading only: no sound to set up") }
                        else if session?.lesson == item.id { Image(systemName: "speaker.wave.2.fill").foregroundStyle(.green).help("Set up on the MODX now") }
                    }
                    .tag(item.id)
                }
            }
        }
        .frame(width: 250)
        .quickHelpArea("Lessons", "The \(engine.title) lessons, in order. A book marks a page that only teaches; a speaker the lesson set up on the MODX now. At Minimal the reading pages leave the list.")
    }

    private func next() { move(1) }
    private func previous() { move(-1) }
    private func move(_ step: Int) {
        guard let lesson, let i = lessons.firstIndex(where: { $0.id == lesson.id }), lessons.indices.contains(i + step) else { return }
        lessonID = lessons[i + step].id
    }
}

private struct LessonView: View {
    let model: ModxModel
    let engine: ModxEngine
    let lesson: TutorialLesson
    let session: ModxTutorialSession?
    let next: () -> Void
    let previous: () -> Void
    @Bindable private var settings = ModxSettings.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(lesson.title).font(.title2.weight(.semibold))
                if settings.showsIntroductions { Text(lesson.goal).font(.title3).foregroundStyle(.secondary) }
                if !lesson.lessonOnly { setUpRow }
                if engine == .fmx, let algorithm = shownAlgorithm {
                    AlgorithmDiagram(model: model, part: session?.part, number: algorithm)
                } else if engine == .awm2, let session, !lesson.lessonOnly {
                    ElementMap(model: model, part: session.part)
                }
                if settings.showsTheory, !lesson.theory.isEmpty {
                    Card(title: "Why it works", systemImage: "lightbulb") {
                        ForEach(Array(lesson.theory.enumerated()), id: \.offset) { _, text in
                            Text(text).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        }
                    }
                }
                if !lesson.steps.isEmpty {
                    Card(title: "Try this", systemImage: "hand.point.right") {
                        ForEach(Array(lesson.steps.enumerated()), id: \.offset) { i, text in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("\(i + 1).").monospacedDigit().foregroundStyle(.secondary)
                                Text(text).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                if !lesson.controls.isEmpty { controls }
                if settings.showsListening, let listen = lesson.listen {
                    Card(title: "Listen for", systemImage: "ear") { Text(listen).fixedSize(horizontal: false, vertical: true) }
                }
                HStack {
                    Button("Previous Lesson", action: previous)
                    Spacer()
                    Button("Next Lesson", action: next).keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                }
                .padding(.top, 4)
            }
            .padding(18)
            .frame(maxWidth: 880, alignment: .leading)
        }
    }

    /// The Part's own algorithm while a tutorial runs (what you hear), else the lesson's.
    private var shownAlgorithm: Int? {
        if let session, let param = ModxParams.voiceParam("fm.algorithm"), let v = model.value(param, .fmCommon(session.part)) { return v + 1 }
        return lesson.algorithm
    }

    private var setUpRow: some View {
        HStack(spacing: 10) {
            Button {
                Task { await model.setUpLesson(lesson) }
            } label: {
                Label("Set Up on the MODX", systemImage: "arrow.down.to.line")
            }
            .buttonStyle(.borderedProminent)
            .disabled(session == nil || !model.editsUnlocked || model.tutorialBusy != nil)
            .quickHelp("Set Up on the MODX", "Builds this lesson's sound on the tutorial's Part: the \(engine.engineName) settings it needs, starting from a plain sound, sent as Parameter Changes to the MODX's edit buffer and read back. Then play the MODX.")
            if session == nil {
                Text("Start with a Part above first.").font(.callout).foregroundStyle(.secondary)
            } else if session?.lesson == lesson.id {
                Label("Set up — play the MODX", systemImage: "speaker.wave.2.fill").font(.callout).foregroundStyle(.green)
            }
        }
    }

    private var controls: some View {
        Card(title: "Change it while you play", systemImage: "slider.horizontal.3") {
            if let session {
                ForEach(lesson.controls) { control in
                    if let param = control.param {
                        let target = TutorialSetting(block: control.block, key: control.key, value: 0).target(part: session.part)
                        if control.key == "el.wave" {
                            WaveRow(model: model, param: param, target: target, label: control.label)
                        } else {
                            ParamRow(model: model, param: param, target: target, label: control.label)
                        }
                    }
                }
                Text("Each change goes to Part \(session.part + 1) on the MODX as you make it, and is read back.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(lesson.controls) { Text("• \($0.label)").foregroundStyle(.secondary) }
                Text("Start with a Part above to change these on the MODX.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// An element's waveform, from the preset waveforms the lessons use.
private struct WaveRow: View {
    let model: ModxModel
    let param: ModxParam
    let target: ModxTarget
    let label: String

    var body: some View {
        let current = model.value(param, target)
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            if model.canEdit(param, target) {
                Picker("", selection: Binding(get: { current ?? ModxVoice.basicWaves[0].number }, set: { model.set(param, target, to: $0) })) {
                    if let current, !ModxVoice.basicWaves.contains(where: { $0.number == current }) {
                        Text(ModxVoice.waveName(current)).tag(current)
                    }
                    ForEach(ModxVoice.basicWaves, id: \.number) { Text("\($0.number) \($0.name)").tag($0.number) }
                }
                .labelsHidden().fixedSize()
            } else {
                Text(current.map(ModxVoice.waveName) ?? "—").fontWeight(.medium)
            }
        }
        .font(.callout)
        .quickHelp(label, "The element's preset waveform: Saw (all harmonics), P50-1 (a square: odd harmonics), P25-1 (a narrow pulse), Tri Wave and Sine. The MODX has 6,347; the Waveform List names them all.")
    }
}

/// An FM-X algorithm as the Data List draws it: modulators above the operators they modulate, carriers along the
/// bottom into the output, operator 1's feedback loop; each box filled by its operator's level.
struct AlgorithmDiagram: View {
    let model: ModxModel
    let part: Int?
    let number: Int

    var body: some View {
        Card(title: "Algorithm \(number)", systemImage: "point.3.connected.trianglepath.dotted") {
            if let algorithm = ModxFMAlgorithms.known[number] {
                diagram(algorithm)
                    .frame(height: CGFloat((algorithm.positions.values.map(\.row).max() ?? 0) + 1) * 46 + 30)
                Text("Carriers (outlined) are heard; the others modulate the operator below them. Operator 1 feeds back into itself. \(part == nil ? "" : "Boxes fill with each operator's level on the MODX.")")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("The Part plays algorithm \(number). The app draws algorithms 1–8; the MODX Data List's Algorithm Chart (p. 182–185) shows all 88.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .quickHelpArea("Algorithm \(number)", "How the Part's 8 operators are wired: each modulator sits above the operator it modulates; carriers along the bottom are what you hear.")
    }

    private func level(_ op: Int) -> Double? {
        guard let part, let param = ModxParams.voiceParam("op.level"), let v = model.value(param, .fmOperator(part: part, op: op - 1)) else { return nil }
        return Double(v) / 99
    }

    private func diagram(_ algorithm: ModxFMAlgorithms.Algorithm) -> some View {
        Canvas { context, size in
            let w: CGFloat = 40, h: CGFloat = 28, dx: CGFloat = 56, dy: CGFloat = 46
            let top = CGFloat(algorithm.positions.values.map(\.row).max() ?? 0)
            func center(_ op: Int) -> CGPoint {
                let p = algorithm.positions[op]!
                return CGPoint(x: 24 + CGFloat(p.col) * dx + w / 2, y: 6 + (top - CGFloat(p.row)) * dy + h / 2)
            }
            let line = GraphicsContext.Shading.color(.secondary)
            for edge in algorithm.edges {
                let a = center(edge.from), b = center(edge.to)
                var path = Path()
                path.move(to: CGPoint(x: a.x, y: a.y + h / 2))
                if a.x == b.x {
                    path.addLine(to: CGPoint(x: b.x, y: b.y - h / 2))
                } else {
                    let mid = b.y - h / 2 - 8
                    path.addLine(to: CGPoint(x: a.x, y: mid))
                    path.addLine(to: CGPoint(x: b.x, y: mid))
                    path.addLine(to: CGPoint(x: b.x, y: b.y - h / 2))
                }
                context.stroke(path, with: line, lineWidth: 1.5)
            }
            let carriers = algorithm.carriers
            if let first = carriers.first, let last = carriers.last {
                let busY = center(first).y + h / 2 + 10
                var bus = Path()
                for c in carriers {
                    bus.move(to: CGPoint(x: center(c).x, y: center(c).y + h / 2))
                    bus.addLine(to: CGPoint(x: center(c).x, y: busY))
                }
                bus.move(to: CGPoint(x: center(first).x, y: busY))
                bus.addLine(to: CGPoint(x: center(last).x + 22, y: busY))
                context.stroke(bus, with: .color(Modx.accent), lineWidth: 2)
                context.draw(Text("out").font(.caption2).foregroundColor(Modx.accent), at: CGPoint(x: center(last).x + 36, y: busY))
            }
            let fb = center(algorithm.feedback)
            var loop = Path()
            loop.move(to: CGPoint(x: fb.x + w / 2, y: fb.y + 4))
            loop.addLine(to: CGPoint(x: fb.x + w / 2 + 7, y: fb.y + 4))
            loop.addLine(to: CGPoint(x: fb.x + w / 2 + 7, y: fb.y - h / 2 - 5))
            loop.addLine(to: CGPoint(x: fb.x, y: fb.y - h / 2 - 5))
            loop.addLine(to: CGPoint(x: fb.x, y: fb.y - h / 2))
            context.stroke(loop, with: line, lineWidth: 1.2)
            for op in 1...8 {
                let c = center(op)
                let rect = CGRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h)
                let box = Path(roundedRect: rect, cornerRadius: 5)
                context.fill(box, with: .color(Color(white: 0.5).opacity(0.18)))
                if let level = level(op), level > 0 {
                    let filled = CGRect(x: rect.minX, y: rect.maxY - rect.height * level, width: rect.width, height: rect.height * level)
                    context.fill(Path(roundedRect: filled, cornerRadius: 5), with: .color(Modx.live.opacity(0.55)))
                }
                if carriers.contains(op) { context.stroke(box, with: .color(Modx.accent), lineWidth: 1.6) }
                context.draw(Text("\(op)").font(.callout.weight(.semibold)), at: c)
            }
        }
    }
}

/// An AWM2 Part's 8 elements: on or off, waveform, level, and the keys and velocities each plays.
struct ElementMap: View {
    let model: ModxModel
    let part: Int

    var body: some View {
        Card(title: "Elements of Part \(part + 1)", systemImage: "square.3.layers.3d") {
            ForEach(0..<8, id: \.self) { e in row(e) }
            Text("Bars: the keys each element plays (C-2 to G8) and, below, its velocity range (1–127).")
                .font(.caption).foregroundStyle(.secondary)
        }
        .quickHelpArea("Elements", "The Part's 8 elements as the MODX holds them: whether each is on, its waveform and level, and the keys and velocities it plays.")
    }

    private func value(_ key: String, _ e: Int) -> Int? {
        guard let param = ModxParams.voiceParam(key) else { return nil }
        return model.value(param, .element(part: part, element: e))
    }

    @ViewBuilder private func row(_ e: Int) -> some View {
        let on = value("el.switch", e) == 1
        HStack(spacing: 10) {
            Text("\(e + 1)").monospacedDigit().frame(width: 14).foregroundStyle(on ? .primary : .tertiary)
            Text(on ? value("el.wave", e).map(ModxVoice.waveName) ?? "—" : "off").frame(width: 130, alignment: .leading)
                .foregroundStyle(on ? .primary : .tertiary).lineLimit(1)
            Text(on ? "level \(value("el.level", e) ?? 0)" : "").font(.caption).foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
            GeometryReader { geo in
                let low = CGFloat(value("el.noteLow", e) ?? 0), high = CGFloat(value("el.noteHigh", e) ?? 127)
                let vLow = CGFloat(value("el.velLow", e) ?? 1), vHigh = CGFloat(value("el.velHigh", e) ?? 127)
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.12))
                    if on {
                        RoundedRectangle(cornerRadius: 3).fill(Modx.live.opacity(0.6))
                            .frame(width: max(2, (high - low + 1) / 128 * geo.size.width), height: 7)
                            .offset(x: low / 128 * geo.size.width)
                        RoundedRectangle(cornerRadius: 2).fill(Modx.accent.opacity(0.6))
                            .frame(width: max(2, (vHigh - vLow + 1) / 127 * geo.size.width), height: 4)
                            .offset(x: (vLow - 1) / 127 * geo.size.width, y: 9)
                    }
                }
            }
            .frame(height: 13)
        }
        .font(.callout)
    }
}
