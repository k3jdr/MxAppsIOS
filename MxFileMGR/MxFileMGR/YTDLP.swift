//
//  YTDLP.swift
//  MxFileMGR
//
//  yt-dlp Download… (file list right-click menu): type a URL or a whole yt-dlp command; it runs in the
//  folder shown, as a background job in the transfer panel. Each line of the dialog is its own job, and the
//  dialog can be opened again while others run, so any number of downloads run at the same time.
//
//  The command is split into words here and run without a shell: quotes and backslashes work as in Terminal,
//  but a URL's ? and & need no quoting, and pipes and redirects aren't available.
//
//  Progress comes from --progress-template, which prints each update as JSON. A job waits with Task.sleep
//  rather than blocking a thread, so running downloads never hold up the app's other background work.
//
//  Stop sends SIGINT, which yt-dlp handles by stopping its ffmpeg and exiting; the .part file stays, and
//  running the same command again resumes it where the server allows that.
//

import AppKit
import SwiftUI
import os

nonisolated enum YTDLP {
    static var tool: String? { CLITool.find(["/opt/homebrew/bin/yt-dlp", "/usr/local/bin/yt-dlp", "/usr/bin/yt-dlp"]) }

    // MARK: The command

    /// The commands in the dialog's text, as arguments for yt-dlp: one per line, and a backslash at the
    /// end of a line continues it. A leading "yt-dlp" is optional.
    static func commands(in text: String) throws -> [[String]] {
        try text.replacingOccurrences(of: "\\\n", with: " ")
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { line in
                var args = try words(in: line)
                if args.first == "yt-dlp" { args.removeFirst() }
                guard !args.isEmpty else { throw CLIToolError(message: "Add a URL to download.") }
                if let op = args.first(where: shellOperators.contains) {
                    throw CLIToolError(message: "“\(op)” needs a shell, and yt-dlp runs without one here.")
                }
                return args
            }
    }

    private static let shellOperators: Set<String> = ["|", "||", "&", "&&", ";", ">", ">>", "<"]

    /// Splits a line as a shell would: 'single quotes', "double quotes" and backslash escapes.
    static func words(in line: String) throws -> [String] {
        var words: [String] = []
        var word: String?
        var quote: Character?
        var escaped = false
        for c in line {
            if escaped {
                // Within double quotes a backslash only escapes what's special there.
                if quote == "\"", !"\"\\$`".contains(c) { word?.append("\\") }
                word = (word ?? "") + String(c)
                escaped = false
            } else if c == "\\", quote != "'" {
                escaped = true
                if word == nil { word = "" }
            } else if let open = quote {
                if c == open { quote = nil } else { word?.append(c) }
            } else if c == "'" || c == "\"" {
                quote = c
                if word == nil { word = "" }
            } else if c.isWhitespace {
                if let finished = word { words.append(finished) }
                word = nil
            } else {
                word = (word ?? "") + String(c)
            }
        }
        if let quote { throw CLIToolError(message: "A \(quote) quote isn't closed.") }
        if escaped { throw CLIToolError(message: "The line ends with a lone backslash.") }
        if let word { words.append(word) }
        return words
    }

    /// The job's name in the transfer panel: the URL, or else the command.
    static func title(for args: [String]) -> String {
        let target = args.first { $0.contains("://") } ?? args.joined(separator: " ")
        return "yt-dlp " + (target.count > 70 ? target.prefix(70) + "…" : target)
    }

    // MARK: Running

    private static let marker = "mxdl"

    /// Goes first, so anything the command itself says (--no-progress, its own template) wins.
    private static var progressArguments: [String] {
        ["--newline", "--progress", "--progress-template",
         "download:\(marker)\t%(progress.{status,downloaded_bytes,total_bytes,total_bytes_estimate,speed,eta})j"
            + "\t%(info.{title,playlist_index,n_entries})j"]
    }

    /// Starts one download as a job in the transfer panel, and returns at once.
    @MainActor
    static func download(_ args: [String], in folder: URL) {
        guard let tool else { Alerts.message("yt-dlp isn't installed.", info: "Install it with: brew install yt-dlp"); return }
        TransferManager.shared.start(title(for: args)) { reporter in
            await run(tool, args, in: folder, reporter: reporter)
        }
    }

    private static func run(_ tool: String, _ args: [String], in folder: URL, reporter: ProgressReporter) async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = progressArguments + args
        process.currentDirectoryURL = folder
        process.environment = CLITool.environment()
        process.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err

        let downloaded = OSAllocatedUnfairLock(initialState: false)
        let problems = OSAllocatedUnfairLock(initialState: [String]())
        let outLines = LineReader(out) { line in
            if let update = Update(line: line) {
                downloaded.withLock { $0 = true }
                reporter.progress(done: update.done, of: update.total, update.detail)
            } else {
                reporter.log(line)
                reporter.status(line)
            }
        }
        let errLines = LineReader(err) { line in
            reporter.log(line)
            problems.withLock { $0.append(line) }
        }

        do { try process.run() } catch {
            outLines.stop()
            errLines.stop()
            reporter.error(error.localizedDescription)
            return
        }

        var stopSent: Date?
        while process.isRunning {
            if reporter.isCancelled {
                if let stopSent {
                    if Date().timeIntervalSince(stopSent) > 5 { process.terminate() }
                } else {
                    stopSent = Date()
                    process.interrupt()
                }
            }
            try? await Task.sleep(for: .milliseconds(150))
        }

        // The last lines may still be in the pipes. A leftover child process can hold them open, so don't wait long.
        let deadline = Date().addingTimeInterval(2)
        while !(outLines.isFinished && errLines.isFinished), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        outLines.stop()
        errLines.stop()

        guard !reporter.isCancelled else { return }
        if process.terminationStatus != 0 {
            let lines = problems.withLock { $0 }
            let errors = lines.filter { $0.hasPrefix("ERROR:") }
            let shown = errors.isEmpty ? lines : errors
            reporter.error(shown.isEmpty ? "yt-dlp exited with status \(process.terminationStatus)" : shown.joined(separator: "\n"))
        } else if !downloaded.withLock({ $0 }) {
            // -F, --version, --print and the like: what they printed is the point, so it stays to be read.
            await MainActor.run { reporter.job.keepListed = true }
        }
    }

    // MARK: Progress

    /// One line of --progress-template output.
    struct Update {
        var done: Int64
        var total: Int64
        var detail: String

        private struct Progress: Decodable {
            var status: String?
            var downloaded_bytes: Double?
            var total_bytes: Double?
            var total_bytes_estimate: Double?
            var speed: Double?
            var eta: Double?
        }

        private struct Info: Decodable {
            var title: String?
            var playlist_index: Int?
            var n_entries: Int?
        }

        init?(line: String) {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 3, fields[0] == YTDLP.marker,
                  let progress = try? JSONDecoder().decode(Progress.self, from: Data(fields[1].utf8)),
                  let info = try? JSONDecoder().decode(Info.self, from: Data(fields[2].utf8)) else { return nil }
            let total = progress.total_bytes ?? progress.total_bytes_estimate ?? 0
            let done = progress.downloaded_bytes ?? (progress.status == "finished" ? total : 0)
            self.done = Int64(done)
            self.total = Int64(total)

            var facts: [String] = []
            if total > 0 {
                facts.append("\(Int(min(1, done / total) * 100))% of \(Fmt.size(Int64(total)))")
            } else if done > 0 {
                facts.append(Fmt.size(Int64(done)))
            }
            if progress.status != "finished" {
                if let speed = progress.speed { facts.append("\(Fmt.size(Int64(speed)))/s") }
                if let eta = progress.eta { facts.append("\(Self.time(eta)) left") }
            }
            var name = info.title ?? ""
            if let index = info.playlist_index, let count = info.n_entries { name = "\(index)/\(count) \(name)" }
            detail = ([name] + (facts.isEmpty ? [] : [facts.joined(separator: " · ")])).joined(separator: " — ")
        }

        private static func time(_ seconds: Double) -> String {
            let s = Int(seconds.rounded())
            return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
        }
    }

    /// Reads a pipe as it fills and passes on whole lines; one read can end anywhere, even within a character.
    private final class LineReader: @unchecked Sendable {
        private let lock = NSLock()
        private let handle: FileHandle
        private var pending = Data()
        private var finished = false

        var isFinished: Bool { lock.withLock { finished } }

        init(_ pipe: Pipe, onLine: @escaping @Sendable (String) -> Void) {
            handle = pipe.fileHandleForReading
            handle.readabilityHandler = { [self] handle in
                let chunk = handle.availableData
                if chunk.isEmpty { handle.readabilityHandler = nil }
                let lines: [Data] = lock.withLock {
                    pending.append(chunk)
                    var parts = pending.split(omittingEmptySubsequences: false) { $0 == 10 || $0 == 13 }.map { Data($0) }
                    // The last part is an unfinished line, until the pipe has ended.
                    pending = chunk.isEmpty ? Data() : (parts.popLast() ?? Data())
                    return parts
                }
                lines.filter { !$0.isEmpty }.forEach { onLine(String(decoding: $0, as: UTF8.self)) }
                if chunk.isEmpty { lock.withLock { finished = true } }
            }
        }

        func stop() { handle.readabilityHandler = nil }
    }
}

