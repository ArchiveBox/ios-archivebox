import Foundation
import Security

/// A saved destination. Identity survives credential rotation and display-name edits.
public struct ServerConfiguration: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let server: URL
    public let token: String
    /// nil selects the server's named Default persona. It never grants cookie-sync consent.
    public let persona: String?
    public init(id: String = UUID().uuidString.lowercased(), name: String = "", server: URL, token: String, persona: String? = nil) {
        self.id = id; self.name = name.isEmpty ? (server.host() ?? server.absoluteString) : name
        self.server = server; self.token = token; self.persona = persona
    }
    enum CodingKeys: String, CodingKey { case id, name, server, token, persona }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(name, forKey: .name)
        try values.encode(server, forKey: .server)
        try values.encode(token, forKey: .token)
        try values.encode(persona, forKey: .persona)
    }

}

public struct ServerRegistry: Codable, Sendable, Equatable {
    public var schema_version = 1
    public var servers: [ServerConfiguration] = []
    public var active_server_id: String?
    public var default_server_ids: [String] = []
    public init() {}
    public var active_server: ServerConfiguration? { servers.first { $0.id == active_server_id } }
    public var default_servers: [ServerConfiguration] {
        default_server_ids.compactMap { id in servers.first { $0.id == id } }
    }
    public mutating func upsert(_ configuration: ServerConfiguration) {
        if let index = servers.firstIndex(where: { $0.id == configuration.id }) {
            servers[index] = configuration
        } else {
            if servers.isEmpty { active_server_id = configuration.id; default_server_ids = [configuration.id] }
            servers.append(configuration)
        }
    }
    public mutating func remove(_ id: String) {
        servers.removeAll { $0.id == id }
        default_server_ids.removeAll { $0 == id }
        if active_server_id == id { active_server_id = servers.first?.id }
    }
    enum CodingKeys: String, CodingKey { case schema_version, servers, active_server_id, default_server_ids }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schema_version, forKey: .schema_version)
        try values.encode(servers, forKey: .servers)
        try values.encode(active_server_id, forKey: .active_server_id)
        try values.encode(default_server_ids, forKey: .default_server_ids)
    }
    public func validate() throws {
        let ids = Set(servers.map(\.id))
        guard schema_version == 1, ids.count == servers.count,
              servers.allSatisfy({ UUID(uuidString: $0.id)?.uuidString.lowercased() == $0.id && ["http", "https"].contains($0.server.scheme ?? "") && $0.server.host() != nil && $0.server.user() == nil && $0.server.password() == nil && $0.server.query() == nil && $0.server.fragment() == nil }),
              active_server_id.map({ ids.contains($0) }) ?? true,
              Set(default_server_ids).count == default_server_ids.count,
              default_server_ids.allSatisfy({ ids.contains($0) }) else {
            throw ArchiveBoxError.message("Saved server settings are invalid or from an unsupported version.")
        }
    }
}

/// One atomic, device-only Keychain registry shared with the read-only extensions.
/// Submitted URLs, receipts, and browser sessions remain in memory.
public struct ConfigurationStore: Sendable {
    private let item: KeychainItem
    public init(accessGroup: String) {
        item = KeychainItem(service: "io.archivebox.configuration", account: "server_registry", accessGroup: accessGroup)
    }
    public func load() throws -> ServerRegistry {
        guard let data = try item.load() else { return ServerRegistry() }
        let registry = try JSONDecoder().decode(ServerRegistry.self, from: data)
        try registry.validate()
        return registry
    }
    public func save(_ registry: ServerRegistry) throws {
        try registry.validate()
        try item.save(JSONEncoder().encode(registry))
    }
    public func clear() throws { try item.clear() }
}

/// Shared Keychain mechanics; each caller chooses its own service/account scope.
/// The client/extensions use a shared data-protection group. The independently
/// signed server companion keeps a collection-scoped item in its own Keychain.
public struct KeychainItem: Sendable {
    private let service: String
    private let account: String
    private let accessGroup: String?
    public init(service: String, account: String, accessGroup: String? = nil) {
        self.service = service; self.account = account; self.accessGroup = accessGroup
    }

    private var query: [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }

    public func load() throws -> Data? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data else { throw ArchiveBoxError.message("Saved settings could not be read.") }
        return data
    }

    public func save(_ data: Data) throws {
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            try check(SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil))
        } else { try check(status) }
    }

    public func clear() throws {
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }

    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            throw ArchiveBoxError.message("Could not access secure settings (\(status)). Unlock your device and try again.")
        }
    }
}
