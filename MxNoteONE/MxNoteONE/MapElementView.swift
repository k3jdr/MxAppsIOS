//
//  MapElementView.swift
//  MxNoteONE
//
//  A map on the page (Apple's maps, through MapKit): pan with a drag, zoom with a pinch or the + −, turn and tilt.
//  Pins as Apple Maps' markers — their colour and symbol (or letters), title, notes and what they link to in a
//  callout — dragged to move them, grouped by category in a list beside the map (each category shown or hidden),
//  joined by driving or walking routes. Search for places to pin them; drop pins with a click; pin an address or
//  where you are. Clicked, the map is active: the Map ribbon tab works on it, and scrolling zooms it (otherwise the
//  page scrolls past it). Printed, exported and sent to OneNote as a picture with its pins.
//

import AppKit
import CoreLocation
import MapKit
import SwiftUI

/// A pin on the map.
final class PinAnnotation: NSObject, MKAnnotation {
    let id: UUID
    // Observed by the map (a renamed pin's marker shows its new name).
    @objc dynamic var coordinate: CLLocationCoordinate2D
    @objc dynamic var title: String?
    @objc dynamic var subtitle: String?
    var pin: MapPin

    init(_ pin: MapPin) {
        id = pin.id
        coordinate = pin.coordinate
        self.pin = pin
        super.init()
        update(pin)
    }

    func update(_ pin: MapPin) {
        self.pin = pin
        if coordinate.latitude != pin.latitude || coordinate.longitude != pin.longitude { coordinate = pin.coordinate }
        if title != pin.title { title = pin.title }
        let sub = [pin.address, pin.linkTitle.map { "→ " + $0 }].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
        if subtitle != sub { subtitle = sub }
    }
}

/// A route's line.
final class RouteLine: MKPolyline {
    var routeID = UUID()
    var color = NSColor.systemBlue
    var walking = false
}

/// A button that runs a closure.
final class ClosureButton: NSButton {
    var handler: () -> Void = {}
    convenience init(symbol: String, tip: String, handler: @escaping () -> Void) {
        self.init(frame: NSRect(x: 0, y: 0, width: 26, height: 26))
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        bezelStyle = .regularSquare
        isBordered = false
        imagePosition = .imageOnly
        toolTip = tip
        self.handler = handler
        target = self
        action = #selector(fire)
    }
    /// A button with words (in a group's callout: a pin's name).
    convenience init(title: String, tip: String?, handler: @escaping () -> Void) {
        self.init(frame: .zero)
        self.title = title
        bezelStyle = .inline
        isBordered = false
        font = .systemFont(ofSize: 11)
        contentTintColor = .controlAccentColor
        alignment = .left
        toolTip = tip
        self.handler = handler
        target = self
        action = #selector(fire)
    }

    @objc private func fire() { handler() }
}

/// A group of nearby pins (all of them, or one category's): their count, colour and category; its callout lists the
/// pins, its right-click menu too.
final class ClusterMarkerView: MKMarkerAnnotationView {
    weak var owner: MapElementView?
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let owner, let cluster = annotation as? MKClusterAnnotation else { return nil }
        owner.activate()
        return owner.clusterMenu(cluster)
    }
}

/// A pin's marker (its right-click menu is the pin's).
final class PinMarkerView: MKMarkerAnnotationView {
    weak var owner: MapElementView?
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let owner, let pin = annotation as? PinAnnotation else { return nil }
        owner.activate()
        return owner.pinMenu(pin.id)
    }
}

/// The map view: active once clicked (scrolling then zooms it; before, the page scrolls past it).
final class NoteMapView: MKMapView {
    weak var owner: MapElementView?

    override var acceptsFirstResponder: Bool { true }

    override func scrollWheel(with event: NSEvent) {
        if owner?.isActive == true { super.scrollWheel(with: event) } else if let page = enclosingScrollView { page.scrollWheel(with: event) } else { super.scrollWheel(with: event) }
    }

    override func magnify(with event: NSEvent) {
        if owner?.isActive == true { super.magnify(with: event) } else if let page = enclosingScrollView { page.magnify(with: event) } else { super.magnify(with: event) }
    }

    override func mouseDown(with event: NSEvent) {
        owner?.activate()
        if NotebookStore.shared.editor.mapDropping, !hitsAnnotation(event), let owner {
            owner.dropPin(at: convert(convert(event.locationInWindow, from: nil), toCoordinateFrom: self))
            return
        }
        super.mouseDown(with: event)
    }

    private func hitsAnnotation(_ event: NSEvent) -> Bool {
        guard let superview else { return false }
        var v = hitTest(superview.convert(event.locationInWindow, from: nil))
        while let view = v, view !== self {
            if view is MKAnnotationView { return true }
            v = view.superview
        }
        return false
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        owner?.activate()
        return owner?.mapMenu(at: convert(convert(event.locationInWindow, from: nil), toCoordinateFrom: self))
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { owner?.focusMoved() }
        return ok
    }
}

/// What the pin list shows (and does).
@Observable
final class MapPanelModel {
    var data = MapData.starter
    var selected: UUID?
    var select: (UUID) -> Void = { _ in }
    var edit: (UUID) -> Void = { _ in }
    var follow: (UUID) -> Void = { _ in }
    var delete: (UUID) -> Void = { _ in }
    var toggleCategory: (String) -> Void = { _ in }
    var addPin: () -> Void = {}
    var deleteRoute: (UUID) -> Void = { _ in }
    var copyLink: (UUID) -> Void = { _ in }
    var colorCategory: (String, String) -> Void = { _, _ in }
}

final class MapElementView: ElementView, MKMapViewDelegate, NSSearchFieldDelegate {
    /// The map being worked on (the Map ribbon tab acts on it).
    static weak var active: MapElementView? {
        didSet {
            NotebookStore.shared.editor.mapActive = active != nil
            if active == nil { NotebookStore.shared.editor.mapDropping = false }
            if oldValue !== active { oldValue?.isEditing = false }
            NotebookStore.shared.editor.mapChanged += 1
        }
    }

    let mapView = NoteMapView()
    let searchField = NSSearchField()
    private let panel = MapPanelModel()
    private var list: NSHostingView<MapPinList>?
    private var annotations: [UUID: PinAnnotation] = [:]
    private var picture: NSImageView?
    private var cameraSave: DispatchWorkItem?
    private var previewWork: DispatchWorkItem?
    private var previewKey: Int?
    /// The last picture of the map (copy, print), and the search running.
    private(set) var lastPicture: NSImage?
    private var search: MKLocalSearch?
    private var settling = true
    /// The pin selected on the map or in the list.
    private(set) var selectedPin: UUID?

    var data: MapData { element.map ?? .starter }
    var isActive: Bool { Self.active === self }
    static let listWidth: CGFloat = 210

