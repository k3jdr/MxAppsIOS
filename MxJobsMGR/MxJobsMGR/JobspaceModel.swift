//
//  JobspaceModel.swift
//  MxJobsMGR
//
//  The data behind a jobspace (*.jobspace, JSON): the API subscriptions,
//  the nodes of the three-layer operation diagram and the links between them.
//
//  Layer 1  Business operations  – trigger, assemble instructions, user approval,
//                                  execution request, outcome report
//  Layer 2  Agentic operations   – agents that call Layer 3 and shape the data
//  Layer 3  Data reads           – API calls (with keys) against subscriptions
//
//  Every decoder tolerates missing keys so files saved by earlier versions keep opening.
//  API keys are never written to the file; they live in the Keychain (Keychain.swift).
//

import Foundation

nonisolated extension KeyedDecodingContainer {
    /// Decodes `key` if it is present and valid, otherwise returns `fallback`.
    func value<T: Decodable>(_ key: Key, _ fallback: @autoclosure () -> T) -> T {
        ((try? decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback()
    }
}

// MARK: - Layers and node kinds

nonisolated enum Layer: Int, Codable, CaseIterable, Identifiable, Sendable {
    case operations = 1
    case agents = 2
    case data = 3

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .operations: "Business Operations"
        case .agents: "Agentic Operations"
        case .data: "Data Reads"
        }
    }

    var subtitle: String {
        switch self {
        case .operations: "Refresh, assemble instructions, approve, execute, report"
        case .agents: "Agents calling the data services and preparing instructions"
        case .data: "API calls against subscriptions, with keys when needed"
        }
    }
}

nonisolated enum NodeKind: String, Codable, CaseIterable, Identifiable, Sendable {
    // Layer 1
    case trigger, instructionSet, approvalGate, executeRequest, outcomeReport
    // Layer 2
    case agentTask, aggregate, decision
    // Layer 3
    case apiRead, pythonScript, dataNormalize

    var id: String { rawValue }

    var layer: Layer {
        switch self {
        case .trigger, .instructionSet, .approvalGate, .executeRequest, .outcomeReport: .operations
        case .agentTask, .aggregate, .decision: .agents
        case .apiRead, .pythonScript, .dataNormalize: .data
        }
    }

    var title: String {
        switch self {
        case .trigger: "Refresh Trigger"
        case .instructionSet: "Assemble Instructions"
        case .approvalGate: "User Approval"
        case .executeRequest: "Execution Request"
        case .outcomeReport: "Outcome Report"
        case .agentTask: "Agent Task"
        case .aggregate: "Aggregate Results"
        case .decision: "Decision"
        case .apiRead: "API Data Read"
        case .pythonScript: "Python Script"
        case .dataNormalize: "Normalize Data"
        }
    }

    var summary: String {
        switch self {
        case .trigger: "Starts the day-to-day market data refresh"
        case .instructionSet: "Builds the instructions presented for approval"
        case .approvalGate: "Waits for the user to approve the instructions"
        case .executeRequest: "Sends the approved instructions to be executed"
        case .outcomeReport: "Reports the outcomes back to the user"
        case .agentTask: "An agent gathering data points through Layer 3"
        case .aggregate: "Combines the results of several agents"
        case .decision: "Routes the flow on a condition"
        case .apiRead: "Calls an API endpoint of a subscription"
        case .pythonScript: "Runs Python: arguments in as JSON, JSON out"
        case .dataNormalize: "Maps raw response fields to named data points"
        }
    }

    var symbol: String {
        switch self {
        case .trigger: "clock.arrow.circlepath"
        case .instructionSet: "list.bullet.clipboard"
        case .approvalGate: "person.badge.shield.checkmark"
        case .executeRequest: "paperplane"
        case .outcomeReport: "doc.text.magnifyingglass"
        case .agentTask: "cpu"
        case .aggregate: "arrow.triangle.merge"
        case .decision: "arrow.triangle.branch"
        case .apiRead: "network"
        case .pythonScript: "terminal"
        case .dataNormalize: "tablecells"
        }
    }

    static func kinds(in layer: Layer) -> [NodeKind] { allCases.filter { $0.layer == layer } }
}

// MARK: - Shared node settings

