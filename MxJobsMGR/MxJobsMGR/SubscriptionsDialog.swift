//
//  SubscriptionsDialog.swift
//  MxJobsMGR
//
//  Layer 3 configuration: the API subscriptions of the jobspace (base URL, how the
//  key is sent, rate limit, default headers) and the MxAcctMGR secure account whose
//  service key each sends. The keys themselves are entered in MxAcctMGR ▸ Secure Accounts.
//

import SwiftUI

struct SubscriptionsDialog: View {
    @Binding var space: Jobspace
    var editor: EditorState
    @Environment(\.dismiss) private var dismiss

    @State private var selection: UUID?
    @State private var confirmDelete = false
    @State private var moveKeys = false

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                VStack(spacing: 0) {
                    List(selection: $selection) {
                        ForEach(space.subscriptions) { sub in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(sub.name.isEmpty ? "Untitled" : sub.name)
                                KeyStatus(subscription: sub)
                            }
                            .tag(sub.id)
                        }
                    }
                    Divider()
                    HStack(spacing: 0) {
                        Menu {
                            Button("New Subscription") { add(ApiSubscription()) }
                            Button("Local Python Service (127.0.0.1:\(ApiSubscription.localServicePort))") {
                                add(.localService())
                            }
                        } label: { Image(systemName: "plus").frame(width: 24, height: 20) }
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("Add a subscription")
                        .quickHelp("Add Subscription", "A new subscription for a data service, or one for the local Python service (127.0.0.1:\(ApiSubscription.localServicePort)).")
                        Button {
                            confirmDelete = true
                        } label: { Image(systemName: "minus").frame(width: 24, height: 20) }
                        .disabled(selection == nil)
                        Spacer()
                    }
                    .buttonStyle(.borderless)
                    .padding(6)
                }
                .frame(minWidth: 190, idealWidth: 210, maxWidth: 280)
                .quickHelpArea("Subscriptions", "This jobspace's API subscriptions and whether each has a key in MxAcctMGR ▸ Secure Accounts. Select one to edit it; − deletes it (its key stays in Secure Accounts).", symbol: "list.bullet")

                Group {
                    if let selection, let i = space.subscriptions.firstIndex(where: { $0.id == selection }) {
                        SubscriptionForm(subscription: $space.subscriptions[i], usage: usage(of: selection))
                            .id(selection)
                    } else {
                        ContentUnavailableView("No Subscription Selected", systemImage: "network",
                                               description: Text("Add a subscription for each data service the Layer 3 API reads call."))
                    }
                }
                .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack {
                Text("API keys are kept in MxAcctMGR ▸ Secure Accounts, never in the jobspace file.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                let _ = KeychainChanges.shared.revision
                if !KeyMove.pending(space).isEmpty {
                    Button("Move Keys to Secure Accounts…") { moveKeys = true }
                        .help("Some subscriptions still have their keys in MxJobsMGR's own Keychain items")
                }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(minWidth: 720, idealWidth: 780, minHeight: 520, idealHeight: 580)
        .onAppear {
            selection = editor.subscriptionToEdit ?? space.subscriptions.first?.id
            editor.subscriptionToEdit = nil
        }
        .sheet(isPresented: $moveKeys) { KeyMoveSheet(space: $space) }
        .task(id: KeychainChanges.shared.revision) { await SecureAccountsList.shared.loadIfNeeded() }
        .confirmationDialog("Delete this subscription?", isPresented: $confirmDelete) {
            Button("Delete Subscription", role: .destructive) { deleteSelected() }
        } message: {
            let n = selection.map(usage(of:)) ?? 0
            Text(n > 0 ? "\(n) API read\(n == 1 ? "" : "s") use it and will be left without a subscription. Its secure account and key stay in MxAcctMGR."
                       : "Its secure account and key stay in MxAcctMGR.")
        }
    }

    private func add(_ sub: ApiSubscription) {
        space.subscriptions.append(sub)
        selection = sub.id
    }

    private func usage(of id: UUID) -> Int {
        space.nodes.filter { $0.api?.subscriptionID == id || $0.script?.subscriptionID == id }.count
    }

    private func deleteSelected() {
        guard let id = selection, space.subscription(id) != nil else { return }
        space.subscriptions.removeAll { $0.id == id }
        for i in space.nodes.indices {
            if space.nodes[i].api?.subscriptionID == id { space.nodes[i].api?.subscriptionID = nil }
            if space.nodes[i].script?.subscriptionID == id { space.nodes[i].script?.subscriptionID = nil }
        }
        selection = space.subscriptions.first?.id
    }
}

private struct SubscriptionForm: View {
    @Binding var subscription: ApiSubscription
    var usage: Int

    @State private var showHelp = false