    override init(element: PageElement) {
        super.init(element: element)
        mapView.owner = self
        mapView.delegate = self
        mapView.showsZoomControls = true
        mapView.showsCompass = true
        mapView.showsPitchControl = true
        mapView.showsScale = true
        mapView.isRotateEnabled = true
        mapView.isPitchEnabled = true
        mapView.register(PinMarkerView.self, forAnnotationViewWithReuseIdentifier: "pin")
        mapView.register(ClusterMarkerView.self, forAnnotationViewWithReuseIdentifier: MKMapViewDefaultClusterAnnotationViewReuseIdentifier)
        addSubview(mapView)
        searchField.placeholderString = "Search Maps"
        searchField.sendsWholeSearchString = true
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(searchEntered)
        searchField.font = .systemFont(ofSize: 12)
        searchField.toolTip = "Search for a place or an address, then choose one to pin it (⌥ to just go there)"
        addSubview(searchField)
        panel.select = { [weak self] id in self?.selectPin(id, center: true) }
        panel.edit = { [weak self] id in self?.editPin(id) }
        panel.follow = { [weak self] id in self?.followLink(id) }
        panel.delete = { [weak self] id in self?.deletePin(id) }
        panel.toggleCategory = { [weak self] c in self?.toggleCategory(c) }
        panel.addPin = { [weak self] in self?.pinAtCenter() }
        panel.deleteRoute = { [weak self] id in self?.deleteRoute(id) }
        panel.copyLink = { [weak self] id in self?.copyLink(id) }
        panel.colorCategory = { [weak self] c, hex in self?.colorCategory(c, hex) }
        finishSetup()
        configure()
        mapView.camera = Self.camera(for: data)
        sync()
        setWidth(frame.width)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.settling = false }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var minWidth: CGFloat { 280 }

    override func setWidth(_ width: CGFloat) {
        let w = max(minWidth, width)
        setFrameSize(NSSize(width: w, height: Self.gripHeight + max(200, (w * 0.6).rounded())))
    }

    private var showsList: Bool { data.showsList == true && contentFrame.width > Self.listWidth + 200 }

    override func layoutContent() {
        var mapFrame = contentFrame
        if showsList {
            mapFrame.size.width -= Self.listWidth
            if list == nil {
                let host = NSHostingView(rootView: MapPinList(model: panel))
                addSubview(host, positioned: .below, relativeTo: resizeHandle)
                list = host
            }
            list?.isHidden = false
            list?.frame = NSRect(x: mapFrame.maxX, y: contentFrame.minY, width: Self.listWidth, height: contentFrame.height)
        } else {
            list?.isHidden = true
        }
        mapView.frame = mapFrame
        picture?.frame = mapFrame
        // At the top right (the map's scale shows at the top left).
        let w = min(240, mapFrame.width - 80)
        searchField.frame = NSRect(x: mapFrame.maxX - w - 10, y: mapFrame.minY + 10, width: w, height: 24)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil, isActive { Self.active = nil }
    }

    // MARK: Showing the map

    static func camera(for d: MapData) -> MKMapCamera {
        MKMapCamera(lookingAtCenter: d.center, fromDistance: max(50, d.distance), pitch: CGFloat(d.pitch ?? 0), heading: d.heading ?? 0)
    }

    static func configuration(for d: MapData) -> MKMapConfiguration {
        let elevation: MKMapConfiguration.ElevationStyle = d.realistic == true ? .realistic : .flat
        let poi: MKPointOfInterestFilter = d.pointsOfInterest == false ? .excludingAll : .includingAll
        switch d.style ?? .standard {
        case .standard, .muted:
            let c = MKStandardMapConfiguration(elevationStyle: elevation, emphasisStyle: d.style == .muted ? .muted : .default)
            c.pointOfInterestFilter = poi
            c.showsTraffic = d.traffic == true
            return c
        case .satellite:
            return MKImageryMapConfiguration(elevationStyle: elevation)
        case .hybrid:
            let c = MKHybridMapConfiguration(elevationStyle: elevation)
            c.pointOfInterestFilter = poi
            c.showsTraffic = d.traffic == true
            return c
        }
    }

    private func configure() {
        mapView.preferredConfiguration = Self.configuration(for: data)
    }

