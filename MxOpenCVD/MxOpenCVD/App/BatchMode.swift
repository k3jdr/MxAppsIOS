import AVFoundation
import Foundation

/// Command-line modes of the app's own executable, for scripted inspection and for checking the cameras:
///   MxOpenCVD --inspect job.json image... [--out results.json]    exit status 0 only if every image passes
///   MxOpenCVD --probe-cameras [--snapshots dir] [--out cameras.json]
///   MxOpenCVD --repeat job.json [--seconds 10] [--camera name] [--out results.json]    how much each measure varies on a still scene
///   MxOpenCVD --export-contours job.json image out.dxf|.svg|.csv    the job's first Contours tool, from an image file
///   MxOpenCVD --teach-color job.json "tool name" "color name" image x y width height out.json    adds a color to a color tool
///   MxOpenCVD --self-test    checks camera ranking, failover and pass/fail logic without any camera
///   MxOpenCVD --ui-check dir [--job job.json] [--image image] [--soak seconds]    runs the real window off screen, with the live cameras
enum BatchMode {
    static func runIfRequested() -> Bool {
        let arguments = CommandLine.arguments
        if arguments.contains("--inspect") {
            exit(inspect(arguments))
        }
        if arguments.contains("--probe-cameras") {
            exit(probeCameras(arguments))
        }
        if arguments.contains("--teach-color") {
            exit(teachColor(arguments))
        }
        if arguments.contains("--export-contours") {
            exit(exportContours(arguments))
        }
        if let jobPath = value(of: "--repeat", in: arguments) {
            exit(repeatability(jobPath: jobPath, arguments))
        }
        if let folder = value(of: "--ui-check", in: arguments) {
            MainActor.assumeIsolated {  // main() runs on the main thread
                UICheck.run(folder: folder, jobPath: value(of: "--job", in: arguments), imagePath: value(of: "--image", in: arguments),
                            soakSeconds: value(of: "--soak", in: arguments).flatMap(Double.init) ?? 0)
            }
            exit(0)
        }
        if arguments.contains("--self-test") {
            exit(SelfTest.run(modelsDirectory: modelsDirectory))
        }
        return false
    }

    private static func value(of flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    private static func emit(_ object: Any, to path: String?) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else { return }
        if let path {
            try? data.write(to: URL(fileURLWithPath: path))
        } else {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        }
    }

