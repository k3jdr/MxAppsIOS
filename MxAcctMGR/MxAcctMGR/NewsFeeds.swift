//
//  NewsFeeds.swift
//  MxAcctMGR
//
//  The sources of CNBC Live's Market News (the menu at the panel's top), and how those other than Massive are read
//  (MarketNews.swift has Massive's). None needs a key or a sign-in. All checked 10/30/26:
//    • CNBC press releases — the data in the cnbc.com/press-releases page. CNBC's RSS for that section (id 10000027)
//      answers with no items, so the page is the only list there is.
//    • Yahoo Finance — its headline RSS, for the three main indexes or one ticker.
//    • Google News, Business — its RSS. Google Finance itself has no feed or public endpoint (its page is drawn by
//      scripts), so this stands in for it and is named for what it is.
//    • Wall Street Journal — Dow Jones's Markets RSS (the older feeds.a.dj.com stopped in January 2025): headlines and
//      a line of summary, and the articles open in your browser behind WSJ's paywall.
//
//  What a source sends is untrusted: it's reduced to plain text of a limited length here, only web addresses open
//  (NewsArticle.url), and nothing in it is run, loaded or asked for.
//

import Foundation

/// Where the panel's news comes from.
nonisolated enum NewsSource: String, CaseIterable, Identifiable {
    case massive, cnbcPress, yahoo, googleNews, wsj

    var id: String { rawValue }

    /// In the menu.
    var title: String {
        switch self {
        case .massive: "Massive API"
        case .cnbcPress: "CNBC Press Releases"
        case .yahoo: "Yahoo Finance"
        case .googleNews: "Google News — Business"
        case .wsj: "Wall Street Journal"
        }
    }
    /// In the panel's sentences.
    var name: String {
        switch self {
        case .massive: "Massive"
        case .cnbcPress: "CNBC"
        case .yahoo: "Yahoo Finance"
        case .googleNews: "Google News"
        case .wsj: "The Wall Street Journal"
        }
    }
    var site: String {
        switch self {
        case .massive: "massive.com"
        case .cnbcPress: "cnbc.com"
        case .yahoo: "yahoo.com"
        case .googleNews: "google.com"
        case .wsj: "wsj.com"
        }
    }
    /// What it is, on the menu's help.
    var detail: String {
        switch self {
        case .massive: "Massive's news feed, with your API key in Secure Accounts: sentiment on each ticker"
        case .cnbcPress: "CNBC's own announcements and interview transcripts, from its Press Releases page"
        case .yahoo: "Yahoo Finance's headlines on the main indexes, or on the ticker you type"
        case .googleNews: "Google News's Business section (Google Finance itself has no feed to read)"
        case .wsj: "The Journal's Markets headlines; reading the articles takes a WSJ subscription"
        }
    }
    /// It can narrow its news to one ticker.
    var takesTicker: Bool { self == .massive || self == .yahoo }

    fileprivate func feedURL(ticker: String) -> URL {
        switch self {
        case .massive: MassiveClient.newsURL
        case .cnbcPress: URL(string: "https://www.cnbc.com/press-releases/")!
        case .yahoo: {
            var parts = URLComponents(string: "https://feeds.finance.yahoo.com/rss/2.0/headline")!
            parts.queryItems = [URLQueryItem(name: "s", value: ticker.isEmpty ? "^GSPC,^DJI,^IXIC" : ticker),
                                URLQueryItem(name: "region", value: "US"), URLQueryItem(name: "lang", value: "en-US")]
            return parts.url!
        }()
        case .googleNews: URL(string: "https://news.google.com/rss/headlines/section/topic/BUSINESS?hl=en-US&gl=US&ceid=US:en")!
        case .wsj: URL(string: "https://feeds.content.dowjones.io/public/rss/RSSMarketsMain")!
        }
    }
}

/// Why a source's news didn't come, in the panel's words.
nonisolated struct NewsFailure: LocalizedError {
    var errorDescription: String?
}

