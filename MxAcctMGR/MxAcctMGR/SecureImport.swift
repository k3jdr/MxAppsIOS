//
//  SecureImport.swift
//  MxAcctMGR
//
//  Secure Accounts ▸ Import Passwords and Keys…: reads a credentials worksheet from the workbook open in Microsoft Excel
//  (Apple Events — macOS asks once; an encrypted workbook can't be read from its file, and no CSV with passwords in
//  plain text is made) and puts each row's password and keys in this Mac's Keychain, under the secure account the row
//  names (made when there isn't one). Columns: A user ID, B password, C account description,
//  D notes, E keys. The account's name comes from the description as the accounts were seeded from it: a web address
//  without its scheme and "www." (and the address as the service URL), a license key or "(PIN …)" taken out of it (they
//  are keys: the product key), the user ID when there's no description, and " 2", " 3" … after a name already taken. A
//  user ID that is a token (an API key's id) is a key too: the service key, never the user name.
//

import AppKit
import Carbon
import SwiftUI

/// One worksheet row as an account to import: what it names, and which secrets it holds (never shown).
nonisolated struct SecureImportRow: Identifiable {
    var row: Int
    var name: String
    var user: String?
    var url: String?
    var notes: String?
    var password: String?
    /// The product key: column E, else a license key or PIN found in the description.
    var productKey: String?
    /// A token-like user ID (an API key's id).
    var serviceKey: String?
    var id: Int { row }

    static func rows(_ sheet: [[String: String]]) -> [SecureImportRow] {
        var out: [SecureImportRow] = [], taken = Set<String>()
        for (i, cells) in sheet.enumerated().dropFirst() {
            let trim = { (s: String?) in (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
            let user = trim(cells["A"]), password = trim(cells["B"]), notes = trim(cells["D"]), keys = trim(cells["E"])
            var desc = trim(cells["C"])
            var found: [String] = []
            for pattern in [#"\s*:?\s*\b([A-Z0-9]{5}(?:-[A-Z0-9]{5}){3,})\b"#, #"(?i)\s*\((PIN\s*\d+)\)"#] {
                let re = try! NSRegularExpression(pattern: pattern)
                for m in re.matches(in: desc, range: NSRange(desc.startIndex..., in: desc)) {
                    if let r = Range(m.range(at: 1), in: desc) { found.append(String(desc[r])) }
                }
                desc = re.stringByReplacingMatches(in: desc, range: NSRange(desc.startIndex..., in: desc), withTemplate: "")
            }
            desc = desc.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: " :"))
            var url: String?
            let first = String(desc.split(separator: " ", maxSplits: 1).first ?? "")
            let rest = desc.split(separator: " ", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
            if isWeb(desc) || (first.range(of: #"^https?://"#, options: [.regularExpression, .caseInsensitive]) != nil && isWeb(first)) {
                let address = isWeb(desc) ? desc : first
                url = address.range(of: #"^https?://"#, options: [.regularExpression, .caseInsensitive]) != nil ? address : "https://" + address
                var shown = address.replacingOccurrences(of: #"^https?://"#, with: "", options: [.regularExpression, .caseInsensitive])
                shown = shown.replacingOccurrences(of: #"^www\."#, with: "", options: [.regularExpression, .caseInsensitive])
                while shown.hasSuffix("/") { shown.removeLast() }
                desc = address == desc ? shown : shown + " " + rest
            }
            let secretUser = isToken(user)
            let base = desc.isEmpty ? (secretUser ? "" : user) : desc
            guard !base.isEmpty else { continue }
            var name = base, n = 1
            while taken.contains(name.lowercased()) { n += 1; name = "\(base) \(n)" }
            taken.insert(name.lowercased())
            out.append(SecureImportRow(row: i + 1, name: name, user: secretUser || user.isEmpty ? nil : user, url: url,
                                       notes: notes.isEmpty ? nil : notes, password: password.isEmpty ? nil : password,
                                       productKey: ([keys] + found).first { !$0.isEmpty }, serviceKey: secretUser ? user : nil))
        }
        return out
    }

    static func isWeb(_ s: String) -> Bool {
        s.range(of: #"^(https?://)?(www\.)?[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}(/\S*)?$"#, options: .regularExpression) != nil
    }

    /// A user ID that is an API key's id or a token rather than a user name.
    static func isToken(_ s: String) -> Bool {
        s.range(of: #"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#, options: .regularExpression) != nil
            || (s.range(of: #"^[A-Za-z0-9_\-]{24,}$"#, options: .regularExpression) != nil && !s.contains("@"))
    }
}

/// The workbooks open in Microsoft Excel and a worksheet's cells, read with Apple Events (macOS asks once whether
/// MxAcctMGR may control Excel: System Settings ▸ Privacy & Security ▸ Automation).
enum ExcelBridge {
    struct Failure: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    /// Each open workbook's name and its worksheets' names.
    static func workbooks() throws -> [(name: String, sheets: [String])] {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.microsoft.Excel").isEmpty else {
            throw Failure(message: "Microsoft Excel isn't open: open the workbook in Excel first.")
        }
        let list = try run("""
            tell application id "com.microsoft.Excel"
                set out to {}
                repeat with i from 1 to count of workbooks
                    set wb to workbook i
                    set end of out to {name of wb, name of every worksheet of wb}
                end repeat
                return out
            end tell
            """)
        return items(list).compactMap { pair in
            let p = items(pair)
            guard p.count == 2, let name = p[0].stringValue else { return nil }
            return (name, items(p[1]).compactMap(\.stringValue))
        }
    }

    /// A worksheet's columns A–E, row by row from the first, each cell's text by its column letter (empty ones left out).
    static func cells(workbook: String, sheet: String) throws -> [[String: String]] {
        let rows = try run("""
            tell application id "com.microsoft.Excel"
                set ws to worksheet \(quoted(sheet)) of workbook \(quoted(workbook))
                set n to (count of rows of used range of ws) + (first row index of used range of ws) - 1
                return value of range ("A1:E" & n) of ws
            end tell
            """)
        return items(rows).map { row in
            var cells: [String: String] = [:]
            for (column, value) in zip(["A", "B", "C", "D", "E"], items(row)) {
                let t = text(value)
                if !t.isEmpty { cells[column] = t }
            }
            return cells
        }
    }

    private static func run(_ source: String) throws -> NSAppleEventDescriptor {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            let number = error[NSAppleScript.errorNumber] as? Int ?? 0
            throw Failure(message: number == -1743
                ? "MxAcctMGR isn't allowed to control Microsoft Excel: allow it in System Settings ▸ Privacy & Security ▸ Automation."
                : "Excel: \(error[NSAppleScript.errorMessage] as? String ?? "error \(number)")")
        }
        guard let result else { throw Failure(message: "Excel didn't answer.") }
        return result
    }

    private static func items(_ d: NSAppleEventDescriptor) -> [NSAppleEventDescriptor] {
        d.numberOfItems == 0 ? [] : (1...d.numberOfItems).compactMap { d.atIndex($0) }
    }

    /// A cell's value as text: whole numbers without a decimal point, an empty cell (missing value) as "".
    private static func text(_ d: NSAppleEventDescriptor) -> String {
        switch d.descriptorType {
        case DescType(typeIEEE64BitFloatingPoint), DescType(typeIEEE32BitFloatingPoint):
            let x = d.doubleValue
            return x == x.rounded() && abs(x) < 1e15 ? String(Int64(x)) : String(x)
        case DescType(typeSInt32), DescType(typeSInt16): return String(d.int32Value)
        case DescType(typeType): return ""
        default: return (d.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private static func quoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

struct SecureImportSheet: View {
    /// The secure accounts now: rows are matched to them by name.
    let accounts: [SecureAccount]
    /// Saves an account (id 0 makes one); answers its id, or why it couldn't.
    var save: (Int, [String: Any]) async -> PayeeSaved
    var done: () async -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var workbooks: [(name: String, sheets: [String])] = []
    @State private var workbook = ""
    @State private var sheet = ""
    @State private var headers: [String] = []
    @State private var rows: [SecureImportRow] = []
    @State private var fillDescriptions = true
    @State private var problem: String?
    @State private var result: String?
    @State private var working = false

    private static let expected = ["USER_ID", "PASSWORD", "Account Description", "Notes", "Keys"]

    private func match(_ r: SecureImportRow) -> SecureAccount? { accounts.first { $0.name.lowercased() == r.name.lowercased() } }
    private var sheets: [String] { workbooks.first { $0.name == workbook }?.sheets ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import Passwords and Keys").heading(.heading)
            Text("Reads a credentials worksheet from the workbook open in Microsoft Excel — columns A user ID, B password, C account description, D notes, E keys — and puts each row's password and keys in this Mac's Keychain, under the secure account it names (made when there isn't one). Nothing with a password is written anywhere else, and none is shown here. The first time, macOS asks whether MxAcctMGR may control Excel.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(workbooks.isEmpty ? "Read from Excel" : "Read Again") { list() }
                if !workbooks.isEmpty {
                    Picker("Workbook", selection: $workbook) { ForEach(workbooks, id: \.name) { Text($0.name).tag($0.name) } }
                        .frame(width: 240)
                        .onChange(of: workbook) { sheet = sheets.first { $0.lowercased() == "creds" } ?? sheets.first ?? "" }
                    Picker("Worksheet", selection: $sheet) { ForEach(sheets, id: \.self) { Text($0).tag($0) } }
                        .frame(width: 200)
                        .onChange(of: sheet) { read() }
                }
                Spacer()
            }
            if !headers.isEmpty {
                let ok = headers == Self.expected
                Label("Columns A–E: " + headers.joined(separator: " · "), systemImage: ok ? "checkmark.circle" : "exclamationmark.triangle.fill")
                    .foregroundStyle(ok ? Color.secondary : Color.orange).font(.callout)
                    .help(ok ? "As expected: user ID, password, account description, notes, keys" : "Expected " + Self.expected.joined(separator: " · "))
            }
            if !rows.isEmpty {
                let matched = rows.filter { match($0) != nil }.count
                Text("\(rows.count) rows: \(matched) match a secure account, \(rows.count - matched) would be made · \(rows.filter { $0.password != nil }.count) passwords · \(rows.filter { $0.productKey != nil || $0.serviceKey != nil }.count) with keys · \(rows.filter { $0.notes != nil }.count) with notes")
                    .font(.callout).monospacedDigit()
                Table(rows) {
                    TableColumn("Row") { r in Text("\(r.row)").monospacedDigit().foregroundStyle(.secondary) }.width(36)
                    TableColumn("Secure account") { r in Text(r.name) }.width(min: 140, ideal: 220)
                    TableColumn("Account") { r in
                        Text(match(r) == nil ? "New" : "Existing").foregroundStyle(match(r) == nil ? Color.accentColor : .secondary)
                    }.width(60)
                    TableColumn("Password") { r in Image(systemName: r.password == nil ? "minus" : "key.fill").foregroundStyle(.secondary) }.width(60)
                    TableColumn("Keys") { r in
                        Text([r.productKey == nil ? nil : "product", r.serviceKey == nil ? nil : "service"].compactMap { $0 }.joined(separator: ", "))
                            .foregroundStyle(.secondary)
                    }.width(80)
                    TableColumn("Notes") { r in Image(systemName: r.notes == nil ? "minus" : "note.text").foregroundStyle(.secondary) }.width(44)
                }
                .tableText()
                .textSelection(.disabled)
                .frame(minHeight: 260)
                Toggle("Fill an account's empty description from the row's notes", isOn: $fillDescriptions)
            }
            if let problem { Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout) }
            if let result { Label(result, systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout).fixedSize(horizontal: false, vertical: true) }
            HStack {
                if result != nil {
                    Text("The workbook still holds them in plain text.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button(result == nil ? "Cancel" : "Done") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Import") { Task { await importRows() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(rows.isEmpty || working || result != nil)
            }
        }
        .padding(18)
        .frame(width: 720, height: 600)
    }

    /// The open workbooks, the one with a "creds" worksheet chosen.
    private func list() {
        problem = nil; result = nil
        do {
            workbooks = try ExcelBridge.workbooks()
            let pick = workbooks.first { $0.sheets.contains { $0.lowercased() == "creds" } } ?? workbooks.first
            workbook = pick?.name ?? ""
            sheet = pick?.sheets.first { $0.lowercased() == "creds" } ?? pick?.sheets.first ?? ""
            read()
        } catch { problem = describe(error) }
    }

    private func read() {
        guard !workbook.isEmpty, !sheet.isEmpty else { return }
        do {
            let cells = try ExcelBridge.cells(workbook: workbook, sheet: sheet)
            headers = ["A", "B", "C", "D", "E"].map { cells.first?[$0] ?? "" }
            rows = SecureImportRow.rows(cells)
            problem = rows.isEmpty ? "No rows with an account description or a user ID in \(sheet)." : nil
        } catch { problem = describe(error); rows = []; headers = [] }
    }
    /// Makes the accounts that aren't there, fills empty user names, service URLs and (with notes) descriptions, and
    /// stores each row's password and keys in the Keychain — leaving what the Keychain has when a row has none.
    private func importRows() async {
        working = true
        defer { working = false }
        var made = 0, filled = 0, passwords = 0, keys = 0, failed: [String] = []
        for r in rows {
            var id = match(r)?.id
            if let a = match(r) {
                var body: [String: Any] = ["version": a.version]
                if (a.ownerUserName ?? "").isEmpty, let u = r.user { body["ownerUserName"] = u }
                if (a.serviceUrl ?? "").isEmpty, let u = r.url { body["serviceUrl"] = u }
                if fillDescriptions, (a.description ?? "").isEmpty, let n = r.notes { body["description"] = n }
                if body.count > 1 {
                    let saved = await save(a.id, body)
                    if let e = saved.error { failed.append("row \(r.row): \(e)"); continue }
                    filled += 1
                }
            } else {
                var body: [String: Any] = ["name": r.name, "ownerUserName": r.user ?? "", "serviceUrl": r.url ?? "", "status": "active"]
                if fillDescriptions, let n = r.notes { body["description"] = n }
                let saved = await save(0, body)
                if let e = saved.error { failed.append("row \(r.row): \(e)"); continue }
                id = saved.id
                made += 1
            }
            guard let id else { failed.append("row \(r.row): no account id"); continue }
            for (kind, value) in [(SecureSecrets.Kind.password, r.password), (.productKey, r.productKey), (.serviceKey, r.serviceKey)] {
                guard let value else { continue }
                if SecureSecrets.set(value, kind, id, product: r.name) {
                    if kind == .password { passwords += 1 } else { keys += 1 }
                } else {
                    failed.append("row \(r.row): the Keychain didn't take its \(kind.rawValue)")
                }
            }
        }
        await done()
        result = "Stored \(passwords) passwords and \(keys) keys in this Mac's Keychain; made \(made) accounts and filled in \(filled)."
            + (failed.isEmpty ? "" : " Not done: " + failed.joined(separator: "; ") + ".")
    }
}