/// A named key/value pair (query parameters, headers, field mappings).
nonisolated struct KeyValue: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var key = ""
    var value = ""

    init(_ key: String = "", _ value: String = "") {
        self.key = key
        self.value = value
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, UUID())
        key = c.value(.key, "")
        value = c.value(.value, "")
    }
}

nonisolated enum ArgumentType: String, Codable, CaseIterable, Identifiable, Sendable {
    case text, number, date, symbols, boolean
    var id: String { rawValue }
}

/// An argument a node expects. Its value can be used as {{name}} in API paths, parameters and bodies.
nonisolated struct Argument: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var name = ""
    var type = ArgumentType.text
    var value = ""
    var required = false

    init(_ name: String = "", _ value: String = "", type: ArgumentType = .text, required: Bool = false) {
        self.name = name
        self.value = value
        self.type = type
        self.required = required
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, UUID())
        name = c.value(.name, "")
        type = c.value(.type, .text)
        value = c.value(.value, "")
        required = c.value(.required, false)
    }
}

/// What a node must produce to count as successful.
nonisolated struct ExpectedOutcome: Codable, Equatable, Sendable {
    var description = ""
    /// For API reads: accepted HTTP status codes, e.g. "200-299" or "200,304".
    var successStatus = "200-299"
    /// Dotted JSON paths that must be present in the result, e.g. "Global Quote.05. price".
    var requiredFields: [String] = []
    /// Name under which the result is published to downstream nodes.
    var outputName = ""
    /// Checks on values in the result, e.g. solverStatus == optimal, turnover < {{maxTurnover}}.
    var assertions: [ValueAssertion] = []

    init() {}

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        description = c.value(.description, "")
        successStatus = c.value(.successStatus, "200-299")
        requiredFields = c.value(.requiredFields, [])
        outputName = c.value(.outputName, "")
        assertions = c.value(.assertions, [])
    }
}

nonisolated enum AssertionOp: String, Codable, CaseIterable, Identifiable, Sendable {
    case equals = "==", notEquals = "!=", less = "<", lessOrEqual = "<=", greater = ">", greaterOrEqual = ">="
    case contains, exists
    var id: String { rawValue }
}

/// A check on one value of a step's result: `path op value`. The value may use {{argument}} placeholders.
nonisolated struct ValueAssertion: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var path = ""
    var op = AssertionOp.equals
    var value = ""

    init(_ path: String = "", _ op: AssertionOp = .equals, _ value: String = "") {
        self.path = path
        self.op = op
        self.value = value
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, UUID())
        path = c.value(.path, "")
        op = c.value(.op, .equals)
        value = c.value(.value, "")
    }

    var label: String { op == .exists ? "\(path) exists" : "\(path) \(op.rawValue) \(value)" }
}

nonisolated enum FailureAction: String, Codable, CaseIterable, Identifiable, Sendable {
    case retry, skip, useFallback, escalateToUser, abortRun
    var id: String { rawValue }

    var title: String {
        switch self {
        case .retry: "Retry, then fail"
        case .skip: "Skip and continue"
        case .useFallback: "Use fallback value"
        case .escalateToUser: "Ask the user"
        case .abortRun: "Abort the run"
        }
    }
}

/// How a node reacts when it fails or times out.
nonisolated struct ExceptionPolicy: Codable, Equatable, Sendable {
    var onFailure = FailureAction.retry
    var maxRetries = 2
    var retryDelaySeconds = 5
    var exponentialBackoff = true
    var timeoutSeconds = 30
    var fallbackValue = ""
    var notifyUser = true

    init() {}

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ExceptionPolicy()
        onFailure = c.value(.onFailure, d.onFailure)
        maxRetries = c.value(.maxRetries, d.maxRetries)
        retryDelaySeconds = c.value(.retryDelaySeconds, d.retryDelaySeconds)
        exponentialBackoff = c.value(.exponentialBackoff, d.exponentialBackoff)
        timeoutSeconds = c.value(.timeoutSeconds, d.timeoutSeconds)
        fallbackValue = c.value(.fallbackValue, d.fallbackValue)
        notifyUser = c.value(.notifyUser, d.notifyUser)
    }
}

// MARK: - Kind-specific settings

