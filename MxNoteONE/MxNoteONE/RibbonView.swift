//
//  RibbonView.swift
//  MxNoteONE
//
//  The ribbon above the page: Home (text formatting, styles, tags),
//  Insert (tables, pictures, files, screen clippings, recordings, links,
//  time stamps, templates), Draw (pens, highlighters, shapes, eraser) and
//  View (page colour, rule lines, zoom, full page view).
//

import SwiftUI

struct RibbonView: View {
    @Bindable private var editor = NotebookStore.shared.editor

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(RibbonTab.allCases) { tab in
                    Button {
                        editor.ribbonTab = tab
                    } label: {
                        Text(tab.rawValue)
                            .font(.system(size: 12, weight: editor.ribbonTab == tab ? .semibold : .regular))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)
                            .background(editor.ribbonTab == tab ? Color.accentColor.opacity(0.16) : .clear,
                                        in: RoundedRectangle(cornerRadius: 5))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                }
                Spacer()
                if editor.isRecording {
                    Button {
                        AudioRecorder.shared.stop()
                    } label: {
                        Label("Stop Recording  \(Duration.seconds(editor.recordingSeconds).formatted(.time(pattern: .minuteSecond)))",
                              systemImage: "stop.circle.fill")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.borderless)
                    .focusable(false)
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)
            .padding(.bottom, 2)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 6) {
                    switch editor.ribbonTab {
                    case .home: HomeRibbon()
                    case .insert: InsertRibbon()
                    case .draw: DrawRibbon()
                    case .view: ViewRibbon()
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
            }
        }
        .background(.bar)
    }
}

// MARK: - Building blocks

struct RibbonButton: View {
    let title: String
    let symbol: String
    var large = false
    var active = false
    let action: () -> Void

    init(_ title: String, _ symbol: String, large: Bool = false, active: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.large = large
        self.active = active
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Group {
                if large {
                    VStack(spacing: 2) {
                        Image(systemName: symbol)
                            .font(.system(size: 17))
                            .frame(height: 22)
                        Text(title)
                            .font(.system(size: 10))
                            .lineLimit(1)
                    }
                    .frame(minWidth: 50)
                    .padding(.horizontal, 2)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 13))
                        .frame(width: 26, height: 22)
                }
            }
            .background(active ? Color.accentColor.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(title)
    }
}

struct RibbonGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 6) {
            VStack(spacing: 3) {
                HStack(spacing: 2) { content }
                    .frame(minHeight: 40)
                Text(title)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            Divider().frame(height: 46)
        }
    }
}

/// A compact menu for the ribbon.
struct RibbonMenu<Content: View>: View {
    let title: String
    let symbol: String
    var showTitle = true
    @ViewBuilder let content: Content

    init(_ title: String, _ symbol: String, showTitle: Bool = true, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.showTitle = showTitle
        self.content = content()
    }

