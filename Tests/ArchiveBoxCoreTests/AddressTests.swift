import Foundation
import Testing
@testable import ArchiveBoxCore

@Test func normalizesSharedTagsWithoutLosingMultiwordNames() {
    #expect(ArchiveTags.normalize([" research, read later\nSwift ", "RESEARCH", "", "café"]) == ["research", "read later", "Swift", "café"])
    #expect(ArchiveTags.normalize([" ,\n  "]).isEmpty)
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
