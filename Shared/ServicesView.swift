//
//  ServicesView.swift
//  Shared by MxDataHUB, MxJobsMGR and MxAcctMGR (MxAppsIOS/Shared)
//
//  "Layer 3 Services": every service both apps use — running or not, its language and why, the use cases it
//  serves and when to use them, its endpoints, how to start it, and the sample workflows built on it.
//  Each app adds its own actions (MxJobsMGR: add a step, open a sample; MxDataHUB: open a workflow).
//

import AppKit
import SwiftUI

struct ServicesView: View {
    /// App-specific buttons for a service (e.g. "Add Step" in MxJobsMGR).
    var serviceActions: (ServiceInfo, ServiceEndpoint?) -> AnyView = { _, _ in AnyView(EmptyView()) }
    /// Opens a sample (MxJobsMGR: new jobspace; MxDataHUB: hand-off to MxJobsMGR).
    var openSample: ((SampleInfo) -> Void)?
    var openSampleTitle = "Open Sample"

    @State private var selection: String? = ServiceCatalog.all.first?.id
    @State private var running: [String: Bool] = [:]
    @State private var checking = false

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                List(selection: $selection) {
                    Section("Layer 3 services") {
                        ForEach(ServiceCatalog.all) { service in
                            ServiceRow(service: service, running: running[service.id])
                                .tag(service.id)
                        }
                    }
                    Section("Choosing a language") {
                        ForEach(ServiceCatalog.languageGuide, id: \.language) { item in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.language).font(.caption.weight(.semibold))
                                Text(item.use).font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
                .listStyle(.sidebar)
                // Rows are picked, not their words (MxDataHUB makes its screens' text selectable).
                .textSelection(.disabled)
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Button {
                            Task { await refresh() }
                        } label: {
                            Label("Check", systemImage: "arrow.clockwise")
                        }
                        .disabled(checking)
                        .quickHelp("Check", "Checks which services are running on this Mac (each answers on its own port).")
                        if checking { ProgressView().controlSize(.small) }
                        Spacer()
                        let up = running.values.filter { $0 }.count
                        Text("\(up) of \(ServiceCatalog.all.count) running").font(.caption).foregroundStyle(.secondary)
                    }
                    CopyCommand(title: "Start all", command: ServiceCatalog.startCommand)
                        .quickHelp("Start All", "The Terminal command that starts every Layer 3 service; copy it and run it in Terminal.")
                }
                .padding(10)
            }
            .frame(minWidth: 260, idealWidth: 300, maxWidth: 360)

            Group {
                if let id = selection, let service = ServiceCatalog.service(id) {
                    ServiceDetail(service: service, running: running[id], serviceActions: serviceActions,
                                  openSample: openSample, openSampleTitle: openSampleTitle)
                } else {
                    ContentUnavailableView("Select a Service", systemImage: "server.rack")
                }
            }
            .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { await refresh() }
    }

    private func refresh() async {
        checking = true
        running = await ServiceCatalog.probeAll()
        checking = false
    }
}

private struct ServiceRow: View {
    var service: ServiceInfo
    var running: Bool?

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(running == nil ? Color.secondary.opacity(0.4) : running! ? Color.green : Color.red.opacity(0.8))
                .frame(width: 8, height: 8)
                .help(running == nil ? "Checking…" : running! ? "Running" : "Not running")
            VStack(alignment: .leading, spacing: 1) {
                Text(service.name)
                Text("\(service.language) · :\(String(service.port)) · \(service.cases.map(\.title).joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        .quickHelpArea(QuickHelpItem(
            title: "\(service.name) (\(service.language))",
            detail: service.purpose + "\n" + (running == nil ? "" : running! ? "Running on port \(service.port). " : "Not running (port \(service.port)). ")
                + "Select it for when to use it, its endpoints, how to start it and the workflows built on it.",
            symbol: "server.rack"))
    }
}

private struct ServiceDetail: View {
    var service: ServiceInfo
    var running: Bool?
    var serviceActions: (ServiceInfo, ServiceEndpoint?) -> AnyView
    var openSample: ((SampleInfo) -> Void)?
    var openSampleTitle: String

