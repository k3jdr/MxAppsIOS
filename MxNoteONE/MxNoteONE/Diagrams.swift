//
//  Diagrams.swift
//  MxNoteONE
//
//  draw.io diagrams on pages, as VS Code's draw.io extension does them: each
//  diagram is a .drawio.svg — an ordinary SVG picture with the diagram itself
//  inside it, so it shows anywhere and opens again in draw.io. Double-click a
//  diagram for the full draw.io editor (every shape library, connectors,
//  layers, styles, templates); every change is saved straight back. A diagram
//  can be linked to a .drawio.svg file elsewhere (in a code repository, say):
//  editing it here writes that file, and changes made to the file elsewhere
//  show on the page.
//
//  The editor is draw.io's own, in its embed mode: online (embed.diagrams.net),
//  or offline from a copy downloaded once (Settings or the Draw tab).
//

import AppKit
import WebKit
import UniformTypeIdentifiers
import Compression

// MARK: - .drawio.svg files

enum DrawioFile {
    /// An empty diagram.
    static let blank = """
    <mxfile host="MxNoteONE"><diagram id="\(UUID().uuidString.prefix(8))" name="Page-1"><mxGraphModel dx="800" dy="600" grid="1" gridSize="10" guides="1" tooltips="1" connect="1" arrows="1" fold="1" page="0" pageScale="1" math="0" shadow="0"><root><mxCell id="0"/><mxCell id="1" parent="0"/></root></mxGraphModel></diagram></mxfile>
    """

    /// The diagram (mxfile XML) inside a .drawio.svg (its content attribute), or a .drawio file's text.
    static func mxfile(from data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        if text.contains("<mxfile") && !text.contains("<svg") { return text }
        guard let svgStart = text.range(of: "<svg") else { return nil }
        let head = text[svgStart.lowerBound...].prefix { $0 != ">" }
        guard let attr = head.range(of: "content=\"") else { return nil }
        let rest = head[attr.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return unescape(String(rest[..<end]))
    }

    static func unescape(_ s: String) -> String {
        var t = s
        for (a, b) in [("&quot;", "\""), ("&lt;", "<"), ("&gt;", ">"), ("&#10;", "\n"), ("&#xa;", "\n"), ("&apos;", "'"), ("&#39;", "'"), ("&amp;", "&")] {
            t = t.replacingOccurrences(of: a, with: b)
        }
        return t
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "\n", with: "&#10;")
    }

    /// A diagram page's model: plain XML, or draw.io's compressed form (base64, deflate, URL-encoded).
    static func models(_ mxfile: String) -> [String] {
        var result: [String] = []
        var rest = mxfile[...]
        while let open = rest.range(of: "<diagram") {
            guard let close = rest[open.upperBound...].range(of: ">"), let end = rest[close.upperBound...].range(of: "</diagram>") else { break }
            let body = rest[close.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            if body.hasPrefix("<") {
                result.append(body)
            } else if let data = Data(base64Encoded: body), let inflated = inflate(data),
                      let text = String(data: inflated, encoding: .utf8)?.removingPercentEncoding {
                result.append(text)
            }
            rest = rest[end.upperBound...]
        }
        return result
    }

    /// Raw deflate (as draw.io compresses diagrams).
    static func inflate(_ data: Data) -> Data? {
        let capacity = max(64 * 1024, data.count * 20)
        var out = Data(count: capacity)
        let count = out.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                          src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        return count > 0 ? out.prefix(count) : nil
    }

    /// The diagram's words: its shapes' and connectors' labels (for search and Quick Help).
    static func labels(_ mxfile: String) -> String {
        var words: [String] = []
        for model in models(mxfile) {
            var rest = model[...]
            while let r = rest.range(of: " value=\"") {
                let after = rest[r.upperBound...]
                guard let end = after.firstIndex(of: "\"") else { break }
                let html = unescape(String(after[..<end]))
                let text = html.replacingOccurrences(of: "<br>", with: " ").replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                let plain = unescape(text).split(whereSeparator: \.isWhitespace).joined(separator: " ")
                if !plain.isEmpty { words.append(plain) }
                rest = after[end...]
            }
        }
        return words.joined(separator: " · ")
    }

    /// The SVG's size (from its width and height, or its viewBox).
    static func size(of svg: Data) -> NSSize? {
        NSImage(data: svg).map(\.size).flatMap { $0.width > 0 ? $0 : nil }
    }

    /// The SVG rendered to PNG (for the page; draw.io's own PNG is used when it made the diagram).
    static func png(fromSVG svg: Data, scale: CGFloat = 2) -> Data? {
        guard let image = NSImage(data: svg), image.size.width > 0 else { return nil }
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    /// A .drawio.svg made here (from ink): a drawing and the diagram inside it.
    static func svg(body: String, width: CGFloat, height: CGFloat, mxfile: String) -> Data {
        let svg = """
        <?xml version="1.0" encoding="UTF-8"?>
        <svg xmlns="http://www.w3.org/2000/svg" version="1.1" width="\(Int(width))px" height="\(Int(height))px" viewBox="0 0 \(Int(width)) \(Int(height))" content="\(escape(mxfile))">\(body)</svg>
        """
        return Data(svg.utf8)
    }
}

// MARK: - On the page

/// A diagram's picture (double-click to edit; drag to move).
final class DiagramPictureView: NSView {
    weak var owner: DiagramElementView?
    var image: NSImage?

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        bounds.fill()
        image?.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                    hints: [.interpolation: NSImageInterpolation.high.rawValue])
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { owner?.edit() } else { owner?.beginMove(with: event) }
    }

