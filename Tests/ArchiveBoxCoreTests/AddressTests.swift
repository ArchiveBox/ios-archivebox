import Foundation
import Testing
@testable import ArchiveBoxCore

@Test func normalizesSharedTagsWithoutLosingMultiwordNames() {
    #expect(ArchiveTags.normalize([" research, read later\nSwift ", "RESEARCH", "", "café"]) == ["research", "read later", "Swift", "café"])
    #expect(ArchiveTags.normalize([" ,\n  "]).isEmpty)
}

@Test func suggestsDomainWithoutSubdomainsOrPublicSuffixes() {
    for (host, tag) in [("abc.example.com", "example"), ("www.example.co.uk", "example"),
                        ("a.project.github.io", "project"), ("www.city.kawasaki.jp", "city"),
                        ("www.example.com.", "example")] {
        #expect(ArchiveTags.domainTag(for: URL(string: "https://\(host)")!) == tag)
    }
    for host in ["localhost", "127.0.0.1", "[::1]", "co.uk"] {
        #expect(ArchiveTags.domainTag(for: URL(string: "http://\(host)")!) == nil)
    }
}

@Test func remembersOnlyTwoRecentTagsPerServer() throws {
    let suite = "ArchiveBoxTagsTests." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let server = URL(string: "https://archive.example")!
    #expect(ArchiveTags.recentlyUsed(server: server, defaults: defaults).isEmpty)
    #expect(ArchiveTags.recentlyUsed(server: server, adding: ["first", "second", "third"], defaults: defaults) == ["third", "second"])
    #expect(ArchiveTags.recentlyUsed(server: server, adding: ["SECOND"], defaults: defaults) == ["SECOND", "third"])
    let reloaded = try #require(UserDefaults(suiteName: suite))
    #expect(ArchiveTags.recentlyUsed(server: server, defaults: reloaded) == ["SECOND", "third"])
    #expect(ArchiveTags.recentlyUsed(server: URL(string: "https://other.example")!, defaults: defaults).isEmpty)
}

@Test func normalizesPastedAddresses() throws {
    #expect(try ServerAddress.normalize("  Example.COM/admin/api/apitoken/?x=1#top ").absoluteString == "https://example.com")
    #expect(try ServerAddress.normalize("http://127.0.0.1:8123/").absoluteString == "http://127.0.0.1:8123")
    #expect(try ServerAddress.normalize("http://[::1]:8123/").absoluteString == "http://[::1]:8123")
}
@Test func rejectsUnsafeAddresses() {
    for text in ["", "ftp://host", "https://user:password@host", "bad host", "http://host:99999"] {
        #expect(throws: (any Error).self) { try ServerAddress.normalize(text) }
    }
}
@Test func correctsOnlyKnownHostVariants() throws {
    #expect(try ServerAddress.candidates(for: "https://admin.archive.example:8443").map(\.absoluteString)
            == ["https://admin.archive.example:8443", "https://api.archive.example:8443", "https://archive.example:8443"])
    #expect(try ServerAddress.candidates(for: "https://api.archive.example").map(\.absoluteString)
            == ["https://api.archive.example", "https://archive.example"])
    #expect(try ServerAddress.candidates(for: "http://127.0.0.1:8000").count == 1)
    #expect(try ServerAddress.candidates(for: "http://[::1]:8000").count == 1)
    #expect(try ServerAddress.candidates(for: "http://localhost:8947").map(\.absoluteString)
            == ["http://localhost:8947", "http://api.archivebox.localhost:8947", "http://archivebox.localhost:8947"])
    #expect(try ServerAddress.candidates(for: "http://api.localhost:8947").map(\.absoluteString)
            == ["http://api.localhost:8947", "http://api.archivebox.localhost:8947", "http://archivebox.localhost:8947"])
}
@Test func extractsLinksAcrossShareFormats() {
    #expect(SharedLinks.extract(from: "An article: https://example.com/a?q=1 and https://example.org/b").count == 2)
    #expect(SharedLinks.extract(from: "https://example.com/a#fragment").first?.fragment == "fragment")
    #expect(SharedLinks.extract(from: "file:///private/document").isEmpty)
    #expect(SharedLinks.extract(from: "mailto:someone@example.com").isEmpty)
    #expect(SharedLinks.extract(from: "https://user:password@example.com").isEmpty)
    #expect(SharedLinks.extract(from: "https://example.com https://example.com").count == 1)
}

@Test func configurationsRoundTripWithAnOptionalPersona() throws {
    let stored = Data(#"{"server":"https://archive.example","token":"test-only"}"#.utf8)
    let configuration = try JSONDecoder().decode(ServerConfiguration.self, from: stored)
    #expect(configuration.persona == nil)
    #expect(configuration.server.absoluteString == "https://archive.example")
    let updated = ServerConfiguration(server: configuration.server, token: configuration.token, persona: "Work")
    #expect(try JSONDecoder().decode(ServerConfiguration.self, from: JSONEncoder().encode(updated)) == updated)
}

@Test func embeddedNavigationKeepsOnlyTheConfiguredServerAndItsSubdomains() {
    let base = URL(string: "https://archive.example:8443")!
    for address in ["https://archive.example:8443/admin/", "http://archive.example/add/",
                    "https://ADMIN.archive.example:8443/admin/", "https://snap-123.archive.example:8443/index.html",
                    "https://nested.snap-123.archive.example/file.pdf", "https://archive.example./"] {
        #expect(BrowserNavigation.belongsToServer(URL(string: address)!, baseURL: base))
    }
    for address in ["https://example.org/", "https://notarchive.example/", "https://archive.example.attacker.test/",
                    "https://archive.example@attacker.test/", "mailto:someone@archive.example", "file:///archive.example"] {
        #expect(!BrowserNavigation.belongsToServer(URL(string: address)!, baseURL: base))
    }
    for address in ["http://127.0.0.1:8000", "http://[::1]:8000", "http://archivebox.localhost:18080"] {
        let local = URL(string: address)!
        #expect(BrowserNavigation.belongsToServer(local.appending(path: "admin/"), baseURL: local))
    }
    #expect(!BrowserNavigation.belongsToServer(URL(string: "http://sub.127.0.0.1")!, baseURL: URL(string: "http://127.0.0.1")!))
    #expect(!BrowserNavigation.belongsToServer(base, baseURL: nil))
}

@MainActor @Test func completedDownloadsNeverOverwriteExistingFiles() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let downloads = root.appending(path: "Downloads")
    let staging = root.appending(path: "staging")
    try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    for name in ["archive.pdf", "README"] {
        let existing = downloads.appendingPathComponent(name)
        try Data("original".utf8).write(to: existing)
        for number in 2...3 {
            let source = staging.appendingPathComponent(name)
            let data = Data("download \(number)".utf8)
            try data.write(to: source)
            let saved = try BrowserDownloads.moveCompletedFile(source, to: downloads)
            let expected = name == "README" ? "README (\(number))" : "archive (\(number)).pdf"
            #expect(saved.lastPathComponent == expected)
            #expect(try Data(contentsOf: saved) == data)
            #expect(!FileManager.default.fileExists(atPath: source.path))
        }
        #expect(try String(contentsOf: existing, encoding: .utf8) == "original")
    }
}
