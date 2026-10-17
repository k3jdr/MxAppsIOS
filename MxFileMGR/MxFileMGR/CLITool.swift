//
//  CLITool.swift
//  MxFileMGR
//
//  Runs command-line tools (the AWS and Azure CLIs) for the cloud storage
//  browsers: either collecting their output, or as a background job that can
//  be stopped and reports progress lines.
//

import Foundation
import os

nonisolated struct CLIToolError: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

nonisolated enum CLITool {
    /// The first of `candidates` that exists and is executable.
    static func find(_ candidates: [String]) -> String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The app's environment with Homebrew on PATH (apps launched from Finder don't have it).
    static func environment(_ extra: [String: String] = [:]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        env.merge(extra) { _, new in new }
        return env
    }

    /// Runs the tool and returns stdout; throws with stderr when it fails.
    static func run(_ path: String, _ args: [String], environment: [String: String]) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = args
            process.environment = environment
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            let errData = OSAllocatedUnfairLock(initialState: Data())
            err.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                errData.withLock { $0.append(chunk) }
            }
            try process.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            err.fileHandleForReading.readabilityHandler = nil
            guard process.terminationStatus == 0 else {
                throw CLIToolError(message: message(errData.withLock { $0 }, path: path, status: process.terminationStatus))
            }
            return data
        }.value
    }

    /// Runs the tool inside a TransferManager job: stops it when the job is cancelled, passes each
    /// stdout/stderr line to `onLine` (for progress), and reports stderr if it fails.
    @discardableResult
    static func runJob(_ path: String, _ args: [String], environment: [String: String],
                       reporter: ProgressReporter, onLine: (@Sendable (String) -> Void)? = nil) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.environment = environment
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let errData = OSAllocatedUnfairLock(initialState: Data())
        out.fileHandleForReading.readabilityHandler = { handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
            text.split(whereSeparator: { $0 == "\r" || $0 == "\n" }).forEach { onLine?(String($0)) }
        }
        err.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            errData.withLock { $0.append(chunk) }
            String(decoding: chunk, as: UTF8.self)
                .split(whereSeparator: { $0 == "\r" || $0 == "\n" }).forEach { onLine?(String($0)) }
        }
        do { try process.run() } catch {
            reporter.error(error.localizedDescription)
            return false
        }
        while process.isRunning {
            if reporter.isCancelled { process.terminate() }
            Thread.sleep(forTimeInterval: 0.1)
        }
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        if process.terminationStatus != 0, !reporter.isCancelled {
            reporter.error(message(errData.withLock { $0 }, path: path, status: process.terminationStatus))
            return false
        }
        return process.terminationStatus == 0
    }

    private static func message(_ stderr: Data, path: String, status: Int32) -> String {
        let text = String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "\((path as NSString).lastPathComponent) exited with status \(status)" : text
    }

    static func parseISODate(_ text: String?) -> Date {
        guard let text else { return .distantPast }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: text) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: text) ?? .distantPast
    }
}
