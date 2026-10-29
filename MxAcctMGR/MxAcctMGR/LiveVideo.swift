//
//  LiveVideo.swift
//  MxAcctMGR
//
//  CNBC Live (Morning Briefing ▸ Watch CNBC Live, Reports ▸ CNBC Live): CNBC's live video in a window of the app's own —
//  moved, resized and kept on top of the other windows as you like, never handed to Safari. One window at a time:
//  opening it again brings it forward. It keeps its place and size between launches, and closing it stops the video.
//
//  The streams (the menu at the window's top left):
//    • CNBC (U.S.), cnbc.com Live TV — the network as it airs. CNBC streams it to CNBC+ subscribers and to viewers
//      who sign in with a TV provider; without a sign-in the page may show a short free preview. The sign-in stays in
//      the window's cookies, as in Safari. Fill Sign-In fills CNBC's sign-in form with the user name and password of
//      your CNBC secure account (Banking ▸ Secure Accounts: its service address on cnbc.com, or CNBC in its name):
//      the user name at once, the password only after Touch ID (or your Mac's password where Touch ID isn't
//      available) confirms it's you, and read from this Mac's Keychain only then; you press the page's Sign In. With no such account the
//      button is Add to Secure Accounts…, which opens New Secure Account filled in for CNBC. A TV provider's sign-in
//      (its own window) you type yourself.
//    • CNBC Television on YouTube — free, live only during the events CNBC streams there (Fed decisions, hearings,
//      special coverage); the channel's page otherwise.
//    • CNBC on YouTube, 24/7 — free and always live, but documentaries and deep dives, not the business-news channel.
//  CNBC doesn't stream its U.S. channel free anywhere, on YouTube or elsewhere (checked 10/29/26).
//
//  LiveVideo.shared is the window's controller: the rest of the app opens it (open), changes its stream (play), keeps
//  it on top (keepOnTop), fills the sign-in (fillSignIn) or closes it, and reads what it shows (stream, isOpen,
//  pageTitle, signInAccount).
//

import AppKit
import LocalAuthentication
import SwiftUI
import WebKit

@MainActor
@Observable
final class LiveVideo {
    static let shared = LiveVideo()

    struct Stream: Identifiable, Hashable {
        var id: String
        var title: String
        var url: URL
        /// What it is and what it needs, under the window's title and on the menu's help.
        var detail: String
        /// The site whose sign-in Fill Sign-In fills from Secure Accounts, when it has one.
        var signInSite: String? = nil
    }

    static let cnbcUS = Stream(id: "cnbc-us", title: "CNBC (U.S.) — cnbc.com Live TV",
                               url: URL(string: "https://www.cnbc.com/live-tv/")!,
                               detail: "The network as it airs: sign in with CNBC+ or your TV provider in the page (a short free preview without one)",
                               signInSite: "cnbc.com")
    static let streams: [Stream] = [
        cnbcUS,
        Stream(id: "cnbc-youtube-live", title: "CNBC Television on YouTube — live events",
               url: URL(string: "https://www.youtube.com/@CNBCtelevision/live")!,
               detail: "Free: live while CNBC streams an event there (Fed decisions, hearings, special coverage)"),
        Stream(id: "cnbc-youtube-247", title: "CNBC on YouTube — 24/7 documentaries",
               url: URL(string: "https://www.youtube.com/@CNBC/live")!,
               detail: "Free and always live: CNBC's documentaries and deep dives, not the business-news channel"),
    ]

    /// The window's place and size, kept in the app's defaults between launches.
    private static let frameName = "CNBC Live"
    private static let streamKey = "liveVideoStream", onTopKey = "liveVideoKeepOnTop"

    /// The stream the window plays (and opens to next time).
    private(set) var stream: Stream
    /// The window floats above the app's and other apps' windows.
    var keepOnTop: Bool {
        didSet {
            UserDefaults.standard.set(keepOnTop, forKey: Self.onTopKey)
            window?.level = keepOnTop ? .floating : .normal
        }
    }
    /// The window is on screen.
    private(set) var isOpen = false
    private(set) var loading = false
    /// The page's own title (a YouTube stream's name, say).
    private(set) var pageTitle = ""
    /// Why the page didn't load, until the next one does.
    private(set) var problem: String?
    /// The page, while the window is open; closing the window lets it go, which stops the video.
    private(set) var webView: WKWebView?
    /// The secure account that signs in to the stream's site, looked up as the window opens or comes forward.
    private(set) var signInAccount: SecureAccount?
    /// What the last Fill Sign-In did.
    private(set) var signInNote: String?

