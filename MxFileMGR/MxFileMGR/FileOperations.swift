//
//  FileOperations.swift
//  MxFileMGR
//
//  Background file operations (copy, move, trash, delete, archive) with
//  progress, cancellation and conflict handling. Jobs show in the transfer
//  panel at the bottom of every window.
//

import AppKit
import Foundation
import os

nonisolated enum ConflictPolicy: String, CaseIterable, Identifiable, Sendable {
    case ask, overwrite, overwriteOlder, skip, keepBoth
    var id: String { rawValue }

    var title: String {
        switch self {
        case .ask: "Ask"
        case .overwrite: "Replace"
        case .overwriteOlder: "Replace if older"
        case .skip: "Skip"
        case .keepBoth: "Keep both (rename)"
        }
    }
}

nonisolated enum ConflictDecision: Sendable {
    case overwrite, skip, keepBoth, cancel
}

nonisolated final class CancelFlag: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: false)
    var isCancelled: Bool { state.withLock { $0 } }
    func cancel() { state.withLock { $0 = true } }
}

@Observable
final class TransferJob: Identifiable {
    enum State: Equatable { case running, finished, cancelled }

    let id = UUID()
    let title: String
    var detail = ""
    /// nil while the size is unknown (indeterminate progress).
    var fraction: Double?
    var state: State = .running
    var errors: [String] = []
    @ObservationIgnored let flag = CancelFlag()

    init(title: String) { self.title = title }

    func cancel() { flag.cancel() }
}

/// Thread-safe, throttled progress reporting from a background job to its TransferJob.
nonisolated final class ProgressReporter: @unchecked Sendable {
    let job: TransferJob
    let flag: CancelFlag
    private let lock = NSLock()
    private var total: Int64 = 0
    private var done: Int64 = 0
    private var current: Int64 = 0
    private var name = ""
    private var lastPost = Date.distantPast

    init(job: TransferJob, flag: CancelFlag) {
        self.job = job
        self.flag = flag
    }

    var isCancelled: Bool { flag.isCancelled }

    func setTotal(_ bytes: Int64) {
        lock.withLock { total = bytes }
        post(force: true)
    }

    func begin(_ fileName: String) {
        lock.withLock { name = fileName; current = 0 }
        post(force: false)
    }

    func fileProgress(_ bytes: Int64) {
        lock.withLock { current = bytes }
        post(force: false)
    }

    func add(_ bytes: Int64) {
        lock.withLock { done += bytes; current = 0 }
        post(force: false)
    }

    /// Absolute progress reported by an external tool (e.g. the AWS CLI).
    func progress(done bytes: Int64, of totalBytes: Int64, _ detail: String) {
        lock.withLock { total = totalBytes; done = bytes; current = 0; name = detail }
        post(force: false)
    }

    func step(_ index: Int, of count: Int, _ fileName: String) {
        lock.withLock { total = Int64(count); done = Int64(index); current = 0; name = fileName }
        post(force: false)
    }

    func error(_ message: String) {
        let job = job
        Task { @MainActor in job.errors.append(message) }
    }

    private func post(force: Bool) {
        let update: (fraction: Double?, detail: String)? = lock.withLock {
            let now = Date()
            guard force || now.timeIntervalSince(lastPost) > 0.1 else { return nil }
            lastPost = now
            let f: Double? = total > 0 ? min(1, Double(done + current) / Double(total)) : nil
            return (f, name)
        }
        guard let (fraction, detail) = update else { return }
        let job = job
        Task { @MainActor in
            job.fraction = fraction
            job.detail = detail
        }
    }
}

@Observable
final class TransferManager {
    static let shared = TransferManager()
    private(set) var jobs: [TransferJob] = []

