//
//  MapPinEditor.swift
//  MxNoteONE
//
//  Editing a map pin: its title, category and notes; its marker (a colour, and a symbol or up to three letters);
//  what it links to — a page, a paragraph on a page (picked from the page's paragraphs), a web address, or a link
//  copied with Copy Link to Page / Paragraph; and where it is (an address, or latitude and longitude). And the
//  Directions dialog: from one pin to another, driving or walking.
//

import AppKit
import SwiftUI

@MainActor
enum MapPinEditor {
    enum Result {
        case cancel, delete
        case save(MapPin)
    }

    static func edit(_ pin: MapPin, categories: [String], in window: NSWindow?, done: @escaping (Result) -> Void) {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 640), styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "Edit Pin"
        func finish(_ r: Result) {
            if let parent = panel.sheetParent { parent.endSheet(panel) } else { panel.close() }
            done(r)
        }
        panel.contentView = NSHostingView(rootView: MapPinEditorView(pin: pin, categories: categories, finish: finish))
        if let window { window.beginSheet(panel) } else { panel.center(); panel.makeKeyAndOrderFront(nil) }
    }
}

struct MapPinEditorView: View {
    enum LinkKind: String, CaseIterable, Identifiable { case none = "None", page = "Page or Paragraph", web = "Web Address"; var id: String { rawValue } }

    let categories: [String]
    let finish: (MapPinEditor.Result) -> Void
    @State private var pin: MapPin
    @State private var kind: LinkKind
    @State private var page: PageRef?
    /// The paragraph chosen on the page: its container and number (nil: the whole page).
    @State private var paragraph: ParagraphChoice?
    @State private var paragraphs: [ParagraphChoice] = []
    @State private var web = ""
    @State private var filter = ""
    @State private var latitude: String
    @State private var longitude: String

    struct ParagraphChoice: Hashable, Identifiable {
        var element: UUID
        var index: Int
        var text: String
        var id: String { element.uuidString + "/\(index)" }
    }

    private var store: NotebookStore { .shared }

    init(pin: MapPin, categories: [String], finish: @escaping (MapPinEditor.Result) -> Void) {
        self.categories = categories
        self.finish = finish
        _pin = State(initialValue: pin)
        _latitude = State(initialValue: String(format: "%.6f", pin.latitude))
        _longitude = State(initialValue: String(format: "%.6f", pin.longitude))
        var kind = LinkKind.none, page: PageRef?, web = ""
        if let url = pin.linkURL {
            if url.scheme == NotebookStore.linkScheme, let ref = NotebookStore.shared.resolve(url) {
                kind = .page
                page = ref
            } else {
                kind = .web
                web = url.absoluteString
            }
        }
        _kind = State(initialValue: kind)
        _page = State(initialValue: page)
        _web = State(initialValue: web)
    }

    private var pages: [(PageRef, String, String)] {
        var result: [(PageRef, String, String)] = []
        for notebook in store.notebooks {
            for node in notebook.manifest.sections.flattenedSections {
                for meta in notebook.sections[node.id]?.pages ?? [] {
                    let ref = PageRef(notebookID: notebook.id, sectionID: node.id, pageID: meta.id)
                    if filter.isEmpty || meta.displayTitle.localizedCaseInsensitiveContains(filter) || ref == page {
                        result.append((ref, meta.displayTitle, notebook.name + " › " + node.name))
                    }
                }
            }
        }
        return result
    }

    /// The link as chosen.
    private var link: URL? {
        switch kind {
        case .none: return nil
        case .page:
            guard let page else { return nil }
            if let p = paragraph { return store.paragraphLink(page, element: p.element, paragraph: p.index, cell: nil, text: p.text) }
            return store.link(for: page)
        case .web:
            let t = web.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { return nil }
            if t.contains("://") || t.hasPrefix("mailto:") { return URL(string: t) }
            return URL(string: "https://" + t)
        }
    }

    private func loadParagraphs() {
        guard let page else { paragraphs = []; return }
        paragraphs = MapLinks.paragraphs(of: page).map { ParagraphChoice(element: $0.element, index: $0.index, text: $0.text) }
        // The pin's own paragraph, chosen again.
        if let url = pin.linkURL, let target = ParagraphTarget(url), store.resolve(url) == page {
            paragraph = paragraphs.first { $0.element == target.element && $0.index == target.paragraph }
                ?? paragraphs.first { !target.text.isEmpty && $0.text.hasPrefix(target.text) }
        } else {
            paragraph = nil
        }
    }

