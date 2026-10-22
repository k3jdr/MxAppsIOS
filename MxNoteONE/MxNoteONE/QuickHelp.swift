//
//  QuickHelp.swift
//  MxNoteONE
//
//  Quick Help, as in Logic Pro: a panel at the bottom of the sidebar that
//  describes what's under the pointer — a toolbar tool or section, a note in
//  a score, a table cell, a link, a text box, a picture — in a sentence or
//  two, with its shortcut. With the pointer over nothing it can describe, it
//  tells about what's being worked on (the selected note, the cell being
//  typed in…). View ▸ Quick Help (⌥⌘/) shows or hides it.
//

import AppKit
import MapKit
import SwiftUI

struct QuickHelpItem: Equatable {
    var title: String
    var detail: String
    var shortcut: String?
    var symbol: String = "questionmark.circle"
}

@MainActor
@Observable
final class QuickHelp {
    static let shared = QuickHelp()
    static let visibleKey = "quickHelpVisible"

    var visible: Bool = UserDefaults.standard.object(forKey: visibleKey) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(visible, forKey: Self.visibleKey)
            visible ? startTracking() : stopTracking()
        }
    }

    /// A toolbar tool under the pointer, the toolbar section it's in, something on the page, what has the focus.
    private(set) var tool: QuickHelpItem?
    private(set) var section: QuickHelpItem?
    private(set) var pointer: QuickHelpItem?
    private(set) var focus: QuickHelpItem?

    var shown: QuickHelpItem? { tool ?? pointer ?? section ?? focus }

    private var monitor: Any?
    private var lastCheck = Date.distantPast

    // MARK: Toolbar

    /// The pointer is on (or left) a toolbar control with this label ("Bold (⌘B)").
    func hoverTool(_ label: String, _ inside: Bool, detail: String? = nil) {
        guard inside else {
            if tool?.title == Self.parse(label).name { tool = nil }
            return
        }
        let (name, shortcut) = Self.parse(label)
        pointer = nil   // the pointer is on the toolbar, not the page
        tool = QuickHelpItem(title: name, detail: detail ?? Self.details[name] ?? section?.detail ?? "",
                             shortcut: shortcut, symbol: "hand.point.up.left")
    }

    func hoverSection(_ title: String, tab: RibbonTab?, _ inside: Bool) {
        guard inside else {
            if section?.title == title + " section" { section = nil }
            return
        }
        let key = tab.map { RibbonLayout.key($0, title) } ?? title
        pointer = nil
        section = QuickHelpItem(title: title + " section", detail: Self.sectionDetails[key] ?? Self.sectionDetails[title]
                                ?? "Tools on the \(tab?.rawValue ?? "") tab. Right-click the section to collapse, float or hide it.",
                                shortcut: nil, symbol: "square.grid.2x2")
    }

    /// "Octave Up (⌘↑)" → ("Octave Up", "⌘↑").
    static func parse(_ label: String) -> (name: String, shortcut: String?) {
        guard let open = label.range(of: " ("), label.hasSuffix(")") else { return (label, nil) }
        let inside = String(label[open.upperBound..<label.index(before: label.endIndex)])
        let name = String(label[..<open.lowerBound])
        // "(bar 3)" isn't a shortcut.
        if inside.hasPrefix("bar ") { return (name, nil) }
        return (name, inside)
    }

    // MARK: The page under the pointer

    func startTracking() {
        guard monitor == nil else { return }
        for window in NSApp.windows where !(window is NSPanel) { window.acceptsMouseMovedEvents = true }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseUp, .keyUp]) { event in
            MainActor.assumeIsolated { QuickHelp.shared.update(event) }
            return event
        }
    }

    func stopTracking() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        pointer = nil
        focus = nil
    }

    private func update(_ event: NSEvent) {
        if event.type == .mouseMoved, Date().timeIntervalSince(lastCheck) < 0.06 { return }
        lastCheck = Date()
        guard let window = event.window, !(window is NSPanel), let content = window.contentView else { return }
        let point = event.locationInWindow
        // hitTest takes a point in the view's superview (the window's frame view).
        var view = content.hitTest(content.superview?.convert(point, from: nil) ?? point)
        var found: QuickHelpItem?
        while let v = view, found == nil {
            found = Self.describe(v, at: v.convert(point, from: nil))
            view = v.superview
        }
        pointer = found
        focus = Self.describeFocus(window)
    }

    /// What a view is, at a point in it.
    private static func describe(_ view: NSView, at p: NSPoint) -> QuickHelpItem? {
        switch view {
        case let staff as ScoreView:
            return staff.quickHelp(at: p)
        case let grid as TableGridView:
            return grid.quickHelp(at: p)
        case let diagram as DBMLCanvasView:
            return diagram.quickHelp(at: p)
        case is DBMLSourceTextView:
            return QuickHelpItem(title: "DBML", detail: "The diagram's DBML: Table name { column type [pk, not null, unique, note: '…', ref: > other.id] }, Enum, Ref: a.b > c.d (> many-to-one, < one-to-many, - one-to-one, <> many-to-many), TableGroup and Note. The diagram follows as you type; problems show below.",
                                 shortcut: nil, symbol: "chevron.left.forwardslash.chevron.right")
        case let tv as NoteTextView:
            if let spot = tv.linkSpot(at: p) {
                let info = LinkInfo(spot.url, tip: NoteRichText.tip(in: tv.textStorage ?? NSAttributedString(), at: spot.range.location))
                return QuickHelpItem(title: "Link: \(info.title)", detail: (info.tip.map { $0.string + "\n" } ?? "") + info.detail
                                     + "\nClick to open it. Rest the pointer for its card (Edit Link, Copy, Remove).",
                                     shortcut: "⌘K to edit", symbol: "link")
            }
            return QuickHelpItem(title: "Text Box", detail: "Type here. Select text to format it from the Home tab; drag the bar above the box to move it, its right edge to resize. Tab after a word starts a table.",
                                 shortcut: nil, symbol: "text.alignleft")
        case is TableElementView:
            return QuickHelpItem(title: "Table", detail: "Drag its edge to move it. Click a cell to select it, double-click to type. The Table tab has rows, columns, merging, shading, sorting, formulas and charts.", shortcut: nil, symbol: "tablecells")
        case is ScoreElementView:
            return QuickHelpItem(title: "Music Score", detail: "Click to write notes: A–G add notes, 3–7 set the length, Space plays. The Score tab has every tool.", shortcut: nil, symbol: "music.note")
        case is ImageElementView:
            return QuickHelpItem(title: "Picture", detail: "Drag to move it; drag a corner to resize. Right-click to copy, save, rotate or delete it.", shortcut: nil, symbol: "photo")
        case let file as FileElementView:
            return QuickHelpItem(title: file.element.kind == .audio ? "Recording" : "Attachment",
                                 detail: file.element.kind == .audio ? "Click to play the recording. Right-click to save or delete it."
                                    : "\(file.element.fileName ?? "A file") — double-click to open it; right-click to save a copy or delete it.",
                                 shortcut: nil, symbol: file.element.kind == .audio ? "waveform" : "paperclip")
        case let marker as PinMarkerView:
            guard let pin = (marker.annotation as? PinAnnotation)?.pin else { return nil }
            let link = pin.linkTitle.map { "Links to \($0). " } ?? ""
            return QuickHelpItem(title: "Pin: \(pin.title)", detail: (pin.notes.map { $0 + "\n" } ?? "") + link
                                 + "Click for its callout (edit, go to its link); drag it to move it; right-click for its colour, directions and more.",
                                 shortcut: nil, symbol: pin.symbol ?? "mappin")
        case is NoteMapView, is MapElementView:
            return QuickHelpItem(title: "Map", detail: "Click it to work on it (the Map tab): drag to pan, pinch or scroll to zoom, search for places, drop pins and link them to pages and paragraphs. Right-click to drop a pin.",
                                 shortcut: nil, symbol: "map")
        case is ChartElementView:
            return QuickHelpItem(title: "Chart", detail: "Made from table data. Right-click to change its type, titles, colours and axes, or to copy it as a picture.", shortcut: nil, symbol: "chart.bar")
        case let canvas as PageCanvasView:
            if canvas.titleField.frame.contains(p) {
                return QuickHelpItem(title: "Page Title", detail: "The page's name in the page list, links and exports. Return goes to the first text on the page.", shortcut: nil, symbol: "textformat")
            }
            if canvas.dateLabel.frame.contains(p) {
                return QuickHelpItem(title: "Page Dates", detail: "When the page was created │ when it was last updated.", shortcut: nil, symbol: "calendar")
            }
            let start = Prefs.newTextBox == .click ? "Click anywhere to start typing there" : Prefs.newTextBox == .doubleClick ? "Double-click anywhere to start typing there" : "Right-click ▸ New Text Box Here to start typing"
            return QuickHelpItem(title: "Page", detail: start + "; right-click to paste or insert there. Drop pictures and files here. Pinch or use View ▸ Zoom to zoom.", shortcut: nil, symbol: "doc")
        default:
            return nil
        }
    }

    /// What's being worked on (the first responder).
    private static func describeFocus(_ window: NSWindow) -> QuickHelpItem? {
        switch window.firstResponder {
        case let staff as ScoreView:
            return staff.quickHelpForSelection()
        case let grid as TableGridView:
            return grid.quickHelpForSelection()
        case let tv as NoteTextView:
            let font = (tv.typingAttributes[.font] as? NSFont).map { "\($0.familyName ?? $0.fontName) \(Int($0.pointSize)) pt" } ?? ""
            return QuickHelpItem(title: "Typing", detail: "In a text box\(font.isEmpty ? "" : " — \(font)"). ⌘B ⌘I ⌘U format; ⌘K adds a link; F7 checks spelling.", shortcut: nil, symbol: "character.cursor.ibeam")
        default:
            return nil
        }
    }
}