nonisolated enum ScheduleMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case manual, daily, weekdays, interval
    var id: String { rawValue }
}

/// Layer 1 trigger: when the refresh runs.
nonisolated struct ScheduleSpec: Codable, Equatable, Sendable {
    var mode = ScheduleMode.weekdays
    var time = "07:30"
    var timeZone = "America/New_York"
    var intervalMinutes = 60

    init() {}

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ScheduleSpec()
        mode = c.value(.mode, d.mode)
        time = c.value(.time, d.time)
        timeZone = c.value(.timeZone, d.timeZone)
        intervalMinutes = c.value(.intervalMinutes, d.intervalMinutes)
    }

    var summary: String {
        switch mode {
        case .manual: "Run manually"
        case .daily: "Daily at \(time)"
        case .weekdays: "Weekdays at \(time)"
        case .interval: "Every \(intervalMinutes) min"
        }
    }
}

/// Layer 1 instruction assembly and Layer 2 agents: what to do with the incoming data.
nonisolated struct AgentSpec: Codable, Equatable, Sendable {
    var instructions = ""
    var model = ""
    /// Output names of upstream nodes this node reads.
    var inputs: [String] = []
    var outputFormat = ""

    init() {}

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        instructions = c.value(.instructions, "")
        model = c.value(.model, "")
        inputs = c.value(.inputs, [])
        outputFormat = c.value(.outputFormat, "")
    }
}

nonisolated enum ApprovalChannel: String, Codable, CaseIterable, Identifiable, Sendable {
    case inApp, email, message
    var id: String { rawValue }
    var title: String {
        switch self {
        case .inApp: "In app"
        case .email: "Email"
        case .message: "Message"
        }
    }
}

/// Layer 1 user approval gate.
nonisolated struct ApprovalSpec: Codable, Equatable, Sendable {
    var approver = ""
    var channel = ApprovalChannel.inApp
    var expiresAfterMinutes = 120
    var requireComment = false
    var summaryTemplate = ""

    init() {}

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ApprovalSpec()
        approver = c.value(.approver, d.approver)
        channel = c.value(.channel, d.channel)
        expiresAfterMinutes = c.value(.expiresAfterMinutes, d.expiresAfterMinutes)
        requireComment = c.value(.requireComment, d.requireComment)
        summaryTemplate = c.value(.summaryTemplate, d.summaryTemplate)
    }
}

nonisolated enum ExecutionMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case dryRun, paper, live
    var id: String { rawValue }
    var title: String {
        switch self {
        case .dryRun: "Dry run (no requests sent)"
        case .paper: "Paper / sandbox account"
        case .live: "Live"
        }
    }
}

/// Layer 1 execution request, sent only after approval.
nonisolated struct ExecutionSpec: Codable, Equatable, Sendable {
    var target = ""
    var mode = ExecutionMode.dryRun
    var confirmBeforeSend = true

    init() {}

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ExecutionSpec()
        target = c.value(.target, d.target)
        mode = c.value(.mode, d.mode)
        confirmBeforeSend = c.value(.confirmBeforeSend, d.confirmBeforeSend)
    }
}

/// Layer 1 outcome report.
nonisolated struct ReportSpec: Codable, Equatable, Sendable {
    var recipients = ""
    var detailed = false
    var includeFailures = true

    init() {}

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ReportSpec()
        recipients = c.value(.recipients, d.recipients)
        detailed = c.value(.detailed, d.detailed)
        includeFailures = c.value(.includeFailures, d.includeFailures)
    }
}

nonisolated enum HTTPMethod: String, Codable, CaseIterable, Identifiable, Sendable {
    case GET, POST
    var id: String { rawValue }
}

/// Layer 3 API read against a subscription.
nonisolated struct ApiCallSpec: Codable, Equatable, Sendable {
    var subscriptionID: UUID?
    var method = HTTPMethod.GET
    var path = ""
    var query: [KeyValue] = []
    var headers: [KeyValue] = []
    var body = ""

    init() {}

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        subscriptionID = c.value(.subscriptionID, nil)
        method = c.value(.method, .GET)
        path = c.value(.path, "")
        query = c.value(.query, [])
        headers = c.value(.headers, [])
        body = c.value(.body, "")
    }
}

