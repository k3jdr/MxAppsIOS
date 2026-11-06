// make-icon.swift — draws MxModxUSB's app icon (a crimson tile: the USB symbol above a synthesizer with its display,
// knobs and keys — a MODX over USB) into MxModxUSB/Assets.xcassets/AppIcon.appiconset.
//
//     swift Tools/make-icon.swift MxModxUSB/Assets.xcassets/AppIcon.appiconset [preview.png]
//
// With a second argument it also writes a 1024-pixel preview there.

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
    func pt(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x * s, y: y * s) }
    func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
    let small = size <= 64   // fewer details where they would only blur

    // Tile, in the family's shape: crimson, lighter at the top.
    let tile = NSBezierPath(roundedRect: r(100, 100, 824, 824), xRadius: 185 * s, yRadius: 185 * s)
    NSGradient(starting: rgb(0.93, 0.27, 0.32), ending: rgb(0.58, 0.07, 0.15))!.draw(in: tile, angle: -90)

    // The USB symbol, white: a stem with an arrowhead, a circle at its foot, a branch ending in a circle and one in a square.
    let white = NSColor.white
    white.setStroke(); white.setFill()
    let w: CGFloat = (small ? 40 : 30) * s
    func line(_ points: [NSPoint]) {
        let path = NSBezierPath()
        path.move(to: points[0]); for p in points.dropFirst() { path.line(to: p) }
        path.lineWidth = w; path.lineCapStyle = .round; path.lineJoinStyle = .round
        path.stroke()
    }
    line([pt(512, 572), pt(512, 780)])
    let head = NSBezierPath()
    head.move(to: pt(512, 862)); head.line(to: pt(456, 770)); head.line(to: pt(568, 770)); head.close()
    head.fill()
    NSBezierPath(ovalIn: r(512 - 34, 572 - 34, 68, 68)).fill()
    line([pt(512, 628), pt(408, 700), pt(408, 728)])
    NSBezierPath(ovalIn: r(408 - 30, 745 - 30, 60, 60)).fill()
    line([pt(512, 664), pt(616, 736), pt(616, 770)])
    NSBezierPath(rect: r(616 - 29, 788 - 29, 58, 58)).fill()

    // The synthesizer: a dark body, its display and knobs, and the keys.
    let body = NSBezierPath(roundedRect: r(160, 170, 704, 326), xRadius: 44 * s, yRadius: 44 * s)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(white: 0, alpha: 0.35); shadow.shadowBlurRadius = 24 * s; shadow.shadowOffset = NSSize(width: 0, height: -8 * s)
    shadow.set()
    NSColor(white: 0.08, alpha: 1).setFill()
    body.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: NSColor(white: 0.20, alpha: 1), ending: NSColor(white: 0.05, alpha: 1))!.draw(in: body, angle: -90)

    let display = NSBezierPath(roundedRect: r(204, 402, 236, 68), xRadius: 12 * s, yRadius: 12 * s)
    NSGradient(starting: rgb(0.40, 0.86, 1.0), ending: rgb(0.13, 0.50, 0.82))!.draw(in: display, angle: -90)
    if !small {
        rgb(0.03, 0.15, 0.30, 0.75).setFill()
        NSBezierPath(roundedRect: r(224, 442, 128, 13), xRadius: 6 * s, yRadius: 6 * s).fill()
        NSBezierPath(roundedRect: r(224, 418, 84, 11), xRadius: 5 * s, yRadius: 5 * s).fill()
    }
    for (i, x) in [520, 602, 684, 766].enumerated() {
        let c = pt(CGFloat(x), 436)
        NSColor(white: 0.62, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: c.x - 25 * s, y: c.y - 25 * s, width: 50 * s, height: 50 * s)).fill()
        if !small {
            let angle = [-35.0, 20.0, -70.0, 45.0][i] * .pi / 180 + .pi / 2
            NSColor(white: 0.12, alpha: 1).setStroke()
            let mark = NSBezierPath()
            mark.move(to: c); mark.line(to: NSPoint(x: c.x + cos(angle) * 20 * s, y: c.y + sin(angle) * 20 * s))
            mark.lineWidth = 7 * s; mark.lineCapStyle = .round
            mark.stroke()
        }
    }

    let keys = r(190, 196, 644, 180)
    let keyShape = NSBezierPath(roundedRect: keys, xRadius: 16 * s, yRadius: 16 * s)
    NSColor(white: 0.97, alpha: 1).setFill()
    keyShape.fill()
    let count = small ? 7 : 11
    let key = keys.width / CGFloat(count)
    NSColor(white: 0.10, alpha: 1).setFill()
    for i in 1..<count {
        NSBezierPath(rect: NSRect(x: keys.minX + CGFloat(i) * key - 2.5 * s, y: keys.minY, width: 5 * s, height: keys.height)).fill()
    }
    for i in [0, 1, 3, 4, 5, 7, 8] where i < count - 1 {
        let x = keys.minX + CGFloat(i + 1) * key - key * 0.31
        NSBezierPath(roundedRect: NSRect(x: x, y: keys.minY + keys.height * 0.40, width: key * 0.62, height: keys.height * 0.60),
                     xRadius: 6 * s, yRadius: 6 * s).fill()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

if CommandLine.arguments.count > 2 {
    try! draw(1024).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
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
