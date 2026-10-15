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
                        Button {
                            let sub = ApiSubscription()
                            space.subscriptions.append(sub)
                            selection = sub.id
                        } label: { Image(systemName: "plus").frame(width: 24, height: 20) }
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

    private func usage(of id: UUID) -> Int {
        space.nodes.filter { $0.api?.subscriptionID == id }.count
    }

    private func deleteSelected() {
        guard let id = selection, let sub = space.subscription(id) else { return }
        Keychain.deleteSecret(for: sub.keychainAccount)
        space.subscriptions.removeAll { $0.id == id }
        for i in space.nodes.indices where space.nodes[i].api?.subscriptionID == id {
            space.nodes[i].api?.subscriptionID = nil
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
                    LabeledContent("Used by", value: "\(usage) API read\(usage == 1 ? "" : "s")")
                }
            }

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
                    HStack {
                        SecureField(hasKey ? "Replace stored key" : "API key", text: $newKey)
                        Button("Save Key") { saveKey() }
                            .disabled(newKey.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    HStack {
                        if hasKey {
                            Label("Key stored in Keychain", systemImage: "key.fill").foregroundStyle(.green)
                            Spacer()
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
                }
            } header: {
                Text("API Key")
            }

            Section {
                KeyValueEditor(items: $subscription.defaultHeaders, keyPrompt: "header", valuePrompt: "value",
                               addTitle: "Add Header")
            } header: {
                Text("Headers Sent With Every Call")
            }

            Section("Notes") {
                TextField("Notes", text: $subscription.notes, axis: .vertical)
                    .lineLimit(2...6)
                    .labelsHidden()
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refresh)
    }

    private func refresh() {
        hasKey = Keychain.hasSecret(for: subscription.keychainAccount)
    }

    private func saveKey() {
        let key = newKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if Keychain.setSecret(key, for: subscription.keychainAccount, label: subscription.name) {
            keyMessage = "Key saved to your Keychain."
            newKey = ""
        } else {
            keyMessage = "The key could not be saved to the Keychain."
        }
        refresh()
    }
}