// MARK: - The panel

struct QuickHelpPanel: View {
    @Bindable private var help = QuickHelp.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Quick Help").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Button { help.visible = false } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                    .buttonStyle(.borderless)
                    .help("Hide Quick Help (⌥⌘/)")
            }
            if let item = help.shown {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: item.symbol).foregroundStyle(Color.accentColor)
                    Text(item.title).font(.system(size: 12, weight: .semibold)).lineLimit(2)
                    Spacer(minLength: 0)
                    if let shortcut = item.shortcut {
                        Text(shortcut)
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                    }
                }
                if !item.detail.isEmpty {
                    Text(item.detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("Point at a tool or at something on the page to see what it does.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
        .background(.background.opacity(0.6))
        .overlay(alignment: .top) { Divider() }
        .animation(nil, value: help.shown)
    }
}

extension View {
    /// A one- or two-word tooltip, and Quick Help while the pointer is on it.
    func tip(_ label: String, _ detail: String? = nil) -> some View {
        help(label)
            .onHover { inside in QuickHelp.shared.hoverTool(label, inside, detail: detail) }
    }
}

// MARK: - What the tools do

extension QuickHelp {
    static let sectionDetails: [String: String] = [
        "Home/Font": "The selected text's font and size (or what you type next).",
        "Home/Format": "Bold, italic, underline, strikethrough, super- and subscript, highlight and colour for the selected text.",
        "Home/Paragraph": "Bullets, numbering, indents, alignment and line spacing for the paragraphs the caret is in.",
        "Home/Styles": "Headings and other paragraph styles, and code formatting with syntax colours.",
        "Home/Tags": "To Do boxes and other tags; the Tag Summary lists every tagged paragraph.",
        "Insert/Tables": "A table, from a size or the Insert Table dialog.",
        "Insert/Music": "A music score, empty or from a MusicXML file.",
        "Insert/Maps": "A map, as in Apple Maps: search for places, drop pins and link each one to a page or a paragraph.",
        "Map/Search": "Search for places and addresses, pin an address, or pin where you are.",
        "Map/Pins": "Drop pins with a click, pin the centre, edit, colour or delete the selected pin.",
        "Map/Link": "Link the selected pin to a page, a paragraph on a page, or a web address — and go there.",
        "Map/Map": "The map's style (standard, muted, satellite, hybrid), 3D, points of interest, traffic, and grouping nearby pins (all together, or by category).",
        "Map/Directions": "Driving or walking routes from one pin to another.",
        "Map/View": "The pin list, showing every pin, zooming, facing north, the title, and copying a picture of the map.",
        "Insert/3D": "A 3D model (parametric CAD): a new part, the sample bracket, or an STL / OBJ file. Double-click it on the page to edit it.",
        "Insert/Files": "Pictures, attachments and screen clippings.",
        "Insert/Recording": "Record audio onto the page.",
        "Insert/Links": "A link to a web page, an email address or a page in your notebooks.",
        "Insert/Time Stamp": "Today's date, the time, or both, where the caret is.",
        "Insert/Pages": "New pages from templates.",
        "Draw/Diagram": "draw.io diagrams — flowcharts, UML, network, org charts, mind maps, anything — saved as .drawio.svg (a picture with the diagram inside, as VS Code's draw.io extension saves them).",
        "Draw/Selected Diagram": "Edit the selected diagram in draw.io (or double-click it), export it as .drawio.svg or PNG.",
        "Draw/Editor": "draw.io online, or a copy on this Mac for working offline; the editor's theme.",
        "Draw/Ink": "Pen strokes from before diagrams: turn them into a draw.io diagram, or clear them.",
        "View/Page Setup": "The page's colour and rule lines (lines or grid).",
        "View/Zoom": "Zoom the page in or out, to actual size or to the window's width.",
        "View/Views": "Full Page View, the Recycle Bin, snapping to the grid, the Tag Summary.",
        "Table/Automation": "Names and tags for the table, its rows and cells, so Python scripts can find them anywhere in the notebook; the Scripts window to write and run them.",
        "Table/Insert": "Rows and columns above, below, left or right of the selected cells.",
        "Table/Merge": "Merge or split cells.",
        "Table/Delete": "Delete rows, columns or the table.",
        "Table/Shading": "Cell fill colour and conditional formatting.",
        "Table/Cell Text": "Number formats, decimals and alignment for the selected cells.",
        "Table/Table": "Header row, banded rows, borders, freezing, sorting, filtering, validation, pivots and charts.",
        "Score/Notes": "The length of the next notes (or the selected one), dots, tuplets and grace notes.",
        "Score/Expression": "Dynamics (pp … ff), slurs, crescendo and diminuendo hairpins, and 8va / 8vb ottava lines.",
        "Score/Articulation": "Staccato, tenuto, accent, marcato, fermata and ornaments on the selected notes.",
        "Score/Staves": "Several staves: add a treble, bass or percussion (drum) staff, make a piano grand staff, move between staves (⌥⌘↑ ⌥⌘↓), rename or remove one, and cross-staff notes (⇧⌘↑ ⇧⌘↓).",
        "Score/Transpose": "Transpose the music (the whole score, or the selected notes); transposing instruments and concert pitch.",
        "Score/Lead Sheet": "Lead sheets and chord charts: slash notation, 1st and 2nd endings, bars per line, the composer.",
                "Score/Bars": "Key changes and repeat signs at the selected note's bar.",
        "Score/Voice": "Which voice you're writing: voice 1 (stems up) or voice 2 (stems down).",
        "Score/Add": "Add notes A–G or a rest after the cursor.",
        "Score/Selected Note": "Move, alter, tie, swap or delete the selected note.",
        "Score/Chords & Lyrics": "Chord notes, chord symbols and lyrics.",
        "Score/Guitar": "Guitar tablature (any tuning, TAB only, typing frets, playing techniques), chord diagrams, voicings and the chord chart, strumming patterns, and the staff's sound.",
        "Score/Analysis": "Figured bass and Roman numeral analysis: typed under the notes, or worked out from the music.",
        "Score/Score": "Play, clef, key, time, tempo, title and MusicXML export.",
    ]

    static let details: [String: String] = [
        // Home
        "Font": "The selected text's font. Your most used fonts are at the top; All Fonts lists every one.",
        "Font Size": "The selected text's size in points.",
        "Bold": "Makes the selected text bold, or plain again. With nothing selected, it applies to what you type next.",
        "Italic": "Makes the selected text italic, or upright again.",
        "Underline": "Underlines the selected text, or takes the underline off.",
        "Strikethrough": "Draws a line through the selected text.",
        "Superscript": "Raises the selected text (x²).",
        "Subscript": "Lowers the selected text (H₂O).",
        "Highlight": "Colours the background of the selected text, like a highlighter pen.",
        "Font Color": "Colours the selected text.",
        "Text Color": "Colours the selected text.",
        "Increase Font Size": "Makes the selected text a size larger.",
        "Decrease Font Size": "Makes the selected text a size smaller.",
        "Clear Formatting": "Removes fonts, colours and styles from the selected text.",
        "Bullets": "Turns the paragraphs into a bulleted list, or back to plain paragraphs.",
        "Numbering": "Turns the paragraphs into a numbered list.",
        "Indent": "Moves the paragraphs in a level (Tab at the start of a list item does too).",
        "Outdent": "Moves the paragraphs out a level.",
        "Alignment": "Left, centred, right or justified, and line spacing.",
        "Align Left": "Lines the paragraph up on the left.",
        "Center": "Centres the paragraph.",
        "Align Right": "Lines the paragraph up on the right.",
        "Styles": "Headings, Title, Quote and other paragraph styles.",
        "Code": "Formats the selection as code, with syntax colouring for the language chosen.",
        "Tags": "Marks the paragraph with a tag: To Do, Important, Question and more.",
        "To Do": "Puts a check box in front of the paragraph; click it to check it off.",
        "Tag Summary": "Opens a window listing every tagged paragraph in your notebooks.",
        // Insert
        "Table": "Inserts a table on the page.",
        "Score": "Inserts an empty music score: click it and type notes A–G.",
        "MusicXML": "Inserts a music score from a MusicXML file (MuseScore, Finale, Sibelius, Dorico).",
        "Picture": "Inserts a picture from a file.",
        "File": "Attaches a file to the page; double-click it to open.",
        "Screen Clipping": "Takes a picture of part of the screen and puts it on the page.",
        "Record Audio": "Records sound onto the page.",
        "Link": "Adds a link to the selected words: a web address, email or a page in your notebooks.",
        "Date": "Types today's date.",
        "Time": "Types the time now (or, on the Score tab, sets the time signature).",
        "Date & Time": "Types today's date and the time.",
        "Page Templates": "A new page laid out from a template.",
        // Draw
        "New Diagram": "A new draw.io diagram on the page, opened in the draw.io editor. Every change is saved back to the page.",
        "From Template": "A new diagram from one of draw.io's templates (flowcharts, UML, networks, business, tables…).",
        "Insert File": "Puts a .drawio.svg or .drawio file on the page (a copy, kept in the notebook).",
        "Link File": "Links a .drawio.svg file (in a code repository, say): editing it here saves the file, and changes made to it elsewhere (VS Code) show here.",
        "Edit Diagram": "Opens the selected diagram in draw.io (double-clicking it does too).",
        "Export .drawio.svg": "Saves the diagram as .drawio.svg — a picture any browser shows, that draw.io and VS Code open as a diagram.",
        "Export PNG": "Saves the diagram's picture as PNG.",
        "Convert Ink to Diagram": "Turns the page's pen strokes and shapes into a draw.io diagram you can edit.",
        "Clear Ink": "Removes the pen strokes from the page.",
        // View
        "Page Color": "The page's background colour.",
        "Rule Lines": "Lines or a grid on the page, to write and line things up on.",
        "Zoom In": "Makes the page bigger.",
        "Zoom Out": "Makes the page smaller.",
        "Actual Size": "Shows the page at 100%.",
        "Page Width": "Zooms so the page fills the window's width.",
        "Full Page View": "Hides the notebook and page lists so the page fills the window.",
        "Recycle Bin": "Deleted pages and sections, kept for 60 days. Restore them from here.",
        "Snap to Grid": "Boxes and drawings line up on an invisible grid as you move them. Hold ⌥ to place freely.",
        // Table
        "Insert Above": "Adds rows above the selected cells (as many as are selected).",
        "Insert Below": "Adds rows below the selected cells.",
        "Insert Left": "Adds columns to the left.",
        "Insert Right": "Adds columns to the right.",
        "Merge Cells": "Joins the selected cells into one.",
        "Split": "Splits merged cells, or a cell into rows or columns.",
        "Delete": "Deletes the selected rows, columns, table — or, on the Score tab, the selected note.",
        "Rows": "Row commands: insert, delete, height, hide.",
        "Columns": "Column commands: insert, delete, width, hide.",
        "Fill": "Shades the selected cells.",
        "Conditional": "Colours cells by their values (greater than, between, top 10, colour scales…).",
        "Number": "How numbers show: general, number, currency, percent, date…",
        "Currency": "Shows the numbers as money.",
        "Percent": "Shows the numbers as percentages.",
        "Increase Decimal": "Shows one more decimal place.",
        "Decrease Decimal": "Shows one fewer decimal place.",
        "Header Row": "Makes the first row the table's heading (bold, shaded, repeated when frozen).",
        "Banded Rows": "Shades every other row.",
        "Hide Borders": "Hides the table's lines.",
        "Freeze Header": "Keeps the header row in view while you scroll.",
        "Freeze Column": "Keeps the first column in view.",
        "Sort A→Z": "Sorts the rows by the selected column, smallest first.",
        "Sort Z→A": "Sorts the rows by the selected column, largest first.",
        "Filter": "Shows only the rows that match (values, colours).",
        "Validation": "Limits what a cell takes — a dropdown list, numbers, dates.",
        "Formulas": "SUM, AVERAGE and other Excel-style formulas.",
        "AutoSum": "Adds up the numbers above (or left of) the cell.",
        "Pivot": "Summarises the table by a column into a new table.",
        "Chart": "Makes a chart from the selected cells.",
        "Select Table": "Selects every cell.",
        "Hide Rows": "Hides the selected rows.",
        "Unhide Rows": "Shows hidden rows again.",
        "Hide Columns": "Hides the selected columns.",
        "Unhide Columns": "Shows hidden columns again.",
        "Cells": "Shades the selected cells with a colour.",
        "Header": "Shades the header row with a colour.",
        "Headings": "Shows or hides the A B C column letters and 1 2 3 row numbers.",
        "Name & Tags": "The table's name (unique in the notebook) and tags. Scripts find it with mx.table(\"Name\") or mx.tables(tag=\"…\").",
        "Tag Rows": "Tags on the selected rows — scripts find them with mx.rows(\"tag\") or table.row(tag=\"tag\"). Tagged rows show a blue mark.",
        "Tag Cells": "Tags on the selected cells — scripts find one with mx.cell(\"tag\"). Tagged cells show a blue corner.",
        "Copy Reference": "Copies the Python that gets to the selected cell (or the table), to paste into a script.",
        "Scripts": "Opens Notebook Scripts: write, run and debug Python that works on the notebook's tables.",
        "Row Up": "Moves the selected rows up.",
        "Row Down": "Moves the selected rows down.",
        // Score
        "Whole": "Notes entered from now on are whole notes (four beats); on a selected note, changes it.",
        "Half": "Half notes (two beats).",
        "Quarter": "Quarter notes (one beat).",
        "Eighth": "Eighth notes (half a beat); they're beamed by the beat.",
        "Sixteenth": "Sixteenth notes (a quarter of a beat).",
        "Dot": "Dotted notes: half as long again.",
        "Tuplet": "Notes fitted into another's time: triplets (3 in 2), quintuplets (5 in 4)… ⌃2–⌃9 as in MuseScore.",
        "Grace Note": "A small note before the selected one: an acciaccatura (/, slashed, crushed in quickly) or an appoggiatura (?, takes half the note's time).",
        "Dynamic": "A dynamic under the selected note: ppp … fff, sfz, fp. Playback gets louder or softer.",
        "Slur": "A curve over the selected notes (or to the next note): played smoothly. S again takes it off.",
        "Crescendo": "A hairpin getting louder over the selected notes, up to the next dynamic.",
        "Diminuendo": "A hairpin getting softer over the selected notes.",
        "Staccato": "Short and detached: plays half the note's length.",
        "Tenuto": "Held for its full length.",
        "Accent": "Louder than the notes around it.",
        "Marcato": "Strongly accented.",
        "Fermata": "Hold: the note lasts about twice as long and the music waits.",
        "Ornament": "Trill, mordent, inverted mordent or turn — played in the key — and staccatissimo.",
        "Staff Up": "Write on the staff above (clicking a staff does too).",
        "Staff Down": "Write on the staff below.",
        "Add Staff": "Adds a treble or bass staff under the others; they share the bars, key, time and tempo, and play together.",
        "Piano Staff": "Treble and bass staves joined by a brace, bar lines running through both — for piano, harp or organ.",
        "Drums": "Inserts a drum score (a percussion staff): K kick, S snare, H hi-hat, C crash, R ride, T M F toms… ⇧ with the key plays it with the note.",
        "Drum": "Adds a drum on a percussion staff: K kick, S snare, H hi-hat, O open hi-hat, P pedal hi-hat, C crash, R ride, B ride bell, T M F toms, X side stick.",
                "Piano": "Inserts a piano score: treble and bass staves joined by a brace.",
        "Slashes": "Slash notation: Fill Bar with Slashes (one beat slash per beat, keeping the chord symbols), rhythmic slashes with stems, Slash Entry to type them. Slashes play the chord symbol in effect.",
        "Endings": "1st and 2nd endings over the selected note's bar: the 1st plays the first time through the repeat, the 2nd after it.",
        "Bars per Line": "So many bars on each line — lead sheets usually have four.",
        "Composer": "The composer (or arranger…) under the title, at the right.",
        "Figured Bass": "Figures under the notes (⌃F): type 6, 64 or 6/4, 7/#, #6 — / stacks them, # b n are ♯ ♭ ♮, _ holds one on; Space goes to the next note.",
        "Roman Numerals": "A Roman numeral under the note (⌃R): I, V7, ii6, V65/V, viio7, bVI, N6 — o ø + for diminished, half-diminished, augmented, \"G: \" for a key; Space goes to the next note.",
        "Analyze": "Works out Roman numerals and figured bass from the notes sounding on every staff (in concert pitch), under the lowest staff: inversions, secondary dominants, the Neapolitan, borrowed chords, and the key — major or minor — with each key change.",
        "Ottava": "An 8va or 15ma line over the selected notes (8vb or 15mb under them): written an octave or two nearer the staff, sounding where they are.",
        "Cross-Staff": "Moves the selected notes onto the staff below (⇧⌘↓) or above (⇧⌘↑): still counted and played with their own staff, beamed between the staves.",
        "Transpose": "Moves the music up or down — a half step, an octave, an interval, steps in the key, or to another key — with its chord symbols and key signatures. Two or more selected notes: only those; otherwise the whole score.",
        "Instrument": "A transposing instrument for the staff (B♭ clarinet or trumpet, E♭ alto sax, F horn…): written where its player reads it, in its own key, and played at the pitch it sounds.",
        "Concert Pitch": "Every staff as it sounds — transposing instruments too — in the score's key. Off: each instrument as its player reads it.",
        "3D Model": "Inserts a 3D model and opens the 3D editor: boxes, cylinders, spheres…, sketches extruded or revolved, unions and cuts, patterns — every size an expression of named parameters. ⌃⌘3.",
        "Sample": "Inserts the sample 3D model — a bracket with rounded edges and two holes, built from parameters you can change.",
        "STL / OBJ": "Puts an STL or OBJ file on the page as a 3D model (shown, turned and measured; it can be cut and joined like any body).",
        "Lead Sheet": "Inserts a lead sheet: title, composer, \"Medium Swing\" tempo, four bars a line — add the melody, chord symbols (⌃K) and lyrics (⌃L).",
                "Key Change": "A new key from the selected note's bar: a double bar, cancelling naturals, the new key.",
        "Start Repeat |:": "The repeated passage starts at the selected note's bar.",
        "End Repeat :|": "At the end of the selected note's bar, go back to the start repeat (once).",
        "Voice 1": "Write in voice 1 (stems up).",
        "Voice 2": "Write in voice 2 (stems down), sharing the bars with voice 1.",
        "Rest": "Adds a rest of the current length.",
        "Up": "Moves the selected note up a step.",
        "Down": "Moves the selected note down a step.",
        "Octave Up": "Moves the selected note up an octave.",
        "Octave Down": "Moves the selected note down an octave.",
        "Sharp": "Makes the selected note sharp (again: takes it off).",
        "Flat": "Makes the selected note flat.",
        "Natural": "A natural sign on the selected note.",
        "Tie": "Ties the note to the next one of the same pitch: they sound as one.",
        "Note / Rest": "Turns the selected note into a rest, or back.",
        "Chord Note": "Adds a note above the selected one, making a chord (⇧A–G).",
        "Chord Symbol": "Types chord names (C, Am7, G/B) above the notes.",
        "Lyrics": "Types words under the notes; - between syllables, Space for the next note.",
        "Guitar Tab": "A TAB staff under the music: each note's string and fret in the instrument's tuning, chosen so the hand moves as little as it can.",
        "TAB Only": "The TAB in place of the music, with the rhythm under it.",
        "Type Frets": "Types frets onto the TAB (⌃T, or click it): ↑ ↓ change string, digits are frets, ⇧3–⇧7 lengths, → next note, Esc stops.",
        "Tuning": "The fretted instrument and its tuning: guitar (standard, drop, open, DADGAD, seven-string), bass, ukulele, mandolin, banjo, or your own.",
        "Chord Chart": "Every chord used, with its diagram, under the title.",
        "Voicing": "The fingering for the selected chord: choose one up the neck or draw it; name chords from their notes.",
        "Technique": "How notes are played: hammer-on / pull-off, slides, bends, vibrato, palm mute, let ring, harmonics, dead and ghost notes, taps (⌥ with a letter).",
        "Strum": "Strumming patterns for the bar (or the bars selected): folk, rock, ballad, reggae, funk, boom-chick, waltz, 6/8 and more, as rhythm slashes marked ⊓ V (or ↓ ↑) and played as a guitar strums the chord symbols — down from the low strings, up from the high ones, muted strums, bass notes alternating root and fifth. The Pattern Editor makes your own; New Rhythm Guitar Staff adds a staff that strums the first staff's chords. ⌥D / ⌥U mark strums; Swing plays eighths long-short.",
        "Sound": "The staff's General MIDI sound for playback: piano, guitars, bass…",
        "Chord Diagrams": "Chord diagrams over the chord symbols, in the instrument's tuning: the usual open chord, else a barre or the handiest voicing; fingers numbered; with a capo, the shape played. Click one to hear it.",
        "Capo": "A capo on a fret: TAB counts frets from it, chord names show the shape played (E♭ (C) with capo 3), the diagrams show that shape, and \"Capo n\" is marked. The music still sounds as written.",
                "String Up": "Moves the selected note to the next higher string on the TAB.",
        "String Down": "Moves the selected note to the next lower string.",
        "Play": "Plays the score from the selected note (Space). Every voice, dynamic, tempo and repeat is followed.",
        "Stop": "Stops playing.",
        "Clef": "Treble or bass clef.",
        "Key": "The key signature at the start.",
        "Tempo": "The speed: tempo words, ♩ = n, rit., accel., a tempo, or a metronome mark at the selected note's bar.",
        "Title": "The score's title, shown above it.",
        "Export MusicXML": "Saves the score as MusicXML for MuseScore, Finale, Sibelius and Dorico.",
    ]
}

// MARK: - Scores and tables

extension ScoreView {
    /// The note (or rest) under the pointer, in words.
    func quickHelp(at p: NSPoint) -> QuickHelpItem? {
        guard let ref = noteRef(at: p) else {
            return QuickHelpItem(title: "Music Score", detail: "Click a note to select it, or between notes to put the cursor there; type A–G to add notes, 0 for a rest, Space to play.",
                                 shortcut: nil, symbol: "music.note")
        }
        return describe(ref)
    }

    /// The selected note, or where the cursor is.
    func quickHelpForSelection() -> QuickHelpItem? {
        if let i = selectedRange?.lowerBound {
            var item = describe(NoteRef(voice: currentVoice, index: i, staff: currentStaff))
            if let r = selectedRange, r.count > 1 { item.title = "\(r.count) notes selected"; item.detail = "S slur, < > hairpins, ⇧S ⇧N ⇧V ⇧O articulations, ⌃3 triplet — all apply to the run." }
            return item
        }
        let ratio = ScoreView.inputTuplet
        let tuplet = ratio.map { r in ", in " + (ScoreData.tupletKinds.first { $0.0 == r }?.1.lowercased() ?? "tuplet") + "s" } ?? ""
        let where_ = fullScore.staffCount > 1 ? fullScore.staffTitle(currentStaff) + ", voice" : "Voice"
        let detail = "\(where_) \(currentVoice + 1), \(ScoreView.inputDuration.title.lowercased()) notes\(ScoreView.inputDotted ? ", dotted" : "")\(tuplet)."
            + " A–G add notes, 3–7 set the length, Space plays."
        return QuickHelpItem(title: "Writing music", detail: detail, shortcut: nil, symbol: "music.note")
    }

    private func describe(_ ref: NoteRef) -> QuickHelpItem {
        let line = shownStaff(ref.staff).forVoice(ref.voice)
        guard line.notes.indices.contains(ref.index) else { return QuickHelpItem(title: "Note", detail: "", shortcut: nil) }
        let n = line.notes[ref.index]
        let names = ["C", "D", "E", "F", "G", "A", "B"]
        var length = n.duration.title.lowercased() + (n.dotted ? " dotted" : "")
        if let actual = n.tupletActual { length += " (\(actual):\(n.tupletNormal) \(ScoreData.tupletKinds.first { $0.0 == [actual, n.tupletNormal] }?.1.lowercased() ?? "tuplet"))" }
        var title: String
        if n.rest {
            title = "\(n.duration.title) rest"
        } else {
            let alter = line.soundingAlter(ref.index)
            let pitch = names[n.step] + (alter > 0 ? "♯" : alter < 0 ? "♭" : "") + "\(n.octave)"
            title = n.grace != nil ? "Grace note \(pitch) (\(n.grace!))" : "\(pitch) — \(length)"
            if let drum = DrumKit.instrument(n.drum) {
                let with = (n.chord ?? []).compactMap { DrumKit.instrument($0.drum)?.name }
                title = ([drum.name] + with).joined(separator: " + ") + " — \(length)"
            }
        }
        var facts: [String] = ["Bar \(line.bar(of: ref.index) + 1)" + (fullScore.staffCount > 1 ? ", \(fullScore.staffTitle(ref.staff))" : "")
                               + (fullScore.forStaff(ref.staff).hasSecondVoice ? ", voice \(ref.voice + 1)" : "")]
        // A transposing instrument's note: where it sounds (or, in concert pitch, where it's written).
        if let t = fullScore.forStaff(ref.staff).transposition, !n.rest, n.drum == nil, n.slash == nil {
            let concert = fullScore.concertPitch == true
            let (d, a) = ScoreData.moved(n.diatonic, line.soundingAlter(ref.index), by: concert ? t.inverse : t)
            let other = names[ScoreData.mod7(d)] + (a > 0 ? "♯" : a < 0 ? "♭" : "") + "\(ScoreData.floor7(d))"
            facts.append(concert ? "written \(other)" : "sounds \(other)")
        }
        if let o = n.ottava, o != 0 {
            facts.append("under \(abs(o) == 2 ? (o > 0 ? "15ma" : "15mb") : (o > 0 ? "8va" : "8vb")) (written \(abs(o) == 2 ? "two octaves" : "an octave") \(o > 0 ? "lower" : "higher"))")
        }
        if let c = n.crossStaff, c != 0 { facts.append("written on the staff \(c > 0 ? "below" : "above")") }
        if let f = n.figures, !f.isEmpty { facts.append("figured \(FiguredBass.glyphs(f))") }
        if let r = n.numeral, !r.isEmpty { facts.append(r) }
        if let chord = n.chord, !chord.isEmpty { facts.append("chord of \(chord.count + 1)") }
        if let d = n.dynamic { facts.append(d) }
        let marks = (n.articulations ?? []) + [n.ornament].compactMap { $0 } + (n.fermata == true ? ["fermata"] : [])
        if !marks.isEmpty { facts.append(marks.joined(separator: ", ")) }
        if n.tie { facts.append("tied to the next") }
        if let symbol = n.chordSymbol, !symbol.isEmpty { facts.append("chord symbol \(symbol)") }
        if let lyric = n.lyric, !lyric.isEmpty { facts.append("lyric “\(lyric)”") }
        return QuickHelpItem(title: title, detail: facts.joined(separator: " · ") + ".\n↑↓ move it, + - = accidentals, T tie, R rest, Delete removes it.",
                             shortcut: nil, symbol: n.rest ? "pause" : "music.note")
    }
}

extension TableGridView {
    /// The cell under the pointer, in words.
    func quickHelp(at p: NSPoint) -> QuickHelpItem? {
        guard let cell = cellRef(at: p) else { return nil }
        if picture(at: p) != nil {
            return QuickHelpItem(title: "Picture in Cell \(TableData.columnName(cell.column))\(cell.row + 1)",
                                 detail: "Drag a side or corner to resize it; it keeps its proportions, and the column widens for a bigger picture. A picture on a line of its own follows its column and row as you resize them.",
                                 shortcut: nil, symbol: "photo")
        }
        return describe(cell)
    }

    func quickHelpForSelection() -> QuickHelpItem? {
        if selection.count > 1 {
            return QuickHelpItem(title: "\(selection.count) cells selected", detail: "Type to replace, ⌘C copies as Excel cells, Delete clears. The Table tab formats, sorts and charts them.", shortcut: nil, symbol: "tablecells")
        }
        return (editingCell ?? selection.first).map(describe)
    }

    private func describe(_ cell: CellRef) -> QuickHelpItem {
        let name = TableData.columnName(cell.column) + "\(cell.row + 1)"
        let raw = model.text(cell)
        var facts: [String] = []
        if Formula.isFormula(raw) {
            facts.append("Formula \(raw) = \(model.shownText(cell).string)")
        } else if raw.isEmpty {
            facts.append("Empty")
        } else {
            facts.append("“\(raw.count > 60 ? String(raw.prefix(60)) + "…" : raw)”")
        }
        if let format = model.numberFormat(cell) { facts.append("\(format.kind.rawValue) format, \(format.decimals) decimals") }
        if model.span(cell).rows > 1 || model.span(cell).columns > 1 { facts.append("merged \(model.span(cell).rows)×\(model.span(cell).columns)") }
        facts += tagFacts(cell)
        return QuickHelpItem(title: "Cell \(name)", detail: facts.joined(separator: " · ") + ".\nDouble-click to type; = starts a formula; Tab moves on.",
                             shortcut: nil, symbol: "tablecells")
    }
}
