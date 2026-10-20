//
//  MapModel.swift
//  MxNoteONE
//
//  A map on the page, as in Apple Maps and Google Maps: where it looks (centre, height, heading, tilt), its style
//  (standard, muted, satellite, hybrid; flat or 3D; points of interest, traffic), and its pins — each with a title,
//  notes, an address, a category (shown or hidden together, as Google My Maps' layers), a colour, a symbol or a few
//  letters, and a link to a page, a paragraph on a page, or a web address. Routes (driving or walking) join pins.
//

import AppKit
import CoreLocation
import MapKit

struct MapData: Codable, Hashable {
    var title: String?
    /// The centre, and the camera's height over it (metres), heading (degrees from north) and tilt.
    var latitude: Double
    var longitude: Double
    var distance: Double
    var heading: Double?
    var pitch: Double?
    var style: MapStyle?
    /// 3D: terrain and buildings in relief.
    var realistic: Bool?
    /// Points of interest (shops, restaurants…) on the map — shown unless false.
    var pointsOfInterest: Bool?
    var traffic: Bool?
    /// Nearby pins group into one when zoomed out — all together, or each category on its own.
    var clusters: Bool?
    var clusterByCategory: Bool?
    /// A colour for each category (its pins and its groups), "#RRGGBB".
    var categoryColors: [String: String]?
    /// The pin list beside the map.
    var showsList: Bool?
    /// Categories whose pins are hidden.
    var hiddenCategories: [String]?
    var pins: [MapPin] = []
    var routes: [MapRoute]?

    /// A new map: the continental United States, from high up.
    static let starter = MapData(title: "Map", latitude: 39.5, longitude: -98.35, distance: 6_500_000)

    var center: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }

    /// The categories used, in the order they first come.
    var categories: [String] {
        var seen: [String] = []
        for p in pins { let c = p.categoryName; if !seen.contains(c) { seen.append(c) } }
        return seen
    }

    func isShown(_ pin: MapPin) -> Bool { !(hiddenCategories ?? []).contains(pin.categoryName) }

    var clustering: MapClustering {
        get { clusters == true ? (clusterByCategory == true ? .category : .all) : .off }
        set {
            clusters = newValue == .off ? nil : true
            clusterByCategory = newValue == .category ? true : nil
        }
    }

    /// The group a pin joins when it's near others (nil: it stays on its own).
    func clusterID(for pin: MapPin) -> String? {
        switch clustering {
        case .off: nil
        case .all: "pins"
        case .category: "category:" + pin.categoryName
        }
    }

    /// A group's colour: its category's, else the colour most of its pins have.
    func clusterColor(_ pins: [MapPin]) -> String {
        let categories = Set(pins.map(\.categoryName))
        if categories.count == 1, let c = categoryColors?[categories.first!] { return c }
        var counts: [String: Int] = [:]
        for p in pins { counts[p.color, default: 0] += 1 }
        return counts.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }?.key ?? MapPin.palette[0].1
    }

    /// A group's name: its category and how many ("Food · 4 pins"), else "6 pins".
    static func clusterTitle(_ pins: [MapPin]) -> String {
        let categories = Set(pins.map(\.categoryName))
        return categories.count == 1 ? "\(categories.first!) · \(pins.count) pins" : "\(pins.count) pins"
    }

    /// Words for search: the title, and each pin's title, notes, address, category and link.
    var searchText: String {
        ([title ?? ""] + pins.flatMap { [$0.title, $0.notes ?? "", $0.address ?? "", $0.category ?? "", $0.linkTitle ?? ""] })
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// The pins as a list (Markdown and OneNote): title, place, notes and what it links to.
    func pinLines(markdown: Bool) -> [String] {
        pins.map { p in
            let maps = "https://maps.apple.com/?ll=\(p.latitude),\(p.longitude)&q=\(p.title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"
            var line = markdown ? "- **\(p.title)** — [\(p.place)](\(maps))" : "\(p.title) — \(p.place)"
            if let notes = p.notes, !notes.isEmpty { line += ": " + notes.replacingOccurrences(of: "\n", with: " ") }
            if let t = p.linkTitle, !t.isEmpty { line += " (→ \(t))" }
            return line
        }
    }
}

enum MapClustering: String, CaseIterable, Identifiable {
    case off, all, category
    var id: String { rawValue }
    var title: String {
        switch self {
        case .off: "Don't Group Pins"
        case .all: "Group Nearby Pins"
        case .category: "Group Nearby Pins by Category"
        }
    }
}

enum MapStyle: String, Codable, CaseIterable, Identifiable {
    case standard, muted, satellite, hybrid
    var id: String { rawValue }
    var title: String {
        switch self {
        case .standard: "Standard"
        case .muted: "Muted"
        case .satellite: "Satellite"
        case .hybrid: "Hybrid (Satellite with Labels)"
        }
    }
}

