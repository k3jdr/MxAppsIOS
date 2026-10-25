//
//  PythonRunner.swift
//  MxJobsMGR
//
//  Runs the Python of a Layer 3 "Python Script" step:
//
//    stdin   {"arguments": {name: value}, "inputs": {output name: value}, "step": title}
//    stdout  the step's output, as JSON
//    env     MXJOBS_API_KEY / MXJOBS_BASE_URL from the step's subscription (and the key under the
//            subscription's key name when that is an environment-variable name, e.g. FINNHUB_TOKEN)
//
//  The script is written to the app's temporary folder and run with the step's timeout. MxJobsMGR is
//  sandboxed and the script runs inside the same sandbox: it can reach the network and the app's own
//  container, not your files. Homebrew, python.org and Apple's (developer tools) python3 work;
//  /usr/bin/python3 is mapped to the developer tools' binary (its xcrun shim can't run sandboxed), and
//  interpreters under your home folder (pyenv, conda) can't be started. Packages must be installed into
//  the interpreter itself: the sandbox hides your ~/Library/Python user site-packages.
//

import Foundation

enum PythonRunner {
    /// Apple's python3 behind /usr/bin/python3 (the developer tools'). /usr/bin/python3 itself is an
    /// xcrun shim, and xcrun refuses to run inside an App Sandbox, so the real binary is used.
    static let developerPythons = ["/Library/Developer/CommandLineTools/usr/bin/python3",
                                   "/Applications/Xcode.app/Contents/Developer/usr/bin/python3"]

    /// Usual places for python3, in order of preference. Interpreters under your home folder
    /// (pyenv, conda) can't be started from the sandbox.
    static var candidates: [String] {
        ["/opt/homebrew/bin/python3", "/usr/local/bin/python3",
         "/Library/Frameworks/Python.framework/Versions/Current/bin/python3"] + developerPythons
    }

    /// The interpreter a step uses: its own setting, else the first one found.
    static func locate(_ preferred: String) -> String? {
        let fm = FileManager.default
        let wanted = preferred.trimmingCharacters(in: .whitespaces)
        if wanted == "/usr/bin/python3" || wanted == "python3" {
            return developerPythons.first { fm.isExecutableFile(atPath: $0) }
        }
        if !wanted.isEmpty { return fm.isExecutableFile(atPath: wanted) ? wanted : nil }
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }

    /// Runs the step's script once and checks its expected outcome.
    static func run(node: JobNode, subscription: ApiSubscription?, inputs: [String: Any]) async -> ApiTestResult {
        let spec = node.script ?? ScriptSpec()
        guard let python = locate(spec.interpreter) else {
            let message = spec.interpreter.isEmpty
                ? "No python3 found. Install Python (e.g. brew install python) or set the interpreter path on the step."
                : "Python interpreter not found or not executable: \(spec.interpreter)"
            return ApiTestResult(url: "", status: nil, elapsed: 0, body: "", checks: [], error: message)
        }
        if spec.code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ApiTestResult(url: python, status: nil, elapsed: 0, body: "", checks: [], error: "The script is empty.")
        }

