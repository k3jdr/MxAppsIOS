//
//  SampleJobspace.swift
//  MxJobsWMS
//
//  File ▸ New Sample Jobspace: a daily market data refresh across the three layers,
//  wired to a few public market data APIs.
//

import Foundation

nonisolated extension Jobspace {
    static func sample() -> Jobspace {
        var space = Jobspace()
        space.name = "Daily Market Data Refresh"
        space.description = "Weekday morning refresh: agents gather quotes, FX, news and filings through the data layer, "
            + "assemble rebalance instructions for approval, then execute and report the outcome."

        // Layer 3 configuration: subscriptions
        var alpha = ApiSubscription()
        alpha.name = "Alpha Vantage"
        alpha.provider = "Alpha Vantage Inc."
        alpha.baseURL = "https://www.alphavantage.co"
        alpha.auth = .queryParameter
        alpha.keyName = "apikey"
        alpha.rateLimitPerMinute = 5
        alpha.plan = "Free"
        alpha.docsURL = "https://www.alphavantage.co/documentation/"

        var finnhub = ApiSubscription()
        finnhub.name = "Finnhub"
        finnhub.provider = "Finnhub.io"
        finnhub.baseURL = "https://finnhub.io/api/v1"
        finnhub.auth = .header
        finnhub.keyName = "X-Finnhub-Token"
        finnhub.rateLimitPerMinute = 60
        finnhub.plan = "Free"
        finnhub.docsURL = "https://finnhub.io/docs/api"

        var frankfurter = ApiSubscription()
        frankfurter.name = "Frankfurter FX"
        frankfurter.provider = "ECB reference rates"
        frankfurter.baseURL = "https://api.frankfurter.dev/v1"
        frankfurter.auth = .none
        frankfurter.keyName = ""
        frankfurter.docsURL = "https://frankfurter.dev"

        var edgar = ApiSubscription()
        edgar.name = "SEC EDGAR"
        edgar.provider = "U.S. SEC"
        edgar.baseURL = "https://data.sec.gov"
        edgar.auth = .none
        edgar.keyName = ""
        edgar.rateLimitPerMinute = 600
        edgar.docsURL = "https://www.sec.gov/search-filings/edgar-application-programming-interfaces"
        edgar.defaultHeaders = [KeyValue("User-Agent", "MxJobsWMS your-name@example.com")]
        edgar.notes = "SEC asks every client to send a User-Agent naming the requester."

        space.subscriptions = [alpha, finnhub, frankfurter, edgar]

        let y1 = Double(Metrics.laneCenter(.operations))
        let y2 = Double(Metrics.laneCenter(.agents))
        let y3 = Double(Metrics.laneCenter(.data))

        // Layer 1
        var trigger = JobNode(kind: .trigger, title: "Morning refresh", x: 400, y: y1)
        trigger.arguments = [Argument("watchlist", "AAPL,MSFT,NVDA", type: .symbols, required: true)]
        trigger.outcome.description = "Refresh run started for the watchlist"
        trigger.outcome.outputName = "run"

        var assemble = JobNode(kind: .instructionSet, title: "Assemble rebalance instructions", x: 1320, y: y1)
        assemble.agent?.instructions = "Combine the analyst view with current holdings into a list of instructions "
            + "(symbol, action, quantity, limit price, rationale). Flag anything outside the risk limits."
        assemble.agent?.outputFormat = "JSON array of instructions"
        assemble.outcome.outputName = "instructions"
        assemble.outcome.description = "At least one instruction, or an explicit 'no action' note"

        var approve = JobNode(kind: .approvalGate, title: "Approve instructions", x: 1580, y: y1)
        approve.approval?.approver = "Portfolio owner"
        approve.approval?.summaryTemplate = "{{instructions.count}} instructions ready for {{today}}"
        approve.outcome.outputName = "approved"

        var execute = JobNode(kind: .executeRequest, title: "Submit approved instructions", x: 1840, y: y1)
        execute.execution?.target = "Broker API (paper)"
        execute.execution?.mode = .paper
        execute.outcome.outputName = "executions"

        var report = JobNode(kind: .outcomeReport, title: "Daily outcome report", x: 2100, y: y1)
        report.report?.recipients = "me"
        report.outcome.description = "Report delivered with fills, rejects and data gaps"

        // Layer 2
        var marketAgent = JobNode(kind: .agentTask, title: "Market data agent", x: 540, y: y2)
        marketAgent.agent?.instructions = "Fetch the latest quote for every watchlist symbol and the USD FX rates."
        marketAgent.agent?.inputs = ["run"]
        marketAgent.outcome.outputName = "prices"

        var newsAgent = JobNode(kind: .agentTask, title: "News & filings agent", x: 1020, y: y2)
        newsAgent.agent?.instructions = "Collect yesterday's company news and the latest SEC filings for each symbol; "
            + "summarise anything that could move the price."
        newsAgent.agent?.inputs = ["run"]
        newsAgent.outcome.outputName = "events"

        var analyst = JobNode(kind: .aggregate, title: "Portfolio analyst", x: 1320, y: y2)
        analyst.agent?.instructions = "Merge prices and events into a per-symbol view with a suggested action."
        analyst.agent?.inputs = ["prices", "events"]
        analyst.outcome.outputName = "analysis"

        // Layer 3
        var quotes = JobNode(kind: .apiRead, title: "Global quote", x: 320, y: y3)
        quotes.api?.subscriptionID = alpha.id
        quotes.api?.path = "/query"
        quotes.api?.query = [KeyValue("function", "GLOBAL_QUOTE"), KeyValue("symbol", "{{symbol}}")]
        quotes.arguments = [Argument("symbol", "IBM", type: .symbols, required: true)]
        quotes.outcome.requiredFields = ["Global Quote.05. price"]
        quotes.outcome.outputName = "quote"
        quotes.exceptions.onFailure = .useFallback
        quotes.exceptions.fallbackValue = "previous close"

        var fx = JobNode(kind: .apiRead, title: "USD FX rates", x: 800, y: y3)
        fx.api?.subscriptionID = frankfurter.id
        fx.api?.path = "/latest"
        fx.api?.query = [KeyValue("base", "USD"), KeyValue("symbols", "EUR,GBP,JPY")]
        fx.outcome.requiredFields = ["rates.EUR"]
        fx.outcome.outputName = "fx"

        var news = JobNode(kind: .apiRead, title: "Company news", x: 1040, y: y3)
        news.api?.subscriptionID = finnhub.id
        news.api?.path = "/company-news"
        news.api?.query = [KeyValue("symbol", "{{symbol}}"), KeyValue("from", "{{yesterday}}"), KeyValue("to", "{{today}}")]
        news.arguments = [Argument("symbol", "AAPL", type: .symbols, required: true)]
        news.outcome.outputName = "news"
        news.exceptions.onFailure = .skip

        var filings = JobNode(kind: .apiRead, title: "Recent filings", x: 1280, y: y3)
        filings.api?.subscriptionID = edgar.id
        filings.api?.path = "/submissions/CIK{{cik}}.json"
        filings.arguments = [Argument("cik", "0000320193", required: true)]
        filings.outcome.requiredFields = ["filings.recent.form"]
        filings.outcome.outputName = "filings"
        filings.exceptions.onFailure = .skip

        var normalize = JobNode(kind: .dataNormalize, title: "Normalize quotes", x: 560, y: y3)
        normalize.transform?.mappings = [KeyValue("price", "Global Quote.05. price"),
                                         KeyValue("change", "Global Quote.10. change percent")]
        normalize.outcome.outputName = "quotes"

        space.nodes = [trigger, assemble, approve, execute, report,
                       marketAgent, newsAgent, analyst,
                       quotes, fx, news, filings, normalize]
        let pairs: [(JobNode, JobNode)] = [
            (trigger, marketAgent), (trigger, newsAgent),
            (marketAgent, quotes), (marketAgent, fx),
            (newsAgent, news), (newsAgent, filings),
            (quotes, normalize), (normalize, marketAgent),
            (marketAgent, analyst), (newsAgent, analyst),
            (analyst, assemble), (assemble, approve), (approve, execute), (execute, report),
        ]
        for (a, b) in pairs { space.addLink(from: a.id, to: b.id) }
        if let i = space.links.firstIndex(where: { $0.from == approve.id }) { space.links[i].label = "approved" }
        if let i = space.links.firstIndex(where: { $0.from == normalize.id }) { space.links[i].label = "quotes" }
        return space
    }
}