    override func menu(for event: NSEvent) -> NSMenu? { owner?.contextMenu() }
}

/// A diagram on a page: its picture; double-click to edit it in draw.io.
final class DiagramElementView: ElementView {
    let picture = DiagramPictureView()
    private var aspect: CGFloat = 0.6
    private var watch: Timer?
    private var linkedDate: Date?

    init(element: PageElement, image: NSImage?) {
        super.init(element: element)
        picture.owner = self
        addSubview(picture)
        finishSetup()
        show(image ?? Self.placeholder)
        startWatching()
    }

    private func show(_ image: NSImage) {
        picture.image = image
        if image.size.width > 0 { aspect = image.size.height / image.size.width }
        setWidth(frame.width)
        needsDisplay = true
        picture.needsDisplay = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    isolated deinit { watch?.invalidate() }

    override var minWidth: CGFloat { 60 }

    override func setWidth(_ width: CGFloat) {
        let w = max(minWidth, width)
        setFrameSize(NSSize(width: w, height: Self.gripHeight + w * aspect))
    }

    override func layoutContent() { picture.frame = contentFrame }

    /// The picture: draw.io's PNG of it, else the SVG drawn here.
    func reloadPicture() {
        var image: NSImage?
        if let preview = element.preview, let data = controller?.assetData(preview) ?? NotebookStore.shared.canvas?.assetData(preview) {
            image = NSImage(data: data)
        }
        if image == nil, let asset = element.asset, let data = controller?.assetData(asset) ?? NotebookStore.shared.canvas?.assetData(asset) {
            image = NSImage(data: data)
        }
        show(image ?? Self.placeholder)
    }

    static let placeholder: NSImage = {
        let image = NSImage(size: NSSize(width: 400, height: 220))
        image.lockFocus()
        NSColor(white: 0.97, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 400, height: 220).fill()
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor]
        ("Empty diagram — double-click to draw" as NSString).draw(at: NSPoint(x: 70, y: 100), withAttributes: attrs)
        image.unlockFocus()
        return image
    }()

