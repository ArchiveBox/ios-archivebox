import SwiftUI
import WebKit
import ArchiveBoxCore

// Embedded pages share an in-memory cookie store; the Keychain API key restores
// the session after relaunch without persisting browser credentials.
@MainActor @Observable final class PageSession {
    let page: WebPage
    var errorMessage: String?
    private var started = false
    private var requestID: UUID?
    private var navigation: Task<Void, Never>?
    private unowned let owner: WebPages
    private var destination: URL?
    init(_ page: WebPage, owner: WebPages) { self.page = page; self.owner = owner }

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
                for try await _ in page.load(url) {}
                // An expired/deleted server session can redirect to login even before
                // its advertised expiry. Exchange the key once, never loop on failure.
                if page.url?.path.contains("/login") == true, owner.hasCredentials {
                    try await owner.authenticate(force: true)
                    try Task.checkCancellation()
                    for try await _ in page.load(url) {}
                }
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
    var hasCredentials: Bool { server != nil && token != nil }

    func configure(server: URL?, token: String?) async {
        guard self.server != server || self.token != token else { return }
        self.server = server; self.token = token
        if server == nil || token == nil { await authentication.clear() }
        for page in pages.values { page.reconnect() }
    }

    func authenticate(force: Bool = false) async throws {
        guard let server, let token else { return }
        try await authentication.authenticate(server: server, token: token, force: force)
    }

    // Retain each screen's page independently, but allocate it only when visited.
    // All pages share the same authenticated in-memory cookie store.
    func page(for key: String) -> PageSession {
        if let page = pages[key] { return page }
        var configuration = WebPage.Configuration()
        // Match the companion's standalone monitor without stripping the admin
        // chrome from other screens or altering its server-owned polling code.
        configuration.websiteDataStore = authentication.dataStore
        configuration.userContentController.addUserScript(EmbeddedPage.script(activity: key.hasPrefix("activity-")))
        let page = PageSession(WebPage(configuration: configuration), owner: self)
        pages[key] = page
        return page
    }
}

struct ServerWebView: View {
    let url: URL
    let title: String
    let session: PageSession
    private var page: WebPage { session.page }
    var reloadID: UUID? = nil
    var body: some View {
        WebView(page)
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