    var body: some View {
        Form {
            Section("Service") {
                TextField("Name", text: $subscription.name)
                TextField("Provider", text: $subscription.provider)
                TextField("Base URL", text: $subscription.baseURL, prompt: Text("https://api.example.com/v1"))
                    .font(.body.monospaced())
                TextField("Plan", text: $subscription.plan, prompt: Text("e.g. Free, Premium"))
                Stepper(subscription.rateLimitPerMinute == 0 ? "Rate limit: none set"
                                                            : "Rate limit: \(subscription.rateLimitPerMinute) calls / min",
                        value: $subscription.rateLimitPerMinute, in: 0...10_000)
                HStack {
                    TextField("Documentation", text: $subscription.docsURL, prompt: Text("https://"))
                    if let url = URL(string: subscription.docsURL), url.host() != nil {
                        Link(destination: url) { Image(systemName: "arrow.up.right.square") }
                            .help("Open the documentation")
                    }
                }
                if usage > 0 {
                    LabeledContent("Used by", value: "\(usage) step\(usage == 1 ? "" : "s")")
                }
            }
            .quickHelpArea(JobsHelp.section("Service"))

            Section {
                Picker("Authentication", selection: $subscription.auth) {
                    ForEach(AuthStyle.allCases) { Text($0.title).tag($0) }
                }
                if subscription.auth == .queryParameter || subscription.auth == .header {
                    TextField(subscription.auth == .header ? "Header name" : "Parameter name",
                              text: $subscription.keyName,
                              prompt: Text(subscription.auth == .header ? "X-API-Key" : "apikey"))
                }
                if subscription.auth != .none {
                    if subscription.auth == .localService {
                        Text("Optional: choose a secure account only if the service requires a token (its service key is sent as “Authorization: Bearer …”).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    SecureAccountSection(subscription: $subscription)
                }
                let guide = ProviderGuide.matching(subscription)
                if guide.id != "generic", guide.auth != subscription.auth, guide.needsKey || subscription.auth.requiresKey {
                    HStack {
                        Label("\(guide.name) expects: \(guide.auth.title)\(guide.keyName.isEmpty ? "" : " (\(guide.keyName))")",
                              systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Button("Use It") {
                            subscription.auth = guide.auth
                            subscription.keyName = guide.keyName
                        }
                        .controlSize(.small)
                    }
                }
                if let base = guide.baseURL, !ProviderGuide.sameBase(subscription.baseURL, base) {
                    HStack {
                        Label("\(guide.name)'s base URL is \(base) — endpoint paths and parameters go on each API Data Read step",
                              systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Use It") { subscription.baseURL = base }
                            .controlSize(.small)
                    }
                }
            } header: {
                HStack {
                    Text("API Key")
                    Spacer()
                    if let url = ProviderGuide.matching(subscription).signupURL {
                        Link("Get a Key…", destination: url).font(.caption)
                    }
                    Button {
                        showHelp.toggle()
                    } label: {
                        Image(systemName: "questionmark.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("How to get and add a key for \(ProviderGuide.matching(subscription).name)")
                    .popover(isPresented: $showHelp, arrowEdge: .trailing) {
                        ScrollView {
                            KeyGuideView(guide: ProviderGuide.matching(subscription))
                                .padding(16)
                        }
                        .frame(width: 400, height: 380)
                    }
                }
            }
            .quickHelpArea(JobsHelp.section("API Key"))

            Section {
                KeyValueEditor(items: $subscription.defaultHeaders, keyPrompt: "header", valuePrompt: "value",
                               addTitle: "Add Header")
            } header: {
                Text("Headers Sent With Every Call")
            }
            .quickHelpArea(JobsHelp.section("Headers Sent With Every Call"))

            Section {
                HStack {
                    TextField("Project folder", text: $subscription.projectFolder, prompt: Text("~/path/to/service"))
                        .font(.body.monospaced())
                    Button("Choose…") { chooseFolder() }
                }
                Picker("Open with", selection: $subscription.ide) {
                    ForEach(IDEChoice.allCases) { ide in
                        Text(ProjectOpener.isInstalled(ide) ? ide.title : "\(ide.title) (not installed)").tag(ide)
                    }
                }
                if !subscription.projectFolder.isEmpty {
                    OpenProjectButton(subscription: subscription)
                }
            } header: {
                Text("Source Project")
            } footer: {
                Text("For services you develop, such as Services/portfolio-java or Services/portfolio-cpp: steps using this subscription get an “Open Project” button.")
            }
            .quickHelpArea(JobsHelp.section("Source Project"))

            Section("Notes") {
                TextField("Notes", text: $subscription.notes, axis: .vertical)
                    .lineLimit(2...6)
                    .labelsHidden()
            }
            .quickHelpArea(JobsHelp.section("Notes"))
        }
        .formStyle(.grouped)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        ProjectOpener.remember(url)  // lets CLion / Xcode / Finder be handed the folder later
        let home = ProjectOpener.realHome
        subscription.projectFolder = url.path.hasPrefix(home + "/") ? "~" + url.path.dropFirst(home.count) : url.path
    }
}