nonisolated enum NewsFeeds {
    /// An item as a source sends it, before it's cleaned.
    fileprivate struct Item {
        var title = "", link = "", guid = "", date = "", summary = "", publisher = ""
    }

    /// The source's newest articles (only `ticker`'s, where it can narrow them and it isn't empty).
    static func articles(from source: NewsSource, ticker: String, limit: Int) async throws -> [NewsArticle] {
        let data = try await fetch(source.feedURL(ticker: ticker), source: source)
        let items = source == .cnbcPress ? try pressReleases(in: data) : try feedItems(in: data, source: source)
        var seen = Set<String>()
        let found = items.compactMap { article($0, source: source) }.filter { seen.insert($0.id).inserted }
        // Not every feed sends them in order; those without a date go last.
        return Array(found.sorted { ($0.published ?? .distantPast) > ($1.published ?? .distantPast) }.prefix(limit))
    }

    private static func fetch(_ url: URL, source: NewsSource) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("MxAcctMGR/1.0", forHTTPHeaderField: "User-Agent")
        request.httpShouldHandleCookies = false
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch code {
        case 200: return data
        case 429: throw NewsFailure(errorDescription: "\(source.name) says too many requests: it's asked again in five minutes.")
        default: throw NewsFailure(errorDescription: "\(source.name) answered HTTP \(code): \(HTTPURLResponse.localizedString(forStatusCode: code))")
        }
    }

    /// A panel article from what the source sent, or nil without a headline or a web address.
    private static func article(_ item: Item, source: NewsSource) -> NewsArticle? {
        let link = item.link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let title = plain(item.title, limit: 300) else { return nil }
        // Google News ends its headlines with the publisher, which the row shows anyway.
        let publisherName = plain(item.publisher, limit: 80)
        let headline = publisherName.map { title.hasSuffix(" - \($0)") ? String(title.dropLast($0.count + 3)) : title } ?? title
        // Google News's summaries are its links to related stories, not a summary.
        let summary = source == .googleNews ? nil : plain(item.summary, limit: 600)
        let date = published(item.date)?.formatted(.iso8601) ?? ""
        var found = NewsArticle(id: link, title: headline, publishedUtc: date, articleUrl: link, description: summary)
        guard let host = found.url?.host()?.lowercased() else { return nil }
        // A publisher Yahoo links to goes by its own site.
        let site = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let own = site == source.site || site.hasSuffix("." + source.site)
        found.publisher = .init(name: publisherName ?? (own ? source.title : site))
        return found
    }

    // MARK: RSS

    private static func feedItems(in data: Data, source: NewsSource) throws -> [Item] {
        let reader = FeedReader()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = reader
        let read = parser.parse()
        guard reader.sawFeed, read || !reader.items.isEmpty else {
            throw NewsFailure(errorDescription: "\(source.name)'s answer wasn't a news feed.")
        }
        return reader.items
    }

    private final class FeedReader: NSObject, XMLParserDelegate {
        var items: [Item] = []
        var sawFeed = false
        private var item: Item?
        private var text = ""

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            if name == "rss" { sawFeed = true }
            if name == "item" { item = Item() }
            text = ""
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
        func parser(_ parser: XMLParser, foundCDATA data: Data) { text += String(decoding: data, as: UTF8.self) }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            switch name {
            case "item":
                if let item { items.append(item) }
                item = nil
            case "title": item?.title = text
            case "link": item?.link = text
            case "guid": item?.guid = text
            case "pubDate": item?.date = text
            case "description": item?.summary = text
            case "source": item?.publisher = text
            default: break
            }
            text = ""
        }
    }

    // MARK: CNBC's Press Releases page

    /// The releases in the page's data (its window.__s_data), wherever on the page they're laid out.
    private static func pressReleases(in data: Data) throws -> [Item] {
        let changed = NewsFailure(errorDescription: "CNBC's Press Releases page has changed: its list couldn't be read.")
        guard let page = String(data: data, encoding: .utf8),
              let name = page.range(of: "window.__s_data"),
              let open = page.range(of: "{", range: name.upperBound..<page.endIndex),
              let end = page.range(of: #"\}\s*;\s*window\."#, options: .regularExpression, range: open.lowerBound..<page.endIndex),
              let json = page[open.lowerBound...end.lowerBound].data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: json) else { throw changed }
        var found: [Item] = []
        collectReleases(in: root, depth: 0, into: &found)
        guard !found.isEmpty else { throw changed }
        return found
    }

    private static func collectReleases(in value: Any, depth: Int, into found: inout [Item]) {
        guard depth < 40 else { return }
        if let list = value as? [Any] {
            for v in list { collectReleases(in: v, depth: depth + 1, into: &found) }
        } else if let fields = value as? [String: Any] {
            // The page's top cards name it "title", the list below "headline".
            if fields["type"] as? String == "pressrelease", let title = (fields["headline"] ?? fields["title"]) as? String, let link = fields["url"] as? String,
               let host = URL(string: link)?.host()?.lowercased(), host == "cnbc.com" || host.hasSuffix(".cnbc.com") {
                found.append(Item(title: title, link: link, date: fields["datePublished"] as? String ?? "",
                                  summary: fields["description"] as? String ?? ""))
            }
            for v in fields.values { collectReleases(in: v, depth: depth + 1, into: &found) }
        }
    }

    // MARK: Cleaning what came

    /// The formats the sources send: RSS's (with "+0000" or "GMT") and CNBC's page's.
    private static let dateFormats: [DateFormatter] = ["EEE, dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm:ss zzz", "yyyy-MM-dd'T'HH:mm:ssZ"].map {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = $0
        return f
    }

    private static func published(_ text: String) -> Date? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return dateFormats.lazy.compactMap { $0.date(from: text) }.first
    }

    /// A source's text as a line of plain text at most `limit` long, or nil if nothing's left: its entities decoded and
    /// its tags and control characters gone. By hand, because NSAttributedString's HTML reader would fetch what the
    /// text points to.
    static func plain(_ text: String, limit: Int) -> String? {
        let decoded = decodingEntities(text)
            .replacing(#/<[^>]*>/#, with: " ")
            .replacing(#/\s+/#, with: " ")
        let kept = decoded.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let line = String(String.UnicodeScalarView(kept)).trimmingCharacters(in: .whitespaces)
        return line.isEmpty ? nil : String(line.prefix(limit))
    }

    private static let named = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "mdash": "—", "ndash": "–",
                                "hellip": "…", "rsquo": "’", "lsquo": "‘", "rdquo": "”", "ldquo": "“"]

    private static func decodingEntities(_ text: String) -> String {
        text.replacing(#/&(#[xX][0-9a-fA-F]{1,6}|#[0-9]{1,7}|[a-zA-Z]+);/#) { match in
            let entity = String(match.output.1)
            if let name = named[entity] { return name }
            guard entity.hasPrefix("#") else { return String(match.output.0) }
            let number = entity.dropFirst()
            let code = number.first?.lowercased() == "x" ? UInt32(number.dropFirst(), radix: 16) : UInt32(number)
            return code.flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? ""
        }
    }
}
