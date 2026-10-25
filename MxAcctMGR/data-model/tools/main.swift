// Writes ../ddl/10_seed.sql from MxAcctMGR's own model. Run ./generate_seed.sh (compiles this with the app's model files).
import Foundation

// Writes pmg seed SQL from MxAcctMGR's own model (Universe, Samples, MarketReport.all, MarketHistory).
func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "''") + "'" }
func q(_ s: String?) -> String { s.map { q($0) } ?? "NULL" }
func n(_ x: Double) -> String { x.isFinite ? String(format: "%.17g", x) : "NULL" }
func n(_ x: Double?) -> String { x.map { n($0) } ?? "NULL" }
func rows(_ head: String, _ r: [String]) -> String { r.isEmpty ? "" : head + "\n" + r.map { "    (" + $0 + ")" }.joined(separator: ",\n") + ";\n" }
var out = ""
func emit(_ s: String) { out += s + "\n" }

let assetCode: [AssetClass: String] = [.equity: "equity", .bond: "bond", .cash: "cash"]
emit(rows("INSERT INTO pmg.asset_class (asset_class, title, sort_order) VALUES",
          AssetClass.allCases.enumerated().map { "\(q(assetCode[$1]!)), \(q($1.rawValue)), \($0 + 1)" }))
var sectorRows = Universe.sectors.enumerated().map { "\(q($1)), 'equity', \($0 + 1)" }
sectorRows += ["\(q(Universe.fixedIncome)), 'fixed_income', 12", "\(q(Universe.cashSector)), 'cash', 13", "\(q(Universe.fundSector)), 'fund', 14",
               "'Diversified Fund', 'fund', 15", "'Unclassified', 'other', 16", "'Unknown', 'other', 17"]
emit(rows("INSERT INTO pmg.sector (sector, sector_kind, sort_order) VALUES", sectorRows))
emit(rows("INSERT INTO pmg.model_parameter (name, value, description) VALUES", [
    "'risk_free', \(n(Universe.riskFree)), 'Risk-free rate (cash return), a year'",
    "'equity_premium', \(n(Universe.equityPremium)), 'Expected stock return over cash for beta 1, a year'",
    "'market_vol', \(n(Universe.marketVol)), 'Volatility of the equity-market factor, a year'",
    "'sector_vol', \(n(Universe.sectorVol)), 'Volatility of each sector factor, a year'",
    "'rate_vol', \(n(Universe.rateVol)), 'Volatility of the interest-rate factor (yield change), a year'"]))
let sleeveCode: [Sleeve: String] = [.stocks: "stocks", .single: "single", .bonds: "bonds", .cash: "cash"]
emit(rows("INSERT INTO pmg.sleeve (sleeve, title, sort_order) VALUES",
          Sleeve.allCases.map { "\(q(sleeveCode[$0]!)), \(q($0.title)), \($0.rawValue + 1)" }))
emit(rows("INSERT INTO pmg.price_driver (driver, title, symbol, sort_order) VALUES",
          Driver.allCases.enumerated().map { "\(q(String(describing: $1))), \(q($1.rawValue)), \(q($1.symbol)), \($0 + 1)" }))
emit(rows("INSERT INTO pmg.report_tier (tier, title, summary) VALUES",
          ReportTier.all.map { "\($0.id), \(q($0.title)), \(q($0.summary))" }))
emit(rows("INSERT INTO pmg.scenario (scenario, title, detail, sort_order) VALUES",
          Scenario.allCases.enumerated().map { "\(q(String(describing: $1))), \(q($1.rawValue)), \(q($1.detail)), \($0 + 1)" }))

// Universe
func kind(_ s: Security) -> String {
    if s.ticker == "CASH" { return "cash" }
    if s.lookThrough != nil { return "index_fund" }
    if s.assetClass == .bond { return s.coupon == nil ? "bond_fund" : "bond" }
    return "company"
}
emit(rows("INSERT INTO pmg.security (ticker, name, security_kind, sector, asset_class, price, beta, rate_beta, idio_vol, market_cap_bn, alpha, yield, fee) VALUES",
          Universe.all.map { s in "\(q(s.ticker)), \(q(s.name)), \(q(kind(s))), \(q(s.sector)), \(q(assetCode[s.assetClass]!)), \(n(s.price)), \(n(s.beta)), \(n(s.rateBeta)), \(n(s.idioVol)), \(n(s.marketCap)), \(n(s.alpha)), \(n(s.yield)), \(n(s.fee))" }))