        // Request on stdin
        var arguments: [String: Any] = [:]
        for arg in node.arguments where !arg.name.isEmpty {
            arguments[arg.name] = ApiTester.substitute(arg.value, arguments: [])
        }
        let request: [String: Any] = ["arguments": arguments, "inputs": jsonSafe(inputs), "step": node.title]
        let stdin = (try? JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])) ?? Data("{}".utf8)

        // Environment: a small PATH, UTF-8 output, and the subscription's key and base URL.
        let parent = ProcessInfo.processInfo.environment
        var env: [String: String] = [
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
            "LANG": "en_US.UTF-8",
            "PYTHONIOENCODING": "utf-8",
            "PYTHONDONTWRITEBYTECODE": "1",
            "MXJOBS_STEP": node.title,
        ]
        for name in ["HOME", "TMPDIR", "USER"] { env[name] = parent[name] }
        if let sub = subscription {
            env["MXJOBS_BASE_URL"] = sub.baseURL
            if sub.auth != .none, let key = Keychain.secret(for: sub.keychainAccount) {
                env["MXJOBS_API_KEY"] = key
                if isEnvName(sub.keyName) { env[sub.keyName] = key }
            }
        }

        let timeout = TimeInterval(max(1, node.exceptions.timeoutSeconds))
        let started = Date()
        let outcome = await execute(python: python, code: spec.code, stdin: stdin, env: env, timeout: timeout)
        let elapsed = Date().timeIntervalSince(started)

        if let error = outcome.launchError {
            return ApiTestResult(url: python, status: nil, elapsed: elapsed, body: "", checks: [], error: error)
        }
        let stdout = String(decoding: outcome.stdout, as: UTF8.self)
        let stderr = String(decoding: outcome.stderr, as: UTF8.self)
        let json = try? JSONSerialization.jsonObject(with: outcome.stdout, options: [.fragmentsAllowed])

        var checks = [(label: "Exit code 0", passed: outcome.exitCode == 0 && !outcome.timedOut)]
        checks.append((label: "Output is JSON", passed: json != nil))
        checks += ApiTester.outcomeChecks(node, json: json)

        var body = json.map(RunEngine.pretty) ?? stdout
        if !stderr.isEmpty { body += (body.isEmpty ? "" : "\n\n") + "stderr:\n" + String(stderr.suffix(4000)) }
        if body.count > 20_000 { body = String(body.prefix(20_000)) + "\n… (truncated)" }

        var error: String?
        if outcome.timedOut {
            error = "Timed out after \(Int(timeout)) s."
        } else if outcome.exitCode != 0 {
            let last = stderr.split(separator: "\n").last.map { ": \($0)" } ?? ""
            error = "Python exited with code \(outcome.exitCode)\(last)"
        } else if json == nil {
            error = stdout.isEmpty ? "The script printed nothing (expected JSON on stdout)." : "The script's output is not JSON."
        }
        return ApiTestResult(url: python, status: Int(outcome.exitCode), elapsed: elapsed, body: body,
                             checks: checks, error: error, json: json)
    }

    // MARK: Process

    nonisolated private struct Outcome {
        var exitCode: Int32 = -1
        var stdout = Data()
        var stderr = Data()
        var timedOut = false
        var launchError: String?
    }

    /// Thread-safe holder for what the pipes and timers report.
    nonisolated private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var _value: Outcome
        init(_ value: Outcome) { _value = value }
        func update(_ change: (inout Outcome) -> Void) { lock.lock(); change(&_value); lock.unlock() }
        var value: Outcome { lock.lock(); defer { lock.unlock() }; return _value }
    }

    nonisolated private static func execute(python: String, code: String, stdin: Data, env: [String: String],
                                timeout: TimeInterval) async -> Outcome {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appending(path: "MxJobsMGR-scripts", directoryHint: .isDirectory)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "step-\(UUID().uuidString).py")
        do {
            try Data(code.utf8).write(to: file)
        } catch {
            return Outcome(launchError: "Could not write the script: \(error.localizedDescription)")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-B", file.path]
        process.environment = env
        process.currentDirectoryURL = folder
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errPipe

        let box = Box(Outcome())
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
                let group = DispatchGroup()
                process.terminationHandler = { _ in group.leave() }
                group.enter()
                do {
                    try process.run()
                } catch {
                    group.leave()
                    try? fm.removeItem(at: file)
                    continuation.resume(returning: Outcome(launchError: "Could not start \(python): \(error.localizedDescription)"))
                    return
                }
                let queue = DispatchQueue.global(qos: .userInitiated)
                // Feed stdin and drain both pipes on their own, so a large request or output can't deadlock.
                queue.async {
                    try? inPipe.fileHandleForWriting.write(contentsOf: stdin)
                    try? inPipe.fileHandleForWriting.close()
                }
                group.enter()
                queue.async {
                    let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                    box.update { $0.stdout = data }
                    group.leave()
                }
                group.enter()
                queue.async {
                    let data = errPipe.fileHandleForReading.readDataToEndOfFile()
                    box.update { $0.stderr = data }
                    group.leave()
                }
                queue.asyncAfter(deadline: .now() + timeout) {
                    if process.isRunning {
                        box.update { $0.timedOut = true }
                        process.terminate()
                        queue.asyncAfter(deadline: .now() + 2) { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
                    }
                }
                group.notify(queue: queue) {
                    box.update { $0.exitCode = process.terminationStatus }
                    try? fm.removeItem(at: file)
                    continuation.resume(returning: box.value)
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }

    // MARK: Helpers

    private static func isEnvName(_ s: String) -> Bool {
        guard let first = s.unicodeScalars.first, CharacterSet.letters.contains(first) || first == "_" else { return false }
        return s.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "_" } && s.uppercased() == s
    }

    /// Makes values JSON-serialisable (anything else becomes its description).
    nonisolated private static func jsonSafe(_ value: Any) -> Any {
        switch value {
        case let dict as [String: Any]: return dict.mapValues(jsonSafe)
        case let array as [Any]: return array.map(jsonSafe)
        case is String, is NSNumber, is NSNull: return value
        default: return String(describing: value)
        }
    }
}
