//
//  PortfolioSamples.swift
//  MxJobsWMS
//
//  The portfolio samples — the same three layers, each Layer 3 tool used for what it is best at:
//
//    Active Portfolio Optimization   Python inputs + momentum alpha → Java active optimizer → C++ risk check
//    Passive Index Tracking          Python covariance → C++ minimum-tracking-error portfolio (sampled vs full)
//    Performance & Risk Attribution  Python Brinson-Fachler attribution + C++ ex-ante active risk
//
//  Data comes from the security master that MxDataHUB manages (MxDataHUB/SRM). Large matrices stay in the
//  services: the Python step returns an inputsUrl that the Java / C++ steps read ({{in:optInputs.inputsUrl}}).
//  Start the services with: python3 Services/mxservices.py start
//

import Foundation

nonisolated extension ApiSubscription {
    /// A subscription for one of the shared Layer 3 services (Services/), from the catalog.
    static func service(_ id: String) -> ApiSubscription {
        let info = ServiceCatalog.service(id)!
        var sub = ApiSubscription.localService(port: info.port)
        sub.name = info.name
        sub.provider = "\(info.language) service on this Mac (Services/\(info.folder))"
        sub.projectFolder = info.projectPath
        sub.notes = info.purpose + " — Start it with: " + ServiceCatalog.startCommand
        return sub
    }
}

