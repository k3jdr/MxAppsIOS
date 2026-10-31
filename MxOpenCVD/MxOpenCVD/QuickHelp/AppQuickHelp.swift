//
//  AppQuickHelp.swift
//
//  What Quick Help says in MxOpenCVD: the window, the cameras, each tool with its settings and measures, the
//  image under the pointer (what a tool found there, and the pixel), and the results.
//

import CoreGraphics
import Foundation

enum AppQuickHelp {
    // MARK: The window

    static let window = QuickHelpItem(
        title: "MxOpenCVD",
        detail: "Inspects what a camera sees with the tools in the job, and gives a pass or fail with the reasons. Add tools on the left, tune them on the right, and press Inspect or Trigger.",
        symbol: "camera.viewfinder")

    /// The selected tool and its latest result. Measures stay out of this, since they change on every frame.
    static func selection(tool: ToolConfig?, report: ToolReport?) -> QuickHelpItem? {
        guard let tool else { return nil }
        var detail = tool.kind.summary
        if let report {
            detail += " Latest result: \(report.verdict.rawValue)."
            if !report.reasons.isEmpty { detail += " " + report.reasons.joined(separator: "; ") + "." }
        }
        return QuickHelpItem(title: tool.name, detail: detail, symbol: tool.kind.symbol)
    }

    // MARK: Toolbar

    static let mode = QuickHelpItem(
        title: "Preview or Inspect",
        detail: "Preview only shows the camera. Inspect runs the job on the newest frame each time the last run finishes, so a slow job lowers the inspection rate instead of falling behind the camera.",
        shortcut: "⌘R", symbol: "play.rectangle")
    static let trigger = QuickHelpItem(
        title: "Trigger",
        detail: "Inspects the image on screen once and adds the result to the results list, whichever mode you're in.",
        shortcut: "⌘T", symbol: "bolt.fill")
    static let freeze = QuickHelpItem(
        title: "Freeze or Live",
        detail: "Holds the current image and re-runs the job on it whenever a tool changes, so you can tune settings against one image. Press again to return to the camera.",
        shortcut: "⌘F", symbol: "pause.fill")
    static let openImage = QuickHelpItem(
        title: "Open Image",
        detail: "Inspects an image file instead of the camera, including HEIC from an iPhone. Live or Freeze returns to the camera.",
        shortcut: "⇧⌘O", symbol: "photo")

    // MARK: Cameras

    static let cameras = QuickHelpItem(
        title: "Cameras",
        detail: "The cameras in the order they're used: the iPhone, then the USB camera, then the MacBook's. Click one to use only that camera.",
        symbol: "video")
    static let auto = QuickHelpItem(
        title: "Auto",
        detail: "Uses the highest-ranked camera available. It moves down the list when a camera disconnects, suspends or sends no frames for 6 seconds, and returns when a better camera comes back. Turning it off keeps the camera in use.",
        symbol: "arrow.triangle.2.circlepath")
    static let focusLock = QuickHelpItem(
        title: "Lock Focus",
        detail: "Holds the focus where it is, so it can't drift between parts. Clicking the image focuses there, on cameras that allow it.",
        symbol: "scope")
    static let exposureLock = QuickHelpItem(
        title: "Lock Exposure",
        detail: "Holds the brightness where it is, so a dark or shiny part doesn't change how the next one looks. Thresholds depend on this.",
        symbol: "sun.max")

    static func camera(_ camera: CameraInfo, isActive: Bool, isPinned: Bool, controls: CameraControls) -> QuickHelpItem {
        var parts: [String] = []
        switch camera.tier {
        case .iPhone where camera.isDeskView:
            parts.append("The iPhone's view of the desk below it, flattened from its ultra wide camera. It's useful for parts too close for the main camera to focus on. Auto never picks it.")
        case .iPhone:
            parts.append("The primary camera, through Continuity Camera. The phone decides focus by itself, so if a close part stays blurred, move it farther away or use the Desk View.")
        case .usb:
            parts.append("The secondary camera, used when the iPhone isn't available.")
        case .builtIn where camera.isDeskView:
            parts.append("The MacBook's view of the desk in front of it. Auto never picks it.")
        case .builtIn:
            parts.append("The third camera, used when the iPhone and USB camera aren't available.")
        case .other:
            parts.append("A virtual camera or capture card, used only when nothing else is available.")
        }
        if camera.isSuspended { parts.append("It's suspended right now, as when the phone is in use.") }
        if isActive && !controls.formatDescription.isEmpty { parts.append("In use at \(controls.formatDescription).") }
        if isPinned { parts.append("Chosen by you: turn on Auto to go back to the order.") }
        return QuickHelpItem(title: camera.name, detail: parts.joined(separator: " "), symbol: camera.tier.symbol)
    }

