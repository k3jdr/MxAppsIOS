//
//  PortfolioTransfer.swift
//  MxAcctMGR
//
//  The open portfolio in and out of files, and copies of it: File ▸ Import Holdings… (a CSV of tickers, shares and
//  optionally cost and purchase date — a custodian's export — resolved against the security master, then added to the
//  holdings or replacing them), Export Portfolio… (JSON: the saved account, lots, preferences and decisions; or CSV:
//  the lots), Duplicate Portfolio… (a new portfolio from the saved version) and Rename Portfolio… (its name; the
//  code stays, as other apps link to it). The portfolio itself stays in the security master.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// One row of an imported CSV, resolved against the security master.
struct ImportRow: Identifiable, Hashable {
    let id = UUID()
    var line: Int
    var ticker: String
    var quantity: Double
    var cost: Double?
    var acquired: Date?
    var security: SRMSecurity?
    var problem: String?
}

/// The rows of a CSV file waiting for Add or Replace.
struct ImportPreview: Identifiable {
    let id = UUID()
    var file: String
    var rows: [ImportRow]
    var skipped: [String]
}

enum HoldingsCSV {
    /// Rows of a CSV with a header naming the columns (case and spaces ignored): ticker or symbol; shares or quantity;
    /// optionally cost / cost basis / total cost, and acquired / date / purchase date (yyyy-mm-dd or m/d/yyyy).
    static func parse(_ text: String) -> (rows: [ImportRow], skipped: [String]) {
        var lines = text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !lines.isEmpty else { return ([], ["The file is empty."]) }
        let header = fields(lines.removeFirst()).map { $0.lowercased().filter { $0.isLetter } }
        func column(_ names: [String]) -> Int? { header.firstIndex { names.contains($0) } }
        guard let t = column(["ticker", "symbol"]), let q = column(["shares", "quantity", "qty", "units"]) else {
            return ([], ["The first line must name the columns, with a Ticker (or Symbol) and a Shares (or Quantity) column."])
        }
        let c = column(["cost", "costbasis", "totalcost", "basis"])
        let d = column(["acquired", "date", "purchasedate", "opendate", "dateacquired"])
        var rows: [ImportRow] = [], skipped: [String] = []
        for (i, line) in lines.enumerated() {
            let f = fields(line)
            let ticker = t < f.count ? f[t].trimmingCharacters(in: .whitespaces).uppercased() : ""
            let quantity = q < f.count ? number(f[q]) : nil
            guard !ticker.isEmpty, let quantity, quantity > 0 else {
                skipped.append("Line \(i + 2): no ticker or no shares")
                continue
            }
            rows.append(ImportRow(line: i + 2, ticker: ticker, quantity: quantity,
                                  cost: c.flatMap { $0 < f.count ? number(f[$0]) : nil },
                                  acquired: d.flatMap { $0 < f.count ? date(f[$0]) : nil }))
        }
        return (rows, skipped)
    }

    /// A CSV line's fields (quoted fields may hold commas).
    static func fields(_ line: String) -> [String] {
        var out: [String] = [], field = "", quoted = false
        for ch in line {
            if ch == "\"" { quoted.toggle() } else if ch == "," && !quoted { out.append(field); field = "" } else { field.append(ch) }
        }
        out.append(field)
        return out.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    static func number(_ s: String) -> Double? {
        Double(s.replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces))
    }

    static func date(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd", "M/d/yyyy", "MM/dd/yyyy", "M/d/yy"] {
            f.dateFormat = format
            if let d = f.date(from: s.trimmingCharacters(in: .whitespaces)) { return d }
        }
        return nil
    }
}

