import Foundation
import Security

public struct ServerConfiguration: Codable, Sendable, Equatable {
    public let server: URL
    public let token: String
    public let persona: String?
    public init(server: URL, token: String, persona: String? = nil) {
        self.server = server; self.token = token; self.persona = persona
    }
}

/// One atomic Keychain item binds the token to its verified server. Both targets use this group.
/// No submitted URLs, history, pending work, or offline content are persisted.
public struct ConfigurationStore: Sendable {
    private let item: KeychainItem
    public init(accessGroup: String, account: String = "server") {
        item = KeychainItem(service: "io.archivebox.configuration", account: account, accessGroup: accessGroup)
    }

    public func load() throws -> ServerConfiguration? {
        guard let data = try item.load() else { return nil }
        return try JSONDecoder().decode(ServerConfiguration.self, from: data)
    }

    public func save(_ configuration: ServerConfiguration) throws {
        try item.save(JSONEncoder().encode(configuration))
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
