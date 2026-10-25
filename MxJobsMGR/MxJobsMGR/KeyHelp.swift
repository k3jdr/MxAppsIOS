//
//  KeyHelp.swift
//  MxJobsMGR
//
//  Help for adding API subscription keys: a guide per provider (where to get the key, how it is
//  sent, free-tier limits), a key test that calls the provider once, and the Help ▸ Adding API Keys
//  window. Keys go to the Keychain only; they are never written to the jobspace.
//

import SwiftUI

// MARK: - Provider guides

struct ProviderGuide: Identifiable {
    let id: String
    var name: String
    var hosts: [String]
    /// Where to sign up for (or find) the key.
    var signupURL: URL?
    var docsURL: URL?
    var needsKey: Bool
    var auth: AuthStyle
    var keyName: String
    var steps: [String]
    var limits: String
    var notes: [String]
    /// The base URL calls start from, when the provider has one (endpoint paths and parameters go on each step).
    var baseURL: String? = nil

    static let all: [ProviderGuide] = [
        ProviderGuide(
            id: "alphavantage", name: "Alpha Vantage", hosts: ["alphavantage.co"],
            signupURL: URL(string: "https://www.alphavantage.co/support/#api-key"),
            docsURL: URL(string: "https://www.alphavantage.co/documentation/"),
            needsKey: true, auth: .queryParameter, keyName: "apikey",
            steps: [
                "Open the Alpha Vantage key page (Get a Key…).",
                "Fill in the short form (what you use it for, organisation, email) and press GET FREE API KEY.",
                "The key appears on the page right away — a 16-character code of letters and digits. Copy it.",
                "Here, paste it into API key and press Save Key, then Test Key.",
            ],
            limits: "Free tier: 25 requests a day. Premium plans raise the limit.",
            notes: [
                "MxJobsMGR sends the key as the apikey query parameter (masked in Test Call).",
                "Alpha Vantage answers HTTP 200 even for a bad key or a reached limit: the message is in the JSON "
                    + "(Error Message, Information or Note). Test Key and Test Call show it.",
                "The free tier also allows about 1 request a second: a quick burst of calls gets an Information "
                    + "notice instead of data (Test Key reports it as a rate limit).",
                "Alpha Vantage does not reject unknown keys, so Test Key confirms that calls work rather than "
                    + "that the key is yours — make sure you paste your own key.",
            ]),
        ProviderGuide(
            id: "finnhub", name: "Finnhub", hosts: ["finnhub.io"],
            signupURL: URL(string: "https://finnhub.io/register"),
            docsURL: URL(string: "https://finnhub.io/docs/api"),
            needsKey: true, auth: .header, keyName: "X-Finnhub-Token",
            steps: [
                "Create a free account (Get a Key…) and confirm your email.",
                "Your API key is shown on the Finnhub dashboard. Copy it.",
                "Here, paste it into API key and press Save Key, then Test Key.",
            ],
            limits: "Free tier: 60 calls a minute; some endpoints need a paid plan.",
            notes: ["MxJobsMGR sends the key in the X-Finnhub-Token header."]),
        ProviderGuide(
            id: "fmp", name: "Financial Modeling Prep", hosts: ["financialmodelingprep.com"],
            signupURL: URL(string: "https://site.financialmodelingprep.com/developer/docs/dashboard"),
            docsURL: URL(string: "https://site.financialmodelingprep.com/developer/docs/stable"),
            needsKey: true, auth: .queryParameter, keyName: "apikey",
            steps: [
                "Sign in at Financial Modeling Prep; your API key is on the dashboard (Get a Key…). Copy it.",
                "Set Base URL to https://financialmodelingprep.com/stable — only the address every call starts with. "
                    + "Each API Data Read step adds its own path and parameters, e.g. /search-name with query=apple, "
                    + "/historical-price-eod/full with symbol=AAPL and from=2026-01-01, or /quote with symbol=AAPL.",
                "Paste the key into API key, press Save Key, then Test Key (it reads Apple's profile).",
                "For the security master's price loads (SRM Daily Refresh ▸ End-of-day prices, Index levels, Profiles, "
                    + "Corporate actions) the key must also be in SRM's own Keychain item: in Terminal run "
                    + "security add-generic-password -s SRM-api -a fmp -w and paste it. Those steps call the srm-loader "
                    + "service on this Mac, which runs srm.py — they don't use this subscription's key.",
            ],
            limits: "Depends on your plan (calls a minute and which endpoints); endpoints outside it answer HTTP 402.",
            notes: [
                "MxJobsMGR sends the key as the apikey query parameter (masked in Test Call).",
                "Use the stable API (/stable/…); the older /api/v3/… paths answer only for legacy plans.",
            ],
            baseURL: "https://financialmodelingprep.com/stable"),
        ProviderGuide(
            id: "edgar", name: "SEC EDGAR", hosts: ["sec.gov"],
            signupURL: nil,
            docsURL: URL(string: "https://www.sec.gov/search-filings/edgar-application-programming-interfaces"),
            needsKey: false, auth: .none, keyName: "",
            steps: [
                "No key is needed.",
                "Under Headers Sent With Every Call, set User-Agent to your name and email "
                    + "(e.g. “Jane Doe jane@example.com”) — the SEC asks every client to identify itself.",
            ],
            limits: "At most 10 requests a second.",
            notes: []),
        ProviderGuide(
            id: "frankfurter", name: "Frankfurter (ECB rates)", hosts: ["frankfurter.dev", "frankfurter.app"],
            signupURL: nil, docsURL: URL(string: "https://frankfurter.dev"),
            needsKey: false, auth: .none, keyName: "",
            steps: ["No key is needed."],
            limits: "Free and open; rates update once a working day.",
            notes: []),
        ProviderGuide(
            id: "local", name: "Local service on this Mac", hosts: ["127.0.0.1", "localhost"],
            signupURL: nil, docsURL: nil,
            needsKey: false, auth: .localService, keyName: "",
            steps: [
                "No key is needed unless you start the service with a token (--token or MXJOBS_SERVICE_TOKEN).",
                "If you do, save the same token here; it is sent as “Authorization: Bearer …”.",
            ],
            limits: "Whatever the service allows.",
            notes: ["Services (MxAppsIOS/Services, start them with python3 Services/mxservices.py start): market-sample (8765), portfolio-java (8766), portfolio-cpp (8767), srm-loader (8770), analytics (8772)."]),
    ]

