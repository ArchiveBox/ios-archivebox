import Foundation

// A native client must not forward tokens (including JSON-body tokens) through redirects.
private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public final class ArchiveBoxClient: Sendable {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    public func discoverServer(_ input: String) async throws -> URL {
        let candidates = try ServerAddress.candidates(for: input)
        var failures: [String] = []
        for server in candidates {
            try Task.checkCancellation()
            do {
                let data = try await request(server, path: "api/v1/openapi.json")
                let schema = try JSONDecoder().decode(APISchema.self, from: data)
                guard schema.info.title.localizedCaseInsensitiveContains("archivebox"),
                      schema.paths.keys.contains(where: { $0.hasSuffix("/cli/add") }),
                      schema.paths.keys.contains(where: { $0.hasSuffix("/auth/check_api_token") }) else {
                    throw ArchiveBoxError.message("This address does not expose the ArchiveBox submission API.")
                }
                return server
            } catch is CancellationError { throw CancellationError() }
            catch {
                if Task.isCancelled { throw CancellationError() }
                failures.append("\(server.host() ?? server.absoluteString): \(error.localizedDescription)")
            }
        }
        throw ArchiveBoxError.message("Could not connect to the ArchiveBox API. Check the address and your Wi-Fi or VPN.\n\n" + failures.joined(separator: "\n"))
    }

    public func testToken(server: URL, token: String) async throws {
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ArchiveBoxError.message("Enter your API key.")
        }
        let body = try JSONEncoder().encode(TokenRequest(token: token))
        let data = try await request(server, path: "api/v1/auth/check_api_token", body: body)
        let result = try JSONDecoder().decode(TokenResponse.self, from: data)
        guard result.success == true, result.userID != nil else {
            throw ArchiveBoxError.message("This API key is invalid or expired. Create a new key in your ArchiveBox server’s admin settings.")
        }
    }

    public func browserSession(server: URL, token: String) async throws -> BrowserSession {
        let data = try await request(server, path: "api/v1/auth/browser_session", body: Data("{}".utf8), token: token)
        return try JSONDecoder().decode(BrowserSession.self, from: data)
    }

    public func personas(server: URL, token: String) async throws -> [ServerPersona] {
        var personas: [ServerPersona] = []
        while true {
            let data = try await request(server, path: "api/v1/personas/personas", token: token,
                                         query: [URLQueryItem(name: "offset", value: String(personas.count))])
            let page = try JSONDecoder().decode(PersonaPage.self, from: data)
            personas += page.items
            if personas.count >= page.total_items { return personas }
            guard !page.items.isEmpty else {
                throw ArchiveBoxError.message("The server returned an incomplete persona list. Refresh to try again.")
            }
        }
    }

    public func sidebarProgress(server: URL, cookie: String) async throws -> SidebarProgress {
        let data = try await request(server, path: "progress.json", query: [URLQueryItem(name: "collection", value: "1")], cookie: cookie)
        return try JSONDecoder().decode(SidebarProgress.self, from: data)
    }

    public func submit(urls: [URL], configuration: ServerConfiguration) async throws -> SubmissionReceipt {
        guard !urls.isEmpty, urls.allSatisfy({ SharedLinks.isWebURL($0) }) else {
            throw ArchiveBoxError.message("Share an http:// or https:// link to ArchiveBox.")
        }
        if let selected = configuration.persona {
            let available = try await personas(server: configuration.server, token: configuration.token)
            guard available.contains(where: { $0.name == selected }) else {
                throw ArchiveBoxError.message("The saved persona is no longer available. Choose a persona in the ArchiveBox app and save your settings again.")
            }
        }
        let body = try JSONEncoder().encode(AddRequest(urls: urls.map(\.absoluteString), persona: configuration.persona ?? "Default"))
        let data = try await request(configuration.server, path: "api/v1/cli/add", body: body, token: configuration.token)
        let response = try JSONDecoder().decode(AddResponse.self, from: data)
        guard response.success, response.errors?.isEmpty != false, let result = response.result,
              result.confirms(urls: urls) else {
            throw ArchiveBoxError.message("The server did not confirm the submission. Check your ArchiveBox server before trying again.")
        }
        return result
    }

    public func updateTags(_ tags: [String], for receipt: SubmissionReceipt, configuration: ServerConfiguration) async throws {
        guard let crawlID = receipt.crawlID, !crawlID.isEmpty else {
            throw ArchiveBoxError.message("The server did not return a crawl ID for updating tags.")
        }
        let tags = ArchiveTags.normalize(tags)
        let body = try JSONEncoder().encode(TagUpdate(tags: tags))
        // Snapshots are created asynchronously. Updating their parent crawl also
        // updates existing snapshots and supplies tags to ones created later.
        let data = try await request(configuration.server, path: "api/v1/crawls/crawl/\(crawlID)",
                                     body: body, token: configuration.token, method: "PATCH")
        let result = try JSONDecoder().decode(TagUpdateResponse.self, from: data)
        guard result.id == crawlID,
              Set(ArchiveTags.normalize([result.tags_str]).map { $0.lowercased() }) == Set(tags.map { $0.lowercased() }) else {
            throw ArchiveBoxError.message("The server did not confirm the tag update.")
        }
    }

    public func tagSuggestions(query: String, configuration: ServerConfiguration) async throws -> [String] {
        let data = try await request(configuration.server, path: "api/v1/core/tags/autocomplete/", token: configuration.token,
                                     query: [URLQueryItem(name: "q", value: query)])
        return try JSONDecoder().decode(TagSuggestions.self, from: data).tags.map(\.name)
    }

    public func removeSubmission(_ receipt: SubmissionReceipt, configuration: ServerConfiguration) async throws {
        guard let crawlID = receipt.crawlID, !crawlID.isEmpty else {
            throw ArchiveBoxError.message("The server did not return a crawl ID for removal.")
        }
        // Delete only the crawl returned by this share, never all captures of its URL.
        // The server cancels its workers before removing its snapshots.
        let data = try await request(configuration.server, path: "api/v1/crawls/crawl/\(crawlID)",
                                     token: configuration.token, method: "DELETE")
        let result = try JSONDecoder().decode(RemovalResponse.self, from: data)
        guard result.success, result.crawl_id == crawlID else {
            throw ArchiveBoxError.message("The server did not confirm removal. Check your archive before trying again.")
        }
    }

    private func request(_ server: URL, path: String, body: Data? = nil, token: String? = nil, query: [URLQueryItem] = [], cookie: String? = nil, method: String? = nil) async throws -> Data {
        var request = URLRequest(url: server.appending(path: path).appending(queryItems: query))
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let cookie { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
        if let method { request.httpMethod = method }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ArchiveBoxError.message("The server returned an invalid response.") }
        switch http.statusCode {
        case 200..<300: return data
        case 300..<400: throw ArchiveBoxError.message("The server redirected this request. Test and save its API address in Settings.")
        case 401, 403: throw ArchiveBoxError.message("Access denied. Check that your API key belongs to an ArchiveBox administrator.")
        case 404: throw ArchiveBoxError.message("ArchiveBox API not found at this address.")
        default: throw ArchiveBoxError.message("The server returned HTTP \(http.statusCode).")
        }
    }
}

