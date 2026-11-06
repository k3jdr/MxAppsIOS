// make-icon.swift — draws MxMidiPRO's app icon (a grey module tile with a scope trace, a lamp and a DIN socket)
// into MxMidiPRO/Assets.xcassets/AppIcon.appiconset.
//
//     swift Tools/make-icon.swift MxMidiPRO/Assets.xcassets/AppIcon.appiconset

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

    // Tile: the macOS icon grid's 824-point rounded square.
    let tile = NSBezierPath(roundedRect: r(100, 100, 824, 824), xRadius: 185 * s, yRadius: 185 * s)
    NSGradient(starting: NSColor(white: 0.88, alpha: 1), ending: NSColor(white: 0.70, alpha: 1))!.draw(in: tile, angle: -90)
    NSColor(srgbRed: 0.90, green: 0.84, blue: 0.32, alpha: 1).setStroke()
    let edge = NSBezierPath(roundedRect: r(122, 122, 780, 780), xRadius: 165 * s, yRadius: 165 * s)
    edge.lineWidth = 10 * s
    edge.stroke()

    // Scope screen with a velocity step line and a pressure curve.
    let screen = NSBezierPath(roundedRect: r(190, 520, 644, 300), xRadius: 18 * s, yRadius: 18 * s)
    NSColor(white: 0.30, alpha: 1).setFill()
    screen.fill()
    let step = NSBezierPath()
    let steps: [(CGFloat, CGFloat)] = [(190, 600), (300, 600), (300, 700), (420, 700), (420, 650), (560, 650), (560, 760), (700, 760), (700, 690), (834, 690)]
    step.move(to: NSPoint(x: steps[0].0 * s, y: steps[0].1 * s))
    for p in steps.dropFirst() { step.line(to: NSPoint(x: p.0 * s, y: p.1 * s)) }
    step.lineWidth = 14 * s
    NSColor(srgbRed: 0.36, green: 0.84, blue: 0.36, alpha: 1).setStroke()
    step.stroke()
    let curve = NSBezierPath()
    curve.move(to: NSPoint(x: 200 * s, y: 545 * s))
    curve.curve(to: NSPoint(x: 400 * s, y: 545 * s), controlPoint1: NSPoint(x: 280 * s, y: 545 * s), controlPoint2: NSPoint(x: 300 * s, y: 800 * s))
    curve.curve(to: NSPoint(x: 620 * s, y: 545 * s), controlPoint1: NSPoint(x: 480 * s, y: 545 * s), controlPoint2: NSPoint(x: 520 * s, y: 720 * s))
    curve.line(to: NSPoint(x: 824 * s, y: 545 * s))
    curve.lineWidth = 12 * s
    NSColor(srgbRed: 0.96, green: 0.70, blue: 0.24, alpha: 1).setStroke()
    curve.stroke()

    // Lamp.
    NSColor(white: 0.45, alpha: 1).setFill()
    NSBezierPath(roundedRect: r(200, 230, 170, 170), xRadius: 18 * s, yRadius: 18 * s).fill()
    NSColor(srgbRed: 0.45, green: 0.92, blue: 0.45, alpha: 1).setFill()
    NSBezierPath(roundedRect: r(232, 262, 106, 106), xRadius: 12 * s, yRadius: 12 * s).fill()

    // DIN socket.
    let c = NSPoint(x: 640 * s, y: 315 * s)
    func circle(_ radius: CGFloat, _ at: NSPoint = c) -> NSBezierPath {
        NSBezierPath(ovalIn: NSRect(x: at.x - radius * s, y: at.y - radius * s, width: radius * 2 * s, height: radius * 2 * s))
    }
    NSGradient(starting: NSColor(white: 0.97, alpha: 1), ending: NSColor(white: 0.45, alpha: 1))!.draw(in: circle(170), angle: -90)
    NSColor(white: 0.18, alpha: 1).setFill()
    circle(142).fill()
    NSColor(white: 0.06, alpha: 1).setFill()
    circle(118).fill()
    NSColor(white: 0.80, alpha: 1).setFill()
    for degrees in [180.0, 135.0, 90.0, 45.0, 0.0] {
        let a = degrees * .pi / 180
        circle(16, NSPoint(x: c.x + cos(a) * 72 * s, y: c.y + sin(a) * 72 * s - 10 * s)).fill()
    }
    NSColor(white: 0.20, alpha: 1).setFill()
    NSBezierPath(rect: NSRect(x: c.x - 14 * s, y: c.y - 118 * s, width: 28 * s, height: 30 * s)).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

var images: [String] = []
for (points, scales) in [(16, [1, 2]), (32, [1, 2]), (128, [1, 2]), (256, [1, 2]), (512, [1, 2])] {
    for scale in scales {
        let pixels = points * scale
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try! draw(CGFloat(pixels)).write(to: folder.appendingPathComponent(name))
        images.append("""
            { "filename" : "\(name)", "idiom" : "mac", "scale" : "\(scale)x", "size" : "\(points)x\(points)" }
        """)
    }
}
let contents = "{\n  \"images\" : [\n" + images.joined(separator: ",\n") + "\n  ],\n  \"info\" : { \"author\" : \"xcode\", \"version\" : 1 }\n}\n"
try! contents.write(to: folder.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
print("wrote \(images.count) icons to \(folder.path)")
