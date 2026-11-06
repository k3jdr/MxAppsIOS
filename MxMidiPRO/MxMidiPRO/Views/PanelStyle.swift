//
//  PanelStyle.swift — MxMidiPRO
//
//  The look, after MMM (Tim Shoebridge's MIDI Message Monitor module for Voltage Modular): a light-grey module
//  between two rack rails with a thin yellow edge, a dark message screen in monospaced type, small grey push buttons,
//  square lamps, dark selector plates beside 5-pin DIN sockets, colour-square legend toggles and a dark scope.
//

import AppKit
import SwiftUI

enum Panel {
    static let rack = Color(white: 0.09)
    static let faceTop = Color(white: 0.84)
    static let faceBottom = Color(white: 0.76)
    static let edge = Color(red: 0.90, green: 0.84, blue: 0.32)
    static let screen = Color(white: 0.30)
    static let screenLine = Color(white: 0.37)
    static let screenText = Color(white: 0.90)
    static let screenDim = Color(white: 0.62)
    static let ink = Color(white: 0.20)
    static let inkSoft = Color(white: 0.36)
    static let inTint = Color(red: 0.50, green: 0.88, blue: 0.50)
    static let outTint = Color(red: 1.00, green: 0.68, blue: 0.34)
    static let pauseTint = Color(red: 1.00, green: 0.82, blue: 0.25)
    static let lampOff = Color(white: 0.36)

    static let nsScreen = NSColor(white: 0.30, alpha: 1)
    static let nsText = NSColor(white: 0.90, alpha: 1)
    static let nsDim = NSColor(white: 0.64, alpha: 1)
    static let nsIn = NSColor(srgbRed: 0.55, green: 0.90, blue: 0.55, alpha: 1)
    static let nsOut = NSColor(srgbRed: 1.00, green: 0.72, blue: 0.40, alpha: 1)
    static let nsSelection = NSColor(white: 0.45, alpha: 1)
    static let logFont = NSFont(name: "Menlo", size: 11) ?? .monospacedSystemFont(ofSize: 11, weight: .regular)
}

extension Trace {
    var color: Color {
        switch self {
        case .channelPressure: Color(red: 0.96, green: 0.70, blue: 0.24)
        case .polyPressure: Color(red: 0.62, green: 0.88, blue: 0.98)
        case .velocity: Color(red: 0.36, green: 0.84, blue: 0.36)
        case .pitchBend: Color(red: 0.96, green: 0.48, blue: 0.78)
        case .controller: Color(red: 0.74, green: 0.64, blue: 1.00)
        }
    }
}

// MARK: Rack and module

struct RackRail: View {
    var body: some View {
        LinearGradient(stops: [.init(color: Color(white: 0.42), location: 0),
                               .init(color: Color(white: 0.96), location: 0.35),
                               .init(color: Color(white: 0.74), location: 0.7),
                               .init(color: Color(white: 0.38), location: 1)],
                       startPoint: .top, endPoint: .bottom)
            .frame(height: 11)
            .overlay(alignment: .bottom) { Color.black.opacity(0.5).frame(height: 1) }
    }
}

struct ModuleFace<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(10)
            .background(LinearGradient(colors: [Panel.faceTop, Panel.faceBottom], startPoint: .top, endPoint: .bottom))
            .overlay(Rectangle().strokeBorder(Panel.edge, lineWidth: 1.5).padding(3))
            .overlay(Rectangle().strokeBorder(Color.black.opacity(0.55), lineWidth: 1))
    }
}

/// The dark screens the log and the scope sit in.
struct ScreenBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Panel.screen)
            .clipShape(RoundedRectangle(cornerRadius: 2))
            .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Color.black.opacity(0.45), lineWidth: 1))
            .overlay(alignment: .bottom) { Color.white.opacity(0.35).frame(height: 1).offset(y: 1) }
    }
}

extension View {
    func screen() -> some View { modifier(ScreenBackground()) }

    func panelLabel() -> some View {
        font(.system(size: 12)).foregroundStyle(Panel.ink)
    }
}

// MARK: Buttons and lamps

/// MMM's small grey "Reset" button.
struct PanelButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Panel.ink)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .frame(height: 21)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(LinearGradient(colors: configuration.isPressed
                                         ? [Color(white: 0.60), Color(white: 0.70)]
                                         : [Color(white: 0.95), Color(white: 0.71)],
                                         startPoint: .top, endPoint: .bottom))
            )
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color(white: 0.42), lineWidth: 1))
            .contentShape(Rectangle())
    }
}

/// A push-on / push-off panel button with a small lamp, for Pause, IN and OUT.
struct PanelToggle: View {
    let title: String
    @Binding var isOn: Bool
    var tint: Color = Panel.inTint

    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(isOn ? tint : Panel.lampOff)
                    .frame(width: 8, height: 8)
                    .overlay(RoundedRectangle(cornerRadius: 1.5).strokeBorder(Color.black.opacity(0.45), lineWidth: 0.5))
                    .shadow(color: isOn ? tint.opacity(0.9) : .clear, radius: 2)
                Text(title)
            }
        }
        .buttonStyle(PanelButtonStyle())
    }
}