    /// Steps for any other provider.
    static let generic = ProviderGuide(
        id: "generic", name: "Other providers", hosts: [], signupURL: nil, docsURL: nil,
        needsKey: true, auth: .queryParameter, keyName: "",
        steps: [
            "Sign up with the provider and find the API key in its dashboard or account settings.",
            "Check its documentation for how the key is sent, and set Authentication to match: "
                + "a query parameter (name it, e.g. apikey or token), a header (e.g. X-API-Key), or a Bearer token.",
            "Paste the key into API key, press Save Key, then Test Key — or Test Call on one of its API Data Read steps.",
        ],
        limits: "See the provider's plan.",
        notes: [])

    /// Whether two base URLs are the same apart from a trailing slash and letter case.
    static func sameBase(_ a: String, _ b: String) -> Bool {
        func norm(_ s: String) -> String { s.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: "/+$", with: "", options: .regularExpression) }
        return norm(a) == norm(b)
    }

    /// The guide matching a subscription's base URL.
    static func matching(_ sub: ApiSubscription) -> ProviderGuide {
        let host = URL(string: sub.baseURL)?.host()?.lowercased() ?? ""
        return all.first { guide in guide.hosts.contains { host == $0 || host.hasSuffix("." + $0) } } ?? generic
    }
}

// MARK: - Key test