    static func missingCamera(_ tier: CameraTier) -> QuickHelpItem {
        let detail: String
        switch tier {
        case .iPhone:
            detail = "Put the iPhone near this Mac, locked, with its screen off and its back camera facing the part. Both need the same Apple Account, with Wi-Fi and Bluetooth on."
        case .usb:
            detail = "Plug in a USB web camera. It's used as soon as it appears, if the iPhone isn't available."
        default:
            detail = "This camera isn't available."
        }
        return QuickHelpItem(title: "\(tier.title): Not Connected", detail: detail, symbol: tier.symbol)
    }

    // MARK: Tools

    static let tools = QuickHelpItem(
        title: "Tools",
        detail: "The steps of the job, run from the top down. Drag to reorder, click to tune one on the right, and right-click to delete. A job passes when every enabled tool does.",
        symbol: "list.bullet")
    static let addTool = QuickHelpItem(
        title: "Add a Tool",
        detail: "Adds an inspection step to the end of the job. Each one can have its own region and limits.",
        symbol: "plus")
    static let toolEnabled = QuickHelpItem(
        title: "Include This Tool",
        detail: "Turn it off to skip this tool without losing its settings.",
        symbol: "checkmark.square")

    static func tool(_ tool: ToolConfig, verdict: Verdict?) -> QuickHelpItem {
        var detail = tool.kind.summary
        if let verdict, tool.enabled { detail += " Latest result: \(verdict.rawValue)." }
        if !tool.enabled { detail += " It's turned off." }
        return QuickHelpItem(title: tool.name, detail: detail, symbol: tool.kind.symbol)
    }

    static func region(hasRegion: Bool) -> QuickHelpItem {
        QuickHelpItem(
            title: hasRegion ? "Redraw Region" : "Draw Region",
            detail: "Limits this tool to part of the image, which makes it faster and keeps it from reacting to anything else in view. The region is kept as a share of the image, so it survives a change of camera.",
            symbol: "rectangle.dashed")
    }
    static let wholeImage = QuickHelpItem(
        title: "Whole Image",
        detail: "Removes the region, so this tool looks at everything in view.",
        symbol: "rectangle")
    static let teachPattern = QuickHelpItem(
        title: "Teach Pattern",
        detail: "Saves the region as what to look for, then clears the region so the search covers the whole image. Teach from a good part with plenty of surface detail, viewed as squarely as you can, and draw the region close around it.",
        symbol: "viewfinder")
    static func addColor(for kind: ToolKind) -> QuickHelpItem {
        let detail: String
        switch kind {
        case .colorSegmenter:
            detail = "Averages the region's color and sets starting ranges around it. Then the region clears, so the search covers the whole image. Adjust the ranges to suit: it usually takes a few tries."
        case .colorExtractor:
            detail = "Takes in all the colors in the region as a volume. A region with more variety takes in more colors, but risks finding others that share them. Then the region clears, so the search covers the whole image."
        case .colorMatch:
            detail = "Adds the region's average color as a reference. Add one for each color to tell apart, then draw the region where the sample will be."
        default:
            detail = "Adds the mix of colors in the region as a reference. Add one for each sample to tell apart, then draw the region where the sample will be."
        }
        return QuickHelpItem(title: "Add Color from Region", detail: detail, symbol: kind.symbol)
    }
    static let segmenterRange = QuickHelpItem(
        title: "Color Range",
        detail: "How far below and above the taught value this plane can be, from the left slider to the right. A pixel must be in range on all three planes. The taught value itself is fixed.",
        symbol: "slider.horizontal.3")
    static let segmenterSoftness = QuickHelpItem(
        title: "Softness",
        detail: "A band just outside the range where pixels get a partial grey instead of none, for use in a result image. It doesn't change which pixels are counted, since those must be fully in range.",
        symbol: "circle.lefthalf.filled")
    static let extractorDilation = QuickHelpItem(
        title: "Dilation",
        detail: "Grows the color volume by this many RGB levels, which helps with changes in lighting and position. Too much starts to take in other colors.",
        symbol: "arrow.up.left.and.arrow.down.right")
    static let extractorSoftness = QuickHelpItem(
        title: "Softness",
        detail: "How far pixels near the volume fade from bright grey to black. It doesn't change the count, unless Softness threshold is lowered from 255.",
        symbol: "circle.lefthalf.filled")
    static let matteLine = QuickHelpItem(
        title: "Matte Line",
        detail: "Extends the color to the same hue lit less (low) or more (high), which helps with shadows and uneven light. 0 is off.",
        symbol: "sun.min")
    static let highlightLine = QuickHelpItem(
        title: "Highlight Line",
        detail: "Extends the color toward pure white, to include shine on a glossy part. 0 is off.",
        symbol: "sparkle")
    static let exportContours = QuickHelpItem(
        title: "Export Contours",
        detail: "Saves the outlines from the current image, at full precision, as DXF for a CAD program, SVG for a drawing program, or CSV for a spreadsheet. They're in millimetres if this camera is calibrated, and pixels otherwise. Lens distortion isn't corrected.",
        symbol: "square.and.arrow.up")
    static let expectedText = QuickHelpItem(
        title: "Expected Text",
        detail: "A regular expression that at least one line of the text must match, or the tool fails. ^ and $ mark the start and end of a line. For example, ^LOT [A-Z0-9-]+$ matches a whole line such as LOT A7-20391.",
        symbol: "text.magnifyingglass")
    static let limits = QuickHelpItem(
        title: "Pass Limits",
        detail: "The tool fails when a measure is outside its minimum or maximum, or can't be measured at all. Leave both empty to ignore a measure. With no limits and no expected text, a tool only reports.",
        symbol: "ruler")
    static let latestResult = QuickHelpItem(
        title: "Latest Result",
        detail: "What this tool found the last time it ran, and why it failed if it did. NO CRITERIA means it ran fine with no limits to judge it against.",
        symbol: "checkmark.seal")