emit(rows("INSERT INTO pmg.bond_terms (ticker, issuer_type, coupon, maturity, rating) VALUES",
          Universe.all.filter { $0.coupon != nil }.map { "\(q($0.ticker)), \(q($0.issuer!)), \(n($0.coupon!)), \(q($0.maturity!)), \(q($0.rating!))" }))
emit(rows("INSERT INTO pmg.fund_look_through (fund_ticker, member_ticker, weight) VALUES",
          Universe.funds.flatMap { f in f.lookThrough!.sorted { $0.key < $1.key }.map { "\(q(f.ticker)), \(q($0.key)), \(n($0.value))" } }))
emit(rows("INSERT INTO pmg.benchmark (code, name, summary) VALUES", Universe.benchmarks.map { "\(q($0.code)), \(q($0.name)), \(q($0.summary))" }))
emit(rows("INSERT INTO pmg.benchmark_weight (code, ticker, weight) VALUES",
          Universe.benchmarks.flatMap { b in b.weights.sorted { $0.key < $1.key }.map { "\(q(b.code)), \(q($0.key)), \(n($0.value))" } }))
emit(rows("INSERT INTO pmg.market_month (month, market_return, rate_change) VALUES",
          MarketHistory.months.indices.map { "'\(MarketHistory.months[$0])-01', \(n(MarketHistory.market[$0])), \(n(MarketHistory.rates[$0]))" }))
emit(rows("INSERT INTO pmg.security_month_return (ticker, month, total_return) VALUES",
          MarketHistory.months.indices.flatMap { t in Universe.base.indices.map { "\(q(Universe.base[$0].ticker)), '\(MarketHistory.months[t])-01', \(n(MarketHistory.returns[t][$0]))" } }))

// Accounts
let acctType: [AccountType: String] = [.taxable: "taxable", .retirement: "retirement", .roth: "roth"]
let style: [PortfolioStyle: String] = [.active: "active", .passive: "passive", .either: "either"]
let accounts = Samples.all + [Samples.myPortfolio]
func aid(_ p: Portfolio) -> String { p.id == "mine" ? "my-portfolio" : p.id }
emit(rows("INSERT INTO pmg.account (account_id, name, account_type, benchmark_code, style, is_sample, lesson, trading, symbol, sort_order) VALUES",
          accounts.enumerated().map { i, p in "\(q(aid(p))), \(q(p.name)), \(q(acctType[p.account]!)), \(q(p.benchmark)), \(q(style[p.style]!)), \(p.id != "mine"), \(q(p.lesson)), \(q(p.trading)), \(q(p.symbol)), \(i + 1)" }))
emit(rows("INSERT INTO pmg.account_look_for (account_id, ordinal, text) VALUES",
          accounts.flatMap { p in p.lookFor.enumerated().map { "\(q(aid(p))), \($0 + 1), \(q($1))" } }))
emit(rows("INSERT INTO pmg.holding (account_id, ticker, ordinal, value, quantity, unpriced) VALUES",
          accounts.flatMap { p in p.holdings.enumerated().map { "\(q(aid(p))), \(q($1.ticker)), \($0 + 1), \(n($1.value)), \(n($1.quantity)), \($1.unpriced)" } }))
emit(rows("INSERT INTO pmg.tax_lot (account_id, ticker, acquired, share, cost_basis) VALUES",
          accounts.flatMap { p in p.holdings.flatMap { h in h.lots.map { "\(q(aid(p))), \(q(h.ticker)), \(q($0.acquired)), \(n($0.share)), \(n($0.costBasis))" } } }))
emit(rows("INSERT INTO pmg.account_missing_return (account_id, ticker, from_month) VALUES",
          accounts.flatMap { p in p.missingFrom.sorted { $0.key < $1.key }.map { "\(q(aid(p))), \(q($0.key)), '\(MarketHistory.months[$0.value])-01'" } }))

// Reports
let after: [Reaction.After: String] = [.revert: "revert", .permanent: "permanent", .rebalanceToPlan: "rebalanceToPlan"]
let reports = MarketReport.all
emit(rows("INSERT INTO pmg.market_report (report_id, title, symbol, source, headline, tier, publisher, frequency, impact, top_five, market_move, rate_move, single_ticker, suggested_sample, sort_order) VALUES",
          reports.enumerated().map { i, r in "\(q(r.id)), \(q(r.title)), \(q(r.symbol)), \(q(r.source)), \(q(r.headline)), \(r.tier), \(q(r.publisher)), \(q(r.frequency)), \(r.impact), \(r.topFive.map(String.init) ?? "NULL"), \(n(r.marketMove)), \(n(r.rateMove)), \(q(r.single)), \(q(r.suggestedSample == "mine" ? "my-portfolio" : r.suggestedSample)), \(i + 1)" }))
