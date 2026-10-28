//
//  LoanViews.swift
//  MxAcctMGR
//
//  Banking ▸ Loan Accounts (V053, the accounts service's loans.py): each mortgage and vehicle loan (auto, boat, RV)
//  with its terms and the target accounts the check register pays it with. Import Statements… reads the lender's
//  billing statements from their PDFs — PDFKit gives the text, the service reads the figures and keeps each PDF in the
//  loan's folder. The latest statement's balance, rate and payment drive the forecast of every payment's interest and
//  principal to payoff, with an extra principal to try; Interest by Year gives each year's interest from the statements
//  and the forecast until the lender's Form 1098 is entered, and Spending Analysis ▸ Year-End Tax lists it.
//

import AppKit
import Charts
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Model and client

/// What a loan is: a mortgage, or a loan on an auto, boat, RV or motorcycle.
enum LoanKind: String, CaseIterable, Identifiable {
    case mortgage, vehicle

    var id: String { rawValue }
    var title: String { self == .mortgage ? "Mortgage" : "Vehicle Loan" }
    var detail: String { self == .mortgage ? "A home loan, secured by the house" : "An auto, boat, RV or motorcycle loan" }
    var symbol: String { self == .mortgage ? "house" : "car" }
    var collateralLabel: String { self == .mortgage ? "Property" : "Vehicle or boat" }
    var collateralPrompt: String { self == .mortgage ? "The house's street address" : "2022 Honda Odyssey, 2019 Sea Ray 210" }

    static func title(_ raw: String) -> String { LoanKind(rawValue: raw)?.title ?? raw }
}

struct LoanPayee: Decodable, Identifiable, Hashable {
    var id: Int
    var name: String
}

struct LoanAccount: Decodable, Identifiable, Hashable {
    var id: Int
    var code: String
    var name: String
    var kind: String
    var lender: String?
    var last4: String?
    var collateral: String?
    var originalAmount: Double?
    /// Percent a year (3.5 for 3.500%).
    var interestRate: Double?
    var termMonths: Int?
    var firstPaymentDate: String?
    var maturityDate: String?
    /// The scheduled principal and interest, escrow aside.
    var paymentAmount: Double?
    var escrowAmount: Double
    /// The extra principal the forecast assumes each month.
    var extraPrincipal: Double
    /// The target accounts the check register pays it with.
    var paymentPayees: [Int]
    var statementFolder: String?
    var interestDeductible: Bool
    /// open or paid_off.
    var status: String
    var paidOffDate: String?
    var notes: String?
    var version: Int
    var updatedBy: String?
    // The list's: the latest statement's balance and due date, and how many statements.
    var balance: Double?
    var balanceAsOf: String?
    var nextDue: String?
    var statements: Int?
    // The loan's own page: the folder its statements are kept in and its target accounts by name.
    var folder: String?
    var payees: [LoanPayee]?

    var title: String { name + (last4.map { " ···\($0)" } ?? "") }
}

struct LoanStatement: Decodable, Identifiable, Hashable {
    var id: Int
    var statementDate: String
    var dueDate: String?
    var amountDue: Double?
    var regularPayment: Double?
    var duePrincipal: Double?
    var dueInterest: Double?
    var dueEscrow: Double?
    var principalBalance: Double
    var escrowBalance: Double?
    var interestRate: Double?
    var maturityDate: String?
    var ytdReceived: Double?
    var ytdPrincipal: Double?
    var ytdInterest: Double?
    var ytdEscrow: Double?
    var lender: String?
    var last4: String?
    var fileName: String?
    var loadedBy: String?
}

struct LoanActivity: Decodable, Identifiable, Hashable {
    var id: Int
    var date: String
    var description: String
    /// payment, principal, escrow, fee or other.
    var kind: String
    var dueMonth: String?
    var total: Double
    var principal: Double
    var interest: Double
    var escrow: Double
    var other: Double
    var statementDate: String
}

/// A check to one of the loan's target accounts, with the statement activity it matches (the same total within five days).
struct LoanCheck: Decodable, Identifiable, Hashable {
    var id: Int
    var date: String
    var amount: Double
    var payee: String
    var register: String
    var memo: String?
    var status: String
    var onStatement: String?
}

struct LoanForecast: Decodable, Hashable {
    struct Row: Decodable, Identifiable, Hashable {
        var due: String
        /// When it is expected: as many days from its due date as the loan's payments have been.
        var paid: String
        var payment: Double
        var principal: Double
        var interest: Double
        var extra: Double
        var escrow: Double
        var balance: Double
        var id: String { due }
    }
    struct Year: Decodable, Identifiable, Hashable {
        var year: Int
        var payments: Int
        var principal: Double
        var interest: Double
        var extra: Double
        var escrow: Double
        var endBalance: Double
        var id: Int { year }
    }
    struct Base: Decodable, Hashable {
        var payoff: String?
        var months: Int
        var interestLeft: Double
    }
    /// Why there is no forecast (no statement and no terms, or a payment that doesn't cover the interest).
    var problem: String?
    /// statement (from the latest statement) or terms (from the amount borrowed and the first payment).
    var basis: String?
    var asOf: String?
    var balance: Double?
    var rate: Double?
    var payment: Double?
    var escrow: Double?
    var extra: Double?
    var paidDayOffset: Int?
    var maturityDate: String?
    var rows: [Row]?
    var payoff: String?
    var months: Int?
    var interestLeft: Double?
    var paidLeft: Double?
    var byYear: [Year]?
    /// The same with no extra principal, to compare.
    var withoutExtra: Base?
    var interestSaved: Double?
}

