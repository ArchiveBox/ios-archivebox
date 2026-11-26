import Foundation

public struct SidebarProgress: Decodable, Sendable {
    public struct Crawl: Decodable, Sendable {
        public let label: String
        public let started: String?
        public let status: String
    }
    public struct Collection: Decodable, Sendable {
        public let snapshots: Int
        public let bytes: Int64
    }
    public let crawls_active: Int
    public let active_crawls: [Crawl]
    public let collection: Collection?

    /// Refresh activity without blanking an already known size while the server samples it.
    /// Only pass a previous response from the same verified server and user.
    public func retainingCollection(from previous: Self?) -> Self {
        guard collection == nil, let collection = previous?.collection else { return self }
        return Self(crawls_active: crawls_active, active_crawls: active_crawls, collection: collection)
    }
}
