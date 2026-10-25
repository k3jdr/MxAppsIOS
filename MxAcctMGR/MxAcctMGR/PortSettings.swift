//
//  PortSettings.swift
//  MxAcctMGR
//
//  MxAcctMGR ▸ Settings (⌘,). Text: a font name, size and style for each kind of text that takes room — the headings,
//  and the numbers and tables (registers, the earnings calendar, IDs and codes, calculation results) — stepped down
//  together or one by one. Guidance: how much teaching the screens show — every page's "Why this step" lesson, the
//  line under its title, and the lesson-only pages. Banking: what the checking register's New entry line starts with.
//

import AppKit
import SwiftUI

/// The kinds of text with a font of their own in Settings ▸ Text.
enum TextKind: String, CaseIterable, Identifiable {
    case pageTitle, pageSubtitle, heading, subheading, name, figure
    case table, calendar, ids, results

    var id: String { rawValue }

    enum Section: String, CaseIterable, Identifiable {
        case headings = "Headings", numbers = "Numbers and Tables"
        var id: String { rawValue }
        var kinds: [TextKind] { TextKind.allCases.filter { $0.section == self } }
    }

    var section: Section {
        switch self {
        case .pageTitle, .pageSubtitle, .heading, .subheading, .name, .figure: .headings
        case .table, .calendar, .ids, .results: .numbers
        }
    }

    var title: String {
        switch self {
        case .pageTitle: "Page titles"
        case .pageSubtitle: "Page introductions"
        case .heading: "Headings"
        case .subheading: "Subheadings"
        case .name: "Names"
        case .figure: "Figures"
        case .table: "Registers and tables"
        case .calendar: "Calendar"
        case .ids: "IDs and codes"
        case .results: "Results"
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
        case .table: "Every register's and table's rows: checking, cards, expenses, targets, holdings, trades, securities"
        case .calendar: "The earnings calendar's days and its notable reports: dates, counts, symbols, EPS"
        case .ids: "Tickers, symbols and portfolio codes (monospaced in the system font)"
        case .results: "Calculation results: risk, trades, tracker, tax estimates, simulations, earnings history"
        }
    }

    /// The size and style it had before Settings had it (a macOS text style: title, title 3, title 2, headline, body,
    /// callout). Smaller text of the same kind — a calendar day's caption — keeps its proportion to it.
    var standard: KindFont {
        switch self {
        case .pageTitle: KindFont(size: 26, style: .semibold)
        case .pageSubtitle: KindFont(size: 15, style: .regular)
        case .heading: KindFont(size: 17, style: .semibold)
        case .subheading: KindFont(size: 15, style: .semibold)
        case .name: KindFont(size: 13, style: .bold)
        case .figure: KindFont(size: 17, style: .semibold)
        case .table: KindFont(size: 13, style: .regular)
        case .calendar: KindFont(size: 12, style: .regular)
        case .ids: KindFont(size: 13, style: .regular)
        case .results: KindFont(size: 12, style: .regular)
        }
    }
}

enum FontStyle: String, CaseIterable, Identifiable, Codable {
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

struct KindFont: Codable, Equatable {
    /// A font family's name; empty for the system font.
    var family = ""
    var size: Double
    var style: FontStyle
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

/// Settings ▸ Banking: the check number a new checking entry starts with, when its kind is Check.
enum CheckNumberDefault: String, CaseIterable, Identifiable {
    case empty = "Empty", next = "The register's next number"
    var id: String { rawValue }
}

/// Settings ▸ Banking: the date a new checking entry starts with.
enum EntryDateDefault: String, CaseIterable, Identifiable {
    case previous = "The date of the entry entered before", today = "Today"
    var id: String { rawValue }
}

@Observable
final class PortSettings {
    static let shared = PortSettings()