/// A year's interest on a loan: from the statements (the last one's year to date plus the activity after it that year),
/// the forecast for the payments still to come, and the lender's Form 1098 once entered. Year-End Tax's carry the loan.
struct LoanYear: Decodable, Identifiable, Hashable {
    struct Form1098: Decodable, Hashable {
        var interestPaid: Double
        var pointsPaid: Double
        var mortgageInsurance: Double
        var propertyTax: Double
        var notes: String?
        var updatedBy: String?
    }
    var year: Int
    var statementsInterest: Double
    var statementsPrincipal: Double
    var activityInterest: Double
    /// The activity misses some of the year-to-date interest: a statement wasn't imported (its interest still counts).
    var missingStatements: Bool
    /// No statement of the year: only the activity a later statement shows.
    var partial: Bool
    var forecastInterest: Double
    var forecastPrincipal: Double
    var forecastPayments: Int
    var estimate: Double
    var form1098: Form1098?
    /// What counts: the Form 1098's interest, else the estimate.
    var interest: Double
    var source: String
    var code: String?
    var name: String?
    var lender: String?

    var id: String { "\(code ?? "")-\(year)" }
}

struct LoanList: Decodable {
    var loans: [LoanAccount]
    var payees: [LoanPayee]
    var defaultFolder: String
    /// The loan a save made or changed.
    var code: String?
}

struct LoanDetail: Decodable {
    struct Imported: Decodable, Identifiable, Hashable {
        var fileName: String
        /// read, already or refused.
        var status: String
        var message: String?
        var statementDate: String?
        var id: String { fileName + status }
    }
    var loan: LoanAccount
    var statements: [LoanStatement]
    var activity: [LoanActivity]
    var checks: [LoanCheck]
    var forecast: LoanForecast
    var years: [LoanYear]
    var imported: [Imported]?
}

nonisolated enum LoanClient {
    private static func signed(_ body: [String: Any]) -> [String: Any] { body.merging(["by": BankClient.by]) { a, _ in a } }
    private static var byQuery: String { BankClient.by.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "" }

    static func list() async throws -> LoanList {
        try await AccountsClient.request("GET", "/loans", as: LoanList.self)
    }
    static func detail(_ code: String, extra: Double? = nil) async throws -> LoanDetail {
        try await AccountsClient.request("GET", "/loans/\(code)" + (extra.map { "?extra=\($0)" } ?? ""), as: LoanDetail.self)
    }
    static func save(_ code: String, _ body: [String: Any]) async throws -> LoanList {
        try await AccountsClient.request("PUT", "/loans/\(code)", body: signed(body), as: LoanList.self)
    }
    /// Removes the loan with its statements; the PDFs stay in its folder.
    static func remove(_ code: String) async throws -> LoanList {
        try await AccountsClient.request("DELETE", "/loans/\(code)?confirm=\(code)&by=\(byQuery)", as: LoanList.self)
    }
    /// Reads billing statements: each `{fileName, text, pdf}` (the PDF's text and the file in base64).
    static func importStatements(_ code: String, _ files: [[String: Any]]) async throws -> LoanDetail {
        try await AccountsClient.request("POST", "/loans/\(code)/statements", body: signed(["files": files]), timeout: 180, as: LoanDetail.self)
    }
    static func removeStatement(_ code: String, _ date: String) async throws -> LoanDetail {
        try await AccountsClient.request("DELETE", "/loans/\(code)/statements/\(date)", as: LoanDetail.self)
    }
    static func saveTaxYear(_ code: String, _ year: Int, _ body: [String: Any]) async throws -> LoanDetail {
        try await AccountsClient.request("PUT", "/loans/\(code)/tax-years/\(year)", body: signed(body), as: LoanDetail.self)
    }
    static func removeTaxYear(_ code: String, _ year: Int) async throws -> LoanDetail {
        try await AccountsClient.request("DELETE", "/loans/\(code)/tax-years/\(year)", as: LoanDetail.self)
    }
}

/// "Nov 2041" for a yyyy-mm-dd date.
private func monthYear(_ s: String?) -> String {
    guard let s, let d = isoDay.date(from: s) else { return "—" }
    return d.formatted(.dateTime.month(.abbreviated).year())
}

private func rate(_ x: Double?) -> String { x.map { String(format: "%.3f%%", $0) } ?? "—" }

// MARK: - Loan Accounts

/// New… or Edit…: the sheet for a loan, with the kind a new one starts as.
private struct LoanSheetRequest: Identifiable {
    let id = UUID()
    var loan: LoanAccount?
    var kind: LoanKind
}

struct LoanAccountsView: View {
    @Bindable var store: PortStore
    @AppStorage("loanAccount") private var selected = ""
    @State private var list: LoanList?
    @State private var detail: LoanDetail?
    @State private var problem: String?
    @State private var message: String?
    @State private var busy = false
    @State private var sheet: LoanSheetRequest?
    @State private var removing = false
    @State private var dropping: LoanStatement?
    @State private var form: LoanYear?
    /// The extra principal typed to try, and the one the forecast shown uses when it isn't the loan's own.
    @State private var extraText = ""
    @State private var tried: Double?
    @State private var everyPayment = false
    /// The last Import Statements…'s files that weren't read, with why.
    @State private var notRead: [LoanDetail.Imported] = []

