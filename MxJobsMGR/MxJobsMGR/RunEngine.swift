//
//  RunEngine.swift
//  MxJobsMGR
//
//  Runs (and debugs) a jobspace across its three layers.
//
//  Order: a step first waits for the steps feeding it along its own layer or from below
//  (same-layer flow, results coming up). It then performs its action and runs the steps it
//  calls down the layers, together with whatever those call in turn. Layer 2 agents act
//  after their calls have returned, so they see the data the Layer 3 reads brought back.
//  Each step runs once; cycles (a call down whose result comes back up) are fine.
//
//  What each layer does is set in the jobspace's run settings (Interactive / Auto-approve /
//  Skip, Run / Skip, Live / Mock / Skip). Execution Requests never send anything yet:
//  they report what would be sent.
//
//  Debugging: breakpoints and Step pause before a step; Continue resumes; Stop cancels.
//  User Approval, send confirmations and "ask the user" failures pause on a prompt.
//

import Foundation

enum NodeRunState: Hashable {
    case pending, paused, running, waiting, succeeded, warning, failed, skipped

    var title: String {
        switch self {
        case .pending: "Pending"
        case .paused: "Paused"
        case .running: "Running"
        case .waiting: "Waiting for you"
        case .succeeded: "Succeeded"
        case .warning: "Completed with warnings"
        case .failed: "Failed"
        case .skipped: "Skipped"
        }
    }

    var symbol: String {
        switch self {
        case .pending: "circle.dotted"
        case .paused: "pause.circle.fill"
        case .running: "play.circle.fill"
        case .waiting: "person.crop.circle.badge.questionmark"
        case .succeeded: "checkmark.circle.fill"
        case .warning: "exclamationmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .skipped: "arrow.uturn.forward.circle"
        }
    }
}

enum RunPhase: Equatable {
    case idle, running, paused, waiting, finished, failed, stopped

    var isActive: Bool { self == .running || self == .paused || self == .waiting }
}

enum LogLevel: Int, Comparable {
    case debug, info, success, warning, error
    static func < (a: LogLevel, b: LogLevel) -> Bool { a.rawValue < b.rawValue }

    var symbol: String {
        switch self {
        case .debug: "ant"
        case .info: "info.circle"
        case .success: "checkmark.circle"
        case .warning: "exclamationmark.triangle"
        case .error: "xmark.octagon"
        }
    }
}

struct RunLogEntry: Identifiable {
    let id = UUID()
    var date = Date()
    var level: LogLevel
    var nodeID: UUID?
    var message: String
}

/// A question the run is waiting on (approval, confirmation, failure handling).
struct RunPrompt: Identifiable {
    struct Option: Identifiable {
        var id: String { label }
        var label: String
        var isDefault = false
        var isDestructive = false
    }
    let id = UUID()
    var nodeID: UUID
    var title: String
    var message: String
    var detail: String
    var options: [Option]
}

private struct RunAbort: Error {}

@Observable
final class RunEngine {
    private(set) var phase: RunPhase = .idle
    private(set) var states: [UUID: NodeRunState] = [:]
    private(set) var log: [RunLogEntry] = []
    private(set) var prompt: RunPrompt?
    private(set) var currentNode: UUID?
    private(set) var startedAt: Date?
    private(set) var finishedAt: Date?
    /// Output of each step, as JSON-like values (dictionaries, arrays, strings, numbers).
    @ObservationIgnored private(set) var outputs: [UUID: Any] = [:]
    /// Bumped when `outputs` changes, so views showing them refresh.
    private(set) var outputsRevision = 0

    /// Pause before the next step (Step / Pause).
    var stepping = false
    /// The live jobspace, read at each checkpoint so breakpoints toggled mid-run count.
    @ObservationIgnored var currentSpace: () -> Jobspace? = { nil }

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var resume: CheckedContinuation<Void, Never>?
    @ObservationIgnored private var answer: CheckedContinuation<String, Never>?