    /// The fonts changed from their kind's standard, by kind.
    private var fonts: [String: KindFont] {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(fonts), forKey: Self.fontsKey) }
    }
    var guidance: Guidance {
        didSet { UserDefaults.standard.set(guidance.rawValue, forKey: Self.guidanceKey) }
    }
    /// The checking register's New entry: its kind (EntryForm.kinds), check number and date to start with.
    var newEntryKind: String {
        didSet { UserDefaults.standard.set(newEntryKind, forKey: "newEntryKind") }
    }
    var newEntryCheckNumber: CheckNumberDefault {
        didSet { UserDefaults.standard.set(newEntryCheckNumber.rawValue, forKey: "newEntryCheckNumber") }
    }
    var newEntryDate: EntryDateDefault {
        didSet { UserDefaults.standard.set(newEntryDate.rawValue, forKey: "newEntryDate") }
    }

    private static let fontsKey = "headingFonts"
    private static let guidanceKey = "guidance"
    static let sizes: ClosedRange<Double> = 8...40

    private init() {
        fonts = UserDefaults.standard.data(forKey: Self.fontsKey)
            .flatMap { try? JSONDecoder().decode([String: KindFont].self, from: $0) } ?? [:]
        guidance = UserDefaults.standard.string(forKey: Self.guidanceKey).flatMap(Guidance.init(rawValue:)) ?? .full
        newEntryKind = UserDefaults.standard.string(forKey: "newEntryKind") ?? "debit"
        newEntryCheckNumber = UserDefaults.standard.string(forKey: "newEntryCheckNumber").flatMap(CheckNumberDefault.init(rawValue:)) ?? .empty
        newEntryDate = UserDefaults.standard.string(forKey: "newEntryDate").flatMap(EntryDateDefault.init(rawValue:)) ?? .previous
    }

    subscript(_ kind: TextKind) -> KindFont {
        get { fonts[kind.rawValue] ?? kind.standard }
        set { fonts[kind.rawValue] = newValue == kind.standard ? nil : newValue }
    }

    /// How much larger (over 1) or smaller a kind is than its standard.
    func scale(_ kind: TextKind) -> Double { self[kind].size / kind.standard.size }

    /// A kind's font. `standard` is the size the text had (smaller text of the kind keeps its proportion);
    /// `weight`, emphasis the text has whatever the kind's style (today's date, a holding's symbol).
    func font(_ kind: TextKind, standard: Double? = nil, weight: Font.Weight? = nil) -> Font {
        let f = self[kind]
        let size = (standard ?? kind.standard.size) * scale(kind)
        let weight = weight ?? f.style.weight
        let font: Font = f.family.isEmpty ? .system(size: size, weight: weight, design: kind == .ids ? .monospaced : .default)
            : .custom(f.family, fixedSize: size).weight(weight)
        return kind == .figure ? font.monospacedDigit() : font
    }

    /// A table's height for `rows` rows and its header, its rows as tall as the Registers and tables font makes them
    /// (24 points at the standard 13).
    func tableHeight(rows: Int) -> CGFloat { CGFloat(rows) * 24 * scale(.table) + 30 }

    /// Every kind of a section a point larger (or smaller).
    func step(_ points: Double, _ section: TextKind.Section) {
        for kind in section.kinds {
            self[kind].size = min(max(self[kind].size + points, Self.sizes.lowerBound), Self.sizes.upperBound)
        }
    }

    func isStandard(_ section: TextKind.Section) -> Bool { section.kinds.allSatisfy { fonts[$0.rawValue] == nil } }
    func restoreStandard(_ section: TextKind.Section) { for kind in section.kinds { fonts[kind.rawValue] = nil } }

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
    func heading(_ kind: TextKind) -> some View { font(PortSettings.shared.font(kind)) }

    /// Text of a kind in Settings ▸ Text: a table's rows, the calendar, an ID, results. `standard` is the size the
    /// text had, when smaller than its kind's (a caption); `weight`, emphasis it keeps whatever the kind's style.
    func textKind(_ kind: TextKind, _ standard: Double? = nil, weight: Font.Weight? = nil) -> some View {
        font(PortSettings.shared.font(kind, standard: standard, weight: weight))
    }

