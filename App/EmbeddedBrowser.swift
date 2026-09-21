import SwiftUI
import WebKit
import ArchiveBoxCore

// Embedded pages share an in-memory cookie store; the Keychain API key restores
// the session after relaunch without persisting browser credentials.
@MainActor @Observable final class PageSession {
    let page: WKWebView
    let routing: BrowserNavigation
    var errorMessage: String?
    var isLoading = true
    var navigationLoading = false
    var loadingProgress = 0.0
    @ObservationIgnored private var loadingObservations: [NSKeyValueObservation] = []
    private var started = false
    private var requestID: UUID?
    private var navigation: Task<Void, Never>?
    private unowned let owner: WebPages
    private var destination: URL?
    private var renewedLogin: URL?
    init(_ page: WKWebView, routing: BrowserNavigation, owner: WebPages) {
        self.page = page; self.routing = routing; self.owner = owner
        // Observe WebKit itself so links, back/forward, and redirects count too.
        loadingObservations = [
            page.observe(\.isLoading, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    navigationLoading = self.page.isLoading
                }
            },
            page.observe(\.estimatedProgress, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    loadingProgress = self.page.estimatedProgress
                }
            }
        ]
        // Present the document as soon as WebKit starts rendering it. Archived
        // subframes may keep loading long after the main page is usable.
        routing.didCommit = { [weak self] page in
            guard page.url?.scheme != "about" else { return }
            self?.isLoading = false
        }
        routing.didFail = { [weak self] error in
            self?.isLoading = false
            self?.errorMessage = error.localizedDescription
        }
        routing.didFinish = { [weak self] page in
            guard let self, page.url?.scheme != "about" else { return }
            isLoading = false
            if !owner.hasCredentials { owner.onWebLogin?(page) }
            guard page.url?.path.contains("/login") == true else { renewedLogin = nil; return }
            // Renew an expired session once per login URL, including navigations
            // initiated inside a page rather than only the initial sidebar load.
            guard self.owner.hasCredentials, renewedLogin != page.url, let destination else { return }
            renewedLogin = page.url
            isLoading = true
            navigation = Task {
                do {
                    try await self.owner.authenticate(force: true)
                    try Task.checkCancellation()
                    routing.authenticatedOrigin = owner.authentication.adminURL
                    page.load(URLRequest(url: owner.authentication.authenticatedPageURL(destination)))
                } catch { if !Task.isCancelled { self.isLoading = false; self.errorMessage = error.localizedDescription } }
            }
        }
    }

    func refresh() {
        guard let current = page.url, ["http", "https"].contains(current.scheme) else {
            reconnect()
            return
        }
        destination = current
        errorMessage = nil
        page.reload()
    }

    func reconnect() {
        if let destination { load(destination, requestID: requestID, force: true) }
    }

    func disconnect() {
        navigation?.cancel()
        navigation = nil
        page.stopLoading()
        isLoading = true
        // Stop timers and redirects in cached pages while credentials are absent.
        // Keep the destination so the same connection can authenticate and reload it.
        page.loadHTMLString("", baseURL: nil)
        renewedLogin = nil
    }

    func load(_ url: URL, requestID: UUID?, force: Bool = false) {
        guard force || !started || self.requestID != requestID else { return }
        destination = url
        loadingProgress = 0
        started = true
        self.requestID = requestID
        navigation?.cancel()
        errorMessage = nil
        isLoading = true
        // Navigation belongs to the cached page, not a transient SwiftUI view.
        // Sidebar transitions must not cancel a load and leave a blank cached page.
        navigation = Task {
            do {
                try await owner.authenticate()
                // A superseded load may still finish awaiting the shared login.
                // Stop it before it can cancel the newer navigation on this page.
                try Task.checkCancellation()
                routing.authenticatedOrigin = owner.authentication.adminURL
                page.load(URLRequest(url: owner.authentication.authenticatedPageURL(url)))
            }
            catch { if !Task.isCancelled { isLoading = false; errorMessage = error.localizedDescription } }
        }
    }
}

@MainActor final class WebPages {
    private var pages: [String: PageSession] = [:]
    let authentication = BrowserAuthentication()
    private var server: URL?
    private var token: String?
    private var baseURL: URL?
    private var clearingSession: Task<Void, Never>?
    var hasCredentials: Bool { server != nil && token != nil }
    var onWebLogin: ((WKWebView) -> Void)?

    func reconnectFailedPages() {
        for page in pages.values where page.errorMessage != nil { page.reconnect() }
    }

    func configure(server: URL?, baseURL: URL?, token: String?) {
        guard self.server != server || self.token != token || self.baseURL != baseURL else { return }
        let changedServer = self.server != server
        // A cached page belongs to the server it was created for. Changing its
        // routing boundary would send its old navigations to the external browser.
        for key in pages.keys.filter({ changedServer || pages[$0]?.routing.baseURL != baseURL }) {
            pages.removeValue(forKey: key)?.disconnect()
        }
        self.server = server; self.token = token
        self.baseURL = baseURL
        if changedServer || server == nil || token == nil {
            for page in pages.values { page.disconnect() }
            let previous = clearingSession
            clearingSession = Task {
                await previous?.value
                await authentication.clear()
            }
            if server == nil || token == nil { return }
        }
        for page in pages.values { page.reconnect() }
    }

