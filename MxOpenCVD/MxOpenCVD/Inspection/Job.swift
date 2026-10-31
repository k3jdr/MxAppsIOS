import CoreGraphics
import Foundation

/// A saved inspection: the tools to run, in order, and the scale for each camera.
struct Job: Codable, Equatable {
    var name = "Untitled Job"
    var tools: [ToolConfig] = []
    /// mm per pixel by camera ID (Job.stillSource for opened images). Scale depends on the camera and its
    /// distance from the part, so one camera's calibration must not apply to another's frames.
    var calibrations: [String: Double] = [:]
    var saveFailureImages = false

    static let stillSource = "still"

    init() {}

    /// Any field can be missing, so a job file saved by an older version still opens.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? name
        tools = try values.decodeIfPresent([ToolConfig].self, forKey: .tools) ?? []
        calibrations = try values.decodeIfPresent([String: Double].self, forKey: .calibrations) ?? [:]
        saveFailureImages = try values.decodeIfPresent(Bool.self, forKey: .saveFailureImages) ?? false
    }
}

/// A color trained from a region. What it's used for depends on the tool: a range, a volume, a reference or a distribution.
struct ColorReference: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var meanRGB: [Double], meanHSI: [Double], spreadRGB: [Double], spreadHSI: [Double]
    var lowRGB: [Double], highRGB: [Double], lowHSI: [Double], highHSI: [Double]
    var softness = 0.0, dilation = 0.0, matteLow = 0.0, matteHigh = 0.0, highlight = 0.0
    var voxels: Data, histogram: Data

    init(_ trained: MXVColorReference, name: String) {
        self.name = name
        meanRGB = trained.meanRGB.map(\.doubleValue)
        meanHSI = trained.meanHSI.map(\.doubleValue)
        spreadRGB = trained.spreadRGB.map(\.doubleValue)
        spreadHSI = trained.spreadHSI.map(\.doubleValue)
        lowRGB = trained.lowRGB.map(\.doubleValue)
        highRGB = trained.highRGB.map(\.doubleValue)
        lowHSI = trained.lowHSI.map(\.doubleValue)
        highHSI = trained.highHSI.map(\.doubleValue)
        softness = trained.softness
        dilation = trained.dilation
        matteLow = trained.matteLow
        matteHigh = trained.matteHigh
        highlight = trained.highlight
        voxels = trained.voxels
        histogram = trained.histogram
    }

    var bridged: MXVColorReference {
        let object = MXVColorReference()
        object.name = name
        object.meanRGB = meanRGB.map { NSNumber(value: $0) }
        object.meanHSI = meanHSI.map { NSNumber(value: $0) }
        object.spreadRGB = spreadRGB.map { NSNumber(value: $0) }
        object.spreadHSI = spreadHSI.map { NSNumber(value: $0) }
        object.lowRGB = lowRGB.map { NSNumber(value: $0) }
        object.highRGB = highRGB.map { NSNumber(value: $0) }
        object.lowHSI = lowHSI.map { NSNumber(value: $0) }
        object.highHSI = highHSI.map { NSNumber(value: $0) }
        object.softness = softness
        object.dilation = dilation
        object.matteLow = matteLow
        object.matteHigh = matteHigh
        object.highlight = highlight
        object.voxels = voxels
        object.histogram = histogram
        return object
    }
}

struct Limit: Codable, Equatable {
    var measure: String
    var minimum: Double?
    var maximum: Double?
}

struct ToolConfig: Codable, Equatable, Identifiable {
    var id = UUID()
    var kind: ToolKind
    var name: String
    var enabled = true
    /// 0...1 of the image's width and height, so a region survives a change of camera or resolution.
    var roi: CGRect?
    var numbers: [String: Double] = [:]
    var strings: [String: String] = [:]
    var limits: [Limit] = []
    /// A regular expression the text this tool reads must contain.
    var expectedText = ""
    var patternPNG: Data?
    var colors: [ColorReference] = []

