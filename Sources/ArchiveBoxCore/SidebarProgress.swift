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
}
