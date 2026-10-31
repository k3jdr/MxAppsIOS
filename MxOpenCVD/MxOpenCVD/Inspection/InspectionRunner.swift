import CoreVideo
import Foundation

enum Verdict: String {
    case pass = "PASS"
    case fail = "FAIL"
    case info = "NO CRITERIA"  // ran fine, with nothing to judge it against
}

struct ToolReport: Identifiable {
    let id: UUID
    let name: String
    let kind: ToolKind
    let verdict: Verdict
    let reasons: [String]
    let output: MXVToolOutput
}

struct InspectionReport: Identifiable {
    let id = UUID()
    let date = Date()
    let source: String
    let verdict: Verdict
    let tools: [ToolReport]
    let totalMs: Double
    let imageSize: CGSize
    let frame: MXVFrame
}

enum Evaluator {
    /// Judges one tool's output against its limits and expected text.
    static func verdict(for tool: ToolConfig, output: MXVToolOutput, jobIsCalibrated: Bool, sourceIsCalibrated: Bool) -> (Verdict, [String]) {
        if let error = output.error {
            return (.fail, [error])
        }

        var reasons: [String] = []
        var judged = false
        for limit in tool.limits where limit.minimum != nil || limit.maximum != nil {
            judged = true
            guard let measure = output.measures.first(where: { $0.name == limit.measure }) else {
                // The tool found nothing to measure, as with a caliper that finds no edges.
                reasons.append("\(limit.measure) couldn't be measured")
                continue
            }
            // A limit set in millimetres against a camera with no scale would compare mm with pixels. The usual
            // way to get here is failing over to another camera, so this must fail rather than pass by luck.
            if jobIsCalibrated && !sourceIsCalibrated && measure.unit.hasPrefix("px") && !["x", "y"].contains(measure.name) {
                reasons.append("\(limit.measure) is in pixels: this camera isn't calibrated")
                continue
            }
            if let minimum = limit.minimum, measure.value < minimum {
                reasons.append("\(limit.measure) \(format(measure.value)) is below \(format(minimum))")
            }
            if let maximum = limit.maximum, measure.value > maximum {
                reasons.append("\(limit.measure) \(format(measure.value)) is above \(format(maximum))")
            }
        }

        let expected = tool.expectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !expected.isEmpty {
            judged = true
            if let regex = try? NSRegularExpression(pattern: expected) {
                let matched = output.texts.contains { text in
                    regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
                }
                if !matched {
                    let seen = output.texts.isEmpty ? "nothing" : output.texts.joined(separator: " | ")
                    reasons.append("expected “\(expected)”, read \(seen)")
                }
            } else {
                reasons.append("“\(expected)” isn't a valid regular expression")
            }
        }

        if !reasons.isEmpty { return (.fail, reasons) }
        return (judged ? .pass : .info, [])
    }

    static func overall(_ tools: [ToolReport]) -> Verdict {
        if tools.contains(where: { $0.verdict == .fail }) { return .fail }
        return tools.contains(where: { $0.verdict == .pass }) ? .pass : .info
    }

    static func format(_ value: Double) -> String {
        if value == value.rounded() && abs(value) < 1e9 { return String(Int(value)) }
        return abs(value) >= 100 ? String(format: "%.1f", value) : String(format: "%.3f", value)
    }
}

/// Runs a job on the inspection queue. The queue only ever holds the newest frame, so a slow tool such as OCR
/// lowers the inspection rate instead of building up a backlog and falling behind the camera.
final class InspectionRunner: @unchecked Sendable {
    enum Input {
        case buffer(CVPixelBuffer)
        case frame(MXVFrame)
    }

    /// Called on the main queue.
    var onReport: ((InspectionReport) -> Void)?

    private let engine: MXVEngine
    private let queue = DispatchQueue(label: "com.k3jdr.MxOpenCVD.inspect", qos: .userInitiated)
    private let lock = NSLock()
    private var job = Job()
    private var pending: (input: Input, source: String, sourceName: String)?
    private var running = false
    private var patterns: [UUID: (data: Data, frame: MXVFrame)] = [:]  // only touched while running a job

    init(modelsDirectory: String) {
        engine = MXVEngine(modelsDirectory: modelsDirectory)
    }

    func update(job: Job) {
        lock.lock()
        self.job = job
        lock.unlock()
    }

    /// source is the calibration key; sourceName is what the log shows.
    func submit(_ input: Input, source: String, sourceName: String) {
        lock.lock()
        pending = (input, source, sourceName)
        let start = !running
        if start { running = true }
        lock.unlock()
        if start {
            queue.async { [self] in drain() }
        }
    }

    private func drain() {
        while true {
            lock.lock()
            guard let next = pending else {
                running = false
                lock.unlock()
                return
            }
            pending = nil
            let job = self.job
            lock.unlock()

            let frame: MXVFrame
            switch next.input {
            case .buffer(let buffer): frame = MXVFrame(pixelBuffer: buffer)
            case .frame(let still): frame = still
            }
            let report = run(job: job, frame: frame, source: next.source, sourceName: next.sourceName)
            let deliver = onReport
            DispatchQueue.main.async { deliver?(report) }
        }
    }

    /// Synchronous, for batch mode. Don't mix with submit().
    func run(job: Job, frame: MXVFrame, source: String, sourceName: String) -> InspectionReport {
        let scale = job.calibrations[source] ?? 0
        let size = frame.size
        var reports: [ToolReport] = []
        var total = 0.0
        for tool in job.tools where tool.enabled {
            let roi: CGRect
            if let area = tool.roi {
                roi = CGRect(x: area.minX * size.width, y: area.minY * size.height,
                             width: area.width * size.width, height: area.height * size.height).integral
            } else {
                roi = .null
            }
            let output = engine.runTool(tool.kind.rawValue, frame: frame, roi: roi,
                                        numbers: tool.engineNumbers.mapValues { NSNumber(value: $0) },
                                        strings: tool.strings, pattern: pattern(for: tool), mmPerPixel: scale,
                                        colors: tool.colors.map(\.bridged))
            total += output.elapsedMs
            let (verdict, reasons) = Evaluator.verdict(for: tool, output: output, jobIsCalibrated: !job.calibrations.isEmpty, sourceIsCalibrated: scale > 0)
            reports.append(ToolReport(id: tool.id, name: tool.name, kind: tool.kind, verdict: verdict, reasons: reasons, output: output))
        }
        return InspectionReport(source: sourceName, verdict: Evaluator.overall(reports), tools: reports, totalMs: total, imageSize: size, frame: frame)
    }

    private func pattern(for tool: ToolConfig) -> MXVFrame? {
        guard let data = tool.patternPNG else { return nil }
        if let cached = patterns[tool.id], cached.data == data { return cached.frame }
        guard let frame = MXVFrame(pngData: data) else { return nil }
        patterns[tool.id] = (data, frame)
        return frame
    }
}