    /// A table's rows in the Registers and tables font, as tall as it needs: the rows follow their text (24 points at
    /// the standard 13) once the minimum is lowered with it.
    func tableText() -> some View {
        font(PortSettings.shared.font(.table))
            .environment(\.defaultMinListRowHeight, 24 * PortSettings.shared.scale(.table))
    }
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
    /// The tab showing; a screen's gear button opens its own (the New entry line's opens Banking).
    @AppStorage(PortSettingsView.tabKey) private var tab = "text"
    static let tabKey = "settingsTab"

    var body: some View {
        TabView(selection: $tab) {
            TextSettings()
                .tabItem { Label("Text", systemImage: "textformat.size") }
                .tag("text")
            GuidanceSettings()
                .tabItem { Label("Guidance", systemImage: "graduationcap") }
                .tag("guidance")
            BankingSettings()
                .tabItem { Label("Banking", systemImage: "building.columns") }
                .tag("banking")
        }
        .frame(width: 800)
    }
}

private struct TextSettings: View {
    @Bindable private var settings = PortSettings.shared

    private static let families = NSFontManager.shared.availableFontFamilies.sorted()

    var body: some View {
        Form {
            ForEach(TextKind.Section.allCases) { section in
                Section {
                    HStack {
                        Button("Step Down") { settings.step(-1, section) }
                            .help("Every kind below one point smaller")
                        Button("Step Up") { settings.step(1, section) }
                            .help("Every kind below one point larger")
                        Spacer()
                        Button("Restore Defaults") { settings.restoreStandard(section) }
                            .disabled(settings.isStandard(section))
                            .help("The system font, in the sizes and styles MxAcctMGR had before")
                    }
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                        GridRow {
                            Text("Kind"); Text("Font name"); Text("Size"); Text("Style")
                        }
                        .font(.caption).foregroundStyle(.secondary)
                        ForEach(section.kinds) { kind in
                            Divider().gridCellColumns(4)
                            row(kind)
                        }
                    }
                } header: {
                    Text(section.rawValue)
                } footer: {
                    if section == .numbers {
                        Text("Each kind's name on the left is drawn in its font. Smaller text of a kind (a calendar day's count, a caption) keeps its proportion; other text keeps the system's sizes.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 720)
    }

    private func row(_ kind: TextKind) -> some View {
        GridRow {
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.title).textKind(kind).lineLimit(1)
                Text(kind.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 330, alignment: .leading)
            Picker("Font name", selection: $settings[kind].family) {
                Text(kind == .ids ? "System Monospaced" : "System").tag("")
                Divider()
                ForEach(Self.families, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .frame(width: 170)
            .help("The font's name")
            Stepper("\(Int(settings[kind].size)) pt", value: $settings[kind].size, in: PortSettings.sizes)
                .monospacedDigit()
                .frame(width: 80, alignment: .leading)
                .help("Its size in points (standard \(Int(kind.standard.size)) pt)")
            Picker("Style", selection: $settings[kind].style) {
                ForEach(FontStyle.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .frame(width: 110)
            .help("Its style (standard \(kind.standard.style.rawValue))")
        }
    }
}

private struct BankingSettings: View {
    @Bindable private var settings = PortSettings.shared

    var body: some View {
        Form {
            Section {
                Picker("Kind", selection: $settings.newEntryKind) {
                    ForEach(EntryForm.kinds, id: \.0) { Text($0.1).tag($0.0) }
                }
                Picker("Check number", selection: $settings.newEntryCheckNumber) {
                    ForEach(CheckNumberDefault.allCases) { Text($0.rawValue).tag($0) }
                }
                Picker("Date", selection: $settings.newEntryDate) {
                    ForEach(EntryDateDefault.allCases) { Text($0.rawValue).tag($0) }
                }
            } header: {
                Text("Checking Accounts ▸ New entry")
            } footer: {
                Text("What the New entry line above the checking register starts with, and starts again with after each entry. The check number is filled in only for a check; the date of the entry before keeps a month's entries from the paper register on their day.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
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
