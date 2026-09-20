import Foundation

/// Credential-free navigation shared by Siri, Spotlight, Handoff and the app.
public enum ArchiveRoute: Equatable, Sendable {
    case search(String)
    case snapshot(server: URL, id: String)
    case add

    public init?(url: URL) {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "archivebox", parts.user == nil, parts.password == nil,
              parts.port == nil, parts.path.isEmpty, parts.fragment == nil else { return nil }
        let items = parts.queryItems ?? []
        guard Set(items.map(\.name)).count == items.count else { return nil }
        switch parts.host {
        case "search":
            guard items.allSatisfy({ $0.name == "q" }) else { return nil }
            self = .search(items.first?.value ?? "")
        case "add":
            guard items.isEmpty else { return nil }
            self = .add
        case "snapshot":
            guard items.count == 2,
                  let address = items.first(where: { $0.name == "server" })?.value,
                  let server = try? ServerAddress.normalize(address), server.absoluteString == address,
                  let id = items.first(where: { $0.name == "id" })?.value, Self.isSnapshotID(id) else { return nil }
            self = .snapshot(server: server, id: id)
        default: return nil
        }
    }

    public var url: URL {
        var parts = URLComponents()
        parts.scheme = "archivebox"
        switch self {
        case .search(let term):
            parts.host = "search"; parts.queryItems = [URLQueryItem(name: "q", value: term)]
        case .snapshot(let server, let id):
            parts.host = "snapshot"
            parts.queryItems = [URLQueryItem(name: "server", value: server.absoluteString), URLQueryItem(name: "id", value: id)]
        case .add: parts.host = "add"
        }
        return parts.url!
    }

    public func snapshotURL(for server: URL) -> URL? {
        guard case .snapshot(let owner, let id) = self, owner == server, Self.isSnapshotID(id) else { return nil }
        return server.appending(path: "snapshot/\(id)/index.html")
    }

    public static func isSnapshotID(_ id: String) -> Bool {
        // The API emits UUIDs with or without hyphens. Never accept paths or prefixes.
        UUID(uuidString: id) != nil || (id.count == 32 && id.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) || (65...70).contains($0) })
    }
}