struct KeyTestResult {
    enum Verdict { case valid, invalid, limited, unreachable, unknown }
    var verdict: Verdict
    var message: String

    var symbol: String {
        switch verdict {
        case .valid: "checkmark.circle.fill"
        case .invalid: "xmark.octagon.fill"
        case .limited: "hourglass"
        case .unreachable: "wifi.exclamationmark"
        case .unknown: "questionmark.circle"
        }
    }

    var color: Color {
        switch verdict {
        case .valid: .green
        case .invalid: .red
        case .limited, .unknown: .orange
        case .unreachable: .secondary
        }
    }
}

enum KeyTester {
    /// Calls the provider once with `key` (the stored key when nil) and says whether it was accepted.
    static func test(_ sub: ApiSubscription, key explicitKey: String? = nil) async -> KeyTestResult {
        var sub = sub
        let key = explicitKey ?? Keychain.secret(for: sub.keychainAccount)
        if sub.auth.requiresKey, key == nil {
            return KeyTestResult(verdict: .invalid, message: "No key stored yet.")
        }
        // A cheap request each known provider answers.
        var node = JobNode(kind: .apiRead)
        switch ProviderGuide.matching(sub).id {
        case "alphavantage":
            node.api?.path = "/query"
            // Not IBM: that is Alpha Vantage's open documentation example.
            node.api?.query = [KeyValue("function", "GLOBAL_QUOTE"), KeyValue("symbol", "MSFT")]
        case "finnhub":
            node.api?.path = "/quote"
            node.api?.query = [KeyValue("symbol", "AAPL")]
        case "fmp":
            sub.baseURL = ProviderGuide.matching(sub).baseURL ?? sub.baseURL   // test the key, not a mistyped base URL
            node.api?.path = "/profile"
            node.api?.query = [KeyValue("symbol", "AAPL")]
        case "local":
            node.api?.path = "/health"
        default:
            node.api?.path = ""
        }
        node.exceptions.timeoutSeconds = 15
        let request: URLRequest
        do {
            request = try ApiTester.buildRequest(node: node, subscription: sub, key: key)
        } catch {
            return KeyTestResult(verdict: .unknown, message: error.localizedDescription)
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            var result = interpret(status: status, json: json)
            if result.verdict == .valid, ProviderGuide.matching(sub).id == "alphavantage" {
                result.message = "Alpha Vantage returned a quote, so calls with this key work. Alpha Vantage does not "
                    + "reject unknown keys, so this cannot prove the key is yours; your free key allows 25 requests a day."
            }
            return result
        } catch {
            return KeyTestResult(verdict: .unreachable, message: "Could not reach \(sub.baseURL): \(error.localizedDescription)")
        }
    }

    static func interpret(status: Int, json: [String: Any]?) -> KeyTestResult {
        if status == 401 || status == 403 {
            return KeyTestResult(verdict: .invalid, message: "Rejected (HTTP \(status)) — check the key and how it is sent.")
        }
        if status == 429 {
            return KeyTestResult(verdict: .limited, message: "Accepted, but the rate limit is reached (HTTP 429). Try later.")
        }
        // Alpha Vantage style: HTTP 200 with the problem in the body.
        if let message = providerMessage(json) {
            let lower = message.lowercased()
            if lower.contains("apikey") && (lower.contains("invalid") || lower.contains("missing")) {
                return KeyTestResult(verdict: .invalid, message: message)
            }
            if lower.contains("rate limit") || lower.contains("requests per day") || lower.contains("call frequency")
                || lower.contains("premium") {
                return KeyTestResult(verdict: .limited, message: message)
            }
            return KeyTestResult(verdict: .unknown, message: message)
        }
        if (200..<300).contains(status) {
            return KeyTestResult(verdict: .valid, message: "Key accepted (HTTP \(status)).")
        }
        return KeyTestResult(verdict: .unknown, message: "HTTP \(status) — the key may be fine; try Test Call on a step.")
    }

