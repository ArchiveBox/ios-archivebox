import Foundation
import WebKit

/// Every embedded page in an app shares this store. Only the API key is durable;
/// browser credentials are issued by Django and remain in memory.
@MainActor public final class BrowserAuthentication {
    public let dataStore = WKWebsiteDataStore.nonPersistent()
    private let client = ArchiveBoxClient()
    private var credentials: ServerConfiguration?
    private var session: BrowserSession?
    private var pending: Task<Void, Error>?
    private var generation = UUID()

    public init() {}

    public func authenticate(server: URL, token: String, force: Bool = false) async throws {
        let configuration = ServerConfiguration(server: server, token: token)
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

    public func clear() async {
        generation = UUID()
        pending?.cancel(); pending = nil; credentials = nil; session = nil
        await dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }
}