struct MapPin: Codable, Hashable, Identifiable {
    var id = UUID()
    var title: String
    var notes: String?
    var latitude: Double
    var longitude: Double
    var address: String?
    var category: String?
    /// "#RRGGBB".
    var color: String = MapPin.palette[0].1
    /// An SF Symbol drawn in the marker, or a few letters instead.
    var symbol: String? = "mappin"
    var label: String?
    /// A page, a paragraph on a page (mxnoteone://…) or a web address; and what it's called.
    var link: String?
    var linkTitle: String?

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
    var categoryName: String { (category ?? "").trimmingCharacters(in: .whitespaces).isEmpty ? "Pins" : category!.trimmingCharacters(in: .whitespaces) }
    var nsColor: NSColor { NSColor(hex: color) ?? .systemRed }
    var linkURL: URL? { link.flatMap { URL(string: $0) } }

    /// Its address, else its coordinates.
    var place: String {
        if let address, !address.isEmpty { return address }
        return String(format: "%.5f, %.5f", latitude, longitude)
    }

    /// Apple Maps' marker colours.
    static let palette: [(String, String)] = [
        ("Red", "#EB4D3D"), ("Orange", "#F29A38"), ("Yellow", "#F5C842"), ("Green", "#5CC85A"), ("Mint", "#3CC9B5"),
        ("Teal", "#3FB1D2"), ("Blue", "#3478F6"), ("Indigo", "#5E5CE6"), ("Purple", "#AF52DE"), ("Pink", "#F2558E"),
        ("Brown", "#A2845E"), ("Gray", "#8E8E93"),
    ]

    /// Symbols for markers (SF Symbols), by what they mark.
    static let symbols: [(String, String)] = [
        ("mappin", "Pin"), ("star.fill", "Star"), ("heart.fill", "Favourite"), ("flag.fill", "Flag"), ("house.fill", "Home"),
        ("building.2.fill", "Building"), ("briefcase.fill", "Work"), ("building.columns.fill", "Museum / Civic"),
        ("fork.knife", "Restaurant"), ("cup.and.saucer.fill", "Café"), ("wineglass.fill", "Bar"), ("cart.fill", "Shopping"),
        ("bag.fill", "Store"), ("bed.double.fill", "Hotel"), ("car.fill", "Car"), ("fuelpump.fill", "Fuel"),
        ("parkingsign", "Parking"), ("airplane", "Airport"), ("tram.fill", "Transit"), ("ferry.fill", "Ferry"),
        ("figure.walk", "Walk"), ("bicycle", "Bike"), ("figure.hiking", "Hike"), ("tent.fill", "Camping"),
        ("mountain.2.fill", "Mountain"), ("tree.fill", "Park"), ("leaf.fill", "Garden"), ("drop.fill", "Water"),
        ("beach.umbrella.fill", "Beach"), ("camera.fill", "View / Photo"), ("theatermasks.fill", "Theatre"),
        ("music.note", "Music"), ("sportscourt.fill", "Sports"), ("dumbbell.fill", "Gym"), ("graduationcap.fill", "School"),
        ("book.fill", "Library"), ("cross.case.fill", "Hospital"), ("pills.fill", "Pharmacy"), ("pawprint.fill", "Pets"),
        ("wrench.and.screwdriver.fill", "Service"), ("gift.fill", "Gift"), ("person.fill", "Person"),
        ("person.2.fill", "Meeting"), ("lightbulb.fill", "Idea"), ("exclamationmark.triangle.fill", "Warning"),
    ]

    /// A symbol for a kind of place (search results).
    static func symbol(for category: String?) -> String {
        guard let c = category?.lowercased() else { return "mappin" }
        let table: [(String, String)] = [
            ("restaurant", "fork.knife"), ("bakery", "fork.knife"), ("cafe", "cup.and.saucer.fill"), ("nightlife", "wineglass.fill"),
            ("winery", "wineglass.fill"), ("brewery", "wineglass.fill"), ("store", "bag.fill"), ("foodmarket", "cart.fill"),
            ("hotel", "bed.double.fill"), ("campground", "tent.fill"), ("gasstation", "fuelpump.fill"), ("evcharger", "fuelpump.fill"),
            ("parking", "parkingsign"), ("airport", "airplane"), ("publictransport", "tram.fill"), ("marina", "ferry.fill"),
            ("park", "tree.fill"), ("nationalpark", "mountain.2.fill"), ("beach", "beach.umbrella.fill"), ("museum", "building.columns.fill"),
            ("theater", "theatermasks.fill"), ("movietheater", "theatermasks.fill"), ("musicvenue", "music.note"),
            ("stadium", "sportscourt.fill"), ("fitnesscenter", "dumbbell.fill"), ("school", "graduationcap.fill"),
            ("university", "graduationcap.fill"), ("library", "book.fill"), ("hospital", "cross.case.fill"),
            ("pharmacy", "pills.fill"), ("animalservice", "pawprint.fill"), ("automotiverepair", "wrench.and.screwdriver.fill"),
            ("bank", "building.columns.fill"), ("postoffice", "building.2.fill"), ("hiking", "figure.hiking"),
        ]
        return table.first { c.contains($0.0) }?.1 ?? "mappin"
    }
}