    /// A linked .drawio.svg changed elsewhere (VS Code, draw.io): the page follows.
    private func startWatching() {
        guard element.linkedPath != nil else { return }
        linkedDate = linkedModified
        watch = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkLinked() }
        }
    }

    private var linkedModified: Date? {
        element.linkedPath.flatMap { try? FileManager.default.attributesOfItem(atPath: $0)[.modificationDate] as? Date }
    }

    private func checkLinked() {
        guard let date = linkedModified, date != linkedDate, !DiagramEditor.isOpen(element.id) else { return }
        linkedDate = date
        refreshFromLinkedFile()
    }

    /// Reads the linked file again (its picture and labels).
    func refreshFromLinkedFile() {
        guard let path = element.linkedPath, let data = FileManager.default.contents(atPath: path), let ref = controller?.ref else { return }
        let store = NotebookStore.shared
        if let asset = element.asset { store.overwriteAsset(asset, data: data, for: ref) } else { element.asset = store.writeAsset(data, ext: "svg", for: ref) }
        if let png = DrawioFile.png(fromSVG: data) {
            if let preview = element.preview { store.overwriteAsset(preview, data: png, for: ref) } else { element.preview = store.writeAsset(png, ext: "png", for: ref) }
        }
        element.diagramText = DrawioFile.mxfile(from: data).map(DrawioFile.labels)
        reloadPicture()
        controller?.markDirty()
    }

    /// Search finds a diagram by its name and its shapes' labels.
    override func indexText() -> String? {
        [element.fileName, element.diagramText].compactMap { $0 }.joined(separator: " ")
    }

    func edit() { DiagramEditor.open(self) }

    var svgData: Data? { element.asset.flatMap { controller?.assetData($0) } }

    override func contextMenu() -> NSMenu {
        let menu = super.contextMenu()
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Edit Diagram") { [weak self] in self?.edit() })
        menu.addItem(ClosureMenuItem("Export .drawio.svg…") { [weak self] in self?.export(png: false) })
        menu.addItem(ClosureMenuItem("Export PNG…") { [weak self] in self?.export(png: true) })
        menu.addItem(ClosureMenuItem("Copy Picture") { [weak self] in
            guard let image = self?.picture.image else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([image])
        })
        if let path = element.linkedPath {
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem("Show Linked File in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) })
            menu.addItem(ClosureMenuItem("Read Linked File Again") { [weak self] in self?.refreshFromLinkedFile() })
            menu.addItem(ClosureMenuItem("Unlink (Keep a Copy Here)") { [weak self] in
                guard let self else { return }
                self.element.linkedPath = nil
                self.watch?.invalidate()
                self.controller?.markDirty()
            })
        }
        return menu
    }

    func export(png: Bool) {
        guard let data = png ? element.preview.flatMap({ controller?.assetData($0) }) : svgData else { return NSSound.beep() }
        let panel = NSSavePanel()
        let base = element.fileName ?? "Diagram"
        panel.nameFieldStringValue = base + (png ? ".png" : ".drawio.svg")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try data.write(to: url) } catch { NotebookStore.shared.report("Couldn't export the diagram.", error) }
    }

}

// MARK: - The editor

/// Where draw.io comes from: online, or the copy downloaded for working offline.
enum DrawioSource {
    static let modeKey = "drawioOffline", themeKey = "drawioTheme"
    static let themes: [(String, String)] = [("kennedy", "Standard"), ("min", "Minimal"), ("atlas", "Atlas"), ("sketch", "Sketch"), ("simple", "Simple"), ("dark", "Dark")]

    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "MxNoteONE/drawio")
    }
    static var offlineInstalled: Bool { FileManager.default.fileExists(atPath: folder.appending(path: "index.html").path) }
    static var useOffline: Bool { UserDefaults.standard.bool(forKey: modeKey) && offlineInstalled }
    static var theme: String { UserDefaults.standard.string(forKey: themeKey) ?? "kennedy" }

    /// draw.io in embed mode: messages as JSON, autosave, and Save & Exit.
    static var query: String {
        "embed=1&proto=json&spin=1&modified=unsavedChanges&saveAndExit=1&noExitBtn=0&libraries=1&ui=\(theme)&dark=auto&lang=en&pv=0"
    }

    static var onlineURL: URL { URL(string: "https://embed.diagrams.net/?" + query)! }

    /// The draw.io release used offline (the same web app VS Code's extension carries).
    static let downloadURL = URL(string: "https://github.com/jgraph/drawio/releases/latest/download/draw.war")!
}