    @ObservationIgnored private var window: NSWindow?
    @ObservationIgnored private let pages = Pages()
    @ObservationIgnored private var titleWatch: NSKeyValueObservation?
    @ObservationIgnored private var closing: NSObjectProtocol?
    @ObservationIgnored private var forward: NSObjectProtocol?

    private init() {
        let saved = UserDefaults.standard.string(forKey: Self.streamKey)
        stream = Self.streams.first { $0.id == saved } ?? Self.cnbcUS
        keepOnTop = UserDefaults.standard.bool(forKey: Self.onTopKey)
        pages.video = self
    }

    /// Shows the window — the one already open, brought forward — playing this stream (or the one it played last).
    func open(_ stream: Stream? = nil) {
        if let stream, stream != self.stream { play(stream) }
        if webView == nil {
            webView = makeWebView()
            load()
        }
        let w = window ?? makeWindow()
        w.level = keepOnTop ? .floating : .normal
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
        isOpen = true
        Task { await findSignInAccount() }
    }

    /// Changes the stream; the window, if open, plays it at once.
    func play(_ stream: Stream) {
        self.stream = stream
        UserDefaults.standard.set(stream.id, forKey: Self.streamKey)
        window?.subtitle = stream.title
        if webView != nil { load() }
        Task { await findSignInAccount() }
    }

    /// Loads the stream's page again (a stalled stream, or after signing in).
    func reload() {
        if webView?.url == nil { load() } else { webView?.reload() }
    }

    func close() { window?.performClose(nil) }

    private func load() {
        problem = nil
        signInNote = nil
        pageTitle = ""
        webView?.load(URLRequest(url: stream.url))
    }

    // MARK: Signing in from Secure Accounts

    /// Looks up the stream's site in Secure Accounts (none for a stream without a sign-in).
    func findSignInAccount() async {
        guard let site = stream.signInSite else { signInAccount = nil; return }
        guard let all = try? await SecureClient.list().secureAccounts else { return }
        signInAccount = Self.account(for: site, in: all)
    }

    /// The secure account for a site: its service address on the site, or the site's name (cnbc) in its own; an active
    /// one first.
    static func account(for site: String, in all: [SecureAccount]) -> SecureAccount? {
        let name = String(site.split(separator: ".").first ?? Substring(site)).lowercased()
        let found = all.filter { a in
            if let host = a.serviceUrl.flatMap(LinkRichText.url(fromAddress:))?.host()?.lowercased(),
               host == site || host.hasSuffix("." + site) { return true }
            return a.name.lowercased().contains(name)
        }
        return found.first(where: \.active) ?? found.first
    }

