//
//  Style.swift — MxModxUSB
//
//  Shared pieces: cards, labelled values, lamps, knob dials, wheels, and the keyboard with the Parts' zones above it.
//

import SwiftUI

enum Modx {
    static let panel = Color(white: 0.10)
    static let panelLine = Color(white: 0.22)
    static let display = LinearGradient(colors: [Color(red: 0.05, green: 0.12, blue: 0.20),
                                                 Color(red: 0.02, green: 0.06, blue: 0.11)],
                                        startPoint: .top, endPoint: .bottom)
    static let accent = Color(red: 0.95, green: 0.52, blue: 0.18)
    static let live = Color(red: 0.35, green: 0.85, blue: 1.0)
    static let partColors: [Color] = [.orange, .cyan, .green, .pink, .yellow, .purple, .mint, .red,
                                      .teal, .indigo, .brown, .blue, Color(red: 0.8, green: 0.6, blue: 1),
                                      Color(red: 1, green: 0.7, blue: 0.5), .gray, Color(red: 0.6, green: 0.9, blue: 0.4)]

    static func slotColor(_ index: UInt8) -> Color {
        switch index {
        case 0: Color(white: 0.28)
        case 1: .red
        case 2: .yellow
        case 3: .green
        case 4: .blue
        case 5: Color(red: 0.3, green: 0.7, blue: 1)
        case 6: .pink
        case 7: .orange
        case 8: .purple
        case 9: Color(red: 1, green: 0.75, blue: 0.82)
        case 10: Color(red: 1, green: 0.95, blue: 0.8)
        case 11: Color(red: 0.7, green: 1, blue: 0.3)
        case 12: Color(red: 0.4, green: 0.95, blue: 0.9)
        case 13: Color(red: 0.9, green: 0.8, blue: 0.65)
        case 14: Color(red: 0.6, green: 1, blue: 0.75)
        default: Color(red: 0.8, green: 0.7, blue: 1)
        }
    }
}

struct Card<Content: View>: View {
    let title: String
    var systemImage: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(title).font(.headline)
            } icon: {
                if let systemImage { Image(systemName: systemImage).foregroundStyle(Modx.accent) }
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator.opacity(0.6)))
    }
}

struct ValueRow: View {
    let name: String
    let value: String
    var detail: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(name).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value).fontWeight(.medium).multilineTextAlignment(.trailing).textSelection(.enabled)
            if let detail { Text(detail).font(.caption.monospaced()).foregroundStyle(.tertiary) }
        }
        .font(.callout)
    }
}

struct Lamp: View {
    var on: Bool
    var color: Color = .green
    var size: CGFloat = 9

    var body: some View {
        Circle()
            .fill(on ? color : Color(white: 0.35))
            .frame(width: size, height: size)
            .shadow(color: on ? color.opacity(0.8) : .clear, radius: on ? 4 : 0)
    }
}

/// A knob: an arc from 7 to 5 o'clock filled to `value` (0 … 127).
struct Dial: View {
    let value: Int
    let label: String
    var size: CGFloat = 40
    var color: Color = Modx.accent
    var active = false

    var body: some View {
        VStack(spacing: 4) {
            Canvas { context, canvas in
                let rect = CGRect(origin: .zero, size: canvas).insetBy(dx: 3, dy: 3)
                let center = CGPoint(x: rect.midX, y: rect.midY)
                let radius = min(rect.width, rect.height) / 2
                func arc(to fraction: Double) -> Path {
                    var p = Path()
                    p.addArc(center: center, radius: radius, startAngle: .degrees(135),
                             endAngle: .degrees(135 + 270 * fraction), clockwise: false)
                    return p
                }
                context.stroke(arc(to: 1), with: .color(Color(white: 0.3)), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                let fraction = Double(min(max(value, 0), 127)) / 127
                context.stroke(arc(to: fraction), with: .color(active ? Modx.live : color),
                               style: StrokeStyle(lineWidth: 4, lineCap: .round))
                let angle = Angle.degrees(135 + 270 * fraction).radians
                var needle = Path()
                needle.move(to: center)
                needle.addLine(to: CGPoint(x: center.x + cos(angle) * radius * 0.7, y: center.y + sin(angle) * radius * 0.7))
                context.stroke(needle, with: .color(.white.opacity(0.85)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            }
            .frame(width: size, height: size)
            Text(label).font(.system(size: 9)).foregroundStyle(.white.opacity(0.7)).lineLimit(1).frame(width: size + 18)
            Text("\(value)").font(.system(size: 10).monospacedDigit()).foregroundStyle(active ? Modx.live : .white.opacity(0.9))
        }
    }
}

/// A wheel as a vertical bar: pitch bend from the centre, modulation from the bottom.
struct Wheel: View {
    let label: String
    let fraction: Double
    var centered = false

    var body: some View {
        VStack(spacing: 4) {
            Canvas { context, size in
                context.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 4),
                             with: .color(Color(white: 0.18)))
                let f = min(max(fraction, 0), 1)
                if centered {
                    let mid = size.height / 2
                    let y = size.height * (1 - f)
                    context.fill(Path(CGRect(x: 0, y: min(y, mid), width: size.width, height: max(2, abs(y - mid)))),
                                 with: .color(Modx.live))
                    context.fill(Path(CGRect(x: 0, y: mid - 0.5, width: size.width, height: 1)), with: .color(.white.opacity(0.5)))
                } else {
                    let h = size.height * f
                    context.fill(Path(roundedRect: CGRect(x: 0, y: size.height - h, width: size.width, height: h), cornerRadius: 4),
                                 with: .color(Modx.live))
                }
            }
            .frame(width: 16, height: 70)
            Text(label).font(.system(size: 9)).foregroundStyle(.white.opacity(0.7))
        }
    }
}

/// The keyboard, with each Part's note range drawn above it and the keys being played lit.
struct KeyboardView: View {
    let keyCount: Int
    let notes: Set<Int>
    let parts: [ModxPart]

