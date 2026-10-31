import CoreGraphics
import CoreImage
import Foundation

/// The decisions a person relies on but can't easily provoke at the bench: which camera wins, what happens when
/// one disappears, and when a result must not pass. Runs with --self-test; Tests/run.sh runs it too.
enum SelfTest {
    private static var failures = 0
    private static var checks = 0

    private static func check(_ condition: Bool, _ message: @autoclosure () -> String) {
        checks += 1
        if !condition {
            failures += 1
            print("  FAILED: \(message())")
        }
    }

    static func run(modelsDirectory: String) -> Int32 {
        testTiers()
        testFailover()
        testFormats()
        testVerdicts(modelsDirectory: modelsDirectory)
        testJobFiles()
        testQuickHelp(modelsDirectory: modelsDirectory)
        testCodes(modelsDirectory: modelsDirectory)
        testContourExport()
        testColorTools(modelsDirectory: modelsDirectory)
        print("\(checks) checks, \(failures) failed")
        return failures == 0 ? 0 : 1
    }

    private static func camera(_ id: String, _ tier: CameraTier, deskView: Bool = false, suspended: Bool = false) -> CameraInfo {
        CameraInfo(id: id, name: id, model: id, tier: tier, isDeskView: deskView, isSuspended: suspended)
    }

    private static func testTiers() {
        // As this Mac's real cameras report themselves. Without the Continuity key an iPhone shows as plain external.
        func tier(continuity: Bool = false, desk: Bool = false, builtIn: Bool = false, usb: Bool = false, _ model: String) -> CameraTier {
            CameraCatalog.tier(isContinuity: continuity, isDeskView: desk, isBuiltIn: builtIn, isUSB: usb, model: model)
        }
        check(tier(continuity: true, "iPhone12,5") == .iPhone, "Continuity iPhone")
        check(tier("iPhone12,5") == .iPhone, "iPhone reported as plain external")
        check(tier(desk: true, "iPhone12,5") == .iPhone, "iPhone Desk View")
        check(tier(desk: true, "MacBook Pro Desk View Camera") == .builtIn, "MacBook Desk View")
        check(tier(usb: true, "UVC Camera VendorID_1443 ProductID_37681") == .usb, "USB web camera")
        check(tier(builtIn: true, "MacBook Pro Camera") == .builtIn, "MacBook camera")
        check(tier("OBS Virtual Camera") == .other, "a virtual camera must rank below the MacBook's")
    }

    private static func testFailover() {
        let iPhone = camera("iphone", .iPhone)
        let usb = camera("usb", .usb)
        let builtIn = camera("mac", .builtIn)
        let macDesk = camera("macdesk", .builtIn, deskView: true)
        let phoneDesk = camera("phonedesk", .iPhone, deskView: true)
        let virtual = camera("virtual", .other)
        func choice(_ cameras: [CameraInfo], pinned: String? = nil, stalled: Set<String> = []) -> String? {
            CameraCatalog.choose(from: CameraCatalog.inRankOrder(cameras), pinned: pinned, excluding: stalled)?.id
        }

        check(choice([iPhone, phoneDesk, usb, builtIn, macDesk, virtual]) == "iphone", "the iPhone comes first")
        check(choice([phoneDesk, usb, builtIn, macDesk]) == "usb", "no iPhone: USB, not the iPhone's Desk View")
        check(choice([phoneDesk, macDesk, builtIn]) == "mac", "no USB: the MacBook camera, not a Desk View")
        check(choice([phoneDesk, macDesk]) == nil, "Desk View is never chosen automatically")
        check(choice([virtual, builtIn]) == "mac", "the MacBook camera outranks a virtual camera")
        check(choice([virtual]) == "virtual", "a virtual camera is the last resort")
        check(choice([]) == nil, "no cameras at all")

        let locked = camera("iphone", .iPhone, suspended: true)
        check(choice([locked, usb, builtIn]) == "usb", "a suspended iPhone falls over to USB")
        check(choice([iPhone, usb, builtIn], stalled: ["iphone"]) == "usb", "a silent iPhone falls over to USB")
        check(choice([iPhone, usb, builtIn], stalled: ["iphone", "usb"]) == "mac", "both silent: the MacBook camera")

        check(choice([iPhone, usb, builtIn], pinned: "mac") == "mac", "a pinned camera overrides the order")
        check(choice([iPhone, phoneDesk], pinned: "phonedesk") == "phonedesk", "Desk View can be picked by hand")
        check(choice([iPhone, usb], pinned: "gone") == "iphone", "a pinned camera that's gone falls back to the order")
        check(choice([locked, usb], pinned: "iphone") == "usb", "a suspended pinned camera falls back to the order")
    }

