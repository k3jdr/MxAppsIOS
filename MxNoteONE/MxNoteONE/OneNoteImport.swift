//
//  OneNoteImport.swift
//  MxNoteONE
//
//  Turns OneNote section files (read by OneStoreReader) into MxNoteONE
//  pages, following the OneNote object model ([MS-ONE]): sections, page
//  series, pages with their title and level, outlines (positioned text
//  containers), paragraphs with indent levels, bullets and numbering, rich
//  text runs (font, size, bold, italic, underline, strikethrough,
//  superscript / subscript, colour, highlight, hyperlinks), tags, tables
//  (column widths, cell shading, formatted cell text), pictures and
//  attached files. Ink is not imported.
//
//  Import ▸ OneNote Package (.onepkg) unpacks the package (a cabinet
//  archive) and imports its sections and section groups as a notebook;
//  Import ▸ OneNote Sections (.one) adds sections to the current notebook;
//  Import ▸ OneNote Notebook Folder imports a folder of sections (for
//  example a OneNote backup folder, keeping the newest copy of each).
//

import AppKit
import UniformTypeIdentifiers

struct ImportedOneNotePage {
    var title: String
    var level: Int
    var created: Date?
    var elements: [PageElement]
    /// Picture and file data for elements, by element ID: (data, file extension).
    var assets: [UUID: (Data, String)]
}

struct ImportedOneNoteSection {
    var name: String
    var color: NoteColor?
    var pages: [ImportedOneNotePage]
    /// Pictures that are kept outside the section file and weren't found.
    var missingFiles = 0
}

enum OneNoteImport {
    // Object types (JCIDs).
    static let sectionNode: UInt32 = 0x0006_0007
    static let pageSeriesNode: UInt32 = 0x0006_0008
    static let pageNode: UInt32 = 0x0006_000B
    static let outlineNode: UInt32 = 0x0006_000C
    static let outlineElementNode: UInt32 = 0x0006_000D
    static let richTextNode: UInt32 = 0x0006_000E
    static let imageNode: UInt32 = 0x0006_0011
    static let numberListNode: UInt32 = 0x0006_0012
    static let tableNode: UInt32 = 0x0006_0022
    static let tableRowNode: UInt32 = 0x0006_0023
    static let tableCellNode: UInt32 = 0x0006_0024
    static let titleNode: UInt32 = 0x0006_002C
    static let embeddedFileNode: UInt32 = 0x0006_0035
    static let pageManifestNode: UInt32 = 0x0006_0037
    static let sectionMetaData: UInt32 = 0x0002_0031

    // Properties.
    static let elementChildNodes: UInt32 = 0x2400_1C1F
    static let contentChildNodes: UInt32 = 0x2400_1C20
    static let structureChildNodes: UInt32 = 0x2400_1D5F
    static let childGraphSpaces: UInt32 = 0x2C00_1D63
    static let metaDataObjects: UInt32 = 0x2400_3442
    static let listNodes: UInt32 = 0x2400_1C26
    static let cachedTitle: UInt32 = 0x1C00_1CF3
    static let pageLevel: UInt32 = 0x1400_1DFF
    static let creationTime: UInt32 = 0x1800_1C65
    static let offsetX: UInt32 = 0x1400_1C14
    static let offsetY: UInt32 = 0x1400_1C15
    static let maxWidth: UInt32 = 0x1400_1C1B
    static let textUnicode: UInt32 = 0x1C00_1C22
    static let textASCII: UInt32 = 0x1C00_3498
    static let runIndex: UInt32 = 0x1C00_1E12
    static let runFormatting: UInt32 = 0x2400_1E13
    static let paragraphStyle: UInt32 = 0x2000_342C
    static let paragraphStyleID: UInt32 = 0x1C00_345A
    static let paragraphAlignment: UInt32 = 0x0C00_3477
    static let bold: UInt32 = 0x0800_1C04
    static let italic: UInt32 = 0x0800_1C05
    static let underline: UInt32 = 0x0800_1C06
    static let strikethrough: UInt32 = 0x0800_1C07
    static let superscript: UInt32 = 0x0800_1C08
    static let subscriptFlag: UInt32 = 0x0800_1C09
    static let fontName: UInt32 = 0x1C00_1C0A
    static let fontSize: UInt32 = 0x1000_1C0B
    static let fontColor: UInt32 = 0x1400_1C0C
    static let highlight: UInt32 = 0x1400_1C0D
    static let hyperlink: UInt32 = 0x0800_1E14
    static let numberListFormat: UInt32 = 0x1C00_1C1A
    static let columnWidths: UInt32 = 0x1C00_1D66
    static let cellShading: UInt32 = 0x1400_1E26
    static let pictureContainer: UInt32 = 0x2000_1C3F
    static let pictureWidth: UInt32 = 0x1400_34CD
    static let pictureHeight: UInt32 = 0x1400_34CE
    static let embeddedFileContainer: UInt32 = 0x2000_1D9B
    static let embeddedFileName: UInt32 = 0x1C00_1D9C
    static let noteTagStates: UInt32 = 0x4000_3489
    static let noteTagLabel: UInt32 = 0x1C00_346E
    static let actionItemStatus: UInt32 = 0x1000_3470
    static let sectionColor: UInt32 = 0x1400_1CBE