    private func save() {
        var p = pin
        p.title = p.title.trimmingCharacters(in: .whitespaces).isEmpty ? "Pin" : p.title.trimmingCharacters(in: .whitespaces)
        if let lat = Double(latitude.trimmingCharacters(in: .whitespaces)), (-90...90).contains(lat) { p.latitude = lat }
        if let lon = Double(longitude.trimmingCharacters(in: .whitespaces)), (-180...180).contains(lon) { p.longitude = lon }
        p.notes = (p.notes ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : p.notes
        p.category = (p.category ?? "").trimmingCharacters(in: .whitespaces).isEmpty ? nil : p.category!.trimmingCharacters(in: .whitespaces)
        p.address = (p.address ?? "").trimmingCharacters(in: .whitespaces).isEmpty ? nil : p.address
        p.label = (p.label ?? "").trimmingCharacters(in: .whitespaces).isEmpty ? nil : String(p.label!.trimmingCharacters(in: .whitespaces).prefix(3))
        if let url = link {
            p.link = url.absoluteString
            p.linkTitle = MapLinks.title(of: url)
        } else {
            p.link = nil
            p.linkTitle = nil
        }
        finish(.save(p))
    }

    private func useCopiedLink() {
        guard let url = MapLinks.copiedLink else { return NSSound.beep() }
        if url.scheme == NotebookStore.linkScheme, let ref = store.resolve(url) {
            kind = .page
            pin.link = url.absoluteString
            page = ref
            loadParagraphs()
        } else {
            kind = .web
            web = url.absoluteString
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 14) {
                marker(size: 46)
                Form {
                    TextField("Title:", text: $pin.title)
                    HStack {
                        TextField("Category:", text: Binding(get: { pin.category ?? "" }, set: { pin.category = $0 }), prompt: Text("Pins"))
                        if !categories.isEmpty {
                            Menu("") {
                                ForEach(categories, id: \.self) { c in Button(c) { pin.category = c } }
                            }
                            .menuStyle(.borderlessButton)
                            .frame(width: 22)
                            .help("A category used on this map")
                        }
                    }
                    .help("Pins in a category are listed together, and shown or hidden together")
                    TextField("Address:", text: Binding(get: { pin.address ?? "" }, set: { pin.address = $0 }))
                }
            }
            Text("Notes").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: Binding(get: { pin.notes ?? "" }, set: { pin.notes = $0 }))
                .font(.body)
                .frame(height: 52)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.separator))
            GroupBox("Marker") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        ForEach(MapPin.palette, id: \.1) { name, hex in
                            Button { pin.color = hex } label: {
                                Circle().fill(Color(nsColor: NSColor(hex: hex) ?? .gray)).frame(width: 22, height: 22)
                                    .overlay(Circle().stroke(Color.primary, lineWidth: pin.color == hex ? 2.5 : 0).padding(-3))
                            }
                            .buttonStyle(.plain)
                            .help(name)
                        }
                    }
                    ScrollView {
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 4), count: 15), spacing: 4) {
                            ForEach(MapPin.symbols, id: \.0) { symbol, name in
                                Button { pin.symbol = symbol; pin.label = nil } label: {
                                    Image(systemName: symbol).frame(width: 28, height: 26)
                                        .background(RoundedRectangle(cornerRadius: 5).fill(pin.symbol == symbol && (pin.label ?? "").isEmpty ? Color.accentColor.opacity(0.25) : Color.clear))
                                }
                                .buttonStyle(.plain)
                                .help(name)
                            }
                        }
                    }
                    .frame(height: 92)
                    HStack {
                        Text("Or letters:")
                        TextField("", text: Binding(get: { pin.label ?? "" }, set: { pin.label = String($0.prefix(3)) }), prompt: Text("1, A, HQ"))
                            .frame(width: 70)
                            .help("Up to three letters or numbers in the marker instead of a symbol")
                    }
                }
                .padding(4)
            }
            GroupBox("Link") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Picker("", selection: $kind) { ForEach(LinkKind.allCases) { Text($0.rawValue).tag($0) } }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                        Button("Use Copied Link") { useCopiedLink() }
                            .disabled(MapLinks.copiedLink == nil)
                            .help("A link copied with Copy Link to Page or Paragraph (right-click a page or a paragraph), or a web address")
                    }
                    switch kind {
                    case .none:
                        Text("The pin links to nothing.").font(.caption).foregroundStyle(.secondary)
                    case .web:
                        TextField("Address:", text: $web, prompt: Text("https://…"))
                    case .page:
                        HStack(alignment: .top, spacing: 8) {
                            VStack(alignment: .leading, spacing: 4) {
                                TextField("Filter pages", text: $filter).textFieldStyle(.roundedBorder)
                                List(selection: $page) {
                                    ForEach(pages, id: \.0) { ref, title, location in
                                        VStack(alignment: .leading) {
                                            Text(title).lineLimit(1)
                                            Text(location).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                        .tag(ref)
                                    }
                                }
                                .frame(height: 120)
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text(page == nil ? "Pick a page" : "To the whole page, or a paragraph:").font(.caption).foregroundStyle(.secondary)
                                List(selection: Binding(get: { paragraph?.id ?? "page" }, set: { id in paragraph = paragraphs.first { $0.id == id } })) {
                                    if page != nil {
                                        Label("The whole page", systemImage: "doc.text").tag("page")
                                        ForEach(paragraphs) { p in
                                            Text(p.text).lineLimit(2).font(.callout).tag(p.id)
                                        }
                                    }
                                }
                                .frame(height: 146)
                            }
                        }
                        .onChange(of: page) { loadParagraphs() }
                    }
                    if let link {
                        Text("Goes to: " + MapLinks.title(of: link)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .padding(4)
            }
            HStack {
                Text("Latitude")
                TextField("", text: $latitude).frame(width: 110)
                Text("Longitude")
                TextField("", text: $longitude).frame(width: 110)
                Spacer()
            }
            .font(.callout)
            HStack {
                Button("Delete Pin", role: .destructive) { finish(.delete) }
                Spacer()
                Button("Cancel") { finish(.cancel) }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 560)
        .onAppear { loadParagraphs() }
    }

    private func marker(size: CGFloat) -> some View {
        ZStack {
            Circle().fill(Color(nsColor: pin.nsColor)).frame(width: size, height: size).shadow(radius: 2)
            if let label = pin.label, !label.isEmpty {
                Text(String(label.prefix(3))).font(.system(size: size * 0.36, weight: .bold)).foregroundStyle(.white)
            } else {
                Image(systemName: pin.symbol ?? "mappin").font(.system(size: size * 0.42, weight: .semibold)).foregroundStyle(.white)
            }
        }
        .padding(.top, 4)
    }
}

