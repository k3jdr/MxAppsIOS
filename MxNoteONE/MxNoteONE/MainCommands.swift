//
//  MainCommands.swift
//  MxNoteONE
//
//  Menu bar: File, Edit, Format, Tags, Insert, View, Go and Notebook menus.
//

import SwiftUI

struct MainCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    private var store: NotebookStore { .shared }
    private var canvas: CanvasController? { store.canvas }
    private var editor: EditorState { store.editor }

    var body: some Commands {
        // File
        CommandGroup(replacing: .newItem) {
            Button("New Page") { store.addPageToCurrentSection() }
                .keyboardShortcut("n")
            Button("New Subpage") { store.addPageToCurrentSection(subpage: true) }
                .keyboardShortcut("n", modifiers: [.command, .option])
            Button("New Quick Note") { store.newQuickNote() }
                .keyboardShortcut("n", modifiers: [.command, .control])
            Menu("New Page from Template") {
                ForEach(PageTemplate.choices) { template in
                    Button(template.title) { store.addPageToCurrentSection(template: template) }
                }
            }
            Divider()
            Button("New Section") { store.addSectionToCurrentNotebook() }
                .keyboardShortcut("t")
            Button("New Section Group") {
                if let nb = store.currentNotebook { store.addSectionGroup(to: nb.id) }
            }
            Button("New Notebook…") { store.sheet = .newNotebook }
            Divider()
            Button("Open Notebook…") { store.openNotebookPanel() }
                .keyboardShortcut("o")
            Button("Save Notebook As…") {
                if let nb = store.currentNotebook { store.saveNotebookAs(nb.id) }
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            Menu("OneDrive") {
                Button("Open Notebook from OneDrive…") { store.sheet = .oneDriveOpen }
                if let nb = store.currentNotebook {
                    if nb.manifest.oneNote == nil {
                        Button("Save “\(nb.name)” to OneDrive") { OneDriveSync.shared.save(nb) }
                    } else {
                        Button("Sync “\(nb.name)”") { OneDriveSync.shared.sync(nb) }
                    }
                }
                Button("Sync All OneDrive Notebooks") { OneDriveSync.shared.syncAll() }
                    .keyboardShortcut("s", modifiers: [.command, .control])
                Divider()
                if OneDriveAuth.shared.isSignedIn {
                    Button("Sign Out of \(OneDriveAuth.shared.account ?? "OneDrive")") { OneDriveAuth.shared.signOut() }
                } else {
                    Button("Sign In…") { OneDriveSync.shared.signIn() }
                }
            }
        }
        CommandGroup(replacing: .saveItem) {
            Button("Close Notebook") {
                if let nb = store.currentNotebook { store.closeNotebook(nb.id) }
            }
            Button("Reload Notebooks") { store.reloadAll() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .importExport) {
            Menu("Import") {
                Button("OneNote Package (.onepkg)…") { ImportActivity.shared.importPackage() }
                Button("OneNote Sections (.one)…") { ImportActivity.shared.importSections() }
                Button("OneNote Notebook Folder…") { ImportActivity.shared.importFolder() }
            }
            Divider()
            Button("Export Page as PDF…") { PageExporter.exportCurrentPagePDF() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            Button("Export Section as PDF…") {
                if let section = store.selectedSection { PageExporter.exportSectionPDF(section) }
            }
            Button("Export Page as Markdown…") { PageExporter.exportMarkdown() }
        }
        CommandGroup(replacing: .printItem) {
            Button("Print Page…") { PageExporter.printPage() }
                .keyboardShortcut("p")
        }

        // Edit
        CommandGroup(after: .pasteboard) {
            Button("Paste as Plain Text") { TextFormatter.pastePlainText() }
                .keyboardShortcut("v", modifiers: [.command, .option, .shift])
            Button("Paste with Formatting") { TextFormatter.pasteWithFormatting() }
            Divider()
            Button("Copy Link to this Page") {
                if let ref = store.currentPageRef { store.copyLink(ref) }
            }
            Button("Delete Page") {
                if let ref = store.currentPageRef { store.deletePage(ref) }
            }
            Divider()
            Button(ClipboardModel.shared.isShown ? "Hide Clipboard" : "Show Clipboard") {
                if ClipboardModel.shared.isShown { dismissWindow(id: "clipboard") } else { openWindow(id: "clipboard") }
            }
        }
        CommandGroup(replacing: .textEditing) {
            Button("Find on Page") {
                editor.showFindBar = true
                editor.findFocusRequest += 1
            }
            .keyboardShortcut("f")
            Button("Find Next") { canvas?.findNext() }
                .keyboardShortcut("g")
            Button("Find Previous") { canvas?.findNext(forward: false) }
                .keyboardShortcut("g", modifiers: [.command, .shift])
            Divider()
            Button("Check Spelling (F7)") { SpellCheck.run() }
            Divider()
            Button("Search All Notebooks") { store.focusSearchRequest += 1 }
                .keyboardShortcut("e")
        }

        // Format
        CommandMenu("Format") {
            Button("Bold") { TextFormatter.toggleBold() }
                .keyboardShortcut("b")
            Button("Italic") { TextFormatter.toggleItalic() }
                .keyboardShortcut("i")
            Button("Underline") { TextFormatter.toggleUnderline() }
                .keyboardShortcut("u")
            Button("Strikethrough") { TextFormatter.toggleStrikethrough() }
                .keyboardShortcut("-", modifiers: [.command, .control])
            Button("Superscript") { TextFormatter.toggleScript(1) }
                .keyboardShortcut("=", modifiers: [.command, .control])
            Button("Subscript") { TextFormatter.toggleScript(-1) }
                .keyboardShortcut("=", modifiers: [.command, .control, .shift])
            Button("Highlight") { TextFormatter.setHighlight(Palette.highlight[0].1) }
                .keyboardShortcut("h", modifiers: [.command, .control])
            Button("Bigger") { TextFormatter.stepFontSize(2) }
                .keyboardShortcut(">", modifiers: [.command, .shift])
            Button("Smaller") { TextFormatter.stepFontSize(-2) }
                .keyboardShortcut("<", modifiers: [.command, .shift])
            Button("Show Fonts") { NSFontManager.shared.orderFrontFontPanel(nil) }
            Button("Notebook Fonts…") {
                if let nb = store.currentNotebook { store.sheet = .notebookFonts(nb.id) }
            }
            Divider()
            Menu("Styles") {
                Button(TextStyleKind.heading1.title) { TextFormatter.applyStyle(.heading1) }
                    .keyboardShortcut("1", modifiers: [.command, .option])
                Button(TextStyleKind.heading2.title) { TextFormatter.applyStyle(.heading2) }
                    .keyboardShortcut("2", modifiers: [.command, .option])
                Button(TextStyleKind.heading3.title) { TextFormatter.applyStyle(.heading3) }
                    .keyboardShortcut("3", modifiers: [.command, .option])
                Button(TextStyleKind.heading4.title) { TextFormatter.applyStyle(.heading4) }
                    .keyboardShortcut("4", modifiers: [.command, .option])
                Button(TextStyleKind.normal.title) { TextFormatter.applyStyle(.normal) }
                    .keyboardShortcut("0", modifiers: [.command, .option])
                Divider()
                Button(TextStyleKind.title.title) { TextFormatter.applyStyle(.title) }
                Button(TextStyleKind.quote.title) { TextFormatter.applyStyle(.quote) }
                Button(TextStyleKind.code.title) { TextFormatter.applyStyle(.code) }
            }
            Divider()
            Button("Bullets") { TextFormatter.toggleBullets() }
                .keyboardShortcut(".")
            Button("Numbering") { TextFormatter.toggleNumbering() }
                .keyboardShortcut("/")
            Button("Indent") { TextFormatter.indent(1) }
            Button("Outdent") { TextFormatter.indent(-1) }
            Menu("Alignment") {
                Button("Align Left") { TextFormatter.setAlignment(.left) }
                Button("Center") { TextFormatter.setAlignment(.center) }
                Button("Align Right") { TextFormatter.setAlignment(.right) }
                Button("Justify") { TextFormatter.setAlignment(.justified) }
            }
            Divider()
            Button("Format as Code") { TextFormatter.formatAsCode() }
                .keyboardShortcut("c", modifiers: [.command, .option])
            Menu("Format as Code in") {
                ForEach(CodeLanguage.allCases.filter { $0 != .auto }) { language in
                    Button(language.title) { TextFormatter.formatAsCode(language) }
                }
            }
            Menu("Code Theme") {
                Button("VS Code Dark+") { TextFormatter.setCodeTheme(.darkPlus) }
                Button("VS Code Light+") { TextFormatter.setCodeTheme(.lightPlus) }
            }
            Divider()
            Button("Clear Formatting") { TextFormatter.clearFormatting() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
        }

        // Tags
        CommandMenu("Tags") {
            ForEach(TagKind.allCases) { kind in
                Button("\(kind.symbol)  \(kind.title)") { TextFormatter.toggleTag(kind) }
                    .keyboardShortcut(KeyEquivalent(kind.shortcutDigit))
            }
            Divider()
            Button("Remove Tag") { TextFormatter.removeTags() }
                .keyboardShortcut("0")
            Divider()
            Button("Tag Summary") { openWindow(id: "tags") }
                .keyboardShortcut("t", modifiers: [.command, .shift])
        }

        // Insert
        CommandMenu("Insert") {
            Button("Table…") { store.sheet = .insertTable }
                .keyboardShortcut("t", modifiers: [.command, .control])
            Button("Music Score") { canvas?.insertScore() }
            Button("Piano Score (Grand Staff)") { canvas?.insertScore(piano: true) }
            Button("Drum Score (Percussion Staff)") { canvas?.insertScore(drums: true) }
            Button("Lead Sheet") { canvas?.insertScore(leadSheet: true) }
            Button("Chord Chart (Slashes)") { canvas?.insertScore(chordChart: true) }
            Divider()
            Button("Diagram (draw.io)") { canvas?.newDiagram() }
                .keyboardShortcut("d", modifiers: [.command, .control])
            Button("Diagram from Template…") { canvas?.newDiagram(template: true) }
            Button("Diagram File (.drawio.svg)…") { canvas?.chooseDiagramFile(link: false) }
            Button("Link Diagram File…") { canvas?.chooseDiagramFile(link: true) }
            Divider()
            Button("Map") { canvas?.insertMap() }
                .keyboardShortcut("m", modifiers: [.command, .control])
            Divider()
            Button("DBML Diagram") { canvas?.insertDBML() }
                .keyboardShortcut("b", modifiers: [.command, .control])
            Button("DBML Diagram from File…") { canvas?.importDBMLFile() }
            Divider()
            Button("3D Model") { canvas?.insertModel() }
                .keyboardShortcut("3", modifiers: [.command, .control])
            Button("3D Model (Sample Bracket)") { canvas?.insertModel(sample: true) }
            Button("3D Model from STL / OBJ…") { canvas?.importModel() }
            Button("3D Model from FreeCAD, STEP or IGES…") { canvas?.importFreeCADModel() }
            Divider()
            Button("Music Score from MusicXML…") { canvas?.chooseMusicXML() }
            Button("Picture…") { canvas?.choosePictures() }
                .keyboardShortcut("p", modifiers: [.command, .control])
            Button("File Attachment…") { canvas?.chooseAttachments() }
            Button("Screen Clipping") { canvas?.screenClipping() }
                .keyboardShortcut("s", modifiers: [.command, .control, .shift])
            Button(editor.isRecording ? "Stop Recording" : "Record Audio") { AudioRecorder.shared.toggle() }
                .keyboardShortcut("r", modifiers: [.command, .control])
            Divider()
            Button("Link…") { store.beginInsertLink() }
                .keyboardShortcut("k")
            Button("Remove Link") { TextFormatter.removeLink() }
            Divider()
            Button("Date") { TextFormatter.insertDate() }
                .keyboardShortcut("d", modifiers: [.option, .shift])
            Button("Time") { TextFormatter.insertTime() }
                .keyboardShortcut("t", modifiers: [.option, .shift])
            Button("Date & Time") { TextFormatter.insertDateTime() }
                .keyboardShortcut("f", modifiers: [.option, .shift])
        }

        // View
        CommandGroup(before: .sidebar) {
            Button(editor.showRibbon ? "Hide Ribbon" : "Show Ribbon") { editor.showRibbon.toggle() }
                .keyboardShortcut("r", modifiers: [.command, .option])
            Toggle("Quick Help", isOn: Binding(get: { QuickHelp.shared.visible }, set: { QuickHelp.shared.visible = $0 }))
                .keyboardShortcut("/", modifiers: [.command, .option])
            Menu("Toolbar") {
                Toggle("Wrap Sections onto More Rows", isOn: Binding(get: { RibbonLayout.shared.wrap }, set: { RibbonLayout.shared.wrap = $0 }))
                Toggle("Compact Toolbar", isOn: Binding(get: { RibbonLayout.shared.compact }, set: { RibbonLayout.shared.compact = $0 }))
                    .keyboardShortcut("r", modifiers: [.command, .option, .shift])
                Divider()
                // Each tab's sections: in the toolbar, collapsed to a button, a floating palette, or hidden.
                ForEach(RibbonLayout.sections, id: \.0) { tab, titles in
                    Menu("\(tab.rawValue) Sections") {
                        ForEach(titles, id: \.self) { title in
                            Menu(title) { RibbonSectionMenu(key: RibbonLayout.key(tab, title), title: title) }
                        }
                        Divider()
                        Button("Collapse All \(tab.rawValue) Sections") { RibbonLayout.shared.collapseAll(in: tab) }
                        Button("Show All \(tab.rawValue) Sections") { RibbonLayout.shared.showAll(in: tab) }
                    }
                }
                Divider()
                Button("Show All Sections") { RibbonLayout.shared.showAll() }
                Button("Dock All Palettes") { RibbonLayout.shared.dockAllPalettes() }
            }
            Button(store.showFullPage ? "Exit Full Page View" : "Full Page View") { store.showFullPage.toggle() }
                .keyboardShortcut("f", modifiers: [.command, .option])
            Divider()
            Button("Zoom In") { canvas?.zoomIn() }
                .keyboardShortcut("=")
            Button("Zoom Out") { canvas?.zoomOut() }
                .keyboardShortcut("-")
            Button("Actual Size") { canvas?.zoom(to: 1) }
                .keyboardShortcut("0", modifiers: [.command, .control])
            Button("Page Width") { canvas?.zoomToPageWidth() }
            Divider()
            Menu("Page Color") {
                ForEach(PageColor.allCases) { color in
                    Button(color.title) { canvas?.setPageColor(color) }
                }
            }
            Menu("Rule Lines") {
                ForEach(RuleLines.allCases) { rules in
                    Button(rules.title) { canvas?.setRuleLines(rules) }
                }
            }
            Button(editor.snapToGrid ? "Turn Off Snap to Grid" : "Snap to Grid") { editor.snapToGrid.toggle() }
                .keyboardShortcut("g", modifiers: [.command, .control])
            Divider()
            Button("Recycle Bin") {
                store.recycleBinNotebookID = store.currentNotebook?.id
                openWindow(id: "trash")
            }
            Divider()
        }

        // Go
        CommandMenu("Go") {
            GoHistoryItems()
            Divider()
            Button("Previous Page") { store.selectAdjacentPage(-1) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            Button("Next Page") { store.selectAdjacentPage(1) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            Button("Previous Section") { store.selectAdjacentSection(-1) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            Button("Next Section") { store.selectAdjacentSection(1) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
        }

        // Notebook
        CommandMenu("Notebook") {
            Button("Notebook Scripts…") { openWindow(id: "scripts") }
                .keyboardShortcut("p", modifiers: [.command, .option])
            Menu("Run Script") {
                let scripts = store.currentNotebook.map(ScriptLibrary.scripts) ?? []
                ForEach(scripts, id: \.self) { url in
                    Button(url.deletingPathExtension().lastPathComponent) {
                        openWindow(id: "scripts")
                        ScriptsIDE.shared.notebookID = store.currentNotebook?.id
                        ScriptsIDE.shared.refresh()
                        ScriptsIDE.shared.run(url)
                    }
                }
                if scripts.isEmpty { Text("No scripts yet — Notebook Scripts… makes one") }
            }
            Divider()
            Button("Make Subpage") {
                if let ref = store.currentPageRef { store.changeLevel(ref, by: 1) }
            }
            .keyboardShortcut("]", modifiers: [.command, .option])
            Button("Promote Subpage") {
                if let ref = store.currentPageRef { store.changeLevel(ref, by: -1) }
            }
            .keyboardShortcut("[", modifiers: [.command, .option])
            Button("Move or Copy Page…") {
                if let ref = store.currentPageRef { store.sheet = .movePage(ref) }
            }
            .keyboardShortcut("m", modifiers: [.command, .shift])
            Button("Duplicate Page") {
                if let ref = store.currentPageRef { store.duplicatePage(ref) }
            }
            Divider()
            Button("Rename Section…") {
                if let section = store.selectedSection { store.sheet = .renameNode(section) }
            }
            Button("Password Protect Section…") {
                guard let section = store.selectedSection else { return }
                if store.node(section)?.isProtected == true {
                    store.sheet = .password(section, store.isLocked(section) ? .unlock : .change)
                } else {
                    store.sheet = .password(section, .set)
                }
            }
            Button("Lock All Protected Sections") { store.lockAll() }
                .keyboardShortcut("l", modifiers: [.command, .control])
            Divider()
            Button("Notebook Fonts…") {
                if let nb = store.currentNotebook { store.sheet = .notebookFonts(nb.id) }
            }
            Button("Find Missing OneNote Pictures…") { ImportActivity.shared.locateMissingPictures() }
            Divider()
            Button("Rename Notebook…") {
                if let nb = store.currentNotebook { store.sheet = .renameNotebook(nb.id) }
            }
            Button("Show Notebook in Finder") {
                if let nb = store.currentNotebook { store.showInFinder(nb.id) }
            }
        }
    }
}

/// Go ▸ Back, Forward and History — a view of their own, so they follow the history as it changes.
private struct GoHistoryItems: View {
    private var store: NotebookStore { .shared }

    var body: some View {
        // ⌃← / ⌃→; ⌘[ / ⌘] and a mouse's side buttons also work (PageNavigation).
        Button("Back") { store.goBack() }
            .keyboardShortcut(.leftArrow, modifiers: .control)
        Button("Forward") { store.goForward() }
            .keyboardShortcut(.rightArrow, modifiers: .control)
        Menu("History") {
            let back = store.backHistory.prefix(15)
            let forward = store.forwardHistory.prefix(15)
            ForEach(Array(forward.enumerated()).reversed(), id: \.offset) { i, ref in
                Button(store.historyTitle(ref)) { store.goForward(steps: i + 1) }
            }
            if let current = store.currentPageRef {
                Toggle(store.historyTitle(current), isOn: .constant(true)).disabled(true)
            }
            ForEach(Array(back.enumerated()), id: \.offset) { i, ref in
                Button(store.historyTitle(ref)) { store.goBack(steps: i + 1) }
            }
        }
        if store.navigationKeysTaken {
            Button("Free ⌃← ⌃→ from Mission Control…") { NavigationKeys.explain() }
        }
    }
}