/// Serves the offline draw.io (mxdrawio://app/…) to the editor's web view.
final class DrawioSchemeHandler: NSObject, WKURLSchemeHandler {
    let root: URL
    init(root: URL) { self.root = root }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        var path = url.path.isEmpty || url.path == "/" ? "/index.html" : url.path
        if path.hasSuffix("/") { path += "index.html" }
        let file = root.appending(path: String(path.dropFirst()))
        guard file.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path), let data = try? Data(contentsOf: file) else {
            task.didReceive(HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)!)
            task.didFinish()
            return
        }
        let type = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                        headerFields: ["Content-Type": type, "Content-Length": "\(data.count)", "Access-Control-Allow-Origin": "*"])!)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

/// A diagram's draw.io window: loads the diagram, saves every change back as .drawio.svg (and a PNG for the page).
final class DiagramEditor: NSWindowController, NSWindowDelegate, WKScriptMessageHandler {
    private static var open: [UUID: DiagramEditor] = [:]

    let elementID: UUID
    let ref: PageRef
    private var title: String
    private var webView: WKWebView!
    private var pendingSave: DispatchWorkItem?
    private var exitAfterSave = false
    private var lastSVG: Data?
    private var ready = false
    /// For self-tests: called with each saved .drawio.svg.
    var onSaved: ((Data) -> Void)?

    static func isOpen(_ id: UUID) -> Bool { open[id] != nil }

    /// Opens (or brings forward) the editor for a diagram on the page.
    @discardableResult
    static func open(_ view: DiagramElementView, template: Bool = false) -> DiagramEditor? {
        guard let ref = view.controller?.ref else { return nil }
        if let editor = open[view.element.id] {
            editor.window?.makeKeyAndOrderFront(nil)
            return editor
        }
        let xml = view.svgData.flatMap(DrawioFile.mxfile(from:)) ?? DrawioFile.blank
        let editor = DiagramEditor(elementID: view.element.id, ref: ref, title: view.element.fileName ?? "Diagram", xml: xml, template: template)
        open[view.element.id] = editor
        editor.showWindow(nil)
        return editor
    }

    private let initialXML: String
    private let showTemplates: Bool

    init(elementID: UUID, ref: PageRef, title: String, xml: String, template: Bool) {
        self.elementID = elementID
        self.ref = ref
        self.title = title
        initialXML = xml
        showTemplates = template
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 820),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "\(title) — draw.io"
        window.setFrameAutosaveName("DiagramEditor")
        if !window.setFrameUsingName("DiagramEditor") { window.center() }
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        let config = WKWebViewConfiguration()
        let controller = WKUserContentController()
        controller.add(WeakHandler(self), name: "drawio")
        config.userContentController = controller
        if DrawioSource.useOffline { config.setURLSchemeHandler(DrawioSchemeHandler(root: DrawioSource.folder), forURLScheme: "mxdrawio") }
        webView = WKWebView(frame: window.contentView!.bounds, configuration: config)
        webView.autoresizingMask = [.width, .height]
        window.contentView!.addSubview(webView)
        load()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// A page that hosts draw.io in a frame and passes its messages to MxNoteONE (and ours to it).
    private func load() {
        let editorURL = DrawioSource.useOffline ? URL(string: "mxdrawio://app/index.html?" + DrawioSource.query)! : DrawioSource.onlineURL
        let host = """
        <!doctype html><html><head><meta charset="utf-8"><style>html,body{margin:0;height:100%;overflow:hidden;background:#f5f5f5}
        iframe{border:0;width:100%;height:100%}#wait{position:absolute;top:45%;width:100%;text-align:center;font:14px -apple-system;color:#888}</style></head>
        <body><div id="wait">Opening draw.io…</div><iframe id="drawio" src="\(editorURL.absoluteString)"></iframe><script>
        const frame = document.getElementById('drawio');
        window.addEventListener('message', function (e) {
          if (e.source !== frame.contentWindow) return;
          document.getElementById('wait').style.display = 'none';
          window.webkit.messageHandlers.drawio.postMessage(typeof e.data === 'string' ? e.data : JSON.stringify(e.data));
        });
        function mxSend(json) { frame.contentWindow.postMessage(json, '*'); }
        </script></body></html>
        """
        webView.loadHTMLString(host, baseURL: DrawioSource.useOffline ? URL(string: "mxdrawio://app/")! : URL(string: "https://mxnoteone.local/")!)
    }