    /// What one setting does. Every setting in ToolKind.params has an entry; the self-test checks this.
    static func param(_ spec: ParamSpec, of kind: ToolKind) -> QuickHelpItem {
        QuickHelpItem(title: spec.label, detail: paramDetail(key: spec.key, kind: kind) ?? "", symbol: kind.symbol)
    }

    static func paramDetail(key: String, kind: ToolKind) -> String? {
        switch (kind, key) {
        case (.blobs, "polarity"): return "Whether the objects to find are darker or brighter than their background."
        case (.blobs, "method"): return "How object is told from background. Automatic picks a level for each image, Fixed always uses yours, and Adaptive compares each pixel with its surroundings, which suits uneven lighting."
        case (.blobs, "threshold"): return "The brightness, from 0 to 255, that separates object from background."
        case (.blobs, "adaptiveBlock"): return "The size in pixels of the surroundings each pixel is compared with. Make it larger than the objects."
        case (.blobs, "adaptiveC"): return "How far a pixel must differ from its surroundings to count. Raise it if background noise is picked up as objects."
        case (.blobs, "blur"): return "Smooths the image first, in pixels, to reduce noise and surface texture. Too much merges objects that are close together."
        case (.blobs, "open"): return "Removes specks and thin bridges up to about this many pixels across. It also trims the objects' edges a little, which affects measured sizes."
        case (.blobs, "minArea"): return "Ignores objects smaller than this, in square pixels. It's the usual way to filter out dust."
        case (.blobs, "maxArea"): return "Ignores objects larger than this, in square pixels. Use 0 for no limit."
        case (.blobs, "dropBorder"): return "Ignores objects touching the region's edge, since they may be cut off and can't be measured properly."
        case (.caliper, "axis"): return "The direction to measure in. The tool averages across the other direction, so draw the region along the edges you're measuring."
        case (.caliper, "smooth"): return "Smooths the brightness along the scan. Raise it if surface texture shows up as false edges."
        case (.caliper, "minEdge"): return "How sharply brightness must change to count as an edge, in gray levels per pixel. Raise it if there are extra edges, and lower it if real ones are missed."
        case (.contours, "method"), (.shapeFit, "method"): return "Threshold splits the image into object and background, and gives closed outlines with holes known apart. Automatic picks a level for each image, and Adaptive suits uneven lighting. Edges needs no level and also gives open outlines, such as a scratch or a shape running out of view."
        case (.contours, "polarity"), (.shapeFit, "polarity"): return "Whether the objects are darker or brighter than the background."
        case (.contours, "threshold"), (.shapeFit, "threshold"): return "The brightness, from 0 to 255, that separates object from background."
        case (.contours, "adaptiveBlock"), (.shapeFit, "adaptiveBlock"): return "The size in pixels of the surroundings each pixel is compared with. Make it larger than the objects."
        case (.contours, "adaptiveC"), (.shapeFit, "adaptiveC"): return "How far a pixel must differ from its surroundings to count. Raise it if background noise becomes outlines."
        case (.contours, "minEdge"), (.shapeFit, "minEdge"): return "How sharp an edge must be to count, in brightness levels per pixel. Use 0 to choose automatically."
        case (.contours, "blur"), (.shapeFit, "blur"): return "Smooths the image first, in pixels, to reduce noise and surface texture. A little helps accuracy. Too much rounds off corners and shrinks small shapes."
        case (.contours, "smoothContour"), (.shapeFit, "smoothContour"): return "Smooths each outline along its length, which steadies its points and a measured perimeter on a noisy image. More than the default rounds off corners and shrinks small shapes."
        case (.contours, "minLength"), (.shapeFit, "minLength"): return "Ignores outlines shorter than this. It's the usual way to filter out dust and noise."
        case (.contours, "maxLength"), (.shapeFit, "maxLength"): return "Ignores outlines longer than this. Use 0 for no limit."
        case (.contours, "dropBorder"), (.shapeFit, "dropBorder"): return "Ignores outlines that reach the edge of the region, since they're cut off and their lengths and areas don't mean much. Leave it off when fitting a line that runs past the region."
        case (.contours, "keep"): return "Which outlines to keep. Open ones only come from the Edges method."
        case (.contours, "includeHoles"): return "Includes the inside edges of holes. Turn it off to get only outer outlines."
        case (.contours, "minArea"): return "Ignores closed outlines enclosing less than this, in square pixels."
        case (.contours, "maxArea"): return "Ignores closed outlines enclosing more than this, in square pixels. Use 0 for no limit."
        case (.contours, "cornerTolerance"): return "How far an outline can stray from a straight line before that counts as a corner. Raise it if noise or rounding adds corners."
        case (.shapeFit, "shape"): return "The shape to fit. Lines and circles use every edge in the region and ignore those that don't agree, so a partly hidden feature still works. Ellipses and rectangles use the largest closed outline."
        case (.shapeFit, "tolerance"): return "How far an edge can be from the shape and still count as part of it. Raise it for rough edges, and lower it if nearby edges are being pulled in."
        case (_, "colorSpace"): return "RGB is how cameras record color. HSI separates color from brightness, so a range or comparison can focus on the hue, and it's usually easier to relate to how a color looks."
        case (_, "ignoreBrightness"): return "Compares color alone, so a part in dimmer or brighter light still matches. Turn it on if the light varies. Leave it off if brightness is what tells your colors apart, such as dark and light red, or white, grey and black, which it can't tell apart."
        case (_, "regionShape"): return "The shape of the region: the rectangle you drew, or the ellipse that fits inside it. Pixels outside the shape don't count, which helps with round parts."
        case (.colorSegmenter, "minArea"), (.colorExtractor, "minArea"): return "Ignores areas smaller than this when counting them, in square pixels. It doesn't change the pixel count or share."
        case (.colorExtractor, "softnessThreshold"): return "The grey value a pixel needs to count as this color. At 255, only pixels in the volume count. Lower it to count nearby pixels, when softness is set."
        case (.pattern, "search"): return "Surface features suit printed or textured parts, tilted or not, from about a third to four times their taught size. Edges suit plain parts such as machined or stamped ones: it follows the outline, copes with changes in lighting, and gives the most exact position. Same angle and size is for parts a fixture always holds the same way."
        case (.pattern, "scaleMin"): return "The smallest the part can look, compared with how it was taught. A narrower range is faster and leaves less room for a false find, so set it as tightly as your setup allows."
        case (.pattern, "scaleMax"): return "The largest the part can look, compared with how it was taught. A narrower range is faster and leaves less room for a false find, so set it as tightly as your setup allows."
        case (.pattern, "angleRange"): return "How far the part can be turned from how it was taught, either way. 180 allows any angle. A narrower range is much faster, and lets you tell apart turns of a symmetrical part, which look alike otherwise."
        case (.pattern, "minEdge"): return "How sharp an outline must be to become part of the pattern, in brightness levels per pixel. Use 0 to choose automatically. Raise it if surface marks are being taught as edges, and lower it if the outline is faint."
        case (.pattern, "anyPolarity"): return "Finds a part even if it's light on dark where it was taught dark on light, as when the background changes or the light comes from behind. Turn it off if contrast is what tells two parts apart."
        case (.pattern, "features"): return "How the search recognizes the part. ORB is the faster, and did as well or better on most parts tested. SIFT takes about twice as long and sometimes holds up better at steep tilts, so try it if ORB misses a part."
        case (.pattern, "allowTilt"): return "Follows a part viewed at an angle, which is usual with a hand-held or stand-mounted phone. Turn it off for a part that's always square to the camera, so the outline can't skew. The edge search only follows a slight tilt."
        case (.pattern, "minScore"): return "How closely the part must match the pattern to count, where 1 is identical. Lower it if good parts are missed or partly hidden, and raise it if wrong ones are found."
        case (.pattern, "maxInstances"): return "The most matches to look for. Use more than 1 when several parts are in view."
        case (.code, "codes"): return "Which kinds of code to look for. Choosing only what you expect stops other codes in view from being read."
        case (.ocr, "boxThreshold"): return "How sure the model must be that an area holds text. Lower it if faint text is missed, and raise it if patterns are mistaken for text."
        case (.ocr, "unclipRatio"): return "How far to grow each text box around the letters. Raise it if the edges of letters are cut off, and lower it if neighbouring lines run together."
        case (.ocr, "minTextScore"): return "Drops lines read with less confidence than this, where 1 is certain."
        case (.ocr, "maxSide"): return "The size the image is reduced to for finding text. Larger finds smaller text but takes longer. Drawing a tight region usually helps more."
        case (.ocr, "checkOrientation"): return "Turns upside-down lines over before reading them. Turn it off if parts always face the same way, or if text that reads either way gets flipped."
        case (.onnx, "modelPath"): return "Your model file, in ONNX format. The app keeps a link to it, so don't move the file."
        case (.onnx, "labelsPath"): return "An optional text file with one class name per line, in the model's class order. Without it, results show class numbers."
        case (.onnx, "modelMode"): return "A classifier gives one answer for the whole region. A YOLO detector finds and boxes objects in it."
        case (.onnx, "yoloFormat"): return "How the model lays out its output. YOLOv8-style models have no objectness column and YOLOv5-style models do. Boxes must be in input pixels, so the model must be exported with its post-processing included."
        case (.onnx, "confidence"): return "Ignores detections below this score."
        case (.onnx, "iou"): return "How much two boxes of one class may overlap before the weaker is dropped as a duplicate."
        case (.onnx, "inputSize"): return "The size to feed the model when the model doesn't fix one itself. Match what it was trained with."
        case (.onnx, "colorOrder"): return "The channel order the model was trained on. Most models use RGB."
        case (.onnx, "normalization"): return "How pixel values are scaled for the model. Match its training: many detectors use 0 to 1, and many classifiers use ImageNet."
        default: return nil
        }
    }