    // Per-run bookkeeping
    @ObservationIgnored private var space = Jobspace()
    @ObservationIgnored private var settings = RunSettings()
    @ObservationIgnored private var done: Set<UUID> = []
    @ObservationIgnored private var active: Set<UUID> = []
    /// Steps whose failure or rejection stops what depends on them.
    @ObservationIgnored private var blocked: Set<UUID> = []
    /// Whether the user allowed this run's Python scripts (asked once, at the first one).
    @ObservationIgnored private var scriptsAllowed: Bool?

    var isActive: Bool { phase.isActive }
    var canContinue: Bool { phase == .paused }

    // MARK: Controls

    /// Starts a run of `space` (or continues a paused one).
    func run(_ space: Jobspace, stepping: Bool = false) {
        if phase == .paused {
            self.stepping = stepping
            continueRun()
            return
        }
        guard !isActive else { return }
        self.space = space
        settings = space.run
        self.stepping = stepping
        done = []; active = []; blocked = []; scriptsAllowed = nil
        outputs = [:]; outputsRevision += 1
        states = Dictionary(uniqueKeysWithValues: space.nodes.map { ($0.id, .pending) })
        log = []
        prompt = nil
        currentNode = nil
        startedAt = Date()
        finishedAt = nil
        phase = .running
        let s = settings
        write(.info, "Run started — Layer 1: \(s.operations.short), Layer 2: \(s.agents.short), Layer 3: \(s.data.short)"
              + (s.breakpointsEnabled ? "" : ", breakpoints off"))
        task = Task { await self.main() }
    }

    func continueRun() {
        guard phase == .paused else { return }
        phase = .running
        resume?.resume()
        resume = nil
    }

    /// Runs to the next step and pauses before it.
    func step(_ space: Jobspace) {
        if phase == .paused {
            stepping = true
            continueRun()
        } else if !isActive {
            run(space, stepping: true)
        }
    }

    /// Pauses before the next step.
    func pause() {
        guard phase == .running else { return }
        stepping = true
        write(.debug, "Pausing before the next step…")
    }

    func stop() {
        guard isActive else { return }
        task?.cancel()
        resume?.resume(); resume = nil
        answer?.resume(returning: "Stop"); answer = nil
    }

    func respond(_ label: String) {
        guard let answer else { return }
        // Clear first so a second click cannot answer the next prompt.
        self.answer = nil
        prompt = nil
        answer.resume(returning: label)
    }

    func reset() {
        guard !isActive else { return }
        phase = .idle
        states = [:]
        log = []
        outputs = [:]; outputsRevision += 1
        currentNode = nil
        startedAt = nil
        finishedAt = nil
    }

    func clearLog() { log = [] }

    func output(of id: UUID) -> Any? { outputs[id] }

    // MARK: Main loop

    private func main() async {
        do {
            // Layer 1 first, left to right, then anything not reached from it.
            let order = space.nodes.sorted { ($0.layer.rawValue, $0.x, $0.y) < ($1.layer.rawValue, $1.x, $1.y) }
            for node in order { try await runNode(node.id) }
            let failed = states.values.filter { $0 == .failed }.count
            phase = failed > 0 ? .failed : .finished
            write(failed > 0 ? .error : .success,
                  failed > 0 ? "Run finished with \(failed) failed step\(failed == 1 ? "" : "s")." : "Run finished.")
        } catch is CancellationError {
            phase = .stopped
            markUnfinished()
            write(.warning, "Run stopped.")
        } catch {
            phase = .failed
            markUnfinished()
            write(.error, "Run aborted.")
        }
        currentNode = nil
        prompt = nil
        finishedAt = Date()
        task = nil
    }

    private func markUnfinished() {
        for (id, state) in states where state == .running || state == .paused || state == .waiting {
            states[id] = .failed
        }
    }

    // MARK: Graph

    /// Steps feeding `id` that it must wait for: along its own layer or from below,
    /// leaving out results coming back from its own calls.
    private func dependencies(of id: UUID) -> [UUID] {
        guard let node = space.node(id) else { return [] }
        let own = calledSubtree(of: id)
        return space.links.compactMap { link in
            guard link.to == id, let from = space.node(link.from),
                  from.layer.rawValue >= node.layer.rawValue, !own.contains(from.id) else { return nil }
            return from.id
        }
    }

