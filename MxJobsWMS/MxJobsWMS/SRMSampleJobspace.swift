//
//  SRMSampleJobspace.swift
//  MxJobsWMS
//
//  File ▸ New SRM Daily Refresh Sample: MxDataHUB's daily securities-master (SRM) automation
//  (MxDataHUB/SRM/srm.py load all) as a three-layer jobspace.
//
//  Layer 3  the 13 SRM loaders and a read-only status / data-quality read, called through the SRM loader
//           service (Services/srm-loader/srm_service.py, 127.0.0.1:8770), which runs srm.py
//  Layer 2  one agent per loader stage, in srm.py's dependency order — universe, benchmark constituents,
//           identifier enrichment, market data — and a data-quality analyst
//  Layer 1  the weekday evening refresh, the daily report and follow-up list, the data steward's approval,
//           the approved backfills (dry run), and the outcome report
//
//  The subscription sends "X-SRM-Dry-Run: 1", so a Live run only reports the srm.py command each loader
//  would run. Remove that header (API Subscriptions) to run the real loads against the database.
//

import Foundation

nonisolated extension Jobspace {
    static func srmDailyRefresh() -> Jobspace {
        var space = Jobspace()
        space.name = "SRM Daily Securities Master Refresh"
        space.description = "MxDataHUB's daily automation: refresh the reference data and the listed universe, "
            + "benchmark constituents, identifiers and issuer data, then prices, index levels and corporate actions "
            + "(srm.py load all); check data quality, and ask the data steward to approve the report and any backfills."
        space.run.data = .mock
        space.run.stepDelay = 0.3

        var srm = ApiSubscription.localService(port: 8770)
        srm.name = "SRM loader service"
        srm.provider = "MxDataHUB/SRM (srm.py) on this Mac"
        srm.projectFolder = "~/MyCodeGIT/MXcodeIDE/MxDataHUB/SRM"
        srm.defaultHeaders = [KeyValue("X-SRM-Dry-Run", "1")]
        srm.notes = "Start it with: python3 Services/mxservices.py start (needs psycopg2, like srm.py). "
            + "X-SRM-Dry-Run: 1 makes every load report its srm.py command without running it — "
            + "remove the header to load for real. Database and API keys come from srm.py's own configuration."
        space.subscriptions = [srm]

        let y1 = Double(Metrics.laneCenter(.operations))
        let y2 = Double(Metrics.laneCenter(.agents))
        let y3 = Double(Metrics.laneCenter(.data))

        /// One `srm.py load <loader>` step.
        func loader(_ name: String, _ title: String, x: Double, output: String, timeout: Int,
                    onFailure: FailureAction, retries: Int = 0, query: [KeyValue] = [],
                    arguments: [Argument] = [], note: String) -> JobNode {
            var node = JobNode(kind: .apiRead, title: title, x: x, y: y3)
            node.api?.subscriptionID = srm.id
            node.api?.method = .POST
            node.api?.path = "/load/\(name)"
            node.api?.query = query
            node.arguments = arguments
            node.notes = note
            node.outcome.successStatus = "200"
            node.outcome.requiredFields = ["status", "loader"]
            node.outcome.assertions = [ValueAssertion("status", .notEquals, "failed")]
            node.outcome.outputName = output
            node.outcome.description = "srm.load_run rows of this load: succeeded or partial (dry-run when dry running)"
            node.exceptions.timeoutSeconds = timeout
            node.exceptions.onFailure = onFailure
            node.exceptions.maxRetries = retries
            node.exceptions.retryDelaySeconds = 60
            node.exceptions.exponentialBackoff = true
            return node
        }

        // Layer 3 — the loaders, left to right in srm.py's dependency order.
        let reference = loader("reference", "Reference data (ISO MICs, currencies)", x: 300, output: "reference",
                               timeout: 300, onFailure: .retry, retries: 2,
                               note: "ISO 10383 market identifier codes and ISO 4217 currencies.")
        let nasdaqTrader = loader("nasdaqtrader", "Listed universe (Nasdaq Trader)", x: 530, output: "universe",
                                  timeout: 600, onFailure: .retry, retries: 2,
                                  note: "US listed securities, listings and tickers; closes listings that left the files.")
        let secTickers = loader("sec-tickers", "Issuers (SEC company tickers)", x: 760, output: "issuers",
                                timeout: 600, onFailure: .retry, retries: 2,
                                note: "CIKs → issuers, linked to the listed securities.")
        let ssga = loader("ssga", "S&P / Dow constituents (SSGA SPDR)", x: 1020, output: "spdrHoldings",
                          timeout: 600, onFailure: .escalateToUser, retries: 1,
                          query: [KeyValue("benchmarks", "{{benchmarks}}")],
                          arguments: [Argument("benchmarks", "SP500 DJIA SP400 SP600")],
                          note: "SPY, DIA, MDY and SPSM daily holdings: members, weights, shares, CUSIP, SEDOL.")
        let nasdaq100 = loader("nasdaq100", "Nasdaq-100 members", x: 1250, output: "nasdaq100",
                               timeout: 300, onFailure: .retry, retries: 1,
                               note: "Nasdaq.com list with market caps (plain cap weights).")
        let openFIGI = loader("openfigi", "FIGIs (OpenFIGI)", x: 1510, output: "figis",
                              timeout: 1800, onFailure: .skip,
                              note: "Composite, share-class and exchange FIGIs by CUSIP, else ticker; 250 requests/min.")
        let profiles = loader("fmp-profiles", "Profiles: ISIN, sector (FMP)", x: 1740, output: "profiles",
                              timeout: 1800, onFailure: .retry, retries: 1,
                              query: [KeyValue("max", "{{maxCalls}}")],
                              arguments: [Argument("maxCalls", "")],
                              note: "ISIN, CUSIP, CIK, sector / industry, market cap for benchmark and portfolio members.")
        let submissions = loader("sec-submissions", "Issuer details (SEC submissions)", x: 1970, output: "secSubmissions",
                                 timeout: 1800, onFailure: .skip,
                                 note: "SIC, state of incorporation, EIN, fiscal year end, former names.")
        let gleif = loader("gleif", "LEIs (GLEIF)", x: 2200, output: "leis",
                           timeout: 1800, onFailure: .skip,
                           note: "ISIN → LEI file and LEI records: legal form, entity status, countries.")
        let prices = loader("fmp-prices", "End-of-day prices (FMP)", x: 2460, output: "prices",
                            timeout: 3600, onFailure: .skip, retries: 1,
                            query: [KeyValue("since", "{{since}}")],
                            arguments: [Argument("since", "", type: .date)],
                            note: "EOD prices, incremental after the first 2 years. Needs an FMP API key; when it fails, "
                                + "the Nasdaq.com step fills the gaps.")
        let fundPrices = loader("nasdaq-prices", "Fund & fallback prices (Nasdaq.com)", x: 2690, output: "fundPrices",
                                timeout: 3600, onFailure: .escalateToUser, retries: 1,
                                note: "Free, no API key: EOD prices for the stock and bond funds (ETFs, ETNs, closed-end "
                                    + "funds) held in portfolios and personal accounts, and for any benchmark or portfolio "
                                    + "security FMP left without a recent price.")
        let levels = loader("fmp-index-levels", "Index levels (FMP)", x: 2920, output: "indexLevels",
                            timeout: 600, onFailure: .skip,
                            note: "^GSPC and ^DJI levels on the current plan.")
        let actions = loader("fmp-corporate-actions", "Corporate actions (FMP)", x: 3150, output: "corporateActions",
                             timeout: 3600, onFailure: .skip,
                             query: [KeyValue("months", "{{months}}")],
                             arguments: [Argument("months", "", type: .number)],
                             note: "Dividends, splits, symbol changes and delistings from the FMP calendars.")

        var status = JobNode(kind: .apiRead, title: "SRM status & data quality", x: 3410, y: y3)
        status.api?.subscriptionID = srm.id
        status.api?.path = "/status"
        status.outcome.successStatus = "200"
        status.outcome.requiredFields = ["summary.failed", "checks", "benchmarks", "prices.lastDate"]
        status.outcome.assertions = [ValueAssertion("summary.failed", .equals, "0")]
        status.outcome.outputName = "quality"
        status.outcome.description = "No failed data-quality check: benchmarks and prices fresh, weights sum to 1, "
            + "no failed loads (identifier coverage only warns)"
        status.exceptions.onFailure = .escalateToUser
        status.exceptions.timeoutSeconds = 120
        status.notes = "Read-only: migrations, row counts, identifier coverage, benchmarks, price freshness, recent loads."

        // Layer 2 — one agent per stage, chained in dependency order.
        func agent(_ kind: NodeKind, _ title: String, x: Double, output: String, instructions: String) -> JobNode {
            var node = JobNode(kind: kind, title: title, x: x, y: y2)
            node.agent?.instructions = instructions
            node.outcome.outputName = output
            return node
        }
        let universeAgent = agent(.agentTask, "Universe agent", x: 530, output: "universeStage",
            instructions: "Refresh venues, currencies, the US listed universe and issuers. Report securities added, "
                + "listings closed and any loader that did not succeed.")
        let constituentsAgent = agent(.agentTask, "Benchmark constituents agent", x: 1135, output: "constituentsStage",
            instructions: "Load today's S&P 500 / 400 / 600, Dow and Nasdaq-100 members and weights. Flag benchmarks "
                + "whose member count or weight sum moved unexpectedly.")
        let enrichmentAgent = agent(.agentTask, "Identifier enrichment agent", x: 1855, output: "enrichmentStage",
            instructions: "Fill FIGIs, ISINs, CUSIPs, sectors, issuer details and LEIs for benchmark and portfolio "
                + "members. Summarise identifier conflicts and rejects.")
        let marketAgent = agent(.agentTask, "Market data agent", x: 2805, output: "marketStage",
            instructions: "Load end-of-day prices (FMP, then Nasdaq.com for funds and gaps), index levels and corporate actions. Note symbols without a price "
                + "for the last trading day and corporate actions that need attention (splits, delistings).")
        var analyst = agent(.aggregate, "Data quality analyst", x: 3410, output: "srmDaily",
            instructions: "Combine every stage's load results with the status checks. Produce the daily SRM report "
                + "and a follow-up list: loaders to re-run, and backfills worth their API budget "
                + "(e.g. fmp-corporate-actions --history, fmp-profiles --all-securities).")
        analyst.agent?.outputFormat = "{report, failedLoads, warnings, followUps: [{loader, options, reason, apiCalls}]}"

        // Layer 1 — operations.
        var trigger = JobNode(kind: .trigger, title: "Weekday SRM refresh", x: 300, y: y1)
        trigger.schedule?.mode = .weekdays
        trigger.schedule?.time = "18:30"
        trigger.schedule?.timeZone = "America/New_York"
        trigger.notes = "After the close, once the SPDR holdings files and end-of-day prices are published."
        trigger.outcome.outputName = "run"

        var assemble = JobNode(kind: .instructionSet, title: "SRM daily report & follow-ups", x: 2700, y: y1)
        assemble.agent?.instructions = "Turn the analyst's report into the day's SRM summary for the data steward, "
            + "and a list of follow-up actions (re-runs, backfills) with their estimated API calls."
        assemble.agent?.outputFormat = "{summary, followUps}"
        assemble.outcome.outputName = "srmReport"

        var approve = JobNode(kind: .approvalGate, title: "Data steward approval", x: 2940, y: y1)
        approve.approval?.approver = "Data steward"
        approve.approval?.summaryTemplate = "SRM daily refresh for {{today}} is loaded. Approve the report and the follow-ups?"
        approve.approval?.expiresAfterMinutes = 720
        approve.outcome.outputName = "approved"

        var backfill = JobNode(kind: .executeRequest, title: "Run approved backfills", x: 3180, y: y1)
        backfill.execution?.target = "srm.py (MxDataHUB/SRM)"
        backfill.execution?.mode = .dryRun
        backfill.execution?.confirmBeforeSend = true
        backfill.notes = "Long, API-hungry loads only run after approval: e.g. fmp-corporate-actions --history "
            + "(2 calls per symbol) or fmp-profiles --all-securities (~13,000 calls, about an hour)."
        backfill.outcome.outputName = "backfills"

        var report = JobNode(kind: .outcomeReport, title: "SRM daily load report", x: 3420, y: y1)
        report.report?.recipients = "Data steward"
        report.report?.detailed = true
        report.outcome.description = "Loads, counts, rejects, data-quality checks and the follow-ups run"

        let loaders = [reference, nasdaqTrader, secTickers, ssga, nasdaq100, openFIGI, profiles, submissions,
                       gleif, prices, fundPrices, levels, actions]
        space.nodes = [trigger, assemble, approve, backfill, report,
                       universeAgent, constituentsAgent, enrichmentAgent, marketAgent, analyst]
            + loaders + [status]

        var pairs: [(JobNode, JobNode)] = [
            (trigger, universeAgent),
            // Stages wait for each other along Layer 2, as srm.py load all orders them.
            (universeAgent, constituentsAgent), (constituentsAgent, enrichmentAgent), (enrichmentAgent, marketAgent),
            (marketAgent, analyst), (analyst, status), (status, analyst),
            (analyst, assemble), (assemble, approve), (approve, backfill), (backfill, report),
        ]
        let stages: [(JobNode, [JobNode])] = [
            (universeAgent, [reference, nasdaqTrader, secTickers]),
            (constituentsAgent, [ssga, nasdaq100]),
            (enrichmentAgent, [openFIGI, profiles, submissions, gleif]),
            (marketAgent, [prices, fundPrices, levels, actions]),
        ]
        for (stage, steps) in stages {
            for step in steps { pairs += [(stage, step), (step, stage)] }   // call down, results back up
        }
        for (a, b) in pairs { space.addLink(from: a.id, to: b.id) }
        if let i = space.links.firstIndex(where: { $0.from == status.id }) { space.links[i].label = "quality" }
        if let i = space.links.firstIndex(where: { $0.from == approve.id }) { space.links[i].label = "approved" }
        if let i = space.links.firstIndex(where: { $0.from == analyst.id && $0.to == assemble.id }) {
            space.links[i].label = "report"
        }
        return space
    }
}