    /// The MODX's lowest key: MODX6 C1 (36), MODX7 E0 (28), MODX8 A-1 (21), in Yamaha's naming.
    var lowNote: Int { keyCount == 61 ? 36 : keyCount == 88 ? 21 : 28 }
    var highNote: Int { lowNote + keyCount - 1 }

    private static let blackKeys: Set<Int> = [1, 3, 6, 8, 10]

    var body: some View {
        let zones = parts.filter { $0.inUse && $0.keyboardControl }
        VStack(spacing: 3) {
            ForEach(zones) { part in zoneBar(part) }
            Canvas { context, size in draw(&context, size) }
                .frame(height: 74)
        }
    }

    private func whiteIndex(_ note: Int) -> Int {
        (lowNote...note).filter { !Self.blackKeys.contains($0 % 12) }.count - 1
    }

    private var whiteCount: Int { (lowNote...highNote).filter { !Self.blackKeys.contains($0 % 12) }.count }

    private func x(_ note: Int, width: CGFloat) -> CGFloat {
        let w = width / CGFloat(whiteCount)
        let n = min(max(note, lowNote), highNote)
        if Self.blackKeys.contains(n % 12) { return CGFloat(whiteIndex(n - 1) + 1) * w }
        return CGFloat(whiteIndex(n)) * w + w / 2
    }

    private func zoneBar(_ part: ModxPart) -> some View {
        GeometryReader { g in
            let from = x(Int(part.noteLow), width: g.size.width)
            let to = x(Int(part.noteHigh), width: g.size.width)
            let color = Modx.partColors[part.index % Modx.partColors.count]
            RoundedRectangle(cornerRadius: 3)
                .fill(color.opacity(part.partSwitch && !part.mute ? 0.75 : 0.25))
                .frame(width: max(6, to - from + 8), height: 12)
                .overlay(alignment: .leading) {
                    Text("\(part.number) \(part.name)").font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.black.opacity(0.8)).padding(.leading, 4).lineLimit(1)
                }
                .offset(x: from - 4)
        }
        .frame(height: 12)
        .help("Part \(part.number) \(part.name): \(part.noteRange)")
    }

    private func draw(_ context: inout GraphicsContext, _ size: CGSize) {
        let w = size.width / CGFloat(whiteCount)
        var i = 0
        for note in lowNote...highNote where !Self.blackKeys.contains(note % 12) {
            let rect = CGRect(x: CGFloat(i) * w + 0.5, y: 0, width: w - 1, height: size.height)
            context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(notes.contains(note) ? Modx.live : .white))
            if note % 12 == 0 {
                context.draw(Text(ModxNames.note(note)).font(.system(size: 8)).foregroundStyle(.gray),
                             at: CGPoint(x: rect.midX, y: size.height - 8))
            }
            i += 1
        }
        for note in lowNote...highNote where Self.blackKeys.contains(note % 12) {
            let left = CGFloat(whiteIndex(note - 1) + 1) * w - w * 0.3
            let rect = CGRect(x: left, y: 0, width: w * 0.6, height: size.height * 0.6)
            context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(notes.contains(note) ? Modx.live : .black))
        }
    }
}
