//
//  NodeView.swift
//  MxJobsWMS
//
//  One node on the canvas: kind icon and name, title, a one-line summary of its
//  configuration, a validation badge and the ● link handle on its right edge.
//

import SwiftUI

struct NodeView<HG: Gesture>: View {
    var node: JobNode
    var space: Jobspace
    var selected: Bool
    var issue: IssueSeverity?
    var interactive = true
    var handleGesture: HG

    @State private var hovering = false

    var body: some View {
        let color = node.kind.color
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: node.kind.symbol)
                    .font(.caption.weight(.semibold))
                Text(node.kind.title.uppercased())
                    .font(.system(size: 9, weight: .bold))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let issue {
                    Image(systemName: issue.symbol)
                        .foregroundStyle(issue.color)
                        .font(.caption)
                }
            }
            .foregroundStyle(color)
            Text(node.title)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
            Text(summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(width: Metrics.nodeSize.width, height: Metrics.nodeSize.height, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
            RoundedRectangle(cornerRadius: 10)
                .fill(color.opacity(0.10))
        }
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 10)
                .fill(color)
                .frame(width: 4)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(selected ? Color.accentColor : color.opacity(0.55), lineWidth: selected ? 2.5 : 1)
        }
        .opacity(node.enabled ? 1 : 0.5)
        .shadow(color: .black.opacity(selected ? 0.18 : 0.08), radius: selected ? 6 : 3, y: 1)
        .overlay(alignment: .trailing) {
            if interactive {
                Circle()
                    .fill(hovering || selected ? Color.accentColor : color.opacity(0.5))
                    .frame(width: 12, height: 12)
                    .overlay(Circle().stroke(Color(nsColor: .textBackgroundColor), lineWidth: 2))
                    .padding(6)
                    .contentShape(Circle().inset(by: -2))
                    .offset(x: 12)
                    .gesture(handleGesture)
                    .help("Drag onto another node to link them")
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onHover { hovering = $0 }
        .help(node.kind.summary)
    }

    private var summary: String { NodeSummary.text(for: node, in: space) }
}

enum NodeSummary {
    /// One line describing a node's configuration (canvas and exports).
    static func text(for node: JobNode, in space: Jobspace) -> String {
        switch node.kind {
        case .trigger:
            return node.schedule?.summary ?? ""
        case .apiRead:
            guard let api = node.api else { return "" }
            let sub = space.subscription(api.subscriptionID)?.name ?? "No subscription"
            return "\(api.method.rawValue) \(api.path.isEmpty ? "/" : api.path) · \(sub)"
        case .approvalGate:
            let who = node.approval?.approver ?? ""
            return who.isEmpty ? "Approver not set" : "By \(who)"
        case .executeRequest:
            guard let e = node.execution else { return "" }
            return "\(e.mode == .live ? "LIVE" : e.mode == .paper ? "Paper" : "Dry run")\(e.target.isEmpty ? "" : " · \(e.target)")"
        case .outcomeReport:
            let to = node.report?.recipients ?? ""
            return to.isEmpty ? "Report" : "To \(to)"
        case .dataNormalize:
            return "\(node.transform?.mappings.count ?? 0) field mappings"
        case .instructionSet, .agentTask, .aggregate, .decision:
            let out = node.outcome.outputName
            let inputs = space.inputNames(for: node.id)
            if !inputs.isEmpty || !out.isEmpty {
                return "\(inputs.joined(separator: ", "))\(inputs.isEmpty ? "" : " → ")\(out.isEmpty ? "…" : out)"
            }
            return node.agent?.instructions.isEmpty == false ? node.agent!.instructions : node.kind.summary
        }
    }
}
