//
//  SampleJobspace.swift
//  MxJobsMGR
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
        alpha.plan = "Free (25 requests a day)"
        alpha.docsURL = "https://www.alphavantage.co/documentation/"
        alpha.secureAccountName = "Alpha Vantage"   // linked once Secure Accounts has one of that name

        var finnhub = ApiSubscription()
        finnhub.name = "Finnhub"
        finnhub.provider = "Finnhub.io"
        finnhub.baseURL = "https://finnhub.io/api/v1"
        finnhub.auth = .header
        finnhub.keyName = "X-Finnhub-Token"
        finnhub.rateLimitPerMinute = 60
        finnhub.plan = "Free"
        finnhub.docsURL = "https://finnhub.io/docs/api"
        finnhub.secureAccountName = "Finnhub"

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
        edgar.defaultHeaders = [KeyValue("User-Agent", "MxJobsMGR your-name@example.com")]
        edgar.notes = "SEC asks every client to send a User-Agent naming the requester."

        let local = ApiSubscription.localService()

        // Java and C++ portfolio services (Services/portfolio-java, Services/portfolio-cpp).
        var javaService = ApiSubscription.localService(port: 8766)
        javaService.name = "Portfolio optimizer (Java)"
        javaService.projectFolder = "~/MyCodeGIT/MxAppsIOS/Services/portfolio-java"
        javaService.notes = "Start it with: python3 Services/mxservices.py start (builds it first if needed)"
        var cppService = ApiSubscription.localService(port: 8767)
        cppService.name = "Portfolio engine (C++)"
        cppService.projectFolder = "~/MyCodeGIT/MxAppsIOS/Services/portfolio-cpp"
        cppService.notes = "Start it with: python3 Services/mxservices.py start (builds it first if needed)"

        space.subscriptions = [alpha, finnhub, frankfurter, edgar, local, javaService, cppService]

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

        // Python at Layer 3: indicators from the local Python service (Services/market-sample),
        // scored by a Python Script step.
        var indicators = JobNode(kind: .apiRead, title: "Indicators (local Python)", x: 1520, y: y3)
        indicators.api?.subscriptionID = local.id
        indicators.api?.path = "/indicators"
        indicators.api?.query = [KeyValue("symbol", "{{symbol}}"), KeyValue("window", "{{window}}")]
        indicators.arguments = [Argument("symbol", "AAPL", type: .symbols, required: true),
                                Argument("window", "14", type: .number)]
        indicators.outcome.requiredFields = ["rsi", "sma"]
        indicators.outcome.outputName = "indicators"
        indicators.exceptions.onFailure = .escalateToUser
        indicators.notes = "Start the services first: python3 Services/mxservices.py start"

        var score = JobNode(kind: .pythonScript, title: "Score signals (Python)", x: 1760, y: y3)
        score.script?.code = Self.scoreSignalsScript
        score.arguments = [Argument("oversold", "30", type: .number), Argument("overbought", "70", type: .number)]
        score.outcome.requiredFields = ["signal"]
        score.outcome.outputName = "signals"
        score.outcome.description = "buy / hold / sell from the RSI and the trend against the moving average"

        // Portfolio optimization at Layer 3 (Java and C++ services) giving the Layer 2 decision its context.
        var optimize = JobNode(kind: .apiRead, title: "Optimize portfolio (Java)", x: 2000, y: y3)
        optimize.api?.subscriptionID = javaService.id
        optimize.api?.method = .POST
        optimize.api?.path = "/optimize"
        optimize.api?.body = Self.optimizeBody
        optimize.arguments = [Argument("maxWeight", "0.4", type: .number, required: true),
                              Argument("riskFreeRate", "0.02", type: .number),
                              Argument("maxTurnover", "0.2", type: .number)]
        optimize.outcome.successStatus = "200"
        optimize.outcome.requiredFields = ["weights", "decisionContext.recommendation"]
        optimize.outcome.assertions = [ValueAssertion("solverStatus", .equals, "optimal"),
                                       ValueAssertion("schema", .equals, "mxjobs.optimization/1")]
        optimize.outcome.outputName = "optimization"
        optimize.outcome.description = "Max-Sharpe weights under the cap, with a decisionContext for the agent"
        optimize.exceptions.onFailure = .escalateToUser

        var risk = JobNode(kind: .apiRead, title: "Portfolio risk (C++)", x: 2240, y: y3)
        risk.api?.subscriptionID = cppService.id
        risk.api?.method = .POST
        risk.api?.path = "/risk"
        risk.api?.body = Self.riskBody
        risk.arguments = [Argument("portfolioValue", "1000000", type: .number, required: true),
                          Argument("maxVaR", "80000", type: .number)]
        risk.outcome.successStatus = "200"
        risk.outcome.requiredFields = ["valueAtRisk", "riskContributions"]
        risk.outcome.assertions = [ValueAssertion("status", .equals, "ok"),
                                   ValueAssertion("valueAtRisk", .less, "{{maxVaR}}")]
        risk.outcome.outputName = "risk"
        risk.outcome.description = "10-day 99% VaR of the current holdings within the limit"
        risk.exceptions.onFailure = .escalateToUser

        var decide = JobNode(kind: .decision, title: "Choose next step", x: 2120, y: y2)
        decide.agent?.instructions = "Follow optimization.decisionContext (rebalance, rebalance_partially, hold, "
            + "rerun_relaxed, escalate), and escalate when the risk step reports VaR above the limit."
        decide.agent?.inputs = ["optimization", "risk"]
        decide.agent?.outputFormat = "{nextStep, confidence, reason}"
        decide.outcome.outputName = "nextStep"

        space.nodes = [trigger, assemble, approve, execute, report,
                       marketAgent, newsAgent, analyst, decide,
                       quotes, fx, news, filings, normalize, indicators, score, optimize, risk]
        let pairs: [(JobNode, JobNode)] = [
            (trigger, marketAgent), (trigger, newsAgent),
            (marketAgent, quotes), (marketAgent, fx),
            (newsAgent, news), (newsAgent, filings),
            (quotes, normalize), (normalize, marketAgent),
            (marketAgent, indicators), (indicators, score), (score, marketAgent),
            (trigger, decide), (decide, optimize), (decide, risk), (optimize, decide), (risk, decide),
            (decide, assemble),
            (marketAgent, analyst), (newsAgent, analyst),
            (analyst, assemble), (assemble, approve), (approve, execute), (execute, report),
        ]
        for (a, b) in pairs { space.addLink(from: a.id, to: b.id) }
        if let i = space.links.firstIndex(where: { $0.from == approve.id }) { space.links[i].label = "approved" }
        if let i = space.links.firstIndex(where: { $0.from == normalize.id }) { space.links[i].label = "quotes" }
        if let i = space.links.firstIndex(where: { $0.from == score.id }) { space.links[i].label = "signals" }
        if let i = space.links.firstIndex(where: { $0.from == optimize.id }) { space.links[i].label = "decisionContext" }
        if let i = space.links.firstIndex(where: { $0.from == risk.id }) { space.links[i].label = "VaR" }
        if let i = space.links.firstIndex(where: { $0.from == decide.id && $0.to == assemble.id }) {
            space.links[i].label = "nextStep"
        }
        return space
    }

    /// The sample universe sent to the optimizer (Services/contracts/examples/optimize-request.json).
    static let optimizeBody = """
    {
      "assets": ["AAPL", "MSFT", "NVDA", "TLT"],
      "expectedReturns": [0.11, 0.10, 0.16, 0.04],
      "covariance": [[0.0625, 0.0300, 0.0450, -0.0040], [0.0300, 0.0484, 0.0400, -0.0030],
                     [0.0450, 0.0400, 0.1600, -0.0050], [-0.0040, -0.0030, -0.0050, 0.0196]],
      "objective": "max_sharpe",
      "riskFreeRate": {{riskFreeRate}},
      "maxWeight": {{maxWeight}},
      "currentWeights": {"AAPL": 0.25, "MSFT": 0.25, "NVDA": 0.25, "TLT": 0.25},
      "maxTurnover": {{maxTurnover}}
    }
    """

    /// Risk of the current holdings, 10 days at 99%.
    static let riskBody = """
    {
      "assets": ["AAPL", "MSFT", "NVDA", "TLT"],
      "weights": {"AAPL": 0.25, "MSFT": 0.25, "NVDA": 0.25, "TLT": 0.25},
      "expectedReturns": [0.11, 0.10, 0.16, 0.04],
      "covariance": [[0.0625, 0.0300, 0.0450, -0.0040], [0.0300, 0.0484, 0.0400, -0.0030],
                     [0.0450, 0.0400, 0.1600, -0.0050], [-0.0040, -0.0030, -0.0050, 0.0196]],
      "confidence": 0.99,
      "horizonDays": 10,
      "portfolioValue": {{portfolioValue}}
    }
    """

    /// The sample "Score signals" step.
    static let scoreSignalsScript = """
    import json, sys

    request = json.load(sys.stdin)
    args = request["arguments"]
    ind = request["inputs"].get("indicators", {})   # output of "Indicators (local Python)"

    rsi = ind.get("rsi")
    oversold = float(args.get("oversold", 30))
    overbought = float(args.get("overbought", 70))

    if rsi is None:
        signal = "unknown"
    elif rsi <= oversold:
        signal = "buy"
    elif rsi >= overbought:
        signal = "sell"
    else:
        signal = "hold"

    trend = "up" if (ind.get("last") or 0) > (ind.get("sma") or 0) else "down"
    json.dump({"symbol": ind.get("symbol"), "rsi": rsi, "trend": trend, "signal": signal}, sys.stdout)

    """
}
