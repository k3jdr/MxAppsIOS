// make-icon.swift — draws MxModxUSB's app icon (a dark instrument panel: a blue display, an orange knob, keys)
// into MxModxUSB/Assets.xcassets/AppIcon.appiconset.
//
//     swift Tools/make-icon.swift MxModxUSB/Assets.xcassets/AppIcon.appiconset

import AppKit

let folder = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")

func draw(_ size: CGFloat) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024
    func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect { NSRect(x: x * s, y: y * s, width: w * s, height: h * s) }

    let tile = NSBezierPath(roundedRect: r(100, 100, 824, 824), xRadius: 185 * s, yRadius: 185 * s)
    NSGradient(starting: NSColor(white: 0.20, alpha: 1), ending: NSColor(white: 0.07, alpha: 1))!.draw(in: tile, angle: -90)

    // Display.
    let display = NSBezierPath(roundedRect: r(190, 590, 644, 230), xRadius: 26 * s, yRadius: 26 * s)
    NSGradient(starting: NSColor(srgbRed: 0.07, green: 0.20, blue: 0.33, alpha: 1),
               ending: NSColor(srgbRed: 0.02, green: 0.08, blue: 0.15, alpha: 1))!.draw(in: display, angle: -90)
    NSColor(srgbRed: 0.35, green: 0.85, blue: 1.0, alpha: 1).setFill()
    NSBezierPath(roundedRect: r(240, 730, 380, 40), xRadius: 12 * s, yRadius: 12 * s).fill()
    NSColor(srgbRed: 0.35, green: 0.85, blue: 1.0, alpha: 0.55).setFill()
    NSBezierPath(roundedRect: r(240, 650, 250, 30), xRadius: 10 * s, yRadius: 10 * s).fill()

    // Knob.
    let c = NSPoint(x: 735 * s, y: 685 * s)
    let ring = NSBezierPath()
    ring.appendArc(withCenter: c, radius: 62 * s, startAngle: 225, endAngle: -45 + 360 * 0, clockwise: true)
    ring.lineWidth = 22 * s
    ring.lineCapStyle = .round
    NSColor(srgbRed: 0.95, green: 0.52, blue: 0.18, alpha: 1).setStroke()
    ring.stroke()

    // Keys.
    let keys = r(190, 200, 644, 330)
    NSColor.white.setFill()
    NSBezierPath(roundedRect: keys, xRadius: 16 * s, yRadius: 16 * s).fill()
    NSColor(white: 0.07, alpha: 1).setFill()
    let white = keys.width / 7
    for i in 1..<7 { NSBezierPath(rect: NSRect(x: keys.minX + CGFloat(i) * white - 3 * s, y: keys.minY, width: 6 * s, height: keys.height)).fill() }
    for i in [0, 1, 3, 4, 5] {
        let x = keys.minX + CGFloat(i + 1) * white - white * 0.3
        NSBezierPath(roundedRect: NSRect(x: x, y: keys.minY + keys.height * 0.4, width: white * 0.6, height: keys.height * 0.6),
                     xRadius: 8 * s, yRadius: 8 * s).fill()
    }
    NSColor(srgbRed: 0.35, green: 0.85, blue: 1.0, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: keys.minX + 2 * white + 6 * s, y: keys.minY + 8 * s, width: white - 12 * s,
                                     height: keys.height * 0.36), xRadius: 8 * s, yRadius: 8 * s).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

var images: [String] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try! draw(CGFloat(points * scale)).write(to: folder.appendingPathComponent(name))
        images.append("    { \"filename\" : \"\(name)\", \"idiom\" : \"mac\", \"scale\" : \"\(scale)x\", \"size\" : \"\(points)x\(points)\" }")
    }
}
let contents = "{\n  \"images\" : [\n" + images.joined(separator: ",\n") + "\n  ],\n  \"info\" : { \"author\" : \"xcode\", \"version\" : 1 }\n}\n"
try! contents.write(to: folder.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
print("wrote \(images.count) icons to \(folder.path)")