public enum ArchiveTags {
    public static func normalize(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.flatMap { $0.components(separatedBy: CharacterSet(charactersIn: ",\n")) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }
}

private struct TagUpdate: Encodable { let tags: [String] }
private struct TagUpdateResponse: Decodable { let id: String; let tags_str: String }
private struct TagSuggestions: Decodable {
    struct Tag: Decodable { let name: String }
    let tags: [Tag]
}
private struct RemovalResponse: Decodable { let success: Bool; let crawl_id: String }

private struct APISchema: Decodable {
    struct Info: Decodable { let title: String }
    struct Operation: Decodable {}
    let info: Info
    let paths: [String: Operation]
}
private struct TokenRequest: Encodable { let token: String }
private struct TokenResponse: Decodable {
    let success: Bool?
    let userID: String?
    enum CodingKeys: String, CodingKey { case success; case userID = "user_id" }
}
public struct ServerPersona: Decodable, Sendable, Identifiable {
    public let id: String
    public let name: String
}
private struct PersonaPage: Decodable {
    let items: [ServerPersona]
    let total_items: Int
}
private struct AddRequest: Encodable { let urls: [String]; let persona: String; let depth = 0 }
private struct AddResponse: Decodable {
    let success: Bool
    let errors: [String]?
    let result: SubmissionReceipt?
}
public struct SubmissionReceipt: Decodable, Sendable {
    public let crawlID: String?
    public let queuedURLs: [String]?
    enum CodingKeys: String, CodingKey {
        case crawlID = "crawl_id", queuedURLs = "queued_urls"
    }

    func confirms(urls: [URL]) -> Bool {
        // 0.9 creates snapshots asynchronously: the persisted crawl and echoed URLs
        // confirm acceptance even when no snapshot rows exist yet.
        if let crawlID, !crawlID.isEmpty, let queuedURLs {
            return Set(urls.map(\.absoluteString)).isSubset(of: Set(queuedURLs))
        }
        return false
    }
}

public struct BrowserSession: Decodable, Sendable {
    public struct Cookie: Decodable, Sendable {
        public let name: String
        public let value: String
        public let expires: Double
        public let secure: Bool
    }
    public let admin_url: URL
    public let cookie: Cookie
}
