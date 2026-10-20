//
//  SubscriptionsDialog.swift
//  MxJobsWMS
//
//  Layer 3 configuration: the API subscriptions of the jobspace (base URL, how the
//  key is sent, rate limit, default headers) and their keys, kept in the Keychain.
//

import SwiftUI

struct SubscriptionsDialog: View {
    @Binding var space: Jobspace
    var editor: EditorState
    @Environment(\.dismiss) private var dismiss

    @State private var selection: UUID?
    @State private var confirmDelete = false

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
                .quickHelpArea("Subscriptions", "This jobspace's API subscriptions and whether each has its key stored. Select one to edit it; − deletes it and its stored key.", symbol: "list.bullet")

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
                Text("API keys are kept in your Keychain, never in the jobspace file.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
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
        .confirmationDialog("Delete this subscription?", isPresented: $confirmDelete) {
            Button("Delete Subscription and Key", role: .destructive) { deleteSelected() }
        } message: {
            let n = selection.map(usage(of:)) ?? 0
            Text(n > 0 ? "\(n) API read\(n == 1 ? "" : "s") use it and will be left without a subscription. Its stored key is removed from the Keychain."
                       : "Its stored key is removed from the Keychain.")
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
        guard let id = selection, let sub = space.subscription(id) else { return }
        Keychain.deleteSecret(for: sub.keychainAccount)
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

    @State private var newKey = ""
    @State private var hasKey = false
    @State private var keyMessage: String?
    @State private var showHelp = false
    @State private var testing = false
    @State private var testResult: KeyTestResult?

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
                        Text("Optional: store a token only if the service requires one (sent as “Authorization: Bearer …”).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent(subscription.auth == .localService ? "Token" : "API key") {
                        HStack {
                            // AppKit field: reports every change (typing or pasting), so Save Key sees it at once.
                            SecureKeyField(placeholder: hasKey ? "Paste to replace the stored key"
                                                               : subscription.auth == .localService ? "Optional token" : "Paste your key",
                                           text: $newKey,
                                           onSubmit: saveKey)
                                .frame(minWidth: 160)
                            Button("Save Key", action: saveKey)
                                .help("Save the key to your Keychain (or press Return in the field)")
                        }
                    }
                    HStack {
                        Spacer()
                        Button {
                            pasteAndSave()
                        } label: {
                            Label("Paste & Save", systemImage: "doc.on.clipboard")
                        }
                        .controlSize(.small)
                        .help("Save the key on the clipboard without pasting it into the field")
                    }
                    HStack {
                        if hasKey {
                            Label("Key stored in Keychain", systemImage: "key.fill").foregroundStyle(.green)
                            Spacer()
                            Button {
                                runKeyTest()
                            } label: {
                                Label("Test Key", systemImage: "checkmark.shield")
                            }
                            .disabled(testing)
                            Button("Remove Key", role: .destructive) {
                                Keychain.deleteSecret(for: subscription.keychainAccount)
                                refresh()
                                keyMessage = "Key removed."
                            }
                        } else {
                            Label("No key stored", systemImage: "key.slash").foregroundStyle(.orange)
                        }
                    }
                    if let keyMessage {
                        Text(keyMessage).font(.caption).foregroundStyle(.secondary)
                    }
                    if testing {
                        HStack { ProgressView().controlSize(.small); Text("Testing the key…").font(.caption) }
                    } else if let testResult {
                        Label(testResult.message, systemImage: testResult.symbol)
                            .font(.caption)
                            .foregroundStyle(testResult.color)
                            .textSelection(.enabled)
                    }
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
        .onAppear(perform: refresh)
    }

    private func refresh() {
        hasKey = Keychain.hasSecret(for: subscription.keychainAccount)
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

    private func runKeyTest() {
        testing = true
        testResult = nil
        let sub = subscription
        Task {
            testResult = await KeyTester.test(sub)
            testing = false
        }
    }

    private func pasteAndSave() {
        guard let text = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            keyMessage = "The clipboard has no text. Copy your key first."
            return
        }
        guard !text.contains("\n"), text.count <= 512 else {
            keyMessage = "The clipboard holds more than a key (several lines or very long text). Copy just the key."
            return
        }
        newKey = text
        saveKey()
    }

    private func saveKey() {
        let key = newKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            keyMessage = "Paste your key into the field first (or use Paste & Save)."
            return
        }
        if Keychain.setSecret(key, for: subscription.keychainAccount, label: subscription.name) {
            keyMessage = "Key saved to your Keychain."
            runKeyTest()
            newKey = ""
        } else {
            keyMessage = "The key could not be saved to the Keychain."
        }
        refresh()
    }
}

/// A secure text field that updates its binding on every edit (typing and pasting) and calls
/// `onSubmit` on Return. SwiftUI's SecureField did not pass a paste on until the field lost focus,
/// which left Save Key disabled.
struct SecureKeyField: NSViewRepresentable {
    var placeholder: String
    @Binding var text: String
    var onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSSecureTextField {
        let field = NSSecureTextField()
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.submit(_:))
        field.bezelStyle = .roundedBezel
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSSecureTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        field.placeholderString = placeholder
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SecureKeyField
        init(_ parent: SecureKeyField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        @objc func submit(_ sender: NSTextField) {
            parent.text = sender.stringValue
            guard !sender.stringValue.isEmpty else { return }
            parent.onSubmit()
        }
    }
}