var texts: [String] = []
for r in reports {
    for (list, items) in [("reading", r.reading), ("key_metric", r.keyMetrics), ("why_care", r.whyCare), ("takeaway", r.takeaways)] {
        texts += items.enumerated().map { "\(q(r.id)), '\(list)', \($0 + 1), \(q($1))" }
    }
}
emit(rows("INSERT INTO pmg.report_text (report_id, list, ordinal, text) VALUES", texts))
emit(rows("INSERT INTO pmg.report_line (report_id, ordinal, label, value, expected, meaning) VALUES",
          reports.flatMap { r in r.lines.enumerated().map { "\(q(r.id)), \($0 + 1), \(q($1.label)), \(q($1.value)), \(q($1.expected)), \(q($1.meaning))" } }))
emit(rows("INSERT INTO pmg.report_term (report_id, ordinal, term, definition) VALUES",
          reports.flatMap { r in r.terms.enumerated().map { "\(q(r.id)), \($0 + 1), \(q($1.term)), \(q($1.definition))" } }))
emit(rows("INSERT INTO pmg.report_asset_move (report_id, ordinal, asset, move, why) VALUES",
          reports.flatMap { r in r.moves.enumerated().map { "\(q(r.id)), \($0 + 1), \(q($1.asset)), \(q($1.move)), \(q($1.why))" } }))
emit(rows("INSERT INTO pmg.report_driver (report_id, driver, ordinal) VALUES",
          reports.flatMap { r in r.drivers.enumerated().map { "\(q(r.id)), \(q(String(describing: $1))), \($0 + 1)" } }))
emit(rows("INSERT INTO pmg.report_factor_move (report_id, factor, name, move) VALUES",
          reports.flatMap { r in r.sectorMoves.sorted { $0.key < $1.key }.map { "\(q(r.id)), 'sector', \(q($0.key)), \(n($0.value))" }
                              + r.companyMoves.sorted { $0.key < $1.key }.map { "\(q(r.id)), 'company', \(q($0.key)), \(n($0.value))" } }))
emit(rows("INSERT INTO pmg.report_context_series (report_id, title, unit, kind, reference, reference_label, note) VALUES",
          reports.compactMap { r in r.context.map { c in "\(q(r.id)), \(q(c.title)), \(q(c.unit)), \(q(c.kind == .bar ? "bar" : "line")), \(n(c.reference)), \(q(c.referenceLabel)), \(q(c.note))" } }))
emit(rows("INSERT INTO pmg.report_context_point (report_id, ordinal, label, value) VALUES",
          reports.flatMap { r in (r.context?.points ?? []).enumerated().map { "\(q(r.id)), \($0 + 1), \(q($1.label)), \(n($1.value))" } }))
emit(rows("INSERT INTO pmg.report_reaction (report_id, reaction_id, ordinal, title, symbol, summary, after, repeat_on_drawdown) VALUES",
          reports.flatMap { r in r.reactions.enumerated().map { "\(q(r.id)), \(q($1.id)), \($0 + 1), \(q($1.title)), \(q($1.symbol)), \(q($1.summary)), \(q(after[$1.after]!)), \(n($1.repeatOnDrawdown))" } }))
emit(rows("INSERT INTO pmg.reaction_move (report_id, reaction_id, ordinal, from_sleeve, to_sleeve, fraction) VALUES",
          reports.flatMap { r in r.reactions.flatMap { x in x.moves.enumerated().map { "\(q(r.id)), \(q(x.id)), \($0 + 1), \(q(sleeveCode[$1.from]!)), \(q(sleeveCode[$1.to]!)), \(n($1.fraction))" } } }))

let header = """
-- MxAcctMGR · pmg DDL package · 10 seed data (generated)
--
-- Generated from MxAcctMGR's own model (Universe.swift, Samples.swift, MarketHistory in
-- Attribution.swift, MarketReport.all in MarketReports.swift / ReportLibrary.swift, BehaviorLab.swift)
-- by compiling those files with a small dumper, so the rows are exactly what the app holds —
-- including the drifted-tracker sample and the monthly returns, which the app draws from seeded
-- random numbers. Regenerate it rather than editing it by hand (see README.md).
-- Illustrative only: none of these companies, prices, forecasts or releases are real.


"""
FileManager.default.createFile(atPath: CommandLine.arguments[1], contents: (header + out).data(using: .utf8))
print("reports \(reports.count), reactions \(reports.reduce(0) { $0 + $1.reactions.count }), accounts \(accounts.count), securities \(Universe.all.count)")
