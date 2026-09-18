import AppIntents
import ArchiveBoxCore
import Foundation

struct SaveURLsToArchiveBoxIntent: AppIntent {
    static let title: LocalizedStringResource = "Save URLs to ArchiveBox"
    static let description = IntentDescription("Send web links to your configured server using the app’s Default Persona. Returns the links accepted for archiving; capture finishes on the server.")
    static let supportedModes: IntentModes = .background
    // Match the existing device-only, when-unlocked Keychain credential policy.
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "URLs", description: "One or more http:// or https:// links.",
               inputConnectionBehavior: .connectToPreviousIntentResult)
    var urls: [URL]

    static var parameterSummary: some ParameterSummary { Summary("Save \(\.$urls) to ArchiveBox") }

    func perform() async throws -> some IntentResult & ReturnsValue<[URL]> & ProvidesDialog {
        guard let configuration = try AppEnvironment.store.load() else {
            throw ArchiveBoxError.message("Open ArchiveBox → Connection Settings and save a server URL and API key first.")
        }
        let links = SharedLinks.unique(urls)
        // Reuse the share sheet’s validation, persona selection and server receipt
        // check. No retries or local queue: an accepted submission must not repeat.
        _ = try await ArchiveBoxClient().submit(urls: links, configuration: configuration)
        return .result(value: links, dialog: "Your server accepted \(links.count) URL(s) for archiving.")
    }
}

struct SearchArchiveBoxIntent: AppIntent {
    static let title: LocalizedStringResource = "Search ArchiveBox"
    static let description = IntentDescription("Find saved snapshots by URL, title, or tags. Returns results to Shortcuts without opening ArchiveBox.")
    static let supportedModes: IntentModes = .background
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "Search", requestValueDialog: "What would you like to find in ArchiveBox?")
    var query: String

    @Parameter(title: "Maximum Results", default: 20, inclusiveRange: (1, 500))
    var limit: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Search ArchiveBox for \(\.$query)") { \.$limit }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[ArchiveBoxSearchResult]> & ProvidesDialog {
        guard let configuration = try AppEnvironment.store.load() else {
            throw ArchiveBoxError.message("Open ArchiveBox → Connection Settings and save a server URL and API key first.")
        }
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw $query.needsValueError("What would you like to find in ArchiveBox?")
        }
        let snapshots = try await ArchiveBoxClient().search(query: query, limit: limit, configuration: configuration)
        let results = snapshots.map { snapshot in
            let result = ArchiveBoxSearchResult()
            result.snapshotID = snapshot.id
            result.title = snapshot.title?.isEmpty == false ? snapshot.title! : snapshot.url.absoluteString
            result.originalURL = snapshot.url
            result.archiveURL = configuration.server.appending(path: "snapshot/\(snapshot.id)/index.html")
            result.tags = snapshot.tags
            return result
        }
        return .result(value: results, dialog: "Returned \(results.count) archived page(s).")
    }
}

// Results travel between Shortcut actions without indexing private archive
// content in Spotlight or adding a persistent, cross-server entity cache.
struct ArchiveBoxSearchResult: TransientAppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Archived Page"
    @Property(title: "Snapshot ID") var snapshotID: String
    @Property(title: "Title") var title: String
    @Property(title: "Original URL") var originalURL: URL
    @Property(title: "Archive URL") var archiveURL: URL
    @Property(title: "Tags") var tags: [String]

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(originalURL.absoluteString)")
    }
}

struct ArchiveBoxShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: SearchArchiveBoxIntent(),
                    phrases: ["Search \(.applicationName)", "Find something in \(.applicationName)"],
                    shortTitle: "Search ArchiveBox", systemImageName: "magnifyingglass")
        AppShortcut(intent: SaveURLsToArchiveBoxIntent(),
                    phrases: ["Save URLs to \(.applicationName)", "Save links to \(.applicationName)"],
                    shortTitle: "Save URLs", systemImageName: "plus.app")
    }
}