    init(kind: ToolKind) {
        self.kind = kind
        self.name = kind.title
        self.limits = kind.defaultLimits
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        kind = try values.decode(ToolKind.self, forKey: .kind)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? kind.title
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        roi = try values.decodeIfPresent(CGRect.self, forKey: .roi)
        numbers = try values.decodeIfPresent([String: Double].self, forKey: .numbers) ?? [:]
        strings = try values.decodeIfPresent([String: String].self, forKey: .strings) ?? [:]
        limits = try values.decodeIfPresent([Limit].self, forKey: .limits) ?? []
        expectedText = try values.decodeIfPresent(String.self, forKey: .expectedText) ?? ""
        patternPNG = try values.decodeIfPresent(Data.self, forKey: .patternPNG)
        colors = try values.decodeIfPresent([ColorReference].self, forKey: .colors) ?? []
    }

    func number(_ spec: ParamSpec) -> Double { numbers[spec.key] ?? spec.defaultValue }

    /// Everything the engine reads, with defaults filled in.
    /// The measures this tool gives with its current settings, for the limits to choose from.
    var relevantMeasures: [String] {
        guard kind == .shapeFit else { return kind.measures }
        switch numbers["shape"] ?? 1 {
        case 0: return ["found", "length", "angle", "x", "y", "rms_error", "max_deviation", "share_used"]
        case 2: return ["found", "major_axis", "minor_axis", "angle", "x", "y", "rms_error", "max_deviation"]
        case 3: return ["found", "length", "width", "angle", "x", "y", "rms_error", "max_deviation"]
        default: return ["found", "diameter", "x", "y", "roundness", "rms_error", "arc_coverage", "share_used"]
        }
    }

    var engineNumbers: [String: Double] {
        var all = numbers
        for spec in kind.params where all[spec.key] == nil {
            all[spec.key] = spec.defaultValue
        }
        return all
    }
}

struct ParamSpec: Identifiable {
    enum Control {
        case slider(ClosedRange<Double>, step: Double)
        case choice([(String, Double)])
        case toggle
        case file(extensions: [String])
    }

    let key: String
    let label: String
    let control: Control
    var defaultValue: Double = 0
    /// Shown only when this returns true, for settings that depend on another setting.
    var isRelevant: (ToolConfig) -> Bool = { _ in true }

    var id: String { key }

    /// How the contour tools get their outlines, which they share.
    static func extraction(defaultMethod: Double, dropBorderByDefault: Bool) -> [ParamSpec] {
        let usesEdges: (ToolConfig) -> Bool = { ($0.numbers["method"] ?? defaultMethod) == 3 }
        return [
            ParamSpec(key: "method", label: "Find outlines by", control: .choice([("Automatic threshold", 0), ("Fixed threshold", 1), ("Adaptive threshold", 2), ("Edges", 3)]), defaultValue: defaultMethod),
            ParamSpec(key: "polarity", label: "Objects", control: .choice([("Dark", 0), ("Bright", 1)]), isRelevant: { !usesEdges($0) }),
            ParamSpec(key: "threshold", label: "Level", control: .slider(0...255, step: 1), defaultValue: 128,
                      isRelevant: { ($0.numbers["method"] ?? defaultMethod) == 1 }),
            ParamSpec(key: "adaptiveBlock", label: "Block size", control: .slider(3...255, step: 2), defaultValue: 51,
                      isRelevant: { ($0.numbers["method"] ?? defaultMethod) == 2 }),
            ParamSpec(key: "adaptiveC", label: "Offset", control: .slider(-30...30, step: 1), defaultValue: 8,
                      isRelevant: { ($0.numbers["method"] ?? defaultMethod) == 2 }),
            ParamSpec(key: "minEdge", label: "Edge contrast (0 = automatic)", control: .slider(0...100, step: 1), isRelevant: usesEdges),
            ParamSpec(key: "blur", label: "Blur", control: .slider(0...25, step: 2), defaultValue: 3),
            ParamSpec(key: "smoothContour", label: "Smoothing", control: .slider(0...5, step: 0.5), defaultValue: 1),
            ParamSpec(key: "minLength", label: "Min length (px)", control: .slider(0...2_000, step: 5), defaultValue: 20),
            ParamSpec(key: "maxLength", label: "Max length (px, 0 = none)", control: .slider(0...20_000, step: 50)),
            ParamSpec(key: "dropBorder", label: "Ignore outlines touching the edge", control: .toggle, defaultValue: dropBorderByDefault ? 1 : 0),
        ]
    }
}