    func authenticate(force: Bool = false) async throws {
        await clearingSession?.value
        try Task.checkCancellation()
        guard let server, let token else { return }
        try await authentication.authenticate(server: server, token: token, force: force)
    }

    // Retain each screen's page independently, but allocate it only when visited.
    // All pages share the same authenticated in-memory cookie store.
    func page(for key: String, baseURL: URL?, server: URL?, token: String?) -> PageSession {
        // Bind credentials before creating or loading a page. A separate SwiftUI
        // task can run after the first navigation or be cancelled during setup.
        configure(server: server, baseURL: baseURL, token: token)
        if let page = pages[key] { return page }
        let configuration = WKWebViewConfiguration()
        // Match the companion's standalone monitor without stripping the admin
        // chrome from other screens or altering its server-owned polling code.
        configuration.websiteDataStore = authentication.dataStore
        configuration.userContentController.addUserScript(EmbeddedPage.script(activity: key.hasPrefix("activity-")))
        // Each page keeps the routing boundary of its configured connection.
        let routing = BrowserNavigation(baseURL: baseURL)
        // WKWebView exposes authenticated download and blob completion callbacks;
        // SwiftUI's WebPage currently does not. Keep the surrounding UI in SwiftUI.
        let webPage = WKWebView(frame: .zero, configuration: configuration)
        webPage.navigationDelegate = routing
        webPage.uiDelegate = routing
        webPage.allowsBackForwardNavigationGestures = true
        #if os(iOS)
        let headerColor = UIColor(red: 165.0 / 255, green: 28.0 / 255, blue: 80.0 / 255, alpha: 1)
        webPage.isOpaque = false
        webPage.backgroundColor = headerColor
        webPage.underPageBackgroundColor = headerColor
        webPage.scrollView.backgroundColor = headerColor
        webPage.scrollView.bounces = false
        webPage.scrollView.contentInsetAdjustmentBehavior = .never
        #endif
        let page = PageSession(webPage, routing: routing, owner: self)
        pages[key] = page
        return page
    }
}

struct ServerWebView: View {
    let url: URL
    let title: String
    let session: PageSession
    var reloadID: UUID? = nil
    @State private var displayedSession: PageSession?

    private struct LoadRequest: Equatable {
        let session: ObjectIdentifier
        let url: URL
        let reloadID: UUID?
    }

    var body: some View {
        EmbeddedWebView(page: (displayedSession ?? session).page)
            .allowsHitTesting(displayedSession == nil || displayedSession === session)
            .overlay {
                if displayedSession == nil && session.isLoading && session.errorMessage == nil {
                    ProgressView("Connecting…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.background)
                } else if let errorMessage = session.errorMessage {
                    ContentUnavailableView {
                        Label("Couldn’t open \(title)", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button("Try again") { session.load(url, requestID: reloadID, force: true) }.buttonStyle(.glass)
                    }.background(.background)
                }
            }
            .overlay(alignment: .top) {
                if (session.isLoading || session.navigationLoading) && session.errorMessage == nil {
                    GeometryReader { geometry in
                        Color.red
                            .frame(width: geometry.size.width * max(0.04, session.loadingProgress))
                            .animation(.easeOut(duration: 0.15), value: session.loadingProgress)
                    }
                    .frame(height: 3)
                    .allowsHitTesting(false)
                    .accessibilityLabel("Loading page")
                    .accessibilityIdentifier("webview.loadingProgress")
                }
            }
            #if os(iOS)
            .ignoresSafeArea(.container, edges: .bottom)
            .navigationTitle(title)
            #endif
            #if os(macOS)
            .focusedSceneValue(\.visibleWebPage, displayedSession ?? session)
            #endif
            .onChange(of: session.isLoading ? nil : ObjectIdentifier(session), initial: true) {
                if !session.isLoading && session.errorMessage == nil { displayedSession = session }
            }
            .task(id: LoadRequest(session: ObjectIdentifier(session), url: url, reloadID: reloadID)) {
                session.load(url, requestID: reloadID)
            }
    }

}

// Retain one webview per sidebar destination while SwiftUI manages its layout.
#if os(macOS)
private struct EmbeddedWebView: NSViewRepresentable {
    let page: WKWebView
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        guard view.subviews.first !== page else { return }
        view.subviews.forEach { $0.removeFromSuperview() }
        page.frame = view.bounds
        page.autoresizingMask = [.width, .height]
        view.addSubview(page)
    }
}
#else
private struct EmbeddedWebView: UIViewRepresentable {
    let page: WKWebView
    func makeUIView(context: Context) -> UIView { UIView() }
    func updateUIView(_ view: UIView, context: Context) {
        guard view.subviews.first !== page else { return }
        view.subviews.forEach { $0.removeFromSuperview() }
        page.frame = view.bounds
        page.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(page)
    }
}
#endif

#if os(macOS)
private struct VisibleWebPageKey: FocusedValueKey {
    typealias Value = PageSession
}

extension FocusedValues {
    var visibleWebPage: PageSession? {
        get { self[VisibleWebPageKey.self] }
        set { self[VisibleWebPageKey.self] = newValue }
    }
}
#endif
