import AppIntents
import ArchiveBoxCore
import CoreSpotlight
import CoreTransferable
import Foundation
import UniformTypeIdentifiers

struct SaveURLsToArchiveBoxIntent: AppIntent {
    static let title: LocalizedStringResource = "Save URLs to ArchiveBox"
    static let description = IntentDescription("Send web links to your configured server using the app’s Default Persona. Returns the links accepted for archiving; capture finishes on the server.")
    static let supportedModes: IntentModes = .background
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "URLs", description: "One or more http:// or https:// links.",
               inputConnectionBehavior: .connectToPreviousIntentResult)
    var urls: [URL]

    static var parameterSummary: some ParameterSummary { Summary("Save \(\.$urls) to ArchiveBox") }

    func perform() async throws -> some IntentResult & ReturnsValue<[URL]> & ProvidesDialog {
        let configuration = try AppEnvironment.requireConfiguration()
        let links = SharedLinks.unique(urls)
        _ = try await ArchiveBoxClient().submit(urls: links, configuration: configuration)
        return .result(value: links, dialog: "Your server accepted \(links.count) URL(s) for archiving.")
    }
}

struct SearchArchiveBoxIntent: AppIntent {
    static let title: LocalizedStringResource = "Search ArchiveBox"
    static let description = IntentDescription("Find saved snapshots by URL, title, or tags. Returns archived pages to Shortcuts without opening ArchiveBox.")
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
        let configuration = try AppEnvironment.requireConfiguration()
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw $query.needsValueError("What would you like to find in ArchiveBox?")
        }
        let snapshots = try await ArchiveBoxClient().search(query: query, limit: limit, configuration: configuration)
        let results = snapshots.map { ArchiveBoxSearchResult(snapshot: $0, server: configuration.server) }
        let summary = results.prefix(3).map(\.title).joined(separator: "; ")
        return .result(value: results, dialog: "Found \(results.count) archived page(s). \(summary)")
    }
}

// IDs include the server, so a saved Shortcut can never resolve an old page
// against a different collection. The server remains the source of truth.
struct ArchiveBoxSearchResult: AppEntity, IndexedEntity, Transferable, URLRepresentableEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Archived Page"
    static let defaultQuery = ArchivePageQuery()
    static var urlRepresentation: URLRepresentation { "\(\.$appURL)" }
    let id: String
    @Property(title: "Snapshot ID") var snapshotID: String
    @Property(title: "Title") var title: String
    @Property(title: "Original URL") var originalURL: URL
    @Property(title: "Archive URL") var archiveURL: URL
    @Property(title: "Tags") var tags: [String]
    @Property(title: "Open in ArchiveBox") var appURL: URL

    init(snapshot: ArchiveSnapshot, server: URL) {
        let route = ArchiveRoute.snapshot(server: server, id: snapshot.id)
        id = route.url.absoluteString
        snapshotID = snapshot.id
        title = snapshot.title?.isEmpty == false ? snapshot.title! : snapshot.url.absoluteString
        originalURL = snapshot.url
        archiveURL = route.snapshotURL(for: server)!
        tags = snapshot.tags
        appURL = route.url
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(originalURL.absoluteString)", image: .init(systemName: "bookmark"))
    }

    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(exporting: \.originalURL)
    }

    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = CSSearchableItemAttributeSet(contentType: .url)
        attributes.title = title
        attributes.contentDescription = originalURL.absoluteString
        attributes.keywords = tags
        attributes.url = originalURL
        attributes.contentURL = appURL
        attributes.relatedUniqueIdentifier = id
        return attributes
    }
}

