//
//  ServicesCheck.swift
//  MxDataHUB
//
//  At launch: whether the Layer 3 services are running, as MxAcctMGR checks. Those that aren't are named in an alert
//  that asks whether to start them, and they start in Terminal only if you say so: the app's sandbox would hold anything
//  it ran itself, and a service needs the repository and the Keychain. The services can still be starting when the app
//  opens at login, so the ones that don't answer are asked again a few seconds later before the alert shows. A service
//  that's running can still be cut off from the security master (macOS's Local Network permission, the database's host
//  being down), so those that use it are asked too, and what they say shows in the error dialog. The launch argument
//  -checkServices NO leaves it all out (tests and demos).
//

import SwiftUI

enum ServicesCheck {
    /// How long to wait before asking the silent ones again.
    static let retry = 4.0
    /// How often, and how many times, to look for the services after asking Terminal to start them (about a minute).
    static let startPoll = 2.0
    static let startPolls = 30

    /// The services that aren't running, after a second try.
    static func stopped() async -> [ServiceInfo] {
        var running = await ServiceCatalog.probeAll()
        if ServiceCatalog.all.contains(where: { running[$0.id] != true }) {
            try? await Task.sleep(for: .seconds(retry))
            running = await ServiceCatalog.probeAll()
        }
        return ServiceCatalog.all.filter { running[$0.id] != true }
    }

    static func atLaunch(_ store: SRMStore) async {
        let stopped = await Self.stopped()
        if stopped.isEmpty {
            await checkDatabase(store)
        } else {
            store.stoppedServices = stopped
        }
    }

    /// Shows what the running services say when they can't reach the security master.
    static func checkDatabase(_ store: SRMStore) async {
        if let problem = await databaseProblem() { store.errorMessage = problem }
    }

    private static func databaseProblem() async -> String? {
        let problems = await ServiceCatalog.databaseProblems()
        guard !problems.isEmpty else { return nil }
        let ids = ServiceCatalog.databaseServices.filter { problems[$0] != nil }
        return Dictionary(grouping: ids) { problems[$0] ?? "" }
            .map { $0.value.joined(separator: ", ") + " can't reach the security master:\n\n" + $0.key }
            .sorted()
            .joined(separator: "\n\n")
    }

    static func title(_ stopped: [ServiceInfo]) -> String {
        stopped.count == ServiceCatalog.all.count ? "The Layer 3 services aren't running"
            : stopped.count == 1 ? "A Layer 3 service isn't running: \(stopped[0].id)"
            : "\(stopped.count) Layer 3 services aren't running"
    }

    static func message(_ stopped: [ServiceInfo]) -> String {
        let lines = stopped.map { "• \($0.id): \($0.name) (\($0.language), port \($0.port))" }
        return lines.joined(separator: "\n") + "\n\nStart \(stopped.count == 1 ? "it" : "them") now? This opens a Terminal window to run:\n"
            + startCommand(stopped)
    }

    private static func startCommand(_ services: [ServiceInfo]) -> String {
        ServiceCatalog.startCommand + " " + services.map(\.id).joined(separator: " ")
    }

    /// Asks Terminal to start these services, then looks for them until they answer (or about a minute has gone).
    static func start(_ services: [ServiceInfo], _ store: SRMStore) {
        let command = startCommand(services)
        store.infoMessage = "Starting the Layer 3 services…"
        Task {
            let problem = await Task.detached { ServiceCatalog.askTerminal(command) }.value
            if let problem {
                store.infoMessage = nil
                store.errorMessage = problem + "\n\nStart them in Terminal yourself:\n" + command
                return
            }
            var waiting = services
            for _ in 0..<startPolls where !waiting.isEmpty {
                try? await Task.sleep(for: .seconds(startPoll))
                let running = await ServiceCatalog.probeAll()
                waiting = waiting.filter { running[$0.id] != true }
            }
            store.servicesStarts += 1
            var problems: [String] = []
            if !waiting.isEmpty {
                problems.append("Not answering yet: " + waiting.map(\.id).joined(separator: ", ")
                    + ".\n\nThe Terminal window says why; a service built for the first time takes longer.")
            }
            if let database = await databaseProblem() { problems.append(database) }
            store.infoMessage = problems.isEmpty ? "The Layer 3 services are running." : nil
            if !problems.isEmpty { store.errorMessage = problems.joined(separator: "\n\n") }
        }
    }
}

/// The alert naming the services that aren't running, on the main window.
struct StoppedServicesAlert: ViewModifier {
    @Bindable var store: SRMStore

    func body(content: Content) -> some View {
        content.alert(ServicesCheck.title(store.stoppedServices ?? []),
                      isPresented: Binding(get: { store.stoppedServices != nil }, set: { if !$0 { store.stoppedServices = nil } }),
                      presenting: store.stoppedServices) { stopped in
            Button("Start Services") { ServicesCheck.start(stopped, store) }
                .keyboardShortcut(.defaultAction)
            Button("Not Now", role: .cancel) { Task { await ServicesCheck.checkDatabase(store) } }
        } message: { stopped in
            Text(ServicesCheck.message(stopped))
        }
    }
}
