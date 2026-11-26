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

@Test func nativeBackAcceptsOnlyItsExactURL() throws {
    #expect(BrowserNavigation.isNativeBack(try #require(URL(string: "archivebox://back"))))
    for text in ["archivebox://back/", "archivebox://back?next=1", "archivebox://back#x",
                 "archivebox://user@back", "archivebox://back:44", "https://back"] {
        #expect(!BrowserNavigation.isNativeBack(try #require(URL(string: text))))
    }
}

@Test func nativeBackTrustsOnlyTheConfiguredServerChrome() throws {
    let server = try #require(URL(string: "https://api.archive.example"))
    let admin = try #require(URL(string: "https://admin.archive.example/admin/"))
    let base = try #require(URL(string: "https://archive.example"))
    let snapshot = "/web/20261126/example.com/0123456789abcdef0123456789abcdef"
    for text in ["https://admin.archive.example/admin/domains/",
                 "https://admin.archive.example/admin/activity/",
                 "https://api.archive.example/add/",
                 "https://web.archive.example" + snapshot] {
        let url = try #require(URL(string: text))
        #expect(BrowserNavigation.isTrustedNativeHeaderPage(url, configured: server, admin: admin, base: base))
    }
    for text in ["https://snap-123.archive.example/", "https://arbitrary.archive.example/admin/domains/",
                 "https://admin.archive.example.attacker.test/admin/domains/",
                 "https://www.archive.example" + snapshot, "https://web.archive.example/not-a-snapshot",
                 "http://web.archive.example" + snapshot, "https://admin.archive.example:444/admin/activity/"] {
        let url = try #require(URL(string: text))
        #expect(!BrowserNavigation.isTrustedNativeHeaderPage(url, configured: server, admin: admin, base: base))
    }
}
