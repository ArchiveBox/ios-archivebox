import Foundation
import WebKit

/// Every embedded page in an app shares this store. Only the API key is durable;
/// browser credentials are issued by Django and remain in memory.
@MainActor public final class BrowserAuthentication {
    public let dataStore = WKWebsiteDataStore.nonPersistent()
    private let client = ArchiveBoxClient()
    private struct Credentials: Equatable { let server: URL; let token: String }
    private var credentials: Credentials?
    private var session: BrowserSession?
    private var pending: Task<Void, Error>?
    private var generation = UUID()

    public init() {}

    /// Only the configured control origin (or its exact admin sibling) may hand
    /// credentials to the app. The broader replay/navigation boundary is not enough.
    public nonisolated static func isTrustedAdminPage(_ url: URL, server: URL) -> Bool {
        guard ["http", "https"].contains(server.scheme ?? ""), url.scheme == server.scheme,
              url.user == nil, url.password == nil,
              (url.port ?? (url.scheme == "https" ? 443 : 80)) == (server.port ?? (server.scheme == "https" ? 443 : 80)),
              let host = url.host?.lowercased(), let configuredHost = server.host?.lowercased(),
              (url.path == "/admin" || url.path.hasPrefix("/admin/")),
              !url.path.hasPrefix("/admin/login"), !url.path.hasPrefix("/admin/logout") else { return false }
        if host == configuredHost { return true }
        guard !configuredHost.contains(":"), !configuredHost.split(separator: ".").allSatisfy({ UInt8($0) != nil }) else { return false }
        let prefix = ["api.", "admin.", "web."].first { configuredHost.hasPrefix($0) }
        let base = prefix.map { String(configuredHost.dropFirst($0.count)) } ?? configuredHost
        return host == "admin." + base
    }

    /// Admin templates already create/reuse this user's key for their REST widgets.
    /// Read that existing value from the main frame; never export cookies or widen REST auth.
    public func apiKey(from webView: WKWebView, server: URL) async throws -> String? {
        guard webView.configuration.websiteDataStore === dataStore,
              let url = webView.url, Self.isTrustedAdminPage(url, server: server) else { return nil }
        let value = try await webView.callAsyncJavaScript("""
            if (window.location.href !== pageURL) return null;
            const key = window.ARCHIVEBOX_API_KEY;
            return typeof key === 'string' && key.trim() ? key.trim() : null;
            """, arguments: ["pageURL": url.absoluteString], in: nil, contentWorld: .page)
        try Task.checkCancellation()
        guard webView.url == url, Self.isTrustedAdminPage(url, server: server) else { return nil }
        return value as? String
    }

    public func authenticate(server: URL, token: String, force: Bool = false) async throws {
        let configuration = Credentials(server: server, token: token)
        if !force, credentials == configuration,
           let session, session.cookie.expires > Date().timeIntervalSince1970 + 60 { return }
        if credentials == configuration, let pending { try await pending.value; return }
        let changed = credentials != configuration
        pending?.cancel()
        credentials = configuration
        let generation = UUID()
        self.generation = generation
        let task = Task { @MainActor in
            if changed {
                await dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
                session = nil
            }
            try Task.checkCancellation()
            let login = try await client.browserSession(server: server, token: token)
            try Task.checkCancellation()
            guard self.generation == generation else { throw CancellationError() }
            guard let host = login.admin_url.host, ["http", "https"].contains(login.admin_url.scheme ?? ""),
                  login.cookie.expires > Date().timeIntervalSince1970 else {
                throw ArchiveBoxError.message("The server returned an invalid browser session.")
            }
            var properties: [HTTPCookiePropertyKey: Any] = [
                .name: login.cookie.name, .value: login.cookie.value, .domain: host, .path: "/",
                .expires: Date(timeIntervalSince1970: login.cookie.expires),
                HTTPCookiePropertyKey("HttpOnly"): "TRUE",
            ]
            if login.cookie.secure { properties[.secure] = "TRUE" }
            guard let cookie = HTTPCookie(properties: properties) else {
                throw ArchiveBoxError.message("The server returned an invalid session cookie.")
            }
            await dataStore.httpCookieStore.setCookie(cookie)
            session = login
        }
        pending = task
        defer { if self.generation == generation { pending = nil } }
        try await task.value
    }

    public func sidebarProgress(server: URL, token: String) async throws -> SidebarProgress {
        try await authenticate(server: server, token: token)
        guard let session else { throw ArchiveBoxError.message("The admin session is unavailable.") }
        let origin = try ServerAddress.normalize(session.admin_url.absoluteString)
        guard !session.cookie.secure || origin.scheme == "https" else {
            throw ArchiveBoxError.message("The admin session requires HTTPS.")
        }
        return try await client.sidebarProgress(server: origin, cookie: "\(session.cookie.name)=\(session.cookie.value)")
    }

    public func clear() async {
        generation = UUID()
        pending?.cancel(); pending = nil; credentials = nil; session = nil
        await dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }
}