// MARK: - Directions

@MainActor
enum MapDirectionsSheet {
    static func ask(pins: [MapPin], from: UUID, to: UUID, in window: NSWindow?, done: @escaping (UUID, UUID, Bool) -> Void) {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "Directions"
        func close() { if let parent = panel.sheetParent { parent.endSheet(panel) } else { panel.close() } }
        panel.contentView = NSHostingView(rootView: MapDirectionsView(pins: pins, from: from, to: to, cancel: close) { a, b, walking in
            close()
            done(a, b, walking)
        })
        if let window { window.beginSheet(panel) } else { panel.center(); panel.makeKeyAndOrderFront(nil) }
    }
}

struct MapDirectionsView: View {
    let pins: [MapPin]
    @State var from: UUID
    @State var to: UUID
    let cancel: () -> Void
    let go: (UUID, UUID, Bool) -> Void
    @State private var walking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Form {
                Picker("From:", selection: $from) { ForEach(pins) { Text($0.title).tag($0.id) } }
                Picker("To:", selection: $to) { ForEach(pins) { Text($0.title).tag($0.id) } }
                Picker("By:", selection: $walking) {
                    Label("Car", systemImage: "car.fill").tag(false)
                    Label("Walking", systemImage: "figure.walk").tag(true)
                }
                .pickerStyle(.segmented)
            }
            Text("The route is drawn on the map, with its distance and time in the pin list.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { cancel() }.keyboardShortcut(.cancelAction)
                Button("Get Directions") { go(from, to, walking) }.keyboardShortcut(.defaultAction).disabled(from == to)
            }
        }
        .padding(16)
        .frame(width: 380)
    }
}