enum ToolKind: String, Codable, CaseIterable, Identifiable {
    case quality, blobs, caliper, contours
    case shapeFit = "shapefit"
    case colorSegmenter = "colorsegmenter"
    case colorExtractor = "colorextractor"
    case colorMatch = "colormatch"
    case compositeColorMatch = "compositecolor"
    case pattern, code, ocr, onnx

    var id: String { rawValue }

    var title: String {
        switch self {
        case .quality: return "Image Quality"
        case .blobs: return "Blob Analysis"
        case .caliper: return "Caliper"
        case .contours: return "Contours"
        case .shapeFit: return "Shape Fit"
        case .colorSegmenter: return "Color Segmenter"
        case .colorExtractor: return "Color Extractor"
        case .colorMatch: return "Color Match"
        case .compositeColorMatch: return "Composite Color Match"
        case .pattern: return "Pattern Match"
        case .code: return "QR / Barcode"
        case .ocr: return "OCR (PaddleOCR)"
        case .onnx: return "ONNX Model"
        }
    }

    var symbol: String {
        switch self {
        case .quality: return "camera.metering.center.weighted"
        case .blobs: return "circle.grid.2x2.fill"
        case .caliper: return "ruler"
        case .contours: return "scribble.variable"
        case .shapeFit: return "circle.dashed"
        case .colorSegmenter: return "paintpalette"
        case .colorExtractor: return "eyedropper"
        case .colorMatch: return "swatchpalette"
        case .compositeColorMatch: return "chart.bar.xaxis"
        case .pattern: return "viewfinder"
        case .code: return "qrcode.viewfinder"
        case .ocr: return "text.viewfinder"
        case .onnx: return "brain"
        }
    }

    var summary: String {
        switch self {
        case .quality: return "Sharpness, brightness and clipped pixels. Use it to set up focus and lighting."
        case .blobs: return "Separates objects from the background, then counts and sizes them."
        case .caliper: return "Finds edges across the region to a fraction of a pixel and measures the distance between the outer two."
        case .contours: return "Extracts outlines to a fraction of a pixel, open or closed, and measures the largest. You can export them to a CAD program."
        case .shapeFit: return "Fits a line, circle, ellipse or rectangle to the edges in the region, ignoring those that don't belong, and measures it. Draw the region around the feature."
        case .colorSegmenter: return "Finds the pixels within set ranges around taught colors, in RGB or HSI, and counts and sizes the areas they form."
        case .colorExtractor: return "Finds the pixels within the volume of colors taught from a region, even if the color varies a lot, and counts them per color."
        case .colorMatch: return "Compares a region's average color with a set of reference colors, and says which is closest. Quick, and best for even colors."
        case .compositeColorMatch: return "Compares the mix of colors in a region with reference samples, and says which is closest. It tells apart patterns with the same average color."
        case .pattern: return "Finds a taught part at any angle, and reports where it is and how it's turned. Search by surface features for detailed parts, or by edges for plain ones."
        case .code: return "Reads QR, Data Matrix, Code 128, Code 39, EAN, UPC, PDF417, Aztec and other codes with Apple Vision, at any angle."
        case .ocr: return "Reads printed text with PaddleOCR's PP-OCRv5 models on ONNX Runtime."
        case .onnx: return "Runs your own ONNX image classifier or YOLO-style detector."
        }
    }