struct ArchivePageQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [ArchiveBoxSearchResult] {
        let configuration = try AppEnvironment.requireConfiguration()
        let client = ArchiveBoxClient()
        var results: [ArchiveBoxSearchResult] = []
        for identifier in identifiers {
            guard let url = URL(string: identifier), let route = ArchiveRoute(url: url),
                  case .snapshot(let server, let id) = route, server == configuration.server else { continue }
            let snapshot = try await client.snapshot(id: id, configuration: configuration)
            results.append(ArchiveBoxSearchResult(snapshot: snapshot, server: server))
        }
        return results
    }

    func entities(matching string: String) async throws -> [ArchiveBoxSearchResult] {
        let configuration = try AppEnvironment.requireConfiguration()
        return try await ArchiveBoxClient().search(query: string, configuration: configuration)
            .map { ArchiveBoxSearchResult(snapshot: $0, server: configuration.server) }
    }

    func suggestedEntities() async throws -> [ArchiveBoxSearchResult] {
        guard let configuration = try AppEnvironment.store.load() else { return [] }
        return try await ArchiveBoxClient().snapshots(limit: 10, configuration: configuration)
            .map { ArchiveBoxSearchResult(snapshot: $0, server: configuration.server) }
    }
}

@available(iOS 27.0, macOS 27.0, *)
@AppIntent(schema: .system.searchInApp)
struct SearchArchiveBoxWithSiriIntent: ShowInAppSearchResultsIntent {
    static let title: LocalizedStringResource = "Show ArchiveBox Search Results"
    static let supportedModes: IntentModes = .foreground
    static let searchScopes: [StringSearchScope] = [.general]
    var criteria: StringSearchCriteria

    @MainActor func perform() async throws -> some IntentResult {
        ArchiveNavigation.shared.open(.search(criteria.term))
        return .result()
    }
}

struct OpenArchivedPageIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Archived Page"
    static let supportedModes: IntentModes = .foreground
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @Parameter(title: "Archived Page") var target: ArchiveBoxSearchResult
    static var parameterSummary: some ParameterSummary { Summary("Open \(\.$target) in ArchiveBox") }
    func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(target.appURL))
    }
}

@available(iOS 27.0, macOS 27.0, *)
@AppIntent(schema: .system.open)
struct OpenArchivedPageWithSiriIntent: OpenIntent, URLRepresentableIntent {
    static let title: LocalizedStringResource = "Show Archived Page"
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    var target: ArchiveBoxSearchResult
}

struct OpenArchiveSearchIntent: AppIntent {
    static let title: LocalizedStringResource = "Open ArchiveBox Search"
    static let supportedModes: IntentModes = .foreground
    @MainActor func perform() async throws -> some IntentResult {
        try await OpenArchiveDestinationIntent(.search).perform()
    }
}

struct OpenAddURLsIntent: AppIntent {
    static let title: LocalizedStringResource = "Add URLs in ArchiveBox"
    static let supportedModes: IntentModes = .foreground
    @MainActor func perform() async throws -> some IntentResult {
        try await OpenArchiveDestinationIntent(.add).perform()
    }
}

struct ArchiveBoxShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: SearchArchiveBoxIntent(),
                    phrases: ["Search \(.applicationName)", "Find something in \(.applicationName)"],
                    shortTitle: "Search ArchiveBox", systemImageName: "magnifyingglass")
        AppShortcut(intent: SaveURLsToArchiveBoxIntent(),
                    phrases: ["Save URLs to \(.applicationName)", "Save links to \(.applicationName)", "Bookmark in \(.applicationName)"],
                    shortTitle: "Save URLs", systemImageName: "plus.app")
        AppShortcut(intent: OpenArchivedPageIntent(),
                    phrases: ["Open a saved page in \(.applicationName)", "Open \(\.$target) in \(.applicationName)"],
                    shortTitle: "Open Saved Page", systemImageName: "bookmark")
        AppShortcut(intent: OpenArchiveSearchIntent(),
                    phrases: ["Browse \(.applicationName)", "Open search in \(.applicationName)"],
                    shortTitle: "Browse Archive", systemImageName: "books.vertical")
        AppShortcut(intent: OpenAddURLsIntent(),
                    phrases: ["Add a bookmark in \(.applicationName)"],
                    shortTitle: "Add URLs", systemImageName: "plus")
    }
}
