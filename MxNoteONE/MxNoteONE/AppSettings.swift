//
//  AppSettings.swift
//  MxNoteONE
//
//  User preferences (kept in UserDefaults) and the editor state shared by
//  the ribbon, the menus and the page canvas.
//

import AppKit
import Observation

enum Prefs {
    static let fontNameKey = "defaultFontName"
    static let fontSizeKey = "defaultFontSize"
    static let pageColorKey = "defaultPageColor"
    static let ruleLinesKey = "defaultRuleLines"
    static let notebooksFolderKey = "notebooksFolder"
    static let autoLockKey = "autoLockMinutes"
    static let openNotebooksKey = "openNotebooks"
    static let newTextBoxKey = "newTextBoxOnClick"

    /// What a click on an empty part of the page does.
    enum NewTextBox: String, CaseIterable, Identifiable {
        case click, doubleClick, menu
        var id: String { rawValue }
        var title: String {
            switch self {
            case .click: "A click starts a new text box (as in OneNote)"
            case .doubleClick: "A double-click starts a new text box"
            case .menu: "Clicking does nothing (right-click ▸ New Text Box Here)"
            }
        }
        var menuTitle: String {
            switch self {
            case .click: "Click Starts a New Text Box"
            case .doubleClick: "Double-Click Starts a New Text Box"
            case .menu: "Clicking Does Nothing"
            }
        }
    }

    static var newTextBox: NewTextBox {
        get { NewTextBox(rawValue: UserDefaults.standard.string(forKey: newTextBoxKey) ?? "") ?? .click }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: newTextBoxKey) }
    }

    private static var defaults: UserDefaults { .standard }

    static var fontName: String {
        defaults.string(forKey: fontNameKey) ?? "Helvetica Neue"
    }

    static var fontSize: CGFloat {
        let size = defaults.double(forKey: fontSizeKey)
        return size > 0 ? size : 14
    }

    static var defaultFont: NSFont {
        NSFont(name: fontName, size: fontSize) ?? .systemFont(ofSize: fontSize)
    }

    static var pageColor: PageColor {
        PageColor(rawValue: defaults.string(forKey: pageColorKey) ?? "") ?? .none
    }

    static var ruleLines: RuleLines {
        RuleLines(rawValue: defaults.string(forKey: ruleLinesKey) ?? "") ?? .none
    }

    /// Where new notebooks are created.
    static var notebooksFolder: URL {
        if let path = defaults.string(forKey: notebooksFolderKey), !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appending(path: "MxNoteONE Notebooks", directoryHint: .isDirectory)
    }

    /// Lock password-protected sections after this many minutes away from the app (0 = never).
    static var autoLockMinutes: Int {
        defaults.object(forKey: autoLockKey) == nil ? 10 : defaults.integer(forKey: autoLockKey)
    }

    /// Folders of the OneDrive accounts signed in with the OneDrive app.
    static var oneDriveFolders: [URL] {
        let cloud = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/CloudStorage")
        let items = (try? FileManager.default.contentsOfDirectory(at: cloud, includingPropertiesForKeys: nil)) ?? []
        return items.filter { $0.lastPathComponent.hasPrefix("OneDrive") }.sorted { $0.path < $1.path }
    }

    static let snapToGridKey = "snapToGrid"

    static let oneDriveAutoSyncKey = "oneDriveAutoSyncMinutes"

    /// Sync OneDrive notebooks automatically every so many minutes (0 = only when asked).
    static var oneDriveAutoSyncMinutes: Int {
        defaults.integer(forKey: oneDriveAutoSyncKey)
    }

    static var openNotebookPaths: [String] {
        get { defaults.stringArray(forKey: openNotebooksKey) ?? [] }
        set { defaults.set(newValue, forKey: openNotebooksKey) }
    }
}

enum RibbonTab: String, CaseIterable, Identifiable {
    case home = "Home", insert = "Insert", draw = "Draw", view = "View", table = "Table", score = "Score", map = "Map", dbml = "DBML"
    var id: String { rawValue }
}

/// What a mouse drag on the page does.
enum CanvasTool: String, CaseIterable, Identifiable {
    case type, lasso, pen, highlighter, eraser, line, arrow, rectangle, ellipse

    var id: String { rawValue }

    var title: String {
        switch self {
        case .type: "Type"
        case .pen: "Pen"
        case .highlighter: "Highlighter"
        case .eraser: "Eraser"
        case .lasso: "Lasso Select"
        case .line: "Line"
        case .arrow: "Arrow"
        case .rectangle: "Rectangle"
        case .ellipse: "Ellipse"
        }
    }

    var symbol: String {
        switch self {
        case .type: "character.cursor.ibeam"
        case .pen: "pencil.tip"
        case .highlighter: "highlighter"
        case .eraser: "eraser"
        case .lasso: "lasso"
        case .line: "line.diagonal"
        case .arrow: "arrow.up.right"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        }
    }

    var isInk: Bool { self != .type }

    var strokeTool: InkStroke.Tool? {
        switch self {
        case .pen: .pen
        case .highlighter: .highlighter
        case .line: .line
        case .arrow: .arrow
        case .rectangle: .rectangle
        case .ellipse: .ellipse
        case .type, .eraser, .lasso: nil
        }
    }
}