    /// The pins, routes and list as the data has them.
    private func sync() {
        let d = data
        let shown = d.pins.filter { d.isShown($0) }
        let ids = Set(shown.map(\.id))
        for (id, a) in annotations where !ids.contains(id) {
            mapView.removeAnnotation(a)
            annotations[id] = nil
        }
        for pin in shown {
            if let a = annotations[pin.id] {
                if a.pin != pin {
                    // A pin moved to another category regroups with its new category.
                    let moved = d.clustering == .category && a.pin.categoryName != pin.categoryName
                    a.update(pin)
                    if moved { regroup([a]) } else if let v = mapView.view(for: a) as? MKMarkerAnnotationView { style(v, pin) }
                }
            } else {
                let a = PinAnnotation(pin)
                annotations[pin.id] = a
                mapView.addAnnotation(a)
            }
        }
        // Routes, drawn again.
        mapView.removeOverlays(mapView.overlays)
        for r in d.routes ?? [] where r.points.count > 1 {
            var coords = r.points.map { CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1]) }
            let line = RouteLine(coordinates: &coords, count: coords.count)
            line.routeID = r.id
            line.color = NSColor(hex: r.color) ?? .systemBlue
            line.walking = r.transport == "walking"
            mapView.addOverlay(line, level: .aboveRoads)
        }
        // Groups showing take their pins' new colours and names.
        for case let cluster as MKClusterAnnotation in mapView.annotations {
            if let v = mapView.view(for: cluster) as? MKMarkerAnnotationView { styleCluster(v, cluster) }
        }
        panel.data = d
        panel.selected = selectedPin
        needsLayout = true
        layoutContent()
    }

    private var regrouping: [PinAnnotation] = []

    /// Takes pins off the map and puts them back a moment later, so they group afresh: MapKit groups pins as they're
    /// added, and changing how a marker on show groups (or taking it off and on at once) confuses it.
    private func regroup(_ list: [PinAnnotation]) {
        guard !list.isEmpty else { return }
        mapView.removeAnnotations(list)
        let first = regrouping.isEmpty
        regrouping += list
        guard first else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            var seen = Set<UUID>()
            let back = self.regrouping.filter { a in self.annotations[a.id] === a && seen.insert(a.id).inserted }
            self.regrouping = []
            self.mapView.addAnnotations(back)
        }
    }

    /// A group's marker: the count in its colour, its category under it, its pins in the callout.
    private func styleCluster(_ v: MKMarkerAnnotationView, _ cluster: MKClusterAnnotation) {
        let pins = cluster.memberAnnotations.compactMap { ($0 as? PinAnnotation)?.pin }
        cluster.title = MapData.clusterTitle(pins)
        v.markerTintColor = NSColor(hex: data.clusterColor(pins)) ?? .systemRed
        v.glyphImage = nil
        v.glyphText = "\(pins.count)"
        v.displayPriority = .required
        v.canShowCallout = true
        v.toolTip = ([MapData.clusterTitle(pins)] + pins.prefix(12).map(\.title)).joined(separator: "\n")
        let ids = pins.map(\.id)
        v.rightCalloutAccessoryView = ClosureButton(symbol: "plus.magnifyingglass", tip: "Zoom in to these pins") { [weak self] in self?.zoom(to: ids) }
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        for p in pins.prefix(10) {
            let id = p.id
            stack.addArrangedSubview(ClosureButton(title: p.title, tip: p.address) { [weak self] in self?.goToPin(id) })
        }
        if pins.count > 10 {
            let more = NSTextField(labelWithString: "and \(pins.count - 10) more")
            more.font = .systemFont(ofSize: 11)
            more.textColor = .secondaryLabelColor
            stack.addArrangedSubview(more)
        }
        v.detailCalloutAccessoryView = stack
    }

    /// A marker's colour, symbol or letters, callout and grouping.
    private func style(_ v: MKMarkerAnnotationView, _ pin: MapPin) {
        v.markerTintColor = pin.nsColor
        if let label = pin.label, !label.isEmpty {
            v.glyphImage = nil
            v.glyphText = String(label.prefix(3))
        } else {
            v.glyphText = nil
            v.glyphImage = NSImage(systemSymbolName: pin.symbol ?? "mappin", accessibilityDescription: pin.title)
        }
        v.displayPriority = .required
        v.clusteringIdentifier = data.clusterID(for: pin)
        v.canShowCallout = true
        v.isDraggable = true
        v.toolTip = [pin.title, pin.linkTitle.map { "Links to " + $0 }].compactMap { $0 }.joined(separator: "\n")
        let id = pin.id
        v.leftCalloutAccessoryView = ClosureButton(symbol: "pencil.circle", tip: "Edit Pin…") { [weak self] in self?.editPin(id) }
        v.rightCalloutAccessoryView = pin.linkURL == nil ? nil
            : ClosureButton(symbol: "arrow.up.forward.app", tip: "Go to \(pin.linkTitle ?? "the link")") { [weak self] in self?.followLink(id) }
        if let notes = pin.notes, !notes.isEmpty {
            let label = NSTextField(wrappingLabelWithString: notes)
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            label.preferredMaxLayoutWidth = 220
            v.detailCalloutAccessoryView = label
        } else {
            v.detailCalloutAccessoryView = nil
        }
    }

    // MARK: MKMapViewDelegate

    func mapView(_ mapView: MKMapView, clusterAnnotationForMemberAnnotations memberAnnotations: [any MKAnnotation]) -> MKClusterAnnotation {
        let cluster = MKClusterAnnotation(memberAnnotations: memberAnnotations)
        let pins = memberAnnotations.compactMap { ($0 as? PinAnnotation)?.pin }
        cluster.title = MapData.clusterTitle(pins)
        cluster.subtitle = pins.prefix(5).map(\.title).joined(separator: ", ") + (pins.count > 5 ? "…" : "")
        return cluster
    }

    func mapView(_ mapView: MKMapView, viewFor annotation: any MKAnnotation) -> MKAnnotationView? {
        if let cluster = annotation as? MKClusterAnnotation {
            let id = MKMapViewDefaultClusterAnnotationViewReuseIdentifier
            let v = mapView.dequeueReusableAnnotationView(withIdentifier: id, for: cluster) as? ClusterMarkerView ?? ClusterMarkerView(annotation: cluster, reuseIdentifier: id)
            v.owner = self
            styleCluster(v, cluster)
            return v
        }
        guard let a = annotation as? PinAnnotation else { return nil }
        let v = mapView.dequeueReusableAnnotationView(withIdentifier: "pin", for: a) as? PinMarkerView ?? PinMarkerView(annotation: a, reuseIdentifier: "pin")
        v.owner = self
        style(v, a.pin)
        return v
    }

    func mapView(_ mapView: MKMapView, rendererFor overlay: any MKOverlay) -> MKOverlayRenderer {
        guard let line = overlay as? RouteLine else { return MKOverlayRenderer(overlay: overlay) }
        let r = MKPolylineRenderer(polyline: line)
        r.strokeColor = line.color
        r.lineWidth = 5
        if line.walking { r.lineDashPattern = [2, 8] }
        r.lineCap = .round
        return r
    }

    func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
        guard let a = view.annotation as? PinAnnotation else { return }
        activate()
        selectedPin = a.id
        panel.selected = a.id
        NotebookStore.shared.editor.mapChanged += 1
    }

    func mapView(_ mapView: MKMapView, didDeselect view: MKAnnotationView) {
        guard let a = view.annotation as? PinAnnotation, selectedPin == a.id else { return }
        selectedPin = nil
        panel.selected = nil
        NotebookStore.shared.editor.mapChanged += 1
    }

    func mapView(_ mapView: MKMapView, annotationView view: MKAnnotationView, didChange newState: MKAnnotationView.DragState,
                 fromOldState oldState: MKAnnotationView.DragState) {
        guard newState == .ending || newState == .none, oldState == .ending || oldState == .dragging, let a = view.annotation as? PinAnnotation else { return }
        let c = a.coordinate
        update("Move Pin") { d in
            guard let i = d.pins.firstIndex(where: { $0.id == a.id }) else { return }
            d.pins[i].latitude = c.latitude
            d.pins[i].longitude = c.longitude
        }
        view.dragState = .none
    }

    func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
        guard !settling else { return }
        cameraSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveCamera() }
        cameraSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    /// Where the map looks is kept (not an undo step).
    private func saveCamera() {
        let c = mapView.camera
        var m = data
        let center = c.centerCoordinate
        guard abs(m.latitude - center.latitude) > 1e-7 || abs(m.longitude - center.longitude) > 1e-7 || abs(m.distance - c.centerCoordinateDistance) > 0.5
                || abs((m.heading ?? 0) - c.heading) > 0.01 || abs(Double(m.pitch ?? 0) - Double(c.pitch)) > 0.01 else { return }
        m.latitude = center.latitude
        m.longitude = center.longitude
        m.distance = c.centerCoordinateDistance
        m.heading = c.heading == 0 ? nil : c.heading
        m.pitch = c.pitch == 0 ? nil : Double(c.pitch)
        element.map = m
        controller?.markDirty()
        schedulePreview()
    }

    // MARK: Changes

    /// A change to the map, as an undo step (where the map looks isn't undone).
    func update(_ name: String, _ change: (inout MapData) -> Void) {
        let old = data
        var new = old
        change(&new)
        guard new != old else { return }
        element.map = new
        if old.style != new.style || old.realistic != new.realistic || old.pointsOfInterest != new.pointsOfInterest || old.traffic != new.traffic { configure() }
        // Grouped afresh (all together, by category, or not at all).
        if old.clustering != new.clustering { regroup(Array(annotations.values)) }
        sync()
        controller?.markDirty()
        controller?.undoManager?.registerUndo(withTarget: self) { view in
            let now = view.data
            view.update(name) { d in
                d = old
                d.latitude = now.latitude; d.longitude = now.longitude; d.distance = now.distance; d.heading = now.heading; d.pitch = now.pitch
            }
        }
        controller?.undoManager?.setActionName(name)
        NotebookStore.shared.editor.mapChanged += 1
        schedulePreview()
    }

    // MARK: Active (the Map tab)

    func activate() {
        if !isActive {
            Self.active = self
            isEditing = true
        }
        // Focus to the map (unless typing in its own search field).
        let searching = (window?.firstResponder as? NSTextView)?.delegate === searchField
        if window?.firstResponder !== mapView, !searching { window?.makeFirstResponder(mapView) }
        if NotebookStore.shared.editor.ribbonTab != .map { NotebookStore.shared.editor.ribbonTab = .map }
    }

    /// Focus moving to another container on the page (or the page) ends working on the map — not the ribbon, a
    /// panel or the map's own search field.
    func focusMoved() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, let canvas = self.canvas else { return }
            if let v = window.firstResponder as? NSView, !v.isDescendant(of: self), v.isDescendant(of: canvas) {
                self.deactivate()
            }
        }
    }

    func deactivate() {
        if isActive { Self.active = nil }
        isEditing = false
    }

    // MARK: Pins

    /// The pin a command acts on: the selected one (or the only one).
    var targetPin: MapPin? {
        let d = data
        if let id = selectedPin, let p = d.pins.first(where: { $0.id == id }) { return p }
        return d.pins.count == 1 ? d.pins[0] : nil
    }

    func selectPin(_ id: UUID, center: Bool) {
        guard let a = annotations[id] else { return }
        if center { mapView.setCenter(a.coordinate, animated: true) }
        mapView.selectAnnotation(a, animated: true)
        selectedPin = id
        panel.selected = id
    }

    /// A new pin, selected.
    @discardableResult
    func addPin(_ make: (inout MapPin) -> Void, name: String = "Add Pin") -> UUID {
        var pin = MapPin(title: "Pin \(data.pins.count + 1)", latitude: 0, longitude: 0)
        make(&pin)
        let id = pin.id
        update(name) { $0.pins.append(pin) }
        DispatchQueue.main.async { [weak self] in self?.selectPin(id, center: false) }
        return id
    }

    func dropPin(at c: CLLocationCoordinate2D) {
        let id = addPin({ $0.latitude = c.latitude; $0.longitude = c.longitude }, name: "Drop Pin")
        lookUpAddress(id)
    }

    func pinAtCenter() {
        let c = mapView.centerCoordinate
        let id = addPin({ $0.latitude = c.latitude; $0.longitude = c.longitude })
        lookUpAddress(id)
    }

    /// Fills in a pin's address from where it is.
    func lookUpAddress(_ id: UUID) {
        guard let pin = data.pins.first(where: { $0.id == id }),
              let request = MKReverseGeocodingRequest(location: CLLocation(latitude: pin.latitude, longitude: pin.longitude)) else { return }
        Task { @MainActor [weak self] in
            guard let items = try? await request.mapItems, let item = items.first, let self else { return }
            let address = item.address?.shortAddress ?? item.address?.fullAddress
            guard let address, !address.isEmpty else { return }
            // Quietly (not an undo step of its own): the pin just made gets its address.
            var m = self.data
            guard let i = m.pins.firstIndex(where: { $0.id == id }), m.pins[i].address == nil else { return }
            m.pins[i].address = address
            if m.pins[i].title.hasPrefix("Pin "), let name = item.name, !name.isEmpty { m.pins[i].title = name }
            self.element.map = m
            self.sync()
            self.controller?.markDirty()
            self.schedulePreview()
        }
    }

    func pinAtAddress() {
        let alert = NSAlert()
        alert.messageText = "Pin an Address"
        alert.informativeText = "A street address, a place's name, or a city."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "1 Infinite Loop, Cupertino"
        alert.accessoryView = field
        alert.addButton(withTitle: "Pin")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, let request = MKGeocodingRequest(addressString: text) else { return }
        request.region = mapView.region
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let item = (try? await request.mapItems)?.first else {
                return NotebookStore.shared.showAlert("Address not found", "Nothing was found for “\(text)”. Check the spelling, or add a city.")
            }
            self.pin(item, fallbackTitle: text)
        }
    }

    /// A place found (search or address) as a pin, the map moved to it.
    func pin(_ item: MKMapItem, fallbackTitle: String) {
        let c = item.location.coordinate
        let category = item.pointOfInterestCategory?.rawValue
        addPin({ p in
            p.title = item.name ?? fallbackTitle
            p.latitude = c.latitude
            p.longitude = c.longitude
            p.address = item.address?.shortAddress ?? item.address?.fullAddress
            if category != nil { p.symbol = MapPin.symbol(for: category) }
            if let url = item.url, p.link == nil { p.link = url.absoluteString; p.linkTitle = url.host() }
        }, name: "Add Pin")
        go(to: c, distance: min(mapView.camera.centerCoordinateDistance, 3000))
    }

    func go(to c: CLLocationCoordinate2D, distance: Double) {
        let cam = mapView.camera.copy() as? MKMapCamera ?? MKMapCamera()
        cam.centerCoordinate = c
        cam.centerCoordinateDistance = distance
        mapView.setCamera(cam, animated: true)
    }

    private var locator: MyLocation?

    func pinAtMyLocation() {
        let l = MyLocation()
        locator = l
        l.find { [weak self] result in
            guard let self else { return }
            self.locator = nil
            switch result {
            case .success(let c):
                let id = self.addPin({ $0.title = "My Location"; $0.latitude = c.latitude; $0.longitude = c.longitude; $0.symbol = "person.fill"; $0.color = "#3478F6" })
                self.lookUpAddress(id)
                self.go(to: c, distance: min(self.mapView.camera.centerCoordinateDistance, 2000))
            case .failure(let message):
                NotebookStore.shared.showAlert("Location not available", message)
            }
        }
    }

    func editPin(_ id: UUID? = nil) {
        guard let pin = id.flatMap({ i in data.pins.first { $0.id == i } }) ?? targetPin else { return NSSound.beep() }
        activate()
        MapPinEditor.edit(pin, categories: data.categories, in: window) { [weak self] result in
            switch result {
            case .cancel: break
            case .delete: self?.deletePin(pin.id)
            case .save(var p):
                self?.update("Edit Pin") { d in
                    guard let i = d.pins.firstIndex(where: { $0.id == p.id }) else { return }
                    // Moved to a category with a colour (and not given another): its colour.
                    if p.categoryName != d.pins[i].categoryName, p.color == d.pins[i].color, let c = d.categoryColors?[p.categoryName] { p.color = c }
                    d.pins[i] = p
                }
                DispatchQueue.main.async { self?.selectPin(p.id, center: false) }
            }
        }
    }

    func deletePin(_ id: UUID? = nil) {
        guard let pin = id.flatMap({ i in data.pins.first { $0.id == i } }) ?? targetPin else { return NSSound.beep() }
        if selectedPin == pin.id { selectedPin = nil }
        update("Delete Pin") { d in
            d.pins.removeAll { $0.id == pin.id }
            d.routes?.removeAll { $0.from == pin.id || $0.to == pin.id }
            if d.routes?.isEmpty == true { d.routes = nil }
        }
    }

    func followLink(_ id: UUID? = nil) {
        guard let pin = id.flatMap({ i in data.pins.first { $0.id == i } }) ?? targetPin, let url = pin.linkURL else { return NSSound.beep() }
        MapLinks.follow(url)
    }

    /// Copy Link to Pin: a link that opens this page at the map with the pin centred and its callout open — pasted
    /// on words it links them, pasted alone it's the pin's name.
    func copyLink(_ id: UUID? = nil) {
        guard let pin = id.flatMap({ i in data.pins.first { $0.id == i } }) ?? targetPin, let ref = controller?.ref else { return NSSound.beep() }
        NotebookStore.shared.copyPinLink(ref, map: element.id, pin: pin.id, title: pin.title)
    }

    /// Following a link to a pin: the map scrolled into view and made active, the pin's category shown, the pin
    /// centred with its callout open.
    func reveal(_ id: UUID) {
        guard let pin = data.pins.first(where: { $0.id == id }) else { return NSSound.beep() }
        canvas?.scrollToVisible(frame.insetBy(dx: 0, dy: -20))
        activate()
        if !data.isShown(pin) { toggleCategory(pin.categoryName) }
        go(to: pin.coordinate, distance: min(mapView.camera.centerCoordinateDistance, 4000))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.selectPin(id, center: false) }
    }

    /// The selected pin links to what's on the clipboard (Copy Link to Page or Paragraph, or a web address).
    func pasteLink() {
        guard let pin = targetPin, let url = MapLinks.copiedLink else { return NSSound.beep() }
        update("Link Pin") { d in
            guard let i = d.pins.firstIndex(where: { $0.id == pin.id }) else { return }
            d.pins[i].link = url.absoluteString
            d.pins[i].linkTitle = MapLinks.title(of: url)
        }
    }

    func removeLink() {
        guard let pin = targetPin, pin.link != nil else { return NSSound.beep() }
        update("Remove Link") { d in
            guard let i = d.pins.firstIndex(where: { $0.id == pin.id }) else { return }
            d.pins[i].link = nil
            d.pins[i].linkTitle = nil
        }
    }

    func toggleCategory(_ c: String) {
        update("Show or Hide \(c)") { d in
            var hidden = d.hiddenCategories ?? []
            if let i = hidden.firstIndex(of: c) { hidden.remove(at: i) } else { hidden.append(c) }
            d.hiddenCategories = hidden.isEmpty ? nil : hidden
        }
    }

    // MARK: The map

    func setStyle(_ s: MapStyle) { update("Map Style") { $0.style = s == .standard ? nil : s } }
    func toggle3D() { update("3D Map") { $0.realistic = $0.realistic == true ? nil : true } }
    func togglePointsOfInterest() { update("Points of Interest") { $0.pointsOfInterest = $0.pointsOfInterest == false ? nil : false } }
    func toggleTraffic() { update("Traffic") { $0.traffic = $0.traffic == true ? nil : true } }
    func setClustering(_ c: MapClustering) { update(c.title) { $0.clustering = c } }

    /// A category's colour: its pins take it (and its groups show it).
    func colorCategory(_ category: String, _ hex: String) {
        update("Category Color") { d in
            var colors = d.categoryColors ?? [:]
            colors[category] = hex
            d.categoryColors = colors
            for i in d.pins.indices where d.pins[i].categoryName == category { d.pins[i].color = hex }
        }
    }

    /// Close in on some pins (a group's).
    func zoom(to ids: [UUID]) {
        let coords = data.pins.filter { ids.contains($0.id) }.map(\.coordinate)
        fit(coords.map { MKMapPoint($0) })
    }

    /// Close enough to a pin that it leaves its group (its nearest neighbour in the group well apart on the map), and
    /// select it.
    func goToPin(_ id: UUID) {
        let d = data
        guard let pin = d.pins.first(where: { $0.id == id }) else { return }
        let here = mapView.convert(pin.coordinate, toPointTo: mapView)
        let key = d.clusterID(for: pin)
        // How far apart on the map (points) its nearest neighbour in the group is now; that grows as the camera nears.
        let apart = d.pins.filter { $0.id != id && d.isShown($0) && (key == nil || d.clusterID(for: $0) == key) }
            .map { other -> CGFloat in let p = mapView.convert(other.coordinate, toPointTo: mapView); return hypot(p.x - here.x, p.y - here.y) }.min()
        let now = mapView.camera.centerCoordinateDistance
        var distance = min(now / 5, 1500)
        if let apart, apart > 0.01 { distance = min(distance, now * Double(apart) / 110) }
        go(to: pin.coordinate, distance: max(120, distance))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in self?.selectPin(id, center: false) }
    }

    func clusterMenu(_ cluster: MKClusterAnnotation) -> NSMenu {
        let pins = cluster.memberAnnotations.compactMap { ($0 as? PinAnnotation)?.pin }
        let menu = NSMenu()
        let ids = pins.map(\.id)
        menu.addItem(ClosureMenuItem("Zoom In to \(MapData.clusterTitle(pins))") { [weak self] in self?.zoom(to: ids) })
        menu.addItem(.separator())
        for p in pins.prefix(20) {
            let item = ClosureMenuItem("Go to \(p.title)") { [weak self] in self?.goToPin(p.id) }
            item.image = Self.swatch(p.color)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        for c in MapClustering.allCases {
            menu.addItem(ClosureMenuItem(c.title, state: data.clustering == c) { [weak self] in self?.setClustering(c) })
        }
        return menu
    }
    func toggleList() {
        update("Pin List") { $0.showsList = $0.showsList == true ? nil : true }
    }

    func editTitle() {
        let alert = NSAlert()
        alert.messageText = "Map Title"
        alert.informativeText = "The map's name: shown in the pin list, and found by search."
        let field = NSTextField(string: data.title ?? "")
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let t = field.stringValue.trimmingCharacters(in: .whitespaces)
        update("Map Title") { $0.title = t.isEmpty ? nil : t }
    }

    /// Every shown pin (and route) in view.
    func fitPins() {
        let d = data
        var points = d.pins.filter { d.isShown($0) }.map { MKMapPoint($0.coordinate) }
        for r in d.routes ?? [] { points += r.points.map { MKMapPoint(CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1])) } }
        fit(points)
    }

    private func fit(_ points: [MKMapPoint]) {
        guard !points.isEmpty else { return NSSound.beep() }
        var rect = MKMapRect(origin: points[0], size: MKMapSize(width: 0, height: 0))
        for p in points.dropFirst() { rect = rect.union(MKMapRect(origin: p, size: MKMapSize(width: 0, height: 0))) }
        if rect.size.width < 2000 { rect = rect.insetBy(dx: -1500, dy: -1500) }
        mapView.setVisibleMapRect(rect, edgePadding: NSEdgeInsets(top: 60, left: 50, bottom: 40, right: 50), animated: true)
    }

    func zoom(_ factor: Double) {
        let cam = mapView.camera.copy() as? MKMapCamera ?? MKMapCamera()
        cam.centerCoordinateDistance = max(100, min(4e7, cam.centerCoordinateDistance * factor))
        mapView.setCamera(cam, animated: true)
    }

    func faceNorth() {
        let cam = mapView.camera.copy() as? MKMapCamera ?? MKMapCamera()
        cam.heading = 0
        cam.pitch = 0
        mapView.setCamera(cam, animated: true)
    }

    // MARK: Routes

    func directions() {
        let pins = data.pins
        guard pins.count >= 2 else {
            return NotebookStore.shared.showAlert("Two pins needed", "Directions go from one pin to another: add at least two pins first.")
        }
        activate()
        let from = targetPin?.id ?? pins[0].id
        let to = pins.first { $0.id != from }!.id
        MapDirectionsSheet.ask(pins: pins, from: from, to: to, in: window) { [weak self] from, to, walking in
            self?.route(from: from, to: to, walking: walking)
        }
    }

    func route(from: UUID, to: UUID, walking: Bool, done: ((Bool) -> Void)? = nil) {
        let d = data
        guard let a = d.pins.first(where: { $0.id == from }), let b = d.pins.first(where: { $0.id == to }) else { done?(false); return }
        let request = MKDirections.Request()
        request.source = MKMapItem(location: CLLocation(latitude: a.latitude, longitude: a.longitude), address: nil)
        request.destination = MKMapItem(location: CLLocation(latitude: b.latitude, longitude: b.longitude), address: nil)
        request.transportType = walking ? .walking : .automobile
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                guard let route = try await MKDirections(request: request).calculate().routes.first else { throw CocoaError(.featureUnsupported) }
                let poly = route.polyline
                var coords = [CLLocationCoordinate2D](repeating: CLLocationCoordinate2D(), count: poly.pointCount)
                poly.getCoordinates(&coords, range: NSRange(location: 0, length: poly.pointCount))
                // Thinned to at most 600 points.
                let step = max(1, coords.count / 600)
                var points = stride(from: 0, to: coords.count, by: step).map { [coords[$0].latitude, coords[$0].longitude] }
                if let last = coords.last, step > 1 { points.append([last.latitude, last.longitude]) }
                let colors = ["#3478F6", "#AF52DE", "#F29A38", "#5CC85A", "#EB4D3D"]
                let r = MapRoute(from: from, to: to, transport: walking ? "walking" : "automobile", color: colors[(self.data.routes?.count ?? 0) % colors.count],
                                 points: points, distance: route.distance, time: route.expectedTravelTime)
                self.update("Directions") { d in d.routes = (d.routes ?? []) + [r] }
                self.fitPins()
                done?(true)
            } catch {
                NotebookStore.shared.showAlert("No route found", "Maps couldn't find a \(walking ? "walking" : "driving") route between “\(a.title)” and “\(b.title)”. \(error.localizedDescription)")
                done?(false)
            }
        }
    }

    func deleteRoute(_ id: UUID) {
        update("Delete Route") { d in
            d.routes?.removeAll { $0.id == id }
            if d.routes?.isEmpty == true { d.routes = nil }
        }
    }

    func clearRoutes() {
        guard data.routes != nil else { return NSSound.beep() }
        update("Clear Routes") { $0.routes = nil }
    }

    // MARK: Search

    @objc private func searchEntered() {
        let text = searchField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        runSearch(text)
    }

    func focusSearch() {
        activate()
        window?.makeFirstResponder(searchField)
    }

    /// Places matching the words near the map; choosing one pins it (⌥: just goes there).
    func runSearch(_ text: String, results: (([MKMapItem]) -> Void)? = nil) {
        search?.cancel()
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = text
        request.region = mapView.region
        let s = MKLocalSearch(request: request)
        search = s
        Task { @MainActor [weak self] in
            guard let self else { return }
            let items = (try? await s.start())?.mapItems ?? []
            if let results { return results(items) }
            self.showResults(items, for: text)
        }
    }

    private func showResults(_ items: [MKMapItem], for text: String) {
        let menu = NSMenu()
        if items.isEmpty {
            let none = NSMenuItem(title: "No places found for “\(text)”", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        for item in items.prefix(12) {
            let name = item.name ?? text
            let address = item.address?.shortAddress ?? ""
            let add = ClosureMenuItem(address.isEmpty ? name : "\(name) — \(address)") { [weak self] in self?.pin(item, fallbackTitle: text) }
            add.image = NSImage(systemSymbolName: MapPin.symbol(for: item.pointOfInterestCategory?.rawValue), accessibilityDescription: nil)
            menu.addItem(add)
            let go = ClosureMenuItem("Go to \(name)") { [weak self] in
                guard let self else { return }
                self.go(to: item.location.coordinate, distance: min(self.mapView.camera.centerCoordinateDistance, 3000))
            }
            go.isAlternate = true
            go.keyEquivalentModifierMask = .option
            menu.addItem(go)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: searchField.bounds.height + 2), in: searchField)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            searchField.stringValue = ""
            window?.makeFirstResponder(mapView)
            return true
        }
        return false
    }

    // MARK: Menus

    func mapMenu(at c: CLLocationCoordinate2D) -> NSMenu {
        let menu = contextMenu()
        var items: [NSMenuItem] = [
            ClosureMenuItem("Drop Pin Here") { [weak self] in self?.dropPin(at: c) },
            ClosureMenuItem("Center Map Here") { [weak self] in self?.mapView.setCenter(c, animated: true) },
            ClosureMenuItem("Copy Coordinates") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(String(format: "%.6f, %.6f", c.latitude, c.longitude), forType: .string)
            },
            .separator(),
        ]
        items += mapCommands()
        for (i, item) in items.enumerated() { menu.insertItem(item, at: i) }
        return menu
    }

    func pinMenu(_ id: UUID) -> NSMenu {
        let menu = NSMenu()
        guard let pin = data.pins.first(where: { $0.id == id }) else { return menu }
        selectPin(id, center: false)
        menu.addItem(ClosureMenuItem("Edit “\(pin.title)”…") { [weak self] in self?.editPin(id) })
        menu.addItem(ClosureMenuItem("Copy Link to Pin") { [weak self] in self?.copyLink(id) })
        if pin.linkURL != nil { menu.addItem(ClosureMenuItem("Go to \(pin.linkTitle ?? "Link")") { [weak self] in self?.followLink(id) }) }
        let paste = ClosureMenuItem("Link to Copied Link") { [weak self] in self?.pasteLink() }
        paste.isEnabled = MapLinks.copiedLink != nil
        menu.addItem(paste)
        if pin.link != nil { menu.addItem(ClosureMenuItem("Remove Link") { [weak self] in self?.removeLink() }) }
        menu.addItem(.separator())
        let colors = NSMenuItem(title: "Color", action: nil, keyEquivalent: "")
        let cm = NSMenu()
        for (name, hex) in MapPin.palette {
            let item = ClosureMenuItem(name, state: pin.color == hex) { [weak self] in
                self?.update("Pin Color") { d in if let i = d.pins.firstIndex(where: { $0.id == id }) { d.pins[i].color = hex } }
            }
            item.image = Self.swatch(hex)
            cm.addItem(item)
        }
        colors.submenu = cm
        menu.addItem(colors)
        menu.addItem(ClosureMenuItem("Directions from Here…") { [weak self] in self?.selectPin(id, center: false); self?.directions() })
        menu.addItem(ClosureMenuItem("Look Up Address") { [weak self] in
            self?.update("Look Up Address") { d in if let i = d.pins.firstIndex(where: { $0.id == id }) { d.pins[i].address = nil } }
            self?.lookUpAddress(id)
        })
        menu.addItem(ClosureMenuItem("Open in Maps") {
            let item = MKMapItem(location: CLLocation(latitude: pin.latitude, longitude: pin.longitude), address: nil)
            item.name = pin.title
            item.openInMaps(launchOptions: nil)
        })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Delete Pin") { [weak self] in self?.deletePin(id) })
        return menu
    }

    /// The map's own commands (right-click menu).
    private func mapCommands() -> [NSMenuItem] {
        let d = data
        let style = NSMenuItem(title: "Map Style", action: nil, keyEquivalent: "")
        let sm = NSMenu()
        for s in MapStyle.allCases { sm.addItem(ClosureMenuItem(s.title, state: (d.style ?? .standard) == s) { [weak self] in self?.setStyle(s) }) }
        sm.addItem(.separator())
        sm.addItem(ClosureMenuItem("3D (Terrain and Buildings)", state: d.realistic == true) { [weak self] in self?.toggle3D() })
        sm.addItem(ClosureMenuItem("Points of Interest", state: d.pointsOfInterest != false) { [weak self] in self?.togglePointsOfInterest() })
        sm.addItem(ClosureMenuItem("Traffic", state: d.traffic == true) { [weak self] in self?.toggleTraffic() })
        style.submenu = sm
        let group = NSMenuItem(title: "Group Nearby Pins", action: nil, keyEquivalent: "")
        let gm = NSMenu()
        for c in MapClustering.allCases { gm.addItem(ClosureMenuItem(c.title, state: d.clustering == c) { [weak self] in self?.setClustering(c) }) }
        group.submenu = gm
        return [
            ClosureMenuItem("Pin at Center") { [weak self] in self?.pinAtCenter() },
            ClosureMenuItem("Pin an Address…") { [weak self] in self?.pinAtAddress() },
            ClosureMenuItem("Search Maps…") { [weak self] in self?.focusSearch() },
            style,
            group,
            ClosureMenuItem("Pin List", state: d.showsList == true) { [weak self] in self?.toggleList() },
            ClosureMenuItem("Show All Pins") { [weak self] in self?.fitPins() },
            ClosureMenuItem("Directions…") { [weak self] in self?.directions() },
            ClosureMenuItem("Map Title…") { [weak self] in self?.editTitle() },
            ClosureMenuItem("Copy Picture of Map") { [weak self] in self?.copyPicture() },
            .separator(),
        ]
    }

    static func swatch(_ hex: String) -> NSImage {
        NSImage(size: NSSize(width: 12, height: 12), flipped: false) { r in
            (NSColor(hex: hex) ?? .gray).setFill()
            NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
    }

    // MARK: Pictures (copy, print, export)

    /// After changes settle, a picture of the map with its pins is kept as the element's preview (for printing,
    /// exports and OneNote).
    func schedulePreview() {
        previewWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.renderPreview() }
        previewWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    private func renderPreview() {
        guard !isExport, let controller, let ref = controller.ref, window != nil else { return }
        let d = data
        let size = mapView.bounds.size.width > 50 ? mapView.bounds.size : NSSize(width: 480, height: 300)
        var hasher = Hasher()
        hasher.combine(d)
        hasher.combine(Int(size.width))
        hasher.combine(Int(size.height))
        let key = hasher.finalize()
        guard key != previewKey else { return }
        Task { @MainActor [weak self] in
            guard let image = await MapPicture.render(d, size: size), let self, let png = image.pngData else { return }
            self.lastPicture = image
            self.previewKey = key
            let store = NotebookStore.shared
            if let name = self.element.preview { store.overwriteAsset(name, data: png, for: ref) } else { self.element.preview = store.writeAsset(png, ext: "png", for: ref) }
            self.controller?.markDirty()
        }
    }

    func image() -> NSImage? {
        if let lastPicture { return lastPicture }
        if let name = element.preview, let data = controller?.assetData(name) { return NSImage(data: data) }
        return nil
    }

    func copyPicture() {
        let d = data
        let size = mapView.bounds.size
        Task { @MainActor in
            guard let image = await MapPicture.render(d, size: size) else { return NSSound.beep() }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([image])
        }
    }

    override func prepareForExport() {
        super.prepareForExport()
        // Printed and exported as its picture (a live map doesn't print).
        let view = NSImageView(image: image() ?? NSImage())
        view.imageScaling = .scaleProportionallyUpOrDown
        addSubview(view)
        picture = view
        mapView.isHidden = true
        searchField.isHidden = true
        layoutContent()
    }

    override func makeElement() -> PageElement {
        var e = super.makeElement()
        e.map = data
        return e
    }

    override func indexText() -> String? { data.searchText }
}