    /// Runs `work` in the background as a job shown in the transfer panel.
    @discardableResult
    func start(_ title: String, work: @escaping @Sendable (ProgressReporter) async -> Void) -> TransferJob {
        let job = TransferJob(title: title)
        jobs.append(job)
        let reporter = ProgressReporter(job: job, flag: job.flag)
        Task.detached(priority: .userInitiated) {
            await work(reporter)
            await MainActor.run { TransferManager.shared.finish(job) }
        }
        return job
    }

    func dismiss(_ job: TransferJob) {
        jobs.removeAll { $0.id == job.id }
    }

    func clearFinished() {
        jobs.removeAll { $0.state != .running }
    }

    private func finish(_ job: TransferJob) {
        job.state = job.flag.isCancelled ? .cancelled : .finished
        job.fraction = 1
        NotificationCenter.default.post(name: .mxFilesChanged, object: nil)
        // Clean jobs leave the panel on their own; ones with errors stay until dismissed.
        if job.errors.isEmpty {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                self?.dismiss(job)
            }
        }
    }

    // MARK: Job types

    /// Copies (or moves) each source to its full destination path.
    func copy(_ pairs: [(URL, URL)], move: Bool, policy: ConflictPolicy) {
        guard !pairs.isEmpty else { return }
        let verb = move ? "Moving" : "Copying"
        let title = pairs.count == 1
            ? "\(verb) “\(pairs[0].0.lastPathComponent)”"
            : "\(verb) \(pairs.count) items"
        start(title) { reporter in
            let engine = CopyEngine(move: move, policy: policy, reporter: reporter)
            await engine.run(pairs)
        }
    }

    func trash(_ urls: [URL]) {
        start("Moving \(Fmt.count(urls.count, "item")) to the Trash") { reporter in
            for (i, url) in urls.enumerated() where !reporter.isCancelled {
                reporter.step(i, of: urls.count, url.lastPathComponent)
                do { try FileManager.default.trashItem(at: url, resultingItemURL: nil) }
                catch { reporter.error("\(url.lastPathComponent): \(error.localizedDescription)") }
            }
        }
    }

    func delete(_ urls: [URL]) {
        start("Deleting \(Fmt.count(urls.count, "item"))") { reporter in
            for (i, url) in urls.enumerated() where !reporter.isCancelled {
                reporter.step(i, of: urls.count, url.lastPathComponent)
                do { try FileManager.default.removeItem(at: url) }
                catch { reporter.error("\(url.lastPathComponent): \(error.localizedDescription)") }
            }
        }
    }

    /// Zips `items` (all in `folder`) into `archive`.
    func compress(_ items: [URL], in folder: URL, to archive: URL) {
        start("Compressing to “\(archive.lastPathComponent)”") { reporter in
            reporter.begin(archive.lastPathComponent)
            if items.count == 1 {
                FileOps.runProcess("/usr/bin/ditto",
                                   ["-c", "-k", "--sequesterRsrc", "--keepParent", items[0].fsPath, archive.fsPath],
                                   reporter: reporter)
            } else {
                FileOps.runProcess("/usr/bin/zip", ["-r", "-y", "-q", archive.fsPath] + items.map(\.lastPathComponent),
                                   in: folder, reporter: reporter)
            }
        }
    }

    /// Extracts each archive into its own new folder inside `destination`.
    func extract(_ archives: [URL], into destination: URL) {
        start("Extracting \(Fmt.count(archives.count, "archive"))") { reporter in
            for (i, archive) in archives.enumerated() where !reporter.isCancelled {
                reporter.step(i, of: archives.count, archive.lastPathComponent)
                let target = FileOps.availableURL(in: destination, stem: FileOps.archiveStem(archive), ext: "")
                do {
                    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                } catch {
                    reporter.error(error.localizedDescription)
                    continue
                }
                if archive.pathExtension.lowercased() == "zip" {
                    FileOps.runProcess("/usr/bin/ditto", ["-x", "-k", archive.fsPath, target.fsPath], reporter: reporter)
                } else {
                    FileOps.runProcess("/usr/bin/tar", ["-xf", archive.fsPath, "-C", target.fsPath], reporter: reporter)
                }
            }
        }
    }
}

