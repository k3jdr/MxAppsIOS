import AppKit
import AVFoundation
import Combine
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Per-frame state, apart from AppModel so the inspector doesn't redraw on every frame.
@MainActor
final class LiveState: ObservableObject {
    @Published var report: InspectionReport?
    @Published var imageSize: CGSize = .zero
    @Published var framesPerSecond: Double = 0
}

struct LogEntry: Identifiable {
    let id = UUID()
    let date: Date
    let source: String
    let verdict: Verdict
    let milliseconds: Double
    let summary: String
}

/// Hands each camera frame to the display and the inspection queue, on the video queue.
final class FrameRouter: @unchecked Sendable {
    private let display: FrameDisplay
    private let runner: InspectionRunner
    private let lock = NSLock()
    private var showsLive = true
    private var inspectsLive = false
    private var source = ""
    private var sourceName = ""

    init(display: FrameDisplay, runner: InspectionRunner) {
        self.display = display
        self.runner = runner
    }

    func configure(showsLive: Bool, inspectsLive: Bool) {
        lock.lock()
        self.showsLive = showsLive
        self.inspectsLive = inspectsLive
        lock.unlock()
    }

    func setSource(_ source: String, name: String) {
        lock.lock()
        self.source = source
        sourceName = name
        lock.unlock()
    }

    func handle(_ buffer: CVPixelBuffer) {
        lock.lock()
        let show = showsLive
        let inspect = inspectsLive
        let source = self.source
        let name = sourceName
        lock.unlock()
        if show { display.present(buffer) }
        if inspect { runner.submit(.buffer(buffer), source: source, sourceName: name) }
    }
}