// MARK: - Pictures of maps

@MainActor
enum MapPicture {
    /// The map as it looks, with its routes and pins (Apple Maps' markers).
    static func render(_ d: MapData, size: NSSize) async -> NSImage? {
        let options = MKMapSnapshotter.Options()
        options.camera = MapElementView.camera(for: d)
        options.size = size
        options.preferredConfiguration = MapElementView.configuration(for: d)
        options.appearance = NSAppearance(named: .aqua)
        guard let snapshot = try? await MKMapSnapshotter(options: options).start(),
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        defer { NSGraphicsContext.restoreGraphicsState() }
        do {
            let rect = NSRect(origin: .zero, size: size)
            snapshot.image.draw(in: rect)
            // On the Mac the snapshot's points run from the bottom left, as the image does.
            func at(_ c: CLLocationCoordinate2D) -> NSPoint { snapshot.point(for: c) }
            for r in d.routes ?? [] where r.points.count > 1 {
                let path = NSBezierPath()
                for (k, p) in r.points.enumerated() {
                    let q = at(CLLocationCoordinate2D(latitude: p[0], longitude: p[1]))
                    if k == 0 { path.move(to: q) } else { path.line(to: q) }
                }
                path.lineWidth = 5
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                if r.transport == "walking" { path.setLineDash([2, 8], count: 2, phase: 0) }
                (NSColor(hex: r.color) ?? .systemBlue).setStroke()
                path.stroke()
            }
            drawPins(d, at: at)
        }
        NSGraphicsContext.current?.flushGraphics()
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }

    /// The pins — grouped as the map groups them (near each other, all together or by category) into one marker with
    /// their count.
    static func drawPins(_ d: MapData, at: (CLLocationCoordinate2D) -> NSPoint) {
        let shown = d.pins.filter { d.isShown($0) }
        guard d.clustering != .off else { return shown.forEach { drawMarker($0, at: at($0.coordinate)) } }
        var groups: [(key: String, pins: [MapPin], point: NSPoint)] = []
        for pin in shown {
            let p = at(pin.coordinate)
            let key = d.clusterID(for: pin) ?? pin.id.uuidString
            if let i = groups.firstIndex(where: { $0.key == key && hypot($0.point.x - p.x, $0.point.y - p.y) < 34 }) {
                let n = CGFloat(groups[i].pins.count)
                groups[i].point = NSPoint(x: (groups[i].point.x * n + p.x) / (n + 1), y: (groups[i].point.y * n + p.y) / (n + 1))
                groups[i].pins.append(pin)
            } else {
                groups.append((key, [pin], p))
            }
        }
        for g in groups {
            if g.pins.count == 1 { drawMarker(g.pins[0], at: g.point); continue }
            var group = MapPin(title: MapData.clusterTitle(g.pins), latitude: 0, longitude: 0)
            group.color = d.clusterColor(g.pins)
            group.label = "\(g.pins.count)"
            drawMarker(group, at: g.point)
        }
    }