    /// Steps `id` calls down the layers, and what those lead to in their own or lower layers.
    private func calledSubtree(of id: UUID) -> [UUID] {
        guard let root = space.node(id) else { return [] }
        var seen: Set<UUID> = []
        var order: [UUID] = []
        var queue = space.links.filter { $0.from == id }
            .compactMap { link in space.node(link.to).flatMap { $0.layer.rawValue > root.layer.rawValue ? $0 : nil } }
            .sorted { $0.x < $1.x }
        while !queue.isEmpty {
            let node = queue.removeFirst()
            guard node.id != id, seen.insert(node.id).inserted else { continue }
            order.append(node.id)
            let next = space.links.filter { $0.from == node.id }
                .compactMap { space.node($0.to) }
                .filter { $0.layer.rawValue >= node.layer.rawValue }
                .sorted { $0.x < $1.x }
            queue.append(contentsOf: next)
        }
        return order
    }

    /// Outputs of the steps linked into `id`, keyed by their output name (or title).
    private func inputs(of id: UUID) -> [String: Any] {
        var result: [String: Any] = [:]
        for link in space.links where link.to == id {
            guard let from = space.node(link.from), let value = outputs[from.id] else { continue }
            result[from.outcome.outputName.isEmpty ? from.title : from.outcome.outputName] = value
        }
        return result
    }

    // MARK: Steps

    private func runNode(_ id: UUID) async throws {
        guard !done.contains(id), !active.contains(id), let node = space.node(id) else { return }
        active.insert(id)
        defer { active.remove(id) }

        for dep in dependencies(of: id) { try await runNode(dep) }

        if let reason = skipReason(node) {
            states[id] = .skipped
            write(.debug, "Skipped — \(reason).", node: id)
            if reason.hasPrefix("upstream") {
                blocked.insert(id)
            } else {
                // A step skipped by the run settings passes its inputs straight through.
                outputs[id] = inputs(of: id); outputsRevision += 1
            }
            done.insert(id)
            // Steps it calls still get their turn from the main loop, where they are blocked too.
            return
        }

        try await checkpoint(node)
        currentNode = id
        states[id] = .running
        write(.info, "▶ \(node.kind.title): \(node.title)", node: id)

        let actsAfterCalls = node.layer == .agents
        if !actsAfterCalls { try await perform(node) }
        if !blocked.contains(id) {
            for callee in calledSubtree(of: id) { try await runNode(callee) }
        }
        if actsAfterCalls { try await perform(node) }
        done.insert(id)
    }

    private func skipReason(_ node: JobNode) -> String? {
        if !node.enabled { return "step disabled" }
        switch node.layer {
        case .operations where settings.operations == .skip: return "Layer 1 set to Skip"
        case .agents where settings.agents == .skip: return "Layer 2 set to Skip"
        case .data where settings.data == .skip: return "Layer 3 set to Skip"
        default: break
        }
        let upstream = space.links.filter { $0.to == node.id }.map(\.from)
        if let bad = upstream.first(where: { blocked.contains($0) }), let n = space.node(bad) {
            return "upstream step “\(n.title)” did not complete"
        }
        return nil
    }

    private func checkpoint(_ node: JobNode) async throws {
        try Task.checkCancellation()
        let live = currentSpace()
        let hasBreakpoint = (live?.node(node.id)?.breakpoint ?? node.breakpoint)
            && (live?.run.breakpointsEnabled ?? settings.breakpointsEnabled)
        if stepping || hasBreakpoint {
            states[node.id] = .paused
            currentNode = node.id
            phase = .paused
            write(.debug, hasBreakpoint ? "Breakpoint — paused before “\(node.title)”." : "Paused before “\(node.title)”.",
                  node: node.id)
            stepping = false
            await withCheckedContinuation { resume = $0 }
            try Task.checkCancellation()
            phase = .running
        }
        let delay = live?.run.stepDelay ?? settings.stepDelay
        if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
    }

