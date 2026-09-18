import SwiftUI
import WebKit
import ArchiveBoxCore

// Embedded pages share an in-memory cookie store; the Keychain API key restores
// the session after relaunch without persisting browser credentials.
@MainActor @Observable final class PageSession {
    let page: WKWebView
    let routing: BrowserNavigation
    var errorMessage: String?
    private var started = false
    private var requestID: UUID?
    private var navigation: Task<Void, Never>?
    private unowned let owner: WebPages
    private var destination: URL?
    private var renewedLogin: URL?
    init(_ page: WKWebView, routing: BrowserNavigation, owner: WebPages) {
        self.page = page; self.routing = routing; self.owner = owner
        routing.didFail = { [weak self] error in self?.errorMessage = error.localizedDescription }
        routing.didFinish = { [weak self] page in
            guard let self else { return }
            guard page.url?.path.contains("/login") == true else { renewedLogin = nil; return }
            // Renew an expired session once per login URL, including navigations
            // initiated inside a page rather than only the initial sidebar load.
            guard owner.hasCredentials, renewedLogin != page.url, let destination else { return }
            renewedLogin = page.url
            navigation = Task {
                do {
                    try await owner.authenticate(force: true)
                    try Task.checkCancellation()
                    page.load(URLRequest(url: destination))
                } catch { if !Task.isCancelled { errorMessage = error.localizedDescription } }
            }
        }
    }

    func reconnect() {
        if let destination { load(destination, requestID: requestID, force: true) }
    }

    func load(_ url: URL, requestID: UUID?, force: Bool = false) {
        guard force || !started || self.requestID != requestID else { return }
        destination = url
        started = true
        self.requestID = requestID
        navigation?.cancel()
        errorMessage = nil
        // Navigation belongs to the cached page, not a transient SwiftUI view.
        // Sidebar transitions must not cancel a load and leave a blank cached page.
        navigation = Task {
            do {
                try await owner.authenticate()
                // A superseded load may still finish awaiting the shared login.
                // Stop it before it can cancel the newer navigation on this page.
                try Task.checkCancellation()
                page.load(URLRequest(url: url))
            }
            catch { if !Task.isCancelled { errorMessage = error.localizedDescription } }
        }
    }
}

@MainActor final class WebPages {
    private var pages: [String: PageSession] = [:]
    let authentication = BrowserAuthentication()
    private var server: URL?
    private var token: String?
    private var baseURL: URL?
    var hasCredentials: Bool { server != nil && token != nil }

    func configure(server: URL?, baseURL: URL?, token: String?) async {
        guard self.server != server || self.token != token || self.baseURL != baseURL else { return }
        self.server = server; self.token = token
        self.baseURL = baseURL
        for page in pages.values { page.routing.baseURL = baseURL }
        if server == nil || token == nil { await authentication.clear() }
        for page in pages.values { page.reconnect() }
    }

    func authenticate(force: Bool = false) async throws {
        guard let server, let token else { return }
        try await authentication.authenticate(server: server, token: token, force: force)
    }

    // Retain each screen's page independently, but allocate it only when visited.
    // All pages share the same authenticated in-memory cookie store.
    func page(for key: String, baseURL: URL?) -> PageSession {
        if let page = pages[key] { return page }
        let configuration = WKWebViewConfiguration()
        // Match the companion's standalone monitor without stripping the admin
        // chrome from other screens or altering its server-owned polling code.
        configuration.websiteDataStore = authentication.dataStore
        configuration.userContentController.addUserScript(EmbeddedPage.script(activity: key.hasPrefix("activity-")))
        // Supply the boundary synchronously: SwiftUI can create/load the page
        // before the asynchronous connection task has configured authentication.
        let routing = BrowserNavigation(baseURL: baseURL)
        // WKWebView exposes authenticated download and blob completion callbacks;
        // SwiftUI's WebPage currently does not. Keep the surrounding UI in SwiftUI.
        let webPage = WKWebView(frame: .zero, configuration: configuration)
        webPage.navigationDelegate = routing
        webPage.uiDelegate = routing
        webPage.allowsBackForwardNavigationGestures = true
        #if os(iOS)
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
    var body: some View {
        EmbeddedWebView(page: session.page)
            .overlay {
                if let errorMessage = session.errorMessage {
                    ContentUnavailableView {
                        Label("Couldn’t open \(title)", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button("Try again") { session.load(url, requestID: reloadID, force: true) }.buttonStyle(.glass)
                    }.background(.background)
                }
            }
            #if os(iOS)
            .navigationTitle(title)
            #endif
            .task(id: reloadID) { session.load(url, requestID: reloadID) }
    }

}

// Retain one webview per sidebar destination while SwiftUI manages its layout.
#if os(macOS)
private struct EmbeddedWebView: NSViewRepresentable {
    let page: WKWebView
    func makeNSView(context: Context) -> WKWebView { page }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
#else
private struct EmbeddedWebView: UIViewRepresentable {
    let page: WKWebView
    func makeUIView(context: Context) -> WKWebView { page }
    func updateUIView(_ view: WKWebView, context: Context) {}
}
#endif