    /// OneNote measures positions in half-inches (48 screen points at OneNote's 96 dpi, matching the 4:3 font scale).
    static let halfInch: CGFloat = 48
    static let fontScale: CGFloat = 4.0 / 3.0

    // MARK: - Sections

    /// The section name without OneNote's backup date, e.g. "Notes (On 10-3-2026)" → "Notes".
    static func sectionName(_ url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent
        if let range = name.range(of: #"\s*\(On [^)]*\)$"#, options: .regularExpression) {
            return String(name[..<range.lowerBound])
        }
        return name
    }

    static func section(at url: URL, searchFolders: [URL]) throws -> ImportedOneNoteSection {
        let file = try OneStoreReader.read(url)
        var section = ImportedOneNoteSection(name: sectionName(url), color: nil, pages: [])
        guard let root = file.spaces[file.rootSpace] else { return section }
        if let meta = root.object(root.roots[2]), meta.jcid == sectionMetaData, let color = u32(meta, sectionColor) {
            section.color = noteColor(colorRef(color))
        }
        var order: [ExGUID] = []
        if let sectionObject = root.object(root.roots[1]) {
            for series in objects(root, sectionObject, contentChildNodes) where series.jcid == pageSeriesNode {
                if case .objectSpaceIDs(let ids)? = series.properties[childGraphSpaces] {
                    order += ids.compactMap { $0 }
                }
            }
        }
        // Pages the series lists don't mention still get imported, after the others.
        let rest = file.spaces.keys.filter { $0 != file.rootSpace && !order.contains($0) }
            .sorted { (pageCreated(file.spaces[$0]) ?? .distantPast) < (pageCreated(file.spaces[$1]) ?? .distantPast) }
        let resolver = FileResolver(sectionURL: url, folders: searchFolders)
        for id in order + rest {
            guard let space = file.spaces[id] else { continue }
            var builder = PageBuilder(space: space, files: resolver)
            guard var page = builder.build() else { continue }
            if page.title.isEmpty { page.title = "Untitled Page" }
            section.pages.append(page)
        }
        section.missingFiles = resolver.missing
        return section
    }

    private static func pageCreated(_ space: ObjectSpace?) -> Date? {
        guard let space, let meta = space.object(space.roots[2]), case .u64(let time)? = meta.properties[creationTime] else { return nil }
        return fileTime(time)
    }