    /// What one measure means. Every measure in ToolKind.measures has an entry; the self-test checks this.
    static func measure(_ name: String, of kind: ToolKind) -> QuickHelpItem {
        QuickHelpItem(title: name.replacingOccurrences(of: "_", with: " ").capitalized,
                      detail: measureDetail(name, kind: kind) ?? "", symbol: "ruler")
    }

    static func measureDetail(_ name: String, kind: ToolKind) -> String? {
        switch (kind, name) {
        case (.quality, "sharpness"): return "How much fine detail the image has: higher is sharper. It depends on the scene as well as the focus, so only compare images of the same part in the same region."
        case (.quality, "brightness"): return "The average brightness, from 0 to 255."
        case (.quality, "contrast"): return "How much brightness varies across the region. Low contrast makes edges and text harder to find."
        case (.quality, "clipped_highlights"): return "The share of pixels at or near pure white, where detail is lost. Glare shows up here."
        case (.quality, "clipped_shadows"): return "The share of pixels at or near pure black, where detail is lost."
        case (.blobs, "count"): return "How many objects passed the size filters."
        case (.blobs, "total_area"): return "The area of all the objects together, in mm² when calibrated and square pixels otherwise. Holes inside an object count as part of it."
        case (.blobs, "largest_area"): return "The area of the largest object, in mm² when calibrated and square pixels otherwise."
        case (.blobs, "largest_length"): return "The long side of the smallest rectangle around the largest object, at any angle, in mm when calibrated and pixels otherwise."
        case (.blobs, "largest_width"): return "The short side of the smallest rectangle around the largest object, at any angle, in mm when calibrated and pixels otherwise."
        case (.caliper, "edges"): return "How many edges were found along the scan."
        case (.caliper, "distance"): return "The distance between the first and last edges, in mm when calibrated and pixels otherwise. It needs at least two edges."
        case (.contours, "count"): return "How many outlines passed the filters."
        case (.contours, "closed"): return "How many outlines close on themselves."
        case (.contours, "open"): return "How many outlines have two ends, which only the Edges method gives."
        case (.contours, "holes"): return "How many outlines are the inside edges of holes. The Edges method can't tell, so it doesn't report this."
        case (.contours, "total_length"): return "The length of all the outlines together, in mm when calibrated and pixels otherwise."
        case (.contours, "longest"): return "The length of the measured outline: the largest closed one, or else the longest open one. It's in mm when calibrated and pixels otherwise."
        case (.contours, "largest_area"): return "The area inside the largest closed outline, in mm² when calibrated and square pixels otherwise. Its holes aren't subtracted."
        case (.contours, "perimeter"): return "The length around the largest closed outline, in mm when calibrated and pixels otherwise. Corners add a few pixels, so it's less exact than the area on a small square part."
        case (.contours, "circularity"): return "How round the largest closed outline is, where 1 is a perfect circle. A square is about 0.79."
        case (.contours, "convexity"): return "How much of the outline's convex hull it fills, where 1 has no dents. A dent or a missing piece lowers it."
        case (.contours, "corners"): return "How many corners the largest closed outline has, within the corner tolerance. A curved shape's count depends on that tolerance."
        case (.contours, "aspect_ratio"): return "The long side of the smallest rectangle around the outline, divided by the short side."
        case (.contours, "x"): return "The horizontal position of the measured outline's center, in image pixels."
        case (.contours, "y"): return "The vertical position of the measured outline's center, in image pixels."
        case (.contours, "angle"): return "The direction of the largest outline's long axis, in degrees, with counter-clockwise positive. It means little for a shape with no long axis, such as a circle or square."
        case (.shapeFit, "found"): return "1 if the shape was found, and 0 if not. A line or circle needs edge points close together along it, mostly in long unbroken stretches, so scattered points don't count. An ellipse or rectangle must follow the outline, within the tolerance."
        case (.shapeFit, "length"): return "A line's length, from the first agreeing edge point to the last, or a rectangle's long side. It's in mm when calibrated and pixels otherwise."
        case (.shapeFit, "width"): return "A rectangle's short side, in mm when calibrated and pixels otherwise."
        case (.shapeFit, "diameter"): return "The fitted circle's diameter, in mm when calibrated and pixels otherwise. It's less exact when only a short arc is visible."
        case (.shapeFit, "major_axis"): return "An ellipse's longest diameter, in mm when calibrated and pixels otherwise."
        case (.shapeFit, "minor_axis"): return "An ellipse's shortest diameter, in mm when calibrated and pixels otherwise."
        case (.shapeFit, "angle"): return "The direction of the line, or the long axis of an ellipse or rectangle, in degrees from -90 to 90, with counter-clockwise positive."
        case (.shapeFit, "x"): return "The horizontal position of the shape's center, or a line's midpoint, in image pixels."
        case (.shapeFit, "y"): return "The vertical position of the shape's center, or a line's midpoint, in image pixels."
        case (.shapeFit, "roundness"): return "The largest radius minus the smallest among the agreeing edge points. Noise adds to it, so a perfect circle still reads a pixel or two."
        case (.shapeFit, "rms_error"): return "The typical distance from the edge points to the fitted shape. A larger value means a rougher or less true shape."
        case (.shapeFit, "max_deviation"): return "The farthest any agreeing edge point lies from the shape. It can't exceed the tolerance for a line, since points beyond it don't count."
        case (.shapeFit, "arc_coverage"): return "How much of the way around the circle has edges, from 0 to 1. Below about a third, treat the diameter with caution."
        case (.shapeFit, "share_used"): return "The share of the edge points in the region that agree with the shape. A low share means there's a lot else in the region, so the fit is less steady. Draw the region tighter, or raise Min length or Edge contrast."
        case (.colorSegmenter, "matched_pixels"): return "How many pixels are fully within a color's range."
        case (.colorSegmenter, "matched_share"), (.colorExtractor, "matched_share"): return "Those pixels as a percentage of the region."
        case (.colorSegmenter, "count"), (.colorExtractor, "count"): return "How many separate areas of matching pixels there are, of at least the minimum area."
        case (.colorSegmenter, "largest_area"), (.colorExtractor, "largest_area"): return "The largest area, in mm² when calibrated and square pixels otherwise."
        case (.colorSegmenter, "x"), (.colorExtractor, "x"): return "The horizontal center of the largest area, in image pixels."
        case (.colorSegmenter, "y"), (.colorExtractor, "y"): return "The vertical center of the largest area, in image pixels."
        case (.colorExtractor, "matched_pixels"): return "How many pixels match any of the colors, at or above the softness threshold."
        case (.colorExtractor, "best_index"): return "Which color has the most pixels, counting the list from 1. The expected text can check its name."
        case (.colorExtractor, "best_pixels"): return "How many pixels that color has."
        case (.colorMatch, "score"): return "How close the region's average is to the best reference, where 1 is identical. It's this app's own measure of distance in the chosen color space, so it isn't comparable with scores from other software. Set limits by trying good and bad samples."
        case (.compositeColorMatch, "score"): return "How alike the mix of colors is, compared with the best reference, where 1 is identical and 0 shares nothing. It's this app's own measure, so it isn't comparable with scores from other software, and a change in lighting can lower it a lot."
        case (.colorMatch, "best_index"), (.compositeColorMatch, "best_index"): return "Which reference is closest, counting the list from 1. The expected text can check its name."
        case (.colorMatch, "margin"), (.compositeColorMatch, "margin"): return "How far the best score is ahead of the next. A small margin means the choice is close, whatever the score."
        case (.colorMatch, "red"): return "The region's average red, from 0 to 255."
        case (.colorMatch, "green"): return "The region's average green, from 0 to 255."
        case (.colorMatch, "blue"): return "The region's average blue, from 0 to 255."
        case (.colorMatch, "hue"): return "The region's average position on the color wheel, scaled to run from 0 to 255. Red sits at 0, so it can read near 0 or near 255."
        case (.colorMatch, "saturation"): return "How pure the region's average color is, from 0 for grey to 255."
        case (.colorMatch, "intensity"): return "The average of the region's red, green and blue, from 0 to 255."
        case (.pattern, "count"): return "How many matches reached the minimum score."
        case (.pattern, "score"): return "How well the best match fits, where 1 is identical. Surface search takes the median across small cells of the pattern. Edge search takes the share of the outline found in connected runs. A small defect barely changes it, so it finds parts rather than checking them."
        case (.pattern, "x"): return "The horizontal position of the best match's center, in image pixels."
        case (.pattern, "y"): return "The vertical position of the best match's center, in image pixels."
        case (.pattern, "angle"): return "How far the best match is turned from the taught pattern, in degrees, with counter-clockwise positive. A limit near 180 can flip between 180 and -180."
        case (.pattern, "scale"): return "How large the best match looks compared with the taught pattern, where 1 is the same size. It's a useful check that the camera hasn't moved."
        case (.pattern, "tilt"): return "How far the part looks tilted away from the taught view, in degrees. It's most useful as a limit when you need the camera to stay square to the part. Small values are normal and don't mean a real tilt."
        case (.pattern, "matches"): return "How many surface features or edge points agree on where the best match is. More means a surer position."
        case (.pattern, "fit"): return "How closely the image's edges line up with the taught outline, where 1 is exact. It's only for the edge search."
        case (.pattern, "coverage"): return "How much of the taught outline was found, from 0 to 1. A part with something on top of it, or a piece missing, loses coverage. It's only for the edge search."
        case (.pattern, "clutter"): return "Extra edges inside the part's outline that aren't in the pattern, compared with the size of the outline. High clutter can mean dirt, a defect or the wrong part. It's only for the edge search."
        case (.code, "count"): return "How many different codes were read."
        case (.ocr, "lines"): return "How many lines of text were read."
        case (.ocr, "mean_score"): return "The average confidence across the lines, where 1 is certain."
        case (.onnx, "count"): return "How many objects a detector found. A classifier doesn't report this."
        case (.onnx, "top_score"): return "The strongest detection's score. A classifier doesn't report this."
        case (.onnx, "class"): return "The number of the class a classifier chose, counting from 0. A detector doesn't report this."
        case (.onnx, "score"): return "A classifier's confidence in its answer, where 1 is certain. A detector doesn't report this."
        default: return nil
        }
    }

