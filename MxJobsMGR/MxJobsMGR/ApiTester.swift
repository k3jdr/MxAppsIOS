//
//  ApiTester.swift
//  MxJobsMGR
//
//  "Test Call" for a Layer 3 API read: builds the request from the subscription and the
//  node (with {{argument}} substitution and the Keychain key), sends it once, and checks
//  the expected outcome (status codes and required JSON fields).
//

import Foundation

struct ApiTestResult {
    var url: String
    var status: Int?
    var elapsed: TimeInterval
    var body: String
    var checks: [(label: String, passed: Bool)]
    var error: String?
    /// The parsed response, when it was JSON.
    var json: Any?

    var passed: Bool { error == nil && checks.allSatisfy(\.passed) }
}

enum ApiTester {
    /// Replaces {{name}} with argument values and the built-ins {{today}} / {{yesterday}} (yyyy-MM-dd), and
    /// placeholders that read the outputs of the steps linked into this one (their output names):
    /// {{in:path}} a value (text, number, or compact JSON), {{json:path}} the value as JSON — e.g.
    /// {"inputsUrl": "{{in:optInputs.inputsUrl}}"} or {"weights": {{json:optimization.weights}}}.
    static func substitute(_ text: String, arguments: [Argument], inputs: [String: Any] = [:]) -> String {
        var out = text
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        let now = Date()
        var values: [String: String] = [
            "today": f.string(from: now),
            "yesterday": f.string(from: now.addingTimeInterval(-86_400)),
        ]
        for arg in arguments where !arg.name.isEmpty {
            // A symbol list tests with its first symbol.
            values[arg.name] = arg.type == .symbols
                ? (arg.value.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? "")
                : arg.value
        }
        for (k, v) in values { out = out.replacingOccurrences(of: "{{\(k)}}", with: v) }
        return fillInputs(out, inputs)
    }

    /// {{in:path}} / {{json:path}} from the inputs (dotted paths; keys may contain dots).
    static func fillInputs(_ text: String, _ inputs: [String: Any]) -> String {
        guard text.contains("{{in:") || text.contains("{{json:") else { return text }
        var out = ""
        var rest = Substring(text)
        while let open = rest.range(of: "{{"), let close = rest.range(of: "}}", range: open.upperBound..<rest.endIndex) {
            out += rest[..<open.lowerBound]
            let token = String(rest[open.upperBound..<close.lowerBound])
            if token.hasPrefix("in:") || token.hasPrefix("json:") {
                let asJSON = token.hasPrefix("json:")
                let path = String(token.dropFirst(asJSON ? 5 : 3)).trimmingCharacters(in: .whitespaces)
                let value = lookup(path, in: inputs)
                if asJSON {
                    out += value.map(jsonText) ?? "null"
                } else if let s = value as? String {
                    out += s
                } else if let n = value as? NSNumber {
                    out += n.stringValue
                } else {
                    out += value.map(jsonText) ?? ""
                }
            } else {
                out += rest[open.lowerBound..<close.upperBound]
            }
            rest = rest[close.upperBound...]
        }
        return out + rest
    }

