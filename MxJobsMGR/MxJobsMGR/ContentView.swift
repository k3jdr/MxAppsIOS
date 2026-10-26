//
//  ContentView.swift
//  MxJobsMGR
//
//  One jobspace window: palette | diagram canvas | properties inspector.
//

import SwiftUI

struct ContentView: View {
    @Binding var document: JobspaceDocument
    @State private var editor = EditorState()
    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        // Re-run the checks when keys change in the subscriptions dialog.
        let _ = editor.keyRevision
        let _ = KeychainChanges.shared.revision  // re-run the key checks when MxAcctMGR may have changed a key
        let issues = Validator.check(document.space)
        let screen = JobsHelp.screen(document.space, editor: editor, problems: issues.count)
        NavigationSplitView {
            PaletteView(editor: editor)
                // Quick Help: what's under the pointer, at the bottom of the palette.
                .quickHelpDock()
                .fixedColumnMinimum(width: 210, height: 300)
                .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 320)
        } detail: {
            VStack(spacing: 0) {
                RunBar(settings: $document.space.run, editor: editor)
                Divider()
                // A plain stack with our own divider: AppKit split views re-entered layout
                // while a run changed the console and crashed (constraint update loop).
                VStack(spacing: 0) {
                    DiagramCanvas(space: $document.space, editor: editor, issues: issues)
                        .frame(maxHeight: .infinity)
                        .overlay(alignment: .top) {
                            // Keep a pending approval in view even with the console closed.
                            if !editor.showConsole, let prompt = editor.run.prompt {
                                RunPromptBanner(prompt: prompt, engine: editor.run)
                                    .background(.regularMaterial)
                            }
                        }
                    if editor.showConsole {
                        ConsoleDivider(height: $editor.consoleHeight)
                        RunConsole(editor: editor, space: document.space)
                            .frame(height: editor.consoleHeight)
                    }
                }
            }
            // The run bar's status, the console's height and a run prompt all change while a run goes;
            // none of them may change the column's minimum size (see fixedColumnMinimum). No minimum width: AppKit
            // already adds the sidebar and the inspector to it (see the window's minWidth below).
            .fixedColumnMinimum(width: 0, height: 400)
            .inspector(isPresented: $editor.showInspector) {
                    InspectorView(space: $document.space, editor: editor, issues: issues)
                        .fixedColumnMinimum(width: 300, height: 300)
                        .inspectorColumnWidth(min: 300, ideal: 360, max: 520)
                }
        }
        .navigationSubtitle(document.space.name)
        .toolbar {
            ToolbarItemGroup {
                Button("Zoom Out", systemImage: "minus.magnifyingglass") { editor.zoomOut() }
                    .quickHelp("Zoom Out", "Makes the diagram smaller (down to 40%).", shortcut: "⌘−")
                Text("\(Int((editor.zoom * 100).rounded()))%")
                    .monospacedDigit()
                    .frame(minWidth: 44)
                    .onTapGesture { editor.zoom = 1 }
                    .help("Click for 100%")
                    .quickHelp("Zoom", "The diagram's zoom. Click for actual size; pinch on the trackpad to zoom.", shortcut: "⌘0")
                Button("Zoom In", systemImage: "plus.magnifyingglass") { editor.zoomIn() }
                    .quickHelp("Zoom In", "Makes the diagram bigger (up to 200%).", shortcut: "⌘+")
            }
            ToolbarItemGroup {
                Button {
                    editor.showIssues.toggle()
                } label: {
                    Label(issues.isEmpty ? "No Problems" : "\(issues.count) Problems",
                          systemImage: issues.contains { $0.severity == .error } ? "xmark.octagon"
                                     : issues.isEmpty ? "checkmark.seal" : "exclamationmark.triangle")
                }
                .help("Configuration checks")
                .quickHelp("Problems", "Configuration checks: missing subscriptions or keys, unlinked steps, empty settings. Click one to go to the step or subscription.", shortcut: "⇧⌘K")
                .popover(isPresented: $editor.showIssues, arrowEdge: .bottom) {
                    Form {
                        if issues.isEmpty {
                            Label("No problems found", systemImage: "checkmark.seal").foregroundStyle(.green)
                        } else {
                            IssueList(issues: issues, editor: editor)
                        }
                    }
                    .formStyle(.grouped)
                    .frame(width: 420, height: min(420, CGFloat(issues.count) * 34 + 60))
                }
                Button("API Subscriptions", systemImage: "key.horizontal") { editor.showSubscriptions = true }
                    .help("Layer 3 API subscriptions and their secure accounts")
                    .quickHelp("API Subscriptions", JobsHelp.subscriptions.detail, shortcut: "⌥⌘K")
                Button("Inspector", systemImage: "sidebar.trailing") { editor.showInspector.toggle() }
                    .help("Show or hide the properties panel")
                    .quickHelp("Inspector", "Shows or hides the properties panel on the right: the selected step's settings, or the jobspace's.", shortcut: "⌥⌘I")
            }
        }
        .sheet(isPresented: $editor.showSubscriptions, onDismiss: { editor.keyRevision += 1 }) {
            SubscriptionsDialog(space: $document.space, editor: editor)
        }
        .sheet(isPresented: $editor.showKeyMove) { KeyMoveSheet(space: $document.space) }
        // MxAcctMGR ▸ Secure Accounts, read again whenever MxJobsMGR becomes active: link the subscriptions waiting
        // for an account, and offer to move the keys MxJobsMGR still keeps itself.
        .task(id: KeychainChanges.shared.revision) {
            await SecureAccountsList.shared.loadIfNeeded()
            var space = document.space
            if SecureAccountsList.shared.link(&space) { document.space = space }
            if !editor.keyMoveOffered, !KeyMove.pending(document.space).isEmpty {
                editor.keyMoveOffered = true
                editor.showKeyMove = true
            }
        }
        .focusedSceneValue(\.editor, editor)
        .onAppear {
            editor.document = $document
            EditorState.lastActive = editor
        }
        .onChange(of: activeState) { if activeState == .key { EditorState.lastActive = editor } }
        // The detail column runs under the sidebar and the inspector (macOS 26), and the width AppKit requires for it
        // counts the sidebar twice and the inspector once. A window narrower than that pushed the columns past its
        // edges, the canvas's scroll bars ended up under the inspector, and the next resize aborted with the constraint
        // update loop. 1160 = 2 × the sidebar's widest 320 + the inspector's widest 520.
        .frame(minWidth: 1160, minHeight: 620)
        .quickHelpScreen(screen.name, screen.item, selection: JobsHelp.selection(document.space, editor: editor))
    }
}

extension View {
    /// Gives a split-view column a constant minimum size. NavigationSplitView / .inspector columns take their
    /// minimum from their content; when that minimum changes during AppKit's constraint pass (run status text,
    /// console height, a prompt appearing, an inspector section) the split view re-invalidates layout, and AppKit
    /// aborts with "more Update Constraints in Window passes than there are views in the window". A flexible frame
    /// with explicit minimums reports the same minimum whatever the content does; content that needs more is clipped.
    func fixedColumnMinimum(width: CGFloat, height: CGFloat) -> some View {
        frame(minWidth: width, maxWidth: .infinity, minHeight: height, maxHeight: .infinity, alignment: .top)
            .clipped()
    }
}