/// MMM's square "To Host" lamp.
struct SquareLamp: View {
    var on: Bool
    var tint: Color = Panel.inTint
    var size: CGFloat = 22

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3)
                .fill(LinearGradient(colors: [Color(white: 0.45), Color(white: 0.80)], startPoint: .top, endPoint: .bottom))
            RoundedRectangle(cornerRadius: 2)
                .fill(on ? tint : Color(white: 0.52))
                .overlay(RoundedRectangle(cornerRadius: 2).fill(
                    LinearGradient(colors: [Color.white.opacity(on ? 0.45 : 0.25), .clear], startPoint: .top, endPoint: .center)))
                .padding(size * 0.2)
                .shadow(color: on ? tint.opacity(0.9) : .clear, radius: on ? 5 : 0)
        }
        .frame(width: size, height: size)
        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color(white: 0.30), lineWidth: 1))
    }
}

/// The dark selector plates ("Nord Wave 2 MIDI", "MIDI Thru").
struct Plate<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .font(.system(size: 12))
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(height: 27)
            .background(RoundedRectangle(cornerRadius: 3)
                .fill(LinearGradient(colors: [Color(white: 0.42), Color(white: 0.30)], startPoint: .top, endPoint: .bottom)))
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color(white: 0.18), lineWidth: 1))
            .overlay(alignment: .top) { Color.white.opacity(0.18).frame(height: 1).padding(.horizontal, 2).offset(y: 1) }
    }
}

/// A 5-pin DIN socket, as on MMM's panel.
struct DINSocket: View {
    var size: CGFloat = 30

    var body: some View {
        Canvas { context, canvas in
            let r = min(canvas.width, canvas.height) / 2
            let c = CGPoint(x: canvas.width / 2, y: canvas.height / 2)
            func circle(_ radius: CGFloat, at p: CGPoint = c) -> Path {
                Path(ellipseIn: CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2))
            }
            context.fill(circle(r), with: .linearGradient(Gradient(colors: [Color(white: 0.96), Color(white: 0.50)]),
                                                          startPoint: CGPoint(x: c.x, y: 0),
                                                          endPoint: CGPoint(x: c.x, y: canvas.height)))
            context.fill(circle(r * 0.84), with: .color(Color(white: 0.20)))
            context.fill(circle(r * 0.70), with: .linearGradient(Gradient(colors: [Color(white: 0.04), Color(white: 0.16)]),
                                                                 startPoint: CGPoint(x: c.x, y: c.y - r),
                                                                 endPoint: CGPoint(x: c.x, y: c.y + r)))
            for degrees in [180.0, 225.0, 270.0, 315.0, 0.0] {
                let a = degrees * .pi / 180
                let p = CGPoint(x: c.x + cos(a) * r * 0.42, y: c.y + sin(a) * r * 0.42 + r * 0.06)
                context.fill(circle(r * 0.085, at: p), with: .color(Color(white: 0.78)))
            }
            context.fill(Path(CGRect(x: c.x - r * 0.09, y: c.y + r * 0.50, width: r * 0.18, height: r * 0.20)),
                         with: .color(Color(white: 0.22)))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A colour square and its name, MMM's trace toggles.
struct LegendToggle: View {
    let trace: Trace
    @Binding var isOn: Bool
    var title: String? = nil

    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(isOn ? trace.color : Color(white: 0.64))
                    .overlay(RoundedRectangle(cornerRadius: 3).fill(
                        LinearGradient(colors: [Color.white.opacity(0.5), .clear], startPoint: .top, endPoint: .center)))
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color(white: 0.38), lineWidth: 1))
                    .frame(width: 16, height: 16)
                Text(title ?? trace.title)
                    .font(.system(size: 12))
                    .foregroundStyle(isOn ? Panel.ink : Panel.inkSoft)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: Logo

struct MxLogo: View {
    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            StripedLetters(text: "Mx", size: 44)
            VStack(alignment: .leading, spacing: 0) {
                Text("MIDI Message Monitor")
                    .font(.system(size: 19))
                    .foregroundStyle(Panel.ink)
                Text("MxMidiPRO  |  Logic Pro ⇄ USB MIDI")
                    .font(.system(size: 11))
                    .foregroundStyle(Panel.inkSoft)
            }
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

/// Heavy condensed letters with fine vertical stripes, like MMM's logo.
struct StripedLetters: View {
    let text: String
    let size: CGFloat

    var body: some View {
        let letters = Text(text).font(.system(size: size, weight: .black).width(.compressed))
        letters
            .foregroundStyle(Color(white: 0.27))
            .overlay {
                Canvas { context, canvas in
                    var x: CGFloat = 1
                    while x < canvas.width {
                        context.fill(Path(CGRect(x: x, y: 0, width: 1, height: canvas.height)),
                                     with: .color(Panel.faceTop.opacity(0.55)))
                        x += 3
                    }
                }
                .mask(letters)
            }
    }
}