// MARK: - Helpers

nonisolated enum FileOps {
    static let archiveExtensions: Set<String> = ["zip", "tar", "tgz", "gz", "tbz", "tbz2", "bz2", "txz", "xz", "7z", "rar"]
    /// Archives `tar` (libarchive) and `ditto` can unpack.
    static let extractableExtensions: Set<String> = ["zip", "tar", "tgz", "gz", "tbz", "tbz2", "bz2", "txz", "xz", "7z", "rar", "cpio", "xar", "iso"]

    static func isArchive(_ url: URL) -> Bool {
        extractableExtensions.contains(url.pathExtension.lowercased())
    }

    /// "photos.tar.gz" -> "photos".
    static func archiveStem(_ url: URL) -> String {
        var u = url.deletingPathExtension()
        if u.pathExtension.lowercased() == "tar" { u = u.deletingPathExtension() }
        return u.lastPathComponent
    }

    /// Total bytes of regular files and number of entries below `urls`.
    static func totals(of urls: [URL]) -> (bytes: Int64, count: Int) {
        var bytes: Int64 = 0
        var count = 0
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        for url in urls {
            count += 1
            guard isRealDirectory(url) else {
                bytes += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
                continue
            }
            guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [],
                                                         errorHandler: { _, _ in true }) else { continue }
            while let f = e.nextObject() as? URL {
                count += 1
                if let v = try? f.resourceValues(forKeys: Set(keys)), v.isRegularFile == true {
                    bytes += Int64(v.fileSize ?? 0)
                }
            }
        }
        return (bytes, count)
    }

    /// True for a directory that is not a symlink.
    static func isRealDirectory(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.fsPath, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
    }

    /// True if anything (even a dangling symlink) is at `url`.
    static func exists(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.fsPath, &st) == 0
    }

    static func modificationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
    }

    static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        guard let va = (try? a.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier,
              let vb = (try? b.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier else { return false }
        return va.isEqual(vb)
    }

    /// Finder-style "name copy.ext", "name copy 2.ext", ... next to `url`.
    static func keepBothURL(for url: URL) -> URL {
        let dir = url.deletingLastPathComponent()
        let ext = isRealDirectory(url) ? "" : url.pathExtension
        let stem = ext.isEmpty ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
        var n = 1
        while true {
            let name = n == 1 ? "\(stem) copy" : "\(stem) copy \(n)"
            let candidate = dir.appendingPathComponent(ext.isEmpty ? name : "\(name).\(ext)")
            if !exists(candidate) { return candidate }
            n += 1
        }
    }

    /// "stem.ext", or "stem 2.ext", "stem 3.ext", ... if taken.
    static func availableURL(in dir: URL, stem: String, ext: String) -> URL {
        var n = 1
        while true {
            let name = n == 1 ? stem : "\(stem) \(n)"
            let candidate = dir.appendingPathComponent(ext.isEmpty ? name : "\(name).\(ext)")
            if !exists(candidate) { return candidate }
            n += 1
        }
    }

    /// Runs a command, terminating it if the job is cancelled. Reports stderr on failure.
    @discardableResult
    static func runProcess(_ executable: String, _ arguments: [String], in directory: URL? = nil,
                           reporter: ProgressReporter) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let directory { process.currentDirectoryURL = directory }
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = FileHandle.nullDevice
        do { try process.run() } catch {
            reporter.error("\(executable): \(error.localizedDescription)")
            return false
        }
        while process.isRunning {
            if reporter.isCancelled { process.terminate() }
            Thread.sleep(forTimeInterval: 0.1)
        }
        if process.terminationStatus != 0, !reporter.isCancelled {
            let text = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            reporter.error(text.isEmpty ? "\(executable) failed (\(process.terminationStatus))" : text)
            return false
        }
        return process.terminationStatus == 0
    }
}

