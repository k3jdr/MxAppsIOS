//
//  FileHost.swift
//  MxFileMGR
//
//  The machine a file lives on, so Delete and ffmpeg run there instead of
//  pulling the file across the network. A file on an SMB or NFS mount belongs
//  to the mount's server; anything else (local disks, WebDAV, …) is this Mac.
//
//  Commands reach the server over ssh, signed in the way ssh would (keys,
//  ssh-agent, ~/.ssh/config) and never prompting (BatchMode). The SSH target
//  is the ~/.ssh/config alias whose HostName is the mount's server, else
//  user@server with the mount's user. The share's folder on the server comes
//  from the server itself:
//
//      Windows  Get-SmbShare (or Win32_Share), run through
//               powershell -NoProfile -EncodedCommand <UTF-16LE base64>,
//               which works whether sshd's shell is cmd or PowerShell
//      POSIX    testparm (Samba) or sharing -l (macOS File Sharing), run in sh -c
//
//  so //calla@192.168.0.223/MyDataMAC/Videos/a.mp4 is D:\MyDataMAC\Videos\a.mp4
//  on k3jdr-dsktop-11. Hosts and shares are looked up once per run.
//

import Foundation
import os

/// A server reachable over ssh.
nonisolated struct RemoteHost: Hashable, Sendable {
    enum OS: Sendable { case windows, posix }

    /// The server as mounted (address or name).
    let server: String
    /// What ssh connects to: a ~/.ssh/config alias, or user@server.
    let sshTarget: String
    let os: OS

    /// Name shown in confirmations and job titles.
    var name: String { sshTarget.contains("@") ? server : sshTarget }

    // MARK: Paths

    func join(_ base: String, _ components: [String]) -> String {
        guard !components.isEmpty else { return base }
        let sep = os == .windows ? "\\" : "/"
        let trimmed = base.hasSuffix(sep) ? String(base.dropLast()) : base
        return ([trimmed] + components).joined(separator: sep)
    }

    func parent(_ path: String) -> String {
        let sep: Character = os == .windows ? "\\" : "/"
        guard let i = path.lastIndex(of: sep) else { return path }
        let head = String(path[..<i])
        return head.isEmpty || head.hasSuffix(":") ? head + String(sep) : head
    }

    // MARK: Scripts

    /// A literal string in this host's script language.
    func quote(_ s: String) -> String {
        switch os {
        case .windows:
            // PowerShell also ends single-quoted strings at typographic quotes; doubling escapes either kind.
            var out = "'"
            for c in s { out.append(c); if "'‘’‚‛".contains(c) { out.append(c) } }
            return out + "'"
        case .posix:
            return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
    }

    /// The command line ssh runs for a script (PowerShell on Windows, sh elsewhere).
    func remoteCommand(_ script: String) -> String {
        switch os {
        case .windows:
            let full = "$ProgressPreference='SilentlyContinue'; [Console]::OutputEncoding=[Text.Encoding]::UTF8\n"
                + "try {\n\(script)\n} catch { [Console]::Error.WriteLine($_.Exception.Message); exit 1 }"
            return "powershell -NoProfile -NonInteractive -EncodedCommand " + Self.encoded(full)
        case .posix:
            // Homebrew isn't on PATH in a non-interactive ssh session to a Mac.
            let full = "PATH=\"$PATH:/opt/homebrew/bin:/usr/local/bin\"; export PATH\n" + script
            return "sh -c " + quote(full)
        }
    }

    /// Script lines that run `tool` (looked up on PATH) with `args`, passing stdout and stderr through and
    /// exiting with its status; exit 127 with a clear message when the host doesn't have it.
    func toolScript(_ tool: String, _ args: [String]) -> String {
        let missing = "\(tool) isn't installed on \(name)."
        switch os {
        case .windows:
            // Started through Process with a command line built here: PowerShell 5.1 drops empty arguments and
            // mangles embedded double quotes when it calls a program itself.
            return """
            $c = Get-Command \(quote(tool)) -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $c) { [Console]::Error.WriteLine(\(quote(missing))); exit 127 }
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $c.Source
            $psi.Arguments = \(quote(Self.windowsCommandLine(args)))
            $psi.UseShellExecute = $false
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
            $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
            $p = [System.Diagnostics.Process]::Start($psi)
            $err = $p.StandardError.ReadToEndAsync()
            while ($null -ne ($line = $p.StandardOutput.ReadLine())) { [Console]::Out.WriteLine($line); [Console]::Out.Flush() }
            $p.WaitForExit()
            [Console]::Error.Write($err.Result)
            exit $p.ExitCode
            """
        case .posix:
            return "command -v \(quote(tool)) >/dev/null 2>&1 || { echo \(quote(missing)) >&2; exit 127; }\n"
                + "exec " + ([tool] + args).map(quote).joined(separator: " ")
        }
    }

    // MARK: Running

    static let sshPath = "/usr/bin/ssh"

    func sshArguments(_ script: String) -> [String] {
        Self.sshOptions + [sshTarget, remoteCommand(script)]
    }

    /// Runs a script on the host and returns its stdout; throws with its stderr when it fails.
    func run(_ script: String) async throws -> String {
        let data = try await CLITool.run(Self.sshPath, sshArguments(script), environment: CLITool.environment())
        return String(decoding: data, as: UTF8.self)
    }

    /// Runs a script on the host inside a TransferManager job (see CLITool.runJob).
    @discardableResult
    func runJob(_ script: String, reporter: ProgressReporter, onLine: (@Sendable (String) -> Void)? = nil) -> Bool {
        CLITool.runJob(Self.sshPath, sshArguments(script), environment: CLITool.environment(), reporter: reporter, onLine: onLine)
    }

    static let sshOptions = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
                             "-o", "StrictHostKeyChecking=accept-new", "-o", "ServerAliveInterval=15"]

    static func encoded(_ script: String) -> String {
        var data = Data()
        for unit in script.utf16 { data.append(UInt8(unit & 0xFF)); data.append(UInt8(unit >> 8)) }
        return data.base64EncodedString()
    }

    /// Quotes arguments the way Windows programs split their command line (CommandLineToArgvW).
    static func windowsCommandLine(_ args: [String]) -> String {
        args.map { arg in
            if !arg.isEmpty, !arg.contains(where: { " \t\n\"".contains($0) }) { return arg }
            var out = "\"", slashes = 0
            for c in arg {
                if c == "\\" { slashes += 1; continue }
                if c == "\"" { out += String(repeating: "\\", count: slashes * 2 + 1) + "\"" }
                else { out += String(repeating: "\\", count: slashes) + String(c) }
                slashes = 0
            }
            return out + String(repeating: "\\", count: slashes * 2) + "\""
        }.joined(separator: " ")
    }
}

