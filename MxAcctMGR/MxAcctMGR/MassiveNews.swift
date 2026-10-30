//
//  MassiveNews.swift
//  MxAcctMGR
//
//  The market news right of CNBC Live's video (past the divider): Massive's news feed (massive.com, formerly
//  Polygon.io — GET api.massive.com/v2/reference/news, in every Stocks plan and updated hourly), newest first. Each
//  article shows its headline, publisher and time and its tickers, colored by Massive's sentiment for each (green
//  positive, red negative); its summary shows on hover. Clicking a headline opens the article in your browser, and
//  clicking a ticker narrows the feed to it (the field at the panel's top: empty for all the news).
//
//  The API key is your Massive secure account's (Banking ▸ Secure Accounts: its service address on massive.com, or
//  Massive in its name — not the S3 Flat Files keys): its service key, or its product key where it was kept there. It
//  is read from this Mac's Keychain for each request and sent in the Authorization header, never in a web address.
//
//  MassiveNews.shared is the panel's controller: CNBC Live runs it while the panel shows (setActive), and the rest of
//  the app can narrow it to a ticker (show) or ask again (refresh).
//

import AppKit
import SwiftUI

/// One article of Massive's news feed.
nonisolated struct NewsArticle: Decodable, Identifiable, Hashable {
    struct Publisher: Decodable, Hashable {
        var name: String?
        var homepageUrl: String?
    }
    /// Massive's reading of the article for one of its tickers.
    struct Insight: Decodable, Hashable {
        var ticker: String
        /// positive, negative or neutral.
        var sentiment: String?
        var sentimentReasoning: String?
    }

    var id: String
    var title: String
    var author: String?
    /// RFC 3339, in UTC.
    var publishedUtc: String
    var articleUrl: String
    var description: String?
    var tickers: [String]?
    var publisher: Publisher?
    var insights: [Insight]?

    var url: URL? { URL(string: articleUrl) }
    var published: Date? {
        (try? Date(publishedUtc, strategy: .iso8601))
            ?? (try? Date(publishedUtc, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
    }
    func insight(_ ticker: String) -> Insight? { insights?.first { $0.ticker == ticker } }
}

nonisolated enum MassiveClient {
    static let newsURL = URL(string: "https://api.massive.com/v2/reference/news")!

    struct Failure: LocalizedError {
        var errorDescription: String?
    }

    private struct Page: Decodable {
        var results: [Lossy]?
        var status: String?
        var error: String?
        var message: String?
    }
    /// An article the feed sends without what the panel shows is passed over, not the whole page.
    private struct Lossy: Decodable {
        var article: NewsArticle?
        init(from decoder: Decoder) throws { article = try? NewsArticle(from: decoder) }
    }

    /// The newest articles (only `ticker`'s, unless it's empty).
    static func news(key: String, ticker: String, limit: Int) async throws -> [NewsArticle] {
        var parts = URLComponents(url: newsURL, resolvingAgainstBaseURL: false)!
        parts.queryItems = [URLQueryItem(name: "order", value: "desc"), URLQueryItem(name: "sort", value: "published_utc"),
                            URLQueryItem(name: "limit", value: String(limit))]
            + (ticker.isEmpty ? [] : [URLQueryItem(name: "ticker", value: ticker)])
        var request = URLRequest(url: parts.url!, timeoutInterval: 20)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let page = try? decoder.decode(Page.self, from: data)
        if code == 200, let page, page.status != "ERROR" {
            return (page.results ?? []).compactMap(\.article)
        }
        let said = page?.error ?? page?.message ?? HTTPURLResponse.localizedString(forStatusCode: code)
        let why = switch code {
        case 200: "Massive's answer wasn't the news feed (\(said))."
        case 401: "Massive didn't take the key (\(said)): check it in Secure Accounts."
        case 403: "Your Massive plan doesn't include the news feed (\(said))."
        case 429: "Too many requests for your Massive plan (\(said)): it's asked again in five minutes."
        default: "Massive answered HTTP \(code): \(said)"
        }
        throw Failure(errorDescription: why)
    }
}

@MainActor
@Observable
final class MassiveNews {
    static let shared = MassiveNews()

    /// How often the feed is asked again while the panel shows (Massive updates it hourly; a free key may ask five
    /// times a minute).
    static let every: TimeInterval = 300
    static let limit = 50
    private static let tickerKey = "massiveNewsTicker"

    /// The feed, newest first.
    private(set) var articles: [NewsArticle] = []
    /// Only this ticker's news ("" for all of it).
    private(set) var ticker: String
    /// The secure account whose key asks for the feed, looked up each time it's asked.
    private(set) var account: SecureAccount?
    /// Secure Accounts answered, with or without a Massive account.
    private(set) var accountsLoaded = false
    /// The account has neither a service key nor a product key.
    private(set) var noKey = false
    private(set) var loading = false
    /// Why the last request failed, until one doesn't.
    private(set) var problem: String?
    private(set) var updated: Date?

    @ObservationIgnored private var refreshing: Task<Void, Never>?
    /// Each request's number: only the latest one's answer is shown.
    @ObservationIgnored private var asked = 0

    private init() {
        ticker = UserDefaults.standard.string(forKey: Self.tickerKey) ?? ""
    }

    /// The panel shows (true) or went (false). While it shows, the feed is asked now if it's older than five minutes,
    /// then every five minutes.
    func setActive(_ on: Bool) {
        guard on != (refreshing != nil) else { return }
        refreshing?.cancel()
        refreshing = nil
        guard on else { return }
        refreshing = Task {
            if let updated {
                let wait = Self.every - Date().timeIntervalSince(updated)
                if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            }
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(Self.every))
            }
        }
    }

    /// Only this ticker's news (empty or nil for all of it), asked at once.
    func show(ticker: String?) {
        let t = (ticker ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if t != self.ticker {
            self.ticker = t
            UserDefaults.standard.set(t, forKey: Self.tickerKey)
            articles = []
        }
        Task { await refresh() }
    }

    /// Asks the feed now, with the key of the Massive secure account.
    func refresh() async {
        asked += 1
        let request = asked
        loading = true
        defer { if request == asked { loading = false } }
        do {
            account = Self.account(in: try await SecureClient.list().secureAccounts)
            accountsLoaded = true
        } catch let error where account == nil {
            problem = "Secure Accounts didn't answer, and the Massive key is kept there: \(describe(error))"
            return
        } catch {}      // the account found before still has its key
        guard let account, let key = Self.key(of: account) else {
            noKey = account != nil
            problem = nil
            articles = []
            updated = nil
            return
        }
        noKey = false
        let ticker = ticker
        do {
            let found = try await MassiveClient.news(key: key, ticker: ticker, limit: Self.limit)
            guard request == asked else { return }      // a newer request (another ticker) is on its way
            articles = found
            updated = Date()
            problem = nil
        } catch {
            guard request == asked else { return }
            problem = describe(error)
        }
    }

    /// The window came forward (back from Secure Accounts, say): asked again if it had no account or key.
    func cameForward() {
        if refreshing != nil, accountsLoaded && account == nil || noKey { Task { await refresh() } }
    }

    /// Opens the Massive account in Secure Accounts (Edit Service Details), or New Secure Account filled in for
    /// Massive when there's none.
    func openAccount() {
        guard let store = PortAppDelegate.store else { return }
        store.secureRequest = account.map { .secureAccount($0.id) }
            ?? .newSecureAccount(name: "Massive.com API Key", api: "https://api.massive.com", url: "https://massive.com")
        store.go(.secureAccounts)
        LiveVideo.showMainWindow()
    }

    /// The secure account for Massive's API: its service address or API on massive.com (or polygon.io, its old name),
    /// or Massive in its name — not the S3 Flat Files keys. An active one first, then one named for the API.
    static func account(in all: [SecureAccount]) -> SecureAccount? {
        let found = all.filter { a in
            let name = a.name.lowercased()
            guard !name.contains("s3") else { return false }
            let hosts = [a.serviceUrl, a.serviceApi].compactMap { $0.flatMap(LinkRichText.url(fromAddress:))?.host()?.lowercased() }
            return hosts.contains { h in ["massive.com", "polygon.io"].contains { h == $0 || h.hasSuffix("." + $0) } }
                || name.contains("massive") || name.contains("polygon")
        }
        func rank(_ a: SecureAccount) -> Int { (a.active ? 0 : 2) + (a.name.lowercased().contains("api") ? 0 : 1) }
        return found.min { rank($0) < rank($1) }
    }

    /// The account's API key: its service key (where Secure Accounts keeps API keys), else its product key.
    static func key(of account: SecureAccount) -> String? {
        for kind in [SecureSecrets.Kind.serviceKey, .productKey] {
            if let key = SecureSecrets.get(kind, account.id)?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
                return key
            }
        }
        return nil
    }
}

