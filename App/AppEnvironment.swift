import ArchiveBoxCore
import Foundation

// The client, share extension, and Safari native handler use the same verified connection.
enum AppEnvironment {
    static func requireConfiguration() throws -> ServerConfiguration {
        guard let configuration = try store.load() else {
            throw ArchiveBoxError.message("Open ArchiveBox → Connection Settings and save a server URL and API key first.")
        }
        return configuration
    }
    static var store: ConfigurationStore {
        configurationStore(account: "server")
    }
    static func configurationStore(account: String) -> ConfigurationStore {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "ArchiveBoxKeychainGroup") as? String,
              !group.isEmpty else { preconditionFailure("ArchiveBoxKeychainGroup must be configured in Info.plist") }
        return ConfigurationStore(accessGroup: group, account: account)
    }
}
