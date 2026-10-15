//
//  ColorPicking.swift
//  MxNoteONE
//
//  Any colour, not only the palette's: "More Colors…" opens the macOS colour
//  picker for table shading, cell text and chart colours, and the colours
//  picked there are remembered as Recent Colors in the menus.
//

import AppKit
import Observation

/// Colours picked with More Colors…, most recent first.
@Observable
final class RecentColors {
    static let shared = RecentColors()
    private static let key = "recentCustomColors"
    private static let limit = 8

    private(set) var colors: [NSColor] = (UserDefaults.standard.stringArray(forKey: key) ?? []).compactMap(RecentColors.color)

    func add(_ color: NSColor) {
        let hex = Self.hex(color)
        var list = colors.map(Self.hex).filter { $0 != hex }
        list.insert(hex, at: 0)
        list = Array(list.prefix(Self.limit))
        UserDefaults.standard.set(list, forKey: Self.key)
        colors = list.compactMap(Self.color)
    }

    static func hex(_ color: NSColor) -> String {
        let c = color.usingColorSpace(.sRGB) ?? color
        return String(format: "%02X%02X%02X", Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()),
                      Int((c.blueComponent * 255).rounded()))
    }

    private static func color(_ hex: String) -> NSColor? {
        guard hex.count == 6, let v = UInt32(hex, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                       blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}

/// The macOS colour picker, applying the colour chosen to whatever asked for it (while that's still there).
final class ColorPicker: NSObject {
    static let shared = ColorPicker()

    private var apply: ((NSColor) -> Void)?
    private var isValid: (() -> Bool)?
    private var closeObserver: NSObjectProtocol?
    private var ownsPanel = false

    /// Opens the colour picker; each colour chosen (when the mouse is let go) is applied and remembered.
    func pick(_ title: String, initial: NSColor? = nil, isValid: @escaping () -> Bool = { true },
              apply: @escaping (NSColor) -> Void) {
        let panel = NSColorPanel.shared
        stop()
        panel.showsAlpha = false
        panel.isContinuous = false
        if let initial { panel.color = initial }
        self.apply = apply
        self.isValid = isValid
        panel.setTarget(self)
        panel.setAction(#selector(colorChanged(_:)))
        ownsPanel = true
        panel.title = title
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: panel,
                                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func colorChanged(_ panel: NSColorPanel) {
        guard let apply, isValid?() ?? false else { return stop() }
        let color = panel.color.usingColorSpace(.sRGB) ?? panel.color
        apply(color)
        RecentColors.shared.add(color)
    }

    /// Later colours from the picker go to text again (as usual), not here.
    func stop() {
        let panel = NSColorPanel.shared
        if ownsPanel {
            panel.setTarget(nil)
            panel.setAction(nil)
            panel.title = "Colors"
            ownsPanel = false
        }
        apply = nil
        isValid = nil
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
    }

    #if DEBUG
    /// Self-tests: as if the colour were chosen in the picker.
    func choose(_ color: NSColor) {
        NSColorPanel.shared.color = color
        colorChanged(NSColorPanel.shared)
    }
    #endif
}

extension Palette {
    /// Menu items for colours picked before, and More Colors… (for an AppKit palette menu).
    static func customItems(_ title: String, isValid: @escaping () -> Bool, apply: @escaping (NSColor) -> Void) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        let recent = RecentColors.shared.colors
        if !recent.isEmpty {
            items.append(.separator())
            let header = NSMenuItem(title: "Recent Colors", action: nil, keyEquivalent: "")
            header.isEnabled = false
            items.append(header)
            for color in recent {
                let item = ClosureMenuItem("#" + RecentColors.hex(color)) { apply(color) }
                item.image = swatch(color)
                items.append(item)
            }
        }
        items.append(.separator())
        items.append(ClosureMenuItem("More Colors…") {
            ColorPicker.shared.pick(title, isValid: isValid, apply: apply)
        })
        return items
    }
}
