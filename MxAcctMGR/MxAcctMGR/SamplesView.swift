//
//  SamplesView.swift
//  MxAcctMGR
//
//  Library ▸ Sample Portfolios: every sample account, the edge case it teaches, what to look for, and where to go
//  with it. Use makes it the account the report walkthroughs and the Morning Briefing work on; Copy to My Portfolio
//  makes an editable copy to work through the Investments steps.
//

import SwiftUI

struct SamplesView: View {
    @Bindable var store: PortStore

    var body: some View {
        StepPage(store: store, subtitle: "Accounts built to show the cases real portfolios run into. Use one in the report walkthroughs, or copy it into My Portfolio, to learn to read the results.", lesson: [
            "Each sample is one edge case: what a tool should flag, and what its results look like when something is unusual.",
            "Use a sample in the report walkthroughs — the same news lands very differently on a concentrated, an income and a cash-heavy account — or copy it into My Portfolio to work through its steps.",
            "Every sample is an account in the security master, built from real securities bought on real dates at their real closes (srm.py load sample-portfolios). My Portfolio is yours to edit, kept there too.",
        ]) {
            AdaptiveColumns(minimum: 340, spacing: 14, rowSpacing: 14) {
                ForEach(store.portfolios) { p in card(p).copyBlock() }
            }
        }
    }

    private func card(_ p: Portfolio) -> some View {
        let selected = p.id == store.selectedID
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: p.symbol).font(.title2).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading) {
                    Text(p.name).heading(.name)
                    Text("\(p.account.rawValue) · \(money(p.total)) · vs \(p.benchmark) · \(p.style.rawValue)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("The account in use") }
            }
            Text(p.lesson).font(.callout).fixedSize(horizontal: false, vertical: true)
            ForEach(p.lookFor, id: \.self) { Label($0, systemImage: "eye").font(.caption).foregroundStyle(.secondary) }
            let issues = p.issues
            if !issues.isEmpty {
                Text("\(issues.count) check\(issues.count == 1 ? "" : "s"): " + issues.map(\.title).joined(separator: "; ")).font(.caption).foregroundStyle(.orange).lineLimit(3)
            }
            Spacer(minLength: 0)
            HStack {
                Button(selected ? "In Use" : "Use") { store.selectedID = p.id }.disabled(selected)
                if p.id == "mine" {
                    Button("Open in Investments") { store.go(.myPortfolio) }
                }
                if p.id != "mine" {
                    Button("Copy to My Portfolio") {
                        store.copyToMine(p)
                        store.go(.myPortfolio)
                    }
                        .help("Make an editable copy of these holdings as My Portfolio (replaces it)")
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 250, alignment: .topLeading)
        .background(selected ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? Color.accentColor.opacity(0.5) : .clear))
        .quickHelpArea(QuickHelpItem(title: p.name, detail: p.lesson + " Look for: " + p.lookFor.joined(separator: " "), symbol: p.symbol))
    }
}