    /// The measures a limit can apply to, in the order the inspector lists them.
    var measures: [String] {
        switch self {
        case .quality: return ["sharpness", "brightness", "contrast", "clipped_highlights", "clipped_shadows"]
        case .blobs: return ["count", "total_area", "largest_area", "largest_length", "largest_width"]
        case .caliper: return ["edges", "distance"]
        case .contours: return ["count", "closed", "open", "holes", "total_length", "longest", "largest_area", "perimeter", "circularity", "convexity", "corners", "aspect_ratio", "x", "y", "angle"]
        case .colorSegmenter: return ["matched_pixels", "matched_share", "count", "largest_area", "x", "y"]
        case .colorExtractor: return ["matched_pixels", "matched_share", "best_index", "best_pixels", "count", "largest_area", "x", "y"]
        case .colorMatch: return ["score", "best_index", "margin", "red", "green", "blue", "hue", "saturation", "intensity"]
        case .compositeColorMatch: return ["score", "best_index", "margin"]
        case .shapeFit: return ["found", "length", "width", "diameter", "major_axis", "minor_axis", "angle", "x", "y", "roundness", "rms_error", "max_deviation", "arc_coverage", "share_used"]
        case .pattern: return ["count", "score", "x", "y", "angle", "scale", "tilt", "matches", "fit", "coverage", "clutter"]
        case .code: return ["count"]
        case .ocr: return ["lines", "mean_score"]
        case .onnx: return ["count", "top_score", "class", "score"]
        }
    }

    var defaultLimits: [Limit] {
        switch self {
        case .pattern, .code: return [Limit(measure: "count", minimum: 1)]
        case .shapeFit: return [Limit(measure: "found", minimum: 1)]
        case .ocr: return [Limit(measure: "lines", minimum: 1)]
        default: return []
        }
    }

    var readsText: Bool { self == .code || self == .ocr || self == .onnx || usesColors && self != .colorSegmenter }

    var usesColors: Bool { self == .colorSegmenter || self == .colorExtractor || self == .colorMatch || self == .compositeColorMatch }

    /// Whether a region taught from should go back to the whole image: a search covers everything, and a comparison doesn't.
    var searchesWholeImageAfterTeaching: Bool { self == .colorSegmenter || self == .colorExtractor }

