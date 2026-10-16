//
//  ContentView.swift
//  MxJobsWMS
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
        let _ = KeychainChanges.shared.revision  // re-run the key checks when a key is saved or removed
        let issues = Validator.check(document.space)
        NavigationSplitView {
            PaletteView(editor: editor)
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
            .inspector(isPresented: $editor.showInspector) {
                    InspectorView(space: $document.space, editor: editor, issues: issues)
                        .inspectorColumnWidth(min: 300, ideal: 360, max: 520)
                }
        }
        .navigationSubtitle(document.space.name)
        .toolbar {
            ToolbarItemGroup {
                Button("Zoom Out", systemImage: "minus.magnifyingglass") { editor.zoomOut() }
                Text("\(Int((editor.zoom * 100).rounded()))%")
                    .monospacedDigit()
                    .frame(minWidth: 44)
                    .onTapGesture { editor.zoom = 1 }
                    .help("Click for 100%")
                Button("Zoom In", systemImage: "plus.magnifyingglass") { editor.zoomIn() }
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
                    .help("Layer 3 API subscriptions and keys")
                Button("Inspector", systemImage: "sidebar.trailing") { editor.showInspector.toggle() }
                    .help("Show or hide the properties panel")
            }
        }
        .sheet(isPresented: $editor.showSubscriptions, onDismiss: { editor.keyRevision += 1 }) {
            SubscriptionsDialog(space: $document.space, editor: editor)
        }
        .focusedSceneValue(\.editor, editor)
        .onAppear {
            editor.document = $document
            EditorState.lastActive = editor
        }
        .onChange(of: activeState) { if activeState == .key { EditorState.lastActive = editor } }
        .frame(minWidth: 1000, minHeight: 620)
    }
}
