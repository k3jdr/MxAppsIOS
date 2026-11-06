//
//  SettingsView.swift — MxModxUSB
//
//  Settings (⌘,). Guidance: how much teaching the FM Synthesis and AWM2 Synthesis tutorials show, as in MxAcctMGR —
//  Full (everything), Brief (no "Why it works" lessons) or Minimal (also no line under the titles, no "Listen for",
//  and the pages that only teach leave the lesson lists).
//

import SwiftUI

/// Settings ▸ Guidance: how much teaching the tutorials show.
enum ModxGuidance: String, CaseIterable, Identifiable {
    case full = "Full", brief = "Brief", minimal = "Minimal"

    var id: String { rawValue }

    var detail: String {
        switch self {
        case .full: "Everything: each lesson's \"Why it works\", its steps, what to listen for, the line under its title, and the pages that only teach."
        case .brief: "Hides the \"Why it works\" lessons: the steps and what to listen for stay."
        case .minimal: "Also hides the line under each title and \"Listen for\", and the pages that only teach (What FM Is, What AWM2 Is) leave the lesson lists: a title, the steps and the controls."
        }
    }
}

@MainActor
@Observable
final class ModxSettings {
    static let shared = ModxSettings()
    private static let guidanceKey = "guidance"

    var guidance: ModxGuidance = UserDefaults.standard.string(forKey: guidanceKey).flatMap(ModxGuidance.init(rawValue:)) ?? .full {
        didSet { UserDefaults.standard.set(guidance.rawValue, forKey: Self.guidanceKey) }
    }

    var showsTheory: Bool { guidance == .full }
    var showsIntroductions: Bool { guidance != .minimal }
    var showsListening: Bool { guidance != .minimal }
    func shows(_ lesson: TutorialLesson) -> Bool { guidance != .minimal || !lesson.lessonOnly }
}

struct ModxSettingsView: View {
    @AppStorage("settingsTab") private var tab = "guidance"

    var body: some View {
        TabView(selection: $tab) {
            GuidanceSettings()
                .tabItem { Label("Guidance", systemImage: "graduationcap") }
                .tag("guidance")
        }
        .frame(width: 520)
    }
}

private struct GuidanceSettings: View {
    @Bindable private var settings = ModxSettings.shared

    var body: some View {
        Form {
            Section {
                Picker("Instruction level", selection: $settings.guidance) {
                    ForEach(ModxGuidance.allCases) { level in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(level.rawValue)
                            Text(level.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.bottom, 6)
                        .tag(level)
                    }
                }
                .pickerStyle(.radioGroup)
                .quickHelp("Instruction level", "How much teaching the FM Synthesis and AWM2 Synthesis pages show: Full, Brief or Minimal.")
            } header: {
                Text("Guidance")
            } footer: {
                Text("For the FM Synthesis and AWM2 Synthesis tutorials; a hidden lesson comes back at Full. Each tutorial's header has the same choice.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