    private func send(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message), let json = String(data: data, encoding: .utf8) else { return }
        let literal = (try? JSONSerialization.data(withJSONObject: [json])).flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        webView.evaluateJavaScript("mxSend(\(literal)[0])")
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let text = message.body as? String, let data = text.data(using: .utf8),
              let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        switch msg["event"] as? String {
        case "init":
            ready = true
            send(["action": "load", "xml": initialXML, "autosave": 1, "title": title])
            if showTemplates { send(["action": "template"]) }
        case "autosave":
            scheduleSave()
        case "save":
            exitAfterSave = (msg["exit"] as? Bool) ?? false
            requestExport()
            send(["action": "status", "message": "Saved to the page", "modified": false])
        case "exit":
            if pendingSave != nil { exitAfterSave = true; requestExport() } else { close() }
        case "export":
            receiveExport(msg)
        default:
            break
        }
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.requestExport() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    /// Asks draw.io for the diagram as .drawio.svg (then as PNG for the page).
    private func requestExport() {
        pendingSave?.cancel()
        pendingSave = nil
        send(["action": "export", "format": "xmlsvg", "spinKey": "saving", "mx": "svg"])
    }

    private func receiveExport(_ msg: [String: Any]) {
        let request = msg["message"] as? [String: Any]
        guard let uri = msg["data"] as? String, let comma = uri.firstIndex(of: ",") else { return }
        let header = uri[..<comma], body = String(uri[uri.index(after: comma)...])
        let data = header.contains(";base64") ? Data(base64Encoded: body) : body.removingPercentEncoding.map { Data($0.utf8) }
        guard let data else { return }
        if (request?["mx"] as? String) == "svg" || (msg["format"] as? String) == "xmlsvg" {
            lastSVG = data
            send(["action": "export", "format": "png", "scale": 2, "border": 4, "mx": "png"])
        } else if let svg = lastSVG {
            DiagramEditor.store(svg: svg, png: data, elementID: elementID, ref: ref)
            onSaved?(svg)
            if exitAfterSave { close() }
        }
    }

    /// Puts a saved diagram into its page (on screen at once, else in the background) and its linked file.
    static func store(svg: Data, png: Data?, elementID: UUID, ref: PageRef) {
        let store = NotebookStore.shared
        let labels = DrawioFile.mxfile(from: svg).map(DrawioFile.labels)
        func update(_ e: inout PageElement) {
            if let asset = e.asset { store.overwriteAsset(asset, data: svg, for: ref) } else { e.asset = store.writeAsset(svg, ext: "svg", for: ref) }
            if let png {
                if let preview = e.preview { store.overwriteAsset(preview, data: png, for: ref) } else { e.preview = store.writeAsset(png, ext: "png", for: ref) }
            }
            e.diagramText = labels
            if let path = e.linkedPath {
                do { try svg.write(to: URL(fileURLWithPath: path)) } catch { store.report("Couldn't write \(path).", error) }
            }
        }
        if store.canvas?.ref == ref, let view = store.canvas?.canvas.elementViews.compactMap({ $0 as? DiagramElementView }).first(where: { $0.element.id == elementID }) {
            update(&view.element)
            view.reloadPicture()
            view.controller?.markDirty()
        } else if var content = store.loadPage(ref), let i = content.elements.firstIndex(where: { $0.id == elementID }) {
            update(&content.elements[i])
            let index = PageIndexer.index(elements: content.elements)
            store.savePage(content, ref: ref, plainText: index.text, tags: index.tags)
        }
    }

    func windowWillClose(_ notification: Notification) {
        if pendingSave != nil { pendingSave?.perform() }
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "drawio")
        DiagramEditor.open[elementID] = nil
    }

    #if DEBUG
    /// Self-tests: draw.io is ready, and runs JavaScript in its frame's host page.
    var isReady: Bool { ready }
    func testSend(_ message: [String: Any]) { send(message) }
    #endif
}

