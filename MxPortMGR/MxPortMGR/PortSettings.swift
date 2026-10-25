//
//  PortSettings.swift
//  MxPortMGR
//
//  MxPortMGR ▸ Settings (⌘,). Text: the larger text's fonts — a name, size and style for each kind of heading, stepped
//  down together or one by one. Guidance: how much teaching the screens show — every page's "Why this step" lesson,
//  the line under its title, and the lesson-only pages.
//

import AppKit
import SwiftUI

/// The kinds of larger text, each with a font of its own in Settings ▸ Text.
enum HeadingRole: String, CaseIterable, Identifiable {
    case pageTitle, pageSubtitle, heading, subheading, name, figure

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pageTitle: "Page titles"
        case .pageSubtitle: "Page introductions"
        case .heading: "Headings"
        case .subheading: "Subheadings"
        case .name: "Names"
        case .figure: "Figures"
        }
    }

    /// Where it shows.
    var detail: String {
        switch self {
        case .pageTitle: "The title at the top of each page"
        case .pageSubtitle: "The line under a page's title"
        case .heading: "Report tiers and headlines, a security's name, dialog titles"
        case .subheading: "Cards, decisions, an earnings day, a simulation's result"
        case .name: "Box and lesson titles; report, account, ledger and sample names"
        case .figure: "The numbers in the metric tiles"
        }
    }

    /// The macOS text style it used before Settings had it (title, title 3, title 2, headline).
    var standard: HeadingFont {
        switch self {
        case .pageTitle: HeadingFont(size: 26, style: .semibold)
        case .pageSubtitle: HeadingFont(size: 15, style: .regular)
        case .heading: HeadingFont(size: 17, style: .semibold)
        case .subheading: HeadingFont(size: 15, style: .semibold)
        case .name: HeadingFont(size: 13, style: .bold)
        case .figure: HeadingFont(size: 17, style: .semibold)
        }
    }
}

enum HeadingStyle: String, CaseIterable, Identifiable, Codable {
    case light = "Light", regular = "Regular", medium = "Medium", semibold = "Semibold", bold = "Bold"

    var id: String { rawValue }

    var weight: Font.Weight {
        switch self {
        case .light: .light
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        }
    }
}

struct HeadingFont: Codable, Equatable {
    /// A font family's name; empty for the system font.
    var family = ""
    var size: Double
    var style: HeadingStyle
}

/// Settings ▸ Guidance: how much teaching the screens show.
enum Guidance: String, CaseIterable, Identifiable {
    case full = "Full", brief = "Brief", minimal = "Minimal"

    var id: String { rawValue }

    var detail: String {
        switch self {
        case .full: "Everything: each page's \"Why this step\" lesson and the line under its title, and the lesson-only pages."
        case .brief: "Hides the \"Why this step\" lessons on every page."
        case .minimal: "Also hides the line under each page's title and the lesson-only pages — Welcome, Choose Your Path, Why Optimize?, Why Attribution? and Active vs Passive — in the sidebar, the Guide menu and Previous / Next Step."
        }
    }
}

@Observable
final class PortSettings {
    static let shared = PortSettings()

    /// The fonts changed from their kind's standard, by kind.
    private var fonts: [String: HeadingFont] {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(fonts), forKey: Self.fontsKey) }
    }
    var guidance: Guidance {
        didSet { UserDefaults.standard.set(guidance.rawValue, forKey: Self.guidanceKey) }
    }

    private static let fontsKey = "headingFonts"
    private static let guidanceKey = "guidance"
    static let sizes: ClosedRange<Double> = 9...40

    private init() {
        fonts = UserDefaults.standard.data(forKey: Self.fontsKey)
            .flatMap { try? JSONDecoder().decode([String: HeadingFont].self, from: $0) } ?? [:]
        guidance = UserDefaults.standard.string(forKey: Self.guidanceKey).flatMap(Guidance.init(rawValue:)) ?? .full
    }

    subscript(_ role: HeadingRole) -> HeadingFont {
        get { fonts[role.rawValue] ?? role.standard }
        set { fonts[role.rawValue] = newValue == role.standard ? nil : newValue }
    }

    func font(_ role: HeadingRole) -> Font {
        let f = self[role]
        let font: Font = f.family.isEmpty ? .system(size: f.size, weight: f.style.weight)
            : .custom(f.family, fixedSize: f.size).weight(f.style.weight)
        return role == .figure ? font.monospacedDigit() : font
    }

    /// Every kind's size up or down by `points`.
    func step(_ points: Double) {
        for role in HeadingRole.allCases {
            self[role].size = min(max(self[role].size + points, Self.sizes.lowerBound), Self.sizes.upperBound)
        }
    }

    var isStandard: Bool { fonts.isEmpty }
    func restoreStandard() { fonts = [:] }

    var showsLessons: Bool { guidance == .full }
    var showsIntroductions: Bool { guidance != .minimal }
    func shows(_ screen: Screen) -> Bool { guidance != .minimal || !screen.lessonOnly }
}

