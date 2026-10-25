//
//  Attribution.swift
//  MxAcctMGR
//
//  Performance attribution as the analytics service computes it (Services/analytics, POST /attribution): monthly
//  sector Brinson-Fachler (or Brinson-Hood-Beebower) effects — allocation, selection, interaction — over the account's
//  holdings history in the security master and real returns, linked over the year with Carino factors so they add up
//  to the compounded active return. The app shows the result; it has no attribution engine of its own.
//

import Foundation

nonisolated struct AttributionResult: Sendable {
    nonisolated struct Group: Hashable, Sendable, Identifiable {
        var id: String { group }
        var group: String
        var portfolioWeight, benchmarkWeight, activeWeight: Double
        var allocation, selection, interaction: Double
        var total: Double { allocation + selection + interaction }
    }
    nonisolated struct Period: Hashable, Sendable, Identifiable {
        var id: String { month }
        var month: String
        var portfolioReturn, benchmarkReturn: Double
        var allocation, selection, interaction: Double
        var activeReturn: Double { portfolioReturn - benchmarkReturn }
    }
    nonisolated struct Contributor: Hashable, Sendable, Identifiable {
        var id: String { ticker }
        var ticker: String
        var sector: String
        var portfolioWeight, benchmarkWeight, contribution: Double
    }

    var engine: String
    var method: String
    var portfolioReturn, benchmarkReturn: Double
    var activeReturn: Double { portfolioReturn - benchmarkReturn }
    var allocation, selection, interaction, residual: Double
    var groups: [Group]
    var periods: [Period]
    var top: [Contributor]
    var bottom: [Contributor]
    var dataGap: Double
    var recommendation: String
    var reasons: [String]
    var highlight: String
    var assumptions: [String]
}

nonisolated enum AttributionEngine {
    enum Method: String, CaseIterable, Sendable {
        case brinsonFachler = "brinson-fachler", brinsonHoodBeebower = "brinson-hood-beebower"
        var title: String { self == .brinsonFachler ? "Brinson-Fachler" : "Brinson-Hood-Beebower" }
    }
}
