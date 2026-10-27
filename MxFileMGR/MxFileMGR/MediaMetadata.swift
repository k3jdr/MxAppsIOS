//
//  MediaMetadata.swift
//  MxFileMGR
//
//  ffmpeg Meta-data… for MP4, M4V, MOV, WebM, MKV, AVI, MP3 and M4A files (file list right-click menu): edit the Title and Description
//  tags with ffmpeg, without re-encoding —
//
//      ffmpeg -i input.mp4 -map 0 -map_metadata 0 -c copy -ignore_unknown \
//             -metadata title="Market Review 2026" -metadata description="Weekly portfolio manager update" output.mp4
//
//  -map 0 keeps every stream (all audio tracks, subtitles, chapters), -map_metadata 0 keeps the other tags,
//  -ignore_unknown skips data streams the container can't take, and an empty value removes the tag. By default
//  the result replaces the original (written to a temporary file next to it first); it can be saved as a new file.
//
//  MOV: QuickTime's standard tags have no description, so ffmpeg would drop it. For .mov the command adds
//  -movflags use_metadata_tags (keys written as mdta metadata) and blanks major_brand, minor_version and
//  compatible_brands in that copy — otherwise each edit appends them again ("qt ;qt "); the file-type header is
//  unaffected. MP4, M4V, WebM and MKV keep description natively (WebM / MKV as DESCRIPTION).
//
//  AVI: its INFO tags have no description either (ffmpeg drops it), so for .avi the Description is written to
//  and read from the comment tag (ICMT).
//
//  MP3: the title is ID3 TIT2 and the description a user-defined frame (TXXX:description), which ffmpeg reads
//  back but music players don't show. -id3v2_version 3 keeps the widely read ID3v2.3 (ffmpeg would write 2.4)
//  and -write_id3v1 1 keeps ID3v1 tags (ffmpeg would drop them). M4A keeps description natively, like MP4.
//
//  A file on an SMB or NFS mount is read and written by ffprobe / ffmpeg on its server, over ssh (FileHost.swift),
//  so the media never crosses the network: only the tags, progress lines and errors come back. The temporary
//  copy is written next to the original on the server and moved into place there.
//

import AppKit
import SwiftUI

