//
//  DiagramExport.swift
//  MxJobsMGR
//
//  Saves the diagram as a PNG image or as a draw.io SVG (*.drawio.svg): an SVG
//  drawing of the lanes, nodes and links that also carries the diagram as draw.io
//  XML in its `content` attribute, so draw.io / diagrams.net opens it for editing
//  (lanes become swimlanes holding their nodes, links become connectors).
//

import SwiftUI
import UniformTypeIdentifiers

enum DiagramExport {
    // MARK: Save panels

    static func savePNG(space: Jobspace) {
        guard let data = pngData(space: space),
              let url = chooseURL(name: "\(fileBaseName(space)).png", type: .png) else { return }
        write(data, to: url)
    }

    static func saveDrawioSVG(space: Jobspace) {
        guard let url = chooseURL(name: "\(fileBaseName(space)).drawio.svg", type: .svg) else { return }
        write(Data(drawioSVG(space: space).utf8), to: url)
    }

    private static func fileBaseName(_ space: Jobspace) -> String {
        let name = space.name.trimmingCharacters(in: .whitespaces)
        return (name.isEmpty ? "Jobspace" : name).replacingOccurrences(of: "/", with: "-")
    }

    private static func chooseURL(name: String, type: UTType) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = name
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, var url = panel.url else { return nil }
        // Keep the ".drawio" in "name.drawio.svg" if the panel dropped it.
        if name.hasSuffix(".drawio.svg"), !url.lastPathComponent.hasSuffix(".drawio.svg") {
            url = url.deletingPathExtension().appendingPathExtension("drawio.svg")
        }
        return url
    }

    private static func write(_ data: Data, to url: URL) {
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }

    // MARK: PNG

    static func pngData(space: Jobspace) -> Data? {
        let size = Metrics.canvasSize(for: space)
        let content = DiagramContent(
            space: space, selectedNodes: [], selectedLink: nil, issues: [], size: size,
            position: { CGPoint(x: $0.x, y: $0.y) }, dropTargetLayer: nil, rubberBand: nil,
            nodeGesture: { _ in TapGesture() }, handleGesture: { _ in TapGesture() }, onNodeTap: { _ in },
            interactive: false)
            .background(Color.white)
            .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation else { return nil }
        return NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
    }

    // MARK: draw.io SVG

    /// Light-mode colours matching the canvas.
    static func hex(_ layer: Layer) -> String {
        switch layer {
        case .operations: "#5856D6"
        case .agents: "#FF9500"
        case .data: "#30B0C7"
        }
    }

    private static func tint(_ layer: Layer) -> String {
        switch layer {
        case .operations: "#F1F1FC"
        case .agents: "#FFF6EA"
        case .data: "#EDF8FA"
        }
    }

    static func drawioSVG(space: Jobspace) -> String {
        let size = Metrics.canvasSize(for: space)
        let w = Int(size.width), h = Int(size.height)
        let nodeW = Metrics.nodeSize.width, nodeH = Metrics.nodeSize.height
        let font = "-apple-system, 'Helvetica Neue', Helvetica, Arial, sans-serif"
        var svg = """
        <?xml version="1.0" encoding="UTF-8"?>
        <svg xmlns="http://www.w3.org/2000/svg" version="1.1" width="\(w)px" height="\(h)px" \
        viewBox="0 0 \(w) \(h)" content="\(xml(drawioXML(space: space)))">
        <rect x="0" y="0" width="\(w)" height="\(h)" fill="#FFFFFF"/>

        """

        // Lanes with their title column.
        for layer in Layer.allCases {
            let top = Int(Metrics.laneTop(layer)), lh = Int(Metrics.laneHeight), g = Int(Metrics.gutter)
            svg += """
            <rect x="0" y="\(top)" width="\(w)" height="\(lh)" fill="\(tint(layer))"/>
            <rect x="0" y="\(top)" width="\(g)" height="\(lh)" fill="\(hex(layer))" fill-opacity="0.12"/>
            <line x1="0" y1="\(top + lh)" x2="\(w)" y2="\(top + lh)" stroke="\(hex(layer))" stroke-opacity="0.35"/>
            <text x="12" y="\(top + 24)" font-family="\(font)" font-size="11" font-weight="800" fill="\(hex(layer))">LAYER \(layer.rawValue)</text>
            <text x="12" y="\(top + 44)" font-family="\(font)" font-size="14" font-weight="600" fill="#1D1D1F">\(xml(layer.title))</text>

            """
            for (i, line) in wrap(layer.subtitle, width: 24).enumerated() {
                svg += "<text x=\"12\" y=\"\(top + 64 + i * 15)\" font-family=\"\(font)\" font-size=\"11\" fill=\"#6E6E73\">\(xml(line))</text>\n"
            }
        }

        // Links: calls down the layers solid, results up dashed.
        for link in space.links {
            guard let a = space.node(link.from), let b = space.node(link.to) else { continue }
            let g = LinkGeometry(from: CGPoint(x: a.x, y: a.y), to: CGPoint(x: b.x, y: b.y))
            let upward = b.layer.rawValue < a.layer.rawValue
            let color = hex(upward ? b.layer : a.layer)
            svg += "<path d=\"M\(n(g.start.x)),\(n(g.start.y)) C\(n(g.control1.x)),\(n(g.control1.y)) "
                + "\(n(g.control2.x)),\(n(g.control2.y)) \(n(g.end.x)),\(n(g.end.y))\" fill=\"none\" stroke=\"\(color)\" "
                + "stroke-width=\"1.8\" stroke-linecap=\"round\"\(upward ? " stroke-dasharray=\"7 5\"" : "")/>\n"
            let len: CGFloat = 11, spread: CGFloat = .pi / 7
            let p1 = CGPoint(x: g.end.x - len * cos(g.arrowAngle - spread), y: g.end.y - len * sin(g.arrowAngle - spread))
            let p2 = CGPoint(x: g.end.x - len * cos(g.arrowAngle + spread), y: g.end.y - len * sin(g.arrowAngle + spread))
            svg += "<polygon points=\"\(n(g.end.x)),\(n(g.end.y)) \(n(p1.x)),\(n(p1.y)) \(n(p2.x)),\(n(p2.y))\" fill=\"\(color)\"/>\n"
            if !link.label.isEmpty {
                let lw = CGFloat(link.label.count) * 6.2 + 12
                svg += "<rect x=\"\(n(g.mid.x - lw / 2))\" y=\"\(n(g.mid.y - 9))\" width=\"\(n(lw))\" height=\"18\" rx=\"4\" "
                    + "fill=\"#FFFFFF\" stroke=\"\(color)\" stroke-opacity=\"0.5\"/>\n"
                svg += "<text x=\"\(n(g.mid.x))\" y=\"\(n(g.mid.y + 4))\" text-anchor=\"middle\" font-family=\"\(font)\" "
                    + "font-size=\"11\" fill=\"#6E6E73\">\(xml(link.label))</text>\n"
            }
        }

        // Nodes.
        for node in space.nodes {
            let x = node.x - nodeW / 2, y = node.y - nodeH / 2
            let c = hex(node.layer)
            let opacity = node.enabled ? "" : " opacity=\"0.5\""
            svg += """
            <g\(opacity)>
            <rect x="\(n(x))" y="\(n(y))" width="\(n(nodeW))" height="\(n(nodeH))" rx="10" fill="#FFFFFF"/>
            <rect x="\(n(x))" y="\(n(y))" width="\(n(nodeW))" height="\(n(nodeH))" rx="10" fill="\(c)" fill-opacity="0.10" stroke="\(c)" stroke-opacity="0.55"/>
            <path d="M\(n(x + 10)),\(n(y)) A10,10 0 0 0 \(n(x)),\(n(y + 10)) L\(n(x)),\(n(y + nodeH - 10)) A10,10 0 0 0 \(n(x + 10)),\(n(y + nodeH)) L\(n(x + 4)),\(n(y + nodeH)) L\(n(x + 4)),\(n(y)) Z" fill="\(c)"/>
            <text x="\(n(x + 12))" y="\(n(y + 19))" font-family="\(font)" font-size="9" font-weight="700" fill="\(c)">\(xml(node.kind.title.uppercased()))</text>
            <text x="\(n(x + 12))" y="\(n(y + 40))" font-family="\(font)" font-size="13" font-weight="600" fill="#1D1D1F">\(xml(clip(node.title, 26)))</text>
            <text x="\(n(x + 12))" y="\(n(y + 60))" font-family="\(font)" font-size="11" fill="#6E6E73">\(xml(clip(NodeSummary.text(for: node, in: space), 32)))</text>
            </g>

            """
        }
        svg += "</svg>\n"
        return svg
    }

    /// The diagram as an uncompressed draw.io file: one swimlane per layer, nodes inside
    /// their lane, links as connectors between them.
    static func drawioXML(space: Jobspace) -> String {
        let size = Metrics.canvasSize(for: space)
        let nodeW = Metrics.nodeSize.width, nodeH = Metrics.nodeSize.height
        var cells = "<mxCell id=\"0\"/><mxCell id=\"1\" parent=\"0\"/>"

        for layer in Layer.allCases {
            let style = "swimlane;horizontal=0;startSize=\(Int(Metrics.gutter));html=1;whiteSpace=wrap;"
                + "fillColor=\(hex(layer));fontColor=#FFFFFF;swimlaneFillColor=\(tint(layer));"
                + "strokeColor=\(hex(layer));fontSize=14;fontStyle=1;"
            let label = "Layer \(layer.rawValue)<br>\(layer.title)"
            cells += "<mxCell id=\"lane-\(layer.rawValue)\" value=\"\(xml(label))\" style=\"\(style)\" vertex=\"1\" parent=\"1\">"
                + "<mxGeometry x=\"0\" y=\"\(n(Metrics.laneTop(layer)))\" width=\"\(n(size.width))\" "
                + "height=\"\(n(Metrics.laneHeight))\" as=\"geometry\"/></mxCell>"
        }

        for node in space.nodes {
            let c = hex(node.layer)
            let value = "<font style=\"font-size:9px\" color=\"\(c)\"><b>\(html(node.kind.title.uppercased()))</b></font><br>"
                + "<b>\(html(node.title))</b><br>"
                + "<font style=\"font-size:10px\" color=\"#6E6E73\">\(html(NodeSummary.text(for: node, in: space)))</font>"
            let style = "rounded=1;arcSize=12;whiteSpace=wrap;html=1;align=left;verticalAlign=top;spacingLeft=10;"
                + "spacingTop=2;fillColor=#FFFFFF;strokeColor=\(c);fontSize=12;"
                + (node.enabled ? "" : "opacity=50;")
            let x = node.x - nodeW / 2
            let y = node.y - nodeH / 2 - Metrics.laneTop(node.layer)
            cells += "<mxCell id=\"\(node.id.uuidString)\" value=\"\(xml(value))\" style=\"\(style)\" vertex=\"1\" "
                + "parent=\"lane-\(node.layer.rawValue)\"><mxGeometry x=\"\(n(x))\" y=\"\(n(y))\" width=\"\(n(nodeW))\" "
                + "height=\"\(n(nodeH))\" as=\"geometry\"/></mxCell>"
        }

        for link in space.links {
            guard let a = space.node(link.from), let b = space.node(link.to) else { continue }
            let upward = b.layer.rawValue < a.layer.rawValue
            let style = "edgeStyle=orthogonalEdgeStyle;curved=1;rounded=1;html=1;endArrow=block;endFill=1;"
                + "strokeColor=\(hex(upward ? b.layer : a.layer));strokeWidth=2;fontSize=11;labelBackgroundColor=#FFFFFF;"
                + (upward ? "dashed=1;" : "")
            cells += "<mxCell id=\"\(link.id.uuidString)\" value=\"\(xml(link.label))\" style=\"\(style)\" edge=\"1\" "
                + "parent=\"1\" source=\"\(link.from.uuidString)\" target=\"\(link.to.uuidString)\">"
                + "<mxGeometry relative=\"1\" as=\"geometry\"/></mxCell>"
        }

        let stamp = ISO8601DateFormatter().string(from: Date())
        return "<mxfile host=\"MxJobsMGR\" modified=\"\(stamp)\" agent=\"MxJobsMGR\" version=\"24.0.0\">"
            + "<diagram id=\"jobspace\" name=\"\(xml(space.name))\">"
            + "<mxGraphModel dx=\"\(Int(size.width))\" dy=\"\(Int(size.height))\" grid=\"1\" gridSize=\"10\" guides=\"1\" "
            + "tooltips=\"1\" connect=\"1\" arrows=\"1\" fold=\"1\" page=\"0\" pageScale=\"1\" math=\"0\" shadow=\"0\">"
            + "<root>\(cells)</root></mxGraphModel></diagram></mxfile>"
    }

    // MARK: Helpers

    /// Escapes text for XML attributes and content.
    static func xml(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "\n", with: "&#10;")
    }

    /// Escapes text placed inside a draw.io html=1 label.
    private static func html(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func n(_ v: CGFloat) -> String {
        let r = (v * 10).rounded() / 10
        return r == r.rounded() ? String(Int(r)) : String(format: "%.1f", r)
    }

    private static func n(_ v: Double) -> String { n(CGFloat(v)) }

    private static func clip(_ s: String, _ max: Int) -> String {
        s.count <= max ? s : String(s.prefix(max - 1)) + "…"
    }

    private static func wrap(_ s: String, width: Int) -> [String] {
        var lines: [String] = [], line = ""
        for word in s.split(separator: " ") {
            if !line.isEmpty, line.count + word.count + 1 > width {
                lines.append(line)
                line = ""
            }
            line += (line.isEmpty ? "" : " ") + word
        }
        if !line.isEmpty { lines.append(line) }
        return lines
    }
}
