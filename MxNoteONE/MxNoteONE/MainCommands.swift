//
//  MainCommands.swift
//  MxNoteONE
//
//  Menu bar: File, Edit, Format, Tags, Insert, View, Go and Notebook menus.
//

import SwiftUI

struct MainCommands: Commands {
    @Environment(\.openWindow) private var openWindow

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
        }
        CommandGroup(replacing: .saveItem) {
            Button("Close Notebook") {
                if let nb = store.currentNotebook { store.closeNotebook(nb.id) }
            }
            Button("Reload Notebooks") { store.reloadAll() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .importExport) {
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
            Divider()
            Button("Copy Link to Page") {
                if let ref = store.currentPageRef { store.copyLink(ref) }
            }
            Button("Delete Page") {
                if let ref = store.currentPageRef { store.deletePage(ref) }
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
            Menu("Drawing Tool") {
                ForEach(CanvasTool.allCases) { tool in
                    Button(tool.title) { editor.tool = tool }
                }
            }
            Divider()
            Button("Recycle Bin") {
                store.recycleBinNotebookID = store.currentNotebook?.id
                openWindow(id: "trash")
            }
            Divider()
        }

        // Go
        CommandMenu("Go") {
            Button("Back") { store.goBack() }
                .keyboardShortcut("[")
            Button("Forward") { store.goForward() }
                .keyboardShortcut("]")
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
            Button("Rename Notebook…") {
                if let nb = store.currentNotebook { store.sheet = .renameNotebook(nb.id) }
            }
            Button("Show Notebook in Finder") {
                if let nb = store.currentNotebook { store.showInFinder(nb.id) }
            }
        }
    }
}