    private static func testFormats() {
        typealias Option = CameraCatalog.FormatOption
        func best(_ options: [(Int32, Int32, Double)]) -> String? {
            let list = options.map { Option(width: $0.0, height: $0.1, maxRate: $0.2) }
            return CameraCatalog.bestOption(in: list).map { "\(list[$0].width)x\(list[$0].height)@\(Int(list[$0].maxRate))" }
        }
        // These are the lists this Mac's cameras really offer.
        let iPhone = [(640, 480, 30.0), (640, 480, 60), (1280, 720, 30), (1280, 720, 60), (1920, 1080, 30), (1920, 1080, 60), (1920, 1440, 30), (1920, 1440, 60)] as [(Int32, Int32, Double)]
        check(best(iPhone) == "1920x1440@30", "iPhone: \(best(iPhone) ?? "none")")
        let macBook = [(640, 480, 30.0), (1280, 720, 30), (1760, 1328, 30), (1328, 1760, 30), (1552, 1552, 30), (1920, 1080, 30), (1080, 1920, 30)] as [(Int32, Int32, Double)]
        check(best(macBook) == "1760x1328@30", "MacBook: \(best(macBook) ?? "none")")
        let usb = [(640, 360, 30.0), (1280, 720, 30), (1280, 720, 5), (1920, 1080, 30), (1920, 1080, 5)] as [(Int32, Int32, Double)]
        check(best(usb) == "1920x1080@30", "USB: \(best(usb) ?? "none")")
        check(best([(4000, 3000, 10), (1920, 1080, 30)]) == "1920x1080@30", "video rate outranks size")
        check(best([(4000, 3000, 10)]) == "4000x3000@10", "a slow format is still better than none")
        check(best([]) == nil, "no formats")
    }