    private func ask(_ node: JobNode, title: String, message: String, detail: Any?,
                     options: [RunPrompt.Option]) async throws -> String {
        states[node.id] = .waiting
        phase = .waiting
        prompt = RunPrompt(nodeID: node.id, title: title, message: message,
                           detail: detail.map(Self.pretty) ?? "", options: options)
        write(.info, "Waiting: \(title)", node: node.id)
        let reply = await withCheckedContinuation { answer = $0 }
        prompt = nil
        try Task.checkCancellation()
        phase = .running
        states[node.id] = .running
        return reply
    }

    private func finish(_ node: JobNode, _ state: NodeRunState, output: Any?, _ message: String, level: LogLevel? = nil) {
        states[node.id] = state
        if let output { outputs[node.id] = output; outputsRevision += 1 }
        let lvl = level ?? (state == .failed ? .error : state == .warning ? .warning : state == .skipped ? .debug : .success)
        write(lvl, message, node: node.id)
    }

    /// A failure the step's exception handling could not recover from.
    private func fail(_ node: JobNode, _ message: String) throws {
        blocked.insert(node.id)
        finish(node, .failed, output: nil, message)
        if node.exceptions.notifyUser { write(.warning, "Notify: “\(node.title)” failed.", node: node.id) }
        if settings.stopOnError { throw RunAbort() }
    }

