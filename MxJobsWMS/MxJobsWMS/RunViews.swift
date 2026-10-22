//
//  RunViews.swift
//  MxJobsWMS
//
//  The debug / run bar above the canvas (run controls, what each layer does in a run,
//  breakpoints, step delay, status) and the run console below it (log, step outputs,
//  and the approval / confirmation prompts a run waits on).
//

import SwiftUI

struct RunBar: View {
    @Binding var settings: RunSettings
    var editor: EditorState

    var body: some View {
        let engine = editor.run
        HStack(spacing: 10) {
            // Run controls
            HStack(spacing: 2) {
                Button {
                    editor.startRun()
                } label: {
                    Image(systemName: "play.fill")
                        .foregroundStyle(engine.isActive && !engine.canContinue ? Color.secondary : Color.green)
                }
                .help(engine.canContinue ? "Continue (⌃⌘Y)" : "Run (⌘R)")
                .disabled(engine.isActive && !engine.canContinue)
                .quickHelp(engine.canContinue ? "Continue" : "Run",
                           engine.canContinue ? "Carries on from where the run paused, to the next breakpoint or the end."
                               : "Runs the jobspace from its trigger, step by step down and back up the layers, following each layer's setting in this bar.",
                           shortcut: engine.canContinue ? "⌃⌘Y" : "⌘R")

                Button {
                    if engine.phase == .running { engine.pause() } else { engine.continueRun() }
                } label: {
                    Image(systemName: engine.phase == .paused ? "play.square" : "pause.fill")
                }
                .help(engine.phase == .paused ? "Continue (⌃⌘Y)" : "Pause before the next step")
                .disabled(!(engine.phase == .running || engine.phase == .paused))
                .quickHelp(engine.phase == .paused ? "Continue" : "Pause",
                           engine.phase == .paused ? "Carries on from where the run paused." : "Pauses the run before its next step; Continue or Step goes on.",
                           shortcut: engine.phase == .paused ? "⌃⌘Y" : nil)

                Button {
                    editor.stepRun()
                } label: {
                    Image(systemName: "arrow.turn.down.right")
                }
                .help("Step — run to the next step and pause (F6)")
                .disabled(engine.phase == .running || engine.phase == .waiting)
                .quickHelp("Step", "Runs the next step and pauses, so you can look at its output in the console before going on.", shortcut: "F6")

                Button {
                    engine.stop()
                } label: {
                    Image(systemName: "stop.fill")
                        .foregroundStyle(engine.isActive ? Color.red : Color.secondary)
                }
                .help("Stop (⌘.)")
                .disabled(!engine.isActive)
                .quickHelp("Stop", "Stops the run. Its results stay on the canvas and in the console until you run again or clear them.", shortcut: "⌘.")
            }
            .buttonStyle(.borderless)
            .font(.system(size: 14))

            Divider().frame(height: 18)

            // What each layer does in a run
            LayerActionMenu(layer: .operations, title: settings.operations.short) {
                Picker("Layer 1", selection: $settings.operations) {
                    ForEach(OperationsAction.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
            }
            LayerActionMenu(layer: .agents, title: settings.agents.short) {
                Picker("Layer 2", selection: $settings.agents) {
                    ForEach(AgentsAction.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
            }
            LayerActionMenu(layer: .data, title: settings.data.short) {
                Picker("Layer 3", selection: $settings.data) {
                    ForEach(DataAction.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
            }

            Divider().frame(height: 18)

            Button {
                settings.breakpointsEnabled.toggle()
            } label: {
                Image(systemName: settings.breakpointsEnabled ? "arrowshape.right.fill" : "arrowshape.right")
                    .foregroundStyle(settings.breakpointsEnabled ? Color.blue : Color.secondary)
            }
            .buttonStyle(.borderless)
            .help("Breakpoints on / off (⌘Y). Toggle one on the selected step with ⌘\\.")
            .quickHelp("Breakpoints", "Turns all breakpoints on or off. A run pauses before each step with a breakpoint while they're on; ⌘\\ toggles one on the selected step.", shortcut: "⌘Y")

            Menu {
                Toggle("Stop the run when a step fails", isOn: $settings.stopOnError)
                Picker("Step delay", selection: $settings.stepDelay) {
                    Text("No delay").tag(0.0)
                    Text("0.2 s").tag(0.2)
                    Text("0.4 s").tag(0.4)
                    Text("1 s").tag(1.0)
                    Text("2 s").tag(2.0)
                }
                Divider()
                Button("Clear Run Results") { editor.run.reset() }
                    .disabled(engine.isActive)
            } label: {
                Image(systemName: "gearshape")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Run options")
            .quickHelp("Run Options", "Stop the run when a step fails, a delay between steps to watch it go, and Clear Run Results.")

            Divider().frame(height: 18)

            RunStatus(engine: engine, space: editor.document?.wrappedValue.space)
                .frame(maxWidth: .infinity, alignment: .leading)
                .quickHelp("Run Status", "Ready, running, paused, waiting for you, finished, failed or stopped — with the current step, or how long the run took.", symbol: "info.circle")

            Button {
                editor.showConsole.toggle()
            } label: {
                Image(systemName: "rectangle.bottomthird.inset.filled")
                    .foregroundStyle(editor.showConsole ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.borderless)
            .help("Show or hide the run console (⇧⌘Y)")
            .quickHelp("Run Console", "Shows or hides the run log and step outputs under the canvas.", shortcut: "⇧⌘Y")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .quickHelpArea(JobsHelp.runBar)
    }
}

private struct LayerActionMenu<Content: View>: View {
    var layer: Layer
    var title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: 3) {
            Text("L\(layer.rawValue)")
                .font(.caption.weight(.heavy))
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(layer.color, in: RoundedRectangle(cornerRadius: 3))
            Menu {
                Section("Layer \(layer.rawValue) · \(layer.title)") { content() }
            } label: {
                Text(title)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .help("What a run does with Layer \(layer.rawValue) · \(layer.title)")
        .quickHelp(JobsHelp.layerAction(layer).title, JobsHelp.layerAction(layer).detail, symbol: JobsHelp.layerAction(layer).symbol)
    }
}

private struct RunStatus: View {
    var engine: RunEngine
    var space: Jobspace?

    var body: some View {
        HStack(spacing: 6) {
            switch engine.phase {
            case .idle:
                Text("Ready").foregroundStyle(.secondary)
            case .running:
                ProgressView().controlSize(.small)
                Text("Running\(current)")
            case .paused:
                Image(systemName: "pause.circle.fill").foregroundStyle(.purple)
                Text("Paused\(current)")
            case .waiting:
                Image(systemName: "person.crop.circle.badge.questionmark").foregroundStyle(.orange)
                Text("Waiting for you\(current)")
            case .finished:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Finished\(duration)")
            case .failed:
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                Text("Failed\(duration)")
            case .stopped:
                Image(systemName: "stop.circle.fill").foregroundStyle(.secondary)
                Text("Stopped\(duration)")
            }
        }
        .font(.callout)
        .lineLimit(1)
    }

    private var current: String {
        guard let id = engine.currentNode, let node = space?.node(id) else { return "" }
        return " — \(node.title)"
    }

    private var duration: String {
        guard let a = engine.startedAt, let b = engine.finishedAt else { return "" }
        return String(format: " in %.1f s", b.timeIntervalSince(a))
    }
}

// MARK: - Prompt

struct RunPromptBanner: View {
    var prompt: RunPrompt
    var engine: RunEngine
    @State private var showDetail = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .font(.title2)
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text(prompt.title).font(.headline)
                    Text(prompt.message).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                ForEach(prompt.options) { option in
                    if option.isDefault {
                        Button(option.label) { engine.respond(option.label) }
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.defaultAction)
                    } else {
                        Button(option.label, role: option.isDestructive ? .destructive : nil) { engine.respond(option.label) }
                    }
                }
            }
            if !prompt.detail.isEmpty {
                DisclosureGroup("Details", isExpanded: $showDetail) {
                    ScrollView {
                        Text(prompt.detail)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 110)
                }
                .font(.caption)
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.10))
        .overlay(alignment: .leading) { Rectangle().fill(.orange).frame(width: 3) }
        .quickHelpArea(JobsHelp.prompt(prompt))
    }
}

// MARK: - Console

/// Drag handle between the canvas and the run console.
struct ConsoleDivider: View {
    @Binding var height: CGFloat
    @State private var start: CGFloat?

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(height: 1)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    if start == nil { start = height }
                    height = min(600, max(120, (start ?? height) - value.translation.height))
                }
                .onEnded { _ in start = nil })
            .help("Drag to resize the run console")
            .quickHelp("Console Divider", "Drag to give the run console more or less room.", symbol: "arrow.up.and.down")
    }
}

struct RunConsole: View {
    var editor: EditorState
    var space: Jobspace

    @State private var minimum: LogLevel = .debug
    @State private var outputNode: UUID?

    var body: some View {
        let engine = editor.run
        VStack(spacing: 0) {
            if let prompt = engine.prompt {
                RunPromptBanner(prompt: prompt, engine: engine)
                Divider()
            }
            HStack(spacing: 0) {
                logPane(engine)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                outputPane(engine)
                    .frame(width: 340)
                    .frame(maxHeight: .infinity)
            }
        }
        .clipped()
        .background(Color(nsColor: .textBackgroundColor))
        .quickHelpArea(JobsHelp.console)
    }

    private func logPane(_ engine: RunEngine) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("Run Log").font(.caption.weight(.semibold))
                Spacer()
                Picker("Show", selection: $minimum) {
                    Text("All").tag(LogLevel.debug)
                    Text("Info").tag(LogLevel.info)
                    Text("Warnings").tag(LogLevel.warning)
                    Text("Errors").tag(LogLevel.error)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.small)
                .fixedSize()
                Button("Clear", systemImage: "trash") { engine.clearLog() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Clear the log")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            Divider()
            ScrollViewReader { proxy in
                List {
                    ForEach(engine.log.filter { $0.level >= minimum }) { entry in
                        LogRow(entry: entry, space: space)
                            .id(entry.id)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if let id = entry.nodeID {
                                    editor.select(node: id)
                                    outputNode = id
                                }
                            }
                    }
                }
                .listStyle(.plain)
                .environment(\.defaultMinListRowHeight, 18)
                .onChange(of: engine.log.count) {
                    if let last = engine.log.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
                .overlay {
                    if engine.log.isEmpty {
                        Text("Press ▶ Run (⌘R) or Step (F6) to run the jobspace.")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private func outputPane(_ engine: RunEngine) -> some View {
        let _ = engine.outputsRevision
        let id = outputNode ?? editor.selectedNodes.first ?? engine.currentNode
        let node = id.flatMap { space.node($0) }
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Output").font(.caption.weight(.semibold))
                if let node {
                    Text(node.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if let state = engine.states[node.id] {
                        Label(state.title, systemImage: state.symbol)
                            .font(.caption)
                            .foregroundStyle(state.color)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            Divider()
            ScrollView {
                Group {
                    if let node, let value = engine.output(of: node.id) {
                        Text(RunEngine.pretty(value))
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    } else {
                        Text(node == nil ? "Select a step to see its output." : "No output yet.")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
        }
        .onChange(of: editor.selectedNodes) { outputNode = nil }
    }
}

private struct LogRow: View {
    var entry: RunLogEntry
    var space: Jobspace

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(Self.time.string(from: entry.date))
                .foregroundStyle(.tertiary)
            Image(systemName: entry.level.symbol)
                .foregroundStyle(entry.level.color)
                .frame(width: 14)
            if let id = entry.nodeID, let node = space.node(id) {
                Text("L\(node.layer.rawValue)")
                    .font(.caption2.weight(.heavy))
                    .foregroundStyle(node.layer.color)
            }
            Text(entry.message)
                .foregroundStyle(entry.level == .debug ? .secondary : .primary)
                .textSelection(.enabled)
        }
        .font(.caption.monospaced())
    }
}

extension LogLevel {
    var color: Color {
        switch self {
        case .debug: .secondary
        case .info: .blue
        case .success: .green
        case .warning: .orange
        case .error: .red
        }
    }
}

extension NodeRunState {
    var color: Color {
        switch self {
        case .pending: .secondary
        case .paused: .purple
        case .running: .blue
        case .waiting: .orange
        case .succeeded: .green
        case .warning: .orange
        case .failed: .red
        case .skipped: .gray
        }
    }
}