// MARK: - Copy engine

/// Copies or moves files and folders. Folders that already exist at the destination
/// are merged; conflicts on files follow the policy (asking when it is `.ask`).
/// File data is copied with copyfile(3), which clones on APFS and reports progress.
nonisolated final class CopyEngine: @unchecked Sendable {
    let move: Bool
    let reporter: ProgressReporter
    private var policy: ConflictPolicy
    private let fm = FileManager()

    init(move: Bool, policy: ConflictPolicy, reporter: ProgressReporter) {
        self.move = move
        self.policy = policy
        self.reporter = reporter
    }

    func run(_ pairs: [(URL, URL)]) async {
        reporter.setTotal(FileOps.totals(of: pairs.map(\.0)).bytes)
        for (src, dst) in pairs {
            if reporter.isCancelled { return }
            try? fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            await transfer(src, to: dst)
        }
    }

    /// Returns true when `src` was transferred completely (so a move may remove it).
    @discardableResult
    private func transfer(_ src: URL, to destination: URL) async -> Bool {
        if reporter.isCancelled { return false }
        var dst = destination
        let srcPath = src.fsPath
        let dstPath = dst.fsPath
        let srcIsDir = FileOps.isRealDirectory(src)

        if srcPath == dstPath {
            if move { return true }                 // moving onto itself: nothing to do
            dst = FileOps.keepBothURL(for: dst)     // copying onto itself: duplicate
        } else if srcIsDir, dstPath.hasPrefix(srcPath + "/") {
            reporter.error("Can't copy “\(src.lastPathComponent)” into itself.")
            return false
        } else if FileOps.exists(dst) {
            if srcIsDir, FileOps.isRealDirectory(dst) {
                return await mergeContents(of: src, into: dst)
            }
            switch await resolve(src, dst) {
            case .skip:
                reporter.add(FileOps.totals(of: [src]).bytes)
                return false
            case .cancel:
                reporter.flag.cancel()
                return false
            case .keepBoth:
                dst = FileOps.keepBothURL(for: dst)
            case .overwrite:
                do { try fm.removeItem(at: dst) } catch {
                    reporter.error("\(dst.lastPathComponent): \(error.localizedDescription)")
                    return false
                }
            }
        }

        // A move within one volume is a rename.
        if move, FileOps.sameVolume(src, dst.deletingLastPathComponent()) {
            reporter.begin(src.lastPathComponent)
            do {
                try fm.moveItem(at: src, to: dst)
                reporter.add(FileOps.totals(of: [dst]).bytes)
                return true
            } catch {
                reporter.error("\(src.lastPathComponent): \(error.localizedDescription)")
                return false
            }
        }

        if srcIsDir {
            do { try fm.createDirectory(at: dst, withIntermediateDirectories: false) } catch {
                reporter.error("\(dst.lastPathComponent): \(error.localizedDescription)")
                return false
            }
            let ok = await mergeContents(of: src, into: dst)
            copyfile(srcPath, dst.fsPath, nil, copyfile_flags_t(COPYFILE_METADATA))
            return ok
        }

        guard copyFile(src, dst) else { return false }
        if move {
            do { try fm.removeItem(at: src) } catch {
                reporter.error("\(src.lastPathComponent): \(error.localizedDescription)")
                return false
            }
        }
        return true
    }

    private func mergeContents(of src: URL, into dst: URL) async -> Bool {
        let children: [URL]
        do { children = try fm.contentsOfDirectory(at: src, includingPropertiesForKeys: nil) } catch {
            reporter.error("\(src.lastPathComponent): \(error.localizedDescription)")
            return false
        }
        var ok = true
        for child in children {
            if reporter.isCancelled { return false }
            if !(await transfer(child, to: dst.appendingPathComponent(child.lastPathComponent))) { ok = false }
        }
        if ok, move {
            do { try fm.removeItem(at: src) } catch {
                reporter.error("\(src.lastPathComponent): \(error.localizedDescription)")
                return false
            }
        }
        return ok
    }

    private func resolve(_ src: URL, _ dst: URL) async -> ConflictDecision {
        switch policy {
        case .overwrite: return .overwrite
        case .skip: return .skip
        case .keepBoth: return .keepBoth
        case .overwriteOlder:
            return FileOps.modificationDate(src) > FileOps.modificationDate(dst) ? .overwrite : .skip
        case .ask:
            let (decision, applyToAll) = await ConflictPrompt.ask(source: src, destination: dst)
            if applyToAll {
                switch decision {
                case .overwrite: policy = .overwrite
                case .skip: policy = .skip
                case .keepBoth: policy = .keepBoth
                case .cancel: break
                }
            }
            return decision
        }
    }

    private func copyFile(_ src: URL, _ dst: URL) -> Bool {
        reporter.begin(src.lastPathComponent)
        let size = Int64((try? src.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        guard let state = copyfile_state_alloc() else { return false }
        defer { copyfile_state_free(state) }
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(CopyCallback.function, to: UnsafeRawPointer.self))
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), Unmanaged.passUnretained(self).toOpaque())
        // COPYFILE_CLONE: clone on APFS when possible, otherwise copy data and all metadata.
        if copyfile(src.fsPath, dst.fsPath, state, copyfile_flags_t(COPYFILE_CLONE)) != 0 {
            let err = errno
            if err != EEXIST { try? fm.removeItem(at: dst) }
            if err != ECANCELED, !reporter.isCancelled {
                reporter.error("\(src.lastPathComponent): \(String(cString: strerror(err)))")
            }
            return false
        }
        reporter.add(size)
        return true
    }

    fileprivate func dataProgress(_ bytes: Int64) -> Bool {
        reporter.fileProgress(bytes)
        return !reporter.isCancelled
    }
}

