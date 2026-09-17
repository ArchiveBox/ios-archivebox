import ArchiveBoxCore
import Foundation

// Shared by both executables; a future Safari native target can use the same store and client.
enum AppEnvironment {
    static var store: ConfigurationStore {
        configurationStore(account: "server")
    }
    static func configurationStore(account: String) -> ConfigurationStore {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "ArchiveBoxKeychainGroup") as? String,
              !group.isEmpty else { preconditionFailure("ArchiveBoxKeychainGroup must be configured in Info.plist") }
        return ConfigurationStore(accessGroup: group, account: account)
    }
}