    private static func testVerdicts(modelsDirectory: String) {
        // A white image with one 100 × 100 black square.
        let width = 400, height = 300
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 150, y: 100, width: 100, height: 100))
        let frame = MXVFrame(cgImage: context.makeImage()!)!

        let runner = InspectionRunner(modelsDirectory: modelsDirectory)
        func report(_ tool: ToolConfig, calibrations: [String: Double] = [:]) -> ToolReport {
            var job = Job()
            job.tools = [tool]
            job.calibrations = calibrations
            return runner.run(job: job, frame: frame, source: "camera", sourceName: "camera").tools[0]
        }
        func blobs(_ limits: [Limit]) -> ToolConfig {
            var tool = ToolConfig(kind: .blobs)
            tool.limits = limits
            return tool
        }

        check(report(blobs([])).verdict == .info, "no limits has nothing to judge")
        check(report(blobs([Limit(measure: "count", minimum: 1, maximum: 1)])).verdict == .pass, "count within limits")
        check(report(blobs([Limit(measure: "count", minimum: 2)])).verdict == .fail, "count below the minimum")
        check(report(blobs([Limit(measure: "count", maximum: 0)])).verdict == .fail, "count above the maximum")

        var nothing = ToolConfig(kind: .blobs)
        nothing.numbers["minArea"] = 1_000_000
        nothing.limits = [Limit(measure: "largest_length", maximum: 5)]
        check(report(nothing).verdict == .fail, "a limit on something unmeasurable must fail, not pass")

        // Failing over to an uncalibrated camera must not compare pixels with a limit set in millimetres.
        let inMM = [Limit(measure: "largest_length", minimum: 9.9, maximum: 10.1)]
        check(report(blobs(inMM), calibrations: ["camera": 0.1]).verdict == .pass, "100 px at 0.1 mm per pixel is 10 mm")
        check(report(blobs(inMM), calibrations: ["camera": 0.2]).verdict == .fail, "100 px at 0.2 mm per pixel is 20 mm")
        let wide = [Limit(measure: "largest_length", minimum: 1, maximum: 1000)]
        let uncalibrated = report(blobs(wide), calibrations: ["another camera": 0.1])
        check(uncalibrated.verdict == .fail, "another camera's scale must not apply here")
        check(uncalibrated.reasons.first?.contains("calibrated") == true, "the reason should name calibration")
        check(report(blobs(wide)).verdict == .pass, "a job with no calibration at all can use pixels")
        let counted = [Limit(measure: "count", minimum: 1)]
        check(report(blobs(counted), calibrations: ["another camera": 0.1]).verdict == .pass, "a count has no units to get wrong")

        var region = blobs([Limit(measure: "count", minimum: 1)])
        region.roi = CGRect(x: 0, y: 0, width: 0.2, height: 0.2)
        check(report(region).verdict == .fail, "the region limits what's seen")
        region.roi = CGRect(x: 0.3, y: 0.25, width: 0.4, height: 0.5)
        region.numbers["dropBorder"] = 0
        check(report(region).verdict == .pass, "a region around the square finds it")

        var disabled = blobs([Limit(measure: "count", minimum: 99)])
        disabled.enabled = false
        var job = Job()
        job.tools = [disabled]
        let result = runner.run(job: job, frame: frame, source: "camera", sourceName: "camera")
        check(result.tools.isEmpty && result.verdict == .info, "a disabled tool doesn't run")

        var regex = ToolConfig(kind: .code)
        regex.limits = []
        regex.expectedText = "("
        check(report(regex).verdict == .fail, "an invalid regular expression must fail, not pass")
        var unread = ToolConfig(kind: .code)
        unread.expectedText = "ABC"
        check(report(unread).verdict == .fail, "expected text with nothing read")

        var untaught = ToolConfig(kind: .pattern)
        untaught.limits = []
        check(report(untaught).verdict == .fail, "an untaught pattern is an error")
    }

    private static func testQuickHelp(modelsDirectory: String) {
        for kind in ToolKind.allCases {
            for spec in kind.params {
                check(AppQuickHelp.paramDetail(key: spec.key, kind: kind) != nil, "Quick Help has nothing for \(kind.rawValue) setting \(spec.key)")
            }
            for measure in kind.measures {
                check(AppQuickHelp.measureDetail(measure, kind: kind) != nil, "Quick Help has nothing for \(kind.rawValue) measure \(measure)")
            }
        }
        for tier in CameraTier.allCases {
            check(!AppQuickHelp.missingCamera(tier).detail.isEmpty, "Quick Help has nothing for a missing \(tier.title)")
        }

        // A white image with one black square, and what the pointer finds over it.
        let context = CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 150, y: 100, width: 100, height: 100))
        let frame = MXVFrame(cgImage: context.makeImage()!)!

        var job = Job()
        var quality = ToolConfig(kind: .quality)
        quality.name = "Whole Image Check"
        var blobs = ToolConfig(kind: .blobs)
        blobs.name = "Square Finder"
        var caliper = ToolConfig(kind: .caliper)
        caliper.name = "Width Check"
        caliper.limits = [Limit(measure: "distance", maximum: 5)]
        job.tools = [quality, blobs, caliper]
        let report = InspectionRunner(modelsDirectory: modelsDirectory).run(job: job, frame: frame, source: "camera", sourceName: "camera")

        let onSpan = AppQuickHelp.found(at: CGPoint(x: 200, y: 150), in: report, tolerance: 3)
        check(onSpan?.title == "100.0 px", "the caliper's dimension line runs through the middle: \(onSpan?.title ?? "nothing")")
        let inSquare = AppQuickHelp.found(at: CGPoint(x: 200, y: 130), in: report, tolerance: 3)
        check(inSquare?.detail.contains("Square Finder") == true || inSquare?.title.contains("Square Finder") == true,
              "the smallest thing under the pointer should win: \(inSquare?.title ?? "nothing")")
        let inCorner = AppQuickHelp.found(at: CGPoint(x: 20, y: 20), in: report, tolerance: 3)
        check(inCorner?.detail.contains("Whole Image Check") == true, "the whole-image rectangle: \(inCorner?.title ?? "nothing")")
        let onEdge = AppQuickHelp.found(at: CGPoint(x: 150, y: 20), in: report, tolerance: 3)
        check(onEdge?.detail.contains("Width Check") == true, "a line under the pointer: \(onEdge?.title ?? "nothing")")
        check(onEdge?.detail.contains("above 5") == true, "a failing tool should say why: \(onEdge?.detail ?? "nothing")")

        var calibrated = AppQuickHelp.image(pixel: CGPoint(x: 100, y: 50), imageSize: CGSize(width: 400, height: 300), isDrawing: false,
                                            sourceName: "Camera", isFrozen: false, canFocus: true, scale: 0.5)
        check(calibrated.detail.contains("Pixel 100, 50") && calibrated.detail.contains("50.00, 25.00 mm"), calibrated.detail)
        check(calibrated.detail.contains("Click to focus"), "focusing should be mentioned only where it works")
        calibrated = AppQuickHelp.image(pixel: nil, imageSize: .zero, isDrawing: false, sourceName: nil, isFrozen: false, canFocus: false, scale: nil)
        check(calibrated.title == "Image" && !calibrated.detail.contains("Click"), "no image yet: \(calibrated.detail)")
    }

    /// "MXV-12345" as a 14 x 14 Data Matrix, from Tests/make_fixtures.py. Core Image can't make these.
    private static let dataMatrix = [
        "10101010101010",
        "10111110101001",
        "10111011000100",
        "10010010000001",
        "11101100010010",
        "10100001000101",
        "10100001100100",
        "11011001101011",
        "11001110110000",
        "11110111100111",
        "11011001100000",
        "11001100111011",
        "11000100100010",
        "11111111111111",
    ]

    private static func testCodes(modelsDirectory: String) {
        let runner = InspectionRunner(modelsDirectory: modelsDirectory)
        let core = CIContext()
        let message = Data("MXV-12345".utf8)
        let frameSize = CGSize(width: 1920, height: 1440)

        func generated(_ filter: String, _ parameters: [String: Any], scale: CGFloat) -> CGImage? {
            guard let output = CIFilter(name: filter, parameters: parameters)?.outputImage else { return nil }
            let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            return core.createCGImage(scaled, from: scaled.extent)
        }
        /// Black modules on white, with a quiet zone.
        func modules(_ rows: [String], scale: Int) -> CGImage {
            let quiet = scale * 4
            let width = rows[0].count * scale + quiet * 2, height = rows.count * scale + quiet * 2
            let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            for (y, row) in rows.enumerated() {
                for (x, cell) in row.enumerated() where cell == "1" {
                    context.fill(CGRect(x: quiet + x * scale, y: height - quiet - (y + 1) * scale, width: scale, height: scale))
                }
            }
            return context.makeImage()!
        }
        func ean13Rows(_ digits: String) -> [String] {
            let values = digits.map { Int(String($0))! }
            let left = ["0001101", "0011001", "0010011", "0111101", "0100011", "0110001", "0101111", "0111011", "0110111", "0001011"]
            let even = ["0100111", "0110011", "0011011", "0100001", "0011101", "0111001", "0000101", "0010001", "0001001", "0010111"]
            let right = ["1110010", "1100110", "1101100", "1000010", "1011100", "1001110", "1010000", "1000100", "1001000", "1110100"]
            let parity = ["LLLLLL", "LLGLGG", "LLGGLG", "LLGGGL", "LGLLGG", "LGGLLG", "LGGGLL", "LGLGLG", "LGLGGL", "LGGLGL"]
            var bits = "101"
            for (i, side) in parity[values[0]].enumerated() { bits += (side == "L" ? left : even)[values[i + 1]] }
            bits += "01010"
            for i in 7..<13 { bits += right[values[i]] }
            bits += "101"
            return Array(repeating: bits, count: 50)
        }
        /// The code in the middle of a close-up frame, turned, slightly soft.
        func frame(_ code: CGImage, degrees: CGFloat = 0, at center: CGPoint? = nil) -> MXVFrame {
            let context = CGContext(data: nil, width: Int(frameSize.width), height: Int(frameSize.height), bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(gray: 0.85, alpha: 1))
            context.fill(CGRect(origin: .zero, size: frameSize))
            let middle = center ?? CGPoint(x: frameSize.width / 2, y: frameSize.height / 2)
            context.translateBy(x: middle.x, y: frameSize.height - middle.y)
            context.rotate(by: degrees * .pi / 180)
            context.draw(code, in: CGRect(x: -CGFloat(code.width) / 2, y: -CGFloat(code.height) / 2, width: CGFloat(code.width), height: CGFloat(code.height)))
            return MXVFrame(cgImage: context.makeImage()!)!
        }
        func read(_ image: MXVFrame, codes: Double = 0, roi: CGRect? = nil) -> ToolReport {
            var tool = ToolConfig(kind: .code)
            tool.numbers["codes"] = codes
            tool.roi = roi
            var job = Job()
            job.tools = [tool]
            return runner.run(job: job, frame: image, source: "camera", sourceName: "camera").tools[0]
        }
        func expect(_ name: String, _ code: CGImage?, text: String, center: CGPoint = CGPoint(x: 960, y: 720)) {
            guard let code else { return check(false, "\(name): couldn't make the code") }
            for degrees in [0, 25, 90, 180] as [CGFloat] where degrees == 0 || max(code.width, code.height) < 1300 {
                let result = read(frame(code, degrees: degrees, at: center))
                check(result.output.texts.contains { $0.contains(text) }, "\(name) \(code.width) x \(code.height) at \(degrees)°: read \(result.output.texts) \(result.output.error ?? "")")
                if let points = result.output.overlays.first?.points.map(\.pointValue), points.count == 4 {
                    let x = points.map(\.x).reduce(0, +) / 4, y = points.map(\.y).reduce(0, +) / 4
                    check(hypot(x - center.x, y - center.y) < 60, "\(name) at \(degrees)°: the outline is centered on \(x), \(y)")
                }
            }
        }

        let inputs: [String: Any] = ["inputMessage": message]
        for scale in [4, 8, 14] as [CGFloat] {
            expect("Code 128", generated("CICode128BarcodeGenerator", ["inputMessage": message, "inputQuietSpace": 10.0], scale: min(scale, 8)), text: "MXV-12345")
            expect("PDF417", generated("CIPDF417BarcodeGenerator", inputs, scale: scale), text: "MXV-12345")
            expect("Aztec", generated("CIAztecCodeGenerator", inputs, scale: scale), text: "MXV-12345")
        }
        // The sizes where OpenCV's QR and barcode readers needed help, up to a code filling most of a close-up frame.
        for scale in [4, 8, 10, 16, 32, 48] as [CGFloat] {
            expect("QR", generated("CIQRCodeGenerator", inputs, scale: scale), text: "MXV-12345")
        }
        for module in [2, 3, 4, 5, 6, 8, 10, 12, 14] {
            expect("EAN-13 at module \(module)", modules(ean13Rows("5901234123457"), scale: module), text: "5901234123457")
        }
        expect("UPC-A", modules(ean13Rows("0036000291452"), scale: 5), text: "36000291452")
        for scale in [6, 10, 20, 40, 70] {
            expect("Data Matrix", modules(dataMatrix, scale: scale), text: "MXV-12345")
        }

        // A control: the same Data Matrix with a block of its data flipped, past what error correction can repair.
        // If this read, the test above wouldn't prove anything.
        let damaged = dataMatrix.enumerated().map { y, row in
            String(row.enumerated().map { x, cell in
                (1...12).contains(x) && (1...12).contains(y) && (x + y) % 2 == 0 ? (cell == "1" ? "0" : "1") : cell
            })
        }
        check(!read(frame(modules(damaged, scale: 20))).output.texts.contains("MXV-12345"), "a damaged Data Matrix shouldn't read")

        // The Look For setting, a region, more than one code, and nothing to read.
        let bars = generated("CICode128BarcodeGenerator", ["inputMessage": message, "inputQuietSpace": 10.0], scale: 4)!
        let qrCode = generated("CIQRCodeGenerator", ["inputMessage": Data("OTHER-777".utf8)], scale: 10)!
        check(read(frame(bars), codes: 1).output.texts.isEmpty, "QR only shouldn't read a Code 128")
        check(read(frame(bars), codes: 2).output.texts == ["MXV-12345"], "barcodes should read a Code 128")
        check(read(frame(bars), codes: 3).output.texts.isEmpty, "the other 2D codes shouldn't include Code 128")
        check(read(frame(modules(dataMatrix, scale: 12)), codes: 3).output.texts == ["MXV-12345"], "the other 2D codes should include Data Matrix")
        check(read(frame(qrCode), codes: 2).output.texts.isEmpty, "barcodes shouldn't read a QR code")
        check(read(frame(qrCode), roi: CGRect(x: 0, y: 0, width: 0.2, height: 0.2)).output.texts.isEmpty, "a code outside the region")
        let inRegion = read(frame(qrCode, at: CGPoint(x: 1500, y: 1100)), roi: CGRect(x: 0.6, y: 0.6, width: 0.4, height: 0.4))
        check(inRegion.output.texts == ["OTHER-777"], "a code inside the region: \(inRegion.output.texts)")
        if let points = inRegion.output.overlays.first?.points.map(\.pointValue), points.count == 4 {
            let x = points.map(\.x).reduce(0, +) / 4, y = points.map(\.y).reduce(0, +) / 4
            check(hypot(x - 1500, y - 1100) < 30, "a region's outline should be in full-image coordinates: \(x), \(y)")
        }
        let blank = read(frame(modules(["0"], scale: 1)))
        check(blank.output.error == nil && blank.output.texts.isEmpty, "nothing to read: \(blank.output.texts)")
        check(read(frame(bars), roi: CGRect(x: 2, y: 2, width: 0.1, height: 0.1)).output.error != nil, "a region outside the image")

        let two = CGContext(data: nil, width: 1600, height: 900, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        two.setFillColor(CGColor(gray: 1, alpha: 1))
        two.fill(CGRect(x: 0, y: 0, width: 1600, height: 900))
        two.draw(bars, in: CGRect(x: 60, y: 300, width: bars.width, height: bars.height))
        two.draw(qrCode, in: CGRect(x: 1000, y: 300, width: qrCode.width, height: qrCode.height))
        let both = read(MXVFrame(cgImage: two.makeImage()!)!)
        check(Set(both.output.texts) == ["MXV-12345", "OTHER-777"], "two codes in view: \(both.output.texts)")
        check(both.output.measures.first { $0.name == "count" }?.value == 2, "two codes should count as two")
    }

    private static func testColorTools(modelsDirectory: String) {
        // A red square and a blue one on grey: teach through the bridge, keep through a job file, and judge through the runner.
        let context = CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        context.setFillColor(CGColor(colorSpace: space, components: [0.85, 0.12, 0.12, 1])!)
        context.fill(CGRect(x: 40, y: 100, width: 100, height: 100))
        context.setFillColor(CGColor(colorSpace: space, components: [0.12, 0.2, 0.85, 1])!)
        context.fill(CGRect(x: 240, y: 100, width: 100, height: 100))
        let frame = MXVFrame(cgImage: context.makeImage()!)!
        let redRegion = CGRect(x: 60, y: 120, width: 60, height: 60), blueRegion = CGRect(x: 260, y: 120, width: 60, height: 60)
        let red = ColorReference(MXVEngine.trainColor(in: frame, roi: redRegion, numbers: [:]), name: "red")
        let blue = ColorReference(MXVEngine.trainColor(in: frame, roi: blueRegion, numbers: [:]), name: "blue")
        check(abs(red.meanRGB[0] - 217) < 3 && abs(red.meanRGB[2] - 31) < 3, "a taught red: \(red.meanRGB)")
        check(abs(blue.meanRGB[2] - 217) < 3, "a taught blue: \(blue.meanRGB)")

        // Everything must survive being saved, since tolerances and volumes are the job.
        var saved = ToolConfig(kind: .colorSegmenter)
        saved.colors = [red, blue]
        saved.colors[0].softness = 12
        if let data = try? JSONEncoder().encode(saved), let back = try? JSONDecoder().decode(ToolConfig.self, from: data) {
            check(back == saved, "a color tool should survive being saved")
        } else {
            check(false, "a color tool couldn't be saved")
        }

        let runner = InspectionRunner(modelsDirectory: modelsDirectory)
        func run(_ kind: ToolKind, roi: CGRect? = nil, expected: String = "", limits: [Limit] = [], numbers: [String: Double] = [:]) -> ToolReport {
            var tool = ToolConfig(kind: kind)
            tool.colors = [red, blue]
            tool.roi = roi
            tool.expectedText = expected
            tool.limits = limits
            tool.numbers = numbers
            var job = Job()
            job.tools = [tool]
            return runner.run(job: job, frame: frame, source: "camera", sourceName: "camera").tools[0]
        }
        func value(_ report: ToolReport, _ name: String) -> Double? { report.output.measures.first { $0.name == name }?.value }

        let segmenter = run(.colorSegmenter, limits: [Limit(measure: "count", minimum: 2, maximum: 2)])
        check(segmenter.verdict == .pass, "the segmenter should find both squares: \(segmenter.reasons)")
        check(abs((value(segmenter, "matched_pixels") ?? 0) - 20000) < 500, "and their pixels: \(value(segmenter, "matched_pixels") ?? -1)")
        let extractor = run(.colorExtractor)
        check(abs((value(extractor, "matched_pixels") ?? 0) - 20000) < 500, "the extractor's pixels: \(value(extractor, "matched_pixels") ?? -1)")

        // Regions run 0 to 1, and the expected text checks which color came back.
        let leftSide = CGRect(x: 0.15, y: 0.4, width: 0.15, height: 0.2), rightSide = CGRect(x: 0.65, y: 0.4, width: 0.15, height: 0.2)
        for kind in [ToolKind.colorMatch, .compositeColorMatch] {
            check(run(kind, roi: leftSide, expected: "^red$").verdict == .pass, "\(kind.title) on the red square")
            check(run(kind, roi: rightSide, expected: "^blue$").verdict == .pass, "\(kind.title) on the blue square")
            check(run(kind, roi: rightSide, expected: "^red$").verdict == .fail, "\(kind.title) should fail when it's not the expected color")
        }
        let cone = run(.colorMatch, roi: rightSide, numbers: ["colorSpace": 1])
        check(value(cone, "best_index") == 2 && (value(cone, "score") ?? 0) > 0.95, "HSI matching: \(value(cone, "score") ?? -1)")

        // Nothing taught is a failure to report, not a pass.
        var empty = ToolConfig(kind: .colorMatch)
        empty.colors = []
        var emptyJob = Job()
        emptyJob.tools = [empty]
        check(runner.run(job: emptyJob, frame: frame, source: "camera", sourceName: "camera").tools[0].verdict == .fail, "a color tool with no colors should fail")
        check(ToolKind.allCases.filter(\.usesColors).count == 4, "four color tools")
    }

    private static func testContourExport() {
        // A dark 200 x 100 rectangle with a hole, on a light 400 x 300 image, so every number is known.
        let context = CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 100, y: 100, width: 200, height: 100))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fillEllipse(in: CGRect(x: 180, y: 130, width: 40, height: 40))
        let frame = MXVFrame(cgImage: context.makeImage()!)!

        let tool = ToolConfig(kind: .contours)
        let contours = ContourExport.extract(tool: tool, frame: frame)
        check(contours.count == 2, "a rectangle with a hole should give two outlines: \(contours.count)")
        check(contours.filter(\.hole).count == 1, "one of them should be a hole")
        check(contours.allSatisfy(\.closed), "both should be closed")

        var region = ToolConfig(kind: .contours)
        region.roi = CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
        region.numbers["polarity"] = 1
        let inRegion = ContourExport.extract(tool: region, frame: frame)
        check(inRegion.count == 1, "just the hole, inside its region: \(inRegion.count)")
        if let point = inRegion.first?.points.first?.pointValue {
            check(point.x > 150 && point.x < 250 && point.y > 100 && point.y < 200, "exported points should be in full-image coordinates: \(point)")
        }

        let size = frame.size
        let dxf = ContourExport.dxf(contours, imageSize: size, mmPerPixel: 0.5)
        check(dxf.hasPrefix("0\nSECTION\n2\nHEADER") && dxf.hasSuffix("0\nEOF\n"), "DXF should start and end as the format requires")
        check(dxf.components(separatedBy: "\nPOLYLINE\n").count - 1 == 2, "DXF should have one polyline per outline")
        check(dxf.contains("\nHOLE\n") && dxf.contains("\nOUTLINE\n"), "DXF should keep holes on their own layer")

        // In a DXF, y points up and the units are mm, so the rectangle's top edge, at image y 100, sits at (300 - 100) * 0.5.
        let tokens = dxf.components(separatedBy: "\n")
        var ys: [Double] = []
        var xs: [Double] = []
        var index = 0
        while index + 1 < tokens.count {
            if tokens[index] == "VERTEX" {
                xs.append(Double(tokens[index + 4]) ?? .nan)
                ys.append(Double(tokens[index + 6]) ?? .nan)
            }
            index += 1
        }
        check(abs((ys.max() ?? 0) - 100) < 1, "DXF y should be flipped and in mm: top at \(ys.max() ?? 0)")
        check(abs((xs.max() ?? 0) - 150) < 1, "DXF x should be in mm: right edge at \(xs.max() ?? 0)")

        let svgPixels = ContourExport.svg(contours, imageSize: size, mmPerPixel: nil)
        check(svgPixels.contains("viewBox=\"0 0 400.0000 300.0000\"") && !svgPixels.contains("mm\""), "SVG in pixels without a scale")
        check(svgPixels.components(separatedBy: "<polygon").count - 1 == 2, "SVG should have one polygon per closed outline")
        check(ContourExport.svg(contours, imageSize: size, mmPerPixel: 0.5).contains("width=\"200.0000mm\""), "SVG should say mm with a scale")

        let csvRows = ContourExport.csv(contours, mmPerPixel: nil).split(separator: "\n")
        check(csvRows.first == "contour,kind,point,x_px,y_px", "CSV header: \(csvRows.first ?? "")")
        check(csvRows.count - 1 == contours.reduce(0) { $0 + $1.points.count }, "CSV should have a row per point")
        check(ContourExport.csv(contours, mmPerPixel: 0.5).hasPrefix("contour,kind,point,x_mm,y_mm"), "CSV should say mm with a scale")

        // Limits list only what the chosen shape gives, or they could ask for a measure that never arrives.
        var fit = ToolConfig(kind: .shapeFit)
        check(fit.relevantMeasures.contains("diameter") && !fit.relevantMeasures.contains("major_axis"), "a circle by default")
        fit.numbers["shape"] = 2
        check(fit.relevantMeasures.contains("major_axis") && !fit.relevantMeasures.contains("diameter"), "an ellipse")
        check(ToolConfig(kind: .shapeFit).limits.first?.measure == "found", "a shape fit should fail if it finds nothing")
    }

    private static func testJobFiles() {
        var job = Job()
        job.name = "Round trip"
        var tool = ToolConfig(kind: .ocr)
        tool.roi = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        tool.numbers["maxSide"] = 640
        tool.strings["x"] = "y"
        tool.expectedText = "^A"
        tool.patternPNG = Data([1, 2, 3])
        job.tools = [tool]
        job.calibrations = ["camera": 0.05]
        job.saveFailureImages = true
        if let data = try? JSONEncoder().encode(job), let back = try? JSONDecoder().decode(Job.self, from: data) {
            check(back == job, "a job survives saving and opening")
        } else {
            check(false, "a job couldn't be saved or opened")
        }

        let sparse = Data(#"{"tools":[{"kind":"caliper"}]}"#.utf8)
        let decoded = try? JSONDecoder().decode(Job.self, from: sparse)
        check(decoded?.tools.first?.kind == .caliper && decoded?.tools.first?.enabled == true, "a job file with missing fields still opens")
        check((try? JSONDecoder().decode(Job.self, from: Data(#"{"tools":[{"kind":"nonsense"}]}"#.utf8))) == nil, "an unknown tool is refused")
    }
}