    /// A marker: a coloured balloon pointing at the place, with its symbol or letters in white.
    static func drawMarker(_ pin: MapPin, at p: NSPoint) {
        let r: CGFloat = 13
        let center = NSPoint(x: p.x, y: p.y + r + 7)
        let shape = NSBezierPath()
        shape.appendArc(withCenter: center, radius: r, startAngle: -60, endAngle: 240)
        shape.line(to: p)
        shape.close()
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()
        pin.nsColor.setFill()
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.white.withAlphaComponent(0.9).setStroke()
        shape.lineWidth = 1.2
        shape.stroke()
        if let label = pin.label, !label.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .bold), .foregroundColor: NSColor.white]
            let s = String(label.prefix(3)) as NSString
            let size = s.size(withAttributes: attrs)
            s.draw(at: NSPoint(x: center.x - size.width / 2, y: center.y - size.height / 2), withAttributes: attrs)
        } else if let image = NSImage(systemSymbolName: pin.symbol ?? "mappin", accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold).applying(.init(paletteColors: [.white]))) {
            let s = image.size
            image.draw(in: NSRect(x: center.x - s.width / 2, y: center.y - s.height / 2, width: s.width, height: s.height))
        }
    }
}

// MARK: - Where you are

/// One fix of where the Mac is (asking permission the first time).
final class MyLocation: NSObject, CLLocationManagerDelegate {
    enum Result { case success(CLLocationCoordinate2D), failure(String) }
    private let manager = CLLocationManager()
    private var done: ((Result) -> Void)?