// MARK: - The panel

struct MassiveNewsView: View {
    @Bindable var news: MassiveNews
    @State private var tickerText = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Label("Market News", systemImage: "newspaper")
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 4)
                TextField("All tickers", text: $tickerText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 92)
                    .onSubmit { news.show(ticker: tickerText) }
                    .help("Only one ticker's news: type its symbol (AAPL) and press Return; empty it for all the news")
                if news.loading { ProgressView().controlSize(.small) }
                Button { Task { await news.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Ask Massive for the latest news now (it's asked every five minutes while the news shows)")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(minWidth: 280, minHeight: 320)
        .onAppear { tickerText = news.ticker }
        .onChange(of: news.ticker) { tickerText = news.ticker }
    }

    @ViewBuilder private var content: some View {
        if news.accountsLoaded && news.account == nil {
            notice("No Massive account in Secure Accounts",
                   detail: "Keep your Massive API key (massive.com ▸ Dashboard ▸ Keys) in Banking ▸ Secure Accounts as a secure account's service key: it stays in this Mac's Keychain.",
                   button: "Add to Secure Accounts…")
        } else if news.noKey, let a = news.account {
            notice("\(a.name) has no key",
                   detail: "Add your Massive API key as its service key in Secure Accounts ▸ Edit Service Details.",
                   button: "Open in Secure Accounts…")
        } else if news.articles.isEmpty {
            VStack(spacing: 8) {
                if let problem = news.problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                } else if news.loading || news.updated == nil {
                    ProgressView()
                } else {
                    Text(news.ticker.isEmpty ? "No news from Massive." : "No news for \(news.ticker).").foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .padding()
        } else {
            VStack(spacing: 0) {
                if let problem = news.problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                    Divider()
                }
                // Each minute, so the times read "12 min. ago" as they pass.
                TimelineView(.everyMinute) { time in
                    List(news.articles) { a in NewsRow(article: a, now: time.date, news: news) }
                        .listStyle(.plain)
                }
            }
        }
    }

    private func notice(_ title: String, detail: String, button: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "key").font(.title2).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button(button) { news.openAccount() }
        }
        .padding(20)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Text(summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if let a = news.account {
                Button { news.openAccount() } label: { Image(systemName: "key") }
                    .buttonStyle(.borderless)
                    .help("The key is \(a.name)'s, in Banking ▸ Secure Accounts: open it there")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    private var summary: String {
        guard let updated = news.updated else { return "From Massive (massive.com)" }
        let count = news.articles.count
        return "\(count) \(count == 1 ? "article" : "articles")\(news.ticker.isEmpty ? "" : " on \(news.ticker)") from Massive · \(updated.formatted(date: .omitted, time: .shortened))"
    }
}

/// An article: its headline (click to read it in your browser), publisher and time, and tickers (click one for only
/// its news), the summary on hover.
private struct NewsRow: View {
    let article: NewsArticle
    /// The minute it was drawn, for its time.
    let now: Date
    let news: MassiveNews

    private static let ago: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { open() } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(article.title)
                        .font(.callout.weight(.semibold))
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                    Text([article.publisher?.name, when].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(article.description ?? article.title)
            if let tickers = article.tickers, !tickers.isEmpty {
                HStack(spacing: 4) {
                    ForEach(tickers.prefix(5), id: \.self) { chip($0) }
                    if tickers.count > 5 { Text("+\(tickers.count - 5)").font(.caption2).foregroundStyle(.secondary) }
                }
            }
        }
        .padding(.vertical, 3)
        .contextMenu {
            Button("Open in Browser") { open() }
            Button("Copy Link") { copy(article.articleUrl) }
            Button("Copy Headline") { copy(article.title) }
            if let tickers = article.tickers, !tickers.isEmpty {
                Divider()
                ForEach(tickers.prefix(8), id: \.self) { t in Button("Only \(t)'s News") { news.show(ticker: t) } }
            }
            if !news.ticker.isEmpty { Button("All the News") { news.show(ticker: nil) } }
        }
    }

    /// "12 min. ago" for today's, the day and time for older ones.
    private var when: String? {
        guard let d = article.published else { return nil }
        return now.timeIntervalSince(d) < 12 * 3600 ? Self.ago.localizedString(for: d, relativeTo: now)
            : d.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    private func chip(_ ticker: String) -> some View {
        let insight = article.insight(ticker)
        let color: Color = switch insight?.sentiment {
        case "positive": .green
        case "negative": .red
        default: .secondary
        }
        return Button { news.show(ticker: ticker) } label: {
            Text(ticker)
                .font(.caption2.monospaced().weight(.medium))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .foregroundStyle(color)
                .background(color.opacity(0.14), in: Capsule())
        }
        .buttonStyle(.plain)
        .help((insight?.sentiment.map { s in "Massive reads it \(s) for \(ticker)" + (insight?.sentimentReasoning.map { ": \($0)\n" } ?? ".\n") } ?? "")
              + "Click for only \(ticker)'s news.")
    }

    private func open() { if let url = article.url { NSWorkspace.shared.open(url) } }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