nonisolated private enum CopyCallback {
    static let function: copyfile_callback_t = { what, stage, state, _, _, ctx in
        guard let ctx else { return COPYFILE_CONTINUE }
        let engine = Unmanaged<CopyEngine>.fromOpaque(ctx).takeUnretainedValue()
        if engine.reporter.isCancelled { return COPYFILE_QUIT }
        if what == COPYFILE_COPY_DATA, stage == COPYFILE_PROGRESS {
            var copied: off_t = 0
            copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &copied)
            if !engine.dataProgress(Int64(copied)) { return COPYFILE_QUIT }
        }
        return COPYFILE_CONTINUE
    }
}

// MARK: - Conflict prompt

enum ConflictPrompt {
    static func ask(source: URL, destination: URL) -> (ConflictDecision, Bool) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "“\(destination.lastPathComponent)” already exists in “\(destination.deletingLastPathComponent().lastPathComponent)”."
        alert.informativeText = """
            Existing: \(describe(destination))
            New:       \(describe(source))
            """
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Skip")
        alert.addButton(withTitle: "Keep Both")
        alert.addButton(withTitle: "Stop")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Apply to all"
        NSApp.activate()
        let response = alert.runModal()
        let all = alert.suppressionButton?.state == .on
        switch response {
        case .alertFirstButtonReturn: return (.overwrite, all)
        case .alertSecondButtonReturn: return (.skip, all)
        case .alertThirdButtonReturn: return (.keepBoth, all)
        default: return (.cancel, false)
        }
    }

    private static func describe(_ url: URL) -> String {
        let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey])
        if v?.isDirectory == true { return "folder, modified \(Fmt.date(v?.contentModificationDate ?? .distantPast))" }
        return "\(Fmt.size(Int64(v?.fileSize ?? 0))), modified \(Fmt.date(v?.contentModificationDate ?? .distantPast))"
    }
}