    var body: some View {
        StepPage(store: store, subtitle: "Each mortgage and vehicle loan: its balance, the lender's statements, and a forecast of every payment's interest and principal to payoff — the interest each year for Year-End Tax.", lesson: [
            "New… ▸ Mortgage or Vehicle Loan (auto, boat, RV or motorcycle): its name, lender and the target accounts the check register pays it with. The terms can wait: the first statement fills in the rate, the payment, the maturity, the lender and the last four digits.",
            "Import Statements… reads the lender's billing statements (PDF; pick several, or a folder): the balance, the payment due and its split, the year-to-date interest and what the lender applied. Each PDF is kept in the loan's folder, and a statement read before is skipped.",
            "The forecast runs from the latest statement: each month's interest is the balance times the rate over 12, the rest of the payment is principal. Try an extra principal each month to see the payoff move. In January, enter the lender's Form 1098: Year-End Tax then counts it instead of the estimate.",
        ]) {
            bar
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
            }
            if let d = detail {
                tiles(d)
                if !notRead.isEmpty { notReadBox }
                forecastBox(d)
                yearsBox(d)
                statementsBox(d)
                activityBox(d)
                checksBox(d)
            } else if list?.loans.isEmpty == true && problem == nil && !busy {
                ContentUnavailableView {
                    Label("No loan account yet", systemImage: "house.circle")
                } description: {
                    Text("Add a mortgage or a vehicle loan, then import its billing statements: the balance, the interest and the payoff follow from them.")
                } actions: {
                    HStack {
                        ForEach(LoanKind.allCases) { k in Button("New \(k.title)…") { sheet = LoanSheetRequest(loan: nil, kind: k) } }
                    }
                }
            }
        }
        .task { await reload() }
        .sheet(item: $sheet) { r in
            LoanSheet(loan: r.loan, kind: r.kind, payees: list?.payees ?? [], defaultFolder: list?.defaultFolder ?? "") { code, body in
                do {
                    let l = try await LoanClient.save(code, body)
                    list = l
                    let before = selected
                    selected = l.code ?? code
                    if selected == before { await refresh() }
                    return nil
                } catch { return describe(error) }
            }
        }
        .sheet(item: $form) { y in
            if let l = detail?.loan {
                Form1098Sheet(loan: l, year: y) { body in
                    await run { try await LoanClient.saveTaxYear(l.code, y.year, body) }
                } remove: {
                    await run { try await LoanClient.removeTaxYear(l.code, y.year) }
                }
            }
        }
        .confirmationDialog("Remove \(detail?.loan.name ?? "the loan")?", isPresented: $removing) {
            Button("Remove", role: .destructive) { Task { await remove() } }
        } message: {
            Text("Its \(detail?.statements.count ?? 0) statements, the lender's activity and its Forms 1098 go. The statements' PDFs stay in \(detail?.loan.folder ?? "its folder"), and the checks stay in the register.")
        }
        .confirmationDialog("Take off the statement of \(shortDay(dropping?.statementDate))?", isPresented: Binding(get: { dropping != nil }, set: { if !$0 { dropping = nil } }),
                            presenting: dropping) { s in
            Button("Take Off", role: .destructive) {
                Task { if let code = detail?.loan.code { await run { try await LoanClient.removeStatement(code, s.statementDate) } } }
            }
        } message: { _ in
            Text("The activity only it showed goes with it; its PDF stays in the loan's folder, and Import Statements… reads it again.")
        }
    }

    private var bar: some View {
        HStack(spacing: 10) {
            Picker("Loan", selection: $selected) {
                ForEach(list?.loans ?? []) { l in Label(l.title, systemImage: LoanKind(rawValue: l.kind)?.symbol ?? "doc").tag(l.code) }
            }
            .frame(maxWidth: 340)
            .disabled(list?.loans.isEmpty ?? true)
            Menu("New…") {
                ForEach(LoanKind.allCases) { k in
                    Button { sheet = LoanSheetRequest(loan: nil, kind: k) } label: { Label("\(k.title) — \(k.detail.lowercased())", systemImage: k.symbol) }
                }
            }
            .fixedSize()
            Button("Edit…") { if let l = detail?.loan { sheet = LoanSheetRequest(loan: l, kind: LoanKind(rawValue: l.kind) ?? .mortgage) } }
                .disabled(detail == nil)
            Button("Remove…") { removing = true }
                .disabled(detail == nil || busy)
                .help("Remove this loan with its statements and Forms 1098: the PDFs stay in its folder")
            Spacer()
            if busy { ProgressView().controlSize(.small) }
            if let message { Text(message).font(.callout).foregroundStyle(.secondary).lineLimit(2) }
            Button { importStatements() } label: { Label("Import Statements…", systemImage: "doc.richtext") }
                .disabled(detail == nil || busy)
                .help("Read the lender's billing statements (PDF; several, or a folder of them): each is kept in the loan's folder, and one read before is skipped")
            Button { Task { await refresh() } } label: { Image(systemName: "arrow.clockwise") }
                .help("Read the loan again")
        }
        .onChange(of: selected) { tried = nil; extraText = ""; notRead = []; Task { await refresh() } }
    }

    // MARK: Tiles

    private func tiles(_ d: LoanDetail) -> some View {
        let l = d.loan, f = d.forecast, s = d.statements.first
        let year = Calendar.current.component(.year, from: .now)
        let now = d.years.first { $0.year == year }
        return HStack(spacing: 10) {
            MetricTile(title: "Principal balance", value: s.map { money2($0.principalBalance) } ?? "—",
                       caption: s.map { "statement of \(shortDay($0.statementDate))" + (l.lender.map { " · \($0)" } ?? "") } ?? "import a statement",
                       help: "The unpaid principal on the latest statement, after the payments it shows. Not a payoff amount: the lender adds the interest since.")
            MetricTile(title: "Rate and payment", value: rate(f.rate ?? l.interestRate),
                       caption: f.payment.map { "\(money2($0)) principal and interest" + ((f.escrow ?? 0) > 0 ? " + \(money2(f.escrow ?? 0)) escrow" : "") } ?? "set the payment in Edit…",
                       help: "The interest rate (the latest statement's, else the loan's) and the scheduled monthly payment: principal and interest, plus escrow for taxes and insurance when the lender keeps one.")
            MetricTile(title: "Next payment", value: s?.amountDue.map(money2) ?? "—",
                       caption: s?.dueDate.map { "due \(shortDay($0))" } ?? "",
                       help: "The total amount due and its due date on the latest statement.")
            MetricTile(title: "Paid off", value: monthYear(f.payoff),
                       caption: f.months.map { "\($0) payments left" + (f.maturityDate.map { " · matures \(monthYear($0))" } ?? "") } ?? (f.problem ?? ""),
                       tint: f.payoff != nil && f.maturityDate != nil && (f.payoff ?? "") < (f.maturityDate ?? "") ? .green : .primary,
                       help: "When the forecast pays the loan off, and the maturity on the note. Extra principal paid in the past (and any tried below) brings it before the maturity: green.")
            MetricTile(title: "Interest \(String(year))", value: now.map { money2($0.interest) } ?? "—",
                       caption: now.map { $0.form1098 != nil ? "Form 1098" : "statements \(money2($0.statementsInterest)) + forecast \(money2($0.forecastInterest))" } ?? "",
                       tint: now?.form1098 != nil ? .green : .primary,
                       help: "This year's interest: the statements' year to date plus the forecast for the payments still to come this year, until the lender's Form 1098 is entered (Interest by Year).")
            MetricTile(title: "Interest to payoff", value: f.interestLeft.map(money2) ?? "—",
                       caption: f.paidLeft.map { "\(money2($0)) still to pay" } ?? "",
                       help: "The interest every payment still to come carries, as forecast.")
        }
    }

    private var notReadBox: some View {
        Box(title: "Not Read", symbol: "exclamationmark.triangle", help: "Files the last Import Statements… didn't read, with why: read before (the same file), not a statement it reads, or another loan's.") {
            ForEach(notRead) { r in
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: r.status == "already" ? "checkmark.circle" : "xmark.octagon").foregroundStyle(r.status == "already" ? Color.secondary : Color.orange)
                    Text(r.fileName)
                    Text(r.message ?? "").foregroundStyle(.secondary)
                }
                .font(.callout)
            }
            HStack { Spacer(); Button("Dismiss") { notRead = [] }.controlSize(.small) }
        }
    }

    // MARK: Forecast

    private func forecastBox(_ d: LoanDetail) -> some View {
        let f = d.forecast
        return Box(title: "Forecast", symbol: "chart.line.downtrend.xyaxis", help: "Every payment from the latest statement until the loan is paid: each month's interest is the balance times the rate over 12 (to the cent), the rest of the payment is principal, and the extra principal comes off too. A payment is expected as many days from its due date as this loan's have been, so a January payment made December 31 counts in the year before.") {
            if let p = f.problem {
                Text(p).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 10) {
                    Text("Extra principal each month")
                    TextField("0.00", text: $extraText).frame(width: 90).multilineTextAlignment(.trailing)
                        .onSubmit { Task { await tryExtra() } }
                    Button("Try") { Task { await tryExtra() } }
                    if let t = tried, abs(t - d.loan.extraPrincipal) > 0.004 {
                        Button("Keep for This Loan") { Task { await keepExtra(t) } }
                            .help("Make \(money2(t)) the extra principal this loan's forecast assumes")
                        Button("Back to \(money2(d.loan.extraPrincipal))") { tried = nil; extraText = ""; Task { await refresh() } }
                    }
                    Spacer()
                    if let o = f.paidDayOffset, o != 0 {
                        Text("Payments expected \(abs(o)) day\(abs(o) == 1 ? "" : "s") \(o < 0 ? "before" : "after") their due date, as they have been")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let saved = f.interestSaved, saved > 0.004, let base = f.withoutExtra {
                    Text("With \(money2(f.extra ?? 0)) a month extra: paid off \(monthYear(f.payoff)) instead of \(monthYear(base.payoff)), \(base.months - (f.months ?? 0)) payments sooner, and \(money2(saved)) less interest.")
                        .font(.callout).foregroundStyle(.green)
                }
                if let rows = f.rows, !rows.isEmpty { chart(rows) }
                byYear(f)
                payments(f)
            }
        }
    }

    private func chart(_ rows: [LoanForecast.Row]) -> some View {
        Chart {
            ForEach(rows) { r in
                if let day = isoDay.date(from: r.due) {
                    AreaMark(x: .value("Due", day), y: .value("Balance", r.balance))
                        .foregroundStyle(.blue.opacity(0.15))
                    LineMark(x: .value("Due", day), y: .value("Balance", r.balance))
                        .foregroundStyle(.blue)
                }
            }
        }
        .chartYAxis {
            AxisMarks { v in
                AxisGridLine()
                AxisValueLabel { if let x = v.as(Double.self) { Text(money(x)) } }
            }
        }
        .frame(height: 150)
        .help("The principal balance after each payment, to payoff")
    }

    private func byYear(_ f: LoanForecast) -> some View {
        let years = f.byYear ?? []
        let escrow = years.contains { $0.escrow > 0 }
        return Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 3) {
            GridRow {
                Text("Year").gridColumnAlignment(.leading); Text("Payments"); Text("Principal"); Text("Extra"); Text("Interest")
                if escrow { Text("Escrow") }
                Text("Balance at year end").fillsGridColumn(.trailing)
            }
            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(years) { y in
                GridRow {
                    Text(verbatim: "\(y.year)").gridColumnAlignment(.leading)
                    Text("\(y.payments)")
                    Text(money2(y.principal))
                    Text(y.extra > 0 ? money2(y.extra) : "—").foregroundStyle(.secondary)
                    Text(money2(y.interest))
                    if escrow { Text(money2(y.escrow)) }
                    Text(money2(y.endBalance)).fillsGridColumn(.trailing)
                }
                .monospacedDigit()
            }
        }
        .font(.callout)
    }

    private func payments(_ f: LoanForecast) -> some View {
        let rows = f.rows ?? []
        let shown = everyPayment ? rows : Array(rows.prefix(12))
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(everyPayment ? "Every payment" : "The next 12 payments").heading(.name)
                Spacer()
                Toggle("Every payment (\(rows.count))", isOn: $everyPayment).toggleStyle(.checkbox)
            }
            Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 3) {
                GridRow {
                    Text("Due").gridColumnAlignment(.leading); Text("Expected").gridColumnAlignment(.leading)
                    Text("Payment"); Text("Principal"); Text("Interest"); Text("Extra"); Text("Balance").fillsGridColumn(.trailing)
                }
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(shown) { r in
                    GridRow {
                        Text(shortDay(r.due)).gridColumnAlignment(.leading)
                        Text(shortDay(r.paid)).foregroundStyle(.secondary).gridColumnAlignment(.leading)
                        Text(money2(r.payment))
                        Text(money2(r.principal))
                        Text(money2(r.interest))
                        Text(r.extra > 0 ? money2(r.extra) : "—").foregroundStyle(.secondary)
                        Text(money2(r.balance)).fillsGridColumn(.trailing)
                    }
                    .monospacedDigit()
                }
            }
            .font(.callout)
        }
    }

    // MARK: Interest by year

    private func yearsBox(_ d: LoanDetail) -> some View {
        let thisYear = Calendar.current.component(.year, from: .now)
        return Box(title: "Interest by Year", symbol: "calendar", help: "Each year's interest: the statements' (the last statement's year-to-date interest plus what later statements show was paid that year, so a missing statement's interest still counts), plus the forecast for the payments still to come, until the lender's Form 1098 is entered. Year-End Tax counts the Form 1098 once it is here\(d.loan.interestDeductible ? "" : " — this loan's interest isn't marked deductible (Edit…)").") {
            Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 4) {
                GridRow {
                    Text("Year").gridColumnAlignment(.leading); Text("Statements"); Text("Forecast"); Text("Estimate"); Text("Form 1098"); Text("Counts")
                    Text("").fillsGridColumn(); Text("")
                }
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(d.years) { y in
                    GridRow {
                        Text(verbatim: "\(y.year)").gridColumnAlignment(.leading)
                        Text(money2(y.statementsInterest))
                        Text(y.forecastPayments > 0 ? money2(y.forecastInterest) : "—").foregroundStyle(.secondary)
                        Text(money2(y.estimate))
                        Text(y.form1098.map { money2($0.interestPaid) } ?? "—")
                        Text(money2(y.interest)).fontWeight(.semibold)
                        Text(note(y)).font(.caption).foregroundStyle(y.missingStatements || y.partial ? .orange : .secondary)
                            .lineLimit(2).fillsGridColumn()
                        Group {
                            if y.year <= thisYear {
                                Button(y.form1098 == nil ? "Enter 1098…" : "Edit 1098…") { form = y }.controlSize(.small)
                            } else { Text("") }
                        }
                    }
                    .monospacedDigit()
                }
            }
            .font(.callout)
        }
    }

    private func note(_ y: LoanYear) -> String {
        var parts: [String] = []
        if let f = y.form1098 {
            parts.append("Form 1098" + (abs(f.interestPaid - y.estimate) > 0.004 ? " (\(money2(f.interestPaid - y.estimate)) from the estimate)" : ""))
        } else if y.forecastPayments > 0 {
            parts.append("\(y.forecastPayments) payment\(y.forecastPayments == 1 ? "" : "s") still to come")
        }
        if y.missingStatements { parts.append("a statement is missing: its year-to-date interest covers it") }
        if y.partial { parts.append("only the payments a later statement shows") }
        return parts.joined(separator: " · ")
    }

    // MARK: Statements, activity and checks

    private func statementsBox(_ d: LoanDetail) -> some View {
        let escrow = d.statements.contains { ($0.dueEscrow ?? 0) > 0 || ($0.escrowBalance ?? 0) > 0 }
        return Box(title: "Statements", symbol: "doc.richtext", help: "The billing statements read, newest first: the payment due and its split, the principal balance, the rate and the year-to-date interest. Each PDF is kept in \(d.loan.folder ?? "the loan's folder"); ✕ takes a statement off.") {
            if d.statements.isEmpty {
                Text("No statement yet: Import Statements… reads the lender's billing statements (PDF).").foregroundStyle(.secondary)
            } else {
                Grid(alignment: .trailing, horizontalSpacing: 12, verticalSpacing: 3) {
                    GridRow {
                        Text("Statement").gridColumnAlignment(.leading); Text("Due").gridColumnAlignment(.leading); Text("Amount due")
                        Text("Principal"); Text("Interest")
                        if escrow { Text("Escrow") }
                        Text("Balance"); Text("Rate"); Text("Interest YTD"); Text("File").fillsGridColumn(); Text("")
                    }
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(d.statements) { s in
                        GridRow {
                            Text(shortDay(s.statementDate)).gridColumnAlignment(.leading)
                            Text(shortDay(s.dueDate)).foregroundStyle(.secondary).gridColumnAlignment(.leading)
                            Text(s.amountDue.map(money2) ?? "—")
                            Text(s.duePrincipal.map(money2) ?? "—")
                            Text(s.dueInterest.map(money2) ?? "—")
                            if escrow { Text(s.dueEscrow.map(money2) ?? "—") }
                            Text(money2(s.principalBalance))
                            Text(rate(s.interestRate)).foregroundStyle(.secondary)
                            Text(s.ytdInterest.map(money2) ?? "—")
                            Text(s.fileName ?? "").foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).fillsGridColumn()
                                .help(s.loadedBy.map { "Read by \($0)" } ?? "")
                            Button { dropping = s } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
                                .help("Take this statement off")
                        }
                        .monospacedDigit()
                    }
                }
                .font(.callout)
            }
        }
    }

    private func activityBox(_ d: LoanDetail) -> some View {
        let escrow = d.activity.contains { $0.escrow != 0 }, other = d.activity.contains { $0.other != 0 }
        return Box(title: "What the Lender Applied", symbol: "list.bullet.rectangle", help: "Each statement's activity since the one before, kept once: regular payments split into principal, interest and escrow, extra principal payments, escrow disbursements and fees.") {
            if d.activity.isEmpty {
                Text("The statements' activity shows here.").foregroundStyle(.secondary)
            } else {
                Grid(alignment: .trailing, horizontalSpacing: 12, verticalSpacing: 3) {
                    GridRow {
                        Text("Date").gridColumnAlignment(.leading); Text("Description").gridColumnAlignment(.leading)
                        Text("Total"); Text("Principal"); Text("Interest")
                        if escrow { Text("Escrow") }
                        if other { Text("Other") }
                        Text("Statement").fillsGridColumn(.trailing)
                    }
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(d.activity) { a in
                        GridRow {
                            Text(shortDay(a.date)).gridColumnAlignment(.leading)
                            Text(a.description).gridColumnAlignment(.leading)
                            Text(money2(a.total))
                            Text(a.principal != 0 ? money2(a.principal) : "—")
                            Text(a.interest != 0 ? money2(a.interest) : "—")
                            if escrow { Text(a.escrow != 0 ? money2(a.escrow) : "—") }
                            if other { Text(a.other != 0 ? money2(a.other) : "—") }
                            Text(shortDay(a.statementDate)).foregroundStyle(.secondary).fillsGridColumn(.trailing)
                        }
                        .monospacedDigit()
                    }
                }
                .font(.callout)
            }
        }
    }

    private func checksBox(_ d: LoanDetail) -> some View {
        Box(title: "Paid from Checking", symbol: "checkmark.rectangle.stack", help: "The check register's payments to this loan's target accounts (the last three years), each matched to the lender's activity on a statement: the same total within five days. A payment no statement shows yet is newer than the latest statement, or its statement wasn't imported.") {
            if d.loan.paymentPayees.isEmpty {
                Text("Choose the target accounts the check register pays this loan with in Edit… to see its checks here.").foregroundStyle(.secondary)
            } else if d.checks.isEmpty {
                Text("No check to \((d.loan.payees ?? []).map(\.name).joined(separator: " or ")) in the last three years.").foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
                    GridRow {
                        Text("Date"); Text("Target account"); Text("Amount").gridColumnAlignment(.trailing); Text("On the lender's statement").fillsGridColumn()
                    }
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(d.checks) { c in
                        GridRow {
                            Text(shortDay(c.date))
                            Text(c.payee).foregroundStyle(.secondary)
                            Text(money2(c.amount)).monospacedDigit()
                            Group {
                                if let on = c.onStatement {
                                    Label("applied \(shortDay(on))", systemImage: "checkmark").foregroundStyle(.green)
                                } else if let s = d.statements.first, c.date > s.statementDate {
                                    Label("after the latest statement", systemImage: "clock").foregroundStyle(.secondary)
                                } else {
                                    Label("no statement shows it: import its statement", systemImage: "questionmark.circle").foregroundStyle(.orange)
                                }
                            }
                            .fillsGridColumn()
                        }
                    }
                }
                .font(.callout)
            }
        }
    }

    // MARK: Loading and saving

    private func reload() async {
        busy = true
        defer { busy = false }
        do {
            list = try await LoanClient.list()
            if !(list?.loans ?? []).contains(where: { $0.code == selected }) { selected = list?.loans.first?.code ?? "" }
            problem = nil
            await refresh()
        } catch {
            problem = describe(error)
        }
    }

    private func refresh() async {
        guard !selected.isEmpty else { detail = nil; return }
        do {
            detail = try await LoanClient.detail(selected, extra: tried)
            problem = nil
        } catch {
            problem = describe(error)
        }
    }

    @discardableResult
    private func run(_ change: () async throws -> LoanDetail) async -> String? {
        busy = true
        defer { busy = false }
        do {
            detail = try await change()
            if let t = tried { detail = try? await LoanClient.detail(selected, extra: t) }
            message = nil
            return nil
        } catch {
            message = describe(error)
            return describe(error)
        }
    }

    private func tryExtra() async {
        let t = extraText.replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)
        guard let v = Double(t.isEmpty ? "0" : t), v >= 0 else { message = "The extra principal is an amount, like 500"; return }
        tried = v
        await refresh()
    }

    private func keepExtra(_ v: Double) async {
        guard let l = detail?.loan else { return }
        var body = Self.body(of: l)
        body["extraPrincipal"] = v
        do {
            list = try await LoanClient.save(l.code, body)
            tried = nil
            extraText = ""
            await refresh()
        } catch { message = describe(error) }
    }

    /// The loan as the save endpoint takes it, unchanged.
    static func body(of l: LoanAccount) -> [String: Any] {
        ["version": l.version, "name": l.name, "kind": l.kind, "lender": l.lender ?? "", "last4": l.last4 ?? "",
         "collateral": l.collateral ?? "", "originalAmount": l.originalAmount ?? NSNull(), "interestRate": l.interestRate ?? NSNull(),
         "termMonths": l.termMonths ?? NSNull(), "firstPaymentDate": l.firstPaymentDate ?? NSNull(), "maturityDate": l.maturityDate ?? NSNull(),
         "paymentAmount": l.paymentAmount ?? NSNull(), "escrowAmount": l.escrowAmount, "extraPrincipal": l.extraPrincipal,
         "paymentPayees": l.paymentPayees, "statementFolder": l.statementFolder ?? "", "interestDeductible": l.interestDeductible,
         "status": l.status, "paidOffDate": l.paidOffDate ?? NSNull(), "notes": l.notes ?? ""]
    }

    private func remove() async {
        guard let l = detail?.loan else { return }
        busy = true
        defer { busy = false }
        do {
            list = try await LoanClient.remove(l.code)
            detail = nil
            selected = list?.loans.first?.code ?? ""
            message = "Removed \(l.name): its PDFs are still in \(l.folder ?? "its folder")"
            await refresh()
        } catch { message = describe(error) }
    }

    private func importStatements() {
        guard let l = detail?.loan else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.message = "The lender's billing statements (PDF), or a folder of them"
        if let f = l.folder { panel.directoryURL = URL(fileURLWithPath: f) }
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { await read(urls, code: l.code) }
    }

    /// Reads the PDFs picked (a folder's too) with PDFKit and sends them to the service six at a time.
    private func read(_ urls: [URL], code: String) async {
        busy = true
        defer { busy = false }
        var pdfs: [URL] = []
        for u in urls {
            if (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                let items = (try? FileManager.default.contentsOfDirectory(at: u, includingPropertiesForKeys: nil)) ?? []
                pdfs += items.filter { $0.pathExtension.lowercased() == "pdf" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            } else {
                pdfs.append(u)
            }
        }
        var results: [LoanDetail.Imported] = []
        for start in stride(from: 0, to: pdfs.count, by: 6) {
            let part = pdfs[start..<min(start + 6, pdfs.count)]
            message = "Reading \(start + 1)–\(start + part.count) of \(pdfs.count)…"
            var files: [[String: Any]] = []
            for u in part {
                guard let data = try? Data(contentsOf: u), let doc = PDFDocument(data: data) else {
                    results.append(.init(fileName: u.lastPathComponent, status: "refused", message: "it couldn't be opened as a PDF"))
                    continue
                }
                files.append(["fileName": u.lastPathComponent, "text": doc.string ?? "", "pdf": data.base64EncodedString()])
            }
            guard !files.isEmpty else { continue }
            do {
                let d = try await LoanClient.importStatements(code, files)
                detail = d
                results += d.imported ?? []
            } catch {
                problem = describe(error)
                break
            }
        }
        notRead = results.filter { $0.status != "read" }
        let count = { (s: String) in results.filter { $0.status == s }.count }
        message = "\(count("read")) read" + (count("already") > 0 ? " · \(count("already")) read before" : "") + (count("refused") > 0 ? " · \(count("refused")) not read" : "")
        list = try? await LoanClient.list()
        if tried != nil { await refresh() }
    }
}