/// Keeps the web view from holding its editor.
private final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) { target?.userContentController(c, didReceive: m) }
}

// MARK: - Offline draw.io

@MainActor
@Observable
final class DrawioDownload {
    static let shared = DrawioDownload()
    private(set) var progress: Double?
    private(set) var message = ""

    /// Downloads draw.io (about 50 MB, once) for editing diagrams without the internet.
    func start() {
        guard progress == nil else { return }
        progress = 0
        message = "Downloading draw.io…"
        Task {
            do {
                let (file, _) = try await URLSession.shared.download(from: DrawioSource.downloadURL, delegate: nil)
                message = "Unpacking…"
                let target = DrawioSource.folder
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                let unzip = Process()
                unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
                unzip.arguments = ["-q", "-o", file.path, "-d", target.path]
                try unzip.run()
                unzip.waitUntilExit()
                try? FileManager.default.removeItem(at: file)
                if DrawioSource.offlineInstalled {
                    UserDefaults.standard.set(true, forKey: DrawioSource.modeKey)
                    message = "draw.io is ready to use offline."
                } else {
                    message = "The download didn't contain draw.io."
                }
            } catch {
                message = "Couldn't download draw.io: \(error.localizedDescription)"
            }
            progress = nil
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: DrawioSource.folder)
        UserDefaults.standard.set(false, forKey: DrawioSource.modeKey)
        message = "Offline copy removed — diagrams open with draw.io online."
    }
}

// MARK: - Making diagrams

extension CanvasController {
    /// Draw ▸ New Diagram: an empty diagram on the page, opened in draw.io (with its templates, if asked).
    func newDiagram(template: Bool = false) {
        guard let ref else { return }
        let p = nextInsertionPoint()
        var element = PageElement(kind: .diagram, x: p.x, y: p.y, width: 480)
        element.fileName = "Diagram"
        let svg = DrawioFile.svg(body: "", width: 400, height: 220, mxfile: DrawioFile.blank)
        element.asset = NotebookStore.shared.writeAsset(svg, ext: "svg", for: ref)
        guard let view = addElement(element) as? DiagramElementView else { return }
        undoManager?.setActionName("New Diagram")
        DispatchQueue.main.async { DiagramEditor.open(view, template: template) }
    }

