//
//  PointerGuard.swift
//  MxNoteONE
//
//  Keeps the text cursor from sticking. With mouse-moved events on (Quick Help turns them on for every window), the
//  window sends each move to its first responder wherever the pointer is — so the text view being typed in set
//  the I-beam again over the ribbon, the toolbar and the menus. Text views now leave the pointer alone outside
//  themselves, and after each move this checks that an I-beam showing is over text (a text view or field, or a
//  view that sets its own pointer, such as a table's cells); otherwise it's the arrow again.
//

import AppKit

/// A view that sets the pointer itself (the guard leaves the pointer to it).
protocol SetsOwnPointer: AnyObject {}

extension NSView {
    /// Whether an event's pointer is over the part of the view that shows. (Views don't clip to their bounds, so
    /// the visible rect alone can reach past them — over the whole page for a text box on it.)
    func pointerInside(_ event: NSEvent) -> Bool {
        guard event.window === window else { return false }
        let p = convert(event.locationInWindow, from: nil)
        return bounds.contains(p) && visibleRect.contains(p)
    }

    /// Whether the view is the one under the pointer — not covered there by another view (a container's resize
    /// edge over its content, a note being typed in).
    func isUnderPointer(_ event: NSEvent) -> Bool {
        guard pointerInside(event), let frame = window?.contentView?.superview,
              let hit = frame.hitTest(frame.convert(event.locationInWindow, from: nil)) else { return false }
        return hit === self || hit.isDescendant(of: self)
    }
}

@MainActor
enum PointerGuard {
    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .mouseExited, .cursorUpdate]) { event in
            let window = event.window
            DispatchQueue.main.async { MainActor.assumeIsolated { check(window) } }
            return event
        }
    }

    /// The arrow again when an I-beam is showing over something that isn't text.
    static func check(_ window: NSWindow?) {
        let current = NSCursor.current
        guard current == NSCursor.iBeam || current == NSCursor.iBeamCursorForVerticalLayout else { return }
        guard let window = window ?? NSApp.keyWindow, let content = window.contentView else { return }
        let p = window.mouseLocationOutsideOfEventStream
        if let frame = content.superview, var view = frame.hitTest(frame.convert(p, from: nil)) {
            while true {
                if view is NSTextView || view is NSTextField || view is SetsOwnPointer { return }
                guard let up = view.superview else { break }
                view = up
            }
        }
        NSCursor.arrow.set()
    }
}