    static func fileTime(_ value: UInt64) -> Date? {
        guard value > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(value) / 10_000_000 - 11_644_473_600)
    }

    // MARK: - Property helpers

    static func objects(_ space: ObjectSpace, _ object: StoreObject, _ key: UInt32) -> [StoreObject] {
        switch object.properties[key] {
        case .objectIDs(let ids)?: ids.compactMap { space.object($0) }
        case .objectID(let id)?: space.object(id).map { [$0] } ?? []
        default: []
        }
    }

    static func u32(_ object: StoreObject, _ key: UInt32) -> UInt32? {
        switch object.properties[key] {
        case .u32(let v)?: v
        case .u16(let v)?: UInt32(v)
        case .u8(let v)?: UInt32(v)
        default: nil
        }
    }

    static func float(_ object: StoreObject, _ key: UInt32) -> CGFloat? {
        guard case .u32(let bits)? = object.properties[key] else { return nil }
        let value = CGFloat(Float(bitPattern: bits))
        return value.isFinite ? value : nil
    }

    static func bool(_ object: StoreObject, _ key: UInt32) -> Bool {
        if case .bool(let b)? = object.properties[key] { return b }
        return false
    }

    static func string(_ object: StoreObject, _ key: UInt32) -> String? {
        guard case .bytes(let data)? = object.properties[key] else { return nil }
        var text = String(data: data, encoding: .utf16LittleEndian) ?? ""
        while text.hasSuffix("\0") { text.removeLast() }
        return text
    }

    /// COLORREF (0x00BBGGRR); 0xFFxxxxxx means automatic.
    static func colorRef(_ value: UInt32) -> NSColor? {
        guard value >> 24 != 0xFF else { return nil }
        return NSColor(srgbRed: CGFloat(value & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                       blue: CGFloat((value >> 16) & 0xFF) / 255, alpha: 1)
    }

    static func noteColor(_ color: NSColor?) -> NoteColor? {
        guard let c = color?.usingColorSpace(.sRGB) else { return nil }
        return NoteColor.allCases.min { a, b in
            func distance(_ n: NoteColor) -> CGFloat {
                let x = n.nsColor.usingColorSpace(.sRGB)!
                return pow(x.redComponent - c.redComponent, 2) + pow(x.greenComponent - c.greenComponent, 2)
                    + pow(x.blueComponent - c.blueComponent, 2)
            }
            return distance(a) < distance(b)
        }
    }

    // MARK: - Files kept outside the section

    /// Finds pictures and attachments: inside the section file, or in a OneNote "onefiles" folder nearby.
    final class FileResolver {
        private var index: [String: URL]?
        private let neighbors: [URL]
        private let chosen: [URL]
        private(set) var missing = 0

        /// `folders`: folders chosen to look in (searched with their subfolders, e.g. a onefiles folder).
        init(sectionURL: URL, folders: [URL]) {
            var nearby: [URL] = []
            var folder = sectionURL.deletingLastPathComponent()
            for _ in 0..<4 {
                nearby.append(folder)
                folder = folder.deletingLastPathComponent()
            }
            neighbors = nearby
            chosen = folders
        }

        /// The GUID a OneNote file reference or a file name contains, lowercased.
        static func guid(in text: String) -> String? {
            guard let range = text.range(of: "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}",
                                         options: .regularExpression) else { return nil }
            return text[range].lowercased()
        }

        static func guid(of object: StoreObject) -> String? {
            object.fileReference.flatMap { guid(in: $0) }
        }

        func data(for object: StoreObject) -> Data? {
            if let data = object.fileData { return data }
            guard let guid = Self.guid(of: object) else { return nil }
            if index == nil { index = Self.buildIndex(neighbors: neighbors, chosen: chosen) }
            if let url = index?[guid], let data = try? Data(contentsOf: url) { return data }
            missing += 1
            return nil
        }

        /// Files named with a GUID (OneNote writes them as "{GUID}.ext.onebin" or similar): in "onefiles" folders next
        /// to the sections, and anywhere inside chosen folders.
        static func buildIndex(neighbors: [URL], chosen: [URL]) -> [String: URL] {
            var result: [String: URL] = [:]
            let fm = FileManager.default
            func scan(_ root: URL) {
                guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey],
                                                     options: [.skipsHiddenFiles]) else { return }
                var count = 0
                for case let url as URL in enumerator {
                    count += 1
                    if count > 50_000 { break }
                    if let guid = guid(in: url.lastPathComponent), result[guid] == nil,
                       (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                        result[guid] = url
                    }
                }
            }
            for folder in neighbors {
                let items = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
                for item in items where item.lastPathComponent.lowercased() == "onefiles" { scan(item) }
            }
            for folder in chosen { scan(folder) }
            return result
        }
    }

    /// A picture placed in text (kept when the text is saved as RTFD), scaled to at most 480 points wide.
    static func pictureAttachment(_ data: Data, ext: String, width: CGFloat, height: CGFloat) -> NSAttributedString {
        let wrapper = FileWrapper(regularFileWithContents: data)
        wrapper.preferredFilename = "picture." + (ext.isEmpty ? "png" : ext)
        let attachment = NSTextAttachment(fileWrapper: wrapper)
        var size = NSSize(width: width, height: height)
        if size.width <= 0 || size.height <= 0, let image = NSImage(data: data) { size = image.size }
        if size.width > 480 { size = NSSize(width: 480, height: size.height * 480 / size.width) }
        resize(attachment, to: size)
        return NSAttributedString(attachment: attachment)
    }

    /// Draws a picture in text at the given size (the picture's own size is used otherwise).
    static func resize(_ attachment: NSTextAttachment, to size: NSSize) {
        if let data = attachment.fileWrapper?.regularFileContents, let image = NSImage(data: data) {
            image.size = size
            attachment.attachmentCell = NSTextAttachmentCell(imageCell: image)
        }
        attachment.bounds = CGRect(origin: .zero, size: size)
    }

    /// The size a picture in text is drawn at.
    static func displaySize(_ attachment: NSTextAttachment) -> NSSize {
        if let cell = attachment.attachmentCell as? NSTextAttachmentCell, let image = cell.image { return image.size }
        if attachment.bounds.width > 0 { return attachment.bounds.size }
        return attachment.fileWrapper?.regularFileContents.flatMap(NSImage.init(data:))?.size ?? .zero
    }

    /// Link on the note left where a picture couldn't be found; it records the picture to look for later.
    static let missingScheme = "mxnoteone-missing"

    static func missingPictureLink(guid: String, ext: String, width: CGFloat, height: CGFloat) -> URL? {
        var components = URLComponents()
        components.scheme = missingScheme
        components.host = "picture"
        components.path = "/" + guid
        components.queryItems = [URLQueryItem(name: "ext", value: ext),
                                 URLQueryItem(name: "w", value: String(Int(width))),
                                 URLQueryItem(name: "h", value: String(Int(height)))]
        return components.url
    }

    // MARK: - Pages

    struct PageBuilder {
        let space: ObjectSpace
        let files: FileResolver
        var elements: [PageElement] = []
        var assets: [UUID: (Data, String)] = [:]

        init(space: ObjectSpace, files: FileResolver) {
            self.space = space
            self.files = files
        }

        mutating func build() -> ImportedOneNotePage? {
            guard let manifest = space.object(space.roots[1]) else { return nil }
            let page = manifest.jcid == pageNode ? manifest
                : objects(space, manifest, elementChildNodes).first { $0.jcid == pageNode }
            guard let page else { return nil }
            let meta = space.object(space.roots[2])
            var title = meta.flatMap { string($0, cachedTitle) } ?? ""
            if title.isEmpty, let titleNode = objects(space, page, structureChildNodes).first(where: { $0.jcid == titleNode }) {
                title = objects(space, titleNode, contentChildNodes).map { plainText(of: $0) }.joined(separator: " ")
            }
            let level = meta.flatMap { u32($0, pageLevel) }.map { max(0, Int($0) - 1) } ?? 0
            let created = meta.flatMap { m -> Date? in
                if case .u64(let t)? = m.properties[creationTime] { return fileTime(t) }
                return nil
            }
            for node in objects(space, page, contentChildNodes) {
                let x = (float(node, offsetX) ?? 1) * halfInch + 12
                let y = (float(node, offsetY) ?? 3) * halfInch + 50
                switch node.jcid {
                case outlineNode:
                    let width = min(max((float(node, maxWidth) ?? 13) * halfInch, 160), 1000)
                    outline(node, x: x, y: y, width: width)
                case imageNode:
                    _ = image(node, x: x, y: y)
                case embeddedFileNode:
                    file(node, x: x, y: y)
                default:
                    break
                }
            }
            return ImportedOneNotePage(title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                                       level: min(level, 2), created: created, elements: elements, assets: assets)
        }

        private func plainText(of outline: StoreObject) -> String {
            var builder = TextBuilder(space: space)
            for oe in objects(space, outline, contentChildNodes) { builder.outlineElement(oe, depth: 0) }
            return builder.text.string.replacingOccurrences(of: "\n", with: " ")
        }

        /// An outline: text becomes text containers; tables, pictures and files become their own containers.
        private mutating func outline(_ node: StoreObject, x: CGFloat, y: CGFloat, width: CGFloat) {
            var cursor = y
            var builder = TextBuilder(space: space)
            var pending: [StoreObject] = []
            builder.onBlock = { pending.append($0) }
            func flush(_ text: inout NSMutableAttributedString) -> CGFloat {
                while let last = text.string.last, last == "\n" || last == " " {
                    text.deleteCharacters(in: NSRange(location: text.length - 1, length: 1))
                }
                guard text.length > 0 else { return 0 }
                let element = OneNoteHTML.textElement(text, x: x, y: cursor, width: width)
                elements.append(element)
                text = NSMutableAttributedString()
                return element.height + 6
            }
            for oe in objects(space, node, contentChildNodes) {
                builder.outlineElement(oe, depth: 0)
                if !pending.isEmpty {
                    cursor += flush(&builder.text)
                    for block in pending {
                        switch block.jcid {
                        case tableNode:
                            if let table = table(block) {
                                var element = PageElement(kind: .table, x: x, y: cursor, width: table.columnWidths.reduce(0, +))
                                element.table = table
                                element.height = ElementView.gripHeight + CGFloat(table.rows.count) * 28
                                elements.append(element)
                                cursor += element.height + 8
                            }
                        case imageNode:
                            cursor += image(block, x: x, y: cursor) + 8
                        case embeddedFileNode:
                            file(block, x: x, y: cursor)
                            cursor += 64
                        default:
                            break
                        }
                    }
                    pending = []
                }
            }
            _ = flush(&builder.text)
        }

        private func table(_ node: StoreObject) -> TableData? {
            let rows = objects(space, node, contentChildNodes).filter { $0.jcid == tableRowNode }
            guard !rows.isEmpty else { return nil }
            var texts: [[String]] = [], rich: [[Data?]] = [], shading: [[RGBA?]] = []
            for row in rows {
                var rowTexts: [String] = [], rowRich: [Data?] = [], rowShading: [RGBA?] = []
                for cell in objects(space, row, contentChildNodes) where cell.jcid == tableCellNode {
                    var builder = TextBuilder(space: space)
                    builder.files = files
                    for oe in objects(space, cell, contentChildNodes) { builder.outlineElement(oe, depth: 0) }
                    let text = builder.text
                    while let last = text.string.last, last == "\n" || last == " " {
                        text.deleteCharacters(in: NSRange(location: text.length - 1, length: 1))
                    }
                    rowTexts.append(text.string)
                    rowRich.append(TableModel.isPlain(text, header: false)
                        ? nil : TableData.cellData(text))
                    rowShading.append(u32(cell, cellShading).flatMap { colorRef($0) }.map { RGBA($0) })
                }
                texts.append(rowTexts)
                rich.append(rowRich)
                shading.append(rowShading)
            }
            let columns = max(texts.map(\.count).max() ?? 1, 1)
            var table = TableData(rows: texts.count, columns: columns)
            table.rows = texts.map { $0 + Array(repeating: "", count: columns - $0.count) }
            table.headerRow = false
            if case .bytes(let data)? = node.properties[columnWidths], data.count >= 5 {
                var r = ByteReader(data)
                let count = Int((try? r.u8()) ?? 0)
                let widths = (0..<count).compactMap { _ in (try? r.u32()).map { Double(Float(bitPattern: $0)) * Double(halfInch) } }
                if widths.count == columns, widths.allSatisfy({ $0.isFinite && $0 > 4 }) { table.columnWidths = widths.map { max($0, 30) } }
            }
            if table.columnWidths.count != columns { table.columnWidths = Array(repeating: 120, count: columns) }
            if rich.contains(where: { $0.contains { $0 != nil } }) {
                table.rich = TableData.padded(rich, rows: texts.count, columns: columns)
            }
            if shading.contains(where: { $0.contains { $0 != nil } }) {
                table.shading = TableData.padded(shading, rows: texts.count, columns: columns)
            }
            return table
        }

        /// Adds a picture; returns its height.
        private mutating func image(_ node: StoreObject, x: CGFloat, y: CGFloat) -> CGFloat {
            let container = objects(space, node, pictureContainer).first
            let width = (float(node, pictureWidth) ?? 8) * halfInch
            let height = (float(node, pictureHeight) ?? 6) * halfInch
            guard let container, let data = files.data(for: container), NSImage(data: data) != nil else {
                // Keep a note where a picture couldn't be found; its link remembers which picture to look for.
                var attrs: [NSAttributedString.Key: Any] = [.font: Prefs.defaultFont, .foregroundColor: NSColor.gray]
                if let container, let guid = FileResolver.guid(of: container),
                   let link = missingPictureLink(guid: guid, ext: container.fileExtension ?? "png", width: width, height: height) {
                    attrs[.link] = link
                }
                let note = NSAttributedString(string: "🖼 Picture not found — click to locate the OneNote “onefiles” folder", attributes: attrs)
                elements.append(OneNoteHTML.textElement(note, x: x, y: y, width: max(min(width, 520), 300)))
                return 30
            }
            var element = PageElement(kind: .image, x: x, y: y, width: max(width, 24),
                                      height: ElementView.gripHeight + max(height, 16))
            element.asset = "pending"
            assets[element.id] = (data, container.fileExtension?.isEmpty == false ? container.fileExtension! : "png")
            elements.append(element)
            return element.height
        }

        private mutating func file(_ node: StoreObject, x: CGFloat, y: CGFloat) {
            guard let container = objects(space, node, embeddedFileContainer).first, let data = files.data(for: container) else { return }
            let name = string(node, embeddedFileName) ?? "Attachment.\(container.fileExtension ?? "bin")"
            let kind: PageElement.Kind = UTType(filenameExtension: (name as NSString).pathExtension)?.conforms(to: .audio) == true ? .audio : .file
            var element = PageElement(kind: kind, x: x, y: y, width: 280, height: ElementView.gripHeight + 46)
            element.asset = "pending"
            element.fileName = name
            assets[element.id] = (data, (name as NSString).pathExtension)
            elements.append(element)
        }
    }

    // MARK: - Text

    /// Builds MxNoteONE text (bullets "• ", numbers "1. ", tags, tab indents) from outline elements.
    struct TextBuilder {
        let space: ObjectSpace
        var text = NSMutableAttributedString()
        /// Tables, pictures and files met in the text (handled by the caller).
        var onBlock: ((StoreObject) -> Void)?
        /// Inside a table cell: pictures go into the text (found through this resolver).
        var files: FileResolver?
        private var counters: [Int: Int] = [:]

        init(space: ObjectSpace) {
            self.space = space
        }

        mutating func outlineElement(_ oe: StoreObject, depth: Int) {
            let list = objects(space, oe, listNodes).first
            var prefix = String(repeating: "\t", count: depth)
            if let list {
                let format = string(list, numberListFormat) ?? ""
                if format.contains("\u{FFFD}") || format.unicodeScalars.contains(where: { $0.value >= 0x30 && $0.value <= 0x39 }) {
                    let n = (counters[depth] ?? 0) + 1
                    counters[depth] = n
                    prefix += "\(n). "
                } else {
                    counters[depth] = nil
                    prefix += TextFormatter.bullet
                }
            } else {
                counters[depth] = nil
            }
            if let (tag, done) = tag(oe) { prefix += (tag == .todo && done ? TagKind.todoDone : tag.symbol) + " " }
            var first = true
            for content in objects(space, oe, elementChildNodes) {
                switch content.jcid {
                case richTextNode:
                    let runs = richText(content)
                    if let (tag, done) = tag(content), !prefix.contains(tag.symbol) {
                        prefix += (tag == .todo && done ? TagKind.todoDone : tag.symbol) + " "
                    }
                    if first, !prefix.isEmpty {
                        var attrs = runs.length > 0 ? runs.attributes(at: 0, effectiveRange: nil) : TextFormatter.defaultAttributes
                        attrs[.link] = nil
                        text.append(NSAttributedString(string: prefix, attributes: attrs))
                    }
                    text.append(runs)
                    text.append(NSAttributedString(string: "\n", attributes: TextFormatter.defaultAttributes))
                    first = false
                case tableNode, imageNode, embeddedFileNode:
                    if let onBlock {
                        onBlock(content)
                    } else if content.jcid == imageNode {
                        if !text.string.isEmpty, !text.string.hasSuffix("\n") {
                            text.append(NSAttributedString(string: "\n", attributes: TextFormatter.defaultAttributes))
                        }
                        if !prefix.isEmpty, first {
                            text.append(NSAttributedString(string: prefix, attributes: TextFormatter.defaultAttributes))
                        }
                        text.append(inlinePicture(content))
                        text.append(NSAttributedString(string: "\n", attributes: TextFormatter.defaultAttributes))
                        first = false
                    } else if content.jcid == tableNode {
                        // Inside a table cell: keep the nested table's text.
                        for row in objects(space, content, contentChildNodes) {
                            for cell in objects(space, row, contentChildNodes) {
                                for inner in objects(space, cell, contentChildNodes) { outlineElement(inner, depth: depth + 1) }
                            }
                        }
                    }
                default:
                    break
                }
            }
            for child in objects(space, oe, contentChildNodes) where child.jcid == outlineElementNode {
                outlineElement(child, depth: depth + 1)
            }
        }

        /// A picture in a table cell: the picture itself, or a note whose link remembers the missing picture.
        private func inlinePicture(_ node: StoreObject) -> NSAttributedString {
            let container = objects(space, node, pictureContainer).first
            let width = (float(node, pictureWidth) ?? 4) * halfInch
            let height = (float(node, pictureHeight) ?? 3) * halfInch
            if let container, let data = files?.data(for: container), NSImage(data: data) != nil {
                return OneNoteImport.pictureAttachment(data, ext: container.fileExtension ?? "png", width: width, height: height)
            }
            var attrs: [NSAttributedString.Key: Any] = [.font: Prefs.defaultFont, .foregroundColor: NSColor.gray]
            if let container, let guid = FileResolver.guid(of: container),
               let link = missingPictureLink(guid: guid, ext: container.fileExtension ?? "png", width: width, height: height) {
                attrs[.link] = link
            }
            return NSAttributedString(string: "🖼 Picture not found — click to locate", attributes: attrs)
        }

        /// A note tag on a paragraph: its label (To Do, Important…) and whether it is checked.
        private func tag(_ object: StoreObject) -> (TagKind, Bool)? {
            guard case .propertyValues(let states)? = object.properties[noteTagStates] else { return nil }
            for state in states {
                var label = ""
                var done = false
                for (key, value) in state.values {
                    switch value {
                    case .objectID(let id):
                        if let definition = space.object(id) {
                            label = string(definition, noteTagLabel) ?? label
                        }
                    case .u16(let v) where key == actionItemStatus:
                        done = v & 1 != 0
                    case .u32(let v) where key == actionItemStatus:
                        done = v & 1 != 0
                    default:
                        break
                    }
                }
                let lower = label.lowercased()
                let kind: TagKind? = lower.contains("to do") || lower.contains("to-do") ? .todo
                    : lower.contains("important") ? .important
                    : lower.contains("question") ? .question
                    : lower.contains("critical") ? .critical
                    : lower.contains("idea") ? .idea
                    : lower.contains("remember") ? .remember
                    : lower.contains("definition") ? .definition
                    : lower.contains("phone") || lower.contains("contact") ? .contact
                    : lower.contains("discuss") ? .discuss
                    : label.isEmpty ? nil : .important
                if let kind { return (kind, done) }
            }
            return nil
        }

        /// The text of a rich text node with its formatting runs.
        private func richText(_ node: StoreObject) -> NSAttributedString {
            var string = OneNoteImport.string(node, textUnicode)
            if string == nil, case .bytes(let data)? = node.properties[textASCII] {
                string = String(data: data, encoding: .windowsCP1252) ?? String(decoding: data, as: UTF8.self)
                while string?.hasSuffix("\0") == true { string?.removeLast() }
            }
            let raw = string ?? ""
            let ns = raw as NSString
            let style = objects(space, node, paragraphStyle).first
            var base = TextFormatter.defaultAttributes
            if let style { base.merge(attributes(style, over: base)) { $1 } }
            if let styleID = style.flatMap({ OneNoteImport.string($0, paragraphStyleID) }) {
                let heading: TextStyleKind? = ["h1": .heading1, "h2": .heading2, "h3": .heading3, "h4": .heading4,
                                               "PageTitle": .title, "cite": .quote, "code": .code][styleID]
                if let heading, style.map({ $0.properties[fontSize] == nil }) ?? true {
                    base.merge(heading.attributes) { $1 }
                }
            }
            if let alignment = u32(node, paragraphAlignment), alignment != 0 {
                let paragraph = NSMutableParagraphStyle()
                paragraph.alignment = alignment == 1 ? .center : (alignment == 2 ? .right : .left)
                base[.paragraphStyle] = paragraph
            }
            let result = NSMutableAttributedString(string: raw, attributes: base)
            let formats = objects(space, node, runFormatting)
            var ends: [Int] = []
            if case .bytes(let data)? = node.properties[runIndex] {
                var r = ByteReader(data)
                while r.remaining >= 4, let v = try? r.u32() { ends.append(Int(v)) }
            }
            var start = 0
            for (i, format) in formats.enumerated() {
                let end = min(i < ends.count ? ends[i] : ns.length, ns.length)
                guard end > start else { continue }
                var attrs = attributes(format, over: base)
                if bool(format, hyperlink) { attrs[.mxHyperlinkRun] = true }
                result.setAttributes(attrs, range: NSRange(location: start, length: end - start))
                start = end
            }
            applyHyperlinks(result)
            return result
        }

        /// Character formatting of a OneNote formatting object.
        private func attributes(_ format: StoreObject, over base: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
            var attrs = base
            let fm = NSFontManager.shared
            var font = base[.font] as? NSFont ?? Prefs.defaultFont
            var substitute = false
            if let name = string(format, fontName), !name.isEmpty {
                font = fm.convert(font, toFamily: name)
                if font.familyName != name {
                    font = fm.convert(font, toFamily: Prefs.fontName)
                    substitute = true
                }
            }
            if let size = u32(format, fontSize), size > 0 {
                // A missing OneNote font (Calibri…) is narrower than the substitute; shrink it a little to keep the layout.
                font = fm.convert(font, toSize: CGFloat(size) / 2 * fontScale * (substitute ? 0.92 : 1))
            }
            if case .bool? = format.properties[bold] {
                font = bool(format, bold) ? fm.convert(font, toHaveTrait: .boldFontMask) : fm.convert(font, toNotHaveTrait: .boldFontMask)
            }
            if case .bool? = format.properties[italic] {
                font = bool(format, italic) ? fm.convert(font, toHaveTrait: .italicFontMask) : fm.convert(font, toNotHaveTrait: .italicFontMask)
            }
            attrs[.font] = font
            if bool(format, underline) { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            if bool(format, strikethrough) { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if bool(format, superscript) { attrs[.superscript] = 1 }
            if bool(format, subscriptFlag) { attrs[.superscript] = -1 }
            if let color = u32(format, fontColor).flatMap({ colorRef($0) }) { attrs[.foregroundColor] = color }
            if let color = u32(format, highlight).flatMap({ colorRef($0) }) { attrs[.backgroundColor] = color }
            return attrs
        }

        static let fieldMark: UInt16 = 0xFDDF

        /// OneNote writes links as a field: "\u{FDDF}HYPERLINK \"url\"" followed by the link text.
        private func applyHyperlinks(_ text: NSMutableAttributedString) {
            let pattern = try! NSRegularExpression(pattern: "\\x{FDDF}HYPERLINK\\s+\"([^\"]*)\"\\s?")
            for match in pattern.matches(in: text.string, range: NSRange(location: 0, length: text.length)).reversed() {
                let url = (text.string as NSString).substring(with: match.range(at: 1))
                text.deleteCharacters(in: match.range)
                var end = match.range.location
                while end < text.length, text.attribute(.mxHyperlinkRun, at: end, effectiveRange: nil) != nil,
                      (text.string as NSString).character(at: end) != Self.fieldMark {
                    end += 1
                }
                if end == match.range.location {
                    // No marked run: link up to the end of the word.
                    let rest = (text.string as NSString).substring(from: end)
                    end += (rest.firstIndex(where: \.isWhitespace).map { rest.distance(from: rest.startIndex, to: $0) } ?? rest.count)
                }
                if end > match.range.location, let link = URL(string: url) {
                    text.addAttribute(.link, value: link, range: NSRange(location: match.range.location, length: end - match.range.location))
                }
            }
            text.removeAttribute(.mxHyperlinkRun, range: NSRange(location: 0, length: text.length))
            text.mutableString.replaceOccurrences(of: String(UnicodeScalar(Self.fieldMark)!), with: "",
                                                  range: NSRange(location: 0, length: text.length))
        }
    }

    // MARK: - Importing into notebooks

    /// Section files in a folder tree: (path of section group names, file). Backup copies of the same
    /// section ("Name (On date).one") keep only the newest. The recycle bin folder is skipped.
    static func sectionFiles(in folder: URL) -> [([String], URL)] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: folder, includingPropertiesForKeys: [.contentModificationDateKey],
                                             options: [.skipsHiddenFiles]) else { return [] }
        var newest: [String: ([String], URL, Date)] = [:]
        for case let url as URL in enumerator {
            let relative = url.path.dropFirst(folder.path.count).split(separator: "/").map(String.init)
            if relative.contains(where: { $0.caseInsensitiveCompare("OneNote_RecycleBin") == .orderedSame }) { continue }
            guard url.pathExtension.lowercased() == "one" else { continue }
            let groups = Array(relative.dropLast())
            let key = (groups + [sectionName(url)]).joined(separator: "/").lowercased()
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if let existing = newest[key], existing.2 >= date { continue }
            newest[key] = (groups, url, date)
        }
        return newest.values.map { ($0.0, $0.1) }.sorted {
            ($0.0.joined(separator: "/"), sectionName($0.1).lowercased()) < ($1.0.joined(separator: "/"), sectionName($1.1).lowercased())
        }
    }

    /// Unpacks a .onepkg (a cabinet archive) into a temporary folder.
    static func unpack(_ package: URL) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "MxNoteONE-onepkg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for tool in [("/usr/bin/tar", ["-xf", package.path, "-C", folder.path]),
                     ("/opt/homebrew/bin/7z", ["x", "-y", "-o" + folder.path, package.path]),
                     ("/usr/local/bin/7z", ["x", "-y", "-o" + folder.path, package.path])]
            where FileManager.default.isExecutableFile(atPath: tool.0) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool.0)
            process.arguments = tool.1
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0, !sectionFiles(in: folder).isEmpty { return folder }
        }
        throw OneStoreError.notOneNote
    }
}

extension NSAttributedString.Key {
    /// Marks text runs OneNote flagged as hyperlink text while importing (never saved).
    static let mxHyperlinkRun = NSAttributedString.Key("MxHyperlinkRun")
}
