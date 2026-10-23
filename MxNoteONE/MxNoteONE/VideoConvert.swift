//
//  VideoConvert.swift
//  MxNoteONE
//
//  Videos macOS can't decode — VP9 or AV1 from the web, often in an .mp4 —
//  are converted to an H.264 / AAC .mp4 that plays everywhere, with ffmpeg
//  (Homebrew's, when it's installed) using the Mac's hardware encoder. A video
//  is converted as it's put on the page; one already on a page is converted
//  in place when it's played (or from its right-click menu).
//

import AVFoundation
import Foundation

enum VideoConverter {
    enum Failure: LocalizedError {
        case noFFmpeg, failed(String)

        var errorDescription: String? {
            switch self {
            case .noFFmpeg: "ffmpeg, which converts the video, isn't installed."
            case .failed(let why): "ffmpeg couldn't convert the video" + (why.isEmpty ? "." : ": \(why)")
            }
        }
    }

    /// ffmpeg from Homebrew or MacPorts (apps don't see the shell's PATH).
    static var ffmpeg: URL? {
        ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/opt/local/bin/ffmpeg"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map(URL.init(fileURLWithPath:))
    }

    /// Whether macOS can show the video's picture (a file with sound only counts as playable).
    static func canPlay(_ url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else {
            return (try? await asset.load(.isPlayable)) ?? false
        }
        return (try? await track.load(.isDecodable)) ?? false
    }

    /// The picture's codec, by name ("VP9", "AV1"), for messages.
    static func codecName(_ url: URL) async -> String {
        guard let track = try? await AVURLAsset(url: url).loadTracks(withMediaType: .video).first,
              let format = try? await track.load(.formatDescriptions).first else { return "this kind of" }
        let code = CMFormatDescriptionGetMediaSubType(format)
        let fourcc = String(bytes: [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }, encoding: .ascii)?
            .trimmingCharacters(in: .whitespaces) ?? "?"
        return ["vp09": "VP9", "vp08": "VP8", "av01": "AV1", "theo": "Theora"][fourcc] ?? fourcc.uppercased()
    }

    static func noFFmpegMessage(_ name: String, codec: String) -> String {
        "“\(name)” is \(codec) video, which macOS can't play. MxNoteONE converts such videos to H.264 with ffmpeg, "
            + "which isn't installed. Install it with Homebrew (brew install ffmpeg) and try again, or convert the video "
            + "to an H.264 or HEVC .mp4 or .mov first."
    }

    /// Converts the video to an H.264 / AAC .mp4 in a temporary folder (remove the folder when done with it).
    /// `progress` gets the share done (0…1).
    static func convert(_ url: URL, progress: @escaping (Double) -> Void) async throws -> URL {
        guard let ffmpeg else { throw Failure.noFFmpeg }
        let asset = AVURLAsset(url: url)
        let duration = (try? await asset.load(.duration).seconds).flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        // Keep about the original's quality: its bit rate, with some room for H.264 being less efficient than VP9 / AV1.
        let rate = (try? await asset.loadTracks(withMediaType: .video).first?.load(.estimatedDataRate)).flatMap { $0 } ?? 0
        let kbps = max(2_000, min(20_000, Int(Double(rate) * 1.5 / 1000)))
        let folder = FileManager.default.temporaryDirectory.appending(path: "MxNoteONE-convert-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let out = folder.appending(path: url.deletingPathExtension().lastPathComponent + ".mp4")
        // The Mac's hardware encoder first; the software one (libx264) if that isn't there.
        let encoders: [[String]] = [["-c:v", "h264_videotoolbox", "-b:v", "\(kbps)k", "-allow_sw", "1"],
                                    ["-c:v", "libx264", "-crf", "20", "-preset", "veryfast"]]
        var lastError = ""
        for encoder in encoders {
            try Task.checkCancellation()
            let args = ["-nostdin", "-y", "-hide_banner", "-loglevel", "error", "-i", url.path,
                        "-map", "0:v:0", "-map", "0:a:0?"] + encoder
                + ["-pix_fmt", "yuv420p", "-tag:v", "avc1", "-c:a", "aac", "-b:a", "160k",
                   "-movflags", "+faststart", "-progress", "pipe:1", "-nostats", out.path]
            let (status, errors) = try await run(ffmpeg, args) { line in
                // "out_time_us=12345678"
                guard let duration, line.hasPrefix("out_time_us="), let us = Double(line.dropFirst(12)) else { return }
                progress(min(1, max(0, us / 1_000_000 / duration)))
            }
            if status == 0, FileManager.default.fileExists(atPath: out.path) { return out }
            lastError = errors.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines).last ?? ""
        }
        try? FileManager.default.removeItem(at: folder)
        throw Failure.failed(lastError)
    }

    /// Runs a tool, handing each line it writes to `onLine`; returns its exit status and error output. Stopped if
    /// the task is cancelled.
    private static func run(_ tool: URL, _ args: [String], onLine: @escaping (String) -> Void) async throws -> (Int32, String) {
        let process = Process()
        process.executableURL = tool
        process.arguments = args
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        // The handler runs on one queue at a time; the part line waits here for the rest of it.
        nonisolated final class Pending: @unchecked Sendable { var text = "" }
        let pending = Pending()
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            let lines = (pending.text + text).components(separatedBy: "\n")
            pending.text = lines.last ?? ""
            for line in lines.dropLast() {
                DispatchQueue.main.async { onLine(line) }
            }
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (done: CheckedContinuation<(Int32, String), Error>) in
                process.terminationHandler = { p in
                    output.fileHandleForReading.readabilityHandler = nil
                    let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    done.resume(returning: (p.terminationStatus, message))
                }
                do { try process.run() } catch { done.resume(throwing: error) }
            }
        } onCancel: {
            process.terminate()
        }
    }

    /// A playable video's shown size (turned as it plays) and a poster frame from early on.
    static func posterAndSize(_ url: URL) async -> (poster: CGImage?, size: CGSize) {
        let asset = AVURLAsset(url: url)
        var size = CGSize(width: 16, height: 9)
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let (natural, transform) = try? await track.load(.naturalSize, .preferredTransform) {
            let shown = natural.applying(transform)
            if abs(shown.width) > 0, abs(shown.height) > 0 { size = CGSize(width: abs(shown.width), height: abs(shown.height)) }
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1280, height: 1280)
        let seconds = (try? await asset.load(.duration).seconds).flatMap { $0.isFinite ? $0 : nil } ?? 0
        let poster = try? await generator.image(at: CMTime(seconds: min(1, seconds / 3), preferredTimescale: 600)).image
        return (poster, size)
    }
}
