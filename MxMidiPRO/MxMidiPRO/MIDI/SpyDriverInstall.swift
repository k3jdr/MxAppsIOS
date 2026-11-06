//
//  SpyDriverInstall.swift — MxMidiPRO
//
//  The spy driver ships inside the app (Contents/PlugIns/MxMidiPRO Spy.plugin) and is installed per user in
//  ~/Library/Audio/MIDI Drivers, one of the folders the MIDI server loads drivers from — no administrator password.
//  The server only loads drivers when it starts, so a new or updated driver needs the server restarted once.
//

import AppKit
import Security

enum SpyDriverInstall {
    static let bundleName = "MxMidiPRO Spy.plugin"

    static var embedded: URL? {
        Bundle.main.builtInPlugInsURL?.appendingPathComponent(bundleName, isDirectory: true)
    }

    static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Audio/MIDI Drivers", isDirectory: true)
    }

    static var installed: URL { folder.appendingPathComponent(bundleName, isDirectory: true) }

    static var isInstalled: Bool { FileManager.default.fileExists(atPath: installed.path) }

    /// Whether the installed driver is the one this copy of the app carries: the same code directory hash. (Every
    /// build signs again, so the files' bytes differ even when the code doesn't.)
    static var isCurrent: Bool {
        guard let embedded, let a = codeHash(embedded), let b = codeHash(installed) else { return false }
        return a == b
    }

    private static func codeHash(_ bundle: URL) -> Data? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: 0), &info) == errSecSuccess,
              let values = info as? [String: Any] else { return nil }
        return values[kSecCodeInfoUnique as String] as? Data
    }

    enum Failure: LocalizedError {
        case notInApp
        case command(String)

        var errorDescription: String? {
            switch self {
            case .notInApp: "This copy of MxMidiPRO doesn't carry the spy driver (Contents/PlugIns is empty)."
            case .command(let text): text
            }
        }
    }

    static func install() throws {
        guard let embedded, FileManager.default.fileExists(atPath: embedded.path) else { throw Failure.notInApp }
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        if fm.fileExists(atPath: installed.path) { try fm.removeItem(at: installed) }
        try fm.copyItem(at: embedded, to: installed)
    }

    static func uninstall() throws {
        if FileManager.default.fileExists(atPath: installed.path) {
            try FileManager.default.removeItem(at: installed)
        }
    }

    /// Restarts the per-user MIDI server (launchd agent com.apple.midiserver) so it loads the driver. Every MIDI app
    /// loses its connections, so Logic Pro should be quit first.
    static func restartMIDIServer() throws {
        let service = "gui/\(getuid())/com.apple.midiserver"
        let (status, output) = run("/bin/launchctl", ["kickstart", "-k", service])
        if status == 0 { return }
        let (killStatus, killOutput) = run("/usr/bin/killall", ["MIDIServer"])
        if killStatus == 0 { return }
        throw Failure.command("Couldn't restart the MIDI server.\nlaunchctl: \(output)\nkillall: \(killOutput)")
    }

    /// Quits and reopens this copy of MxMidiPRO: a shell waits, then `open -n`s the bundle. The quit waits for the
    /// confirmation dialog to close (AppKit ignores a quit asked for from inside it); if it is still refused, the
    /// process exits — there is nothing to save.
    static func relaunchApp() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1.5; /usr/bin/open -n \"$1\"", "sh", Bundle.main.bundlePath]
        try? process.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { exit(0) }
    }

    private static func run(_ path: String, _ arguments: [String]) -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return (-1, error.localizedDescription)
        }
        let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (process.terminationStatus, text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
