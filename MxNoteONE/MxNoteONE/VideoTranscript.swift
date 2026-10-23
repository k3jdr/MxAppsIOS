//
//  VideoTranscript.swift
//  MxNoteONE
//
//  Transcripts and recaps of videos, as for a Teams meeting recording. A
//  video's sound is transcribed on this Mac (Speech: SpeechAnalyzer with
//  SpeechTranscriber) into a text box under the video, a paragraph per
//  stretch of speech with its time; clicking a time plays the video from
//  there. Apple Intelligence (FoundationModels, on this Mac) then writes a
//  recap of the transcript: an overview, key points, action items as To Do
//  tags, and chapters. When its safety filter blocks the structured recap
//  (finance lessons trip it: "speculating", "buy a put"), it's written again
//  as plain text with the filter Apple provides for transforming the user's
//  own text (permissiveContentTransformations), and read back. The transcript is also kept with the video, so a
//  recap can be made after the text box was edited or deleted.
//

import AppKit
import AVFoundation
import FoundationModels
import Speech

// MARK: - Speech to text

enum VideoTranscriber {
    struct Transcription {
        var segments: [TranscriptSegment]
        var locale: Locale
        var duration: Double
    }

    enum Failure: LocalizedError {
        case noSound, noSpeech, language(String), export

        var errorDescription: String? {
            switch self {
            case .noSound: "The video has no sound to transcribe."
            case .noSpeech: "No speech was heard in the video."
            case .language(let name): "Transcription isn't available for \(name) on this Mac."
            case .export: "Couldn't read the video's sound."
            }
        }
    }

    /// The language transcribed: the Mac's own when the transcriber has it, else US English.
    static func locale() async throws -> Locale {
        if let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) { return locale }
        if let english = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en_US")) { return english }
        throw Failure.language(Locale.current.localizedString(forIdentifier: Locale.current.identifier) ?? Locale.current.identifier)
    }

    /// Transcribes a video's sound; `progress` gets the share done (0…1) and what's happening.
    static func transcribe(_ url: URL, progress: @escaping (Double, String) -> Void) async throws -> Transcription {
        let asset = AVURLAsset(url: url)
        guard try await !asset.loadTracks(withMediaType: .audio).isEmpty else { throw Failure.noSound }
        let locale = try await locale()
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
        // The speech model for the language, downloaded the first time.
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            progress(0, "Downloading the speech model…")
            try await request.downloadAndInstall()
        }
        progress(0, "Reading the sound…")
        let audioURL = FileManager.default.temporaryDirectory.appending(path: "MxNoteONE-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: audioURL) }
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else { throw Failure.export }
        try await export.export(to: audioURL, as: .m4a)
        let file = try AVAudioFile(forReading: audioURL)
        let duration = Double(file.length) / file.fileFormat.sampleRate
        progress(0, "Transcribing…")

        let collector = Task { () -> [TranscriptSegment] in
            var segments: [TranscriptSegment] = []
            for try await result in transcriber.results {
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let start = result.range.start.seconds, end = result.range.end.seconds
                segments.append(TranscriptSegment(start: start.isFinite ? start : 0, end: end.isFinite ? end : start, text: text))
                if duration > 0, end.isFinite { progress(min(1, end / duration), "Transcribing…") }
            }
            return segments
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        do {
            try await withTaskCancellationHandler {
                if let last = try await analyzer.analyzeSequence(from: file) {
                    try await analyzer.finalizeAndFinish(through: last)
                } else {
                    await analyzer.cancelAndFinishNow()
                }
            } onCancel: {
                Task { await analyzer.cancelAndFinishNow() }
            }
        } catch {
            collector.cancel()
            throw error
        }
        let segments = try await collector.value
        try Task.checkCancellation()
        guard !segments.isEmpty else { throw Failure.noSpeech }
        return Transcription(segments: segments.sorted { $0.start < $1.start }, locale: locale, duration: duration)
    }

    /// Phrases joined into paragraphs, as Teams shows them: a new one after a pause or every half minute or so.
    static func paragraphs(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        var out: [TranscriptSegment] = []
        for s in segments {
            if var last = out.last, s.start - last.end < 1.0, s.end - last.start < 30 {
                last.text += " " + s.text
                last.end = max(last.end, s.end)
                out[out.count - 1] = last
            } else {
                out.append(s)
            }
        }
        return out
    }
}