// MARK: - The loan's sheet

struct LoanSheet: View {
    let loan: LoanAccount?
    var payees: [LoanPayee]
    var defaultFolder: String
    var save: (String, [String: Any]) async -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var kind: LoanKind
    @State private var code = ""
    @State private var codeTyped = false
    @State private var name = ""
    @State private var lender = ""
    @State private var last4 = ""
    @State private var collateral = ""
    @State private var originalAmount: Double?
    @State private var interestRate: Double?
    @State private var termMonths: Int?
    @State private var firstPayment: Date?
    @State private var maturity: Date?
    @State private var payment: Double?
    @State private var escrow = 0.0
    @State private var extra = 0.0
    @State private var chosen = Set<Int>()
    @State private var search = ""
    @State private var folder = ""
    @State private var deductible = true
    @State private var paidOff = false
    @State private var paidOffDate: Date?
    @State private var notes = ""
    @State private var error: String?
    @State private var saving = false

    init(loan: LoanAccount?, kind: LoanKind, payees: [LoanPayee], defaultFolder: String, save: @escaping (String, [String: Any]) async -> String?) {
        self.loan = loan
        self.payees = payees
        self.defaultFolder = defaultFolder
        self.save = save
        _kind = State(initialValue: kind)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(loan == nil ? "New \(kind.title)" : "Edit \(loan!.name)").heading(.heading)
            if loan == nil {
                Picker("", selection: $kind) {
                    ForEach(LoanKind.allCases) { k in Label(k.title, systemImage: k.symbol).tag(k) }
                }
                .pickerStyle(.segmented).labelsHidden()
                Text(kind.detail).font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                Form {
                    Section("The loan") {
                        TextField("Name", text: $name, prompt: Text(kind == .mortgage ? "Wells Fargo Mortgage" : "Honda Odyssey Loan"))
                            .onChange(of: name) { if loan == nil && !codeTyped { code = Self.code(from: name) } }
                        TextField("Code", text: Binding(get: { code }, set: { code = $0.uppercased(); codeTyped = true }))
                            .disabled(loan != nil)
                            .help("A short name for it: letters, digits, _ or - (WF_MORTGAGE)")
                        TextField("Lender", text: $lender, prompt: Text("a statement fills it in"))
                        TextField("Last four digits", text: $last4, prompt: Text("of the loan number"))
                            .help("Statements for another loan number are refused. Never the whole number.")
                        TextField(kind.collateralLabel, text: $collateral, prompt: Text(kind.collateralPrompt))
                    }
                    Section("Terms (a statement fills in what's empty)") {
                        TextField("Amount borrowed", value: $originalAmount, format: .number.precision(.fractionLength(2)))
                        TextField("Interest rate %", value: $interestRate, format: .number.precision(.fractionLength(3)))
                        TextField("Term in months", value: $termMonths, format: .number)
                            .help("360 for 30 years, 180 for 15, 72 for a six-year car loan")
                        OptionalDate(label: "First payment", date: $firstPayment)
                        OptionalDate(label: "Maturity", date: $maturity)
                        TextField("Principal and interest", value: $payment, format: .number.precision(.fractionLength(2)))
                            .help("The scheduled monthly payment, escrow aside")
                        TextField("Escrow each month", value: $escrow, format: .number.precision(.fractionLength(2)))
                            .help("What the lender collects for property taxes and insurance, when it keeps an escrow account")
                        TextField("Extra principal each month", value: $extra, format: .number.precision(.fractionLength(2)))
                            .help("What the forecast assumes you pay on top, each month")
                    }
                    Section("Paid from checking as") {
                        TextField("Find a target account", text: $search)
                        ScrollView {
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(shownPayees) { p in
                                    Toggle(p.name, isOn: Binding(get: { chosen.contains(p.id) }, set: { if $0 { chosen.insert(p.id) } else { chosen.remove(p.id) } }))
                                        .toggleStyle(.checkbox)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(height: 110)
                        Text("The target accounts the check register pays this loan with — two when the servicer changed (Mortgage, then Wells Fargo). Their checks show on the loan, matched to the statements.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Section("Statements and taxes") {
                        HStack {
                            TextField("Statements folder", text: $folder, prompt: Text(defaultFolderFor))
                            Button("Choose…") { chooseFolder() }
                        }
                        .help("Where Import Statements… keeps each statement's PDF")
                        Toggle("Its interest is deductible (Year-End Tax lists it)", isOn: $deductible)
                        Toggle("Paid off", isOn: $paidOff)
                        if paidOff { OptionalDate(label: "Paid off on", date: $paidOffDate) }
                        TextField("Notes", text: $notes, axis: .vertical).lineLimit(1...3)
                    }
                }
                .formStyle(.grouped)
            }
            .frame(height: 470)
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(loan == nil ? "Add" : "Save") { Task { await submit() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving || code.isEmpty || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 540)
        .onAppear(perform: fill)
        .onChange(of: kind) { if loan == nil { deductible = kind == .mortgage } }
    }

    private var defaultFolderFor: String { (defaultFolder as NSString).appendingPathComponent(code.isEmpty ? "CODE" : code) }

    /// The target accounts chosen first, then the rest the search finds.
    private var shownPayees: [LoanPayee] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let mine = payees.filter { chosen.contains($0.id) }
        let rest = payees.filter { !chosen.contains($0.id) && (q.isEmpty || $0.name.lowercased().contains(q)) }
        return mine + rest
    }

    static func code(from name: String) -> String {
        let s = name.uppercased().map { $0.isLetter || $0.isNumber ? String($0) : "_" }.joined()
        return String(s.split(separator: "_").joined(separator: "_").prefix(40))
    }

    private func fill() {
        guard let l = loan else { deductible = kind == .mortgage; return }
        code = l.code; name = l.name; lender = l.lender ?? ""; last4 = l.last4 ?? ""; collateral = l.collateral ?? ""
        originalAmount = l.originalAmount; interestRate = l.interestRate; termMonths = l.termMonths
        firstPayment = l.firstPaymentDate.flatMap { isoDay.date(from: $0) }; maturity = l.maturityDate.flatMap { isoDay.date(from: $0) }
        payment = l.paymentAmount; escrow = l.escrowAmount; extra = l.extraPrincipal; chosen = Set(l.paymentPayees)
        folder = l.statementFolder ?? ""; deductible = l.interestDeductible; paidOff = l.status == "paid_off"
        paidOffDate = l.paidOffDate.flatMap { isoDay.date(from: $0) }; notes = l.notes ?? ""
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = "The folder the loan's statement PDFs are kept in"
        if panel.runModal() == .OK, let url = panel.url { folder = url.path }
    }

    private func submit() async {
        saving = true
        defer { saving = false }
        let day = { (d: Date?) -> Any in d.map { isoDay.string(from: $0) } ?? NSNull() }
        let body: [String: Any] = [
            "version": loan?.version ?? 0, "name": name, "kind": kind.rawValue, "lender": lender, "last4": last4, "collateral": collateral,
            "originalAmount": originalAmount ?? NSNull(), "interestRate": interestRate ?? NSNull(), "termMonths": termMonths ?? NSNull(),
            "firstPaymentDate": day(firstPayment), "maturityDate": day(maturity), "paymentAmount": payment ?? NSNull(),
            "escrowAmount": escrow, "extraPrincipal": extra, "paymentPayees": chosen.sorted(), "statementFolder": folder,
            "interestDeductible": deductible, "status": paidOff ? "paid_off" : "open", "paidOffDate": paidOff ? day(paidOffDate) : NSNull(),
            "notes": notes]
        if let e = await save(code, body) { error = e } else { dismiss() }
    }
}

// MARK: - Form 1098

/// The lender's Form 1098 for a loan and year: what Year-End Tax counts instead of the estimate.
struct Form1098Sheet: View {
    let loan: LoanAccount
    let year: LoanYear
    var save: ([String: Any]) async -> String?
    var remove: () async -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var interest: Double?
    @State private var points = 0.0
    @State private var insurance = 0.0
    @State private var propertyTax = 0.0
    @State private var notes = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Form 1098 for \(String(year.year)): \(loan.name)").heading(.heading)
            Text("From the lender's Form 1098 (Mortgage Interest Statement), sent in January. Until it is entered, Year-End Tax counts the estimate: \(money2(year.estimate)) (statements \(money2(year.statementsInterest))\(year.forecastPayments > 0 ? " + forecast \(money2(year.forecastInterest))" : "")).")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Form {
                TextField("Box 1 · Mortgage interest received", value: $interest, format: .number.precision(.fractionLength(2)))
                TextField("Box 6 · Points paid on purchase", value: $points, format: .number.precision(.fractionLength(2)))
                TextField("Box 5 · Mortgage insurance premiums", value: $insurance, format: .number.precision(.fractionLength(2)))
                TextField("Box 10 · Property tax (paid from escrow)", value: $propertyTax, format: .number.precision(.fractionLength(2)))
                TextField("Notes", text: $notes, axis: .vertical).lineLimit(1...3)
            }
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                if year.form1098 != nil {
                    Button("Remove", role: .destructive) {
                        Task { if let e = await remove() { error = e } else { dismiss() } }
                    }
                    .help("Take the Form 1098 off: the year counts the estimate again")
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    Task {
                        let body: [String: Any] = ["interestPaid": interest ?? 0, "pointsPaid": points, "mortgageInsurance": insurance,
                                                   "propertyTax": propertyTax, "notes": notes]
                        if let e = await save(body) { error = e } else { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(interest == nil)
            }
        }
        .padding(18)
        .frame(width: 470)
        .onAppear {
            if let f = year.form1098 {
                interest = f.interestPaid; points = f.pointsPaid; insurance = f.mortgageInsurance; propertyTax = f.propertyTax; notes = f.notes ?? ""
            }
        }
    }
}