    private static func say(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    private static var modelsDirectory: String {
        Bundle.main.resourceURL!.appendingPathComponent("Models").path
    }

    private static func inspect(_ arguments: [String]) -> Int32 {
        guard let start = arguments.firstIndex(of: "--inspect"), start + 2 < arguments.count else {
            say("usage: MxOpenCVD --inspect job.json image... [--out results.json]")
            return 2
        }
        var rest = Array(arguments[(start + 1)...])
        var out: String?
        if let index = rest.firstIndex(of: "--out"), index + 1 < rest.count {
            out = rest[index + 1]
            rest.removeSubrange(index...(index + 1))
        }
        let job: Job
        do {
            job = try JSONDecoder().decode(Job.self, from: Data(contentsOf: URL(fileURLWithPath: rest[0])))
        } catch {
            say("Couldn't read the job \(rest[0]): \(error.localizedDescription)")
            return 2
        }

        let runner = InspectionRunner(modelsDirectory: modelsDirectory)
        var results: [[String: Any]] = []
        var allPassed = true
        for path in rest.dropFirst() {
            guard let image = ImageLoader.load(URL(fileURLWithPath: path)), let frame = MXVFrame(cgImage: image) else {
                say("Couldn't read the image \(path)")
                results.append(["image": path, "verdict": "UNREADABLE"])
                allPassed = false
                continue
            }
            let report = runner.run(job: job, frame: frame, source: Job.stillSource, sourceName: path)
            if report.verdict == .fail { allPassed = false }
            results.append([
                "image": path,
                "verdict": report.verdict.rawValue,
                "totalMs": report.totalMs,
                "tools": report.tools.map { tool -> [String: Any] in
                    [
                        "name": tool.name,
                        "kind": tool.kind.rawValue,
                        "verdict": tool.verdict.rawValue,
                        "reasons": tool.reasons,
                        "texts": tool.output.texts,
                        "measures": Dictionary(uniqueKeysWithValues: tool.output.measures.map { ($0.name, $0.value) }),
                        "ms": tool.output.elapsedMs,
                    ]
                },
            ])
        }
        emit(results, to: out)
        return allPassed ? 0 : 1
    }

    private static func teachColor(_ arguments: [String]) -> Int32 {
        guard let start = arguments.firstIndex(of: "--teach-color"), start + 9 < arguments.count,
              let x = Double(arguments[start + 5]), let y = Double(arguments[start + 6]),
              let width = Double(arguments[start + 7]), let height = Double(arguments[start + 8])
        else {
            say("usage: MxOpenCVD --teach-color job.json \"tool name\" \"color name\" image x y width height out.json")
            return 2
        }
        let jobPath = arguments[start + 1], toolName = arguments[start + 2], colorName = arguments[start + 3]
        guard let data = FileManager.default.contents(atPath: jobPath), var job = try? JSONDecoder().decode(Job.self, from: data) else {
            say("Couldn't read the job \(jobPath)")
            return 2
        }
        guard let index = job.tools.firstIndex(where: { $0.name == toolName }), job.tools[index].kind.usesColors else {
            say("The job has no color tool named \(toolName).")
            return 2
        }
        guard let image = ImageLoader.load(URL(fileURLWithPath: arguments[start + 4])), let frame = MXVFrame(cgImage: image) else {
            say("Couldn't read the image \(arguments[start + 4])")
            return 2
        }
        let trained = MXVEngine.trainColor(in: frame, roi: CGRect(x: x, y: y, width: width, height: height), numbers: job.tools[index].engineNumbers.mapValues { NSNumber(value: $0) })
        job.tools[index].colors.append(ColorReference(trained, name: colorName))
        do {
            try JSONEncoder().encode(job).write(to: URL(fileURLWithPath: arguments[start + 9]))
        } catch {
            say("Couldn't write \(arguments[start + 9]): \(error.localizedDescription)")
            return 1
        }
        return 0
    }

    private static func exportContours(_ arguments: [String]) -> Int32 {
        guard let start = arguments.firstIndex(of: "--export-contours"), start + 3 < arguments.count else {
            say("usage: MxOpenCVD --export-contours job.json image out.dxf|.svg|.csv")
            return 2
        }
        let jobPath = arguments[start + 1], imagePath = arguments[start + 2], outPath = arguments[start + 3]
        guard let data = FileManager.default.contents(atPath: jobPath), let job = try? JSONDecoder().decode(Job.self, from: data) else {
            say("Couldn't read the job \(jobPath)")
            return 2
        }
        guard let tool = job.tools.first(where: { $0.kind == .contours }) else {
            say("The job has no Contours tool.")
            return 2
        }
        guard let image = ImageLoader.load(URL(fileURLWithPath: imagePath)), let frame = MXVFrame(cgImage: image) else {
            say("Couldn't read the image \(imagePath)")
            return 2
        }
        let contours = ContourExport.extract(tool: tool, frame: frame)
        do {
            try ContourExport.write(contours, imageSize: frame.size, mmPerPixel: job.calibrations[Job.stillSource], to: URL(fileURLWithPath: outPath))
        } catch {
            say("Couldn't write \(outPath): \(error.localizedDescription)")
            return 1
        }
        say("Wrote \(contours.count) contours to \(outPath)")
        return 0
    }

    /// Runs a job on a live camera again and again and reports how much each measure varies. With nothing moving in view,
    /// that spread is the real repeatability of the measurement, noise and all, which no synthetic test can stand in for.
    private static func repeatability(jobPath: String, _ arguments: [String]) -> Int32 {
        let out = value(of: "--out", in: arguments)
        guard let data = FileManager.default.contents(atPath: jobPath), let job = try? JSONDecoder().decode(Job.self, from: data) else {
            say("Couldn't read the job \(jobPath)")
            emit(["error": "couldn't read the job"], to: out)
            return 2
        }
        let wait = DispatchSemaphore(value: 0)
        var granted = false
        AVCaptureDevice.requestAccess(for: .video) {
            granted = $0
            wait.signal()
        }
        wait.wait()
        guard granted else {
            say("Camera access is denied. Allow MxOpenCVD in System Settings ▸ Privacy & Security ▸ Camera.")
            emit(["error": "camera access denied"], to: out)
            return 3
        }

        let devices = CameraCatalog.makeDiscovery().devices
        let ranked = CameraCatalog.ranked(devices)
        let wanted = value(of: "--camera", in: arguments)
        guard let camera = wanted.map({ name in ranked.first { $0.name == name } }) ?? CameraCatalog.choose(from: ranked, pinned: nil, excluding: []),
              let device = devices.first(where: { $0.uniqueID == camera.id })
        else {
            say("No camera\(wanted.map { " named \($0)" } ?? "") is available.")
            emit(["error": "no such camera"], to: out)
            return 2
        }

        let capture = CaptureEngine()
        capture.start(device) { _ in }
        // Let the camera's exposure and focus settle first, or the spread only measures that.
        RunLoop.main.run(until: Date().addingTimeInterval(3))

        let seconds = value(of: "--seconds", in: arguments).flatMap(Double.init) ?? 10
        let runner = InspectionRunner(modelsDirectory: modelsDirectory)
        var samples: [String: [String: [Double]]] = [:]
        var verdicts: [String: Int] = [:]
        var slowest = 0.0, total = 0.0, runs = 0
        let end = Date().addingTimeInterval(seconds)
        var previous: CVPixelBuffer?
        while Date() < end {
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
            // Each frame once, since the same frame twice would make the spread look better than it is.
            guard let buffer = capture.latestFrame, buffer !== previous else { continue }
            previous = buffer
            let report = runner.run(job: job, frame: MXVFrame(pixelBuffer: buffer), source: camera.id, sourceName: camera.name)
            verdicts[report.verdict.rawValue, default: 0] += 1
            slowest = max(slowest, report.totalMs)
            total += report.totalMs
            runs += 1
            for tool in report.tools {
                for measure in tool.output.measures {
                    samples["\(tool.name)", default: [:]][measure.name, default: []].append(measure.value)
                }
            }
        }
        capture.stop()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))

