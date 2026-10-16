//
//  NotebookFonts.swift
//  MxNoteONE
//
//  Notebook ▸ Notebook Fonts…: one font family and size for a whole notebook — every page's text boxes and
//  table cells — optionally also the default for new text.
//

import AppKit
import SwiftUI

struct NotebookFontChange {
    enum SizeMode: String, CaseIterable, Identifiable {
        case scale = "Scale all sizes (headings stay larger)"
        case uniform = "Same size for all text"
        case keep = "Keep sizes"
        var id: String { rawValue }
    }

    /// New family (nil keeps families).
    var family: String?
    var size: CGFloat
    var sizeMode: SizeMode
    /// Change only text in the current default font (keep text set to other fonts).
    var onlyDefaultFont: Bool
    var keepMonospaced: Bool
    var textBoxes: Bool
    var tables: Bool
    /// Also make this the default font for new text.
    var makeDefault: Bool

    /// The default font before the change.
    let oldFamily = Prefs.fontName
    let oldSize = Prefs.fontSize

    func convert(_ font: NSFont) -> NSFont {
        let fm = NSFontManager.shared
        let monospaced = font.isFixedPitch || font.fontDescriptor.symbolicTraits.contains(.monoSpace)
        if keepMonospaced && monospaced { return font }
        let eligible = !onlyDefaultFont || font.familyName == oldFamily
        var result = font
        if let family, eligible {
            let converted = fm.convert(result, toFamily: family)
            if converted.familyName == family { result = converted }
        }
        switch sizeMode {
        case .scale:
            let scaled = (result.pointSize * size / max(oldSize, 1) * 2).rounded() / 2
            result = fm.convert(result, toSize: max(6, scaled))
        case .uniform:
            if eligible { result = fm.convert(result, toSize: size) }
        case .keep:
            break
        }
        return result
    }

    /// The text with every font run converted.
    func convert(_ text: NSAttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: text)
        result.enumerateAttribute(.font, in: NSRange(location: 0, length: result.length)) { value, range, _ in
            result.addAttribute(.font, value: convert(value as? NSFont ?? Prefs.defaultFont), range: range)
        }
        return result
    }
}

enum NotebookFonts {
    struct Result {
        var pages = 0
        var changedPages = 0
        var lockedSections = 0
    }

    static func pageCount(_ nb: Notebook) -> Int {
        nb.manifest.sections.flattenedSections.reduce(0) { $0 + (nb.sections[$1.id]?.pages.count ?? 0) }
    }

    /// Applies the change to every page of the notebook (sections that are locked are skipped).
    static func apply(_ change: NotebookFontChange, to nb: Notebook, progress: (String) async -> Void) async -> Result {
        let store = NotebookStore.shared
        store.canvas?.flush()
        var result = Result()
        let base = Prefs.defaultFont
        let headerBase = NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask)
        for node in nb.manifest.sections.flattenedSections {
            guard let pages = nb.sections[node.id]?.pages else {
                result.lockedSections += 1
                continue
            }
            let section = SectionRef(notebookID: nb.id, sectionID: node.id)
            for meta in pages {
                result.pages += 1
                if result.pages % 10 == 0 { await progress("Changing fonts: \(result.pages) pages…") }
                let ref = PageRef(notebookID: nb.id, sectionID: node.id, pageID: meta.id)
                guard var content = store.loadPage(ref) else { continue }
                var changed = false
                for i in content.elements.indices {
                    switch content.elements[i].kind {
                    case .text where change.textBoxes:
                        guard let data = content.elements[i].rtfd,
                              let text = NoteRichText.text(data), text.length > 0 else { continue }
                        let converted = change.convert(text)
                        content.elements[i].rtfd = NoteRichText.data(converted)
                        changed = true
                    case .table where change.tables:
                        guard var table = content.elements[i].table else { continue }
                        table.normalize()
                        var rich = TableData.padded(table.rich, rows: table.rows.count, columns: table.columnCount)
                        for r in table.rows.indices {
                            for c in 0..<table.columnCount {
                                if let data = rich[r][c], let text = TableData.attributedCell(data) {
                                    rich[r][c] = TableData.cellData(change.convert(text))
                                } else if !change.makeDefault, !table.rows[r][c].isEmpty {
                                    // Plain cells use the default font; keep them as they look now, in the new font.
                                    let font = table.headerRow && r == 0 ? headerBase : base
                                    rich[r][c] = TableData.cellData(NSAttributedString(string: table.rows[r][c],
                                                                                       attributes: [.font: change.convert(font)]))
                                }
                            }
                        }
                        table.rich = rich.contains(where: { $0.contains { $0 != nil } }) ? rich : nil
                        content.elements[i].table = table
                        changed = true
                    default:
                        break
                    }
                }
                guard changed else { continue }
                var updated = meta
                updated.modified = Date()
                store.storeImportedPage(content, meta: updated, in: section)
                result.changedPages += 1
            }
        }
        if change.makeDefault {
            if let family = change.family { UserDefaults.standard.set(family, forKey: Prefs.fontNameKey) }
            if change.sizeMode != .keep { UserDefaults.standard.set(Double(change.size), forKey: Prefs.fontSizeKey) }
        }
        store.reloadToken += 1
        return result
    }
}

