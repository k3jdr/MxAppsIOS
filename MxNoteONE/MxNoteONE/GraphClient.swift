//
//  GraphClient.swift
//  MxNoteONE
//
//  Microsoft Graph requests for OneNote (v1.0 /me/onenote/…): JSON calls,
//  paged lists, page creation as multipart HTML with pictures and files,
//  resource downloads. Retries after throttling (429 / 503) and refreshes
//  the token once on 401.
//

import Foundation

final class GraphClient {
    static let shared = GraphClient()
    private let base = "https://graph.microsoft.com/v1.0"

    /// A file sent with a new page, referenced from the HTML as "name:<name>".
    struct Part {
        var name: String
        var contentType: String
        var data: Data
    }

    private func url(_ pathOrURL: String) -> URL {
        URL(string: pathOrURL.hasPrefix("https://") ? pathOrURL : base + pathOrURL)!
    }

    func send(_ method: String, _ pathOrURL: String, body: Data? = nil, contentType: String? = nil) async throws -> (Data, HTTPURLResponse) {
        var refreshed = false
        var attempt = 0
        while true {
            var request = URLRequest(url: url(pathOrURL))
            request.httpMethod = method
            request.httpBody = body
            request.timeoutInterval = 120
            if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
            request.setValue("Bearer " + (try await OneDriveAuth.shared.token()),
                             forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw OneDriveError.server("No response from Microsoft Graph.") }
            switch http.statusCode {
            case 200..<300:
                return (data, http)
            case 401 where !refreshed:
                refreshed = true
                _ = try await OneDriveAuth.shared.token(forceRefresh: true)
                continue
            case 429, 503, 504:
                guard attempt < 6 else { throw Self.error(from: data, status: http.statusCode) }
                attempt += 1
                let wait = Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? pow(2, Double(attempt))
                try await Task.sleep(for: .seconds(min(wait, 60)))
                continue
            default:
                throw Self.error(from: data, status: http.statusCode)
            }
        }
    }

    static func error(from data: Data, status: Int) -> OneDriveError {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let message = (json?["error"] as? [String: Any])?["message"] as? String
        return .server("Microsoft Graph error \(status)" + (message.map { ": \($0)" } ?? "."))
    }

    func json(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        let payload = try body.map { try JSONSerialization.data(withJSONObject: $0) }
        let (data, _) = try await send(method, path, body: payload, contentType: body == nil ? nil : "application/json")
        if data.isEmpty { return [:] }
        return (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    /// Every item of a collection, following @odata.nextLink.
    func list(_ path: String) async throws -> [[String: Any]] {
        var items: [[String: Any]] = []
        var next: String? = path
        while let current = next {
            let page = try await json("GET", current)
            items += page["value"] as? [[String: Any]] ?? []
            next = page["@odata.nextLink"] as? String
        }
        return items
    }

    func data(_ pathOrURL: String) async throws -> Data {
        try await send("GET", pathOrURL).0
    }

    func delete(_ path: String) async throws {
        _ = try await send("DELETE", path)
    }

    /// Creates a page in a section from HTML and its pictures and files.
    func createPage(inSection sectionID: String, html: String, parts: [Part]) async throws -> [String: Any] {
        let boundary = "MxNoteONE-" + UUID().uuidString
        var body = Data()
        func add(_ string: String) { body.append(Data(string.utf8)) }
        add("--\(boundary)\r\nContent-Disposition: form-data; name=\"Presentation\"\r\nContent-Type: text/html\r\n\r\n")
        add(html)
        add("\r\n")
        for part in parts {
            add("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(part.name)\"\r\nContent-Type: \(part.contentType)\r\n\r\n")
            body.append(part.data)
            add("\r\n")
        }
        add("--\(boundary)--\r\n")
        let (data, _) = try await send("POST", "/me/onenote/sections/\(sectionID)/pages", body: body,
                                       contentType: "multipart/form-data; boundary=\(boundary)")
        return (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    static func date(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}