struct MapRoute: Codable, Hashable, Identifiable {
    var id = UUID()
    var from: UUID
    var to: UUID
    /// "automobile" or "walking".
    var transport: String = "automobile"
    var color: String = "#3478F6"
    /// The route's line, [latitude, longitude] points.
    var points: [[Double]] = []
    var distance: Double = 0
    var time: Double = 0

    /// "12.4 mi, 18 min by car".
    var summary: String {
        let d = Self.formatter.string(fromDistance: distance)
        let minutes = Int((time / 60).rounded())
        let t = minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
        return "\(d), \(t) \(transport == "walking" ? "walking" : "by car")"
    }

    private static let formatter: MKDistanceFormatter = {
        let f = MKDistanceFormatter()
        f.unitStyle = .abbreviated
        return f
    }()
}

extension NSColor {
    /// "#RRGGBB".
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}

// MARK: - Links from pins

/// What pins link to: pages and paragraphs in the notebooks (as Copy Link to Page / Paragraph makes them), or the web.
@MainActor
enum MapLinks {
    /// A page's paragraphs with words in them: (its container, its number there, its words).
    static func paragraphs(of ref: PageRef) -> [(element: UUID, index: Int, text: String)] {
        let store = NotebookStore.shared
        if store.currentPageRef == ref { store.canvas?.flush() }
        guard let page = store.loadPage(ref) else { return [] }
        var out: [(UUID, Int, String)] = []
        let texts = page.elements.filter { $0.kind == .text }.sorted { ($0.y, $0.x) < ($1.y, $1.x) }
        for element in texts {
            guard let data = element.rtfd, let s = NoteRichText.text(data) else { continue }
            let ns = s.string as NSString
            var location = 0, index = 0
            while location < ns.length {
                let range = ns.paragraphRange(for: NSRange(location: location, length: 0))
                let words = ns.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
                if !words.isEmpty { out.append((element.id, index, words)) }
                location = NSMaxRange(range)
                index += 1
            }
        }
        return out
    }

    /// The pin a pin link goes to (from the map on the page open, else the page as saved).
    static func pin(for url: URL) -> MapPin? {
        let store = NotebookStore.shared
        guard let target = ParagraphTarget(url), let id = target.pin, let ref = store.resolve(url) else { return nil }
        if store.currentPageRef == ref, let maps = store.canvas?.canvas.elementViews.compactMap({ $0 as? MapElementView }) {
            return maps.lazy.compactMap { $0.data.pins.first { $0.id == id } }.first
        }
        return store.loadPage(ref)?.elements.compactMap(\.map).lazy.compactMap { $0.pins.first { $0.id == id } }.first
    }

    /// The name of a link's target: a page's title, "Title › “words…”" for a paragraph, "Title › 📍 Pin" for a pin,
    /// else the address.
    static func title(of url: URL) -> String {
        let store = NotebookStore.shared
        if url.scheme == NotebookStore.linkScheme {
            guard let ref = store.resolve(url) else { return "A page that can't be found" }
            let page = store.meta(ref)?.displayTitle ?? "Page"
            if let target = ParagraphTarget(url), target.pin != nil {
                return "\(page) › 📍 \(pin(for: url)?.title ?? (target.text.isEmpty ? "Pin" : target.text))"
            }
            if let target = ParagraphTarget(url), !target.text.isEmpty {
                let words = target.text.count > 40 ? String(target.text.prefix(40)) + "…" : target.text
                return "\(page) › “\(words)”"
            }
            return page
        }
        if url.scheme == "mailto" { return url.absoluteString.replacingOccurrences(of: "mailto:", with: "") }
        return url.host() ?? url.absoluteString
    }

    /// Goes where a pin links to.
    static func follow(_ url: URL) {
        if url.scheme == NotebookStore.linkScheme { NotebookStore.shared.openLink(url) } else { WebBrowser.open(url) }
    }

    /// A link on the clipboard (Copy Link to Page or Paragraph, or a web address).
    static var copiedLink: URL? {
        let pb = NSPasteboard.general
        if let url = (pb.readObjects(forClasses: [NSURL.self]) as? [URL])?.first, url.scheme != nil { return url }
        if let s = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), let url = URL(string: s),
           let scheme = url.scheme, ["http", "https", "mailto", NotebookStore.linkScheme].contains(scheme) { return url }
        return nil
    }
}