    func find(_ done: @escaping (Result) -> Void) {
        self.done = done
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .denied, .restricted: finish(.failure("MxNoteONE isn't allowed to use your location. Allow it in System Settings ▸ Privacy & Security ▸ Location Services."))
        default: manager.requestLocation()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            switch manager.authorizationStatus {
            case .authorized, .authorizedAlways: manager.requestLocation()
            case .denied, .restricted: finish(.failure("MxNoteONE isn't allowed to use your location. Allow it in System Settings ▸ Privacy & Security ▸ Location Services."))
            default: break
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        MainActor.assumeIsolated { if let c = locations.last?.coordinate { finish(.success(c)) } }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        MainActor.assumeIsolated { finish(.failure("Your location couldn't be found. \(error.localizedDescription)")) }
    }

    private func finish(_ r: Result) {
        guard let done else { return }
        self.done = nil
        done(r)
    }
}

// MARK: - The pin list

struct MapPinList: View {
    @Bindable var model: MapPanelModel

    var body: some View {
        let d = model.data
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(d.title ?? "Map").font(.headline).lineLimit(1)
                Spacer()
                Button { model.addPin() } label: { Image(systemName: "mappin.and.ellipse") }
                    .buttonStyle(.borderless)
                    .help("Add a pin at the centre of the map")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            Divider()
            if d.pins.isEmpty {
                Text("No pins yet. Search for a place, right-click the map, or use the Map tab's Drop Pins.")
                    .font(.caption).foregroundStyle(.secondary).padding(10)
                Spacer()
            } else {
                List {
                    ForEach(d.categories, id: \.self) { category in
                        let hidden = (d.hiddenCategories ?? []).contains(category)
                        Section {
                            if !hidden {
                                ForEach(d.pins.filter { $0.categoryName == category }) { pin in row(pin) }
                            }
                        } header: {
                            HStack(spacing: 4) {
                                Button { model.toggleCategory(category) } label: { Image(systemName: hidden ? "eye.slash" : "eye") }
                                    .buttonStyle(.borderless)
                                    .help(hidden ? "Show this category's pins" : "Hide this category's pins")
                                if let hex = d.categoryColors?[category] {
                                    Circle().fill(Color(nsColor: NSColor(hex: hex) ?? .gray)).frame(width: 8, height: 8)
                                }
                                Text(category)
                                Spacer()
                                Text("\(d.pins.filter { $0.categoryName == category }.count)").foregroundStyle(.secondary)
                            }
                            .contextMenu {
                                Menu("Category Color") {
                                    ForEach(MapPin.palette, id: \.1) { name, hex in
                                        Button { model.colorCategory(category, hex) } label: { Label { Text(name) } icon: { Image(nsImage: MapElementView.swatch(hex)) } }
                                    }
                                }
                                Button(hidden ? "Show \(category)" : "Hide \(category)") { model.toggleCategory(category) }
                            }
                        }
                    }
                    if let routes = d.routes, !routes.isEmpty {
                        Section("Routes") {
                            ForEach(routes) { r in
                                let from = d.pins.first { $0.id == r.from }?.title ?? "?"
                                let to = d.pins.first { $0.id == r.to }?.title ?? "?"
                                HStack(alignment: .top, spacing: 6) {
                                    Image(systemName: r.transport == "walking" ? "figure.walk" : "car.fill").foregroundStyle(Color(nsColor: NSColor(hex: r.color) ?? .systemBlue))
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text("\(from) → \(to)").font(.caption).lineLimit(2)
                                        Text(r.summary).font(.caption2).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button { model.deleteRoute(r.id) } label: { Image(systemName: "xmark.circle") }.buttonStyle(.borderless).help("Remove this route")
                                }
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func row(_ pin: MapPin) -> some View {
        HStack(spacing: 7) {
            ZStack {
                Circle().fill(Color(nsColor: pin.nsColor)).frame(width: 20, height: 20)
                if let label = pin.label, !label.isEmpty {
                    Text(String(label.prefix(3))).font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
                } else {
                    Image(systemName: pin.symbol ?? "mappin").font(.system(size: 9, weight: .semibold)).foregroundStyle(.white)
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(pin.title).font(.callout).lineLimit(1)
                if let t = pin.linkTitle, !t.isEmpty {
                    Text("→ " + t).font(.caption2).foregroundStyle(Color.accentColor).lineLimit(1)
                } else if let a = pin.address, !a.isEmpty {
                    Text(a).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if pin.linkURL != nil {
                Button { model.follow(pin.id) } label: { Image(systemName: "arrow.up.forward.app") }
                    .buttonStyle(.borderless)
                    .help("Go to \(pin.linkTitle ?? "the link")")
            }
        }
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .listRowBackground(model.selected == pin.id ? Color.accentColor.opacity(0.18) : Color.clear)
        .onTapGesture(count: 2) { model.edit(pin.id) }
        .onTapGesture { model.select(pin.id) }
        .contextMenu {
            Button("Edit Pin…") { model.edit(pin.id) }
            Button("Copy Link to Pin") { model.copyLink(pin.id) }
            if pin.linkURL != nil { Button("Go to \(pin.linkTitle ?? "Link")") { model.follow(pin.id) } }
            Divider()
            Button("Delete Pin", role: .destructive) { model.delete(pin.id) }
        }
        .help(pin.notes ?? pin.place)
    }
}

// MARK: - Putting maps on the page

extension CanvasController {
    /// Insert ▸ Map: a map (the continental US, ready for a search), active so the Map tab is at hand.
    func insertMap() {
        guard ref != nil else { return }
        let p = nextInsertionPoint()
        var element = PageElement(kind: .map, x: p.x, y: p.y, width: 600)
        element.map = .starter
        guard let view = addElement(element) as? MapElementView else { return }
        undoManager?.setActionName("Insert Map")
        DispatchQueue.main.async {
            view.activate()
            view.window?.makeFirstResponder(view.searchField)
        }
    }
}
