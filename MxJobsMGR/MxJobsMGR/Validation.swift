//
//  Validation.swift
//  MxJobsMGR
//
//  Checks a jobspace for configuration gaps: execution without an approval gate,
//  API reads without a subscription or key, unlinked nodes, links that skip the agent layer.
//

import SwiftUI

enum IssueSeverity: Int, Comparable {
    case info, warning, error

    static func < (a: IssueSeverity, b: IssueSeverity) -> Bool { a.rawValue < b.rawValue }

    var symbol: String {
        switch self {
        case .info: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    var color: Color {
        switch self {
        case .info: .blue
        case .warning: .yellow
        case .error: .red
        }
    }
}

struct ValidationIssue: Identifiable {
    let id = UUID()
    var severity: IssueSeverity
    var message: String
    var nodeID: UUID?
    var subscriptionID: UUID?
}

enum Validator {
    static func check(_ space: Jobspace) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        let linked = Set(space.links.flatMap { [$0.from, $0.to] })

        for node in space.nodes {
            if !linked.contains(node.id), space.nodes.count > 1 {
                issues.append(.init(severity: .warning, message: "“\(node.title)” is not linked to anything.", nodeID: node.id))
            }
            for arg in node.arguments where arg.required && arg.value.trimmingCharacters(in: .whitespaces).isEmpty {
                issues.append(.init(severity: .warning, message: "“\(node.title)”: required argument “\(arg.name)” has no value.", nodeID: node.id))
            }
            switch node.kind {
            case .executeRequest:
                let upstream = space.upstream(of: node.id)
                if !space.nodes.contains(where: { $0.kind == .approvalGate && upstream.contains($0.id) }) {
                    issues.append(.init(severity: .error, message: "“\(node.title)” runs without a User Approval step before it.", nodeID: node.id))
                }
                if node.execution?.mode == .live {
                    issues.append(.init(severity: .info, message: "“\(node.title)” sends live requests.", nodeID: node.id))
                }
            case .apiRead:
                guard let api = node.api else { break }
                if let sub = space.subscription(api.subscriptionID) {
                    if sub.auth.requiresKey, !Keychain.hasSecret(for: sub.keychainAccount) {
                        issues.append(.init(severity: .warning, message: "“\(node.title)”: no API key stored for “\(sub.name)”.", nodeID: node.id, subscriptionID: sub.id))
                    }
                } else {
                    issues.append(.init(severity: .error, message: "“\(node.title)” has no API subscription.", nodeID: node.id))
                }
                if api.path.isEmpty {
                    issues.append(.init(severity: .warning, message: "“\(node.title)” has no endpoint path.", nodeID: node.id))
                }
            case .pythonScript:
                let spec = node.script ?? ScriptSpec()
                if spec.code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    issues.append(.init(severity: .error, message: "“\(node.title)” has no Python code.", nodeID: node.id))
                }
                if PythonRunner.locate(spec.interpreter) == nil {
                    issues.append(.init(severity: .warning, message: "“\(node.title)”: no Python interpreter found.", nodeID: node.id))
                }
                if let sub = space.subscription(spec.subscriptionID), sub.auth.requiresKey,
                   !Keychain.hasSecret(for: sub.keychainAccount) {
                    issues.append(.init(severity: .warning, message: "“\(node.title)”: no API key stored for “\(sub.name)”.", nodeID: node.id, subscriptionID: sub.id))
                }
            case .approvalGate:
                if node.approval?.approver.isEmpty ?? true {
                    issues.append(.init(severity: .info, message: "“\(node.title)” has no approver named.", nodeID: node.id))
                }
            default:
                break
            }
        }

        for link in space.links {
            guard let a = space.node(link.from), let b = space.node(link.to) else { continue }
            if abs(a.layer.rawValue - b.layer.rawValue) > 1 {
                issues.append(.init(severity: .warning, message: "“\(a.title)” → “\(b.title)” skips the agent layer.", nodeID: a.id))
            }
        }

        for sub in space.subscriptions {
            guard URL(string: sub.baseURL)?.host() != nil else {
                issues.append(.init(severity: .error, message: "Subscription “\(sub.name)” has no valid base URL.", subscriptionID: sub.id))
                continue
            }
            if let base = ProviderGuide.matching(sub).baseURL, !ProviderGuide.sameBase(sub.baseURL, base) {
                issues.append(.init(severity: .warning, message: "Subscription “\(sub.name)”: the base URL should be \(base); put the endpoint and its parameters on each API Data Read step.", subscriptionID: sub.id))
            } else if sub.baseURL.contains("?") {
                issues.append(.init(severity: .warning, message: "Subscription “\(sub.name)”: the base URL has parameters (?…); put them on each API Data Read step instead.", subscriptionID: sub.id))
            }
        }
        return issues.sorted { $0.severity > $1.severity }
    }
}