/// Layer 3 Python script. It gets {"arguments": {...}, "inputs": {...}, "step": title} as JSON on
/// stdin and prints its result as JSON on stdout. The optional subscription's key and base URL are
/// passed as MXJOBS_API_KEY / MXJOBS_BASE_URL (and under the subscription's key name when that is
/// an environment-variable name such as FINNHUB_TOKEN).
nonisolated struct ScriptSpec: Codable, Equatable, Sendable {
    static let template = """
    import json, os, sys

    request = json.load(sys.stdin)        # {"arguments": {...}, "inputs": {...}, "step": "..."}
    args = request["arguments"]
    inputs = request["inputs"]            # outputs of the steps linked into this one
    api_key = os.environ.get("MXJOBS_API_KEY")  # from the step's subscription, if any

    result = {"arguments": args, "inputCount": len(inputs)}

    json.dump(result, sys.stdout)         # the step's output (must be JSON)

    """

    var code = ScriptSpec.template
    /// Path of python3; empty = the first one found (Homebrew, python.org, Apple's).
    var interpreter = ""
    var subscriptionID: UUID?

    init() {}

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        code = c.value(.code, "")
        interpreter = c.value(.interpreter, "")
        subscriptionID = c.value(.subscriptionID, nil)
    }
}

/// Layer 3 normalisation: output field ← JSON path in the input.
nonisolated struct TransformSpec: Codable, Equatable, Sendable {
    var mappings: [KeyValue] = []

    init() {}

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mappings = c.value(.mappings, [])
    }
}

// MARK: - Nodes and links

nonisolated struct JobNode: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var kind: NodeKind
    var title: String
    var notes = ""
    var x: Double = 0
    var y: Double = 0
    var enabled = true
    /// Debug runs pause before this node (when breakpoints are on).
    var breakpoint = false

    var arguments: [Argument] = []
    var outcome = ExpectedOutcome()
    var exceptions = ExceptionPolicy()

    var schedule: ScheduleSpec?
    var agent: AgentSpec?
    var approval: ApprovalSpec?
    var execution: ExecutionSpec?
    var report: ReportSpec?
    var api: ApiCallSpec?
    var transform: TransformSpec?
    var script: ScriptSpec?

    var layer: Layer { kind.layer }

    init(kind: NodeKind, title: String? = nil, x: Double = 0, y: Double = 0) {
        self.kind = kind
        self.title = title ?? kind.title
        self.x = x
        self.y = y
        switch kind {
        case .trigger: schedule = ScheduleSpec()
        case .instructionSet, .agentTask, .aggregate, .decision: agent = AgentSpec()
        case .approvalGate: approval = ApprovalSpec()
        case .executeRequest: execution = ExecutionSpec()
        case .outcomeReport: report = ReportSpec()
        case .apiRead: api = ApiCallSpec()
        case .dataNormalize: transform = TransformSpec()
        case .pythonScript: script = ScriptSpec()
        }
        if kind == .executeRequest || kind == .approvalGate {
            exceptions.onFailure = .escalateToUser
            exceptions.maxRetries = 0
        }
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(NodeKind.self, forKey: .kind)
        id = c.value(.id, UUID())
        title = c.value(.title, kind.title)
        notes = c.value(.notes, "")
        x = c.value(.x, 0)
        y = c.value(.y, 0)
        enabled = c.value(.enabled, true)
        breakpoint = c.value(.breakpoint, false)
        arguments = c.value(.arguments, [])
        outcome = c.value(.outcome, ExpectedOutcome())
        exceptions = c.value(.exceptions, ExceptionPolicy())
        schedule = c.value(.schedule, nil)
        agent = c.value(.agent, nil)
        approval = c.value(.approval, nil)
        execution = c.value(.execution, nil)
        report = c.value(.report, nil)
        api = c.value(.api, nil)
        transform = c.value(.transform, nil)
        script = c.value(.script, nil)
    }
}

nonisolated struct JobLink: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var from: UUID
    var to: UUID
    var label = ""

    init(from: UUID, to: UUID, label: String = "") {
        self.from = from
        self.to = to
        self.label = label
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, UUID())
        from = try c.decode(UUID.self, forKey: .from)
        to = try c.decode(UUID.self, forKey: .to)
        label = c.value(.label, "")
    }
}