    private func perform(_ node: JobNode) async throws {
        let input = inputs(of: node.id)
        switch node.kind {
        case .trigger:
            var out: [String: Any] = ["startedAt": ISO8601DateFormatter().string(from: startedAt ?? Date())]
            for arg in node.arguments where !arg.name.isEmpty { out[arg.name] = arg.value }
            finish(node, .succeeded, output: out, "Refresh started (\(node.schedule?.summary ?? "manual")).")

        case .instructionSet:
            let out: [String: Any] = ["instructions": input, "assembly": node.agent?.instructions ?? ""]
            finish(node, .succeeded, output: out, "Instructions assembled from \(input.count) input\(input.count == 1 ? "" : "s").")

        case .approvalGate:
            if settings.operations == .autoApprove {
                finish(node, .warning, output: ["approved": true, "by": "auto-approve"], "Auto-approved (rehearsal).")
                return
            }
            let approver = node.approval?.approver ?? ""
            let summary = Self.fill(ApiTester.substitute(node.approval?.summaryTemplate ?? "", arguments: node.arguments),
                                    with: input)
            let reply = try await ask(node, title: "Approve “\(node.title)”?",
                                      message: (summary.isEmpty ? "Review the instructions below." : summary)
                                        + (approver.isEmpty ? "" : "\nApprover: \(approver)"),
                                      detail: input,
                                      options: [.init(label: "Approve", isDefault: true),
                                                .init(label: "Reject", isDestructive: true)])
            if reply == "Approve" {
                finish(node, .succeeded, output: ["approved": true, "instructions": input], "Approved.")
            } else {
                blocked.insert(node.id)
                finish(node, .warning, output: ["approved": false], "Rejected — the steps after it will not run.")
            }

        case .executeRequest:
            let spec = node.execution ?? ExecutionSpec()
            if spec.confirmBeforeSend, settings.operations == .interactive {
                let reply = try await ask(node, title: "Send “\(node.title)”?",
                                          message: "Target: \(spec.target.isEmpty ? "not set" : spec.target) · Mode: \(spec.mode.title)",
                                          detail: input,
                                          options: [.init(label: "Send", isDefault: true),
                                                    .init(label: "Cancel", isDestructive: true)])
                if reply != "Send" {
                    blocked.insert(node.id)
                    finish(node, .skipped, output: ["sent": false], "Cancelled — nothing was sent.", level: .warning)
                    return
                }
            }
            let out: [String: Any] = ["sent": false, "mode": spec.mode.rawValue, "target": spec.target, "request": input]
            finish(node, .warning, output: out,
                   "Not sent: execution connectors are not available yet. Would send to \(spec.target.isEmpty ? "(no target)" : spec.target) in \(spec.mode.rawValue) mode.")

        case .outcomeReport:
            let counts = Dictionary(grouping: states.values, by: { $0 }).mapValues(\.count)
            let report: [String: Any] = [
                "succeeded": counts[.succeeded, default: 0],
                "warnings": counts[.warning, default: 0],
                "failed": counts[.failed, default: 0],
                "skipped": counts[.skipped, default: 0],
                "recipients": node.report?.recipients ?? "",
                "results": input,
            ]
            finish(node, .succeeded, output: report,
                   "Report for \(node.report?.recipients.isEmpty == false ? node.report!.recipients : "the user"): "
                   + "\(report["succeeded"]!) succeeded, \(report["warnings"]!) with warnings, \(report["failed"]!) failed, \(report["skipped"]!) skipped.")

        case .decision:
            // Simulated decision: follow the decisionContext of a Layer 3 outcome — the first of the step's own
            // Inputs list that has one (its priority), else the most confident.
            let priority = node.agent?.inputs ?? []
            let rank = { (name: String) in priority.firstIndex(of: name) ?? priority.count }
            let contexts = input.compactMap { name, value -> (String, [String: Any])? in
                guard let dict = value as? [String: Any], let ctx = dict["decisionContext"] as? [String: Any] else { return nil }
                return (name, ctx)
            }.sorted {
                rank($0.0) != rank($1.0) ? rank($0.0) < rank($1.0)
                    : ($0.1["confidence"] as? Double ?? 0) > ($1.1["confidence"] as? Double ?? 0)
            }
            if let (source, ctx) = contexts.first, let next = ctx["recommendation"] as? String {
                let confidence = ctx["confidence"] as? Double ?? 0
                let out: [String: Any] = ["nextStep": next, "confidence": confidence, "source": source,
                                          "alternatives": ctx["alternatives"] ?? [], "reason": ctx["reason"] ?? "",
                                          "inputs": input]
                finish(node, .succeeded, output: out,
                       "Decision: \(next) (confidence \(String(format: "%.2f", confidence)), from “\(source)”).")
            } else {
                // No context to decide on (e.g. the optimizer was skipped): hand it to the user.
                let out: [String: Any] = ["nextStep": "escalate", "confidence": 0.0, "source": "",
                                          "reason": "No decisionContext among the inputs.", "inputs": input]
                finish(node, .warning, output: out,
                       "Decision: escalate — no decisionContext among \(input.count) input\(input.count == 1 ? "" : "s").")
            }

        case .agentTask, .aggregate:
            let model = node.agent?.model ?? ""
            finish(node, .succeeded, output: input,
                   "Agent simulated\(model.isEmpty ? "" : " (\(model) not connected yet)") — passed on \(input.count) input\(input.count == 1 ? "" : "s").")

        case .dataNormalize:
            let source: Any? = input.count == 1 ? input.values.first : input
            var out: [String: Any] = [:]
            var missing: [String] = []
            for m in node.transform?.mappings ?? [] where !m.key.isEmpty {
                if let source, let v = ApiTester.lookup(m.value, in: source) { out[m.key] = v } else { missing.append(m.key) }
            }
            if missing.isEmpty {
                finish(node, .succeeded, output: out, "Normalized \(out.count) field\(out.count == 1 ? "" : "s").")
            } else {
                try await handleFailure(node, message: "Fields not found: \(missing.joined(separator: ", "))", partial: out)
            }

        case .apiRead:
            try await performAPIRead(node)

        case .pythonScript:
            try await performScript(node)
        }
    }

    // MARK: API reads and exception handling

