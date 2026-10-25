//
//  SampleLibrary.swift
//  MxJobsMGR
//
//  Creating jobspaces from the samples (Shared/ServiceCatalog.swift lists them): File ▸ New from Sample…,
//  the Layer 3 Services window, and mxjobsmgr://sample/<id>?portfolio=CODE&benchmark=CODE links from MxDataHUB.
//

import AppKit

nonisolated extension Jobspace {
    /// A sample jobspace by id, for a portfolio / benchmark where the sample takes one.
    static func fromSample(_ id: String, portfolio: String? = nil, benchmark: String? = nil) -> Jobspace? {
        let p = portfolio.flatMap { $0.isEmpty ? nil : $0 }
        let b = benchmark.flatMap { $0.isEmpty ? nil : $0 }
        switch id {
        case "srm-daily-refresh": return srmDailyRefresh()
        case "market-refresh": return sample()
        case "active-optimization": return activeOptimization(portfolio: p ?? "DEMO_GROWTH", benchmark: b)
        case "passive-tracking": return passiveTracking(benchmark: b ?? "SP500", portfolio: p)
        case "attribution": return attribution(portfolio: p ?? "DEMO_GROWTH", benchmark: b)
        default: return nil
        }
    }
}

/// Hands a sample to the next new document (DocumentGroup's newDocument reads it). Set and read on the main thread.
nonisolated enum PendingSample {
    nonisolated(unsafe) static var next: Jobspace?

    static func take() -> Jobspace {
        defer { next = nil }
        return next ?? Jobspace()
    }

    /// Opens a new jobspace window with the sample.
    @MainActor @discardableResult
    static func open(_ id: String, portfolio: String? = nil, benchmark: String? = nil) -> Bool {
        guard let space = Jobspace.fromSample(id, portfolio: portfolio, benchmark: benchmark) else { return false }
        next = space
        NSDocumentController.shared.newDocument(nil)
        return true
    }
}

/// Opens mxjobsmgr:// links (Shared/AppLinks.swift) — the hand-offs from MxDataHUB.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if case let .sample(id, portfolio, benchmark)? = AppLink(url: url) {
                PendingSample.open(id, portfolio: portfolio, benchmark: benchmark)
            }
        }
    }
}