struct NotebookFontsSheet: View {
    let notebookID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var changeFamily = true
    @State private var family = Prefs.fontName
    @State private var size = Double(Prefs.fontSize)
    @State private var sizeMode: NotebookFontChange.SizeMode = .scale
    @State private var onlyDefault = false
    @State private var keepMonospaced = true
    @State private var textBoxes = true
    @State private var tables = true
    @State private var makeDefault = true
    @State private var confirm = false

    private var store: NotebookStore { .shared }
    private var notebook: Notebook? { store.notebook(notebookID) }

    private var change: NotebookFontChange {
        NotebookFontChange(family: changeFamily ? family : nil, size: CGFloat(size), sizeMode: sizeMode,
                           onlyDefaultFont: onlyDefault, keepMonospaced: keepMonospaced,
                           textBoxes: textBoxes, tables: tables, makeDefault: makeDefault)
    }

    private var previewFont: NSFont {
        let fm = NSFontManager.shared
        var font = Prefs.defaultFont
        if changeFamily { font = fm.convert(font, toFamily: family) }
        return sizeMode == .keep ? font : fm.convert(font, toSize: CGFloat(size))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Notebook Fonts — “\(notebook?.name ?? "")”").font(.headline)
            Form {
                Section {
                    Toggle("Change the font to:", isOn: $changeFamily)
                    Picker("Font:", selection: $family) {
                        ForEach(FontLibrary.shared.families, id: \.self) { Text($0).tag($0) }
                    }
                    .disabled(!changeFamily)
                    Picker("Sizes:", selection: $sizeMode) {
                        ForEach(NotebookFontChange.SizeMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Stepper("Size: \(size.formatted()) pt", value: $size, in: 8...48, step: 1)
                        .disabled(sizeMode == .keep)
                    if sizeMode == .scale {
                        Text("Text at the current default size (\(Prefs.fontSize.formatted()) pt) becomes \(size.formatted()) pt; other sizes change in proportion.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Toggle("Text boxes", isOn: $textBoxes)
                    Toggle("Tables", isOn: $tables)
                    Toggle("Only text in the current default font (\(Prefs.fontName))", isOn: $onlyDefault)
                    Toggle("Leave code (monospaced) text alone", isOn: $keepMonospaced)
                    Toggle("Also use for new text", isOn: $makeDefault)
                }
            }
            .formStyle(.grouped)
            Text("The quick brown fox jumps over the lazy dog.")
                .font(Font(previewFont as CTFont))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 6))
                .foregroundStyle(.black)
            Text("Changes every page of the notebook (\(notebook.map { NotebookFonts.pageCount($0) } ?? 0) pages). Page titles keep their style; locked sections are skipped. This can't be undone.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Apply…") { confirm = true }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!textBoxes && !tables || (!changeFamily && sizeMode == .keep) || ImportActivity.shared.busy)
            }
        }
        .padding(20)
        .frame(width: 560)
        .confirmationDialog("Change the fonts on every page of “\(notebook?.name ?? "")”?", isPresented: $confirm) {
            Button("Change Fonts", role: .destructive) { apply() }
        } message: {
            Text("This can't be undone.")
        }
    }

    private func apply() {
        guard let nb = notebook else { return }
        let change = change
        dismiss()
        ImportActivity.shared.runTask("Changing fonts…") { activity in
            let result = await NotebookFonts.apply(change, to: nb) { status in
                activity.status = status
                await Task.yield()
            }
            var message = "\(result.changedPages) of \(result.pages) pages in “\(nb.name)” updated."
            if result.lockedSections > 0 {
                message += " \(result.lockedSections) locked section\(result.lockedSections == 1 ? " was" : "s were") skipped — unlock and apply again to include \(result.lockedSections == 1 ? "it" : "them")."
            }
            NotebookStore.shared.showAlert("Notebook fonts changed", message)
        }
    }
}