nonisolated extension Jobspace {
    // MARK: - Active

    static func activeOptimization(portfolio: String, benchmark: String?) -> Jobspace {
        var space = Jobspace()
        space.name = "Active Portfolio Optimization — \(portfolio)"
        space.description = "An active mandate: beat \(benchmark ?? "the portfolio's benchmark") within a tracking-error budget. "
            + "Python builds the inputs from the security master and a momentum alpha; Java turns alpha into active weights "
            + "under the risk budget, name and sector limits; C++ checks the result's risk; the decision agent picks "
            + "rebalance / rebalance partially / hold, and the portfolio manager approves the trade list."
        space.run.data = .live
        space.run.stepDelay = 0.3
        let analytics = ApiSubscription.service("analytics")
        let java = ApiSubscription.service("portfolio-java")
        let cpp = ApiSubscription.service("portfolio-cpp")
        space.subscriptions = [analytics, java, cpp]
        let (y1, y2, y3) = lanes()

        var inputs = JobNode(kind: .apiRead, title: "Inputs + momentum alpha (Python)", x: 520, y: y3)
        inputs.api?.subscriptionID = analytics.id
        inputs.api?.method = .POST
        inputs.api?.path = "/inputs"
        inputs.api?.body = """
        {"mode": "active", "portfolio": "{{portfolio}}", "benchmark": "{{benchmark}}",
         "alpha": "momentum_12_1", "ic": {{ic}}, "lookbackDays": 504}
        """
        inputs.arguments = [Argument("portfolio", portfolio, required: true), Argument("benchmark", benchmark ?? ""),
                            Argument("ic", "0.05", type: .number)]
        inputs.outcome.successStatus = "200"
        inputs.outcome.requiredFields = ["inputsUrl", "assets", "alpha.top"]
        inputs.outcome.assertions = [ValueAssertion("assets", .greater, "50")]
        inputs.outcome.outputName = "optInputs"
        inputs.outcome.description = "Universe = benchmark + holdings, Ledoit-Wolf covariance, α = IC × σ × z(12-1 momentum)"
        inputs.notes = "Why Python: querying the security master, aligning two years of prices and estimating covariance and "
            + "alpha is data and statistics work. The matrices stay in the service; the step passes on an inputsUrl."
        inputs.exceptions.onFailure = .escalateToUser

        var optimize = JobNode(kind: .apiRead, title: "Optimize active portfolio (Java)", x: 900, y: y3)
        optimize.api?.subscriptionID = java.id
        optimize.api?.method = .POST
        optimize.api?.path = "/optimize/active"
        optimize.api?.body = """
        {"inputsUrl": "{{in:optInputs.inputsUrl}}", "maxWeight": {{maxWeight}}, "maxActiveWeight": {{maxActiveWeight}},
         "maxSectorActive": {{maxSectorActive}}, "trackingErrorTarget": {{teTarget}}, "maxTurnover": {{maxTurnover}}}
        """
        optimize.arguments = [Argument("maxWeight", "0.08", type: .number), Argument("maxActiveWeight", "0.03", type: .number),
                              Argument("maxSectorActive", "0.05", type: .number), Argument("teTarget", "0.03", type: .number),
                              Argument("maxTurnover", "0.30", type: .number)]
        optimize.outcome.successStatus = "200"
        optimize.outcome.requiredFields = ["weights", "trades", "decisionContext.recommendation"]
        optimize.outcome.assertions = [ValueAssertion("solverStatus", .equals, "optimal"),
                                       ValueAssertion("trackingError", .lessOrEqual, "0.0305"),
                                       ValueAssertion("informationRatio", .greater, "0")]
        optimize.outcome.outputName = "optimization"
        optimize.outcome.description = "Max α − λ/2·active variance at a 3% tracking error, ±3% per name, ±5% per sector"
        optimize.notes = "Why Java: the construction rules — name, active-weight, sector and turnover limits, the trade list — "
            + "are business logic that must stay readable, unit-tested and stable in a long-running service."
        optimize.exceptions.onFailure = .escalateToUser
        optimize.exceptions.timeoutSeconds = 120

        var risk = JobNode(kind: .apiRead, title: "Risk check (C++)", x: 1280, y: y3)
        risk.api?.subscriptionID = cpp.id
        risk.api?.method = .POST
        risk.api?.path = "/risk"
        risk.api?.body = """
        {"inputsUrl": "{{in:optInputs.inputsUrl}}", "weights": {{json:optimization.weights}},
         "confidence": 0.99, "horizonDays": 10, "portfolioValue": {{portfolioValue}}, "maxTrackingError": {{maxTE}}}
        """
        risk.arguments = [Argument("portfolioValue", "10000000", type: .number), Argument("maxTE", "0.035", type: .number)]
        risk.outcome.successStatus = "200"
        risk.outcome.requiredFields = ["trackingError", "beta", "activeRiskContributions"]
        risk.outcome.assertions = [ValueAssertion("status", .equals, "ok"),
                                   ValueAssertion("withinTrackingErrorLimit", .equals, "true")]
        risk.outcome.outputName = "risk"
        risk.outcome.description = "10-day 99% VaR, tracking error within the limit, beta, where active risk comes from"
        risk.notes = "Why C++: risk on a 500 × 500 covariance is recomputed for every proposal and scenario in milliseconds."
        risk.exceptions.onFailure = .escalateToUser

        var research = JobNode(kind: .agentTask, title: "Research agent", x: 520, y: y2)
        research.agent?.instructions = "Review the alpha: which names the momentum signal favours and avoids, and whether any "
            + "should be excluded (corporate events, liquidity, restrictions)."
        research.outcome.outputName = "research"
        var decide = JobNode(kind: .decision, title: "Construction decision", x: 1090, y: y2)
        decide.agent?.instructions = "Follow optimization.decisionContext (rebalance, rebalance_partially, hold, rerun_relaxed, "
            + "escalate). Escalate when risk.withinTrackingErrorLimit is false or one sector carries most of the active risk."
        decide.agent?.inputs = ["optimization", "risk"]
        decide.agent?.outputFormat = "{nextStep, confidence, reason, trades}"
        decide.outcome.outputName = "decision"

        var trigger = JobNode(kind: .trigger, title: "Monthly rebalance review", x: 300, y: y1)
        trigger.schedule?.mode = .manual
        trigger.notes = "Run on the first business day of the month, or when the alpha or the benchmark changes."
        trigger.outcome.outputName = "run"
        var assemble = JobNode(kind: .instructionSet, title: "Trade proposal", x: 1280, y: y1)
        assemble.agent?.instructions = "Turn the decision into a trade list (optimization.trades) with the reason, the ex-ante "
            + "tracking error, information ratio and turnover, for the portfolio manager."
        assemble.outcome.outputName = "proposal"
        var approve = JobNode(kind: .approvalGate, title: "Portfolio manager approval", x: 1520, y: y1)
        approve.approval?.approver = "Portfolio manager"
        approve.approval?.summaryTemplate = "Rebalance \(portfolio) as proposed?"
        approve.outcome.outputName = "approved"
        var execute = JobNode(kind: .executeRequest, title: "Send orders to OMS", x: 1760, y: y1)
        execute.execution?.target = "Order management system"
        execute.execution?.mode = .dryRun
        var report = JobNode(kind: .outcomeReport, title: "Rebalance report", x: 2000, y: y1)
        report.report?.recipients = "Portfolio manager, risk"

        space.nodes = [trigger, assemble, approve, execute, report, research, decide, inputs, optimize, risk]
        link(&space, [(trigger, research), (research, inputs), (inputs, research), (research, decide),
                      (decide, optimize), (decide, risk), (inputs, optimize), (optimize, risk), (inputs, risk),
                      (optimize, decide), (risk, decide), (decide, assemble), (assemble, approve), (approve, execute),
                      (execute, report)],
             labels: [(optimize, decide, "decisionContext"), (risk, decide, "risk"), (inputs, optimize, "inputsUrl"),
                      (optimize, risk, "weights"), (approve, execute, "approved")])
        return space
    }

    // MARK: - Passive

    static func passiveTracking(benchmark: String, portfolio: String?) -> Jobspace {
        var space = Jobspace()
        space.name = "Passive Index Tracking — \(benchmark)"
        space.description = "A passive mandate: hold \(benchmark) with as few names as the tracking-error budget allows. "
            + "Python builds the covariance from the security master; C++ finds the stratified sample with the smallest "
            + "tracking error and, for comparison, full replication; the decision agent rebalances only when the current "
            + "portfolio has drifted beyond the budget. Use it after benchmark constituents change (MxDataHUB ▸ Data Refresh)."
        space.run.data = .live
        space.run.stepDelay = 0.3
        let analytics = ApiSubscription.service("analytics")
        let cpp = ApiSubscription.service("portfolio-cpp")
        space.subscriptions = [analytics, cpp]
        let (y1, y2, y3) = lanes()

        var inputs = JobNode(kind: .apiRead, title: "Benchmark covariance (Python)", x: 520, y: y3)
        inputs.api?.subscriptionID = analytics.id
        inputs.api?.method = .POST
        inputs.api?.path = "/inputs"
        inputs.api?.body = """
        {"mode": "tracking", "benchmark": "{{benchmark}}", "portfolio": "{{portfolio}}", "alpha": "none", "lookbackDays": 504}
        """
        inputs.arguments = [Argument("benchmark", benchmark, required: true), Argument("portfolio", portfolio ?? "")]
        inputs.outcome.successStatus = "200"
        inputs.outcome.requiredFields = ["inputsUrl", "assets"]
        inputs.outcome.assertions = [ValueAssertion("assets", .greater, "20")]
        inputs.outcome.outputName = "trackInputs"
        inputs.notes = "Why Python: assembling the benchmark's members, weights and two years of returns from PostgreSQL "
            + "and shrinking the covariance is data and statistics work."
        inputs.exceptions.onFailure = .escalateToUser

        var sampled = JobNode(kind: .apiRead, title: "Sampled tracker (C++)", x: 900, y: y3)
        sampled.api?.subscriptionID = cpp.id
        sampled.api?.method = .POST
        sampled.api?.path = "/optimize/tracking"
        sampled.api?.body = """
        {"inputsUrl": "{{in:trackInputs.inputsUrl}}", "maxNames": {{maxNames}}, "selection": "{{selection}}",
         "maxWeight": {{maxWeight}}, "trackingErrorBudget": {{teBudget}}, "maxTurnover": {{maxTurnover}}}
        """
        sampled.arguments = [Argument("maxNames", "100", type: .number), Argument("selection", "stratified"),
                             Argument("maxWeight", "0.10", type: .number), Argument("teBudget", "0.01", type: .number),
                             Argument("maxTurnover", "0.10", type: .number)]
        sampled.outcome.successStatus = "200"
        sampled.outcome.requiredFields = ["weights", "trackingError", "decisionContext.recommendation"]
        sampled.outcome.assertions = [ValueAssertion("solverStatus", .equals, "optimal"),
                                      ValueAssertion("trackingError", .lessOrEqual, "{{teBudget}}")]
        sampled.outcome.outputName = "tracker"
        sampled.outcome.description = "At most 100 names, one or more per sector, ex-ante tracking error within 1%"
        sampled.notes = "Why C++: thousands of iterations over the full covariance per solve — fast enough to re-check "
            + "the tracker every day, for every candidate number of names."
        sampled.exceptions.onFailure = .escalateToUser

        var full = JobNode(kind: .apiRead, title: "Full replication (C++)", x: 1160, y: y3)
        full.api?.subscriptionID = cpp.id
        full.api?.method = .POST
        full.api?.path = "/optimize/tracking"
        full.api?.body = """
        {"inputsUrl": "{{in:trackInputs.inputsUrl}}", "maxNames": 0, "trackingErrorBudget": {{teBudget}}}
        """
        full.arguments = [Argument("teBudget", "0.01", type: .number)]
        full.outcome.successStatus = "200"
        full.outcome.requiredFields = ["names", "trackingError"]
        full.outcome.assertions = [ValueAssertion("method", .equals, "full_replication")]
        full.outcome.outputName = "fullReplication"
        full.outcome.description = "Every member at its benchmark weight: no tracking error, the most names and trades"
        full.exceptions.onFailure = .skip

        var data = JobNode(kind: .agentTask, title: "Index data agent", x: 520, y: y2)
        data.agent?.instructions = "Confirm the benchmark snapshot is current (MxDataHUB ▸ Data Refresh ▸ Benchmark "
            + "constituents) and note members excluded for missing prices."
        data.outcome.outputName = "indexData"
        var decide = JobNode(kind: .decision, title: "Rebalance decision", x: 1030, y: y2)
        decide.agent?.instructions = "Compare the sampled tracker with full replication: names held, tracking error, "
            + "turnover. Follow tracker.decisionContext — hold while the current tracking error is within budget."
        decide.agent?.inputs = ["tracker", "fullReplication"]
        decide.outcome.outputName = "decision"

        var trigger = JobNode(kind: .trigger, title: "Daily drift check", x: 300, y: y1)
        trigger.schedule?.mode = .weekdays
        trigger.schedule?.time = "16:30"
        trigger.outcome.outputName = "run"
        var assemble = JobNode(kind: .instructionSet, title: "Index rebalance proposal", x: 1280, y: y1)
        assemble.agent?.instructions = "List the trades (tracker.trades), names held, ex-ante tracking error and turnover."
        assemble.outcome.outputName = "proposal"
        var approve = JobNode(kind: .approvalGate, title: "Index PM approval", x: 1520, y: y1)
        approve.approval?.approver = "Index portfolio manager"
        approve.outcome.outputName = "approved"
        var execute = JobNode(kind: .executeRequest, title: "Send index trades", x: 1760, y: y1)
        execute.execution?.target = "Order management system"
        execute.execution?.mode = .dryRun
        var report = JobNode(kind: .outcomeReport, title: "Tracking report", x: 2000, y: y1)
        report.report?.recipients = "Index team"

        space.nodes = [trigger, assemble, approve, execute, report, data, decide, inputs, sampled, full]
        link(&space, [(trigger, data), (data, inputs), (inputs, data), (data, decide), (decide, sampled), (decide, full),
                      (inputs, sampled), (inputs, full), (sampled, decide), (full, decide), (decide, assemble),
                      (assemble, approve), (approve, execute), (execute, report)],
             labels: [(sampled, decide, "tracker"), (full, decide, "full"), (approve, execute, "approved")])
        return space
    }

    // MARK: - Attribution

    static func attribution(portfolio: String, benchmark: String?) -> Jobspace {
        var space = Jobspace()
        space.name = "Performance & Risk Attribution — \(portfolio)"
        space.description = "Explain \(portfolio)'s performance against \(benchmark ?? "its benchmark"): Brinson-Fachler "
            + "allocation, selection and interaction by sector, monthly and Carino-linked (Python), next to where the "
            + "ex-ante active risk sits today (C++). The analysts turn both into commentary for review and publication."
        space.run.data = .live
        space.run.stepDelay = 0.3
        let analytics = ApiSubscription.service("analytics")
        let cpp = ApiSubscription.service("portfolio-cpp")
        space.subscriptions = [analytics, cpp]
        let (y1, y2, y3) = lanes()

        var attribution = JobNode(kind: .apiRead, title: "Sector attribution (Python)", x: 520, y: y3)
        attribution.api?.subscriptionID = analytics.id
        attribution.api?.method = .POST
        attribution.api?.path = "/attribution"
        attribution.api?.body = """
        {"portfolio": "{{portfolio}}", "benchmark": "{{benchmark}}", "start": "{{start}}", "end": "{{end}}",
         "method": "{{method}}"}
        """
        attribution.arguments = [Argument("portfolio", portfolio, required: true), Argument("benchmark", benchmark ?? ""),
                                 Argument("start", "", type: .date), Argument("end", "", type: .date),
                                 Argument("method", "brinson-fachler")]
        attribution.outcome.successStatus = "200"
        attribution.outcome.requiredFields = ["effects.allocation", "effects.selection", "byGroup", "periods"]
        attribution.outcome.assertions = [ValueAssertion("schema", .equals, "mxjobs.attribution/1"),
                                          ValueAssertion("effects.residual", .lessOrEqual, "0.000001")]
        attribution.outcome.outputName = "attribution"
        attribution.outcome.description = "Effects add up to the active return; start/end empty = the last 12 months"
        attribution.notes = "Why Python: grouping holdings and returns by sector and month and linking the effects is "
            + "data shaping — quick to change when the team wants another grouping or method (brinson-hood-beebower)."
        attribution.exceptions.onFailure = .escalateToUser

        var riskInputs = JobNode(kind: .apiRead, title: "Risk inputs (Python)", x: 800, y: y3)
        riskInputs.api?.subscriptionID = analytics.id
        riskInputs.api?.method = .POST
        riskInputs.api?.path = "/inputs"
        riskInputs.api?.body = """
        {"mode": "risk", "portfolio": "{{portfolio}}", "benchmark": "{{benchmark}}", "alpha": "none"}
        """
        riskInputs.arguments = [Argument("portfolio", portfolio, required: true), Argument("benchmark", benchmark ?? "")]
        riskInputs.outcome.successStatus = "200"
        riskInputs.outcome.requiredFields = ["inputsUrl"]
        riskInputs.outcome.outputName = "riskInputs"

        var risk = JobNode(kind: .apiRead, title: "Ex-ante active risk (C++)", x: 1080, y: y3)
        risk.api?.subscriptionID = cpp.id
        risk.api?.method = .POST
        risk.api?.path = "/risk"
        risk.api?.body = """
        {"inputsUrl": "{{in:riskInputs.inputsUrl}}", "confidence": 0.99, "horizonDays": 10, "portfolioValue": {{portfolioValue}}}
        """
        risk.arguments = [Argument("portfolioValue", "10000000", type: .number)]
        risk.outcome.successStatus = "200"
        risk.outcome.requiredFields = ["trackingError", "sectorActiveRisk", "activeRiskContributions"]
        risk.outcome.assertions = [ValueAssertion("status", .equals, "ok")]
        risk.outcome.outputName = "exAnteRisk"
        risk.notes = "Why C++: decomposing active risk over the full benchmark covariance, per position and sector."

        var analyst = JobNode(kind: .agentTask, title: "Performance analyst", x: 650, y: y2)
        analyst.agent?.instructions = "Check the attribution's assumptions and data gaps (decisionContext.reasons); "
            + "find the sectors and names behind the active return."
        analyst.outcome.outputName = "analysis"
        var commentary = JobNode(kind: .aggregate, title: "Commentary agent", x: 1080, y: y2)
        commentary.agent?.instructions = "Write the period commentary: active return, the largest allocation and selection "
            + "effects, top and bottom contributors, and how today's active risk (exAnteRisk.sectorActiveRisk) compares."
        commentary.agent?.inputs = ["attribution", "exAnteRisk"]
        commentary.outcome.outputName = "commentary"

        var trigger = JobNode(kind: .trigger, title: "Month-end attribution", x: 300, y: y1)
        trigger.schedule?.mode = .manual
        trigger.notes = "Run after month-end prices are loaded (MxDataHUB ▸ Data Refresh ▸ Prices)."
        trigger.outcome.outputName = "run"
        var assemble = JobNode(kind: .instructionSet, title: "Attribution pack", x: 1280, y: y1)
        assemble.agent?.instructions = "Tables by sector (byGroup), monthly effects (periods), contributors, risk and the commentary."
        assemble.outcome.outputName = "pack"
        var approve = JobNode(kind: .approvalGate, title: "Performance team review", x: 1520, y: y1)
        approve.approval?.approver = "Head of performance"
        approve.outcome.outputName = "approved"
        var publish = JobNode(kind: .executeRequest, title: "Publish to client reporting", x: 1760, y: y1)
        publish.execution?.target = "Client reporting portal"
        publish.execution?.mode = .dryRun
        var report = JobNode(kind: .outcomeReport, title: "Publication report", x: 2000, y: y1)
        report.report?.recipients = "Performance team"

        space.nodes = [trigger, assemble, approve, publish, report, analyst, commentary, attribution, riskInputs, risk]
        link(&space, [(trigger, analyst), (analyst, attribution), (attribution, analyst), (analyst, commentary),
                      (commentary, riskInputs), (commentary, risk), (riskInputs, risk), (risk, commentary),
                      (attribution, commentary), (commentary, assemble), (assemble, approve), (approve, publish),
                      (publish, report)],
             labels: [(attribution, analyst, "attribution"), (risk, commentary, "active risk"),
                      (riskInputs, risk, "inputsUrl"), (approve, publish, "approved")])
        return space
    }

    // MARK: - Helpers

    private static func lanes() -> (Double, Double, Double) {
        (Double(Metrics.laneCenter(.operations)), Double(Metrics.laneCenter(.agents)), Double(Metrics.laneCenter(.data)))
    }

    private static func link(_ space: inout Jobspace, _ pairs: [(JobNode, JobNode)], labels: [(JobNode, JobNode, String)]) {
        for (a, b) in pairs { space.addLink(from: a.id, to: b.id) }
        for (a, b, label) in labels {
            if let i = space.links.firstIndex(where: { $0.from == a.id && $0.to == b.id }) { space.links[i].label = label }
        }
    }
}
