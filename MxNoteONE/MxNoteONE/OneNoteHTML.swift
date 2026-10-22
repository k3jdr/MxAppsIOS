//
//  OneNoteHTML.swift
//  MxNoteONE
//
//  Converts pages to and from the HTML that the OneNote API reads and
//  writes. Containers keep their position (absolute positioning); text
//  keeps fonts, sizes, colours, highlights, bold / italic / underline /
//  strikethrough, alignment, bullets, numbering, links and tags (To Do
//  check marks included); tables, pictures and attached files carry over.
//  Ink is sent as a picture. OneNote point sizes are scaled 4:3 to
//  MxNoteONE's screen points.
//

import AppKit
import UniformTypeIdentifiers

enum OneNoteHTML {
    static let fontScale: CGFloat = 4.0 / 3.0

    static let tagNames: [TagKind: String] = [
        .todo: "to-do", .important: "important", .question: "question", .critical: "critical", .idea: "idea",
        .remember: "remember-for-later", .definition: "definition", .contact: "phone-number",
        .discuss: "discuss-with-person-a",
    ]

    // MARK: - Export

    struct Export {
        var html: String
        var parts: [GraphClient.Part]
    }

    static func export(_ content: PageContent, assetData: (String) -> Data?) -> Export {
        var parts: [GraphClient.Part] = []
        let grip = Double(ElementView.gripHeight)
        let base = Prefs.defaultFont
        var body = ""
        for element in content.elements {
            let x = Int(element.x.rounded()), y = Int((element.y + grip).rounded()), w = Int(element.width.rounded())
            switch element.kind {
            case .text:
                guard let data = element.rtfd, let text = NoteRichText.text(data),
                      text.length > 0 else { continue }
                body += "<div style=\"position:absolute;left:\(x)px;top:\(y)px;width:\(w)px\">"
                body += textHTML(text, parts: &parts) + "</div>\n"
            case .table:
                guard let table = element.table, !table.rows.isEmpty else { continue }
                let total = table.columnWidths.reduce(0, +)
                body += "<div style=\"position:absolute;left:\(x)px;top:\(y)px;width:\(w)px\"><table border=\"1\">"
                for (r, row) in table.rows.enumerated() {
                    body += "<tr>"
                    for (c, cell) in row.enumerated() {
                        let width = c < table.columnWidths.count && total > 0 ? Int(element.width * table.columnWidths[c] / total) : 120
                        let header = table.headerRow && r == 0
                        var cellStyle = "width:\(width)px"
                        if let shade = table.shade(r, c) { cellStyle += ";background-color:\(hex(shade.nsColor))" }
                        if table.textIsLight(r, c) { cellStyle += ";color:#FFFFFF" }
                        if table.hideBorders == true { cellStyle += ";border:none" }
                        body += "<td style=\"\(cellStyle)\">"
                        if let rtf = table.richData(r, c), let rich = TableData.attributedCell(rtf) {
                            body += textHTML(rich, parts: &parts)
                        } else {
                            let lines = cell.components(separatedBy: "\n").map { escape($0) }
                            let content = lines.joined(separator: "<br />")
                            body += header ? "<span style=\"font-weight:bold\">\(content)</span>" : content
                        }
                        body += "</td>"
                    }
                    body += "</tr>"
                }
                body += "</table></div>\n"
            case .model:
                // OneNote has no 3D models: its picture.
                guard let model = element.cad else { continue }
                let height = max(element.height - grip, 10)
                guard let png = CADElementView.picture(of: model, size: NSSize(width: max(element.width, 40), height: height))?.pngData else { continue }
                let name = "img\(parts.count)"
                parts.append(GraphClient.Part(name: name, contentType: "image/png", data: png))
                body += "<img style=\"position:absolute;left:\(x)px;top:\(y)px\" width=\"\(w)\" height=\"\(Int(height.rounded()))\" src=\"name:\(name)\" />\n"
            case .map:
                // OneNote has no maps: its picture, and its pins in a list.
                guard let map = element.map else { continue }
                body += "<div style=\"position:absolute;left:\(x)px;top:\(y)px;width:\(w)px\"><p><b>\(escape(map.title ?? "Map"))</b></p>"
                if let asset = element.preview, let data = assetData(asset), let (imageData, type) = webImage(data, ext: "png") {
                    let name = "img\(parts.count)"
                    parts.append(GraphClient.Part(name: name, contentType: type, data: imageData))
                    body += "<img width=\"\(w)\" height=\"\(Int(max(element.height - grip, 10).rounded()))\" src=\"name:\(name)\" />"
                }
                if !map.pins.isEmpty { body += "<ul>" + map.pinLines(markdown: false).map { "<li>\(escape($0))</li>" }.joined() + "</ul>" }
                body += "</div>\n"
            case .dbml:
                // OneNote has no DBML diagrams: its picture, and its DBML.
                guard let d = element.dbml else { continue }
                let picture = DBMLRenderer.picture(d.diagram, scale: 1)
                let png = (picture.representations.first as? NSBitmapImageRep)?.representation(using: .png, properties: [:])
                body += "<div style=\"position:absolute;left:\(x)px;top:\(y)px;width:\(w)px\">"
                if let png {
                    let name = "img\(parts.count)"
                    parts.append(GraphClient.Part(name: name, contentType: "image/png", data: png))
                    let width = min(Double(w), picture.size.width)
                    body += "<img width=\"\(Int(width))\" height=\"\(Int((picture.size.height * width / max(picture.size.width, 1)).rounded()))\" src=\"name:\(name)\" />"
                }
                body += "<pre style=\"font-family:Consolas,Menlo,monospace;font-size:9pt\">\(escape(d.dbmlText(includingLayout: false)))</pre></div>\n"
            case .score:
                // OneNote has no scores: its title, signatures and notes in letter names.
                guard let score = element.score else { continue }
                body += "<div style=\"position:absolute;left:\(x)px;top:\(y)px;width:\(w)px\"><p><b>♪ \(escape(score.summary))</b></p>"
                body += "<p>\(escape(score.noteNames))</p></div>\n"
            case .chart:
                // OneNote has no charts: the chart's data as a table, under its title.
                guard let chart = element.chart, !chart.series.isEmpty else { continue }
                let title = chart.title.isEmpty ? "\(chart.kind.title) chart" : chart.title
                body += "<div style=\"position:absolute;left:\(x)px;top:\(y)px;width:\(w)px\"><p><b>\(escape(title))</b></p><table border=\"1\">"
                body += "<tr><td><b>\(escape(chart.categoryField))</b></td>" + chart.series.map { "<td><b>\(escape($0.name))</b></td>" }.joined() + "</tr>"
                for (i, category) in chart.categories.enumerated() {
                    let values = chart.series.map { s in "<td>\(i < s.values.count ? s.values[i].map(Formula.format) ?? "" : "")</td>" }
                    body += "<tr><td>\(escape(category))</td>" + values.joined() + "</tr>"
                }
                body += "</table></div>\n"
            case .image:
                guard let asset = element.asset, let data = assetData(asset),
                      let (imageData, type) = webImage(data, ext: (asset as NSString).pathExtension) else { continue }
                let name = "img\(parts.count)"
                parts.append(GraphClient.Part(name: name, contentType: type, data: imageData))
                let height = Int(max(element.height - grip, 10).rounded())
                body += "<img style=\"position:absolute;left:\(x)px;top:\(y)px\" width=\"\(w)\" height=\"\(height)\" src=\"name:\(name)\" />\n"
            case .diagram:
                // A diagram goes to OneNote as its picture.
                guard let asset = element.preview ?? element.asset, let data = assetData(asset),
                      let (imageData, type) = webImage(data, ext: (asset as NSString).pathExtension) else { continue }
                let name = "img\(parts.count)"
                parts.append(GraphClient.Part(name: name, contentType: type, data: imageData))
                let height = Int(max(element.height - grip, 10).rounded())
                body += "<img style=\"position:absolute;left:\(x)px;top:\(y)px\" width=\"\(w)\" height=\"\(height)\" src=\"name:\(name)\" />\n"
            case .file, .audio:
                guard let asset = element.asset, let data = assetData(asset) else { continue }
                let fileName = element.fileName ?? asset
                let name = "file\(parts.count)"
                let type = UTType(filenameExtension: (fileName as NSString).pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                parts.append(GraphClient.Part(name: name, contentType: type, data: data))
                body += "<object style=\"position:absolute;left:\(x)px;top:\(y)px\" data-attachment=\"\(escape(fileName))\" data=\"name:\(name)\" type=\"\(type)\" />\n"
            }
        }
        if let ink = inkImage(content.strokes) {
            let name = "ink\(parts.count)"
            parts.append(GraphClient.Part(name: name, contentType: "image/png", data: ink.png))
            body += "<img style=\"position:absolute;left:\(Int(ink.frame.minX))px;top:\(Int(ink.frame.minY))px\" width=\"\(Int(ink.frame.width))\" height=\"\(Int(ink.frame.height))\" src=\"name:\(name)\" alt=\"Ink\" />\n"
        }
        let created = ISO8601DateFormatter().string(from: content.created)
        let html = """
        <!DOCTYPE html>
        <html><head><title>\(escape(content.title))</title><meta name="created" content="\(created)" /></head>
        <body data-absolute-enabled="true" style="font-family:\(escape(base.familyName ?? "Calibri"));font-size:\(pt(base.pointSize))pt">
        \(body)</body></html>
        """
        return Export(html: html, parts: parts)
    }

    private static func pt(_ points: CGFloat) -> String {
        let value = Double((points / fontScale * 2).rounded() / 2)
        return value == value.rounded() ? String(Int(value)) : String(value)
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func hex(_ color: NSColor) -> String {
        let c = color.usingColorSpace(.sRGB) ?? .black
        return String(format: "#%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }

    /// Pictures OneNote accepts (PNG, JPEG, GIF); others are converted to PNG.
    private static func webImage(_ data: Data, ext: String) -> (Data, String)? {
        switch ext.lowercased() {
        case "png": return (data, "image/png")
        case "jpg", "jpeg": return (data, "image/jpeg")
        case "gif": return (data, "image/gif")
        default:
            guard let rep = NSImage(data: data)?.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)),
                  let png = rep.representation(using: .png, properties: [:]) else { return nil }
            return (png, "image/png")
        }
    }

    private static func inkImage(_ strokes: [InkStroke]) -> (png: Data, frame: CGRect)? {
        guard !strokes.isEmpty else { return nil }
        let frame = InkView.bounds(of: strokes).integral
        guard frame.width > 0, frame.height > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(frame.width * 2), pixelsHigh: Int(frame.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = frame.size
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.current = context
        let cg = context.cgContext
        cg.translateBy(x: 0, y: frame.height)
        cg.scaleBy(x: 1, y: -1)
        cg.translateBy(x: -frame.minX, y: -frame.minY)
        for stroke in strokes {
            var opaque = stroke
            if stroke.tool == .highlighter { opaque.color.a = max(stroke.color.a, 0.45) }
            InkView.draw(opaque, in: cg)
        }
        context.flushGraphics()
        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return (png, frame)
    }

    /// Paragraphs as <p> / <ul> / <ol> with inline styles and data-tag attributes.
    private static func textHTML(_ text: NSAttributedString, parts: inout [GraphClient.Part]) -> String {
        var out = ""
        var openList: String?
        let ns = text.string as NSString
        var location = 0
        func closeList() {
            if let list = openList { out += "</\(list)>" }
            openList = nil
        }
        while location < ns.length {
            let range = ns.paragraphRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(range)
            var body = range
            if body.length > 0, ns.character(at: NSMaxRange(body) - 1) == 0x0A { body.length -= 1 }
            let plain = ns.substring(with: body)
            let info = TextFormatter.parseParagraph(plain)
            var attributes = ""
            if let tag = info.tag, let name = tagNames[tag] {
                attributes += " data-tag=\"\(name)\(tag == .todo && info.tagDone ? ":completed" : "")\""
            }
            var style: [String] = []
            let tabs = plain.prefix(info.indent).filter { $0 == "\t" }.count
            if tabs > 0 { style.append("margin-left:\(tabs * 24)px") }
            if body.length > 0, let ps = text.attribute(.paragraphStyle, at: body.location, effectiveRange: nil) as? NSParagraphStyle {
                switch ps.alignment {
                case .center: style.append("text-align:center")
                case .right: style.append("text-align:right")
                case .justified: style.append("text-align:justify")
                default: break
                }
            }
            if !style.isEmpty { attributes += " style=\"\(style.joined(separator: ";"))\"" }
            let content = NSRange(location: body.location + info.contentStart, length: max(0, body.length - info.contentStart))
            let runs = runsHTML(text, content, parts: &parts)
            switch info.list {
            case .bullet?, .number?:
                let tag = info.list == .bullet ? "ul" : "ol"
                if openList != tag {
                    closeList()
                    if case .number(let n)? = info.list, n != 1 { out += "<ol start=\"\(n)\">" } else { out += "<\(tag)>" }
                    openList = tag
                }
                out += "<li\(attributes)>\(runs)</li>"
            case nil:
                closeList()
                out += "<p\(attributes)>\(runs.isEmpty ? "&nbsp;" : runs)</p>"
            }
            if range.length == 0 { break }
        }
        closeList()
        return out
    }

    private static func runsHTML(_ text: NSAttributedString, _ range: NSRange, parts: inout [GraphClient.Part]) -> String {
        guard range.length > 0 else { return "" }
        let fm = NSFontManager.shared
        let base = Prefs.defaultFont
        let ns = text.string as NSString
        var out = ""
        text.enumerateAttributes(in: range) { attrs, run, _ in
            if let attachment = attrs[.attachment] as? NSTextAttachment {
                let data = attachment.fileWrapper?.regularFileContents ?? attachment.contents
                    ?? attachment.image?.tiffRepresentation
                if let data, let (image, type) = webImage(data, ext: (attachment.fileWrapper?.preferredFilename as NSString?)?.pathExtension ?? "") {
                    let name = "img\(parts.count)"
                    parts.append(GraphClient.Part(name: name, contentType: type, data: image))
                    let size = NSImage(data: image)?.size ?? .zero
                    out += "<img src=\"name:\(name)\"\(size.width > 0 ? " width=\"\(Int(min(size.width, 600)))\"" : "") />"
                }
                return
            }
            var piece = escape(ns.substring(with: run)).replacingOccurrences(of: "\t", with: "&nbsp;&nbsp;&nbsp;&nbsp;")
            var style: [String] = []
            if let font = attrs[.font] as? NSFont {
                if font.familyName != base.familyName, let family = font.familyName { style.append("font-family:\(escape(family))") }
                if abs(font.pointSize - base.pointSize) > 0.5 { style.append("font-size:\(pt(font.pointSize))pt") }
                let traits = fm.traits(of: font)
                if traits.contains(.boldFontMask) { style.append("font-weight:bold") }
                if traits.contains(.italicFontMask) { style.append("font-style:italic") }
            }
            var decorations: [String] = []
            if (attrs[.underlineStyle] as? Int ?? 0) != 0 { decorations.append("underline") }
            if (attrs[.strikethroughStyle] as? Int ?? 0) != 0 { decorations.append("line-through") }
            if !decorations.isEmpty { style.append("text-decoration:\(decorations.joined(separator: " "))") }
            if let color = attrs[.foregroundColor] as? NSColor, hex(color) != "#000000" { style.append("color:\(hex(color))") }
            if let color = attrs[.backgroundColor] as? NSColor { style.append("background-color:\(hex(color))") }
            if let script = attrs[.superscript] as? Int, script != 0 { style.append("vertical-align:\(script > 0 ? "super" : "sub")") }
            if !style.isEmpty { piece = "<span style=\"\(style.joined(separator: ";"))\">\(piece)</span>" }
            if let link = attrs[.link] {
                let url = (link as? URL)?.absoluteString ?? (link as? String) ?? ""
                if !url.hasPrefix(NotebookStore.linkScheme + ":") { piece = "<a href=\"\(escape(url))\">\(piece)</a>" }
            }
            out += piece
        }
        return out
    }

    // MARK: - Import

    struct ImportedPage {
        var title: String
        var created: Date?
        var elements: [PageElement]
        /// Picture and file data for elements, by element ID: (data, file extension).
        var assets: [UUID: (Data, String)]
    }

    /// Parses OneNote page HTML. `download` fetches pictures and files (absolute Graph resource URLs).
    static func importPage(_ html: String, download: (String) async -> Data?) async -> ImportedPage {
        var page = ImportedPage(title: "", created: nil, elements: [], assets: [:])
        guard let doc = try? XMLDocument(xmlString: html, options: [.documentTidyHTML]) else {
            let fallback = NSAttributedString(string: html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression),
                                              attributes: TextFormatter.defaultAttributes)
            page.elements = [textElement(fallback, x: 48, y: 110, width: 624)]
            return page
        }
        page.title = (try? doc.nodes(forXPath: "//*[local-name()='title']").first?.stringValue) ?? ""
        if let created = (try? doc.nodes(forXPath: "//*[local-name()='meta'][@name='created']").first as? XMLElement)?
            .attribute(forName: "content")?.stringValue {
            page.created = GraphClient.date(created) ?? ISO8601DateFormatter().date(from: created) ?? {
                // OneNote writes e.g. 2026-09-30T10:15:00.0000000 (local time, seven fractional digits).
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
                return formatter.date(from: String(created.prefix(19)))
            }()
        }

        // Fetch pictures and files first; conversion below is synchronous.
        var resources: [String: Data] = [:]
        let media = (try? doc.nodes(forXPath: "//*[local-name()='img' or local-name()='object']")) ?? []
        for case let element as XMLElement in media {
            for name in ["data-fullres-src", "src", "data"] {
                if let url = element.attribute(forName: name)?.stringValue, url.hasPrefix("https://"), resources[url] == nil {
                    if let data = await download(url) { resources[url] = data }
                    break
                }
            }
        }

        guard let body = (try? doc.nodes(forXPath: "//*[local-name()='body']"))?.first as? XMLElement else { return page }
        var base = Context()
        base.apply(style: body.attribute(forName: "style")?.stringValue)
        let converter = Converter(resources: resources)
        var loose: [XMLNode] = []
        func flushLoose() {
            guard !loose.isEmpty else { return }
            let y = (page.elements.map { $0.y + max($0.height, 30) }.max() ?? 90) + 20
            converter.outline(loose, x: 48, y: y, width: 624, context: base, into: &page)
            loose = []
        }
        for node in body.children ?? [] {
            guard let element = node as? XMLElement, let name = element.localName?.lowercased() else {
                if !(node.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { loose.append(node) }
                continue
            }
            let style = Context.styleMap(element.attribute(forName: "style")?.stringValue)
            let left = Context.px(style["left"]), top = Context.px(style["top"])
            switch name {
            case "div" where left != nil || top != nil:
                flushLoose()
                converter.outline(element.children ?? [], x: left ?? 48, y: (top ?? 110) - ElementView.gripHeight,
                                  width: Context.px(style["width"]) ?? 624, context: base, into: &page)
            case "img":
                flushLoose()
                converter.image(element, x: left ?? 48, y: (top ?? 110) - ElementView.gripHeight, into: &page)
            case "object":
                flushLoose()
                converter.file(element, x: left ?? 48, y: (top ?? 110) - ElementView.gripHeight, into: &page)
            default:
                loose.append(element)
            }
        }
        flushLoose()
        return page
    }

    static func textElement(_ text: NSAttributedString, x: CGFloat, y: CGFloat, width: CGFloat) -> PageElement {
        var element = PageElement(kind: .text, x: max(0, x), y: max(0, y), width: max(width, 80))
        element.rtfd = NoteRichText.data(text)
        let height = text.boundingRect(with: NSSize(width: max(width - 8, 40), height: .greatestFiniteMagnitude),
                                       options: [.usesLineFragmentOrigin, .usesFontLeading]).height
        element.height = ceil(height) + 8 + ElementView.gripHeight
        return element
    }

    /// Character formatting inherited down the HTML tree.
    struct Context {
        var family = Prefs.fontName
        var size = Prefs.fontSize
        var bold = false
        var italic = false
        var underline = false
        var strike = false
        var color: NSColor?
        var background: NSColor?
        var link: URL?
        var script = 0
        var alignment: NSTextAlignment?

        static func styleMap(_ style: String?) -> [String: String] {
            var map: [String: String] = [:]
            for declaration in (style ?? "").split(separator: ";") {
                let pair = declaration.split(separator: ":", maxSplits: 1)
                guard pair.count == 2 else { continue }
                map[pair[0].trimmingCharacters(in: .whitespaces).lowercased()] = pair[1].trimmingCharacters(in: .whitespaces)
            }
            return map
        }

        static func px(_ value: String?) -> CGFloat? {
            guard let value else { return nil }
            let number = Double(value.replacingOccurrences(of: "px", with: "").replacingOccurrences(of: "pt", with: "")
                .trimmingCharacters(in: .whitespaces))
            guard let number else { return nil }
            return value.hasSuffix("pt") ? CGFloat(number) * OneNoteHTML.fontScale : CGFloat(number)
        }

        static func color(_ value: String?) -> NSColor? {
            guard var value = value?.trimmingCharacters(in: .whitespaces).lowercased(), !value.isEmpty else { return nil }
            let names: [String: String] = ["black": "#000000", "white": "#ffffff", "red": "#ff0000", "green": "#008000",
                                           "blue": "#0000ff", "yellow": "#ffff00", "gray": "#808080", "grey": "#808080",
                                           "orange": "#ffa500", "purple": "#800080", "aqua": "#00ffff", "lime": "#00ff00"]
            value = names[value] ?? value
            if value.hasPrefix("rgb") {
                let numbers = value.components(separatedBy: CharacterSet(charactersIn: "0123456789.").inverted)
                    .compactMap(Double.init)
                guard numbers.count >= 3 else { return nil }
                return NSColor(srgbRed: numbers[0] / 255, green: numbers[1] / 255, blue: numbers[2] / 255, alpha: 1)
            }
            guard value.hasPrefix("#") else { return nil }
            var hex = String(value.dropFirst())
            if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
            guard hex.count == 6, let n = Int(hex, radix: 16) else { return nil }
            return NSColor(srgbRed: CGFloat((n >> 16) & 255) / 255, green: CGFloat((n >> 8) & 255) / 255,
                           blue: CGFloat(n & 255) / 255, alpha: 1)
        }

        mutating func apply(style: String?) {
            let map = Self.styleMap(style)
            if let family = map["font-family"]?.split(separator: ",").first?
                .trimmingCharacters(in: CharacterSet(charactersIn: "'\" ")), !family.isEmpty {
                self.family = family
            }
            if let size = map["font-size"] {
                if size.hasSuffix("pt"), let value = Double(size.dropLast(2)) { self.size = CGFloat(value) * OneNoteHTML.fontScale }
                else if let value = Self.px(size) { self.size = value }
            }
            if let weight = map["font-weight"] { bold = weight == "bold" || (Int(weight) ?? 400) >= 600 }
            if let style = map["font-style"] { italic = style == "italic" }
            if let decoration = map["text-decoration"] {
                underline = decoration.contains("underline")
                strike = decoration.contains("line-through")
            }
            if let value = map["color"], let color = Self.color(value) { self.color = color }
            if let value = map["background-color"], let color = Self.color(value) { background = color }
            if let value = map["vertical-align"] { script = value == "super" ? 1 : (value == "sub" ? -1 : 0) }
            switch map["text-align"] {
            case "center": alignment = .center
            case "right": alignment = .right
            case "justify": alignment = .justified
            case "left": alignment = .left
            default: break
            }
        }

        var attributes: [NSAttributedString.Key: Any] {
            let fm = NSFontManager.shared
            var traits: NSFontTraitMask = []
            if bold { traits.insert(.boldFontMask) }
            if italic { traits.insert(.italicFontMask) }
            var font = fm.font(withFamily: family, traits: traits, weight: 5, size: size)
                ?? fm.font(withFamily: Prefs.fontName, traits: traits, weight: 5, size: size)
                ?? .systemFont(ofSize: size)
            if bold, !fm.traits(of: font).contains(.boldFontMask) { font = fm.convert(font, toHaveTrait: .boldFontMask) }
            var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color ?? NSColor.black]
            if let background { attrs[.backgroundColor] = background }
            if underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            if strike { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if script != 0 { attrs[.superscript] = script }
            if let link { attrs[.link] = link }
            if let alignment {
                let paragraph = NSMutableParagraphStyle()
                paragraph.alignment = alignment
                attrs[.paragraphStyle] = paragraph
            }
            return attrs
        }
    }

    /// Builds page elements from OneNote outlines.
    final class Converter {
        let resources: [String: Data]

        init(resources: [String: Data]) {
            self.resources = resources
        }

        private func resource(_ element: XMLElement) -> Data? {
            for name in ["data-fullres-src", "src", "data"] {
                if let url = element.attribute(forName: name)?.stringValue, let data = resources[url] { return data }
            }
            return nil
        }

        /// An outline: text runs become text containers, tables become tables, stacked top to bottom.
        func outline(_ nodes: [XMLNode], x: CGFloat, y: CGFloat, width: CGFloat, context: Context, into page: inout ImportedPage) {
            var cursor = y
            var text = NSMutableAttributedString()
            var files: [XMLElement] = []
            func flushText() {
                while let last = text.string.last, last == "\n" || last == " " {
                    text.deleteCharacters(in: NSRange(location: text.length - 1, length: 1))
                }
                guard text.length > 0, !text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    text = NSMutableAttributedString()
                    return
                }
                let element = OneNoteHTML.textElement(text, x: x, y: cursor, width: width)
                page.elements.append(element)
                cursor += element.height + 6
                text = NSMutableAttributedString()
            }
            func walk(_ nodes: [XMLNode], _ context: Context) {
                for node in nodes {
                    guard let element = node as? XMLElement, let name = element.localName?.lowercased() else {
                        TextBuilder(resources: resources, out: text).inline(node, context)
                        continue
                    }
                    switch name {
                    case "table":
                        flushText()
                        if let table = table(element, context: context) {
                            var tableElement = PageElement(kind: .table, x: max(0, x), y: max(0, cursor),
                                                           width: max(table.columnWidths.reduce(0, +), 120))
                            tableElement.table = table
                            tableElement.height = ElementView.gripHeight + CGFloat(table.rows.count) * 30
                            page.elements.append(tableElement)
                            cursor += tableElement.height + 8
                        }
                    case "div":
                        var inner = context
                        inner.apply(style: element.attribute(forName: "style")?.stringValue)
                        walk(element.children ?? [], inner)
                    case "object":
                        files.append(element)
                    default:
                        TextBuilder(resources: resources, out: text).block(element, context, list: nil)
                    }
                }
            }
            walk(nodes, context)
            flushText()
            for file in files {
                self.file(file, x: x, y: cursor, into: &page)
                cursor += 60
            }
        }

        func table(_ element: XMLElement, context: Context) -> TableData? {
            let rows = ((try? element.nodes(forXPath: ".//*[local-name()='tr']")) ?? []).compactMap { $0 as? XMLElement }
            guard !rows.isEmpty else { return nil }
            var data: [[String]] = []
            var rich: [[Data?]] = []
            var shading: [[RGBA?]] = []
            var widths: [Double] = []
            var header = false
            for (r, row) in rows.enumerated() {
                let cells = (row.children ?? []).compactMap { $0 as? XMLElement }
                    .filter { ["td", "th"].contains($0.localName?.lowercased() ?? "") }
                if r == 0 {
                    header = cells.contains { $0.localName?.lowercased() == "th" }
                    widths = cells.map { Double(Context.px(Context.styleMap($0.attribute(forName: "style")?.stringValue)["width"]) ?? 120) }
                }
                shading.append(cells.map { cell in
                    Context.color(Context.styleMap(cell.attribute(forName: "style")?.stringValue)["background-color"]).map { RGBA($0) }
                })
                var rowRich: [Data?] = []
                data.append(cells.map { cell in
                    let text = NSMutableAttributedString()
                    let builder = TextBuilder(resources: resources, out: text)
                    for child in cell.children ?? [] {
                        if let block = child as? XMLElement, ["p", "div", "li", "h1", "h2", "h3", "h4", "h5", "h6"]
                            .contains(block.localName?.lowercased() ?? "") {
                            builder.block(block, context, list: nil)
                        } else {
                            builder.inline(child, context)
                        }
                    }
                    while let last = text.string.last, last == "\n" || last == " " {
                        text.deleteCharacters(in: NSRange(location: text.length - 1, length: 1))
                    }
                    rowRich.append(TableModel.isPlain(text, header: header && r == 0)
                        ? nil : TableData.cellData(text))
                    return text.string.trimmingCharacters(in: .whitespacesAndNewlines)
                        .replacingOccurrences(of: "\u{FFFC}", with: "")
                })
                rich.append(rowRich)
            }
            let columns = max(data.map(\.count).max() ?? 1, 1)
            data = data.map { $0 + Array(repeating: "", count: columns - $0.count) }
            while widths.count < columns { widths.append(120) }
            var table = TableData(rows: data.count, columns: columns)
            table.rows = data
            table.columnWidths = Array(widths.prefix(columns))
            table.headerRow = header
            if rich.contains(where: { $0.contains { $0 != nil } }) {
                table.rich = TableData.padded(rich, rows: data.count, columns: columns)
            }
            if shading.contains(where: { $0.contains { $0 != nil } }) {
                table.shading = shading
                table.padShading()
            }
            return table
        }

        func image(_ element: XMLElement, x: CGFloat, y: CGFloat, into page: inout ImportedPage) {
            guard let data = resource(element), let image = NSImage(data: data), image.size.width > 0 else { return }
            let style = Context.styleMap(element.attribute(forName: "style")?.stringValue)
            let width = Context.px(element.attribute(forName: "width")?.stringValue) ?? Context.px(style["width"]) ?? min(image.size.width, 640)
            var pageElement = PageElement(kind: .image, x: max(0, x), y: max(0, y), width: width,
                                          height: ElementView.gripHeight + width * image.size.height / image.size.width)
            pageElement.asset = "pending"
            let type = element.attribute(forName: "data-fullres-src-type")?.stringValue
                ?? element.attribute(forName: "data-src-type")?.stringValue ?? "image/png"
            page.assets[pageElement.id] = (data, UTType(mimeType: type)?.preferredFilenameExtension ?? "png")
            page.elements.append(pageElement)
        }

        func file(_ element: XMLElement, x: CGFloat, y: CGFloat, into page: inout ImportedPage) {
            guard let data = resource(element) else { return }
            let name = element.attribute(forName: "data-attachment")?.stringValue ?? "Attachment"
            let type = UTType(filenameExtension: (name as NSString).pathExtension)
            var pageElement = PageElement(kind: type?.conforms(to: .audio) == true ? .audio : .file, x: max(0, x), y: max(0, y),
                                          width: 280, height: ElementView.gripHeight + 46)
            pageElement.asset = "pending"
            pageElement.fileName = name
            page.assets[pageElement.id] = (data, (name as NSString).pathExtension)
            page.elements.append(pageElement)
        }
    }

    /// Appends HTML paragraphs and inline content to an attributed string, in MxNoteONE's text conventions.
    struct TextBuilder {
        let resources: [String: Data]
        let out: NSMutableAttributedString

        struct ListContext {
            var ordered: Bool
            var counter: Int
            var depth: Int
        }

        private func trimTrailingSpaces() {
            while out.length > 0, out.string.hasSuffix(" ") {
                out.deleteCharacters(in: NSRange(location: out.length - 1, length: 1))
            }
        }

        private func newline(_ context: Context) {
            trimTrailingSpaces()
            if out.length > 0, !out.string.hasSuffix("\n") {
                out.append(NSAttributedString(string: "\n", attributes: context.attributes))
            }
        }

        private func headingContext(_ name: String, _ context: Context) -> Context {
            var c = context
            switch name {
            case "h1": c.size = 20; c.bold = true; c.color = NSColor(srgbRed: 0.16, green: 0.31, blue: 0.56, alpha: 1)
            case "h2": c.size = 17; c.bold = true; c.color = NSColor(srgbRed: 0.16, green: 0.31, blue: 0.56, alpha: 1)
            case "h3": c.size = 15; c.bold = true; c.color = NSColor(srgbRed: 0.24, green: 0.43, blue: 0.70, alpha: 1)
            case "h4", "h5", "h6": c.bold = true; c.italic = name == "h4"
            default: break
            }
            return c
        }

        static func tag(_ value: String?) -> (TagKind, Bool)? {
            guard let value else { return nil }
            for raw in value.split(separator: ",") {
                let item = raw.trimmingCharacters(in: .whitespaces).lowercased()
                let done = item.hasSuffix(":completed")
                let name = item.replacingOccurrences(of: ":completed", with: "")
                if name.hasPrefix("to-do") { return (.todo, done) }
                if name.hasPrefix("discuss-with") { return (.discuss, false) }
                if name == "contact" || name == "address" { return (.contact, false) }
                if let kind = OneNoteHTML.tagNames.first(where: { $0.value == name })?.key { return (kind, false) }
            }
            return nil
        }

        func block(_ element: XMLElement, _ inherited: Context, list: ListContext?) {
            let name = element.localName?.lowercased() ?? ""
            var context = headingContext(name, inherited)
            context.apply(style: element.attribute(forName: "style")?.stringValue)
            switch name {
            case "ul", "ol":
                var nested = ListContext(ordered: name == "ol",
                                         counter: Int(element.attribute(forName: "start")?.stringValue ?? "") ?? 1,
                                         depth: (list?.depth ?? -1) + 1)
                for child in element.children ?? [] {
                    if let item = child as? XMLElement, item.localName?.lowercased() == "li" {
                        block(item, context, list: nested)
                        nested.counter += 1
                    } else if let item = child as? XMLElement, ["ul", "ol"].contains(item.localName?.lowercased() ?? "") {
                        block(item, context, list: nested)
                    }
                }
                return
            case "br":
                out.append(NSAttributedString(string: "\n", attributes: context.attributes))
                return
            default:
                break
            }
            newline(context)
            var prefix = ""
            if name == "li", let list {
                prefix += String(repeating: "\t", count: list.depth)
                prefix += list.ordered ? "\(list.counter). " : TextFormatter.bullet
            }
            if let (kind, done) = Self.tag(element.attribute(forName: "data-tag")?.stringValue) {
                prefix += (kind == .todo && done ? TagKind.todoDone : kind.symbol) + " "
            }
            if !prefix.isEmpty {
                var plain = context
                plain.link = nil
                out.append(NSAttributedString(string: prefix, attributes: plain.attributes))
            }
            for child in element.children ?? [] {
                if let inner = child as? XMLElement,
                   ["p", "div", "ul", "ol", "li", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "pre"]
                    .contains(inner.localName?.lowercased() ?? "") {
                    block(inner, context, list: list)
                } else {
                    inline(child, context)
                }
            }
            newline(context)
        }

        func inline(_ node: XMLNode, _ inherited: Context) {
            guard let element = node as? XMLElement else {
                var text = (node.stringValue ?? "").replacingOccurrences(of: "\r", with: "")
                    .replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
                while text.contains("  ") { text = text.replacingOccurrences(of: "  ", with: " ") }
                // Whitespace between blocks, or at the start of a line, isn't text.
                if out.length == 0 || out.string.hasSuffix("\n") {
                    text = String(text.drop(while: { $0 == " " }))
                }
                if !text.isEmpty { out.append(NSAttributedString(string: text, attributes: inherited.attributes)) }
                return
            }
            let name = element.localName?.lowercased() ?? ""
            var context = inherited
            switch name {
            case "b", "strong": context.bold = true
            case "i", "em", "cite": context.italic = true
            case "u": context.underline = true
            case "s", "del", "strike": context.strike = true
            case "sup": context.script = 1
            case "sub": context.script = -1
            case "a":
                if let href = element.attribute(forName: "href")?.stringValue { context.link = URL(string: href) }
            case "br":
                out.append(NSAttributedString(string: "\n", attributes: context.attributes))
                return
            case "img":
                guard let data = ["data-fullres-src", "src"].lazy
                        .compactMap({ element.attribute(forName: $0)?.stringValue }).compactMap({ resources[$0] }).first,
                      let image = NSImage(data: data) else { return }
                let attachment = NSTextAttachment(data: data, ofType: nil)
                let width = Context.px(element.attribute(forName: "width")?.stringValue) ?? image.size.width
                if image.size.width > 0 {
                    attachment.bounds = CGRect(x: 0, y: 0, width: width, height: width * image.size.height / image.size.width)
                }
                out.append(NSAttributedString(attachment: attachment))
                return
            case "p", "div", "ul", "ol", "li", "h1", "h2", "h3", "h4", "h5", "h6":
                block(element, context, list: nil)
                return
            default:
                break
            }
            context.apply(style: element.attribute(forName: "style")?.stringValue)
            for child in element.children ?? [] { inline(child, context) }
        }
    }
}