    nonisolated private static func jsonText(_ value: Any) -> String {
        if let s = value as? String, let data = try? JSONSerialization.data(withJSONObject: [s]),
           let text = String(data: data, encoding: .utf8) {
            return String(text.dropFirst().dropLast())        // the quoted, escaped string
        }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]) {
            return String(decoding: data, as: UTF8.self)
        }
        if let n = value as? NSNumber { return n.stringValue }
        return "null"
    }

    static func buildRequest(node: JobNode, subscription sub: ApiSubscription, key: String?,
                             inputs: [String: Any] = [:]) throws -> URLRequest {
        guard let api = node.api else { throw TestError("Not an API node.") }
        let base = sub.baseURL.hasSuffix("/") ? String(sub.baseURL.dropLast()) : sub.baseURL
        var path = substitute(api.path, arguments: node.arguments, inputs: inputs)
        if !path.isEmpty, !path.hasPrefix("/") { path = "/" + path }
        guard var comps = URLComponents(string: base + path), comps.host != nil else {
            throw TestError("Invalid URL: \(base + path)")
        }
        var items = comps.queryItems ?? []
        for q in api.query where !q.key.isEmpty {
            let value = substitute(q.value, arguments: node.arguments, inputs: inputs)
            // An optional argument left empty leaves its parameter out ("max={{maxCalls}}" with no maxCalls).
            if value.isEmpty, q.value.contains("{{") { continue }
            items.append(URLQueryItem(name: q.key, value: value))
        }
        if sub.auth == .queryParameter, let key {
            items.append(URLQueryItem(name: sub.keyName.isEmpty ? "apikey" : sub.keyName, value: key))
        }
        comps.queryItems = items.isEmpty ? nil : items
        guard let url = comps.url else { throw TestError("Could not build the URL.") }

        var request = URLRequest(url: url, timeoutInterval: TimeInterval(max(1, node.exceptions.timeoutSeconds)))
        request.httpMethod = api.method.rawValue
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for h in sub.defaultHeaders + api.headers where !h.key.isEmpty {
            request.setValue(substitute(h.value, arguments: node.arguments, inputs: inputs), forHTTPHeaderField: h.key)
        }
        switch sub.auth {
        case .header: if let key { request.setValue(key, forHTTPHeaderField: sub.keyName.isEmpty ? "X-API-Key" : sub.keyName) }
        case .bearer, .localService: if let key { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        case .none, .queryParameter: break
        }
        if api.method == .POST, !api.body.isEmpty {
            request.httpBody = Data(substitute(api.body, arguments: node.arguments, inputs: inputs).utf8)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    /// Sends the step's request once; `inputs` are the outputs of the steps linked into it ({{in:…}}).
    static func run(node: JobNode, subscription sub: ApiSubscription, inputs: [String: Any] = [:]) async -> ApiTestResult {
        let key = sub.auth == .none ? nil : Keychain.secret(for: sub.keychainAccount)
        let request: URLRequest
        do {
            if sub.auth.requiresKey, key == nil { throw TestError("No API key stored for “\(sub.name)”. Add one under API Subscriptions.") }
            request = try buildRequest(node: node, subscription: sub, key: key, inputs: inputs)
        } catch {
            return ApiTestResult(url: "", status: nil, elapsed: 0, body: "", checks: [], error: error.localizedDescription)
        }
        let shownURL = redacted(request.url, sub: sub)
        let started = Date()
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let elapsed = Date().timeIntervalSince(started)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            var checks = [(label: "HTTP \(status) in \(node.outcome.successStatus)",
                           passed: statusMatches(status, node.outcome.successStatus))]
            checks += outcomeChecks(node, json: json)
            // Providers like Alpha Vantage report a bad key or a reached limit in a 200 response.
            let notice = checks.allSatisfy(\.passed) ? nil
                : KeyTester.providerMessage(json as? [String: Any]).map { "\(sub.name): \($0)" }
            return ApiTestResult(url: shownURL, status: status, elapsed: elapsed,
                                 body: pretty(data, json: json), checks: checks, error: notice, json: json)
        } catch {
            return ApiTestResult(url: shownURL, status: nil, elapsed: Date().timeIntervalSince(started),
                                 body: "", checks: [], error: error.localizedDescription)
        }
    }

    /// Required fields and value assertions of a step's expected outcome, against its JSON result.
    static func outcomeChecks(_ node: JobNode, json: Any?) -> [(label: String, passed: Bool)] {
        var checks: [(label: String, passed: Bool)] = []
        for field in node.outcome.requiredFields where !field.isEmpty {
            checks.append((label: "Field “\(field)” present", passed: json.map { lookup(field, in: $0) != nil } ?? false))
        }
        for assertion in node.outcome.assertions where !assertion.path.isEmpty {
            let expected = substitute(assertion.value, arguments: node.arguments)
            let actual = json.flatMap { lookup(assertion.path, in: $0) }
            let passed = evaluate(actual, assertion.op, expected)
            let shown = assertion.op == .exists ? "\(assertion.path) exists" : "\(assertion.path) \(assertion.op.rawValue) \(expected)"
            checks.append((label: passed ? shown : "\(shown) (got \(describe(actual)))", passed: passed))
        }
        return checks
    }

    /// Compares numerically when both sides are numbers, else as text.
    static func evaluate(_ actual: Any?, _ op: AssertionOp, _ expected: String) -> Bool {
        let present = actual != nil && !(actual is NSNull)
        if op == .exists { return present }
        guard present, let actual else { return false }
        let actualNumber = (actual as? NSNumber).flatMap { CFGetTypeID($0) == CFBooleanGetTypeID() ? nil : $0.doubleValue }
        let expectedNumber = Double(expected.trimmingCharacters(in: .whitespaces))
        if let a = actualNumber, let e = expectedNumber {
            switch op {
            case .equals: return abs(a - e) <= 1e-9 * max(1, abs(e))
            case .notEquals: return abs(a - e) > 1e-9 * max(1, abs(e))
            case .less: return a < e
            case .lessOrEqual: return a <= e
            case .greater: return a > e
            case .greaterOrEqual: return a >= e
            case .contains, .exists: break
            }
        }
        let text = describe(actual)
        switch op {
        case .equals: return text == expected
        case .notEquals: return text != expected
        case .contains:
            if let array = actual as? [Any] { return array.contains { describe($0) == expected } }
            if let dict = actual as? [String: Any] { return dict[expected] != nil }
            return text.contains(expected)
        default: return false  // ordering needs numbers
        }
    }

    static func describe(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "null" }
        if let s = value as? String { return s }
        if let n = value as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
            return n.stringValue
        }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
            let s = String(decoding: data, as: UTF8.self)
            return s.count > 60 ? String(s.prefix(60)) + "…" : s
        }
        return String(describing: value)
    }

    /// "200-299", "200,304", "2xx".
    static func statusMatches(_ status: Int, _ spec: String) -> Bool {
        let parts = spec.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        if parts.isEmpty { return (200..<300).contains(status) }
        return parts.contains { part in
            if part.hasSuffix("xx"), let d = Int(part.prefix(1)) { return status / 100 == d }
            let bounds = part.split(separator: "-").compactMap { Int($0) }
            if bounds.count == 2 { return (bounds[0]...bounds[1]).contains(status) }
            return Int(part) == status
        }
    }

    /// Dotted path lookup; array elements by index ("filings.recent.form.0"). Keys may contain
    /// dots themselves ("Global Quote.05. price"): the longest matching key wins at each level.
    static func lookup(_ path: String, in json: Any) -> Any? {
        lookup(path.split(separator: ".", omittingEmptySubsequences: false).map(String.init)[...], in: json)
    }

    private static func lookup(_ parts: ArraySlice<String>, in json: Any) -> Any? {
        guard !parts.isEmpty else { return json }
        if let dict = json as? [String: Any] {
            for n in stride(from: parts.count, through: 1, by: -1) {
                let key = parts.prefix(n).joined(separator: ".")
                if let next = dict[key], let found = lookup(parts.dropFirst(n), in: next) { return found }
            }
            return nil
        }
        if let array = json as? [Any], let i = Int(parts.first!), array.indices.contains(i) {
            return lookup(parts.dropFirst(), in: array[i])
        }
        return nil
    }

    private static func pretty(_ data: Data, json: Any?) -> String {
        var text: String
        if let json, let out = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]) {
            text = String(decoding: out, as: UTF8.self)
        } else {
            text = String(decoding: data, as: UTF8.self)
        }
        if text.count > 20_000 { text = String(text.prefix(20_000)) + "\n… (truncated)" }
        return text
    }

    private static func redacted(_ url: URL?, sub: ApiSubscription) -> String {
        guard let url, var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url?.absoluteString ?? "" }
        if sub.auth == .queryParameter {
            comps.queryItems = comps.queryItems?.map {
                $0.name == sub.keyName ? URLQueryItem(name: $0.name, value: "•••") : $0
            }
        }
        return comps.string ?? url.absoluteString
    }
}

struct TestError: LocalizedError {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