    // MARK: Job

    static let jobName = QuickHelpItem(
        title: "Job Name",
        detail: "The name shown in the title bar and suggested when you save the job or export its results.",
        symbol: "doc")
    static let scale = QuickHelpItem(
        title: "Scale",
        detail: "Converts pixels to millimetres for this camera, and holds only at the distance it was set. Clear it to go back to pixels. If a job has a scale and fails over to a camera without one, limits on lengths and areas fail instead of comparing pixels with millimetres.",
        symbol: "ruler")
    static let chessboard = QuickHelpItem(
        title: "Chessboard Calibration",
        detail: "Sets the scale from a printed chessboard lying where the part will be. Count the corners where four squares meet, not the squares themselves, and measure a printed square: printers often rescale. The whole board must be in view.",
        symbol: "checkerboard.rectangle")
    static let saveFailures = QuickHelpItem(
        title: "Save Failure Images",
        detail: "Saves a PNG in Pictures ▸ MxOpenCVD ▸ Failures for each triggered failure, and each time live inspection changes to failing, so a long failure doesn't fill the disk.",
        symbol: "photo.on.rectangle")

    // MARK: Results

    static let results = QuickHelpItem(
        title: "Results",
        detail: "The latest 500 results, newest first. Triggers and frozen images always add a row. Live inspection only adds one when the result changes or different tools fail.",
        symbol: "list.bullet.rectangle")
    static let exportResults = QuickHelpItem(
        title: "Export Results",
        detail: "Saves this list as a CSV file, oldest first, with the time, camera, result, time taken and details.",
        shortcut: "⇧⌘E", symbol: "square.and.arrow.up")
    static let clearResults = QuickHelpItem(
        title: "Clear Results",
        detail: "Empties this list. Failure images already saved aren't affected.",
        symbol: "trash")