        var tools: [String: Any] = [:]
        for (name, measures) in samples {
            var summary: [String: Any] = [:]
            for (measure, values) in measures {
                let mean = values.reduce(0, +) / Double(values.count)
                let variance = values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(max(values.count - 1, 1))
                summary[measure] = ["mean": mean, "std": variance.squareRoot(), "min": values.min() ?? 0, "max": values.max() ?? 0, "n": values.count]
            }
            tools[name] = summary
        }
        emit(["camera": camera.name, "runs": runs, "seconds": seconds, "meanMs": runs > 0 ? total / Double(runs) : 0, "slowestMs": slowest, "verdicts": verdicts, "tools": tools], to: out)
        return 0
    }

    /// Lists the cameras in acquisition order, starts each in turn, and measures one real frame from it.
    private static func probeCameras(_ arguments: [String]) -> Int32 {
        let wait = DispatchSemaphore(value: 0)
        var granted = false
        AVCaptureDevice.requestAccess(for: .video) {
            granted = $0
            wait.signal()
        }
        wait.wait()
        guard granted else {
            say("Camera access is denied. Allow MxOpenCVD in System Settings ▸ Privacy & Security ▸ Camera.")
            emit(["error": "camera access denied"], to: value(of: "--out", in: arguments))
            return 3
        }

        let snapshots = value(of: "--snapshots", in: arguments)
        if let snapshots {
            try? FileManager.default.createDirectory(atPath: snapshots, withIntermediateDirectories: true)
        }
        let engine = MXVEngine(modelsDirectory: modelsDirectory)
        let devices = CameraCatalog.makeDiscovery().devices
        let chosen = CameraCatalog.choose(from: CameraCatalog.ranked(devices), pinned: nil, excluding: [])

        var results: [[String: Any]] = []
        for camera in CameraCatalog.ranked(devices) {
            var entry: [String: Any] = [
                "name": camera.name, "model": camera.model, "tier": camera.tier.title, "role": camera.tier.role,
                "isDeskView": camera.isDeskView, "isSuspended": camera.isSuspended, "autoChosen": chosen?.id == camera.id,
            ]
            if let device = devices.first(where: { $0.uniqueID == camera.id }) {
                entry.merge(grabFrame(from: device, cameraName: camera.name, engine: engine, snapshots: snapshots)) { _, new in new }
            }
            results.append(entry)
        }
        emit(["libraries": MXVEngine.libraryVersions(), "cameras": results], to: value(of: "--out", in: arguments))
        return 0
    }

    private static func grabFrame(from device: AVCaptureDevice, cameraName: String, engine: MXVEngine, snapshots: String?) -> [String: Any] {
        let capture = CaptureEngine()
        let first = DispatchSemaphore(value: 0)
        let settled = NSLock()
        var seen = 0
        // Skip the first frames, while the camera's exposure settles.
        capture.onFrame = { _ in
            settled.lock()
            seen += 1
            if seen == 45 { first.signal() }
            settled.unlock()
        }
        var startError: Error?
        var controls = CameraControls()
        capture.onControlsChanged = { controls = $0 }
        capture.start(device) { startError = $0 }

        var result: [String: Any] = [:]
        let deadline = Date().addingTimeInterval(12)
        var gotFrames = false
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            if first.wait(timeout: .now()) == .success {
                gotFrames = true
                break
            }
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))  // let the controls report arrive
        if let startError { result["error"] = startError.localizedDescription }
        result["format"] = controls.formatDescription
        result["canPickFocusPoint"] = controls.supportsFocusPoint
        result["canLockFocus"] = controls.supportsFocusLock
        result["canLockExposure"] = controls.supportsExposureLock
        result["canLockWhiteBalance"] = controls.supportsWhiteBalanceLock
        result["effectWarnings"] = controls.effectWarnings

        if gotFrames, let buffer = capture.latestFrame {
            let frame = MXVFrame(pixelBuffer: buffer)
            let quality = engine.runTool("quality", frame: frame, roi: .null, numbers: [:], strings: [:], pattern: nil, mmPerPixel: 0, colors: [])
            result["frameWidth"] = frame.size.width
            result["frameHeight"] = frame.size.height
            result["framesPerSecond"] = capture.framesPerSecond
            result["quality"] = Dictionary(uniqueKeysWithValues: quality.measures.map { ($0.name, $0.value) })
            if let snapshots, let data = frame.pngData(in: .null) {
                let safe = cameraName.replacingOccurrences(of: "/", with: "-")
                try? data.write(to: URL(fileURLWithPath: snapshots).appendingPathComponent("\(safe).png"))
            }
        } else {
            result["noFrames"] = true
        }
        capture.stop()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        return result
    }
}