    var params: [ParamSpec] {
        switch self {
        case .quality:
            return []
        case .blobs:
            return [
                ParamSpec(key: "polarity", label: "Objects", control: .choice([("Dark", 0), ("Bright", 1)])),
                ParamSpec(key: "method", label: "Threshold", control: .choice([("Automatic", 0), ("Fixed", 1), ("Adaptive", 2)])),
                ParamSpec(key: "threshold", label: "Level", control: .slider(0...255, step: 1), defaultValue: 128,
                          isRelevant: { ($0.numbers["method"] ?? 0) == 1 }),
                ParamSpec(key: "adaptiveBlock", label: "Block size", control: .slider(3...255, step: 2), defaultValue: 51,
                          isRelevant: { ($0.numbers["method"] ?? 0) == 2 }),
                ParamSpec(key: "adaptiveC", label: "Offset", control: .slider(-30...30, step: 1), defaultValue: 8,
                          isRelevant: { ($0.numbers["method"] ?? 0) == 2 }),
                ParamSpec(key: "blur", label: "Blur", control: .slider(0...25, step: 2), defaultValue: 3),
                ParamSpec(key: "open", label: "Remove specks", control: .slider(0...25, step: 1), defaultValue: 0),
                ParamSpec(key: "minArea", label: "Min area (px²)", control: .slider(0...50_000, step: 25), defaultValue: 25),
                ParamSpec(key: "maxArea", label: "Max area (px², 0 = none)", control: .slider(0...2_000_000, step: 500), defaultValue: 0),
                ParamSpec(key: "dropBorder", label: "Ignore objects touching the edge", control: .toggle),
            ]
        case .caliper:
            return [
                ParamSpec(key: "axis", label: "Measure", control: .choice([("Across (left to right)", 0), ("Down (top to bottom)", 1)])),
                ParamSpec(key: "smooth", label: "Smoothing", control: .slider(0...10, step: 0.5), defaultValue: 1.5),
                ParamSpec(key: "minEdge", label: "Min edge strength", control: .slider(1...60, step: 1), defaultValue: 4),
            ]
        case .colorSegmenter:
            return [
                ParamSpec(key: "colorSpace", label: "Color space", control: .choice([("HSI", 1), ("RGB", 0)]), defaultValue: 1),
                ParamSpec(key: "ignoreBrightness", label: "Ignore brightness", control: .toggle,
                          isRelevant: { ($0.numbers["colorSpace"] ?? 1) == 1 }),
                ParamSpec(key: "regionShape", label: "Region shape", control: .choice([("Rectangle", 0), ("Ellipse", 1)])),
                ParamSpec(key: "minArea", label: "Min area (px²)", control: .slider(0...50_000, step: 25), defaultValue: 50),
            ]
        case .colorExtractor:
            return [
                ParamSpec(key: "regionShape", label: "Region shape", control: .choice([("Rectangle", 0), ("Ellipse", 1)])),
                ParamSpec(key: "softnessThreshold", label: "Softness threshold", control: .slider(1...255, step: 1), defaultValue: 255),
                ParamSpec(key: "minArea", label: "Min area (px²)", control: .slider(0...50_000, step: 25), defaultValue: 50),
            ]
        case .colorMatch:
            return [
                ParamSpec(key: "colorSpace", label: "Color space", control: .choice([("RGB", 0), ("HSI", 1)])),
                ParamSpec(key: "ignoreBrightness", label: "Ignore brightness", control: .toggle),
                ParamSpec(key: "regionShape", label: "Region shape", control: .choice([("Rectangle", 0), ("Ellipse", 1)])),
            ]
        case .compositeColorMatch:
            return [
                ParamSpec(key: "ignoreBrightness", label: "Ignore brightness", control: .toggle),
                ParamSpec(key: "regionShape", label: "Region shape", control: .choice([("Rectangle", 0), ("Ellipse", 1)])),
            ]
        case .contours:
            return ParamSpec.extraction(defaultMethod: 0, dropBorderByDefault: true) + [
                ParamSpec(key: "keep", label: "Keep", control: .choice([("All", 0), ("Closed only", 1), ("Open only", 2)])),
                ParamSpec(key: "includeHoles", label: "Include holes", control: .toggle, defaultValue: 1,
                          isRelevant: { ($0.numbers["method"] ?? 0) != 3 }),
                ParamSpec(key: "minArea", label: "Min area (px²)", control: .slider(0...50_000, step: 25)),
                ParamSpec(key: "maxArea", label: "Max area (px², 0 = none)", control: .slider(0...2_000_000, step: 500)),
                ParamSpec(key: "cornerTolerance", label: "Corner tolerance (px)", control: .slider(0.5...20, step: 0.5), defaultValue: 3),
            ]
        case .shapeFit:
            return [
                ParamSpec(key: "shape", label: "Shape", control: .choice([("Line", 0), ("Circle", 1), ("Ellipse", 2), ("Rectangle", 3)]), defaultValue: 1),
                ParamSpec(key: "tolerance", label: "Tolerance (px)", control: .slider(0.5...10, step: 0.5), defaultValue: 1.5),
            ] + ParamSpec.extraction(defaultMethod: 3, dropBorderByDefault: false)
        case .pattern:
            return [
                ParamSpec(key: "search", label: "Search", control: .choice([("Surface features", 0), ("Same angle and size", 1), ("Edges, for plain parts", 2)])),
                ParamSpec(key: "features", label: "Features", control: .choice([("ORB", 0), ("SIFT", 1)]),
                          isRelevant: { ($0.numbers["search"] ?? 0) == 0 }),
                ParamSpec(key: "allowTilt", label: "Allow for tilt", control: .toggle, defaultValue: 1,
                          isRelevant: { ($0.numbers["search"] ?? 0) != 1 }),
                ParamSpec(key: "scaleMin", label: "Smallest size", control: .slider(0.25...1, step: 0.05), defaultValue: 0.7,
                          isRelevant: { ($0.numbers["search"] ?? 0) == 2 }),
                ParamSpec(key: "scaleMax", label: "Largest size", control: .slider(1...4, step: 0.05), defaultValue: 1.4,
                          isRelevant: { ($0.numbers["search"] ?? 0) == 2 }),
                ParamSpec(key: "angleRange", label: "Angle range (± degrees)", control: .slider(0...180, step: 5), defaultValue: 180,
                          isRelevant: { ($0.numbers["search"] ?? 0) == 2 }),
                ParamSpec(key: "minEdge", label: "Edge contrast (0 = automatic)", control: .slider(0...100, step: 1), defaultValue: 0,
                          isRelevant: { ($0.numbers["search"] ?? 0) == 2 }),
                ParamSpec(key: "anyPolarity", label: "Allow reversed contrast", control: .toggle, defaultValue: 1,
                          isRelevant: { ($0.numbers["search"] ?? 0) == 2 }),
                ParamSpec(key: "minScore", label: "Min score", control: .slider(0.3...1, step: 0.01), defaultValue: 0.7),
                ParamSpec(key: "maxInstances", label: "Max parts", control: .slider(1...50, step: 1), defaultValue: 1),
            ]
        case .code:
            return [ParamSpec(key: "codes", label: "Look for", control: .choice([("All codes", 0), ("QR", 1), ("Barcodes", 2), ("Data Matrix, PDF417, Aztec", 3)]))]
        case .ocr:
            return [
                ParamSpec(key: "boxThreshold", label: "Text box confidence", control: .slider(0.1...0.95, step: 0.05), defaultValue: 0.6),
                ParamSpec(key: "unclipRatio", label: "Box padding", control: .slider(1...3, step: 0.1), defaultValue: 1.5),
                ParamSpec(key: "minTextScore", label: "Min read confidence", control: .slider(0...0.99, step: 0.01), defaultValue: 0.5),
                ParamSpec(key: "maxSide", label: "Detection size (px)", control: .slider(320...1920, step: 32), defaultValue: 960),
                ParamSpec(key: "checkOrientation", label: "Read upside-down text", control: .toggle, defaultValue: 1),
            ]
        case .onnx:
            let isDetector: (ToolConfig) -> Bool = { ($0.numbers["modelMode"] ?? 0) == 1 }
            return [
                ParamSpec(key: "modelPath", label: "Model", control: .file(extensions: ["onnx"])),
                ParamSpec(key: "labelsPath", label: "Labels (one per line)", control: .file(extensions: ["txt", "names"])),
                ParamSpec(key: "modelMode", label: "Type", control: .choice([("Classifier", 0), ("YOLO detector", 1)])),
                ParamSpec(key: "yoloFormat", label: "Output", control: .choice([("v8 style", 0), ("v5 style (objectness)", 1)]), isRelevant: isDetector),
                ParamSpec(key: "confidence", label: "Min confidence", control: .slider(0.05...0.95, step: 0.05), defaultValue: 0.25, isRelevant: isDetector),
                ParamSpec(key: "iou", label: "Overlap limit (IoU)", control: .slider(0.1...0.9, step: 0.05), defaultValue: 0.45, isRelevant: isDetector),
                ParamSpec(key: "inputSize", label: "Input size if not fixed", control: .slider(32...1280, step: 32), defaultValue: 640, isRelevant: isDetector),
                ParamSpec(key: "colorOrder", label: "Channels", control: .choice([("BGR", 0), ("RGB", 1)]), defaultValue: 1),
                ParamSpec(key: "normalization", label: "Pixel scale", control: .choice([("0 to 1", 0), ("ImageNet", 1)])),
            ]
        }
    }
}
