//
//  ReportSources.swift
//  MxAcctMGR
//
//  The real reports behind the walkthroughs: for each one, the publisher's own pages — the latest release, its
//  release schedule — and where its history is kept (FRED, the St. Louis Fed's database, for the economic series).
//  The walkthroughs teach with illustrative numbers; these links go to the actual source. Every address was checked
//  in a browser on 2026-10-22 (several sites refuse command-line requests); a publisher may move a page later.
//

import Foundation

nonisolated struct ReportSource: Hashable, Sendable, Identifiable {
    enum Kind: String, Hashable, Sendable {
        case release = "Latest release", schedule = "Release schedule", history = "History", live = "Live data"

        var symbol: String {
            switch self {
            case .release: "doc.richtext"
            case .schedule: "calendar"
            case .history: "chart.xyaxis.line"
            case .live: "dot.radiowaves.left.and.right"
            }
        }
    }

    var kind: Kind
    /// Who publishes it: BLS, the Fed, BEA…
    var publisher: String
    var title: String
    var address: String

    var id: String { address }
    var url: URL { URL(string: address)! }

    static func release(_ publisher: String, _ title: String, _ address: String) -> ReportSource { ReportSource(kind: .release, publisher: publisher, title: title, address: address) }
    static func schedule(_ publisher: String, _ title: String, _ address: String) -> ReportSource { ReportSource(kind: .schedule, publisher: publisher, title: title, address: address) }
    static func history(_ publisher: String, _ title: String, _ address: String) -> ReportSource { ReportSource(kind: .history, publisher: publisher, title: title, address: address) }
    static func live(_ publisher: String, _ title: String, _ address: String) -> ReportSource { ReportSource(kind: .live, publisher: publisher, title: title, address: address) }

    private static func fred(_ title: String, _ series: String) -> ReportSource {
        .history("FRED (St. Louis Fed)", title, "https://fred.stlouisfed.org/series/" + series)
    }

    /// By MarketReport.id.
    static let byReport: [String: [ReportSource]] = [
        "jobs": [
            .release("BLS", "The Employment Situation", "https://www.bls.gov/news.release/empsit.nr0.htm"),
            .schedule("BLS", "Employment Situation release dates", "https://www.bls.gov/schedule/news_release/empsit.htm"),
            fred("Nonfarm payrolls (PAYEMS)", "PAYEMS"),
            fred("Unemployment rate (UNRATE)", "UNRATE"),
        ],
        "cpi": [
            .release("BLS", "Consumer Price Index", "https://www.bls.gov/news.release/cpi.nr0.htm"),
            .schedule("BLS", "CPI release dates", "https://www.bls.gov/schedule/news_release/cpi.htm"),
            fred("Core CPI, less food and energy (CPILFESL)", "CPILFESL"),
        ],
        "ppi": [
            .release("BLS", "Producer Price Index", "https://www.bls.gov/news.release/ppi.nr0.htm"),
            .schedule("BLS", "PPI release dates", "https://www.bls.gov/schedule/news_release/ppi.htm"),
            fred("PPI final demand (PPIFIS)", "PPIFIS"),
        ],
        "fomc": [
            .release("Federal Reserve", "FOMC meeting calendar, statements, projections and minutes", "https://www.federalreserve.gov/monetarypolicy/fomccalendars.htm"),
            .release("Federal Reserve", "Press releases", "https://www.federalreserve.gov/newsevents/pressreleases.htm"),
            .live("CME Group", "FedWatch: market odds for the next meetings", "https://www.cmegroup.com/markets/interest-rates/cme-fedwatch-tool.html"),
            fred("Fed funds target, upper limit (DFEDTARU)", "DFEDTARU"),
        ],
        "gdp": [
            .release("BEA", "Gross Domestic Product", "https://www.bea.gov/data/gdp/gross-domestic-product"),
            .schedule("BEA", "Release schedule", "https://www.bea.gov/news/schedule"),
            fred("Real GDP growth, annualised (A191RL1Q225SBEA)", "A191RL1Q225SBEA"),
        ],
        "ism-manufacturing": [
            .release("ISM", "PMI Reports: Manufacturing (latest and past month)", "https://www.ismworld.org/supply-management-news-and-reports/reports/ism-pmi-reports/"),
        ],
        "ism-services": [
            .release("ISM", "PMI Reports: Services (latest and past month)", "https://www.ismworld.org/supply-management-news-and-reports/reports/ism-pmi-reports/"),
        ],
        "retail-sales": [
            .release("U.S. Census Bureau", "Advance Monthly Retail Trade", "https://www.census.gov/retail/sales.html"),
            .schedule("U.S. Census Bureau", "Economic indicator calendar", "https://www.census.gov/economic-indicators/calendar-listview.html"),
            fred("Advance retail sales (RSAFS)", "RSAFS"),
        ],
        "earnings": [
            .live("Nasdaq.com", "Earnings calendar", "https://www.nasdaq.com/market-activity/earnings"),
            .release("SEC EDGAR", "Company filings: 10-Q, 10-K and 8-K earnings releases (full-text search)", "https://www.sec.gov/edgar/search/"),
        ],
        "revisions": [
            .release("FactSet", "Earnings Insight: weekly estimate revisions and S&P 500 earnings", "https://insight.factset.com/topic/earnings"),
        ],
        "cot": [
            .release("CFTC", "Commitments of Traders", "https://www.cftc.gov/MarketReports/CommitmentsofTraders/index.htm"),
            .schedule("CFTC", "Release schedule", "https://www.cftc.gov/MarketReports/CommitmentsofTraders/ReleaseSchedule/index.htm"),
        ],
        "fund-flows": [
            .release("ICI", "Weekly combined estimated ETF and long-term fund flows", "https://www.ici.org/research/statistics/etfs/weekly-combined-estimated-etf-and-longterm-flows"),
            .release("ICI", "Weekly money market fund assets", "https://www.ici.org/weekly-money-market-mutual-fund-assets"),
        ],
        "auctions": [
            .release("TreasuryDirect", "Auction results", "https://www.treasurydirect.gov/auctions/auction-results/"),
            .schedule("TreasuryDirect", "Auction announcements (upcoming auctions)", "https://www.treasurydirect.gov/auctions/auction-announcements/"),
            .history("TreasuryDirect", "Auction query: every past auction", "https://www.treasurydirect.gov/auctions/auction-query/"),
        ],
        "yield-curve": [
            .live("U.S. Treasury", "Daily Treasury par yield curve rates", "https://home.treasury.gov/resource-center/data-chart-center/interest-rates/TextView?type=daily_treasury_yield_curve"),
            fred("10-year minus 2-year spread (T10Y2Y)", "T10Y2Y"),
            fred("10-year minus 3-month spread (T10Y3M)", "T10Y3M"),
        ],
        "semiconductors": [
            .release("SIA", "Semiconductor Industry Association news: monthly global chip sales", "https://www.semiconductors.org/news-events/latest-news/"),
            .release("WSTS", "World Semiconductor Trade Statistics", "https://www.wsts.org/"),
        ],
        "banks": [
            .release("FDIC", "Quarterly Banking Profile", "https://www.fdic.gov/quarterly-banking-profile"),
            .release("Federal Reserve", "H.8 Assets and Liabilities of Commercial Banks (weekly)", "https://www.federalreserve.gov/releases/h8/current/default.htm"),
            .history("Federal Reserve", "Charge-off and delinquency rates", "https://www.federalreserve.gov/releases/chargeoff/"),
        ],
        "housing": [
            .release("U.S. Census Bureau", "New Residential Construction: starts and permits", "https://www.census.gov/construction/nrc/index.html"),
            .release("U.S. Census Bureau", "New Residential Sales", "https://www.census.gov/construction/nrs/index.html"),
            .release("National Association of Realtors", "Existing-home sales", "https://www.nar.realtor/research-and-statistics/housing-statistics/existing-home-sales"),
            .live("Freddie Mac", "Primary Mortgage Market Survey: weekly mortgage rates", "https://www.freddiemac.com/pmms"),
            fred("Housing starts (HOUST)", "HOUST"),
        ],
        "energy": [
            .release("EIA", "Weekly Petroleum Status Report", "https://www.eia.gov/petroleum/supply/weekly/"),
            .schedule("EIA", "Release schedule", "https://www.eia.gov/petroleum/supply/weekly/schedule.php"),
            .release("EIA", "Short-Term Energy Outlook (monthly)", "https://www.eia.gov/outlooks/steo/"),
        ],
    ]
}

extension MarketReport {
    /// The publisher's own pages for the real report: the latest release first.
    nonisolated var sources: [ReportSource] { ReportSource.byReport[id] ?? [] }
}