    static func logEntry(_ entry: LogEntry) -> QuickHelpItem {
        QuickHelpItem(title: "\(entry.verdict.rawValue): \(entry.source)", detail: entry.summary, symbol: "list.bullet.rectangle")
    }

    // MARK: The image

    /// Drawing a region, or a description of the image and the pixel under the pointer.
    static func image(pixel: CGPoint?, imageSize: CGSize, isDrawing: Bool, sourceName: String?, isFrozen: Bool, canFocus: Bool, scale: Double?) -> QuickHelpItem {
        if isDrawing {
            return QuickHelpItem(title: "Drawing a Region", detail: "Drag across the image to set the selected tool's region.", symbol: "rectangle.dashed")
        }
        var parts: [String] = []
        if let pixel {
            var position = "Pixel \(Int(pixel.x)), \(Int(pixel.y))"
            if let scale {
                position += String(format: " (%.2f, %.2f mm from the top left)", pixel.x * scale, pixel.y * scale)
            }
            parts.append(position + ".")
        }
        if imageSize.width > 0 { parts.append("The image is \(Int(imageSize.width)) × \(Int(imageSize.height)).") }
        if isFrozen {
            parts.append("It's held still, and tools re-run on it as you change them.")
        } else if canFocus {
            parts.append("Click to focus there.")
        }
        return QuickHelpItem(title: sourceName ?? "Image", detail: parts.joined(separator: " "), symbol: "camera.viewfinder")
    }

