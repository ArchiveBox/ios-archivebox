import AppIntents
import ArchiveBoxCore
import CoreSpotlight
import CryptoKit
import Foundation

// Serialize index changes so an in-flight result cannot restore the previous
// account's metadata after a server/key change. No second bookmark database.
@MainActor
enum ArchiveSystemIndex {
    private static var pending: Task<Void, Error>?

    static func update(_ pages: [ArchiveBoxSearchResult] = [], configuration: ServerConfiguration? = nil) async throws {
        let previous = pending
        let operation = Task {
            _ = try? await previous?.value
            let current = try AppEnvironment.store.load().active_server
            let scope = current.map { SHA256.hash(data: Data(($0.server.absoluteString + "\n" + $0.token).utf8)).map { String(format: "%02x", $0) }.joined() }
            let defaults = UserDefaults.standard
            let index = CSSearchableIndex.default()
            if defaults.string(forKey: "spotlight.connection") != scope {
                try await index.deleteAllSearchableItems()
                defaults.set(scope, forKey: "spotlight.connection")
            }
            guard let configuration, let current,
                  configuration.server == current.server, configuration.token == current.token else { return }
            // Index only metadata fetched by normal use. Expire it so deleted or
            // renamed server records aren't advertised forever on an offline device.
            let items = pages.map { page in
                let item = CSSearchableItem(appEntity: page)
                item.expirationDate = Date.now.addingTimeInterval(7 * 24 * 60 * 60)
                return item
            }
            try await index.indexSearchableItems(items)
        }
        pending = operation
        try await operation.value
    }

    static func connectionChanged() {
        Task {
            do { try await update() }
            catch { NSLog("ArchiveBox Spotlight update failed: %@", error.localizedDescription) }
        }
    }
}
