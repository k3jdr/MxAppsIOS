//
//  InspectorView.swift
//  MxJobsMGR
//
//  The properties panel on the right. With a node selected: its general settings,
//  the kind-specific settings (schedule, agent instructions, approval, execution,
//  API call, field mappings), arguments, expected outcome and exception handling.
//  With a link selected: its label. With nothing selected: the jobspace itself.
//

import SwiftUI

struct InspectorView: View {
    @Binding var space: Jobspace
    @Bindable var editor: EditorState
    var issues: [ValidationIssue]

    var body: some View {
        Group {
            if editor.selectedNodes.count == 1, let id = editor.selectedNodes.first, let i = space.index(of: id) {
                NodeInspector(node: $space.nodes[i], space: $space, editor: editor,
                              issues: issues.filter { $0.nodeID == id })
                    .id(id)
            } else if editor.selectedNodes.count > 1 {
                ContentUnavailableView("\(editor.selectedNodes.count) Nodes Selected", systemImage: "square.on.square",
                                       description: Text("Drag to move them together, ⌘D to duplicate, Delete to remove."))
            } else if let linkID = editor.selectedLink, let i = space.links.firstIndex(where: { $0.id == linkID }) {
                LinkInspector(link: $space.links[i], space: space)
            } else {
                JobspaceInspector(space: $space, editor: editor, issues: issues)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .quickHelpArea(JobsHelp.inspector(space, editor: editor))
    }
}

// MARK: - Jobspace

private struct JobspaceInspector: View {
    @Binding var space: Jobspace
    var editor: EditorState
    var issues: [ValidationIssue]

    var body: some View {
        Form {
            Section("Jobspace") {
                TextField("Name", text: $space.name)
                TextField("Description", text: $space.description, axis: .vertical)
                    .lineLimit(3...8)
            }
            Section("Layers") {
                ForEach(Layer.allCases) { layer in
                    LabeledContent {
                        Text("\(space.nodes.filter { $0.layer == layer }.count) nodes")
                    } label: {
                        Label("\(layer.rawValue) · \(layer.title)", systemImage: "square.fill")
                            .foregroundStyle(layer.color)
                    }
                }
                LabeledContent("Links", value: "\(space.links.count)")
            }
            Section {
                if space.subscriptions.isEmpty {
                    Text("No subscriptions yet").foregroundStyle(.secondary)
                }
                ForEach(space.subscriptions) { sub in
                    LabeledContent {
                        KeyStatus(subscription: sub)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(sub.name)
                            Text(sub.baseURL).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Button("Manage API Subscriptions…") { editor.showSubscriptions = true }
                    .quickHelp("Manage API Subscriptions", "Opens API Subscriptions: each data service's base URL, how its key is sent, headers, and the key itself (kept in your Keychain).", shortcut: "⌥⌘K", symbol: "key.horizontal")
            } header: {
                Text("Layer 3 API Subscriptions")
            }
            Section("Checks") {
                if issues.isEmpty {
                    Label("No problems found", systemImage: "checkmark.seal").foregroundStyle(.green)
                } else {
                    IssueList(issues: issues, editor: editor)
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct KeyStatus: View {
    var subscription: ApiSubscription
    var body: some View {
        let _ = KeychainChanges.shared.revision  // redraw when a key is saved or removed
        if subscription.auth == .none {
            Text("No key needed").font(.caption).foregroundStyle(.secondary)
        } else if subscription.auth == .localService {
            Text(Keychain.hasSecret(for: subscription.keychainAccount) ? "Local · token stored" : "Local · no token")
                .font(.caption).foregroundStyle(.secondary)
        } else if Keychain.hasSecret(for: subscription.keychainAccount) {
            Label("Key stored", systemImage: "key.fill").font(.caption).foregroundStyle(.green)
        } else {
            Label("No key", systemImage: "key.slash").font(.caption).foregroundStyle(.orange)
        }
    }
}

struct IssueList: View {
    var issues: [ValidationIssue]
    var editor: EditorState

    var body: some View {
        ForEach(issues) { issue in
            Button {
                if let id = issue.nodeID {
                    editor.select(node: id)
                } else if let sub = issue.subscriptionID {
                    editor.subscriptionToEdit = sub
                    editor.showSubscriptions = true
                }
                editor.showIssues = false
            } label: {
                Label {
                    Text(issue.message).multilineTextAlignment(.leading)
                } icon: {
                    Image(systemName: issue.severity.symbol).foregroundStyle(issue.severity.color)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Link

private struct LinkInspector: View {
    @Binding var link: JobLink
    var space: Jobspace

    var body: some View {
        Form {
            Section("Link") {
                LabeledContent("From", value: space.node(link.from)?.title ?? "–")
                LabeledContent("To", value: space.node(link.to)?.title ?? "–")
                TextField("Label", text: $link.label, prompt: Text("e.g. prices, approved"))
            }
            Section {
                Text("Links pointing down the layers are calls; links pointing up (dashed) carry results back. Press Delete to remove the link.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Node

private struct NodeInspector: View {
    @Binding var node: JobNode
    @Binding var space: Jobspace
    var editor: EditorState
    var issues: [ValidationIssue]

    var body: some View {
        Form {
            Section {
                HStack(spacing: 8) {
                    Image(systemName: node.kind.symbol)
                        .font(.title2)
                        .foregroundStyle(node.kind.color)
                        .frame(width: 30)
                    VStack(alignment: .leading) {
                        Text(node.kind.title).font(.headline)
                        Text("Layer \(node.layer.rawValue) · \(node.layer.title)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                TextField("Title", text: $node.title)
                Toggle("Enabled", isOn: $node.enabled)
                Toggle("Breakpoint — pause runs before this step", isOn: $node.breakpoint)
                TextField("Notes", text: $node.notes, axis: .vertical)
                    .lineLimit(2...6)
            }

            if !issues.isEmpty {
                Section("Checks") { IssueList(issues: issues, editor: editor) }
                    .quickHelpArea(JobsHelp.section("Checks"))
            }

            if let state = editor.run.states[node.id], state != .pending {
                Section("Last Run") {
                    Label(state.title, systemImage: state.symbol).foregroundStyle(state.color)
                    if let message = editor.run.log.last(where: { $0.nodeID == node.id && $0.level >= .success })?.message
                        ?? editor.run.log.last(where: { $0.nodeID == node.id })?.message {
                        Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Button("Show Output in Console") { editor.showConsole = true }
                }
                .quickHelpArea(JobsHelp.section("Last Run"))
            }

            kindSection

            Section {
                ArgumentsEditor(arguments: $node.arguments)
            } header: {
                Text("Arguments")
            } footer: {
                Text("Use {{name}} in paths, parameters, headers and templates. Built-ins: {{today}}, {{yesterday}}.")
            }
            .quickHelpArea(JobsHelp.section("Arguments"))

            OutcomeSection(outcome: $node.outcome, isAPI: node.kind == .apiRead,
                           inputs: space.inputNames(for: node.id))
                .quickHelpArea(JobsHelp.section("Expected Outcome"))

            ExceptionSection(policy: $node.exceptions)
                .quickHelpArea(JobsHelp.section("Exception Handling"))
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private var kindSection: some View {
        switch node.kind {
        case .trigger:
            ScheduleSection(spec: Binding($node.schedule, default: ScheduleSpec()))
                .quickHelpArea(JobsHelp.section("Schedule"))
        case .instructionSet, .agentTask, .aggregate, .decision:
            AgentSection(kind: node.kind, spec: Binding($node.agent, default: AgentSpec()),
                         available: space.inputNames(for: node.id))
                .quickHelpArea(JobsHelp.section(node.kind == .instructionSet ? "Instruction Assembly" : node.kind == .decision ? "Decision" : "Agent"))
        case .approvalGate:
            ApprovalSection(spec: Binding($node.approval, default: ApprovalSpec()))
                .quickHelpArea(JobsHelp.section("User Approval"))
        case .executeRequest:
            ExecutionSection(spec: Binding($node.execution, default: ExecutionSpec()))
                .quickHelpArea(JobsHelp.section("Execution Request"))
        case .outcomeReport:
            ReportSection(spec: Binding($node.report, default: ReportSpec()))
                .quickHelpArea(JobsHelp.section("Outcome Report"))
        case .apiRead:
            ApiSection(node: $node, space: space, editor: editor)
        case .pythonScript:
            ScriptSection(node: $node, space: space, editor: editor)
        case .dataNormalize:
            Section {
                KeyValueEditor(items: Binding($node.transform, default: TransformSpec()).mappings,
                               keyPrompt: "output field", valuePrompt: "JSON path", addTitle: "Add Mapping")
            } header: {
                Text("Field Mappings")
            } footer: {
                Text("Each output field takes the value at a dotted JSON path of the incoming data.")
            }
            .quickHelpArea(JobsHelp.section("Field Mappings"))
        }
    }
}

extension Binding {
    /// A non-optional binding over an optional value, writing back on change.
    init(_ source: Binding<Value?>, default fallback: Value) {
        self.init(get: { source.wrappedValue ?? fallback }, set: { source.wrappedValue = $0 })
    }
}

private struct ScheduleSection: View {
    @Binding var spec: ScheduleSpec
    var body: some View {
        Section("Schedule") {
            Picker("Runs", selection: $spec.mode) {
                Text("Manually").tag(ScheduleMode.manual)
                Text("Daily").tag(ScheduleMode.daily)
                Text("Weekdays").tag(ScheduleMode.weekdays)
                Text("Every N minutes").tag(ScheduleMode.interval)
            }
            if spec.mode == .daily || spec.mode == .weekdays {
                TextField("Time (HH:mm)", text: $spec.time)
                TextField("Time zone", text: $spec.timeZone)
            }
            if spec.mode == .interval {
                Stepper("Every \(spec.intervalMinutes) minutes", value: $spec.intervalMinutes, in: 1...1440, step: 5)
            }
        }
    }
}

private struct AgentSection: View {
    var kind: NodeKind
    @Binding var spec: AgentSpec
    var available: [String]

    var body: some View {
        Section {
            TextField(kind == .instructionSet ? "Assembly instructions" : "Instructions",
                      text: $spec.instructions, axis: .vertical)
                .lineLimit(3...10)
            if kind != .instructionSet {
                TextField("Model / engine", text: $spec.model, prompt: Text("e.g. claude-sonnet-5-5"))
            }
            TextField("Output format", text: $spec.outputFormat, prompt: Text("e.g. JSON array of instructions"))
            StringListEditor(items: $spec.inputs, prompt: "input name", addTitle: "Add Input", suggestions: available)
        } header: {
            Text(kind == .instructionSet ? "Instruction Assembly" : kind == .decision ? "Decision" : "Agent")
        } footer: {
            if !available.isEmpty {
                Text("Linked inputs: \(available.joined(separator: ", "))")
            }
        }
    }
}

private struct ApprovalSection: View {
    @Binding var spec: ApprovalSpec
    var body: some View {
        Section {
            TextField("Approver", text: $spec.approver)
            Picker("Ask via", selection: $spec.channel) {
                ForEach(ApprovalChannel.allCases) { Text($0.title).tag($0) }
            }
            Stepper("Expires after \(spec.expiresAfterMinutes) min", value: $spec.expiresAfterMinutes, in: 5...1440, step: 5)
            Toggle("Require a comment", isOn: $spec.requireComment)
            TextField("Summary shown to the approver", text: $spec.summaryTemplate, axis: .vertical)
                .lineLimit(2...5)
        } header: {
            Text("User Approval")
        } footer: {
            Text("Nothing downstream of this step runs until the user approves.")
        }
    }
}

private struct ExecutionSection: View {
    @Binding var spec: ExecutionSpec
    var body: some View {
        Section("Execution Request") {
            TextField("Target", text: $spec.target, prompt: Text("e.g. Broker API"))
            Picker("Mode", selection: $spec.mode) {
                ForEach(ExecutionMode.allCases) { Text($0.title).tag($0) }
            }
            Toggle("Confirm again before sending", isOn: $spec.confirmBeforeSend)
            if spec.mode == .live {
                Label("Live mode sends real requests once approved.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
            }
        }
    }
}

private struct ReportSection: View {
    @Binding var spec: ReportSpec
    var body: some View {
        Section("Outcome Report") {
            TextField("Recipients", text: $spec.recipients)
            Toggle("Detailed report", isOn: $spec.detailed)
            Toggle("Include failures and data gaps", isOn: $spec.includeFailures)
        }
    }
}

private struct ApiSection: View {
    @Binding var node: JobNode
    var space: Jobspace
    var editor: EditorState
    @State private var testing = false
    @State private var result: ApiTestResult?

    var body: some View {
        let api = Binding($node.api, default: ApiCallSpec())
        if let service = ServiceAboutSection.service(for: space.subscription(node.api?.subscriptionID)) {
            ServiceAboutSection(service: service, path: node.api?.path ?? "")
                .quickHelpArea(JobsHelp.section("About This Service"))
        }
        Section {
            Picker("Subscription", selection: api.subscriptionID) {
                Text("None").tag(UUID?.none)
                ForEach(space.subscriptions) { Text($0.name).tag(Optional($0.id)) }
            }
            if let sub = space.subscription(node.api?.subscriptionID), !sub.projectFolder.isEmpty {
                OpenProjectButton(subscription: sub)
            }
            if let sub = space.subscription(node.api?.subscriptionID) {
                LabeledContent("Base URL") {
                    Text(sub.baseURL).textSelection(.enabled).lineLimit(1)
                }
                LabeledContent("API key") { KeyStatus(subscription: sub) }
            }
            Button("Manage API Subscriptions…") {
                editor.subscriptionToEdit = node.api?.subscriptionID
                editor.showSubscriptions = true
            }
            .quickHelp("Manage API Subscriptions", "Opens API Subscriptions at this step's subscription: its base URL, how its key is sent, headers, and the key itself (kept in your Keychain).", shortcut: "⌥⌘K", symbol: "key.horizontal")
            Picker("Method", selection: api.method) {
                ForEach(HTTPMethod.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            TextField("Endpoint path", text: api.path, prompt: Text("/query"))
                .font(.body.monospaced())
        } header: {
            Text("API Call")
        }
        .quickHelpArea(JobsHelp.section("API Call"))

        Section("Query Parameters") {
            KeyValueEditor(items: api.query, keyPrompt: "name", valuePrompt: "value", addTitle: "Add Parameter")
        }
        .quickHelpArea(JobsHelp.section("Query Parameters"))
        Section("Headers") {
            KeyValueEditor(items: api.headers, keyPrompt: "header", valuePrompt: "value", addTitle: "Add Header")
        }
        .quickHelpArea(JobsHelp.section("Headers"))
        if node.api?.method == .POST {
            Section("Body (JSON)") {
                TextEditor(text: api.body)
                    .font(.body.monospaced())
                    .frame(minHeight: 80)
            }
        }

        Section {
            HStack {
                Button {
                    runTest()
                } label: {
                    Label("Test Call", systemImage: "bolt.horizontal")
                }
                .disabled(testing || space.subscription(node.api?.subscriptionID) == nil)
                if testing { ProgressView().controlSize(.small) }
                Spacer()
                if let result, result.error == nil {
                    Text("\(result.status ?? 0) · \(Int(result.elapsed * 1000)) ms")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(result.passed ? .green : .orange)
                }
            }
            if let result { TestResultView(result: result) }
        } header: {
            Text("Try It")
        } footer: {
            Text("Sends one request now with the stored key and checks the expected outcome.")
        }
        .quickHelpArea(JobsHelp.section("Try It"))
    }

    private func runTest() {
        guard let sub = space.subscription(node.api?.subscriptionID) else { return }
        testing = true
        result = nil
        let snapshot = node
        // The outputs of the steps linked into this one from the last run ({{in:…}} placeholders).
        var inputs: [String: Any] = [:]
        for link in space.links where link.to == node.id {
            guard let from = space.node(link.from), let value = editor.run.output(of: from.id) else { continue }
            inputs[from.outcome.outputName.isEmpty ? from.title : from.outcome.outputName] = value
        }
        Task {
            result = await ApiTester.run(node: snapshot, subscription: sub, inputs: inputs)
            testing = false
        }
    }
}

/// What the Layer 3 service behind a step is for, from the shared catalog (Services/).
struct ServiceAboutSection: View {
    var service: ServiceInfo
    var path: String
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Section {
            HStack(alignment: .firstTextBaseline) {
                LanguageBadge(language: service.language)
                Text(service.name).font(.callout.weight(.semibold))
            }
            Text(service.purpose).font(.callout)
            if let endpoint = service.endpoints.first(where: { path.hasPrefix($0.path.components(separatedBy: "{").first ?? $0.path)
                                                                 && !$0.path.isEmpty && $0.path != "/" }) {
                LabeledContent("This call") {
                    Text(endpoint.summary + (endpoint.contract.map { " · \($0)" } ?? "")).foregroundStyle(.secondary)
                }
            }
            LabeledContent("Use it for") {
                Text(service.cases.map(\.title).joined(separator: ", ")).foregroundStyle(.secondary)
            }
            Button("Layer 3 Services…") { openWindow(id: "services") }
        } header: {
            Text("About This Service")
        }
    }

    /// The catalog service a subscription points at (by local port).
    static func service(for sub: ApiSubscription?) -> ServiceInfo? {
        guard let sub, let url = URL(string: sub.baseURL), let host = url.host(),
              host == "127.0.0.1" || host == "localhost", let port = url.port else { return nil }
        return ServiceCatalog.all.first { $0.port == port }
    }
}

private struct ScriptSection: View {
    @Binding var node: JobNode
    var space: Jobspace
    var editor: EditorState
    @State private var testing = false
    @State private var result: ApiTestResult?

    var body: some View {
        let spec = Binding($node.script, default: ScriptSpec())
        let found = PythonRunner.locate(node.script?.interpreter ?? "")
        Section {
            TextField("Interpreter", text: spec.interpreter,
                      prompt: Text(PythonRunner.locate("") ?? "python3 path (none found)"))
                .font(.body.monospaced())
            if found == nil {
                Label(node.script?.interpreter.isEmpty ?? true
                      ? "No python3 found — install Python (brew install python) or enter its path."
                      : "Not found or not executable.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Picker("Subscription", selection: spec.subscriptionID) {
                Text("None").tag(UUID?.none)
                ForEach(space.subscriptions) { Text($0.name).tag(Optional($0.id)) }
            }
            if let sub = space.subscription(node.script?.subscriptionID) {
                LabeledContent("API key") { KeyStatus(subscription: sub) }
            }
        } header: {
            Text("Python Script")
        } footer: {
            Text("The script reads {\"arguments\", \"inputs\", \"step\"} as JSON on stdin and prints its output as JSON. "
                 + "The subscription's key and base URL arrive as MXJOBS_API_KEY and MXJOBS_BASE_URL.")
        }
        .quickHelpArea(JobsHelp.section("Python Script"))

        Section {
            TextEditor(text: spec.code)
                .font(.system(.callout, design: .monospaced))
                .autocorrectionDisabled()
                .frame(minHeight: 220)
            if node.script?.code != ScriptSpec.template {
                Button("Reset to Template") { node.script?.code = ScriptSpec.template }
                    .font(.caption)
            }
        } header: {
            Text("Code")
        }
        .quickHelpArea(JobsHelp.section("Code"))

        Section {
            HStack {
                Button {
                    runTest()
                } label: {
                    Label("Run Script", systemImage: "play")
                }
                .disabled(testing || found == nil)
                if testing { ProgressView().controlSize(.small) }
                Spacer()
                if let result, result.error == nil {
                    Text("exit \(result.status ?? -1) · \(Int(result.elapsed * 1000)) ms")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(result.passed ? .green : .orange)
                }
            }
            if let result { TestResultView(result: result) }
        } header: {
            Text("Try It")
        } footer: {
            Text("Runs the script once with the arguments above and the inputs from the last run, then checks the expected outcome.")
        }
        .quickHelpArea(JobsHelp.section("Try It"))
    }

    private func runTest() {
        testing = true
        result = nil
        let snapshot = node
        let sub = space.subscription(node.script?.subscriptionID)
        var inputs: [String: Any] = [:]
        for link in space.links where link.to == node.id {
            guard let from = space.node(link.from), let value = editor.run.output(of: from.id) else { continue }
            inputs[from.outcome.outputName.isEmpty ? from.title : from.outcome.outputName] = value
        }
        Task {
            result = await PythonRunner.run(node: snapshot, subscription: sub, inputs: inputs)
            testing = false
        }
    }
}

private struct TestResultView: View {
    var result: ApiTestResult
    var body: some View {
        if let error = result.error {
            Label(error, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .textSelection(.enabled)
        }
        if !result.url.isEmpty {
            Text(result.url)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        ForEach(Array(result.checks.enumerated()), id: \.offset) { _, check in
            Label(check.label, systemImage: check.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(check.passed ? .green : .red)
                .font(.caption)
        }
        if !result.body.isEmpty {
            ScrollView {
                Text(result.body)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 200)
        }
    }
}

private struct OutcomeSection: View {
    @Binding var outcome: ExpectedOutcome
    var isAPI: Bool
    var inputs: [String]

    var body: some View {
        Section {
            TextField("Description", text: $outcome.description, axis: .vertical)
                .lineLimit(1...4)
            TextField("Output name", text: $outcome.outputName, prompt: Text("published to downstream nodes"))
            if isAPI {
                TextField("Success HTTP status", text: $outcome.successStatus, prompt: Text("200-299"))
            }
            StringListEditor(items: $outcome.requiredFields, prompt: "dotted.json.path", addTitle: "Add Required Field")
            AssertionsEditor(assertions: $outcome.assertions)
        } header: {
            Text("Expected Outcome")
        } footer: {
            Text("The step fails when the status, a required field or a value check fails; the exception handling below then applies. "
                 + "Values may use {{argument}}.")
        }
    }
}

private struct AssertionsEditor: View {
    @Binding var assertions: [ValueAssertion]

    var body: some View {
        ForEach($assertions) { $a in
            HStack(spacing: 6) {
                TextField("path", text: $a.path, prompt: Text("solverStatus"))
                    .labelsHidden()
                    .font(.callout.monospaced())
                Picker("Check", selection: $a.op) {
                    ForEach(AssertionOp.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .frame(width: 84)
                if a.op != .exists {
                    TextField("value", text: $a.value, prompt: Text("optimal"))
                        .labelsHidden()
                        .font(.callout.monospaced())
                }
                Button {
                    assertions.removeAll { $0.id == a.id }
                } label: {
                    Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Remove")
            }
        }
        Button("Add Value Check", systemImage: "plus") { assertions.append(ValueAssertion()) }
    }
}

private struct ExceptionSection: View {
    @Binding var policy: ExceptionPolicy
    var body: some View {
        Section("Exception Handling") {
            Picker("On failure", selection: $policy.onFailure) {
                ForEach(FailureAction.allCases) { Text($0.title).tag($0) }
            }
            if policy.onFailure == .retry {
                Stepper("Retries: \(policy.maxRetries)", value: $policy.maxRetries, in: 0...10)
                Stepper("Delay: \(policy.retryDelaySeconds) s", value: $policy.retryDelaySeconds, in: 0...600)
                Toggle("Exponential backoff", isOn: $policy.exponentialBackoff)
            }
            if policy.onFailure == .useFallback {
                TextField("Fallback value", text: $policy.fallbackValue)
            }
            Stepper("Timeout: \(policy.timeoutSeconds) s", value: $policy.timeoutSeconds, in: 1...7200,
                    step: policy.timeoutSeconds >= 120 ? 60 : 5)
            Toggle("Notify the user on failure", isOn: $policy.notifyUser)
        }
    }
}

// MARK: - List editors

struct ArgumentsEditor: View {
    @Binding var arguments: [Argument]
    var body: some View {
        ForEach($arguments) { $arg in
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    TextField("name", text: $arg.name, prompt: Text("name"))
                        .labelsHidden()
                    Picker("Type", selection: $arg.type) {
                        ForEach(ArgumentType.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 90)
                    RemoveButton { arguments.removeAll { $0.id == arg.id } }
                }
                HStack {
                    TextField("value", text: $arg.value, prompt: Text(arg.type == .symbols ? "AAPL,MSFT" : "value"))
                        .labelsHidden()
                    Toggle("Required", isOn: $arg.required)
                        .toggleStyle(.checkbox)
                }
            }
        }
        Button("Add Argument", systemImage: "plus") { arguments.append(Argument()) }
    }
}

struct KeyValueEditor: View {
    @Binding var items: [KeyValue]
    var keyPrompt: String
    var valuePrompt: String
    var addTitle: String

    var body: some View {
        ForEach($items) { $item in
            HStack {
                TextField(keyPrompt, text: $item.key, prompt: Text(keyPrompt))
                    .labelsHidden()
                TextField(valuePrompt, text: $item.value, prompt: Text(valuePrompt))
                    .labelsHidden()
                RemoveButton { items.removeAll { $0.id == item.id } }
            }
        }
        Button(addTitle, systemImage: "plus") { items.append(KeyValue()) }
    }
}

struct StringListEditor: View {
    @Binding var items: [String]
    var prompt: String
    var addTitle: String
    var suggestions: [String] = []

    var body: some View {
        ForEach(items.indices, id: \.self) { i in
            HStack {
                TextField(prompt, text: Binding(get: { items.indices.contains(i) ? items[i] : "" },
                                                set: { if items.indices.contains(i) { items[i] = $0 } }),
                          prompt: Text(prompt))
                    .labelsHidden()
                RemoveButton { if items.indices.contains(i) { items.remove(at: i) } }
            }
        }
        HStack {
            Button(addTitle, systemImage: "plus") { items.append("") }
            let missing = suggestions.filter { !items.contains($0) }
            if !missing.isEmpty {
                Menu("Linked") {
                    ForEach(missing, id: \.self) { s in Button(s) { items.append(s) } }
                }
                .fixedSize()
            }
        }
    }
}

private struct RemoveButton: View {
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .help("Remove")
    }
}

/// "Open in IDE" for a subscription's source project.
struct OpenProjectButton: View {
    var subscription: ApiSubscription
    @State private var message: String?
    @State private var refresh = 0

    var body: some View {
        let _ = refresh
        let needsAccess = ProjectOpener.needsAccess(subscription.projectFolder, for: subscription.ide)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button {
                    message = nil
                    ProjectOpener.open(subscription.projectFolder, in: subscription.ide) { message = $0 }
                } label: {
                    Label("Open Project in \(subscription.ide.title)", systemImage: "hammer")
                }
                .help(ProjectOpener.expand(subscription.projectFolder))
                if needsAccess && ProjectOpener.isInstalled(subscription.ide) {
                    Button("Grant Access…") {
                        if ProjectOpener.grantAccess(startingAt: subscription.projectFolder) != nil {
                            message = nil
                            refresh += 1
                        }
                    }
                    .help("\(subscription.ide.title) has no URL scheme: choose the folder once so MxJobsMGR may hand it over.")
                }
            }
            if let message {
                Text(message).font(.caption).foregroundStyle(.orange)
            }
        }
    }
}