/// The yt-dlp Download… dialog. Downloads run in the transfer panel, so it closes as soon as they start.
struct YTDLPSheet: View {
    let folder: URL
    @State private var text = ""
    @FocusState private var fieldFocused: Bool
    @Environment(\.dismiss) private var dismiss

    private var parsed: Result<[[String]], Error> { Result { try YTDLP.commands(in: text) } }

    private var commands: [[String]] { (try? parsed.get()) ?? [] }

    private var problem: String? {
        if case .failure(let error) = parsed { return error.localizedDescription }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("yt-dlp Download").font(.headline)
                Text("Saves to \(folder.path)")
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    .help(folder.path)
            }

            if YTDLP.tool == nil {
                Label("yt-dlp isn't installed. Install it with: brew install yt-dlp", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange).textSelection(.enabled)
            }

            TextField("URL, or yt-dlp options and URL", text: $text, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
                .lineLimit(3...10)
                .autocorrectionDisabled()
                .focused($fieldFocused)
                .onSubmit(start)

            if let problem {
                Text(problem).font(.caption).foregroundStyle(.red)
            }
            Text("A URL, or a whole command such as yt-dlp -x --audio-format mp3 URL. Each line is its own download (⌥Return starts a new line, and pasted lines stay separate). "
                 + "Downloads run in the background, with their progress in the transfer panel; open this again to start more.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(commands.count > 1 ? "Download \(commands.count)" : "Download", action: start)
                    .keyboardShortcut(.defaultAction)
                    .disabled(commands.isEmpty || problem != nil || YTDLP.tool == nil)
            }
        }
        .padding(20)
        .frame(width: 600)
        .onAppear {
            // A link just copied is what's most likely to be downloaded.
            if let copied = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
               copied.hasPrefix("http://") || copied.hasPrefix("https://"), !copied.contains(where: \.isWhitespace) {
                text = "yt-dlp \(copied)"
            }
            fieldFocused = true
        }
    }

    private func start() {
        guard !commands.isEmpty, problem == nil, YTDLP.tool != nil else { return }
        commands.forEach { YTDLP.download($0, in: folder) }
        dismiss()
    }
}
