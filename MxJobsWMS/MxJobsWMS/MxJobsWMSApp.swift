//
//  MxJobsWMSApp.swift
//  MxJobsWMS
//
//  Document-based app: each window is a jobspace (*.jobspace JSON) describing a
//  three-layer financial data gathering operation. DocumentGroup provides the
//  File menu (New, Open, Open Recent, Save, Save As, Duplicate, Rename, Revert);
//  JobspaceCommands adds New from Sample, Export, the Run and Diagram menus, and the Layer 3 Services window.
//  mxjobswms:// links from MxDataHUB open samples for a portfolio (SampleLibrary.swift).
//

import SwiftUI

@main
struct MxJobsWMSApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // A new document is empty, or the sample PendingSample hands over (gallery, Services window, links).
        DocumentGroup(newDocument: JobspaceDocument(space: PendingSample.take())) { file in
            ContentView(document: file.$document)
        }
        .defaultSize(width: 1560, height: 920)
        .commands {
            JobspaceCommands()
            QuickHelpCommands()
        }

        Window("Adding API Keys", id: "keys-help") {
            KeysHelpView()
                .quickHelpScreen("Adding API Keys", JobsHelp.keys)
        }
        .defaultSize(width: 820, height: 560)

        Window("Layer 3 Services", id: "services") {
            ServicesView(serviceActions: { service, endpoint in
                AnyView(Group {
                    if let endpoint {
                        Button("Add Step") { EditorState.lastActive?.addServiceStep(service, endpoint) }
                            .help("Add a Layer 3 step calling \(endpoint.path) to the front jobspace")
                            .disabled(EditorState.lastActive == nil)
                    }
                })
            }, openSample: { PendingSample.open($0.id) }, openSampleTitle: "New Jobspace")
            .quickHelpScreen("Layer 3 Services", JobsHelp.services)
        }
        .defaultSize(width: 1040, height: 720)

        Window("New from Sample", id: "samples") {
            SampleGalleryView(open: { PendingSample.open($0.id) }, openTitle: "Create",
                              note: "Each sample is a complete three-layer workflow. Portfolio samples use DEMO_GROWTH; "
                                  + "open them from a portfolio in MxDataHUB to use another one.")
                .frame(minWidth: 720, minHeight: 520)
                .quickHelpScreen("New from Sample", JobsHelp.samples)
        }
        .defaultSize(width: 860, height: 640)
    }
}