    /// The error or notice a provider put in a 200 response ("Error Message", "Information", "Note", "error").
    static func providerMessage(_ json: [String: Any]?) -> String? {
        guard let json else { return nil }
        for key in ["Error Message", "Information", "Note", "error"] {
            if let s = json[key] as? String, !s.isEmpty { return s.count > 300 ? String(s.prefix(300)) + "…" : s }
        }
        return nil
    }
}

// MARK: - Views

/// The guide for one provider (inspector popover and Help window).
struct KeyGuideView: View {
    var guide: ProviderGuide
    var showName = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showName {
                HStack {
                    Text(guide.name).font(.headline)
                    Spacer()
                    Text(guide.needsKey ? "Key required" : "No key needed")
                        .font(.caption)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background((guide.needsKey ? Color.orange : Color.green).opacity(0.15), in: Capsule())
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(guide.steps.enumerated()), id: \.offset) { i, step in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(i + 1).").monospacedDigit().foregroundStyle(.secondary)
                        Text(step).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if guide.needsKey && guide.id != "generic" {
                Label("Authentication: \(guide.auth.title)\(guide.keyName.isEmpty ? "" : " — \(guide.keyName)")",
                      systemImage: "key")
                    .font(.caption)
            }
            Label(guide.limits, systemImage: "speedometer").font(.caption)
            ForEach(guide.notes, id: \.self) { note in
                Label(note, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if let url = guide.signupURL {
                    Link(destination: url) { Label("Get a Key…", systemImage: "arrow.up.right.square") }
                }
                if let url = guide.docsURL {
                    Link(destination: url) { Label("Documentation", systemImage: "book") }
                }
            }
            .font(.callout)
        }
    }
}

/// Help ▸ Adding API Keys.
struct KeysHelpView: View {
    @State private var selection = ProviderGuide.all[0].id

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Overview") {
                    Label("Adding a key", systemImage: "key.horizontal").tag("overview")
                }
                Section("Providers") {
                    ForEach(ProviderGuide.all + [ProviderGuide.generic]) { guide in
                        Text(guide.name).tag(guide.id)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
        } detail: {
            ScrollView {
                Group {
                    if selection == "overview" {
                        overview
                    } else if let guide = (ProviderGuide.all + [ProviderGuide.generic]).first(where: { $0.id == selection }) {
                        KeyGuideView(guide: guide)
                    }
                }
                .frame(maxWidth: 560, alignment: .leading)
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 720, minHeight: 460)
        .onAppear { selection = "overview" }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Adding API Keys").font(.title2.bold())
            Text("Layer 3 API Data Read steps call data services through **API subscriptions**. "
                 + "Services that need a key get it from the subscription.")
            VStack(alignment: .leading, spacing: 6) {
                step(1, "Open **API Subscriptions** — the key button in the toolbar, Diagram ▸ API Subscriptions… (⌥⌘K), "
                     + "or click a “no API key stored” problem.")
                step(2, "Select the subscription. Under **API Key**, press **?** for that provider's steps and "
                     + "**Get a Key…** to sign up.")
                step(3, "Paste the key into **API key** and press **Save Key**.")
                step(4, "Press **Test Key**: MxJobsMGR calls the provider once and says whether the key was accepted.")
                step(5, "Run the jobspace with Layer 3 set to **Live**, or use **Test Call** on a step.")
            }
            Label("Keys are stored in your login Keychain (service com.k3jdr.MxJobsMGR), never in the jobspace file — "
                  + "share a jobspace without its keys, and enter them again on another Mac.",
                  systemImage: "lock.shield")
                .font(.callout)
                .foregroundStyle(.secondary)
            Label("Remove Key deletes it from the Keychain; deleting a subscription removes its key too.",
                  systemImage: "trash")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func step(_ n: Int, _ markdown: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(n).").monospacedDigit().foregroundStyle(.secondary)
            Text(LocalizedStringKey(markdown)).fixedSize(horizontal: false, vertical: true)
        }
    }
}
