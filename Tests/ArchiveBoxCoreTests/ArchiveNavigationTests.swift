import Foundation
import Testing
@testable import ArchiveBoxCore

@Test func archiveRoutesRoundTripSearchAndServerScopedSnapshots() throws {
    let server = try #require(URL(string: "https://archive.example:8443"))
    let id = UUID().uuidString.lowercased()
    for route in [ArchiveRoute.search("café & Swift / #tags?"), .snapshot(server: server, id: id), .add] {
        #expect(ArchiveRoute(url: route.url) == route)
    }
    let route = ArchiveRoute.snapshot(server: server, id: id)
    #expect(route.snapshotURL(for: server) == server.appending(path: "snapshot/\(id)/index.html"))
    #expect(route.snapshotURL(for: URL(string: "https://other.example")!) == nil)
}

@Test func archiveRoutesRejectAmbiguousOrUnsafeDestinations() throws {
    for text in ["https://search?q=hello", "archivebox://unknown", "archivebox://search?q=a&q=b",
                 "archivebox://snapshot?server=https://user:secret@host&id=abc",
                 "archivebox://snapshot?server=https://host&id=../../admin",
                 "archivebox://snapshot?server=file:///tmp&id=abc", "archivebox://user@search?q=a",
                 "archivebox://search/extra?q=a"] {
        #expect(ArchiveRoute(url: try #require(URL(string: text))) == nil)
    }
}
