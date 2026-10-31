import CoreGraphics
import Foundation
import UniformTypeIdentifiers

/// Writes extracted outlines for other programs: DXF for CAD, SVG for drawing programs and browsers, CSV for spreadsheets.
enum ContourExport {
    enum Format: String, CaseIterable {
        case dxf, svg, csv

        var contentType: UTType? { UTType(filenameExtension: rawValue) }
    }

    enum ExportError: LocalizedError {
        case unknownFormat(String)

        var errorDescription: String? {
            switch self {
            case .unknownFormat(let name): return "\(name) isn't a format this can write. Use .dxf, .svg or .csv."
            }
        }
    }

    static func extract(tool: ToolConfig, frame: MXVFrame) -> [MXVContour] {
        var roi = CGRect.null
        if let area = tool.roi {
            let size = frame.size
            roi = CGRect(x: area.minX * size.width, y: area.minY * size.height, width: area.width * size.width, height: area.height * size.height).integral
        }
        return MXVEngine.extractContours(in: frame, roi: roi, numbers: tool.engineNumbers.mapValues { NSNumber(value: $0) })
    }

    static func write(_ contours: [MXVContour], imageSize: CGSize, mmPerPixel: Double?, to url: URL) throws {
        guard let format = Format(rawValue: url.pathExtension.lowercased()) else {
            throw ExportError.unknownFormat(url.lastPathComponent)
        }
        let text: String
        switch format {
        case .dxf: text = dxf(contours, imageSize: imageSize, mmPerPixel: mmPerPixel)
        case .svg: text = svg(contours, imageSize: imageSize, mmPerPixel: mmPerPixel)
        case .csv: text = csv(contours, mmPerPixel: mmPerPixel)
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func number(_ value: Double) -> String {
        String(format: "%.4f", value)
    }

    /// DXF R12, which nearly everything reads. Its y axis points up, so the image is turned the right way for CAD.
    static func dxf(_ contours: [MXVContour], imageSize: CGSize, mmPerPixel: Double?) -> String {
        let scale = mmPerPixel ?? 1
        var lines: [String] = [
            "0", "SECTION", "2", "HEADER", "9", "$ACADVER", "1", "AC1009", "0", "ENDSEC",
            "0", "SECTION", "2", "TABLES",
            "0", "TABLE", "2", "LAYER", "70", "3",
        ]
        for (name, color) in [("OUTLINE", "7"), ("HOLE", "1"), ("OPEN", "3")] {
            lines += ["0", "LAYER", "2", name, "70", "0", "62", color, "6", "CONTINUOUS"]
        }
        lines += ["0", "ENDTAB", "0", "ENDSEC", "0", "SECTION", "2", "ENTITIES"]
        for contour in contours {
            let layer = !contour.closed ? "OPEN" : (contour.hole ? "HOLE" : "OUTLINE")
            lines += ["0", "POLYLINE", "8", layer, "66", "1", "70", contour.closed ? "1" : "0", "10", "0", "20", "0", "30", "0"]
            for value in contour.points {
                let p = value.pointValue
                lines += ["0", "VERTEX", "8", layer, "10", number(p.x * scale), "20", number((imageSize.height - p.y) * scale), "30", "0"]
            }
            lines += ["0", "SEQEND", "8", layer]
        }
        lines += ["0", "ENDSEC", "0", "EOF"]
        return lines.joined(separator: "\n") + "\n"
    }

    static func svg(_ contours: [MXVContour], imageSize: CGSize, mmPerPixel: Double?) -> String {
        let scale = mmPerPixel ?? 1
        let width = imageSize.width * scale, height = imageSize.height * scale
        let unit = mmPerPixel == nil ? "" : "mm"
        let stroke = max(width, height) / 1000
        var lines = [
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(number(width))\(unit)\" height=\"\(number(height))\(unit)\" viewBox=\"0 0 \(number(width)) \(number(height))\" fill=\"none\" stroke-width=\"\(number(stroke))\">",
        ]
        for contour in contours {
            let color = !contour.closed ? "#2a9d3a" : (contour.hole ? "#d0342c" : "#000000")
            let points = contour.points.map { value -> String in
                let p = value.pointValue
                return "\(number(p.x * scale)),\(number(p.y * scale))"
            }
            let element = contour.closed ? "polygon" : "polyline"
            lines.append("<\(element) stroke=\"\(color)\" points=\"\(points.joined(separator: " "))\"/>")
        }
        lines.append("</svg>")
        return lines.joined(separator: "\n") + "\n"
    }

    static func csv(_ contours: [MXVContour], mmPerPixel: Double?) -> String {
        let scale = mmPerPixel ?? 1
        let unit = mmPerPixel == nil ? "px" : "mm"
        var lines = ["contour,kind,point,x_\(unit),y_\(unit)"]
        for (index, contour) in contours.enumerated() {
            let kind = !contour.closed ? "open" : (contour.hole ? "hole" : "outline")
            for (pointIndex, value) in contour.points.enumerated() {
                let p = value.pointValue
                lines.append("\(index + 1),\(kind),\(pointIndex + 1),\(number(p.x * scale)),\(number(p.y * scale))")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