    private func performAPIRead(_ node: JobNode) async throws {
        guard let sub = space.subscription(node.api?.subscriptionID) else {
            return try fail(node, "No API subscription set.")
        }
        if settings.data == .mock {
            finish(node, .succeeded, output: mockOutput(for: node),
                   "Mock data for \(sub.name) \(ApiTester.substitute(node.api?.path ?? "", arguments: node.arguments)) (no network call).")
            return
        }
        let input = inputs(of: node.id)
        try await attempt(node) {
            let result = await ApiTester.run(node: node, subscription: sub, inputs: input)
            return (result, "HTTP \(result.status ?? 0) in \(Int(result.elapsed * 1000)) ms — \(result.url)")
        }
    }

    private func performScript(_ node: JobNode) async throws {
        let spec = node.script ?? ScriptSpec()
        let sub = space.subscription(spec.subscriptionID)
        if settings.data == .mock {
            finish(node, .succeeded, output: mockOutput(for: node), "Mock data instead of running the Python script.")
            return
        }
        // A jobspace can carry code: ask once per run before any of its scripts runs.
        if scriptsAllowed == nil {
            let count = space.nodes.filter { $0.kind == .pythonScript && $0.enabled }.count
            let reply = try await ask(node, title: "Run Python scripts?",
                                      message: "This jobspace runs \(count) Python script\(count == 1 ? "" : "s") on this Mac "
                                        + "(inside MxJobsMGR's sandbox: network and the app's own folder only). "
                                        + "Review the code below before allowing.",
                                      detail: spec.code,
                                      options: [.init(label: "Run Scripts", isDefault: true), .init(label: "Skip Scripts"),
                                                .init(label: "Stop", isDestructive: true)])
            switch reply {
            case "Run Scripts": scriptsAllowed = true
            case "Skip Scripts": scriptsAllowed = false
            default: throw CancellationError()
            }
        }
        guard scriptsAllowed == true else {
            finish(node, .skipped, output: inputs(of: node.id), "Skipped — Python scripts not allowed in this run.", level: .warning)
            return
        }
        let input = inputs(of: node.id)
        try await attempt(node) {
            let result = await PythonRunner.run(node: node, subscription: sub, inputs: input)
            return (result, "Python exited \(result.status ?? -1) in \(Int(result.elapsed * 1000)) ms — \(result.url)")
        }
    }

    /// Mock output: the required fields, plus whatever the Normalize steps it feeds read.
    private func mockOutput(for node: JobNode) -> [String: Any] {
        var mock: [String: Any] = ["mock": true]
        let mapped = space.links.filter { $0.from == node.id }.compactMap { space.node($0.to)?.transform?.mappings }
            .flatMap { $0 }.map(\.value)
        for field in node.outcome.requiredFields + mapped where !field.isEmpty { Self.insert("mock", at: field, into: &mock) }
        // A value that passes each assertion.
        for assertion in node.outcome.assertions where !assertion.path.isEmpty {
            let expected = ApiTester.substitute(assertion.value, arguments: node.arguments)
            let number = Double(expected.trimmingCharacters(in: .whitespaces))
            let value: Any
            switch assertion.op {
            case .equals: value = number.map { $0 as Any } ?? expected
            case .notEquals: value = number.map { ($0 + 1) as Any } ?? "not \(expected)"
            case .less: value = number.map { ($0 > 0 ? $0 / 2 : $0 - 1) as Any } ?? 0
            case .lessOrEqual, .greaterOrEqual: value = number.map { $0 as Any } ?? expected
            case .greater: value = number.map { ($0 > 0 ? $0 * 2 : $0 + 1) as Any } ?? 1
            case .contains: value = [expected]
            case .exists: value = "mock"
            }
            Self.insert(value, at: assertion.path, into: &mock)
        }
        return mock
    }