    var body: some View {
        Form {
            Section {
                HStack(alignment: .firstTextBaseline) {
                    LanguageBadge(language: service.language)
                    Text(service.name).font(.title3.weight(.semibold))
                    Spacer()
                    Label(running == true ? "Running on :\(String(service.port))" : "Not running",
                          systemImage: running == true ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundStyle(running == true ? .green : .secondary)
                }
                Text(service.purpose)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Why \(service.language)").font(.callout.weight(.semibold))
                    Text(service.whyThisLanguage).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                serviceActions(service, nil)
            }

            Section("Use it for") {
                ForEach(service.cases) { useCase in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(useCase.title).font(.callout.weight(.semibold))
                        Text(useCase.whenToUse).font(.callout).foregroundStyle(.secondary)
                    }
                }
            }

            Section("Endpoints") {
                ForEach(service.endpoints, id: \.self) { endpoint in
                    HStack(alignment: .firstTextBaseline) {
                        Text(endpoint.method)
                            .font(.caption.monospaced().weight(.semibold))
                            .frame(width: 40, alignment: .leading)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(endpoint.path).font(.callout.monospaced())
                            Text(endpoint.summary + (endpoint.contract.map { " · \($0)" } ?? ""))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        serviceActions(service, endpoint)
                    }
                }
            }

            let samples = service.samples.compactMap(SampleInfo.sample)
            if !samples.isEmpty {
                Section("Sample workflows using it") {
                    ForEach(samples) { sample in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(sample.title).font(.callout.weight(.semibold))
                                Text(sample.summary).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let openSample {
                                Button(openSampleTitle) { openSample(sample) }
                            }
                        }
                    }
                }
            }

            Section("Run and develop") {
                if running != true {
                    CopyCommand(title: "Start", command: "python3 \(ServiceCatalog.repository)/Services/mxservices.py start \(service.id)")
                }
                CopyCommand(title: "Status", command: ServiceCatalog.statusCommand)
                CopyCommand(title: "Start at login", command: ServiceCatalog.agentsCommand)
                LabeledContent("Project", value: service.projectPath)
                LabeledContent("Develop in", value: service.developIn)
                Button("Show Project in Finder") {
                    let path = (service.projectPath as NSString).expandingTildeInPath
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct LanguageBadge: View {
    var language: String
    var body: some View {
        Text(language)
            .font(.caption.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color, in: RoundedRectangle(cornerRadius: 4))
    }

    private var color: Color {
        switch language {
        case "Python": .blue
        case "Java": .orange
        case "C++": .purple
        default: .gray
        }
    }
}

/// A shell command with a Copy button.
struct CopyCommand: View {
    var title: String
    var command: String

    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
            Text(command)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy the command; paste it in Terminal")
            .quickHelp("Copy \u{201C}\(title)\u{201D} Command", "Copies \(command) — paste it in Terminal to run it.", symbol: "doc.on.doc")
        }
    }
}

/// The sample workflows, with the services each needs and whether they are running.
struct SampleGalleryView: View {
    var open: (SampleInfo) -> Void
    var openTitle = "Create"
    /// Shown above the list (e.g. the portfolio the samples will use).
    var note: String?

    @State private var running: [String: Bool] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let note {
                Text(note).font(.callout).padding([.horizontal, .top], 14)
            }
            List {
                ForEach(["Data", "Active", "Passive", "Analytics", "Templates"], id: \.self) { area in
                    let samples = SampleInfo.all.filter { $0.area == area }
                    if !samples.isEmpty {
                        Section(area) {
                            ForEach(samples) { sample in
                                SampleRow(sample: sample, running: running, open: open, openTitle: openTitle)
                            }
                        }
                    }
                }
            }
            .listStyle(.inset)
            Divider()
            HStack {
                Text("Services must be running for Live runs; Mock runs work without them.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                CopyCommand(title: "Start all", command: ServiceCatalog.startCommand).frame(maxWidth: 460)
            }
            .padding(10)
        }
        .task { running = await ServiceCatalog.probeAll() }
    }
}

private struct SampleRow: View {
    var sample: SampleInfo
    var running: [String: Bool]
    var open: (SampleInfo) -> Void
    var openTitle: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(sample.title).font(.headline)
                Text(sample.summary).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    ForEach(sample.services, id: \.self) { id in
                        if let s = ServiceCatalog.service(id) {
                            HStack(spacing: 3) {
                                Circle().fill(running[id] == true ? Color.green : Color.secondary.opacity(0.5))
                                    .frame(width: 6, height: 6)
                                Text("\(s.name) (\(s.language))").font(.caption)
                            }
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.1), in: Capsule())
                        }
                    }
                }
            }
            Spacer()
            Button(openTitle) { open(sample) }
                .buttonStyle(.borderedProminent)
        }
        .padding(.vertical, 6)
        .quickHelpArea(QuickHelpItem(
            title: "\(sample.area): \(sample.title)",
            detail: sample.summary + "\nUses " + sample.services.compactMap { ServiceCatalog.service($0)?.name }.joined(separator: ", ")
                + (sample.services.isEmpty ? "no services" : "") + ". \(openTitle) opens it"
                + (sample.takesPortfolio ? " for a portfolio (DEMO_GROWTH unless it comes from a portfolio in MxDataHUB)." : "."),
            symbol: "doc.on.doc"))
    }
}