    /// Draw ▸ Insert / Link: a .drawio.svg (or .drawio) file — copied into the notebook, or linked so the file and
    /// the page stay the same (edits here write the file; changes to the file show here).
    func chooseDiagramFile(link: Bool) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "svg"), UTType(filenameExtension: "drawio"), UTType(filenameExtension: "xml")].compactMap { $0 }
        panel.message = link ? "Choose a .drawio.svg file to link — edits here are saved to it" : "Choose a .drawio.svg or .drawio file to put on the page"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        insertDiagram(from: url, link: link)
    }

    @discardableResult
    func insertDiagram(from url: URL, link: Bool, at point: NSPoint? = nil) -> DiagramElementView? {
        guard let ref, let data = try? Data(contentsOf: url) else { return nil }
        guard let mxfile = DrawioFile.mxfile(from: data) else {
            store.showAlert("Not a draw.io diagram", "“\(url.lastPathComponent)” has no draw.io diagram in it. Diagrams are .drawio.svg or .drawio files.")
            return nil
        }
        let isSVG = String(data: data.prefix(2000), encoding: .utf8)?.contains("<svg") == true
        // A .drawio file has no picture yet: it gets one when draw.io opens it.
        let svg = isSVG ? data : DrawioFile.svg(body: "", width: 400, height: 220, mxfile: mxfile)
        let size = isSVG ? (DrawioFile.size(of: svg) ?? NSSize(width: 480, height: 300)) : NSSize(width: 480, height: 300)
        let p = point ?? nextInsertionPoint()
        var element = PageElement(kind: .diagram, x: p.x, y: p.y, width: min(760, max(240, size.width)))
        element.fileName = url.lastPathComponent.replacingOccurrences(of: ".drawio.svg", with: "").replacingOccurrences(of: ".drawio", with: "")
            .replacingOccurrences(of: ".svg", with: "")
        element.asset = store.writeAsset(svg, ext: "svg", for: ref)
        if isSVG, let png = DrawioFile.png(fromSVG: svg) { element.preview = store.writeAsset(png, ext: "png", for: ref) }
        element.diagramText = DrawioFile.labels(mxfile)
        if link, isSVG { element.linkedPath = url.path }
        guard let view = addElement(element) as? DiagramElementView else { return nil }
        undoManager?.setActionName(link ? "Link Diagram" : "Insert Diagram")
        if !isSVG { DispatchQueue.main.async { DiagramEditor.open(view) } }
        return view
    }

    /// Draw ▸ Convert Ink to Diagram: the page's pen strokes and shapes become a draw.io diagram (lines, arrows,
    /// rectangles and ellipses as draw.io shapes; pen strokes as freehand lines) that can be edited in draw.io.
    @discardableResult
    func convertInkToDiagram() -> DiagramElementView? {
        guard let ref else { return nil }
        let strokes = canvas.inkView.strokes
        guard !strokes.isEmpty else { return nil }
        var bounds = CGRect.null
        for s in strokes { for p in s.points { bounds = bounds.union(CGRect(x: p.x, y: p.y, width: 0.1, height: 0.1)) } }
        let pad: CGFloat = 12
        bounds = bounds.insetBy(dx: -pad, dy: -pad)
        func local(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x - bounds.minX, y: p.y - bounds.minY) }
        var cells = "", body = ""
        for (n, s) in strokes.enumerated() {
            let hex = String(RecentColors.hex(s.color.nsColor))
            let opacity = s.tool == .highlighter ? 40 : 100
            let width = String(format: "%.1f", s.width)
            let points = s.points.map(local)
            guard let first = points.first, let last = points.last else { continue }
            switch s.tool {
            case .rectangle, .ellipse:
                let r = CGRect(x: min(first.x, last.x), y: min(first.y, last.y), width: abs(last.x - first.x), height: abs(last.y - first.y))
                let shape = s.tool == .ellipse ? "ellipse;" : "rounded=0;"
                cells += "<mxCell id=\"ink\(n)\" value=\"\" style=\"\(shape)whiteSpace=wrap;html=1;fillColor=none;strokeColor=#\(hex);strokeWidth=\(width);opacity=\(opacity);\" vertex=\"1\" parent=\"1\"><mxGeometry x=\"\(Int(r.minX))\" y=\"\(Int(r.minY))\" width=\"\(Int(max(1, r.width)))\" height=\"\(Int(max(1, r.height)))\" as=\"geometry\"/></mxCell>"
                body += s.tool == .ellipse
                    ? "<ellipse cx=\"\(r.midX)\" cy=\"\(r.midY)\" rx=\"\(r.width / 2)\" ry=\"\(r.height / 2)\" fill=\"none\" stroke=\"#\(hex)\" stroke-width=\"\(width)\" opacity=\"\(Double(opacity) / 100)\"/>"
                    : "<rect x=\"\(r.minX)\" y=\"\(r.minY)\" width=\"\(r.width)\" height=\"\(r.height)\" fill=\"none\" stroke=\"#\(hex)\" stroke-width=\"\(width)\" opacity=\"\(Double(opacity) / 100)\"/>"
            default:
                // Lines and arrows: start and end; pen strokes: their path, thinned to the points that matter.
                let kept: [CGPoint] = s.tool == .line || s.tool == .arrow ? [first, last] : Self.simplify(points, tolerance: 1.5)
                let middle = kept.dropFirst().dropLast().map { "<mxPoint x=\"\(Int($0.x))\" y=\"\(Int($0.y))\"/>" }.joined()
                let arrow = s.tool == .arrow ? "classic" : "none"
                let curved = s.tool == .pen || s.tool == .highlighter ? "curved=1;" : ""
                cells += "<mxCell id=\"ink\(n)\" value=\"\" style=\"endArrow=\(arrow);html=1;\(curved)strokeColor=#\(hex);strokeWidth=\(width);opacity=\(opacity);rounded=1;\" edge=\"1\" parent=\"1\"><mxGeometry relative=\"1\" as=\"geometry\"><mxPoint x=\"\(Int(first.x))\" y=\"\(Int(first.y))\" as=\"sourcePoint\"/><mxPoint x=\"\(Int(last.x))\" y=\"\(Int(last.y))\" as=\"targetPoint\"/>" + (middle.isEmpty ? "" : "<Array as=\"points\">\(middle)</Array>") + "</mxGeometry></mxCell>"
                let d = kept.enumerated().map { ($0.offset == 0 ? "M" : "L") + String(format: "%.1f %.1f", $0.element.x, $0.element.y) }.joined(separator: " ")
                body += "<path d=\"\(d)\" fill=\"none\" stroke=\"#\(hex)\" stroke-width=\"\(width)\" stroke-linecap=\"round\" stroke-linejoin=\"round\" opacity=\"\(Double(opacity) / 100)\"/>"
                if s.tool == .arrow, kept.count >= 2 {
                    let a = kept[kept.count - 2], b = kept[kept.count - 1]
                    let angle = atan2(b.y - a.y, b.x - a.x), len = 10 + s.width * 2
                    let p1 = CGPoint(x: b.x - len * cos(angle - 0.4), y: b.y - len * sin(angle - 0.4))
                    let p2 = CGPoint(x: b.x - len * cos(angle + 0.4), y: b.y - len * sin(angle + 0.4))
                    body += String(format: "<path d=\"M%.1f %.1f L%.1f %.1f L%.1f %.1f Z\" fill=\"#%@\"/>", b.x, b.y, p1.x, p1.y, p2.x, p2.y, hex)
                }
            }
        }
        let mxfile = DrawioFile.blank.replacingOccurrences(of: "<mxCell id=\"1\" parent=\"0\"/>", with: "<mxCell id=\"1\" parent=\"0\"/>" + cells)
        let svg = DrawioFile.svg(body: body, width: bounds.width, height: bounds.height, mxfile: mxfile)
        var element = PageElement(kind: .diagram, x: bounds.minX, y: bounds.minY - ElementView.gripHeight, width: bounds.width)
        element.fileName = "Ink"
        element.asset = store.writeAsset(svg, ext: "svg", for: ref)
        if let png = DrawioFile.png(fromSVG: svg) { element.preview = store.writeAsset(png, ext: "png", for: ref) }
        undoManager?.beginUndoGrouping()
        let old = strokes
        canvas.inkView.strokes = []
        strokesChanged(from: old)
        let view = addElement(element) as? DiagramElementView
        undoManager?.endUndoGrouping()
        undoManager?.setActionName("Convert Ink to Diagram")
        return view
    }

    /// Fewer points along a stroke (Ramer–Douglas–Peucker), keeping its shape.
    static func simplify(_ points: [CGPoint], tolerance: CGFloat) -> [CGPoint] {
        guard points.count > 2, let first = points.first, let last = points.last else { return points }
        var index = 0, distance: CGFloat = 0
        let dx = last.x - first.x, dy = last.y - first.y, length = max(0.0001, hypot(dx, dy))
        for i in 1..<(points.count - 1) {
            let d = abs(dy * points[i].x - dx * points[i].y + last.x * first.y - last.y * first.x) / length
            if d > distance { distance = d; index = i }
        }
        guard distance > tolerance else { return [first, last] }
        let left = simplify(Array(points[...index]), tolerance: tolerance)
        let right = simplify(Array(points[index...]), tolerance: tolerance)
        return left.dropLast() + right
    }

    /// The diagram selected on the page (or the only one).
    var selectedDiagram: DiagramElementView? {
        if let view = canvas.selectedElement as? DiagramElementView { return view }
        let all = canvas.elementViews.compactMap { $0 as? DiagramElementView }
        return all.count == 1 ? all[0] : nil
    }
}