    /// What a tool found at a point in the image, from the smallest thing drawn there: a text box rather than the
    /// whole-image rectangle around it. tolerance is how near a line counts, in image pixels.
    static func found(at point: CGPoint, in report: InspectionReport, tolerance: CGFloat) -> QuickHelpItem? {
        var best: (size: CGFloat, overlay: MXVOverlay, tool: ToolReport)?
        for tool in report.tools {
            for overlay in tool.output.overlays {
                let points = overlay.points.map(\.pointValue)
                guard points.count >= 2, let size = hitSize(of: points, closed: overlay.closed, point: point, tolerance: tolerance) else { continue }
                if best == nil || size < best!.size { best = (size, overlay, tool) }
            }
        }
        guard let best else { return nil }
        let name = best.tool.name
        var detail = best.overlay.label.isEmpty ? "Found by \(name)." : "\(name) reads or measures this."
        detail += " The tool's latest result: \(best.tool.verdict.rawValue)."
        if !best.tool.reasons.isEmpty { detail += " " + best.tool.reasons.joined(separator: "; ") + "." }
        return QuickHelpItem(title: best.overlay.label.isEmpty ? name : best.overlay.label, detail: detail, symbol: best.tool.kind.symbol)
    }

    /// nil if the point misses. A line's size is 0, so one under the pointer wins over any box around it.
    private static func hitSize(of points: [CGPoint], closed: Bool, point: CGPoint, tolerance: CGFloat) -> CGFloat? {
        if closed {
            let path = CGMutablePath()
            path.addLines(between: points)
            path.closeSubpath()
            guard path.contains(point) else { return nil }
            let box = path.boundingBox
            return box.width * box.height
        }
        for (a, b) in zip(points, points.dropFirst()) {
            let dx = b.x - a.x, dy = b.y - a.y
            let lengthSquared = dx * dx + dy * dy
            let along = lengthSquared > 0 ? min(1, max(0, ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared)) : 0
            if hypot(point.x - (a.x + along * dx), point.y - (a.y + along * dy)) <= tolerance { return 0 }
        }
        return nil
    }
}