// MARK: - API subscriptions (Layer 3 configuration)

nonisolated enum AuthStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case none, queryParameter, header, bearer, localService
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: "No key"
        case .queryParameter: "Key as query parameter"
        case .header: "Key in header"
        case .bearer: "Bearer token"
        case .localService: "Local service (optional token)"
        }
    }

    /// Calls fail without a stored key. A local service sends its token only when one is stored.
    var requiresKey: Bool { self == .queryParameter || self == .header || self == .bearer }
}

nonisolated extension ApiSubscription {
    static let localServicePort = 8765

    /// A Python (or any) service on this Mac, e.g. Services/market-sample/mxjobs_service.py.
    static func localService(port: Int = localServicePort) -> ApiSubscription {
        var sub = ApiSubscription()
        sub.name = "Local Python service"
        sub.provider = "This Mac"
        sub.baseURL = "http://127.0.0.1:\(port)"
        sub.auth = .localService
        sub.keyName = ""
        sub.notes = "Start it with: python3 Services/mxservices.py start (or python3 Services/market-sample/mxjobs_service.py --port \(port)). "
            + "Store a token here only if the service is started with --token."
        return sub
    }
}

nonisolated struct ApiSubscription: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var name = "New Subscription"
    var provider = ""
    var baseURL = "https://"
    var auth = AuthStyle.queryParameter
    /// Query parameter or header name that carries the key ("apikey", "X-API-Key").
    var keyName = "apikey"
    var rateLimitPerMinute = 0
    var plan = ""
    var docsURL = ""
    /// Headers sent with every call (e.g. the User-Agent SEC EDGAR asks for).
    var defaultHeaders: [KeyValue] = []
    var notes = ""
    /// Source project of a local service (e.g. Services/portfolio-java), opened with "Open in IDE".
    var projectFolder = ""
    var ide = IDEChoice.vscode

    /// Keychain account under which this subscription's API key is stored.
    var keychainAccount: String { "subscription-\(id.uuidString)" }

    init() {}

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ApiSubscription()
        id = c.value(.id, UUID())
        name = c.value(.name, d.name)
        provider = c.value(.provider, "")
        baseURL = c.value(.baseURL, d.baseURL)
        auth = c.value(.auth, d.auth)
        keyName = c.value(.keyName, d.keyName)
        rateLimitPerMinute = c.value(.rateLimitPerMinute, 0)
        plan = c.value(.plan, "")
        docsURL = c.value(.docsURL, "")
        defaultHeaders = c.value(.defaultHeaders, [])
        notes = c.value(.notes, "")
        projectFolder = c.value(.projectFolder, "")
        ide = c.value(.ide, .vscode)
    }
}

nonisolated enum IDEChoice: String, Codable, CaseIterable, Identifiable, Sendable {
    case vscode, intellij, clion, xcode, finder
    var id: String { rawValue }
    var title: String {
        switch self {
        case .vscode: "Visual Studio Code"
        case .intellij: "IntelliJ IDEA"
        case .clion: "CLion"
        case .xcode: "Xcode"
        case .finder: "Finder"
        }
    }
}

// MARK: - Run settings

/// What a run does with the Layer 1 business operations.
nonisolated enum OperationsAction: String, Codable, CaseIterable, Identifiable, Sendable {
    case interactive, autoApprove, skip
    var id: String { rawValue }
    var title: String {
        switch self {
        case .interactive: "Interactive — ask for approvals"
        case .autoApprove: "Auto-approve (rehearsal)"
        case .skip: "Skip Layer 1"
        }
    }
    var short: String {
        switch self {
        case .interactive: "Interactive"
        case .autoApprove: "Auto-approve"
        case .skip: "Skip"
        }
    }
}

/// What a run does with the Layer 2 agents.
nonisolated enum AgentsAction: String, Codable, CaseIterable, Identifiable, Sendable {
    case run, skip
    var id: String { rawValue }
    var title: String {
        switch self {
        case .run: "Run agents (simulated)"
        case .skip: "Skip Layer 2"
        }
    }
    var short: String { self == .run ? "Run" : "Skip" }
}