    /// Fills the sign-in form showing in the page from the secure account: its user name at once; its password only
    /// when the page shows a password field and Touch ID confirms it's you — read from this Mac's Keychain then, and
    /// kept nowhere else. You press the page's Sign In: nothing is sent until you do.
    func fillSignIn() async {
        guard let webView, let a = signInAccount else { return }
        let userName = a.ownerUserName ?? ""
        let hasPassword = SecureSecrets.has(.password, a.id)
        if userName.isEmpty && !hasPassword {
            signInNote = "\(a.name) in Secure Accounts has no user name or password yet: add them in its Edit Service Details."
            return
        }
        do {
            // The user name, and which fields the page shows.
            let found = try await fill(webView, userName: userName, password: "")
            guard found.contains("password"), hasPassword else {
                signInNote = found == "none" ? "No sign-in form is showing: choose Sign In in CNBC's page first, then Fill Sign-In."
                    : found.contains("password") ? "\(a.name) in Secure Accounts has no password: add it in its Edit Service Details."
                    : userName.isEmpty ? "\(a.name) in Secure Accounts has no user name: add it in its Edit Service Details."
                    : "Filled your user name from \(a.name): continue in the page, then Fill Sign-In again for the password."
                return
            }
            // The password, once Touch ID confirms it's you.
            let you = LAContext()
            you.localizedCancelTitle = "Don't Fill"
            do {
                _ = try await you.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "fill in your CNBC password from Secure Accounts")
            } catch let e as LAError where [.userCancel, .appCancel, .systemCancel].contains(e.code) {
                signInNote = "Touch ID was cancelled: the password wasn't filled."
                return
            } catch {
                signInNote = "The password wasn't filled: Touch ID didn't confirm it's you (\(describe(error)))."
                return
            }
            guard let password = SecureSecrets.get(.password, a.id), !password.isEmpty else {
                signInNote = "This Mac's Keychain didn't give the password of \(a.name)."
                return
            }
            _ = try await fill(webView, userName: "", password: password)
            signInNote = "Filled your \(found.contains("user") && !userName.isEmpty ? "user name and " : "")password from \(a.name): press Sign In in the page."
        } catch {
            signInNote = "Couldn't fill the sign-in: \(describe(error))"
        }
    }

    /// Fills what's given (an empty value is left alone); answers the fields the page shows: "user", "password", both
    /// ("user password") or "none".
    private func fill(_ webView: WKWebView, userName: String, password: String) async throws -> String {
        try await webView.callAsyncJavaScript(Self.fillScript, arguments: ["userName": userName, "password": password],
                                              in: nil, contentWorld: .defaultClient) as? String ?? ""
    }

    /// Opens Secure Accounts on New Secure Account filled in for the stream's site (or its account, if there is one).
    func addSignInAccount() {
        guard let site = stream.signInSite, let store = PortAppDelegate.store else { return }
        store.secureRequest = .newSecureAccount(name: site == "cnbc.com" ? "CNBC" : site, api: nil, url: "https://www.\(site)")
        store.go(.secureAccounts)
        NSApp.activate()
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true }?.makeKeyAndOrderFront(nil)
    }

    /// Fills the page's visible sign-in fields — the user name (an e-mail or user field) and the password — as typing
    /// would, so the page's own scripts see them; never submits. Answers which fields it found, as fill(_:userName:password:).
    private static let fillScript = #"""
    const shown = el => !el.disabled && !el.readOnly && el.getClientRects().length > 0 && getComputedStyle(el).visibility !== "hidden";
    const fields = [...document.querySelectorAll("input")].filter(shown);
    const passwordField = fields.find(el => el.type === "password");
    const userField = fields.find(el => el.type === "email" || (["text", ""].includes(el.type) &&
        /e-?mail|user|login|account/i.test([el.name, el.id, el.autocomplete, el.placeholder, el.getAttribute("aria-label")].join(" "))));
    const set = (el, value) => {
        el.focus();
        Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value").set.call(el, value);
        el.dispatchEvent(new Event("input", { bubbles: true }));
        el.dispatchEvent(new Event("change", { bubbles: true }));
    };
    if (userField && userName) set(userField, userName);
    if (passwordField && password) set(passwordField, password);
    return userField && passwordField ? "user password" : userField ? "user" : passwordField ? "password" : "none";
    """#

    // MARK: The page and the window

    private func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()     // a CNBC+ or TV-provider sign-in stays, as in Safari
        config.applicationNameForUserAgent = "Version/18.5 Safari/605.1.15"     // the pages ask for a browser
        config.mediaTypesRequiringUserActionForPlayback = []      // the stream plays as the window opens
        config.allowsAirPlayForMediaPlayback = true
        config.preferences.isElementFullscreenEnabled = true     // the players' full-screen buttons
        let view = WKWebView(frame: .zero, configuration: config)
        view.allowsMagnification = true
        view.uiDelegate = pages
        view.navigationDelegate = pages
        titleWatch = view.observe(\.title, options: [.new]) { [weak self] view, _ in
            MainActor.assumeIsolated { self?.pageTitle = view.title ?? "" }
        }
        return view
    }

    private func makeWindow() -> NSWindow {
        let host = NSHostingController(rootView: LiveVideoView(video: self))
        host.sizingOptions = [.minSize]     // the window is yours to size; the bar and page only set its minimum
        let w = NSWindow(contentViewController: host)
        w.title = "CNBC Live"
        w.subtitle = stream.title
        w.styleMask.insert([.resizable, .miniaturizable])
        w.isReleasedWhenClosed = false
        w.collectionBehavior.insert(.fullScreenPrimary)
        w.setContentSize(NSSize(width: 960, height: 580))
        if !w.setFrameUsingName(Self.frameName) { w.center() }
        w.setFrameAutosaveName(Self.frameName)
        closing = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            MainActor.assumeIsolated { LiveVideo.shared.stopped() }
        }
        // Back from Secure Accounts (a CNBC account just added, say): look it up again.
        forward = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: w, queue: .main) { _ in
            Task { @MainActor in await LiveVideo.shared.findSignInAccount() }
        }
        window = w
        return w
    }

    /// The window closed: the video stops, and its page (and any sign-in window it opened) goes.
    private func stopped() {
        if let webView {
            webView.pauseAllMediaPlayback()
            webView.closeAllMediaPresentations(completionHandler: nil)     // full screen or picture in picture
            webView.stopLoading()
            webView.loadHTMLString("", baseURL: nil)
        }
        titleWatch = nil
        webView = nil
        pages.closePopups()
        isOpen = false
        loading = false
        pageTitle = ""
    }

    /// The pages' loads, and the windows they open (a TV provider's sign-in) — in the app, never in Safari.
    private final class Pages: NSObject, WKNavigationDelegate, WKUIDelegate {
        weak var video: LiveVideo?
        private var popups: [NSWindow] = []

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            guard webView === video?.webView else { return }
            video?.loading = true
            video?.problem = nil
        }
        /// The page is showing: done loading, as far as you can tell (cnbc.com's ads and trackers keep it from finishing).
        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            guard webView === video?.webView else { return }
            video?.loading = false
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard webView === video?.webView else { return }
            video?.loading = false
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            failed(webView, error)
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(webView, error) }
        private func failed(_ webView: WKWebView, _ error: Error) {
            guard webView === video?.webView else { return }
            video?.loading = false
            let e = error as NSError
            guard e.code != NSURLErrorCancelled else { return }     // a page that moved on to the next
            video?.problem = "\(webView.url?.host ?? "The page") didn't load: \(e.localizedDescription)"
        }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            if webView === video?.webView { webView.reload() }
        }

        /// A page's new window (a TV provider's sign-in, a link to another page) opens as a window of the app's own,
        /// still linked to the page that opened it.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            popups.removeAll { !$0.isVisible }
            let size = NSSize(width: windowFeatures.width?.doubleValue ?? 560, height: windowFeatures.height?.doubleValue ?? 720)
            let page = WKWebView(frame: NSRect(origin: .zero, size: size), configuration: configuration)
            page.uiDelegate = self
            let w = NSWindow(contentRect: page.frame, styleMask: [.titled, .closable, .resizable, .miniaturizable],
                             backing: .buffered, defer: false)
            w.title = action.request.url?.host ?? "CNBC Live"
            w.contentView = page
            w.isReleasedWhenClosed = false
            w.level = webView.window?.level ?? .normal
            w.center()
            w.makeKeyAndOrderFront(nil)
            popups.append(w)
            return page
        }
        func webViewDidClose(_ webView: WKWebView) {
            popups.first { $0.contentView === webView }?.close()
        }

        func closePopups() {
            for w in popups { (w.contentView as? WKWebView)?.loadHTMLString("", baseURL: nil); w.close() }
            popups = []
        }
    }
}

private struct LiveWebView: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ view: WKWebView, context: Context) {}
}

struct LiveVideoView: View {
    @Bindable var video: LiveVideo

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("Stream", selection: Binding(get: { video.stream }, set: { video.play($0) })) {
                    ForEach(LiveVideo.streams) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .help("The stream: \(video.stream.detail)")
                Button { video.reload() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Load the stream again (a stalled stream, or after signing in)")
                Toggle(isOn: $video.keepOnTop) { Label("Keep on Top", systemImage: "pin") }
                    .toggleStyle(.button)
                    .help("Keep this window above the others while you read the briefing")
                if video.stream.signInSite != nil {
                    if let a = video.signInAccount {
                        Button { Task { await video.fillSignIn() } } label: { Label("Fill Sign-In", systemImage: "key.fill") }
                            .disabled(video.webView == nil)
                            .help("Fill CNBC's sign-in form with the user name and password of \(a.name) in Secure Accounts — the password after Touch ID, from this Mac's Keychain; then press Sign In in the page")
                    } else {
                        Button { video.addSignInAccount() } label: { Label("Add to Secure Accounts…", systemImage: "key") }
                            .help("Keep your CNBC user name and password in Banking ▸ Secure Accounts (the password in this Mac's Keychain), for Fill Sign-In")
                    }
                }
                if video.loading { ProgressView().controlSize(.small) }
                Spacer(minLength: 8)
                let note = video.problem ?? video.signInNote
                Text(note ?? (video.pageTitle.isEmpty ? video.stream.detail : video.pageTitle))
                    .font(.callout)
                    .foregroundStyle(video.problem != nil ? Color.orange : video.signInNote != nil ? Color.primary : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(note ?? video.stream.detail)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()
            if let webView = video.webView {
                LiveWebView(webView: webView)
            } else {
                Color.black
            }
        }
        .frame(minWidth: 560, minHeight: 320)
    }
}
