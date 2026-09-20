import ArchiveBoxCore
import Foundation

// The app owns registry edits. Share/Safari extensions read immutable destinations.
enum AppEnvironment {
    static func requireConfiguration() throws -> ServerConfiguration {
        guard let configuration = try store.load().active_server else {
            throw ArchiveBoxError.message("Open ArchiveBox → Connection Settings and save a server URL and API key first.")
        }
        return configuration
    }
    static func requireSubmissionConfiguration() throws -> ServerConfiguration {
        guard let configuration = try store.load().default_servers.first else {
            throw ArchiveBoxError.message("Configure a default submission server in ArchiveBox first.")
        }
        return configuration
    }
    static var store: ConfigurationStore {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "ArchiveBoxKeychainGroup") as? String,
              !group.isEmpty else { preconditionFailure("ArchiveBoxKeychainGroup must be configured in Info.plist") }
        return ConfigurationStore(accessGroup: group)
    }
}