/// What a run does with the Layer 3 data reads.
nonisolated enum DataAction: String, Codable, CaseIterable, Identifiable, Sendable {
    case live, mock, skip
    var id: String { rawValue }
    var title: String {
        switch self {
        case .live: "Live API calls"
        case .mock: "Mock data (no network)"
        case .skip: "Skip Layer 3"
        }
    }
    var short: String {
        switch self {
        case .live: "Live"
        case .mock: "Mock"
        case .skip: "Skip"
        }
    }
}

nonisolated struct RunSettings: Codable, Equatable, Sendable {
    var operations = OperationsAction.interactive
    var agents = AgentsAction.run
    var data = DataAction.mock
    var breakpointsEnabled = true
    /// Stop the whole run at the first step that fails after its exception handling.
    var stopOnError = true
    /// Pause between steps so the flow can be followed on the canvas (seconds).
    var stepDelay = 0.4

    init() {}

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = RunSettings()
        operations = c.value(.operations, d.operations)
        agents = c.value(.agents, d.agents)
        data = c.value(.data, d.data)
        breakpointsEnabled = c.value(.breakpointsEnabled, d.breakpointsEnabled)
        stopOnError = c.value(.stopOnError, d.stopOnError)
        stepDelay = c.value(.stepDelay, d.stepDelay)
    }
}

// MARK: - Jobspace

nonisolated struct Jobspace: Codable, Equatable, Sendable {
    var format = "mxjobspace"
    var formatVersion = 1
    var name = "Untitled Jobspace"
    var description = ""
    var subscriptions: [ApiSubscription] = []
    var nodes: [JobNode] = []
    var links: [JobLink] = []
    var run = RunSettings()

    init() {}

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = c.value(.format, "mxjobspace")
        formatVersion = c.value(.formatVersion, 1)
        name = c.value(.name, "Untitled Jobspace")
        description = c.value(.description, "")
        subscriptions = c.value(.subscriptions, [])
        nodes = c.value(.nodes, [])
        links = try c.decodeIfPresent([JobLink].self, forKey: .links) ?? []
        run = c.value(.run, RunSettings())
        let ids = Set(nodes.map(\.id))
        links.removeAll { !ids.contains($0.from) || !ids.contains($0.to) }
    }
}

// MARK: - Editing

nonisolated extension Jobspace {
    func index(of id: UUID) -> Int? { nodes.firstIndex { $0.id == id } }
    func node(_ id: UUID) -> JobNode? { nodes.first { $0.id == id } }
    func subscription(_ id: UUID?) -> ApiSubscription? { subscriptions.first { $0.id == id } }

    @discardableResult
    mutating func addLink(from: UUID, to: UUID) -> UUID? {
        guard from != to, !links.contains(where: { $0.from == from && $0.to == to }) else { return nil }
        let link = JobLink(from: from, to: to)
        links.append(link)
        return link.id
    }

    mutating func delete(nodes ids: Set<UUID>, links linkIDs: Set<UUID> = []) {
        nodes.removeAll { ids.contains($0.id) }
        links.removeAll { ids.contains($0.from) || ids.contains($0.to) || linkIDs.contains($0.id) }
    }

    /// Copies the nodes (and the links among them) 30 points down-right; returns the new ids.
    mutating func duplicate(_ ids: Set<UUID>) -> Set<UUID> {
        var map: [UUID: UUID] = [:]
        for node in nodes where ids.contains(node.id) {
            var copy = node
            copy.id = UUID()
            copy.x += 30
            copy.y += 30
            copy.title += " copy"
            map[node.id] = copy.id
            nodes.append(copy)
        }
        for link in links {
            if let from = map[link.from], let to = map[link.to] {
                links.append(JobLink(from: from, to: to, label: link.label))
            }
        }
        return Set(map.values)
    }

    func upstream(of id: UUID) -> Set<UUID> {
        var seen = Set<UUID>()
        var stack = [id]
        while let current = stack.popLast() {
            for link in links where link.to == current && !seen.contains(link.from) {
                seen.insert(link.from)
                stack.append(link.from)
            }
        }
        return seen
    }

    /// All `outputName`s published by nodes linked into `id` (directly).
    func inputNames(for id: UUID) -> [String] {
        links.filter { $0.to == id }.compactMap { node($0.from)?.outcome.outputName }.filter { !$0.isEmpty }
    }
}