enum ImageLoader {
    /// Reads anything ImageIO can (HEIC from an iPhone included) at full size, the right way up.
    static func load(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

@MainActor
final class AppModel: ObservableObject {
    enum RunMode: String, CaseIterable, Identifiable {
        case preview = "Preview"
        case inspect = "Inspect"
        var id: String { rawValue }
    }

    @Published var job = Job() {
        didSet {
            guard job != oldValue else { return }
            runner.update(job: job)
            scheduleAutosave()
            if frozenFrame != nil { inspectFrozen() }
        }
    }
    @Published var jobURL: URL?
    @Published var selectedToolID: UUID?
    @Published var mode: RunMode = .preview { didSet { routeFrames() } }
    @Published var isDrawingROI = false

    @Published private(set) var cameras: [CameraInfo] = []
    @Published private(set) var activeCameraID: String?
    @Published private(set) var pinnedCameraID: String?
    @Published private(set) var controls = CameraControls()
    @Published private(set) var cameraStatus = "Starting…"
    @Published private(set) var cameraAccessDenied = false

    @Published private(set) var frozenFrame: MXVFrame?
    @Published private(set) var stillName: String?
    @Published private(set) var log: [LogEntry] = []
    @Published var alertMessage: String?

    let live = LiveState()
    let display = FrameDisplay()

    private let capture = CaptureEngine()
    private let runner: InspectionRunner
    private let router: FrameRouter
    private let discovery = CameraCatalog.makeDiscovery()
    private var stalledCameras = Set<String>()
    private var deviceObservers: [NSKeyValueObservation] = []
    private var watchdog: Timer?
    private var autosaveWork: DispatchWorkItem?
    private var lastVerdict: Verdict?
    private var lastLogKey = ""
    private var triggerPending = false
    private let keepsSettings: Bool  // false under --ui-check, which must leave the real job and camera choice alone
    private var hasStartedCameras = false
    private(set) var reportCount = 0

    static let logLimit = 500

    /// A given job is for --ui-check: it runs without touching the autosaved one.
    init(job given: Job? = nil) {
        let models = Bundle.main.resourceURL!.appendingPathComponent("Models").path
        runner = InspectionRunner(modelsDirectory: models)
        router = FrameRouter(display: display, runner: runner)

        keepsSettings = given == nil
        if let given {
            self.job = given
        } else if let saved = try? Data(contentsOf: Self.autosaveURL), let job = try? JSONDecoder().decode(Job.self, from: saved) {
            self.job = job
        } else {
            var starter = Job()
            starter.tools = [ToolConfig(kind: .quality)]
            self.job = starter
        }
        selectedToolID = job.tools.first?.id
        pinnedCameraID = keepsSettings ? UserDefaults.standard.string(forKey: "pinnedCamera") : nil
        runner.update(job: job)

        capture.onFrame = { [router] in router.handle($0) }
        capture.onControlsChanged = { [weak self] controls in
            MainActor.assumeIsolated { self?.controls = controls }
        }
        runner.onReport = { [weak self] report in
            MainActor.assumeIsolated { self?.receive(report) }
        }
        display.onSizeChange = { [weak self] size in
            MainActor.assumeIsolated { self?.live.imageSize = size }
        }
    }

    // MARK: Cameras

    func startCameras() {
        guard !hasStartedCameras else { return }
        hasStartedCameras = true
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            beginDiscovery()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        if granted { self.beginDiscovery() } else { self.denyCameraAccess() }
                    }
                }
            }
        default:
            denyCameraAccess()
        }
    }

    private func denyCameraAccess() {
        cameraAccessDenied = true
        cameraStatus = "MxOpenCVD doesn't have permission to use the cameras."
    }

    private func beginDiscovery() {
        deviceObservers.append(discovery.observe(\.devices, options: []) { [weak self] _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.camerasChanged() } }
        })
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.camerasChanged() }
            }
        }
        watchdog = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkCameraIsAlive() }
        }
        camerasChanged()
    }

    private func camerasChanged() {
        stalledCameras.removeAll()  // anything may work again now the set of cameras has changed
        observeSuspension()
        chooseCamera()
    }

    /// Continuity Camera suspends rather than disconnects in some cases, as when the phone is in use.
    private func observeSuspension() {
        deviceObservers.removeAll { _ in true }
        deviceObservers.append(discovery.observe(\.devices, options: []) { [weak self] _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.camerasChanged() } }
        })
        for device in discovery.devices {
            deviceObservers.append(device.observe(\.isSuspended, options: []) { [weak self] _, _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.chooseCamera() } }
            })
        }
    }

    private func chooseCamera() {
        cameras = CameraCatalog.ranked(discovery.devices)
        let choice = CameraCatalog.choose(from: cameras, pinned: pinnedCameraID, excluding: stalledCameras)
        if choice?.id != activeCameraID {
            activate(choice)
        }
        updateStatus()
    }

    private func activate(_ camera: CameraInfo?) {
        activeCameraID = camera?.id
        guard let camera, let device = discovery.devices.first(where: { $0.uniqueID == camera.id }) else {
            capture.stop()
            return
        }
        router.setSource(camera.id, name: camera.name)
        capture.start(device) { [weak self] error in
            MainActor.assumeIsolated {
                guard let self, let error, self.activeCameraID == camera.id else { return }
                self.stalledCameras.insert(camera.id)
                self.alertMessage = "\(camera.name) didn't start: \(error.localizedDescription)"
                self.chooseCamera()
            }
        }
    }

    /// A camera can stop sending frames with no notification, and an iPhone is the likeliest to do it.
    private func checkCameraIsAlive() {
        live.framesPerSecond = capture.framesPerSecond
        guard let active = activeCameraID, capture.secondsSinceLastFrame > 6 else { return }
        stalledCameras.insert(active)
        chooseCamera()
    }

    private func updateStatus() {
        guard let active = cameras.first(where: { $0.id == activeCameraID }) else {
            cameraStatus = cameras.isEmpty ? "No cameras found." : "No camera is available."
            return
        }
        if let pinned = pinnedCameraID, pinned != active.id {
            cameraStatus = "The chosen camera isn't available. Using \(active.name)."
        } else if pinnedCameraID != nil {
            cameraStatus = "Using \(active.name), chosen by you."
        } else if active.tier == .iPhone {
            cameraStatus = "Using \(active.name), the primary camera."
        } else {
            cameraStatus = "The iPhone isn't available. Using \(active.name)."
        }
    }

    /// nil returns to automatic selection.
    func pinCamera(_ id: String?) {
        pinnedCameraID = id
        if keepsSettings { UserDefaults.standard.set(id, forKey: "pinnedCamera") }
        stalledCameras.removeAll()
        chooseCamera()
    }

    /// point is 0...1 in the image, from the top left, the same convention as focusPointOfInterest.
    func focus(at point: CGPoint) { capture.setFocus(at: point) }
    func setFocusLocked(_ locked: Bool) { capture.setFocusLocked(locked) }
    func setExposureLocked(_ locked: Bool) { capture.setExposureLocked(locked) }

    func openCameraPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
            NSWorkspace.shared.open(url)
        }
    }

    var activeCamera: CameraInfo? { cameras.first { $0.id == activeCameraID } }

    // MARK: Frames

    private func routeFrames() {
        router.configure(showsLive: frozenFrame == nil, inspectsLive: frozenFrame == nil && mode == .inspect)
    }

    /// The image on screen as a frame of its own: the frozen one, or the camera's newest.
    func currentFrame() -> MXVFrame? {
        if let frozenFrame { return frozenFrame }
        return capture.latestFrame.map { MXVFrame(pixelBuffer: $0) }
    }

    private var currentSource: String { frozenFrame != nil && stillName != nil ? Job.stillSource : (activeCameraID ?? Job.stillSource) }
    private var currentSourceName: String { stillName ?? activeCamera?.name ?? "No camera" }

    func trigger() {
        guard let frame = currentFrame() else {
            alertMessage = "There's no image to inspect yet."
            return
        }
        triggerPending = true
        runner.submit(.frame(frame), source: currentSource, sourceName: currentSourceName)
    }

    func toggleFreeze() {
        if frozenFrame != nil {
            resumeLive()
        } else if let buffer = capture.latestFrame {
            freeze(on: MXVFrame(pixelBuffer: buffer), name: nil)
        } else {
            alertMessage = "There's no image to freeze yet."
        }
    }

    func resumeLive() {
        frozenFrame = nil
        stillName = nil
        live.report = nil
        routeFrames()
    }

    private func freeze(on frame: MXVFrame, name: String?) {
        frozenFrame = frame
        stillName = name
        routeFrames()
        if let image = frame.createCGImage() {
            display.present(image)
        }
        inspectFrozen()
    }

    private func inspectFrozen() {
        guard let frozenFrame else { return }
        runner.submit(.frame(frozenFrame), source: currentSource, sourceName: currentSourceName)
    }

    func openImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.message = "Choose an image to inspect instead of the camera"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openImage(at: url)
    }

    func openImage(at url: URL) {
        guard let image = ImageLoader.load(url), let frame = MXVFrame(cgImage: image) else {
            alertMessage = "\(url.lastPathComponent) couldn't be read as an image."
            return
        }
        freeze(on: frame, name: url.lastPathComponent)
    }

    func saveSnapshot() {
        guard let frame = currentFrame(), let data = frame.pngData(in: .null) else {
            alertMessage = "There's no image to save yet."
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "Snapshot \(Self.fileDate.string(from: Date())).png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url)
        } catch {
            alertMessage = "The image wasn't saved: \(error.localizedDescription)"
        }
    }

    private func receive(_ report: InspectionReport) {
        live.report = report
        reportCount += 1

        let wasTriggered = triggerPending
        triggerPending = false
        // Live inspection repeats itself many times a second. Its log keeps changes: a different result, or a
        // different set of tools failing. A trigger or a frozen image is one deliberate result, so it always logs.
        let isContinuous = mode == .inspect && frozenFrame == nil
        let logKey = report.verdict.rawValue + report.tools.filter { $0.verdict == .fail }.map(\.name).joined(separator: "|")
        if !isContinuous || wasTriggered || logKey != lastLogKey {
            append(report)
        }
        lastLogKey = logKey
        if job.saveFailureImages, report.verdict == .fail, wasTriggered || lastVerdict != .fail {
            saveFailure(report)
        }
        lastVerdict = report.verdict
    }

    private func append(_ report: InspectionReport) {
        let failed = report.tools.filter { $0.verdict == .fail }
        let summary: String
        if failed.isEmpty {
            let texts = report.tools.flatMap { $0.output.texts }
            summary = texts.isEmpty ? (report.tools.count == 1 ? "1 tool ran" : "\(report.tools.count) tools ran") : texts.joined(separator: " | ")
        } else {
            summary = failed.map { "\($0.name): \($0.reasons.joined(separator: "; "))" }.joined(separator: " • ")
        }
        log.insert(LogEntry(date: report.date, source: report.source, verdict: report.verdict, milliseconds: report.totalMs, summary: summary), at: 0)
        if log.count > Self.logLimit {
            log.removeLast(log.count - Self.logLimit)
        }
    }

    private func saveFailure(_ report: InspectionReport) {
        let name = "\(Self.fileDate.string(from: report.date)) \(report.source).png".replacingOccurrences(of: "/", with: "-")
        let frame = report.frame
        DispatchQueue.global(qos: .utility).async {
            let folder = Self.failureFolder
            guard let data = frame.pngData(in: .null) else { return }
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? data.write(to: folder.appendingPathComponent(name))
        }
    }

    nonisolated static var failureFolder: URL {
        FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0].appendingPathComponent("MxOpenCVD/Failures")
    }

    private static let fileDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss.SSS"
        return formatter
    }()

    func clearLog() { log.removeAll() }

    func exportLog() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "\(job.name) results.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let formatter = ISO8601DateFormatter()
        var rows = ["time,camera,result,ms,details"]
        for entry in log.reversed() {
            let fields = [formatter.string(from: entry.date), entry.source, entry.verdict.rawValue, String(format: "%.1f", entry.milliseconds), entry.summary]
            rows.append(fields.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }.joined(separator: ","))
        }
        do {
            try rows.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
        } catch {
            alertMessage = "The results weren't saved: \(error.localizedDescription)"
        }
    }

    // MARK: Tools

    func addTool(_ kind: ToolKind) {
        let tool = ToolConfig(kind: kind)
        job.tools.append(tool)
        selectedToolID = tool.id
    }

    func removeTool(_ id: UUID) {
        job.tools.removeAll { $0.id == id }
        if selectedToolID == id { selectedToolID = job.tools.first?.id }
    }

    /// Saves the selected region of the current image as what the Pattern Match tool looks for.
    func teachPattern(toolID: UUID) {
        guard let index = job.tools.firstIndex(where: { $0.id == toolID }) else { return }
        guard let area = job.tools[index].roi else {
            alertMessage = "Draw a region around the part first."
            return
        }
        guard let frame = currentFrame() else {
            alertMessage = "There's no image to teach from yet."
            return
        }
        let size = frame.size
        let rect = CGRect(x: area.minX * size.width, y: area.minY * size.height, width: area.width * size.width, height: area.height * size.height).integral
        guard let data = frame.pngData(in: rect) else {
            alertMessage = "That region is empty."
            return
        }
        job.tools[index].patternPNG = data
        // The drawn region was the part itself; searching only there would stop it finding a part that has moved.
        job.tools[index].roi = nil
    }

    /// Adds a color to a color tool, trained from its region on the current image.
    func addColor(toolID: UUID) {
        guard let index = job.tools.firstIndex(where: { $0.id == toolID }) else { return }
        guard let area = job.tools[index].roi else {
            alertMessage = "Draw a region on the color first."
            return
        }
        guard let frame = currentFrame() else {
            alertMessage = "There's no image to teach from yet."
            return
        }
        let size = frame.size
        let rect = CGRect(x: area.minX * size.width, y: area.minY * size.height, width: area.width * size.width, height: area.height * size.height).integral
        let trained = MXVEngine.trainColor(in: frame, roi: rect, numbers: job.tools[index].engineNumbers.mapValues { NSNumber(value: $0) })
        job.tools[index].colors.append(ColorReference(trained, name: "Color \(job.tools[index].colors.count + 1)"))
        if job.tools[index].kind.searchesWholeImageAfterTeaching {
            job.tools[index].roi = nil
        }
    }

    /// Saves the Contours tool's outlines from the current image. The extension chosen sets the format.
    func exportContours(toolID: UUID) {
        guard let tool = job.tools.first(where: { $0.id == toolID }) else { return }
        guard let frame = currentFrame() else {
            alertMessage = "There's no image to export from yet."
            return
        }
        let contours = ContourExport.extract(tool: tool, frame: frame)
        guard !contours.isEmpty else {
            alertMessage = "This tool finds no outlines in the current image, so there's nothing to export."
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = ContourExport.Format.allCases.compactMap(\.contentType)
        panel.allowsOtherFileTypes = false
        panel.nameFieldStringValue = "\(tool.name).dxf"
        panel.message = "Name it .dxf for CAD, .svg for drawing programs, or .csv for spreadsheets."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ContourExport.write(contours, imageSize: frame.size, mmPerPixel: currentScale, to: url)
        } catch {
            alertMessage = "The contours weren't saved: \(error.localizedDescription)"
        }
    }

    // MARK: Calibration

    var calibrationKey: String { currentSource }

    var currentScale: Double? { job.calibrations[calibrationKey] }

    func setScale(_ mmPerPixel: Double?) {
        if let mmPerPixel, mmPerPixel > 0 {
            job.calibrations[calibrationKey] = mmPerPixel
        } else {
            job.calibrations[calibrationKey] = nil
        }
    }

    /// Returns a sentence for the panel to show.
    func calibrateFromChessboard(cols: Int, rows: Int, squareMM: Double) -> String {
        guard let frame = currentFrame() else { return "There's no image yet." }
        let result = MXVEngine.measureChessboard(in: frame, cols: cols, rows: rows, squareMM: squareMM)
        guard result.found else {
            return "No \(cols) × \(rows) board was found. Check that the whole board is in view, in focus and evenly lit."
        }
        setScale(result.mmPerPixel)
        return String(format: "Board found: %.4f mm per pixel.", result.mmPerPixel)
    }

    // MARK: Job files

    static var autosaveURL: URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MxOpenCVD")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("current-job.json")
    }

    private func scheduleAutosave() {
        guard keepsSettings else { return }
        autosaveWork?.cancel()
        let snapshot = job
        let work = DispatchWorkItem {
            if let data = try? Self.encode(snapshot) {
                try? data.write(to: Self.autosaveURL, options: .atomic)
            }
        }
        autosaveWork = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1, execute: work)
    }

    nonisolated private static func encode(_ job: Job) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(job)
    }

    func newJob() {
        var fresh = Job()
        fresh.tools = [ToolConfig(kind: .quality)]
        job = fresh
        jobURL = nil
        selectedToolID = fresh.tools.first?.id
        live.report = nil
        clearLog()
    }

    func openJob() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            job = try JSONDecoder().decode(Job.self, from: Data(contentsOf: url))
            jobURL = url
            selectedToolID = job.tools.first?.id
            live.report = nil
        } catch {
            alertMessage = "\(url.lastPathComponent) isn't a job file this version can read."
        }
    }

    func saveJob() {
        if let jobURL {
            write(to: jobURL)
        } else {
            saveJobAs()
        }
    }

    func saveJobAs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(job.name).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        write(to: url)
        jobURL = url
    }

    private func write(to url: URL) {
        do {
            try Self.encode(job).write(to: url, options: .atomic)
        } catch {
            alertMessage = "The job wasn't saved: \(error.localizedDescription)"
        }
    }
}
