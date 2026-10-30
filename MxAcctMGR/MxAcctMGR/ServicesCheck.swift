//
//  ServicesCheck.swift
//  MxAcctMGR
//
//  At launch: whether the Layer 3 services MxAcctMGR uses are running. Those that aren't are named in an alert, with
//  what each one does here and the command that starts them (Guide ▸ Layer 3 Services has every service's status).
//  The services can still be starting when the app opens at login, so the ones that don't answer are asked again a
//  few seconds later before the alert shows. After that the app keeps checking: while any of them doesn't answer, the
//  sidebar's Layer 3 Services row and the toolbar's Layer 3 services engine are red. The launch argument -checkServices NO leaves it all out (tests and demos).
//

import AppKit
import SwiftUI

enum ServicesCheck {
    /// The services MxAcctMGR uses, with what each does here (market-sample is only for MxJobsMGR's jobspaces).
    static let used: [(id: String, use: String)] = [
        ("accounts", "every account, register and security — nothing loads without it"),
        ("analytics", "risk numbers, optimization inputs and attribution"),
        ("portfolio-java", "Optimize My Portfolio with the Layer 3 engine (Built-in works without it)"),
        ("portfolio-cpp", "Build My Index Tracker and risk with the Layer 3 engine (Built-in works without it)"),
        ("srm-loader", "loading prices, card downloads and policy benchmarks (the accounts service asks it)"),
    ]
    /// How long to wait before asking the silent ones again.
    static let retry = 4.0
    /// How often to check again after launch.
    static let watchEvery = 30.0
    /// The red of what's down, dark enough for white text.
    static let red = Color(red: 0.82, green: 0.1, blue: 0.1)

    /// The services MxAcctMGR uses that aren't running, after a second try.
    static func stopped() async -> [ServiceInfo] {
        var running = await ServiceCatalog.probeAll()
        if used.contains(where: { running[$0.id] != true }) {
            try? await Task.sleep(for: .seconds(retry))
            running = await ServiceCatalog.probeAll()
        }
        return used.compactMap { running[$0.id] == true ? nil : ServiceCatalog.service($0.id) }
    }

    /// At launch and from then on: keeps the store's services that are down current; only the first check alerts.
    static func watch(_ store: PortStore) async {
        let stopped = await Self.stopped()
        store.servicesDown = stopped.map(\.id)
        if !stopped.isEmpty { store.stoppedServices = stopped }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(watchEvery))
            store.servicesDown = await Self.stopped().map(\.id)
        }
    }

    static func title(_ stopped: [ServiceInfo]) -> String {
        stopped.count == used.count ? "The Layer 3 services aren't running"
            : stopped.count == 1 ? "A Layer 3 service isn't running: \(stopped[0].id)"
            : "\(stopped.count) Layer 3 services aren't running"
    }

    static func message(_ stopped: [ServiceInfo]) -> String {
        let lines = stopped.map { s in "• \(s.id) (\(s.language), port \(s.port)): \(used.first { $0.id == s.id }?.use ?? s.purpose)" }
        return "MxAcctMGR uses \(stopped.count == 1 ? "it" : "them") for:\n" + lines.joined(separator: "\n")
            + "\n\nStart the services in Terminal:\n\(ServiceCatalog.startCommand)"
    }

    static func copyStartCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ServiceCatalog.startCommand, forType: .string)
    }
}

/// The toolbar's engine picker while it reads Layer 3 services and any of them is down, so it shows even when the
/// sidebar's row is scrolled out of sight.
struct ServicesDownPicker: ViewModifier {
    var down: [String]

    func body(content: Content) -> some View {
        if down.isEmpty {
            content
        } else {
            content
                .foregroundStyle(.white)
                .background(ServicesCheck.red, in: Capsule())
                .help("Not running: " + down.joined(separator: ", "))
        }
    }
}

/// The sidebar's Layer 3 Services row while any service MxAcctMGR uses is down: red, with their names on hover.
struct ServicesDownRow: ViewModifier {
    var down: [String]

    func body(content: Content) -> some View {
        if down.isEmpty {
            content
        } else {
            let names = "Not running: " + down.joined(separator: ", ")
            content
                .foregroundStyle(.white)
                .listItemTint(.white)
                .background {
                    RoundedRectangle(cornerRadius: 6).fill(ServicesCheck.red)
                        .padding(.horizontal, -8).padding(.vertical, -4)
                }
                .help(names)
                .accessibilityValue(names)
        }
    }
}

/// The alert naming the services that aren't running, on the main window (a modifier of its own: ContentView's chain
/// is as long as the type checker takes).
struct StoppedServicesAlert: ViewModifier {
    @Bindable var store: PortStore

    func body(content: Content) -> some View {
        content.alert(ServicesCheck.title(store.stoppedServices ?? []),
                      isPresented: Binding(get: { store.stoppedServices != nil }, set: { if !$0 { store.stoppedServices = nil } }),
                      presenting: store.stoppedServices) { _ in
            Button("Copy Start Command") { ServicesCheck.copyStartCommand() }
            Button("Layer 3 Services…") { store.go(.services) }
            Button("OK", role: .cancel) {}
        } message: { stopped in
            Text(ServicesCheck.message(stopped))
        }
    }
}