@Observable
final class EditorState {
    var ribbonTab: RibbonTab = .home
    /// A table is being edited or has selected cells (shows the Table ribbon tab).
    var tableActive = false
    /// A music score is being edited (the Score ribbon tab shows), or playing.
    var scoreActive = false
    var scorePlaying = false
    /// Bumped when the length or dot for new notes changes (the Score tab shows it).
    var scoreInputChanged = 0
    /// A map is being worked on (the Map ribbon tab shows); clicks on it drop pins; bumped when it changes.
    var mapActive = false
    var mapDropping = false
    var mapChanged = 0
    /// A DBML diagram is being worked on (the DBML ribbon tab shows); bumped when it or its selection changes.
    var dbmlActive = false
    var dbmlChanged = 0
    var showRibbon = true
    var tool: CanvasTool = .type {
        didSet { NotebookStore.shared.canvas?.toolChanged() }
    }
    var penColor = RGBA.black
    var penWidth: Double = 2
    var highlighterColor = RGBA(r: 1, g: 0.92, b: 0.2, a: 0.45)
    var highlighterWidth: Double = 14

    var showFindBar = false
    var findText = ""
    var findStatus = ""
    var findFocusRequest = 0

    var isRecording = false
    var recordingSeconds = 0

    var zoom: Double = 1

    // Formatting of the selected text, shown in the Home ribbon (nil = the selection mixes several).
    var fontFamily: String? = Prefs.fontName
    var fontSize: CGFloat? = Prefs.fontSize
    var isBold = false
    var isItalic = false
    var isUnderline = false
    var isStrikethrough = false

    /// View ▸ Snap to Grid: containers, pictures and shapes line up on the page grid (hold ⌥ to place freely).
    var snapToGrid = UserDefaults.standard.bool(forKey: Prefs.snapToGridKey) {
        didSet {
            UserDefaults.standard.set(snapToGrid, forKey: Prefs.snapToGridKey)
            NotebookStore.shared.canvas?.canvas.needsDisplay = true
        }
    }
}

/// Palette used by the ribbon colour menus.
enum Palette {
    static let text: [(String, NSColor)] = [
        ("Black", .black),
        ("Dark Gray", NSColor(white: 0.35, alpha: 1)),
        ("Red", NSColor(srgbRed: 0.80, green: 0.10, blue: 0.10, alpha: 1)),
        ("Orange", NSColor(srgbRed: 0.90, green: 0.45, blue: 0.05, alpha: 1)),
        ("Green", NSColor(srgbRed: 0.10, green: 0.55, blue: 0.20, alpha: 1)),
        ("Blue", NSColor(srgbRed: 0.10, green: 0.35, blue: 0.80, alpha: 1)),
        ("Purple", NSColor(srgbRed: 0.45, green: 0.20, blue: 0.70, alpha: 1)),
        ("Brown", NSColor(srgbRed: 0.50, green: 0.30, blue: 0.15, alpha: 1)),
    ]

    static let highlight: [(String, NSColor)] = [
        ("Yellow", NSColor(srgbRed: 1.00, green: 0.95, blue: 0.30, alpha: 1)),
        ("Green", NSColor(srgbRed: 0.60, green: 0.95, blue: 0.50, alpha: 1)),
        ("Turquoise", NSColor(srgbRed: 0.50, green: 0.92, blue: 0.95, alpha: 1)),
        ("Pink", NSColor(srgbRed: 1.00, green: 0.65, blue: 0.85, alpha: 1)),
        ("Blue", NSColor(srgbRed: 0.60, green: 0.78, blue: 1.00, alpha: 1)),
        ("Orange", NSColor(srgbRed: 1.00, green: 0.78, blue: 0.45, alpha: 1)),
        ("Gray", NSColor(white: 0.82, alpha: 1)),
    ]

    static let pen: [(String, NSColor)] = text + [
        ("Yellow", NSColor(srgbRed: 0.95, green: 0.80, blue: 0.05, alpha: 1)),
        ("Pink", NSColor(srgbRed: 0.90, green: 0.30, blue: 0.60, alpha: 1)),
    ]

    /// Table cell shading.
    static let shading: [(String, NSColor)] = [
        ("Light Gray", NSColor(srgbRed: 0.93, green: 0.93, blue: 0.93, alpha: 1)),
        ("Gray", NSColor(srgbRed: 0.80, green: 0.80, blue: 0.80, alpha: 1)),
        ("Light Blue", NSColor(srgbRed: 0.85, green: 0.91, blue: 0.99, alpha: 1)),
        ("Blue", NSColor(srgbRed: 0.62, green: 0.77, blue: 0.95, alpha: 1)),
        ("Light Green", NSColor(srgbRed: 0.87, green: 0.95, blue: 0.85, alpha: 1)),
        ("Green", NSColor(srgbRed: 0.66, green: 0.85, blue: 0.62, alpha: 1)),
        ("Light Yellow", NSColor(srgbRed: 1.00, green: 0.97, blue: 0.80, alpha: 1)),
        ("Yellow", NSColor(srgbRed: 1.00, green: 0.90, blue: 0.45, alpha: 1)),
        ("Light Orange", NSColor(srgbRed: 1.00, green: 0.90, blue: 0.80, alpha: 1)),
        ("Light Red", NSColor(srgbRed: 0.99, green: 0.84, blue: 0.84, alpha: 1)),
        ("Light Purple", NSColor(srgbRed: 0.91, green: 0.87, blue: 0.98, alpha: 1)),
        ("Purple", NSColor(srgbRed: 0.47, green: 0.30, blue: 0.70, alpha: 1)),
        ("Dark Blue", NSColor(srgbRed: 0.16, green: 0.31, blue: 0.56, alpha: 1)),
        ("Dark Gray", NSColor(srgbRed: 0.30, green: 0.30, blue: 0.32, alpha: 1)),
    ]

    static func swatch(_ color: NSColor, size: CGFloat = 12) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            color.setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 2, yRadius: 2).fill()
            NSColor(white: 0, alpha: 0.25).setStroke()
            NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 2, yRadius: 2).stroke()
            return true
        }
        image.isTemplate = false
        return image
    }
}