    /// Runs a live call or script with the step's exception handling: retries with backoff,
    /// asking the user, fallback, skip or abort.
    private func attempt(_ node: JobNode, _ body: () async -> (ApiTestResult, String)) async throws {
        let policy = node.exceptions
        var attempt = 0
        while true {
            try Task.checkCancellation()
            let (result, summary) = await body()
            try Task.checkCancellation()
            if result.passed {
                finish(node, .succeeded, output: result.json ?? result.body, summary)
                return
            }
            let reason = result.error
                ?? result.checks.filter { !$0.passed }.map(\.label).joined(separator: "; ")
            if policy.onFailure == .retry, attempt < policy.maxRetries {
                let delay = Double(policy.retryDelaySeconds) * (policy.exponentialBackoff ? pow(2, Double(attempt)) : 1)
                attempt += 1
                write(.warning, "Attempt \(attempt) failed (\(reason)); retrying in \(Int(delay)) s…", node: node.id)
                try await Task.sleep(for: .seconds(delay))
                continue
            }
            if policy.onFailure == .escalateToUser {
                let reply = try await ask(node, title: "“\(node.title)” failed", message: reason, detail: result.body,
                                          options: [.init(label: "Retry", isDefault: true), .init(label: "Skip"),
                                                    .init(label: "Abort", isDestructive: true)])
                switch reply {
                case "Retry": continue
                case "Skip": finish(node, .skipped, output: nil, "Skipped after failure: \(reason)", level: .warning); return
                default: throw RunAbort()
                }
            }
            return try await handleFailure(node, message: reason, partial: nil)
        }
    }

    /// Applies the step's exception handling (other than retry) to a failure.
    private func handleFailure(_ node: JobNode, message: String, partial: Any?) async throws {
        switch node.exceptions.onFailure {
        case .skip:
            finish(node, .skipped, output: partial, "Skipped: \(message)", level: .warning)
        case .useFallback:
            finish(node, .warning, output: node.exceptions.fallbackValue, "Using fallback value “\(node.exceptions.fallbackValue)”: \(message)")
        case .escalateToUser:
            let reply = try await ask(node, title: "“\(node.title)” failed", message: message, detail: partial,
                                      options: [.init(label: "Continue", isDefault: true), .init(label: "Abort", isDestructive: true)])
            if reply == "Continue" {
                finish(node, .warning, output: partial, "Continued after failure: \(message)")
            } else {
                throw RunAbort()
            }
        case .abortRun:
            blocked.insert(node.id)
            finish(node, .failed, output: nil, "\(message) — aborting the run.")
            throw RunAbort()
        case .retry:
            try fail(node, message)
        }
    }

    // MARK: Helpers

    private func write(_ level: LogLevel, _ message: String, node: UUID? = nil) {
        log.append(RunLogEntry(level: level, nodeID: node, message: message))
    }

    /// Fills {{name}} and {{name.count}} from a step's inputs (or paths inside them).
    static func fill(_ template: String, with inputs: [String: Any]) -> String {
        var out = template
        while let open = out.range(of: "{{"), let close = out.range(of: "}}", range: open.upperBound..<out.endIndex) {
            var path = String(out[open.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespaces)
            let wantsCount = path.hasSuffix(".count")
            if wantsCount { path = String(path.dropLast(6)) }
            var text = "?"
            if let value = ApiTester.lookup(path, in: inputs) {
                if wantsCount {
                    text = String((value as? [Any])?.count ?? (value as? [String: Any])?.count ?? 1)
                } else {
                    text = (value as? String) ?? (value as? NSNumber)?.stringValue ?? "\((value as? [Any])?.count ?? (value as? [String: Any])?.count ?? 0) items"
                }
            }
            out.replaceSubrange(open.lowerBound..<close.upperBound, with: text)
        }
        return out
    }

    /// Sets `value` at a dotted path, creating dictionaries on the way.
    static func insert(_ value: Any, at path: String, into dict: inout [String: Any]) {
        let parts = path.split(separator: ".").map(String.init)
        guard let first = parts.first else { return }
        if parts.count == 1 {
            dict[first] = value
        } else {
            var child = dict[first] as? [String: Any] ?? [:]
            insert(value, at: parts.dropFirst().joined(separator: "."), into: &child)
            dict[first] = child
        }
    }

    nonisolated static func pretty(_ value: Any) -> String {
        if let s = value as? String { return s }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) {
            return String(decoding: data, as: UTF8.self)
        }
        return String(describing: value)
    }
}