// MARK: - Recap (Apple Intelligence)

/// A recap as the page shows it (from the structured answer, or read from the plain-text one).
struct VideoRecapNotes {
    var overview: String
    var keyPoints: [String]
    var actionItems: [String]
    /// (time mark "m:ss", title)
    var chapters: [(start: String, title: String)]
}

@Generable
struct VideoRecap {
    @Guide(description: "Two to four sentences: what the recording is about, and what was decided or concluded.")
    var overview: String
    @Guide(description: "The main points, each a short sentence.", .maximumCount(8))
    var keyPoints: [String]
    @Guide(description: "Follow-up tasks: every time someone says a person will do something (\"Maria will write…\", \"I'll send…\"), one item each, starting with who will do it and including when, if said. Empty only when nobody commits to anything.", .maximumCount(8))
    var actionItems: [String]
    @Guide(description: "Where each main topic starts, in order.", .maximumCount(8))
    var chapters: [VideoChapter]
}

@Generable
struct VideoChapter {
    @Guide(description: "The time mark where the topic starts, copied from the transcript's [m:ss] marks, like 4:05.")
    var start: String
    @Guide(description: "A short title for the topic, a few words.")
    var title: String
}

enum VideoRecapper {
    enum Failure: LocalizedError {
        case unavailable(String)

        var errorDescription: String? {
            if case .unavailable(let why) = self { return why }
            return nil
        }
    }