struct JobspaceCommands: Commands {
    @FocusedValue(\.editor) private var editor
    @Environment(\.openWindow) private var openWindow
    @Environment(\.newDocument) private var newDocument

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New from Sample…") { openWindow(id: "samples") }
                .keyboardShortcut("n", modifiers: [.command, .option])
            Menu("New Sample") {
                ForEach(SampleInfo.all) { sample in
                    Button("\(sample.area): \(sample.title)") {
                        if let space = Jobspace.fromSample(sample.id) { newDocument(JobspaceDocument(space: space)) }
                    }
                }
            }
        }
        CommandGroup(after: .windowArrangement) {
            Divider()
            Button("Layer 3 Services") { openWindow(id: "services") }
                .keyboardShortcut("l", modifiers: [.command, .option])
            Button("Open MxDataHUB") {
                if !AppLink.dataRefresh.open() {
                    NSWorkspace.shared.open(URL(string: "https://github.com/k3jdr/MXcodeIDE/tree/main/MxDataHUB")!)
                }
            }
            Button("Open MxPortMGR") {
                if !AppLink.myPortfolio(nil).open() {
                    NSWorkspace.shared.open(URL(string: "https://github.com/k3jdr/MXcodeIDE/tree/main/MxPortMGR")!)
                }
            }
        }
        CommandGroup(after: .importExport) {
            Button("Export Diagram as PNG…") {
                if let space = editor?.document?.wrappedValue.space { DiagramExport.savePNG(space: space) }
            }
            .disabled(editor == nil)
            Button("Export Diagram as draw.io SVG…") {
                if let space = editor?.document?.wrappedValue.space { DiagramExport.saveDrawioSVG(space: space) }
            }
            .disabled(editor == nil)
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Duplicate Nodes") { editor?.duplicateSelection() }
                .keyboardShortcut("d")
                .disabled(editor?.selectedNodes.isEmpty ?? true)
            Button("Delete Selection") { editor?.deleteSelection() }
                .disabled(!(editor?.hasSelection ?? false))
            Button("Select All Nodes") { editor?.selectAll() }
                .keyboardShortcut("a", modifiers: [.command, .option])
                .disabled(editor == nil)
        }
        CommandGroup(replacing: .help) {
            Button("Adding API Keys") { openWindow(id: "keys-help") }
            Button("MxJobsWMS on GitHub") {
                NSWorkspace.shared.open(URL(string: "https://github.com/k3jdr/MXcodeIDE/tree/main/MxJobsWMS")!)
            }
        }
        CommandMenu("Run") {
            let run = editor?.run
            Button(run?.canContinue == true ? "Continue" : "Run") { editor?.startRun() }
                .keyboardShortcut("r")
                .disabled(editor == nil || (run?.isActive == true && run?.canContinue == false))
            Button("Continue") { run?.continueRun() }
                .keyboardShortcut("y", modifiers: [.command, .control])
                .disabled(run?.canContinue != true)
            Button("Step") { editor?.stepRun() }
                .keyboardShortcut(KeyEquivalent(Character(UnicodeScalar(NSF6FunctionKey)!)), modifiers: [])
                .disabled(editor == nil || run?.phase == .running || run?.phase == .waiting)
            Button("Pause") { run?.pause() }
                .disabled(run?.phase != .running)
            Button("Stop") { run?.stop() }
                .keyboardShortcut(".")
                .disabled(run?.isActive != true)
            Divider()
            Button("Toggle Breakpoint") { editor?.toggleBreakpoint() }
                .keyboardShortcut("\\")
                .disabled(editor?.selectedNodes.isEmpty ?? true)
            Button(editor?.document?.wrappedValue.space.run.breakpointsEnabled == false ? "Activate Breakpoints" : "Deactivate Breakpoints") {
                editor?.document?.wrappedValue.space.run.breakpointsEnabled.toggle()
            }
            .keyboardShortcut("y")
            .disabled(editor == nil)
            Divider()
            Button(editor?.showConsole == true ? "Hide Run Console" : "Show Run Console") { editor?.showConsole.toggle() }
                .keyboardShortcut("y", modifiers: [.command, .shift])
                .disabled(editor == nil)
            Button("Clear Run Results") { run?.reset() }
                .disabled(run == nil || run?.isActive == true)
        }
        CommandMenu("Diagram") {
            Menu("Add Node") {
                ForEach(Layer.allCases) { layer in
                    Section("Layer \(layer.rawValue) · \(layer.title)") {
                        ForEach(NodeKind.kinds(in: layer)) { kind in
                            Button(kind.title) { editor?.add(kind) }
                        }
                    }
                }
            }
            .disabled(editor == nil)
            Divider()
            Button("Zoom In") { editor?.zoomIn() }
                .keyboardShortcut("+")
                .disabled(editor == nil)
            Button("Zoom Out") { editor?.zoomOut() }
                .keyboardShortcut("-")
                .disabled(editor == nil)
            Button("Actual Size") { editor?.zoom = 1 }
                .keyboardShortcut("0")
                .disabled(editor == nil)
            Divider()
            Button("Show Problems") { editor?.showIssues = true }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .disabled(editor == nil)
            Button("API Subscriptions…") { editor?.showSubscriptions = true }
                .keyboardShortcut("k", modifiers: [.command, .option])
                .disabled(editor == nil)
            Button(editor?.showInspector == true ? "Hide Inspector" : "Show Inspector") {
                editor?.showInspector.toggle()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .disabled(editor == nil)
        }
    }
}