nonisolated enum FFmpegTool {
    /// File types the menu offers ffmpeg Meta-data… for.
    static let extensions: Set<String> = ["mp4", "m4v", "mov", "webm", "mkv", "avi", "mp3", "m4a"]

    static func supports(_ url: URL) -> Bool { extensions.contains(url.pathExtension.lowercased()) }

    static var ffmpeg: String? { CLITool.find(["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]) }
    static var ffprobe: String? { CLITool.find(["/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe", "/usr/bin/ffprobe"]) }

    /// The tag the dialog's Description is stored in: AVI has no description tag, so it uses comment (ICMT).
    static func descriptionKey(for url: URL) -> String {
        url.pathExtension.lowercased() == "avi" ? "comment" : "description"
    }

    struct Info: Sendable {
        var tags: [String: String] = [:]      // keys lower-cased (WebM writes DESCRIPTION, MP4 description)
        var format = ""
        var duration: Double?
        var streams: [String] = []            // "video h264", "audio aac", …

        var title: String { tags["title"] ?? "" }
        var descriptionKey = "description"
        var description: String { tags[descriptionKey] ?? "" }
        /// Tags other than title and description, for reference.
        var otherTags: [(String, String)] {
            tags.filter { $0.key != "title" && $0.key != descriptionKey }.sorted { $0.key < $1.key }
        }
    }

    /// What's wrong with running ffmpeg for this file (not installed here or on its host, host unreachable), or nil.
    static func problem(on location: FileLocation) async -> String? {
        guard let host = location.host else {
            return ffmpeg == nil ? "ffmpeg isn't installed. Install it with: brew install ffmpeg" : nil
        }
        let script = switch host.os {
        case .windows: "foreach ($t in 'ffmpeg','ffprobe') { if (-not (Get-Command $t -CommandType Application -ErrorAction SilentlyContinue)) { $t } }"
        case .posix: "for t in ffmpeg ffprobe; do command -v $t >/dev/null 2>&1 || echo $t; done"
        }
        do {
            let missing = try await host.run(script).split(whereSeparator: \.isNewline).map(String.init)
            guard !missing.isEmpty else { return nil }
            let hint = host.os == .windows ? "winget install Gyan.FFmpeg" : "brew install ffmpeg (or the system's package manager)"
            return "\(missing.joined(separator: " and ")) isn't installed on \(host.name), where this file is. Install it there with: \(hint)"
        } catch {
            return (error as? CLIToolError)?.message ?? error.localizedDescription
        }
    }

    /// Current tags, format, duration and streams, from ffprobe (on the file's host).
    static func read(_ location: FileLocation) async throws -> Info {
        let args = ["-v", "error", "-print_format", "json",
                    "-show_entries", "format=format_name,duration:format_tags:stream=codec_type,codec_name", location.path]
        let data: Data
        if let host = location.host {
            data = Data(try await host.run(host.toolScript("ffprobe", args)).utf8)
        } else {
            guard let ffprobe else { throw CLIToolError(message: "ffprobe isn't installed. Install it with: brew install ffmpeg") }
            data = try await CLITool.run(ffprobe, args, environment: CLITool.environment())
        }
        let url = location.url
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let format = json["format"] as? [String: Any] ?? [:]
        var info = Info()
        info.descriptionKey = descriptionKey(for: url)
        for (key, value) in format["tags"] as? [String: Any] ?? [:] {
            info.tags[key.lowercased()] = "\(value)"
        }
        info.format = format["format_name"] as? String ?? ""
        info.duration = (format["duration"] as? String).flatMap(Double.init)
        info.streams = (json["streams"] as? [[String: Any]] ?? []).map {
            "\($0["codec_type"] as? String ?? "?") \($0["codec_name"] as? String ?? "?")"
        }
        return info
    }

    /// Extra options per container (see the header): QuickTime keeps the description, MP3 keeps its tag versions.
    static func containerOptions(for url: URL) -> [String] {
        switch url.pathExtension.lowercased() {
        case "mov":
            return ["-movflags", "use_metadata_tags",
                    "-metadata", "major_brand=", "-metadata", "minor_version=", "-metadata", "compatible_brands="]
        case "mp3":
            return ["-id3v2_version", "3", "-write_id3v1", "1"]
        default:
            return []
        }
    }

    /// The note under the fields: where this format keeps the description.
    static func fieldNote(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "avi": "AVI has no description tag, so Description is stored as the comment (ICMT). An empty field removes that tag."
        case "mp3": "MP3 has no standard description: it is stored as a custom ID3 frame (TXXX:description), which music players don't show. An empty field removes that tag."
        default: "An empty field removes that tag."
        }
    }

    /// `input` and `output` are paths on the machine ffmpeg runs on; `url` (the file as listed) gives the type.
    static func arguments(for url: URL, input: String, output: String, title: String, description: String, progress: Bool) -> [String] {
        ["-nostdin", "-v", "error", "-y", "-i", input,
         "-map", "0", "-map_metadata", "0", "-c", "copy", "-ignore_unknown"]
            + containerOptions(for: url)
            + ["-metadata", "title=\(title)", "-metadata", "\(descriptionKey(for: url))=\(description)"]
            + (progress ? ["-progress", "pipe:1", "-nostats"] : [])
            + [output]
    }

    /// The command as you would type it in Terminal (shown in the dialog).
    static func commandLine(input: URL, output: URL, title: String, description: String) -> String {
        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let extra = containerOptions(for: input).joined(separator: " ")
        return "ffmpeg -i \(q(input.lastPathComponent)) -map 0 -map_metadata 0 -c copy -ignore_unknown \\\n"
            + (extra.isEmpty ? "" : "  \(extra) \\\n")
            + "  -metadata title=\(q(title)) \\\n  -metadata \(descriptionKey(for: input))=\(q(description)) \\\n  \(q(output.lastPathComponent))"
    }

    /// Writes the tags as a background job, on the file's host. `newName` (a file next to it) nil replaces the original.
    @MainActor
    static func write(_ location: FileLocation, title: String, description: String, newName: String?, duration: Double?) {
        if location.isRemote {
            writeRemote(location, title: title, description: description, newName: newName, duration: duration)
            return
        }
        guard let ffmpeg else { Alerts.message("ffmpeg isn't installed.", info: "Install it with: brew install ffmpeg"); return }
        let source = location.url
        let destination = newName.map { source.deletingLastPathComponent().appendingPathComponent($0) }
        let replace = destination == nil
        let stem = source.deletingPathExtension().lastPathComponent
        let output = destination ?? source.deletingLastPathComponent()
            .appendingPathComponent(".\(stem).mxmeta-\(UUID().uuidString.prefix(8)).\(source.pathExtension)")
        let args = arguments(for: source, input: source.path, output: output.path, title: title, description: description, progress: true)
        let name = source.lastPathComponent
        TransferManager.shared.start("Writing meta-data to “\(name)”") { reporter in
            reporter.begin(name)
            let ok = CLITool.runJob(ffmpeg, args, environment: CLITool.environment(), reporter: reporter,
                                    onLine: progressHandler(reporter, name, duration))
            guard ok, !reporter.isCancelled else {
                // Only our own output: the temporary file, or the new file (which didn't exist before).
                try? FileManager.default.removeItem(at: output)
                return
            }
            if replace {
                do {
                    _ = try FileManager.default.replaceItemAt(source, withItemAt: output)
                } catch {
                    reporter.error("\(name): \(error.localizedDescription)")
                    try? FileManager.default.removeItem(at: output)
                }
            }
        }
    }

    /// ffmpeg on the file's server writes a temporary copy next to it, which is then moved over the original
    /// (or to the new name) there. Stopping the job stops that ffmpeg (found by the temporary name) and removes the copy.
    @MainActor
    private static func writeRemote(_ location: FileLocation, title: String, description: String, newName: String?, duration: Double?) {
        guard let host = location.host else { return }
        let source = location.url
        let folder = host.parent(location.path)
        let marker = "mxmeta-\(UUID().uuidString.prefix(8))"
        let temp = host.join(folder, [".\(source.deletingPathExtension().lastPathComponent).\(marker).\(source.pathExtension)"])
        let target = newName.map { host.join(folder, [$0]) } ?? location.path
        let args = arguments(for: source, input: location.path, output: temp, title: title, description: description, progress: true)
        let (q, name) = (host.quote, source.lastPathComponent)
        let finish = switch host.os {
        case .windows: newName == nil
            ? "Move-Item -LiteralPath \(q(temp)) -Destination \(q(target)) -Force -ErrorAction Stop"
            : "Move-Item -LiteralPath \(q(temp)) -Destination \(q(target)) -ErrorAction Stop"
        case .posix: newName == nil
            ? "mv -f -- \(q(temp)) \(q(target))"
            : "if [ -e \(q(target)) ]; then echo \(q("\(newName ?? "") already exists.")) >&2; exit 1; fi; mv -- \(q(temp)) \(q(target))"
        }
        let cleanup = switch host.os {
        case .windows: """
            Get-CimInstance Win32_Process -Filter "Name='ffmpeg.exe'" | Where-Object { $_.CommandLine -like '*\(marker)*' } |
              ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
            Start-Sleep -Milliseconds 500
            Remove-Item -LiteralPath \(q(temp)) -Force -ErrorAction SilentlyContinue
            """
        // The bracket keeps pkill from matching this shell's own command line.
        case .posix: "pkill -f \(q(marker.replacingOccurrences(of: "-", with: "[-]"))); sleep 0.5; rm -f -- \(q(temp))"
        }
        TransferManager.shared.start("Writing meta-data to “\(name)” on \(host.name)") { reporter in
            reporter.begin(name)
            let ok = host.runJob(host.toolScript("ffmpeg", args), reporter: reporter,
                                 onLine: progressHandler(reporter, name, duration))
            if ok, !reporter.isCancelled, host.runJob(finish, reporter: reporter) { return }
            _ = try? await host.run(cleanup)
        }
    }

    private static func progressHandler(_ reporter: ProgressReporter, _ name: String, _ duration: Double?) -> @Sendable (String) -> Void {
        { line in
            if line.hasPrefix("out_time_us="), let us = Double(line.dropFirst("out_time_us=".count)),
               let duration, duration > 0 {
                reporter.progress(done: Int64(max(0, us)), of: Int64(duration * 1_000_000), name)
            }
        }
    }
}

/// The ffmpeg Meta-data… dialog.
struct MediaMetadataSheet: View {
    let workspace: Workspace
    let url: URL
    @State private var info: FFmpegTool.Info?
    @State private var location: FileLocation?
    @State private var toolProblem: String?
    @State private var title = ""
    @State private var descriptionText = ""
    @State private var saveAsNew = false
    @State private var newName = ""
    @State private var loadError: String?
    @Environment(\.dismiss) private var dismiss

    private var output: URL {
        saveAsNew ? url.deletingLastPathComponent().appendingPathComponent(newName) : url
    }

    private var newNameProblem: String? {
        guard saveAsNew else { return nil }
        let name = newName.trimmingCharacters(in: .whitespaces)
        if name.isEmpty || name.contains("/") { return "Enter a file name." }
        if (name as NSString).pathExtension.lowercased() != url.pathExtension.lowercased() {
            return "Keep the .\(url.pathExtension) extension."
        }
        if FileOps.exists(output) { return "“\(name)” already exists." }
        return nil
    }

    private var changed: Bool {
        guard let info else { return false }
        return saveAsNew || title != info.title || descriptionText != info.description
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("ffmpeg Meta-data").font(.headline)
                    Text(url.lastPathComponent).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    if let info {
                        Text(summary(info)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            if let toolProblem {
                Label(toolProblem, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange).textSelection(.enabled)
            } else if let loadError {
                Text(loadError).foregroundStyle(.red).font(.callout).textSelection(.enabled)
            } else if info == nil {
                HStack { ProgressView().controlSize(.small); Text("Reading the current tags…") }
            }
            if let location, let host = location.host {
                Label("ffmpeg runs on \(host.name), where the file is: \(location.path)", systemImage: "server.rack")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Title:")
                    TextField("e.g. Market Review 2026", text: $title)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow(alignment: .top) {
                    Text("Description:")
                    TextEditor(text: $descriptionText)
                        .font(.body)
                        .frame(minHeight: 70, maxHeight: 120)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.35)))
                }
                GridRow {
                    Text("")
                    Text(FFmpegTool.fieldNote(for: url))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .disabled(info == nil)

            Toggle("Save as a new file", isOn: $saveAsNew)
            if saveAsNew {
                TextField("New file name", text: $newName)
                    .textFieldStyle(.roundedBorder)
                if let problem = newNameProblem {
                    Text(problem).font(.caption).foregroundStyle(.red)
                }
            } else {
                Text("The original is replaced once ffmpeg has written the new copy; nothing is re-encoded.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if let info, !info.otherTags.isEmpty {
                DisclosureGroup("Other tags (kept)") {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(info.otherTags, id: \.0) { key, value in
                            Text("\(key): \(value)").font(.caption.monospaced()).textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.callout)
            }

            DisclosureGroup("Command") {
                Text(FFmpegTool.commandLine(input: url, output: output, title: title, description: descriptionText))
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
            }
            .font(.callout)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Apply") { apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(info == nil || location == nil || toolProblem != nil || newNameProblem != nil || !changed)
            }
        }
        .padding(20)
        .frame(width: 540)
        .task { await load() }
        .onChange(of: saveAsNew) {
            if saveAsNew, newName.isEmpty {
                newName = FileOps.availableURL(in: url.deletingLastPathComponent(),
                                               stem: url.deletingPathExtension().lastPathComponent + " (edited)",
                                               ext: url.pathExtension).lastPathComponent
            }
        }
    }

    private func summary(_ info: FFmpegTool.Info) -> String {
        var parts = [url.pathExtension.uppercased()]
        if !info.streams.isEmpty { parts.append(info.streams.joined(separator: ", ")) }
        if let d = info.duration {
            let s = Int(d.rounded())
            parts.append(s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60))
        }
        if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize { parts.append(Fmt.size(Int64(size))) }
        return parts.joined(separator: " · ")
    }

    private func load() async {
        do {
            let location = try await FileHosts.locate(url)
            self.location = location
            toolProblem = await FFmpegTool.problem(on: location)
            guard toolProblem == nil else { return }
            let read = try await FFmpegTool.read(location)
            info = read
            title = read.title
            descriptionText = read.description
        } catch {
            loadError = (error as? CLIToolError)?.message ?? error.localizedDescription
        }
    }

    private func apply() {
        guard let location else { return }
        let destination = saveAsNew ? output : nil
        FFmpegTool.write(location, title: title, description: descriptionText,
                         newName: destination?.lastPathComponent, duration: info?.duration)
        if let destination { workspace.activeTab.focus(on: destination) }
        dismiss()
    }
}
