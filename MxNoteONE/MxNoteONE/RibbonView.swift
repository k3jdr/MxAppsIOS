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
    @Bindable private var layout = RibbonLayout.shared
    private static var restored = false

    /// The tab shown (Table and Score only while a table or score is being worked on).
    private var shownTab: RibbonTab {
        switch editor.ribbonTab {
        case .table where !editor.tableActive, .score where !editor.scoreActive: .home
        default: editor.ribbonTab
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(RibbonTab.allCases.filter { ($0 != .table || editor.tableActive) && ($0 != .score || editor.scoreActive) }) { tab in
                    Button {
                        editor.ribbonTab = tab
                    } label: {
                        Text(tab.rawValue)
                            .font(.system(size: 12, weight: editor.ribbonTab == tab ? .semibold : .regular))
                            .foregroundStyle(tab == .table || tab == .score ? Color.accentColor : Color.primary)
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
                // Arranging the toolbar: wrap, compact, and where each section goes.
                Menu {
                    RibbonOptionsMenu(tab: shownTab)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .focusable(false)
                .tip("Toolbar Options", "Wrap the toolbar onto more rows, make it compact, and show, collapse, float or hide each section.")
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)
            .padding(.bottom, 2)

            Group {
                if layout.wrap {
                    // Sections wrap onto more rows: everything fits the window.
                    RibbonFlow(spacing: 6, rowSpacing: layout.compact ? 2 : 4) {
                        RibbonTabContent(tab: shownTab)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ScrollView(.horizontal, showsIndicators: true) {
                        HStack(alignment: .top, spacing: 6) {
                            RibbonTabContent(tab: shownTab)
                        }
                    }
                }
            }
            .environment(\.ribbonTab, shownTab)
            .padding(.horizontal, 10)
            .padding(.vertical, layout.compact ? 2 : 5)
        }
        .background(.bar)
        .onAppear {
            // Palettes left floating last time open again.
            guard !Self.restored else { return }
            Self.restored = true
            DispatchQueue.main.async { RibbonLayout.shared.restorePalettes() }
        }
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
                if large && !RibbonLayout.shared.compact {
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
        .tip(title)
    }
}

struct RibbonGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    @Environment(\.ribbonTab) private var tab
    @Environment(\.ribbonPaletteKey) private var paletteKey
    @Bindable private var layout = RibbonLayout.shared
    @State private var showingPopover = false

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    private var key: String { RibbonLayout.key(tab ?? .home, title) }

    var body: some View {
        if let paletteKey {
            // A floating palette shows only its own section.
            if paletteKey == key {
                HStack(spacing: 2) { content }
                    .frame(minHeight: 30)
            }
        } else {
            switch layout.state(key) {
            case .docked:
                docked
            case .collapsed:
                collapsed
            case .floating, .hidden:
                EmptyView()
            }
        }
    }

    private var docked: some View {
        HStack(spacing: 6) {
            VStack(spacing: 3) {
                HStack(spacing: 2) { content }
                    .frame(minHeight: layout.compact ? 26 : 40)
                if !layout.compact {
                    Text(title)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
            Divider().frame(height: layout.compact ? 26 : 46)
        }
        .contentShape(Rectangle())
        .contextMenu { sectionMenu }
        .onHover { QuickHelp.shared.hoverSection(title, tab: tab, $0) }
    }

    /// One button for the whole section; its tools open under it.
    private var collapsed: some View {
        HStack(spacing: 6) {
            Button {
                showingPopover.toggle()
            } label: {
                VStack(spacing: 2) {
                    HStack(spacing: 2) {
                        Text(title).font(.system(size: 11))
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(showingPopover ? 0.12 : 0.05), in: RoundedRectangle(cornerRadius: 5))
                }
                .frame(minHeight: layout.compact ? 26 : 40)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .tip("\(title) — click for its tools")
            .popover(isPresented: $showingPopover, arrowEdge: .bottom) {
                HStack(spacing: 2) { content }
                    .padding(8)
            }
            Divider().frame(height: layout.compact ? 26 : 46)
        }
        .contextMenu { sectionMenu }
        .onHover { QuickHelp.shared.hoverSection(title, tab: tab, $0) }
    }

    @ViewBuilder private var sectionMenu: some View {
        RibbonSectionMenu(key: key, title: "\(title) Section")
        Divider()
        Button("Show All Sections") { layout.showAll(in: tab) }
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
        .tip(title)
    }
}

/// A dropdown box showing a value (the current font or size); its menu changes it.
struct RibbonField<Content: View>: View {
    let text: String
    let width: CGFloat
    let help: String
    @ViewBuilder let content: Content

    init(_ text: String, width: CGFloat, help: String, @ViewBuilder content: () -> Content) {
        self.text = text
        self.width = width
        self.help = help
        self.content = content()
    }

    var body: some View {
        Menu {
            content
        } label: {
            Text(text)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: width, alignment: .leading)
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .fixedSize()
        .focusable(false)
        .tip(help)
    }
}

private func swatch(_ color: NSColor) -> Image {
    Image(nsImage: Palette.swatch(color))
}

// MARK: - Home

struct HomeRibbon: View {
    private static let sizes: [CGFloat] = [8, 9, 10, 11, 12, 14, 16, 18, 20, 24, 28, 32, 36, 48, 72]
    private static let common = ["Helvetica Neue", "Avenir Next", "Aptos", "Calibri", "Segoe UI", "Arial", "Verdana",
                                 "Georgia", "Cambria", "Times New Roman", "Palatino", "Optima", "Gill Sans", "Futura",
                                 "Menlo", "Consolas", "Courier New"]

    private var families: [String] {
        let available = Set(FontLibrary.shared.families)
        return Self.common.filter(available.contains)
    }

    @Bindable private var editor = NotebookStore.shared.editor

    private var sizeText: String {
        guard let size = editor.fontSize else { return "–" }
        return size == size.rounded() ? String(Int(size)) : String(format: "%.1f", size)
    }

    @ViewBuilder
    private func fontItem(_ family: String) -> some View {
        Button {
            TextFormatter.setFontFamily(family)
        } label: {
            if family == editor.fontFamily { Label(family, systemImage: "checkmark") } else { Text(family) }
        }
    }

    var body: some View {
        RibbonGroup("Font") {
            RibbonField(editor.fontFamily ?? "Mixed", width: 132, help: "Font") {
                ForEach(families, id: \.self) { fontItem($0) }
                if let family = editor.fontFamily, !families.contains(family) {
                    Divider()
                    fontItem(family)
                }
                Divider()
                Menu("All Fonts") {
                    ForEach(FontLibrary.shared.families, id: \.self) { fontItem($0) }
                }
                Divider()
                Button("Show Fonts…") { NSFontManager.shared.orderFrontFontPanel(nil) }
            }
            RibbonField(sizeText, width: 34, help: "Font Size") {
                ForEach(Self.sizes, id: \.self) { size in
                    Button {
                        TextFormatter.setFontSize(size)
                    } label: {
                        if size == editor.fontSize { Label("\(Int(size))", systemImage: "checkmark") } else { Text("\(Int(size))") }
                    }
                }
            }
            RibbonButton("Increase Font Size", "textformat.size.larger") { TextFormatter.stepFontSize(2) }
            RibbonButton("Decrease Font Size", "textformat.size.smaller") { TextFormatter.stepFontSize(-2) }
        }
        RibbonGroup("Format") {
            RibbonButton("Bold (⌘B)", "bold", active: editor.isBold) { TextFormatter.toggleBold() }
            RibbonButton("Italic (⌘I)", "italic", active: editor.isItalic) { TextFormatter.toggleItalic() }
            RibbonButton("Underline (⌘U)", "underline", active: editor.isUnderline) { TextFormatter.toggleUnderline() }
            RibbonButton("Strikethrough", "strikethrough", active: editor.isStrikethrough) { TextFormatter.toggleStrikethrough() }
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
            RibbonMenu("Code", "chevron.left.forwardslash.chevron.right") {
                Button("Format as Code (⌥⌘C)") { TextFormatter.formatAsCode() }
                Divider()
                ForEach(CodeLanguage.allCases.filter { $0 != .auto }) { language in
                    Button(language.title) { TextFormatter.formatAsCode(language) }
                }
                Divider()
                Button("Theme: VS Code Dark+") { TextFormatter.setCodeTheme(.darkPlus) }
                Button("Theme: VS Code Light+") { TextFormatter.setCodeTheme(.lightPlus) }
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
        RibbonGroup("Music") {
            RibbonButton("Score", "music.note.list", large: true) { canvas?.insertScore() }
            RibbonButton("Piano", "pianokeys", large: true) { canvas?.insertScore(piano: true) }
            RibbonButton("Drums", "circle.grid.cross", large: true) { canvas?.insertScore(drums: true) }
            RibbonButton("Lead Sheet", "music.note.list", large: true) { canvas?.insertScore(leadSheet: true) }
            RibbonButton("MusicXML", "square.and.arrow.down", large: true) { canvas?.chooseMusicXML() }
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

/// The Draw tab: draw.io diagrams (the editor VS Code's draw.io extension uses), saved as .drawio.svg.
struct DrawRibbon: View {
    @Bindable private var editor = NotebookStore.shared.editor
    @Bindable private var download = DrawioDownload.shared
    @AppStorage(DrawioSource.themeKey) private var theme = "kennedy"
    @AppStorage(DrawioSource.modeKey) private var offline = false
    private var canvas: CanvasController? { NotebookStore.shared.canvas }

    var body: some View {
        let _ = editor.scoreInputChanged
        RibbonGroup("Diagram") {
            RibbonButton("New Diagram", "square.on.square.dashed", large: true) { canvas?.newDiagram() }
            RibbonButton("From Template", "rectangle.3.group", large: true) { canvas?.newDiagram(template: true) }
            RibbonButton("Insert File", "doc.badge.plus", large: true) { canvas?.chooseDiagramFile(link: false) }
            RibbonButton("Link File", "link.badge.plus", large: true) { canvas?.chooseDiagramFile(link: true) }
        }
        RibbonGroup("Selected Diagram") {
            RibbonButton("Edit Diagram", "pencil.and.outline", large: true) {
                if let d = canvas?.selectedDiagram { d.edit() } else { NSSound.beep() }
            }
            RibbonButton("Export .drawio.svg", "square.and.arrow.up") { canvas?.selectedDiagram?.export(png: false) }
            RibbonButton("Export PNG", "photo") { canvas?.selectedDiagram?.export(png: true) }
        }
        RibbonGroup("Editor") {
            RibbonMenu(DrawioSource.offlineInstalled && offline ? "Offline" : "Online", DrawioSource.offlineInstalled && offline ? "internaldrive" : "globe") {
                Button("Online (embed.diagrams.net)") { offline = false }
                if DrawioSource.offlineInstalled {
                    Button("Offline (the copy on this Mac)") { offline = true }
                    Divider()
                    Button("Remove the Offline Copy") { download.remove() }
                } else {
                    Button("Download for Offline Use (about 50 MB)…") { download.start() }
                }
            }
            .tip("Editor", "Where the draw.io editor comes from: online, or a copy downloaded once for working without the internet (as VS Code's draw.io extension).")
            RibbonMenu("Theme", "paintbrush") {
                ForEach(DrawioSource.themes, id: \.0) { id, name in
                    Button(name) { theme = id }
                }
            }
            .tip("Theme", "The draw.io editor's look: Standard, Minimal, Atlas, Sketch, Simple or Dark.")
            if let progress = download.progress {
                ProgressView(value: progress).frame(width: 60).help(download.message)
            }
        }
        if !(canvas?.canvas.inkView.strokes.isEmpty ?? true) {
            RibbonGroup("Ink") {
                RibbonButton("Convert Ink to Diagram", "scribble.variable", large: true) { canvas?.convertInkToDiagram() }
                RibbonButton("Clear Ink", "trash") { canvas?.clearInk() }
            }
        }
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
            RibbonButton("Snap to Grid (⌃⌘G)", "square.grid.3x3", large: true,
                         active: editor.snapToGrid) { editor.snapToGrid.toggle() }
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

// MARK: - Score (shown while a music score is being edited)

struct ScoreRibbon: View {
    @Bindable private var editor = NotebookStore.shared.editor
    private var staff: ScoreView? { ScoreView.active }

    /// Runs a command on the score and keeps typing going to it.
    private func act(_ body: (ScoreView) -> Void) {
        guard let staff else { return }
        body(staff)
        staff.window?.makeFirstResponder(staff)
    }

    var body: some View {
        let _ = editor.scoreInputChanged
        RibbonGroup("Notes") {
            ForEach(ScoreNote.Duration.allCases) { d in
                RibbonButton("\(d.title) (\(d.key))", d == .whole ? "circle" : d == .half ? "music.note" : "music.note",
                             active: ScoreView.inputDuration == d) { act { $0.setDuration(d) } }
                    .overlay(alignment: .bottom) { Text(d.key).font(.system(size: 8, weight: .medium)).foregroundStyle(.secondary).offset(y: 8) }
            }
            RibbonButton("Dot (.)", "circle.fill", active: ScoreView.inputDotted) { act { $0.toggleDot() } }
            RibbonMenu("Tuplet", ScoreView.inputTuplet.map { "\($0[0]).square" } ?? "3.square", showTitle: false) {
                ForEach(ScoreData.tupletKinds, id: \.1) { ratio, name in
                    Button("\(name) (\(ratio[0]):\(ratio[1]))  ⌃\(ratio[0])") { act { $0.toggleTuplet(ratio) } }
                }
                Divider()
                Button("No Tuplet") { act { $0.clearTuplet() } }
            }
            RibbonMenu("Grace Note", "music.note.list", showTitle: false) {
                Button("Acciaccatura (slashed)  /") { act { $0.insertGrace("acciaccatura") } }
                Button("Appoggiatura  ?") { act { $0.insertGrace("appoggiatura") } }
                Divider()
                Button("Make Selected Note a Grace Note") { act { $0.setGrace("acciaccatura") } }
                Button("Make Selected Grace Note Normal") { act { $0.setGrace(nil) } }
            }
        }
        RibbonGroup("Expression") {
            RibbonMenu("Dynamic", "speaker.wave.2") {
                ForEach(ScoreData.dynamics, id: \.self) { d in
                    Button(d) { act { $0.setDynamic(d) } }
                }
                Divider()
                Button("Remove Dynamic") { act { $0.setDynamic(nil) } }
            }
            .tip("Dynamic")
            RibbonButton("Slur (S)", "point.topleft.down.to.point.bottomright.curvepath", active: staff?.slurHere == true) { act { $0.toggleSlur() } }
            RibbonButton("Crescendo (<)", "lessthan", active: staff?.hairpinHere == 1) { act { $0.toggleHairpin(1) } }
            RibbonButton("Diminuendo (>)", "greaterthan", active: staff?.hairpinHere == -1) { act { $0.toggleHairpin(-1) } }
            RibbonMenu("Ottava", "8.square") {
                Button("8va — an octave higher") { act { $0.setOttava(1) } }
                Button("15ma — two octaves higher") { act { $0.setOttava(2) } }
                Button("8vb — an octave lower") { act { $0.setOttava(-1) } }
                Button("15mb — two octaves lower") { act { $0.setOttava(-2) } }
                Divider()
                Button("Remove Ottava") { act { $0.setOttava(nil) } }
            }
            .tip("Ottava", "An 8va or 15ma line over the selected notes (8vb, 15mb under them): they're written an octave or two nearer the staff and sound where they are.")
        }
        RibbonGroup("Articulation") {
            Button { act { $0.toggleArticulation("staccato") } } label: { Text("•").font(.system(size: 15, weight: .bold)).frame(width: 22) }
                .tip("Staccato (⇧S)")
            Button { act { $0.toggleArticulation("tenuto") } } label: { Text("–").font(.system(size: 15, weight: .bold)).frame(width: 22) }
                .tip("Tenuto (⇧N)")
            Button { act { $0.toggleArticulation("accent") } } label: { Text(">").font(.system(size: 15, weight: .bold)).frame(width: 22) }
                .tip("Accent (⇧V)")
            Button { act { $0.toggleArticulation("marcato") } } label: { Text("^").font(.system(size: 15, weight: .bold)).frame(width: 22) }
                .tip("Marcato (⇧O)")
            Button { act { $0.toggleFermata() } } label: { Text("\u{1D110}").font(.custom("Apple Symbols", size: 22)).frame(width: 22) }
                .tip("Fermata (⇧H)")
            RibbonMenu("Ornament", "waveform.path") {
                ForEach(ScoreData.ornamentKinds, id: \.0) { id, name in
                    Button(name) { act { $0.toggleOrnament(id) } }
                }
                Button("Staccatissimo") { act { $0.toggleArticulation("staccatissimo") } }
                Divider()
                Button("Clear Articulations & Ornaments") { act { $0.clearMarks() } }
            }
            .tip("Ornament")
        }
        .buttonStyle(.borderless)
        RibbonGroup("Staves") {
            let count = staff?.fullScore.staffCount ?? 1
            RibbonButton("Staff Up (⌥⌘↑)", "chevron.up.square", active: false) { act { $0.setStaff($0.currentStaff - 1) } }
                .disabled(count < 2)
            RibbonButton("Staff Down (⌥⌘↓)", "chevron.down.square", active: false) { act { $0.setStaff($0.currentStaff + 1) } }
                .disabled(count < 2)
            RibbonMenu("Add Staff", "plus.rectangle") {
                Button("Treble Staff") { act { $0.addStaff(.treble) } }
                Button("Bass Staff") { act { $0.addStaff(.bass) } }
                Button("Percussion Staff (Drums)") { act { $0.addStaff(.percussion) } }
                Divider()
                Button(count == 1 ? "Make Piano Grand Staff" : "Piano Brace On / Off") { act { $0.makeGrandStaff() } }
                if count > 1 {
                    Divider()
                    Button("Move Staff Up") { act { $0.moveStaff(by: -1) } }
                    Button("Move Staff Down") { act { $0.moveStaff(by: 1) } }
                    Button("Rename Staff…") { staff?.renameStaff() }
                    Button("Remove Staff") { act { $0.removeStaff() } }
                }
            }
            RibbonButton("Piano Staff", "pianokeys", active: staff?.fullScore.grandStaff == true) { act { $0.makeGrandStaff() } }
            RibbonMenu("Cross-Staff", "arrow.up.arrow.down.square") {
                Button("Move to Staff Below (⇧⌘↓)") { act { $0.moveToStaff(1) } }
                Button("Move to Staff Above (⇧⌘↑)") { act { $0.moveToStaff(-1) } }
                Button("Back to Own Staff") { act { $0.moveToStaff(0) } }
            }
            .disabled(count < 2)
            .tip("Cross-Staff", "The selected notes drawn on the staff below or above — a piano passage shared between the hands — still counted and played with their own staff; beams between the staves join them.")
        }
        RibbonGroup("Transpose") {
            RibbonMenu("Transpose", "arrow.up.arrow.down") {
                Section(staff?.transposeScope ?? "") {
                    Button("Up a Half Step") { act { $0.transposeHalfStep(up: true) } }
                    Button("Down a Half Step") { act { $0.transposeHalfStep(up: false) } }
                    Button("Up an Octave") { act { $0.transpose(by: ScoreInterval(steps: 7, semitones: 12)) } }
                    Button("Down an Octave") { act { $0.transpose(by: ScoreInterval(steps: -7, semitones: -12)) } }
                }
                Menu("Up by Interval") {
                    ForEach(ScoreInterval.named, id: \.0) { name, interval in Button(name) { act { $0.transpose(by: interval) } } }
                }
                Menu("Down by Interval") {
                    ForEach(ScoreInterval.named, id: \.0) { name, interval in Button(name) { act { $0.transpose(by: interval.inverse) } } }
                }
                Menu("In the Key") {
                    ForEach(Array(["a 2nd", "a 3rd", "a 4th", "a 5th", "a 6th", "a 7th"].enumerated()), id: \.offset) { i, name in
                        Button("Up \(name)") { act { $0.transposeInKey(steps: i + 1) } }
                    }
                    Divider()
                    ForEach(Array(["a 2nd", "a 3rd", "a 4th", "a 5th", "a 6th", "a 7th"].enumerated()), id: \.offset) { i, name in
                        Button("Down \(name)") { act { $0.transposeInKey(steps: -(i + 1)) } }
                    }
                }
                Menu("To Key") {
                    ForEach(ScoreData.keyNames, id: \.0) { fifths, name in
                        Button(name) { act { $0.transpose(toKey: fifths, direction: 0) } }
                    }
                }
                .disabled(staff?.transposeRange != nil)
                Divider()
                Toggle("Transpose Key Signatures", isOn: Binding(get: { TransposeOptions.keys }, set: { TransposeOptions.keys = $0; editor.scoreInputChanged += 1 }))
                Toggle("Transpose Chord Symbols", isOn: Binding(get: { TransposeOptions.chordSymbols }, set: { TransposeOptions.chordSymbols = $0; editor.scoreInputChanged += 1 }))
                Divider()
                Button("Transpose…") { staff?.showTransposeDialog() }
            }
            .tip("Transpose", "Moves the music up or down — a half step, an octave, an interval, steps in the key, or to another key — with its chord symbols and key signatures. Two or more selected notes: only those; otherwise the whole score.")
            RibbonMenu(staff?.currentInstrument?.name ?? "Instrument", "music.mic") {
                Section("This staff's instrument") {
                    Toggle("In C (as it sounds)", isOn: Binding(get: { staff?.fullScore.forStaff(staff?.currentStaff ?? 0).transposition == nil }, set: { _ in act { $0.setInstrument(nil) } }))
                }
                ForEach(ScoreInstrument.all) { instrument in
                    Toggle(instrument.name, isOn: Binding(get: { staff?.currentInstrument == instrument }, set: { _ in act { $0.setInstrument(instrument) } }))
                }
            }
            .tip("Instrument", "A transposing instrument for the staff (B♭ clarinet or trumpet, E♭ alto sax, F horn…): its notes are written where its player reads them, in its own key, and play at the pitch they sound.")
            RibbonButton("Concert Pitch", "c.circle", active: staff?.fullScore.concertPitch == true) { act { $0.toggleConcertPitch() } }
                .tip("Concert Pitch", "Shows every staff as it sounds — transposing instruments too — in the score's key. Off: each instrument as its player reads it. Notes written either way go to the right place.")
        }
        RibbonGroup("Lead Sheet") {
            RibbonMenu("Slashes", "line.diagonal") {
                Button("Fill Bar with Slashes") { act { $0.fillWithSlashes() } }
                Button("Rhythmic Slashes (selected notes)") { act { $0.setSlash("rhythm") } }
                Button("Beat Slashes (selected notes)") { act { $0.setSlash("beat") } }
                Button("Slashes Back to Notes") { act { $0.setSlash(nil) } }
                Divider()
                Toggle("Slash Entry", isOn: Binding(get: { ScoreView.inputSlash }, set: { _ in act { $0.toggleSlashEntry() } }))
            }
            .tip("Slashes", "Slash notation: Fill Bar with Slashes (a beat slash per beat, keeping the chords), rhythmic slashes with stems, or Slash Entry to type them. Slashes play the chord symbol in effect.")
            RibbonMenu("Endings", "1.square") {
                Button("1st Ending") { act { $0.toggleEnding(1) } }
                Button("2nd Ending") { act { $0.toggleEnding(2) } }
                Button("3rd Ending") { act { $0.toggleEnding(3) } }
            }
            .tip("Endings", "1st and 2nd endings (voltas) over the selected note's bar: the 1st is played the first time through the repeat, the 2nd after it.")
            RibbonMenu(staff?.fullScore.barsPerLine.map { "\($0) per Line" } ?? "Bars per Line", "rectangle.split.3x1") {
                Button("As Many as Fit") { act { $0.setBarsPerLine(nil) } }
                ForEach([2, 3, 4, 5, 6, 8], id: \.self) { n in Button("\(n)") { act { $0.setBarsPerLine(n) } } }
            }
            .tip("Bars per Line", "So many bars on each line — lead sheets usually have 4.")
            RibbonButton("Composer", "person.text.rectangle") { staff?.editComposer() }
        }
        RibbonGroup("Bars") {
            let bar = staff?.currentBar ?? 0
            let mark = staff?.score.mark(bar) ?? ScoreBarMark()
            RibbonMenu("Key Change", "number.square") {
                ForEach(ScoreData.keyNames, id: \.0) { fifths, name in
                    Button(name) { act { $0.setKeyChange(fifths) } }
                }
                if bar > 0, mark.keyFifths != nil {
                    Divider()
                    Button("Remove Key Change") { act { $0.setKeyChange(nil) } }
                }
            }
            .tip("Key Change")
            RibbonButton("Start Repeat |: (bar \(bar + 1))", "arrow.right.to.line", active: mark.repeatStart == true) { act { $0.toggleRepeatStart() } }
            RibbonButton("End Repeat :| (bar \(bar + 1))", "arrow.uturn.backward", active: mark.repeatEnd == true) { act { $0.toggleRepeatEnd() } }
        }
        RibbonGroup("Voice") {
            RibbonButton("Voice 1 (⌥⌘1)", "1.circle", active: (staff?.currentVoice ?? 0) == 0) { act { $0.setVoice(0) } }
            RibbonButton("Voice 2 (⌥⌘2)", "2.circle", active: staff?.currentVoice == 1) { act { $0.setVoice(1) } }
        }
        RibbonGroup("Add") {
            if staff?.isPercussion == true {
                // A drum staff: the kit's instruments.
                Menu {
                    ForEach(DrumKit.instruments) { drum in
                        Button("\(drum.name)  \(String(drum.key).uppercased())") { act { $0.insertDrum(drum) } }
                    }
                    Divider()
                    ForEach(DrumKit.instruments) { drum in
                        Button("With \(drum.name)  ⇧\(String(drum.key).uppercased())") { act { $0.addDrumToChord(drum) } }
                    }
                } label: {
                    Label("Drum", systemImage: "circle.grid.cross")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .tip("Drum", "Adds a drum: K kick, S snare, H hi-hat, O open hi-hat, P pedal hi-hat, C crash, R ride, B ride bell, T M F toms, X side stick. ⇧ with the key plays it with the note.")
                ForEach(["kick", "snare", "hihat", "crash", "ride"], id: \.self) { id in
                    if let drum = DrumKit.instrument(id) {
                        Button(String(drum.key).uppercased()) { act { $0.insertDrum(drum) } }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .tip("\(drum.name) (\(drum.key))", "Adds a \(drum.name.lowercased()) of the current length after the cursor; ⇧\(String(drum.key).uppercased()) plays it with the note.")
                    }
                }
            } else {
                ForEach(Array(["C", "D", "E", "F", "G", "A", "B"].enumerated()), id: \.offset) { step, name in
                    Button(name) { act { $0.insert(step: step) } }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tip("Add \(name) (\(name.lowercased()))", "Adds a \(name) of the current length after the cursor, in the octave nearest the note before. ⇧\(name) adds it to the chord instead.")
                }
            }
            RibbonButton("Rest (0)", "pause", large: true) { act { $0.insert(step: nil) } }
        }
        RibbonGroup("Selected Note") {
            RibbonButton("Up (↑)", "arrow.up") { act { $0.moveSelected(steps: 1) } }
            RibbonButton("Down (↓)", "arrow.down") { act { $0.moveSelected(steps: -1) } }
            RibbonButton("Octave Up (⌘↑)", "arrow.up.to.line") { act { $0.moveSelected(steps: 7) } }
            RibbonButton("Octave Down (⌘↓)", "arrow.down.to.line") { act { $0.moveSelected(steps: -7) } }
            Button("♯") { act { $0.setAccidental(1) } }.tip("Sharp (+)")
            Button("♭") { act { $0.setAccidental(-1) } }.tip("Flat (-)")
            Button("♮") { act { $0.setAccidental(0) } }.tip("Natural (=)")
            RibbonButton("Tie (T)", "link") { act { $0.toggleTie() } }
            RibbonButton("Note / Rest (R)", "arrow.left.arrow.right") { act { $0.toggleRest() } }
            RibbonButton("Delete", "delete.left") { act { $0.deleteSelected() } }
        }
        RibbonGroup("Chords & Lyrics") {
            RibbonMenu("Chord Note", "music.quarternote.3") {
                ForEach(Array(["C", "D", "E", "F", "G", "A", "B"].enumerated()), id: \.offset) { step, name in
                    Button("Add \(name) to the Chord  (⇧\(name))") { act { $0.addChordTone(step: step) } }
                }
                Divider()
                Button("Remove Chord Notes") { act { $0.clearChordTones() } }
            }
            RibbonButton("Chord Symbol (⌃K)", "textformat.abc", large: true) { staff?.beginWords(.chordSymbol) }
            RibbonButton("Lyrics (⌃L)", "text.quote", large: true) { staff?.beginWords(.lyric) }
            RibbonButton("Guitar Tab", "guitars", large: true, active: staff?.owner?.score.showTab == true) { act { $0.toggleTab() } }
            RibbonButton("Chord Diagrams", "squareshape.split.3x3", large: true, active: staff?.owner?.score.chordDiagrams == true) { act { $0.toggleChordDiagrams() } }
            RibbonMenu(staff?.owner?.score.capo.map { "Capo \($0)" } ?? "Capo", "dial.low") {
                Button("No Capo") { act { $0.setCapo(0) } }
                Divider()
                ForEach(1...9, id: \.self) { fret in
                    Button("Capo \(fret)") { act { $0.setCapo(fret) } }
                }
            }
            RibbonButton("String Up (⌥↑)", "arrow.up.circle") { act { $0.moveString(by: 1) } }
            RibbonButton("String Down (⌥↓)", "arrow.down.circle") { act { $0.moveString(by: -1) } }
        }
        RibbonGroup("Score") {
            RibbonButton(editor.scorePlaying ? "Stop" : "Play (Space)", editor.scorePlaying ? "stop.fill" : "play.fill", large: true,
                         active: editor.scorePlaying) { act { $0.togglePlay() } }
            RibbonMenu("Clef", "music.note") {
                ForEach(ScoreData.Clef.allCases) { c in
                    Button(c.title) { act { $0.setClef(c) } }
                }
            }
            RibbonMenu("Key", "number") {
                ForEach(ScoreData.keyNames, id: \.0) { fifths, name in
                    Button(name) { act { $0.setKey(fifths) } }
                }
            }
            RibbonMenu("Time", "metronome") {
                ForEach(ScoreData.times, id: \.0.self) { b, u in
                    Button("\(b)/\(u)") { act { s in s.owner?.update({ $0.beats = b; $0.beatUnit = u }, actionName: "Time Signature") } }
                }
            }
            RibbonMenu("Tempo", "speedometer") {
                let bar = staff?.currentBar ?? 0
                Section(bar == 0 ? "Tempo at the start" : "Tempo from bar \(bar + 1)") {
                    ForEach(ScoreData.tempoTerms, id: \.0) { term, bpm in
                        Button("\(term)  (♩ = \(bpm))") { act { $0.setTempoTerm(term, bpm) } }
                    }
                }
                Divider()
                ForEach([60, 72, 80, 90, 100, 112, 120, 132, 144, 160], id: \.self) { t in
                    Button("♩ = \(t)") { act { $0.setTempo(t) } }
                }
                Divider()
                Button("rit. (gradually slower)") { act { $0.toggleGradual(-1) } }
                Button("accel. (gradually faster)") { act { $0.toggleGradual(1) } }
                if bar > 0 { Button("a tempo") { act { $0.aTempo() } } }
                Divider()
                Button("Metronome Mark…") { staff?.editMetronomeMark() }
                if bar > 0 { Button("Remove Tempo Change") { act { $0.removeTempoChange() } } }
            }
            .tip("Tempo")
            RibbonButton("Title", "textformat", large: true) { act { $0.owner?.editTitle() } }
            RibbonButton("Export MusicXML", "square.and.arrow.up", large: true) {
                if let owner = staff?.owner { MusicXML.save(owner.score, from: owner.window) }
            }
        }
    }
}

// MARK: - Table (shown while a table is being edited or has selected cells)

struct TableRibbon: View {
    private var grid: TableGridView? { TableGridView.active }
    @Environment(\.openWindow) private var openWindow

    private func palette(_ title: String = "Shading", _ apply: @escaping (NSColor?) -> Void) -> some View {
        Group {
            ForEach(Palette.shading, id: \.0) { name, color in
                Button { apply(color) } label: { Label { Text(name) } icon: { swatch(color) } }
            }
            custom(title) { apply($0) }
            Divider()
            Button("No Color") { apply(nil) }
        }
    }

    /// Recent colours and More Colors… (the macOS colour picker).
    private func custom(_ title: String, _ apply: @escaping (NSColor) -> Void) -> some View {
        Group {
            let recent = RecentColors.shared.colors
            if !recent.isEmpty {
                Divider()
                Section("Recent Colors") {
                    ForEach(recent.indices, id: \.self) { i in
                        Button { apply(recent[i]) } label: { Label { Text("#" + RecentColors.hex(recent[i])) } icon: { swatch(recent[i]) } }
                    }
                }
            }
            Divider()
            Button("More Colors…") {
                let grid = TableGridView.active
                ColorPicker.shared.pick(title, isValid: { [weak grid] in grid?.window != nil }, apply: apply)
            }
        }
    }

    var body: some View {
        RibbonGroup("Automation") {
            RibbonButton("Name & Tags", "tag", large: true) { grid?.editTableNameAndTags() }
            RibbonButton("Tag Rows", "line.3.horizontal.decrease") { grid?.tagRows() }
            RibbonButton("Tag Cells", "square.dashed") { grid?.tagCells() }
            RibbonButton("Copy Reference", "doc.on.clipboard") { grid?.copyPythonReference() }
            RibbonButton("Scripts (⌥⌘P)", "chevron.left.forwardslash.chevron.right", large: true) { openWindow(id: "scripts") }
        }
        RibbonGroup("Insert") {
            RibbonButton("Insert Above", "arrow.up.square", large: true) { grid?.insertRowAbove() }
            RibbonButton("Insert Below", "arrow.down.square", large: true) { grid?.insertRowBelow() }
            RibbonButton("Insert Left", "arrow.left.square", large: true) { grid?.insertColumnLeft() }
            RibbonButton("Insert Right", "arrow.right.square", large: true) { grid?.insertColumnRight() }
            RibbonMenu("Fill", "arrow.down.to.line.compact") {
                Button("Fill Down  ⌘D") { grid?.fillDown() }
                Button("Fill Right  ⌘R") { grid?.fillRight() }
            }
        }
        RibbonGroup("Merge") {
            RibbonButton("Merge Cells", "rectangle.compress.vertical", large: true) { grid?.mergeCells() }
            RibbonMenu("Split", "rectangle.split.2x1") {
                Button("Unmerge Cells") { grid?.unmergeCell() }
                Button("Split into 2 Columns") { grid?.splitIntoColumns() }
                Button("Split into 2 Rows") { grid?.splitIntoRows() }
            }
        }
        RibbonGroup("Delete") {
            RibbonButton("Rows", "minus.rectangle", large: true) { grid?.deleteRows() }
            RibbonButton("Columns", "minus.rectangle.portrait", large: true) { grid?.deleteColumns() }
            RibbonButton("Table", "trash", large: true) { grid?.deleteTable() }
        }
        RibbonGroup("Shading") {
            RibbonMenu("Cells", "paintbrush.fill") { palette("Cell Shading") { grid?.shadeCells($0) } }
            RibbonMenu("Rows", "line.3.horizontal") { palette("Row Shading") { grid?.shadeRows($0) } }
            RibbonMenu("Columns", "rectangle.split.3x1") { palette("Column Shading") { grid?.shadeColumns($0) } }
            RibbonMenu("Header", "rectangle.topthird.inset.filled") { palette("Header Row Shading") { grid?.shadeHeaderRow($0) } }
            RibbonMenu("Banded Rows", "list.bullet.rectangle") { palette("Banded Rows") { grid?.bandRows($0) } }
            RibbonMenu("Table", "tablecells.fill") { palette("Table Shading") { grid?.shadeTable($0) } }
        }
        RibbonGroup("Cell Text") {
            RibbonButton("Bold", "bold") { TextFormatter.toggleBold() }
            RibbonButton("Italic", "italic") { TextFormatter.toggleItalic() }
            RibbonMenu("Text Color", "paintpalette", showTitle: false) {
                ForEach(Palette.text, id: \.0) { name, color in
                    Button { TextFormatter.setTextColor(color) } label: { Label { Text(name) } icon: { swatch(color) } }
                }
                custom("Text Color") { TextFormatter.setTextColor($0) }
            }
            RibbonButton("Align Left", "text.alignleft") { TextFormatter.setAlignment(.left) }
            RibbonButton("Center", "text.aligncenter") { TextFormatter.setAlignment(.center) }
            RibbonButton("Align Right", "text.alignright") { TextFormatter.setAlignment(.right) }
        }
        RibbonGroup("Table") {
            RibbonButton("Header Row", "rectangle.topthird.inset.filled", large: true) { grid?.toggleHeaderRow() }
            RibbonButton("Hide Borders", "square.dashed", large: true) { grid?.toggleBorders() }
            RibbonButton("Sort A→Z", "arrow.up", large: true) { grid?.sort(ascending: true) }
            RibbonButton("Sort Z→A", "arrow.down", large: true) { grid?.sort(ascending: false) }
            RibbonButton("Filter", "line.3.horizontal.decrease.circle", large: true) { grid?.toggleFilter() }
            RibbonButton("Hide Columns", "eye.slash", large: true) { grid?.hideColumns() }
            RibbonButton("Unhide Columns", "eye", large: true) { grid?.unhideColumns() }
            RibbonMenu("Number", "number") {
                Button("General") { grid?.setNumberFormat(nil) }
                Button("Number  1,234.50") { grid?.setNumberFormat(.number) }
                ForEach(NumberFormat.currencySymbols, id: \.self) { symbol in
                    Button("Currency  \(symbol)1,234.50") { grid?.setNumberFormat(.currency, symbol: symbol) }
                }
                Button("Percent  12%") { grid?.setNumberFormat(.percent) }
                Divider()
                ForEach(NumberFormat.datePatterns, id: \.0) { pattern, name in
                    Button("\(name)  \(Formula.formatDate(Formula.serial(Date()), pattern: pattern))") { grid?.setDateFormat(pattern) }
                }
                Divider()
                Button("Thousands Separator") { grid?.toggleThousands() }
            }
            RibbonButton("Currency", "dollarsign", large: true) { grid?.setNumberFormat(.currency) }
            RibbonButton("Percent", "percent", large: true) { grid?.setNumberFormat(.percent) }
            RibbonButton("Increase Decimal", "increase.decimalplaces", large: true) { grid?.changeDecimals(by: 1) }
            RibbonButton("Decrease Decimal", "decrease.decimalplaces", large: true) { grid?.changeDecimals(by: -1) }
            RibbonMenu("Chart", "chart.bar.xaxis") {
                ForEach(ChartSpec.Kind.allCases) { kind in
                    Button { grid?.insertChart(kind) } label: { Label(kind.title, systemImage: kind.symbol) }
                }
            }
            RibbonMenu("Pivot", "tablecells.badge.ellipsis") {
                Button("Create Pivot Table…") { grid?.showPivot() }
                Button("Refresh Pivot Table") { grid?.refreshPivot() }
            }
            RibbonMenu("Validation", "checkmark.seal") {
                Button("Data Validation…") { grid?.showValidation() }
                Button("Circle Invalid Data") { grid?.circleInvalid.toggle() }
                Button("Clear Validation from Selected Cells") { grid?.clearValidation() }
            }
            RibbonMenu("Conditional", "paintbrush.pointed") {
                Button("New Rule…") { grid?.showConditionalFormatting() }
                Button("Clear Rules from Selected Cells") { grid?.clearConditionalRules(table: false) }
                Button("Clear Rules from Table") { grid?.clearConditionalRules(table: true) }
            }
            RibbonButton("AutoSum", "sum", large: true) { grid?.autoSum() }
            RibbonMenu("Formulas", "function") {
                ForEach(Formula.menuFunctions, id: \.0) { name, about in
                    Button("\(name) — \(about)") { grid?.insertFunction(name) }
                }
            }
            RibbonButton("Headings", "number.square", large: true) { grid?.toggleShowHeadings() }
            RibbonButton("Freeze Header", "rectangle.tophalf.inset.filled", large: true) { grid?.toggleFreezeHeaderRow() }
            RibbonButton("Freeze Column", "rectangle.lefthalf.inset.filled", large: true) { grid?.toggleFreezeFirstColumn() }
            RibbonButton("Hide Rows", "eye.slash", large: true) { grid?.hideRows() }
            RibbonButton("Unhide Rows", "eye", large: true) { grid?.unhideRows() }
            RibbonButton("Row Up", "arrow.up.to.line", large: true) { grid?.moveRows(up: true) }
            RibbonButton("Row Down", "arrow.down.to.line", large: true) { grid?.moveRows(up: false) }
            RibbonButton("Select Table", "tablecells", large: true) { grid?.selectTable() }
        }
    }
}