    var body: some View {
        Menu {
            content
        } label: {
            if showTitle {
                Label(title, systemImage: symbol)
            } else {
                Image(systemName: symbol)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .focusable(false)
        .help(title)
    }
}

private func swatch(_ color: NSColor) -> Image {
    Image(nsImage: Palette.swatch(color))
}

// MARK: - Home

struct HomeRibbon: View {
    private static let sizes: [CGFloat] = [8, 9, 10, 11, 12, 14, 16, 18, 20, 24, 28, 32, 36, 48, 72]
    private static let common = ["Helvetica Neue", "Avenir Next", "Calibri", "Arial", "Georgia", "Times New Roman",
                                 "Palatino", "Optima", "Gill Sans", "Futura", "Verdana", "Menlo", "Courier New"]

    private var families: [String] {
        let available = Set(NSFontManager.shared.availableFontFamilies)
        return Self.common.filter(available.contains)
    }

    var body: some View {
        RibbonGroup("Font") {
            RibbonMenu("Font", "textformat") {
                ForEach(families, id: \.self) { family in
                    Button(family) { TextFormatter.setFontFamily(family) }
                }
                Divider()
                Menu("All Fonts") {
                    ForEach(NSFontManager.shared.availableFontFamilies, id: \.self) { family in
                        Button(family) { TextFormatter.setFontFamily(family) }
                    }
                }
                Divider()
                Button("Show Fonts…") { NSFontManager.shared.orderFrontFontPanel(nil) }
            }
            RibbonMenu("Size", "textformat.size") {
                ForEach(Self.sizes, id: \.self) { size in
                    Button("\(Int(size))") { TextFormatter.setFontSize(size) }
                }
            }
            RibbonButton("Increase Font Size", "textformat.size.larger") { TextFormatter.stepFontSize(2) }
            RibbonButton("Decrease Font Size", "textformat.size.smaller") { TextFormatter.stepFontSize(-2) }
        }
        RibbonGroup("Format") {
            RibbonButton("Bold (⌘B)", "bold") { TextFormatter.toggleBold() }
            RibbonButton("Italic (⌘I)", "italic") { TextFormatter.toggleItalic() }
            RibbonButton("Underline (⌘U)", "underline") { TextFormatter.toggleUnderline() }
            RibbonButton("Strikethrough", "strikethrough") { TextFormatter.toggleStrikethrough() }
            RibbonButton("Superscript", "textformat.superscript") { TextFormatter.toggleScript(1) }
            RibbonButton("Subscript", "textformat.subscript") { TextFormatter.toggleScript(-1) }
            RibbonMenu("Highlight", "highlighter", showTitle: false) {
                ForEach(Palette.highlight, id: \.0) { name, color in
                    Button { TextFormatter.setHighlight(color) } label: { Label { Text(name) } icon: { swatch(color) } }
                }
                Divider()
                Button("No Highlight") { TextFormatter.setHighlight(nil) }
            }
            RibbonMenu("Font Color", "paintpalette", showTitle: false) {
                ForEach(Palette.text, id: \.0) { name, color in
                    Button { TextFormatter.setTextColor(color) } label: { Label { Text(name) } icon: { swatch(color) } }
                }
            }
            RibbonButton("Clear Formatting", "text.badge.xmark") { TextFormatter.clearFormatting() }
        }
        RibbonGroup("Paragraph") {
            RibbonButton("Bullets (⌘.)", "list.bullet") { TextFormatter.toggleBullets() }
            RibbonButton("Numbering (⌘/)", "list.number") { TextFormatter.toggleNumbering() }
            RibbonButton("Outdent", "decrease.indent") { TextFormatter.indent(-1) }
            RibbonButton("Indent", "increase.indent") { TextFormatter.indent(1) }
            RibbonMenu("Alignment", "text.alignleft", showTitle: false) {
                Button { TextFormatter.setAlignment(.left) } label: { Label("Align Left", systemImage: "text.alignleft") }
                Button { TextFormatter.setAlignment(.center) } label: { Label("Center", systemImage: "text.aligncenter") }
                Button { TextFormatter.setAlignment(.right) } label: { Label("Align Right", systemImage: "text.alignright") }
                Button { TextFormatter.setAlignment(.justified) } label: { Label("Justify", systemImage: "text.justify") }
                Divider()
                Button("Line Spacing 1.0") { TextFormatter.setLineSpacing(1) }
                Button("Line Spacing 1.15") { TextFormatter.setLineSpacing(1.15) }
                Button("Line Spacing 1.5") { TextFormatter.setLineSpacing(1.5) }
                Button("Line Spacing 2.0") { TextFormatter.setLineSpacing(2) }
            }
        }
        RibbonGroup("Styles") {
            RibbonMenu("Styles", "textformat.alt") {
                ForEach(TextStyleKind.allCases) { style in
                    Button(style.title) { TextFormatter.applyStyle(style) }
                }
            }
        }
        RibbonGroup("Tags") {
            RibbonButton("To Do (⌘1)", "checkmark.square") { TextFormatter.toggleTag(.todo) }
            RibbonMenu("Tags", "tag") {
                ForEach(TagKind.allCases) { kind in
                    Button("\(kind.symbol)  \(kind.title)    ⌘\(String(kind.shortcutDigit))") { TextFormatter.toggleTag(kind) }
                }
                Divider()
                Button("Remove Tag") { TextFormatter.removeTags() }
            }
        }
    }
}

// MARK: - Insert

struct InsertRibbon: View {
    private var store: NotebookStore { .shared }
    private var canvas: CanvasController? { store.canvas }
    @Bindable private var editor = NotebookStore.shared.editor

    var body: some View {
        RibbonGroup("Tables") {
            RibbonMenu("Table", "tablecells") {
                ForEach(Array([(2, 2), (3, 3), (4, 3), (4, 4), (5, 5), (8, 4)].enumerated()), id: \.offset) { _, size in
                    Button("\(size.0) rows × \(size.1) columns") { canvas?.insertTable(rows: size.0, columns: size.1) }
                }
                Divider()
                Button("Insert Table…") { store.sheet = .insertTable }
            }
        }
        RibbonGroup("Files") {
            RibbonButton("Picture", "photo", large: true) { canvas?.choosePictures() }
            RibbonButton("File", "paperclip", large: true) { canvas?.chooseAttachments() }
            RibbonButton("Screen Clipping", "camera.viewfinder", large: true) { canvas?.screenClipping() }
        }
        RibbonGroup("Recording") {
            RibbonButton(editor.isRecording ? "Stop" : "Record Audio", editor.isRecording ? "stop.circle" : "mic",
                         large: true, active: editor.isRecording) { AudioRecorder.shared.toggle() }
        }
        RibbonGroup("Links") {
            RibbonButton("Link", "link", large: true) { store.beginInsertLink() }
        }
        RibbonGroup("Time Stamp") {
            RibbonButton("Date", "calendar", large: true) { TextFormatter.insertDate() }
            RibbonButton("Time", "clock", large: true) { TextFormatter.insertTime() }
            RibbonButton("Date & Time", "calendar.badge.clock", large: true) { TextFormatter.insertDateTime() }
        }
        RibbonGroup("Pages") {
            RibbonMenu("Page Templates", "doc.on.doc") {
                ForEach(PageTemplate.choices) { template in
                    Button {
                        store.addPageToCurrentSection(template: template)
                    } label: {
                        Label(template.title, systemImage: template.symbol)
                    }
                }
            }
        }
    }
}

// MARK: - Draw

struct DrawRibbon: View {
    @Bindable private var editor = NotebookStore.shared.editor
    private static let widths: [Double] = [1, 2, 3, 5, 8, 12]

    var body: some View {
        RibbonGroup("Tools") {
            ForEach([CanvasTool.type, .pen, .highlighter, .eraser]) { tool in
                RibbonButton(tool.title, tool.symbol, large: true, active: editor.tool == tool) { editor.tool = tool }
            }
        }
        RibbonGroup("Shapes") {
            ForEach([CanvasTool.line, .arrow, .rectangle, .ellipse]) { tool in
                RibbonButton(tool.title + " (⇧ to constrain)", tool.symbol, active: editor.tool == tool) { editor.tool = tool }
            }
        }
        RibbonGroup("Pen Color") {
            ForEach(Palette.pen, id: \.0) { name, color in
                colorDot(color, selected: editor.penColor == RGBA(color), help: name) {
                    editor.penColor = RGBA(color)
                    if editor.tool == .type || editor.tool == .eraser || editor.tool == .highlighter { editor.tool = .pen }
                }
            }
        }
        RibbonGroup("Thickness") {
            RibbonMenu("\(editor.penWidth.formatted()) pt", "lineweight") {
                ForEach(Self.widths, id: \.self) { width in
                    Button("\(width.formatted()) pt") { editor.penWidth = width }
                }
            }
        }
        RibbonGroup("Highlighter") {
            ForEach(Palette.highlight.prefix(6), id: \.0) { name, color in
                let rgba = RGBA(color.withAlphaComponent(0.45))
                colorDot(color, selected: editor.highlighterColor == rgba, help: name) {
                    editor.highlighterColor = rgba
                    editor.tool = .highlighter
                }
            }
        }
        RibbonGroup("Ink") {
            RibbonButton("Clear All Ink", "trash", large: true) { NotebookStore.shared.canvas?.clearInk() }
        }
    }

    private func colorDot(_ color: NSColor, selected: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Circle()
                .fill(Color(nsColor: color))
                .frame(width: 16, height: 16)
                .overlay(Circle().stroke(Color.primary.opacity(0.25), lineWidth: 0.5))
                .padding(3)
                .overlay(Circle().stroke(selected ? Color.accentColor : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(help)
    }
}

// MARK: - View

struct ViewRibbon: View {
    @Bindable private var editor = NotebookStore.shared.editor
    @Environment(\.openWindow) private var openWindow
    private var store: NotebookStore { .shared }
    private var canvas: CanvasController? { store.canvas }

    var body: some View {
        RibbonGroup("Page Setup") {
            RibbonMenu("Page Color", "paintpalette") {
                ForEach(PageColor.allCases) { color in
                    Button { canvas?.setPageColor(color) } label: { Label { Text(color.title) } icon: { swatch(color.nsColor) } }
                }
            }
            RibbonMenu("Rule Lines", "line.3.horizontal") {
                ForEach(RuleLines.allCases) { rules in
                    Button(rules.title) { canvas?.setRuleLines(rules) }
                }
            }
        }
        RibbonGroup("Zoom") {
            RibbonButton("Zoom Out (⌘-)", "minus.magnifyingglass") { canvas?.zoomOut() }
            Text("\(Int((editor.zoom * 100).rounded()))%")
                .font(.system(size: 11).monospacedDigit())
                .frame(width: 42)
            RibbonButton("Zoom In (⌘=)", "plus.magnifyingglass") { canvas?.zoomIn() }
            RibbonButton("Actual Size", "1.magnifyingglass") { canvas?.zoom(to: 1) }
            RibbonButton("Page Width", "arrow.left.and.right") { canvas?.zoomToPageWidth() }
        }
        RibbonGroup("Views") {
            RibbonButton("Full Page View", "arrow.up.left.and.arrow.down.right", large: true, active: store.showFullPage) {
                store.showFullPage.toggle()
            }
            RibbonButton("Tag Summary", "tag", large: true) { openWindow(id: "tags") }
            RibbonButton("Recycle Bin", "trash", large: true) {
                store.recycleBinNotebookID = store.currentNotebook?.id
                openWindow(id: "trash")
            }
        }
    }
}