/// Where a file is: on this Mac (`host` nil, `path` its local path) or at `path` on a remote host.
nonisolated struct FileLocation: Sendable {
    let url: URL
    let host: RemoteHost?
    let path: String

    var isRemote: Bool { host != nil }
    var hostName: String { host?.name ?? "this Mac" }
}

nonisolated enum FileHosts {
    /// A network mount with a server that may run commands for us.
    struct Mount: Sendable {
        enum Kind: Sendable { case smb, nfs }
        let kind: Kind
        let server: String
        let user: String
        /// SMB: the share name (plus any folder mounted inside it). NFS: the exported path.
        let share: String
        let subpath: [String]
        let mountPoint: String
    }

    private static let hosts = OSAllocatedUnfairLock(initialState: [String: RemoteHost]())
    private static let shares = OSAllocatedUnfairLock(initialState: [String: String]())

    /// The mount `url` is on, when it's SMB or NFS.
    static func mount(of url: URL) -> Mount? {
        var fs = statfs()
        guard statfs(url.path, &fs) == 0 else { return nil }
        let type = withUnsafeBytes(of: fs.f_fstypename) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let from = withUnsafeBytes(of: fs.f_mntfromname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let on = withUnsafeBytes(of: fs.f_mntonname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        switch type {
        case "smbfs":
            // //[domain;]user[:pw]@server/share[/folder] (percent-encoded)
            guard from.hasPrefix("//") else { return nil }
            var rest = Substring(from.dropFirst(2)), user = ""
            if let at = rest.firstIndex(of: "@") {
                user = String(rest[..<at])
                if let semi = user.firstIndex(of: ";") { user = String(user[user.index(after: semi)...]) }
                if let colon = user.firstIndex(of: ":") { user = String(user[..<colon]) }
                rest = rest[rest.index(after: at)...]
            }
            let parts = rest.split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
            guard parts.count >= 2 else { return nil }
            var server = parts[0]
            if let colon = server.lastIndex(of: ":"), !server.contains("]") { server = String(server[..<colon]) }  // port
            return Mount(kind: .smb, server: server, user: user.removingPercentEncoding ?? user,
                         share: parts[1], subpath: Array(parts.dropFirst(2)), mountPoint: on)
        case "nfs":
            guard let colon = from.firstIndex(of: ":") else { return nil }
            return Mount(kind: .nfs, server: String(from[..<colon]), user: "",
                         share: String(from[from.index(after: colon)...]), subpath: [], mountPoint: on)
        default:
            return nil
        }
    }

    /// Where `url` is. Throws when it's on a network mount whose server can't be reached over ssh.
    static func locate(_ url: URL) async throws -> FileLocation {
        let url = url.standardizedFileURL
        guard let mount = mount(of: url) else { return FileLocation(url: url, host: nil, path: url.path) }
        let host = try await host(for: mount)
        let base = try await sharePath(mount, on: host)
        let mountComponents = URL(fileURLWithPath: mount.mountPoint).standardizedFileURL.pathComponents
        let relative = Array(url.pathComponents.dropFirst(mountComponents.count))
        return FileLocation(url: url, host: host, path: host.join(base, mount.subpath + relative))
    }

    /// The ssh alias for a server: the ~/.ssh/config Host whose HostName (or name) is the server.
    private static func sshTarget(for mount: Mount) async -> String {
        let server = mount.server.lowercased()
        let bare = server.hasSuffix(".local") ? String(server.dropLast(6)) : server
        for alias in SFTPCLI.configHosts {
            if alias.lowercased() == server || alias.lowercased() == bare { return alias }
            guard let data = try? await CLITool.run(RemoteHost.sshPath, ["-G", alias], environment: CLITool.environment())
            else { continue }
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n") where line.hasPrefix("hostname ") {
                let name = line.dropFirst("hostname ".count).lowercased()
                if name == server || name == bare { return alias }
            }
        }
        return mount.user.isEmpty ? mount.server : "\(mount.user)@\(mount.server)"
    }

    static func host(for mount: Mount) async throws -> RemoteHost {
        if let known = hosts.withLock({ $0[mount.server.lowercased()] }) { return known }
        let target = await sshTarget(for: mount)
        let probe = RemoteHost(server: mount.server, sshTarget: target, os: .windows)
        let os: RemoteHost.OS
        do {
            // PowerShell answers on Windows; elsewhere `powershell` is missing (or isn't Windows PowerShell).
            let out = try await probe.run("Write-Output ('mx' + 'win:' + $env:OS)")
            os = out.contains("mxwin:Windows_NT") ? .windows : .posix
        } catch {
            let posix = RemoteHost(server: mount.server, sshTarget: target, os: .posix)
            do {
                _ = try await posix.run("uname -s")
            } catch {
                let reason = (error as? CLIToolError)?.message ?? error.localizedDescription
                throw CLIToolError(message: "Can't run commands on \(mount.server) over ssh (\(target)): \(reason)")
            }
            os = .posix
        }
        let host = RemoteHost(server: mount.server, sshTarget: target, os: os)
        hosts.withLock { $0[mount.server.lowercased()] = host }
        return host
    }

    /// The folder on the host that the share (SMB) or export (NFS) is.
    private static func sharePath(_ mount: Mount, on host: RemoteHost) async throws -> String {
        if mount.kind == .nfs { return mount.share }
        let key = "\(mount.server.lowercased())/\(mount.share.lowercased())"
        if let known = shares.withLock({ $0[key] }) { return known }
        let name = host.quote(mount.share)
        let script: String
        switch host.os {
        case .windows:
            script = """
            $s = Get-SmbShare -Name \(name) -ErrorAction SilentlyContinue
            if ($s) { $s.Path } else { (Get-CimInstance Win32_Share | Where-Object Name -eq \(name)).Path }
            """
        case .posix:
            script = """
            p=$(testparm -s --section-name=\(name) --parameter-name=path 2>/dev/null)
            [ -n "$p" ] || p=$(sharing -l 2>/dev/null | awk -v s=\(name) '/^name:/{sub(/^name:[ \\t]*/,""); n=$0} /^path:/{sub(/^path:[ \\t]*/,""); if (n==s) {print; exit}}')
            printf '%s\\n' "$p"
            """
        }
        let path = try await host.run(script).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, !path.contains("\n") else {
            throw CLIToolError(message: "\(host.name) doesn't say which folder its share “\(mount.share)” is.")
        }
        shares.withLock { $0[key] = path }
        return path
    }
}

/// One item for TransferManager.deleteRemote: its path on the host and what the file list showed.
nonisolated struct RemoteDeleteTarget: Sendable {
    let path: String
    let name: String
    let isFolder: Bool
    let isSymlink: Bool
    let size: Int64

    /// Deletes each item after checking it's still what the list showed; prints "ok<TAB>i" or "err<TAB>i<TAB>why".
    /// A link (symlink, junction) is removed itself, never what it points to.
    static func script(_ items: [(Int, RemoteDeleteTarget)], on host: RemoteHost) -> String {
        let mismatch = "it isn't the item shown in the list any more, so it was left alone"
        switch host.os {
        case .windows:
            var lines = ["""
            function Remove-MxItem($i, $p, $dir, $link, $size) {
              try {
                $item = Get-Item -LiteralPath $p -Force -ErrorAction Stop
                $isLink = [bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)
                if ($item.PSIsContainer -ne $dir -or (-not $dir -and -not $link -and -not $isLink -and $item.Length -ne $size)) {
                  "err`t$i`t\(mismatch)"; return
                }
                if ($isLink -and $item.PSIsContainer) { [IO.Directory]::Delete($p, $false) }
                else { Remove-Item -LiteralPath $p -Recurse:$dir -Force -ErrorAction Stop }
                "ok`t$i"
              } catch { "err`t$i`t$($_.Exception.Message)" }
            }
            """]
            for (i, t) in items {
                lines.append("Remove-MxItem \(i) \(host.quote(t.path)) $\(t.isFolder) $\(t.isSymlink) \(t.size)")
            }
            return lines.joined(separator: "\n")
        case .posix:
            var lines = ["""
            del() {
              i=$1 p=$2
              if [ -L "$p" ]; then :
              elif [ "$3" = d ]; then [ -d "$p" ] || { printf 'err\\t%s\\t%s\\n' "$i" \(host.quote(mismatch)); return; }
              elif [ "$4" = 0 ]; then
                [ -f "$p" ] && [ "$(wc -c < "$p" | tr -d ' ')" = "$5" ] || { printf 'err\\t%s\\t%s\\n' "$i" \(host.quote(mismatch)); return; }
              fi
              if out=$(rm -rf -- "$p" 2>&1); then printf 'ok\\t%s\\n' "$i"; else printf 'err\\t%s\\t%s\\n' "$i" "$out" | head -1; fi
            }
            """]
            for (i, t) in items {
                lines.append("del \(i) \(host.quote(t.path)) \(t.isFolder ? "d" : "f") \(t.isSymlink ? 1 : 0) \(t.size)")
            }
            return lines.joined(separator: "\n")
        }
    }
}