extension Screen {
    /// Pages that only teach: hidden at Settings ▸ Guidance ▸ Minimal.
    var lessonOnly: Bool { [.welcome, .choosePath, .whyOptimize, .whyAttribution, .activeVsPassive].contains(self) }
}

extension View {
    /// Larger text, in the font Settings ▸ Text gives its kind.
    func heading(_ role: HeadingRole) -> some View { font(PortSettings.shared.font(role)) }
}

/// Menu items that open lesson-only pages, gone at Settings ▸ Guidance ▸ Minimal (a view of their own, so the menu
/// follows the setting).
struct LessonPageItems<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        if PortSettings.shared.guidance != .minimal { content }
    }
}

// MARK: - The Settings window

struct PortSettingsView: View {
    var body: some View {
        TabView {
            TextSettings()
                .tabItem { Label("Text", systemImage: "textformat.size") }
            GuidanceSettings()
                .tabItem { Label("Guidance", systemImage: "graduationcap") }
        }
        .frame(width: 760)
    }
}

private struct TextSettings: View {
    @Bindable private var settings = PortSettings.shared

    private static let families = NSFontManager.shared.availableFontFamilies.sorted()

    var body: some View {
        Form {
            Section {
                HStack {
                    Button("Step Down") { settings.step(-1) }
                        .help("Every heading one point smaller")
                    Button("Step Up") { settings.step(1) }
                        .help("Every heading one point larger")
                    Spacer()
                    Button("Restore Defaults") { settings.restoreStandard() }
                        .disabled(settings.isStandard)
                        .help("The system font, in the sizes and styles MxPortMGR had before")
                }
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    GridRow {
                        Text("Kind"); Text("Font name"); Text("Size"); Text("Style")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    ForEach(HeadingRole.allCases) { role in
                        Divider().gridCellColumns(4)
                        row(role)
                    }
                }
            } header: {
                Text("Headings")
            } footer: {
                Text("Each kind of larger text shows in its own font; its name on the left is drawn in it. Other text keeps the system's sizes.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 640)
    }

    private func row(_ role: HeadingRole) -> some View {
        GridRow {
            VStack(alignment: .leading, spacing: 2) {
                Text(role.title).heading(role).lineLimit(1)
                Text(role.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 290, alignment: .leading)
            Picker("Font name", selection: $settings[role].family) {
                Text("System").tag("")
                Divider()
                ForEach(Self.families, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .frame(width: 170)
            .help("The font's name")
            Stepper("\(Int(settings[role].size)) pt", value: $settings[role].size, in: PortSettings.sizes)
                .monospacedDigit()
                .frame(width: 80, alignment: .leading)
                .help("Its size in points (standard \(Int(role.standard.size)) pt)")
            Picker("Style", selection: $settings[role].style) {
                ForEach(HeadingStyle.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .frame(width: 110)
            .help("Its style (standard \(role.standard.style.rawValue))")
        }
    }
}

private struct GuidanceSettings: View {
    @Bindable private var settings = PortSettings.shared

    var body: some View {
        Form {
            Section {
                Picker("Instruction level", selection: $settings.guidance) {
                    ForEach(Guidance.allCases) { level in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(level.rawValue)
                            Text(level.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.bottom, 6)
                        .tag(level)
                    }
                }
                .pickerStyle(.radioGroup)
            } header: {
                Text("Guidance")
            } footer: {
                Text("A hidden lesson comes back at Full. The educational notice in the status bar always shows.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
