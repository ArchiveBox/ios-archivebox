import Foundation
import Security

public struct ServerConfiguration: Codable, Sendable, Equatable {
    public let server: URL
    public let token: String
    public init(server: URL, token: String) { self.server = server; self.token = token }
}

/// One atomic Keychain item binds the token to its verified server. Both targets use this group.
/// No submitted URLs, history, pending work, or offline content are persisted.
public struct ConfigurationStore: Sendable {
    private let accessGroup: String
    public init(accessGroup: String) { self.accessGroup = accessGroup }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "io.archivebox.configuration",
         kSecAttrAccount as String: "server",
         kSecAttrAccessGroup as String: accessGroup,
         kSecUseDataProtectionKeychain as String: true]
    }

    public func load() throws -> ServerConfiguration? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data else { throw ArchiveBoxError.message("Saved settings could not be read.") }
        return try JSONDecoder().decode(ServerConfiguration.self, from: data)
    }

    public func save(_ configuration: ServerConfiguration) throws {
        let data = try JSONEncoder().encode(configuration)
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            try check(SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil))
        } else { try check(status) }
    }

    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            throw ArchiveBoxError.message("Could not access secure settings (\(status)). Unlock your device and try again.")
        }
    }
}