extension PortStore {
    /// Asks for a CSV file, reads it and resolves its tickers; the preview sheet then adds or replaces.
    func importHoldings() {
        guard openPortfolio != nil else { errorMessage = "Open or create a portfolio first."; return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        panel.message = "A CSV with a header line: Ticker and Shares, optionally Cost and Acquired"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importHoldings(from: url)
    }

    /// Reads a CSV file and resolves its tickers; the preview sheet then adds or replaces.
    func importHoldings(from url: URL) {
        guard let text = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .isoLatin1)) else {
            errorMessage = "\(url.lastPathComponent) could not be read."
            return
        }
        let (parsed, skipped) = HoldingsCSV.parse(text)
        Task {
            var rows = parsed
            do {
                let (found, _) = try await AccountsClient.resolve(rows.map(\.ticker))
                for i in rows.indices {
                    if let s = found[rows[i].ticker] {
                        rows[i].security = s
                        if s.price == nil { rows[i].problem = "no price yet" }
                    } else {
                        rows[i].problem = "not in the security master"
                    }
                }
                importPreview = ImportPreview(file: url.lastPathComponent, rows: rows, skipped: skipped)
            } catch {
                if !(error is CancellationError) { errorMessage = error.localizedDescription }
            }
        }
    }

    /// Adds the resolved rows to the open portfolio, or replaces its holdings (cash stays) — unsaved until File ▸ Save.
    func applyImport(_ preview: ImportPreview, replace: Bool) {
        guard var mine = openPortfolio else { return }
        if replace {
            mine.holdings.removeAll { $0.ticker != "CASH" }
            portfolio = mine
        }
        for r in preview.rows {
            guard let s = r.security else { continue }
            addSRMHolding(s, quantity: r.quantity, cost: r.cost, acquired: r.acquired)
        }
        importPreview = nil
        go(.myPortfolio)
    }

    /// Exports the saved portfolio — after the open one is settled — as JSON (account, lots, preferences, decisions)
    /// or CSV (the lots).
    func exportPortfolio(csv: Bool) {
        let code = srmCode
        guard openPortfolio != nil, !code.isEmpty else { return }
        whenSettled("export \(code)") { [self] in
            do {
                let account = try await AccountsClient.account(code)
                let panel = NSSavePanel()
                panel.allowedContentTypes = [csv ? .commaSeparatedText : .json]
                panel.nameFieldStringValue = "\(code)-v\(account.version ?? 1).\(csv ? "csv" : "json")"
                guard panel.runModal() == .OK, let url = panel.url else { return }
                let data: Data
                if csv {
                    var lines = ["Ticker,Name,Acquired,Shares,Cost Basis,Price,Market Value"]
                    for l in account.lots {
                        let name = l.name.replacingOccurrences(of: "\"", with: "'")
                        let value = l.price.map { $0 * l.quantity }
                        lines.append("\(l.ticker),\"\(name)\",\(l.acquired),\(l.quantity),\(l.costBasis),\(l.price.map { String($0) } ?? ""),\(value.map { String($0) } ?? "")")
                    }
                    if account.cash > 0 { lines.append("CASH,Cash,,,\(account.cash),,\(account.cash)") }
                    data = Data((lines.joined(separator: "\n") + "\n").utf8)
                } else {
                    struct Export: Encodable {
                        var format = "MxAcctMGR portfolio export, version 1"
                        var exportedAt: String
                        var account: SRMAccount
                        var decisions: [SRMDecision]
                    }
                    let enc = JSONEncoder()
                    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
                    data = try enc.encode(Export(exportedAt: ISO8601DateFormatter().string(from: Date()), account: account,
                                                 decisions: (try? await AccountsClient.decisions(code)) ?? []))
                }
                try data.write(to: url)
                message = "Exported \(code) version \(account.version ?? 1) to \(url.lastPathComponent)"
            } catch {
                if !(error is CancellationError) { errorMessage = "\(code) was not exported: \(error.localizedDescription)" }
            }
        }
    }

    /// A new portfolio from the open one's saved version, then opened (File ▸ Duplicate Portfolio…).
    func duplicatePortfolio(to newCode: String, name: String) {
        let code = srmCode, new = newCode.trimmingCharacters(in: .whitespaces).uppercased()
        whenSettled("duplicate \(code)") { [self] in
            do {
                _ = try await AccountsClient.duplicate(code, to: new, name: name)
                await openSRMAccount(new)
                selectedID = "mine"
            } catch {
                if !(error is CancellationError) { errorMessage = "\(new) was not created: \(error.localizedDescription)" }
            }
        }
    }

    /// Renames the open portfolio (its code stays); saved with File ▸ Save.
    func renamePortfolio(_ name: String) {
        guard var mine = openPortfolio, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        mine.name = name.trimmingCharacters(in: .whitespaces)
        portfolio = mine
    }
}