    /// Why Apple Intelligence can't write a recap here (nil when it can).
    static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(.deviceNotEligible):
            return "This Mac can't run Apple Intelligence, which writes the recap."
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Turn on Apple Intelligence in System Settings ▸ Apple Intelligence & Siri to get recaps."
        case .unavailable(.modelNotReady):
            return "Apple Intelligence is still getting its model ready. Try again in a little while."
        case .unavailable:
            return "Apple Intelligence isn't available right now."
        }
    }

    static let instructions = """
        You write notes from the transcript of a recording — a meeting, a lesson, a talk or a video — like the \
        recap after a Teams meeting. You only summarize what the speakers said; you don't give advice of your own. \
        Use only what the transcript says; don't invent names, numbers or decisions. Write in the transcript's language.
        """

    /// For summarizing the user's own text: Apple's filter for content transformations (plain-text answers only).
    static let transformingModel = SystemLanguageModel(guardrails: .permissiveContentTransformations)

    /// The safety filter (or the model) declined. macOS 27 reports it as LanguageModelError, macOS 26 as GenerationError.
    static func isBlocked(_ error: Error) -> Bool {
        if #available(macOS 27, *) {
            switch error {
            case LanguageModelError.guardrailViolation, LanguageModelError.refusal: return true
            default: break
            }
        }
        switch error {
        case LanguageModelSession.GenerationError.guardrailViolation, LanguageModelSession.GenerationError.refusal: return true
        default: return false
        }
    }

    /// The text was too long for the model's context.
    static func isTooLong(_ error: Error) -> Bool {
        if #available(macOS 27, *), case LanguageModelError.contextSizeExceeded = error { return true }
        if case LanguageModelSession.GenerationError.exceededContextWindowSize = error { return true }
        return false
    }

    /// The same recap each time for the same transcript.
    static let options = GenerationOptions(samplingMode: .greedy)

    /// Transcript lines as the model reads them: "[m:ss] words", phrase by phrase (so topics get their own times).
    static func lines(_ segments: [TranscriptSegment]) -> [String] {
        segments.map { "[\(VideoControlBar.clock($0.start))] \($0.text)" }
    }

    /// Lines grouped into parts small enough for the model's context.
    static func chunks(_ lines: [String], budget: Int) -> [String] {
        var parts: [String] = [], current = ""
        for line in lines {
            if !current.isEmpty, current.count + line.count + 1 > budget {
                parts.append(current)
                current = ""
            }
            current += (current.isEmpty ? "" : "\n") + (line.count > budget ? String(line.prefix(budget)) : line)
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    /// A recap of the transcript. Long transcripts are first turned into notes part by part (keeping the time marks).
    static func recap(_ segments: [TranscriptSegment], progress: @escaping (String) -> Void) async throws -> VideoRecapNotes {
        if let why = unavailableReason { throw Failure.unavailable(why) }
        var budget = 7000
        while true {
            do {
                var text = lines(segments)
                var parts = chunks(text, budget: budget)
                var round = 0
                while parts.count > 1 {
                    round += 1
                    var notes: [String] = []
                    for (i, part) in parts.enumerated() {
                        try Task.checkCancellation()
                        progress("Summarizing part \(i + 1) of \(parts.count)…")
                        let session = LanguageModelSession(model: transformingModel, instructions: instructions)
                        let reply = try await session.respond(to: """
                            Write short notes on this part of the transcript: the points made, decisions, \
                            follow-up tasks (with who will do them, when said), and each new topic with its [m:ss] mark.

                            \(part)
                            """, options: options)
                        notes.append(reply.content)
                    }
                    text = notes
                    parts = chunks(text, budget: budget)
                    if round > 3 { parts = [String(parts.joined(separator: "\n").prefix(budget))] }
                }
                try Task.checkCancellation()
                progress("Writing the recap…")
                let source = parts.first ?? ""
                do {
                    let session = LanguageModelSession(instructions: instructions)
                    let reply = try await session.respond(to: """
                        Write the recap of this recording from its transcript\(round > 0 ? " (given as notes)" : ""). \
                        The [m:ss] marks are times in the recording.

                        \(source)
                        """, generating: VideoRecap.self, includeSchemaInPrompt: true, options: options)
                    let r = reply.content
                    return VideoRecapNotes(overview: r.overview, keyPoints: r.keyPoints, actionItems: r.actionItems,
                                           chapters: r.chapters.map { ($0.start, $0.title) })
                } catch where isBlocked(error) {
                    // The filter blocked the structured answer: write it as text with the transformation filter.
                    try Task.checkCancellation()
                    return try await plainRecap(source, fromNotes: round > 0)
                }
            } catch where isTooLong(error) && budget > 1500 {
                budget /= 2
            }
        }
    }

    /// The recap as plain text in set sections, read back into notes.
    static func plainRecap(_ source: String, fromNotes: Bool) async throws -> VideoRecapNotes {
        let session = LanguageModelSession(model: transformingModel, instructions: instructions)
        let reply = try await session.respond(to: """
            Summarize this transcript\(fromNotes ? " (given as notes)" : "") of a recording. The [m:ss] marks are times \
            in the recording. Answer in exactly this form, with these four headings and nothing else:

            OVERVIEW:
            two to four sentences on what the recording is about and what was concluded
            KEY POINTS:
            - one short sentence per main point (at most 8)
            ACTION ITEMS:
            - each follow-up task someone said would be done, starting with who (write "- none" if there are none)
            CHAPTERS:
            - the [m:ss] mark from the transcript where a main topic starts, then a short title, like "- 0:25 How it's calculated" (at most 8)

            \(source)
            """, options: options)
        return parsePlainRecap(reply.content)
    }

    static func parsePlainRecap(_ text: String) -> VideoRecapNotes {
        var notes = VideoRecapNotes(overview: "", keyPoints: [], actionItems: [], chapters: [])
        var section = ""
        for raw in text.components(separatedBy: .newlines) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            let heading = line.uppercased().replacingOccurrences(of: "*", with: "").replacingOccurrences(of: "#", with: "")
                .trimmingCharacters(in: .whitespaces)
            if let name = ["OVERVIEW", "KEY POINTS", "ACTION ITEMS", "CHAPTERS"].first(where: { heading.hasPrefix($0) }) {
                section = name
                line = String(line.drop { $0 != ":" }.dropFirst()).trimmingCharacters(in: .whitespaces)
                if line.isEmpty { continue }
            }
            let item = line.hasPrefix("-") || line.hasPrefix("•") || line.hasPrefix("*")
                ? String(line.dropFirst()).trimmingCharacters(in: .whitespaces) : line
            guard !item.isEmpty else { continue }
            switch section {
            case "OVERVIEW": notes.overview += (notes.overview.isEmpty ? "" : " ") + item
            case "KEY POINTS": notes.keyPoints.append(item)
            case "ACTION ITEMS": if !["none", "none.", "n/a"].contains(item.lowercased()) { notes.actionItems.append(item) }
            case "CHAPTERS":
                // "4:05 Title", "[4:05] Title" or "4:05 - Title".
                let mark = item.prefix { "0123456789:[]".contains($0) }
                let title = item.dropFirst(mark.count).trimmingCharacters(in: CharacterSet(charactersIn: " -–—:"))
                // A chapter without a time is listed without one (no guessing).
                if !title.isEmpty { notes.chapters.append((seconds(String(mark)) != nil ? String(mark) : "", title)) }
            default: break
            }
        }
        return notes
    }

    /// "4:05" or "1:02:03" → seconds.
    static func seconds(_ mark: String) -> Double? {
        let parts = mark.trimmingCharacters(in: CharacterSet(charactersIn: "[] ")).split(separator: ":").map { Double($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        return parts.compactMap { $0 }.reduce(0) { $0 * 60 + $1 }
    }
}

// MARK: - The text on the page

enum VideoTranscriptText {
    /// Links on transcript times: mxnoteone-video://seek/<video element id>?t=<seconds>.
    static let linkScheme = "mxnoteone-video"

    static func link(_ element: UUID, _ seconds: Double) -> URL {
        URL(string: "\(linkScheme)://seek/\(element.uuidString)?t=\(String(format: "%.2f", seconds))")!
    }

    /// The video and moment a transcript link goes to.
    static func target(_ url: URL) -> (element: UUID, seconds: Double)? {
        guard url.scheme == linkScheme, let id = url.pathComponents.last.flatMap(UUID.init(uuidString:)),
              let t = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "t" })?.value,
              let seconds = Double(t) else { return nil }
        return (id, seconds)
    }

    /// Plays the video on the page from the link's moment.
    @discardableResult
    static func follow(_ url: URL) -> Bool {
        guard let (id, seconds) = target(url) else { return false }
        guard let video = NotebookStore.shared.canvas?.canvas.elementViews
            .compactMap({ $0 as? VideoElementView }).first(where: { $0.element.id == id }) else {
            NotebookStore.shared.showAlert("The video isn't on this page", "The transcript's times play the video on the page it was transcribed on.")
            return true
        }
        video.play(from: seconds)
        return true
    }

    private static var gray: NSColor { NSColor(white: 0.45, alpha: 1) }

    private static func line(_ string: String, _ attrs: [NSAttributedString.Key: Any]) -> NSAttributedString {
        NSAttributedString(string: string + "\n", attributes: attrs)
    }

    private static func small(_ base: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
        var attrs = base
        let font = (base[.font] as? NSFont) ?? NSFont.systemFont(ofSize: 12)
        attrs[.font] = NSFontManager.shared.convert(font, toSize: max(9, font.pointSize - 1))
        attrs[.foregroundColor] = gray
        return attrs
    }

    /// Transcript: a heading, what it is, then a paragraph per stretch of speech with its time (a link that plays from there).
    static func transcript(_ t: VideoTranscriber.Transcription, video: PageElement) -> NSAttributedString {
        let base = TextFormatter.defaultAttributes
        let out = NSMutableAttributedString()
        out.append(line("Transcript — \(video.fileName ?? "Video")", TextStyleKind.heading2.attributes))
        let language = Locale.current.localizedString(forIdentifier: t.locale.identifier) ?? t.locale.identifier
        out.append(line("\(VideoControlBar.clock(t.duration)) · \(language) · transcribed on this Mac \(Date().formatted(date: .abbreviated, time: .shortened)). Click a time to play the video from there.", small(base)))
        let font = (base[.font] as? NSFont) ?? NSFont.systemFont(ofSize: 12)
        for p in VideoTranscriber.paragraphs(t.segments) {
            var timeAttrs = small(base)
            timeAttrs[.font] = NSFontManager.shared.convert(NSFontManager.shared.convert(font, toSize: max(9, font.pointSize - 1)), toHaveTrait: .boldFontMask)
            timeAttrs[.link] = link(video.id, p.start)
            out.append(NSAttributedString(string: VideoControlBar.clock(p.start), attributes: timeAttrs))
            out.append(NSAttributedString(string: "   " + p.text + "\n", attributes: base))
        }
        trimLastNewline(out)
        return out
    }

    /// Recap: overview, key points, action items (To Do tags) and chapters (times that play the video).
    static func recap(_ r: VideoRecapNotes, video: PageElement, duration: Double?) -> NSAttributedString {
        let base = TextFormatter.defaultAttributes
        let heading = TextStyleKind.heading3.attributes
        let out = NSMutableAttributedString()
        out.append(line("Recap — \(video.fileName ?? "Video")", TextStyleKind.heading2.attributes))
        out.append(line("Written by Apple Intelligence on this Mac from the transcript, \(Date().formatted(date: .abbreviated, time: .shortened)). Check it against the transcript.", small(base)))
        out.append(line("Overview", heading))
        out.append(line(r.overview.trimmingCharacters(in: .whitespacesAndNewlines), base))
        let points = r.keyPoints.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if !points.isEmpty {
            out.append(line("Key points", heading))
            for p in points { out.append(line(TextFormatter.bullet + p, base)) }
        }
        let tasks = r.actionItems.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        out.append(line("Action items", heading))
        if tasks.isEmpty {
            out.append(line("None mentioned.", small(base)))
        } else {
            for t in tasks { out.append(line(TagKind.todo.symbol + " " + t, base)) }
        }
        // Chapters with a time (a link that plays from there) in time order; any without one keep their place after.
        let chapters = r.chapters.compactMap { c -> (Double?, String)? in
            let title = c.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            guard !c.start.isEmpty else { return (nil, title) }
            guard let s = VideoRecapper.seconds(c.start), s >= 0, s <= (duration ?? .greatestFiniteMagnitude) + 1 else { return nil }
            return (s, title)
        }.enumerated().sorted { ($0.element.0 ?? .greatestFiniteMagnitude, $0.offset) < ($1.element.0 ?? .greatestFiniteMagnitude, $1.offset) }
            .map(\.element)
        if !chapters.isEmpty {
            out.append(line("Chapters", heading))
            for (s, title) in chapters {
                if let s {
                    var timeAttrs = small(base)
                    timeAttrs[.link] = link(video.id, s)
                    out.append(NSAttributedString(string: VideoControlBar.clock(s), attributes: timeAttrs))
                    out.append(line("   " + title, base))
                } else {
                    out.append(line(TextFormatter.bullet + title, base))
                }
            }
        }
        trimLastNewline(out)
        return out
    }

    private static func trimLastNewline(_ s: NSMutableAttributedString) {
        if s.string.hasSuffix("\n") { s.deleteCharacters(in: NSRange(location: s.length - 1, length: 1)) }
    }
}
