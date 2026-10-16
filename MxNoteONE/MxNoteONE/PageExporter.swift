//
//  PageExporter.swift
//  MxNoteONE
//
//  Print a page, export pages or whole sections as PDF (paginated, one
//  document), and export a page as Markdown with its pictures and files.
//

import AppKit
import PDFKit
import UniformTypeIdentifiers

enum PageExporter {
    /// Keeps the canvas of a running print sheet alive.
    private static var printing: CanvasController?

    private static var store: NotebookStore { .shared }

    private static func makeCanvas(_ ref: PageRef) -> CanvasController? {
        store.canvas?.flush()
        guard let content = store.loadPage(ref) else { return nil }
        let controller = CanvasController(mode: .export)
        controller.loadForExport(content, ref: ref)
        return controller
    }

    private static func printInfo(savingTo url: URL?) -> NSPrintInfo {
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.leftMargin = 30
        info.rightMargin = 30
        info.topMargin = 30
        info.bottomMargin = 30
        if let url {
            info.jobDisposition = .save
            info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL.rawValue] = url
        }
        return info
    }

    @discardableResult
    static func writePDF(_ ref: PageRef, to url: URL) -> Bool {
        guard let controller = makeCanvas(ref) else { return false }
        let operation = NSPrintOperation(view: controller.canvas, printInfo: printInfo(savingTo: url))
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        return operation.run()
    }

    private static func safeName(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return cleaned.isEmpty ? "Untitled" : cleaned
    }

    static func exportPDF(_ refs: [PageRef], suggestedName: String) {
        guard !refs.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = safeName(suggestedName) + ".pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if refs.count == 1 {
            if !writePDF(refs[0], to: url) { store.showAlert("Export failed", "The page couldn't be exported as PDF.") }
            return
        }
        let document = PDFDocument()
        let folder = FileManager.default.temporaryDirectory.appending(path: "MxNoteONE-export-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (i, ref) in refs.enumerated() {
            let pageURL = folder.appending(path: "\(i).pdf")
            guard writePDF(ref, to: pageURL), let part = PDFDocument(url: pageURL) else { continue }
            for p in 0..<part.pageCount {
                if let page = part.page(at: p) { document.insert(page, at: document.pageCount) }
            }
        }
        try? FileManager.default.removeItem(at: folder)
        if !document.write(to: url) { store.showAlert("Export failed", "The PDF couldn't be written.") }
    }

    static func exportCurrentPagePDF() {
        guard let ref = store.currentPageRef else { return NSSound.beep() }
        exportPDF([ref], suggestedName: store.meta(ref)?.displayTitle ?? "Page")
    }

    static func exportSectionPDF(_ section: SectionRef) {
        guard let pages = store.pages(in: section), !pages.isEmpty else { return NSSound.beep() }
        let refs = pages.map { PageRef(notebookID: section.notebookID, sectionID: section.sectionID, pageID: $0.id) }
        exportPDF(refs, suggestedName: store.node(section)?.name ?? "Section")
    }

    static func printPage(_ ref: PageRef? = nil) {
        guard let ref = ref ?? store.currentPageRef, let controller = makeCanvas(ref) else { return NSSound.beep() }
        printing = controller
        let operation = NSPrintOperation(view: controller.canvas, printInfo: printInfo(savingTo: nil))
        operation.jobTitle = store.meta(ref)?.displayTitle ?? "Page"
        if let window = NSApp.keyWindow {
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            operation.run()
            printing = nil
        }
    }

    // MARK: Markdown

    static func exportMarkdown(_ ref: PageRef? = nil) {
        guard let ref = ref ?? store.currentPageRef else { return NSSound.beep() }
        store.canvas?.flush()
        guard let content = store.loadPage(ref) else { return }
        let title = store.meta(ref)?.displayTitle ?? "Page"
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = safeName(title) + ".md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        writeMarkdown(content, title: title, ref: ref, to: url)
    }

    /// Writes a page as Markdown, its pictures, files and diagrams in a folder beside it.
    static func writeMarkdown(_ content: PageContent, title: String, ref: PageRef, to url: URL) {
        let assetsName = url.deletingPathExtension().lastPathComponent + " files"
        let assetsFolder = url.deletingLastPathComponent().appending(path: assetsName)
        var lines: [String] = ["# " + title, ""]
        let elements = content.elements.sorted { ($0.y, $0.x) < ($1.y, $1.x) }
        for element in elements {
            switch element.kind {
            case .text:
                guard let data = element.rtfd, let text = NoteRichText.text(data) else { continue }
                lines += markdown(text)
            case .table:
                guard let table = element.table, !table.rows.isEmpty else { continue }
                let escape: (String) -> String = {
                    $0.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: "<br>")
                }
                let header = table.headerRow ? table.rows[0] : Array(repeating: "", count: table.columnCount)
                lines.append("| " + header.map(escape).joined(separator: " | ") + " |")
                lines.append("|" + Array(repeating: " --- |", count: table.columnCount).joined())
                for row in table.rows.dropFirst(table.headerRow ? 1 : 0) {
                    lines.append("| " + row.map(escape).joined(separator: " | ") + " |")
                }
            case .image, .file, .audio:
                guard let asset = element.asset, let data = store.assetData(asset, for: ref) else { continue }
                let fileName = element.kind == .image ? asset : (element.fileName ?? asset)
                try? FileManager.default.createDirectory(at: assetsFolder, withIntermediateDirectories: true)
                try? data.write(to: assetsFolder.appending(path: fileName))
                let link = (assetsName + "/" + fileName).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? fileName
                lines.append(element.kind == .image ? "![](\(link))" : "[\(fileName)](\(link))")
            case .diagram:
                // A diagram as a .drawio.svg beside the Markdown: a picture there, and still a draw.io diagram (VS Code).
                guard let asset = element.asset, let data = store.assetData(asset, for: ref) else { continue }
                let fileName = (element.fileName ?? "Diagram") + "-" + String(element.id.uuidString.prefix(4)) + ".drawio.svg"
                try? FileManager.default.createDirectory(at: assetsFolder, withIntermediateDirectories: true)
                try? data.write(to: assetsFolder.appending(path: fileName))
                let link = (assetsName + "/" + fileName).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? fileName
                lines.append("![\(element.fileName ?? "Diagram")](\(link))")
            case .score:
                // A score as its title, signatures and notes in letter names.
                guard let score = element.score else { continue }
                lines.append("*♪ \(score.summary)*")
                lines.append("")
                lines.append(score.noteNames)
            case .chart:
                // A chart's data as a table, under its title.
                guard let chart = element.chart, !chart.series.isEmpty else { continue }
                lines.append("*\(chart.title.isEmpty ? "\(chart.kind.title) chart" : chart.title)*")
                lines.append("")
                lines.append("| \(chart.categoryField) | " + chart.series.map(\.name).joined(separator: " | ") + " |")
                lines.append("|" + Array(repeating: " --- |", count: chart.series.count + 1).joined())
                for (i, category) in chart.categories.enumerated() {
                    let values = chart.series.map { s in i < s.values.count ? s.values[i].map(Formula.format) ?? "" : "" }
                    lines.append("| \(category) | " + values.joined(separator: " | ") + " |")
                }
            }
            lines.append("")
        }
        do {
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        } catch {
            store.report("Couldn't export the page.", error)
        }
    }

    private static func markdown(_ text: NSAttributedString) -> [String] {
        var lines: [String] = []
        let ns = text.string as NSString
        var location = 0
        while location < ns.length {
            let range = ns.paragraphRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(range)
            var body = NSRange(location: range.location, length: range.length)
            if body.length > 0, ns.character(at: NSMaxRange(body) - 1) == 0x0A { body.length -= 1 }
            let plain = ns.substring(with: body)
            let info = TextFormatter.parseParagraph(plain)
            var prefix = String(repeating: "  ", count: plain.prefix(info.indent).filter { $0 == "\t" }.count)
            switch info.list {
            case .bullet?: prefix += "- "
            case .number(let n)?: prefix += "\(n). "
            case nil: break
            }
            var start = info.indent + info.listLength
            if info.tag == .todo {
                prefix += info.list == nil ? "- " : ""
                prefix += info.tagDone ? "[x] " : "[ ] "
                start += info.tagLength
            }
            if info.list == nil, info.tag == nil, body.length > 0,
               let font = text.attribute(.font, at: body.location, effectiveRange: nil) as? NSFont {
                let bold = NSFontManager.shared.traits(of: font).contains(.boldFontMask)
                if font.pointSize >= 19 { prefix = "## " } else if font.pointSize >= 15.5 && bold { prefix = "### " }
            }
            var line = prefix
            let content = NSRange(location: body.location + start, length: max(0, body.length - start))
            text.enumerateAttributes(in: content) { attrs, run, _ in
                var piece = ns.substring(with: run)
                guard !piece.isEmpty else { return }
                if prefix.hasPrefix("#") == false, let font = attrs[.font] as? NSFont {
                    let traits = NSFontManager.shared.traits(of: font)
                    let trimmed = piece.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty {
                        if traits.contains(.boldFontMask) { piece = piece.replacingOccurrences(of: trimmed, with: "**\(trimmed)**") }
                        if traits.contains(.italicFontMask) { piece = piece.replacingOccurrences(of: trimmed, with: "*\(trimmed)*") }
                    }
                }
                if attrs[.strikethroughStyle] != nil { piece = "~~\(piece)~~" }
                if let link = attrs[.link] {
                    let url = (link as? URL)?.absoluteString ?? (link as? String) ?? ""
                    piece = "[\(piece)](\(url))"
                }
                line += piece
            }
            lines.append(line)
            if range.length == 0 { break }
        }
        return lines
    }
}
