import Foundation
import Testing
@testable import ArchiveBoxCore

@Test func browsingSelectionDoesNotChangeSubmissionDefaults() throws {
    let home = ServerConfiguration(server: URL(string: "https://home.example")!, token: "home-key", persona: "Personal")
    let work = ServerConfiguration(server: URL(string: "https://work.example")!, token: "work-key", persona: "Work")
    var registry = ServerRegistry()
    registry.upsert(home)
    registry.upsert(work)
    registry.active_server_id = work.id
    #expect(registry.default_servers == [home])
    #expect(registry.active_server == work)
    #expect(try JSONDecoder().decode(ServerRegistry.self, from: JSONEncoder().encode(registry)) == registry)
    registry.remove(work.id)
    #expect(registry.active_server == home)
    #expect(registry.default_servers == [home])
    registry.remove(home.id)
    #expect(registry.default_servers.isEmpty)
    #expect(registry.active_server == nil)
}

@Test func updatingCredentialsPreservesServerIdentityAndOtherProfiles() throws {
    let home = ServerConfiguration(server: URL(string: "https://home.example")!, token: "old", persona: "Personal")
    let work = ServerConfiguration(server: URL(string: "https://work.example")!, token: "work", persona: "Work")
    var registry = ServerRegistry()
    registry.upsert(home)
    registry.upsert(work)
    let updated = ServerConfiguration(id: home.id, name: "Home", server: home.server, token: "new", persona: "Other")
    registry.upsert(updated)
    #expect(registry.servers.count == 2)
    #expect(registry.default_servers == [updated])
    #expect(registry.servers.first { $0.id == work.id } == work)
}

@Test func canonicalRegistrySchemaMatchesTheOtherClients() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let data = try Data(contentsOf: root.appending(path: "docs/server_registry.example.json"))
    let registry = try JSONDecoder().decode(ServerRegistry.self, from: data)
    try registry.validate()
    #expect(registry.active_server?.name == "Work")
    #expect(registry.default_servers.map(\.name) == ["Home"])
    let source = try JSONSerialization.jsonObject(with: data) as! NSDictionary
    let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(registry)) as! NSDictionary
    #expect(source == encoded)
    var invalid = registry
    invalid.default_server_ids = ["unknown"]
    #expect(throws: (any Error).self) { try invalid.validate() }
    invalid = registry
    invalid.schema_version = 2
    #expect(throws: (any Error).self) { try invalid.validate() }
}
